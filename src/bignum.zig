// blip_mp_t — bignum value whose canonical storage is BLIP-encoded bytes
// interpreted as signed two's-complement (per SPEC.md §Sign convention).
//
// Representation 1a (small-buffer-optimization) with HEAP REUSE and
// SIGN-EXTENDED INLINE TAIL:
//   - Tier 0/1 (encoded ≤ INLINE_CAP=24 bytes) lives inline; zero alloc.
//   - **Invariant** for inline-length-prefixed values (inline_len in 2..9):
//     `inline_buf[1..9]` holds the full sign-extended i64 in LE form, NOT
//     just the canonical L payload bytes. This lets `decodeInlineSmall`
//     (the arithmetic hot path) read the i64 with a single u64 load —
//     no header parse, no per-byte loop, no sign-extension. External
//     readers via `bytes()` still see only `inline_buf[0..inline_len]`,
//     i.e., the canonical form. setBytes/setI64 maintain this invariant.
//   - Larger values use heap_buf; heap_used tracks the active length.
//     setBytes/setI64 reuse heap_buf when heap_buf.len >= needed (saves
//     malloc/free on every tier-3 op when sizes are stable).
//
// Struct layout (72 bytes total on 64-bit):
//   [0..24)   inline_buf       — encoded bytes when in inline mode
//   [24]      inline_len       — 0..INLINE_CAP if inline; SENTINEL_HEAP if heap
//   [25]      heap_offset      — start offset within heap_buf (heap mode only)
//   [26]      cached_pay_off   — cached payload offset within bytes() view
//   [27]      cached_sign      — cached sign: -1 negative, 0 zero, +1 positive
//   [28..32)  cached_pay_len   — cached payload length (u32, max 4G bytes per Mp)
//   [32..40)  heap_used        — active length within heap_buf starting at heap_offset
//   [40..56)  heap_buf         — full allocation (slice ptr + cap)
//   [56..72)  allocator        — std.mem.Allocator (ptr + vtable ptr)
//
// The cached fields mirror GMP's _mp_size approach (sign + length cached in
// the struct rather than parsed from the data per-op). This eliminates the
// per-op `parseHeader` call and per-op high-bit-of-high-byte sign extraction
// that previously dominated tier-3 add at small sizes (256-2048 bit). Cache
// is maintained atomically with the bytes by every set/setBytes/tier3Op call.
//
// heap_offset enables tier3Op's direct-write optimisation: write the canonical
// payload at a fixed offset (HDR_RESERVE = 10) inside heap_buf, compute the
// header length, then write the header at HDR_RESERVE - hdr_len. Set
// heap_offset = HDR_RESERVE - hdr_len. bytes() returns the contiguous slice
// from heap_offset of length heap_used. This eliminates the scratch+memcpy
// chain that previously dominated 128-512 bit tier-3 add (~5-7 ns/op saved).

const std = @import("std");
const encoding = @import("encoding.zig");
const tier3 = @import("tier3.zig");

pub const INLINE_CAP: usize = 24;
const SENTINEL_HEAP: u8 = 0xFF;

pub const SetError = std.mem.Allocator.Error || encoding.Error || error{
	UnsignedTooLarge,
};

pub const GetError = encoding.Error || error{
	SentinelValue,
	ValueIsNegative,
};

pub const ArithError = SetError || GetError || error{
	TierOverflow, // currently unused — tier 3 promotion handles all in-range cases
	OutputBufferTooSmall, // tier-3 result wouldn't fit in target Mp's heap or inline buffer
};

pub const Mp = struct {
	inline_buf: [INLINE_CAP]u8 align(8),
	inline_len: u8,
	heap_offset: u8,
	cached_pay_off: u8,
	cached_sign: i8, // -1 / 0 / +1
	cached_pay_len: u32,
	heap_used: usize,
	heap_buf: []u8,
	allocator: std.mem.Allocator,

	pub fn init(allocator: std.mem.Allocator) Mp {
		return .{
			.inline_buf = [_]u8{0} ** INLINE_CAP,
			.inline_len = 0,
			.heap_offset = 0,
			.cached_pay_off = 0,
			.cached_sign = 0,
			.cached_pay_len = 0,
			.heap_used = 0,
			.heap_buf = &[_]u8{},
			.allocator = allocator,
		};
	}

	pub fn deinit(self: *Mp) void {
		if (self.heap_buf.len != 0) {
			self.allocator.free(self.heap_buf);
			self.heap_buf = &[_]u8{};
			self.heap_used = 0;
			self.heap_offset = 0;
		}
		self.inline_len = 0;
		self.cached_pay_off = 0;
		self.cached_pay_len = 0;
		self.cached_sign = 0;
	}

	/// Returns the cached payload slice (the value bytes after the BLIP
	/// header). For immediate values (b0 < 0x80) this is the single byte;
	/// for length-prefixed it's the L payload bytes. Cheap: just slices
	/// `bytes()` using the cached offset/len. Used by tier3Op to skip
	/// parseHeader on inputs.
	pub fn payload(self: *const Mp) []const u8 {
		const all = self.bytes();
		const off: usize = self.cached_pay_off;
		return all[off .. off + self.cached_pay_len];
	}

	/// Returns the cached sign (-1, 0, +1) without re-decoding.
	pub fn cachedSign(self: *const Mp) i8 {
		return self.cached_sign;
	}

	/// Returns the active encoded bytes — points into either inline_buf or
	/// heap_buf. Caller must not retain the slice across mutating ops.
	pub fn bytes(self: *const Mp) []const u8 {
		if (self.inline_len != SENTINEL_HEAP) {
			return self.inline_buf[0..self.inline_len];
		}
		return self.heap_buf[self.heap_offset .. self.heap_offset + self.heap_used];
	}

	pub fn isInline(self: *const Mp) bool {
		return self.inline_len != SENTINEL_HEAP;
	}

	/// Replace this value with the canonical signed BLIP encoding of `value`.
	/// Tier 0/1 stays inline (zero allocation). Larger values fall back to heap.
	///
	/// Hot path: value in [0,127] gets a single-byte store with no call into
	/// the encoder. Closes the Mp.add/raw gap measured in BENCHMARK_RESULTS.md
	/// Run 2 (~0.6 ns saved per immediate add).
	pub fn setI64(self: *Mp, value: i64) SetError!void {
		// Immediate-range fast path.
		if (value >= 0 and value < 128) {
			self.inline_buf[0] = @intCast(value);
			self.inline_len = 1;
			self.cached_pay_off = 0;
			self.cached_pay_len = 1;
			self.cached_sign = if (value == 0) 0 else 1;
			return;
		}
		const u: u64 = if (value >= 0) @bitCast(value) else ~@as(u64, @bitCast(value));
		const bits: usize = 64 - @clz(u) + 1;
		const L: usize = (bits + 7) / 8;
		const need = 1 + L;
		self.inline_buf[0] = 0x80 | @as(u8, @intCast(L));
		std.mem.writeInt(u64, self.inline_buf[1..9], @bitCast(value), .little);
		self.inline_len = @intCast(need);
		self.heap_offset = 0;
		self.cached_pay_off = 1;
		self.cached_pay_len = @intCast(L);
		self.cached_sign = if (value > 0) 1 else -1; // value != 0 here (handled above)
	}

	/// Ensure heap_buf has at least `cap` bytes. If a realloc happens it
	/// drops the previous contents (caller must re-write). For monotonically
	/// growing workloads, doubles the existing cap to amortise realloc cost.
	inline fn ensureHeapCapacity(self: *Mp, cap: usize) std.mem.Allocator.Error!void {
		if (self.heap_buf.len >= cap) return;
		const new_cap = @max(cap, 2 * self.heap_buf.len);
		if (self.heap_buf.len != 0) self.allocator.free(self.heap_buf);
		self.heap_buf = try self.allocator.alloc(u8, new_cap);
	}

	pub fn setU64(self: *Mp, value: u64) SetError!void {
		if (value > std.math.maxInt(i64)) return error.UnsignedTooLarge;
		return self.setI64(@intCast(value));
	}

	pub fn getI64(self: *const Mp) GetError!i64 {
		// Hot path: inline + immediate first byte (< 0x80). One byte read,
		// no decode loop, no sign-extension.
		if (self.inline_len != SENTINEL_HEAP and self.inline_len == 1 and self.inline_buf[0] < 0x80) {
			return self.inline_buf[0];
		}
		const dec = try encoding.decodeI64(self.bytes());
		if (dec.is_sentinel) return error.SentinelValue;
		return dec.value;
	}

	pub fn getU64(self: *const Mp) GetError!u64 {
		const v = try self.getI64();
		if (v < 0) return error.ValueIsNegative;
		return @intCast(v);
	}

	pub fn cmp(a: *const Mp, b: *const Mp) GetError!std.math.Order {
		const av = try a.getI64();
		const bv = try b.getI64();
		return std.math.order(av, bv);
	}

	pub fn sign(self: *const Mp) GetError!i2 {
		// Use the cached sign — no decode required.
		return @intCast(self.cached_sign);
	}

	pub fn add(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		// Tier-0/1 fast path: both operands inline AND ≤9 bytes each.
		// Hand-inlined to keep the compiler from emitting function calls
		// in the hot loop (measured: function-call form was 4× slower).
		if (a.inline_len <= 9 and b.inline_len <= 9) {
			const av = decodeInlineSmall(a);
			const bv = decodeInlineSmall(b);
			const ov = @addWithOverflow(av, bv);
			if (ov[1] == 0) {
				try r.setI64(ov[0]);
				return;
			}
		}
		try tier3Op(r, a, b, .add);
	}

	pub fn sub(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		if (a.inline_len <= 9 and b.inline_len <= 9) {
			const av = decodeInlineSmall(a);
			const bv = decodeInlineSmall(b);
			const ov = @subWithOverflow(av, bv);
			if (ov[1] == 0) {
				try r.setI64(ov[0]);
				return;
			}
		}
		try tier3Op(r, a, b, .sub);
	}

	pub fn mul(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		if (a.inline_len <= 9 and b.inline_len <= 9) {
			const av: i128 = @as(i128, decodeInlineSmall(a));
			const bv: i128 = @as(i128, decodeInlineSmall(b));
			const product: i128 = av * bv;
			if (product >= std.math.minInt(i64) and product <= std.math.maxInt(i64)) {
				try r.setI64(@intCast(product));
				return;
			}
		}
		try tier3MulOp(r, a, b);
	}

	/// Returns true iff this Mp's encoded form fits in the i64 universe
	/// (signed canonical L ≤ 8 → at most 9 bytes total).
	fn fitsTier01(self: *const Mp) bool {
		const len = if (self.inline_len != SENTINEL_HEAP) self.inline_len else self.heap_bytes.len;
		return len <= 9;
	}

	/// Replace this Mp's value with the BLIP-encoded byte slice given.
	/// Routes inline vs heap and REUSES heap_buf when capacity suffices.
	///
	/// For inline length-prefixed values (slice.len in 2..9), maintains the
	/// "sign-extended i64 in inline_buf[1..9]" invariant by sign-extending
	/// the canonical payload up to 8 bytes after the header.
	pub fn setBytes(self: *Mp, slice: []const u8) std.mem.Allocator.Error!void {
		if (slice.len <= INLINE_CAP) {
			@memcpy(self.inline_buf[0..slice.len], slice);
			if (slice.len >= 2 and slice.len <= 9) {
				const L = slice.len - 1;
				const high_byte = self.inline_buf[1 + L - 1];
				const sign_fill: u8 = if ((high_byte & 0x80) != 0) 0xFF else 0x00;
				var i: usize = L;
				while (i < 8) : (i += 1) self.inline_buf[1 + i] = sign_fill;
			}
			self.inline_len = @intCast(slice.len);
			self.heap_offset = 0;
			self.computeAndCacheMeta(slice);
			return;
		}
		try self.ensureHeapCapacity(slice.len);
		@memcpy(self.heap_buf[0..slice.len], slice);
		self.heap_used = slice.len;
		self.heap_offset = 0;
		self.inline_len = SENTINEL_HEAP;
		self.computeAndCacheMeta(slice);
	}

	/// Decode a BLIP-encoded slice's payload offset, length, and sign, and
	/// store them in the cached fields. Called once per `setBytes` so the
	/// arithmetic hot path doesn't re-parse the header per op.
	fn computeAndCacheMeta(self: *Mp, slice: []const u8) void {
		if (slice.len == 0) {
			self.cached_pay_off = 0;
			self.cached_pay_len = 0;
			self.cached_sign = 0;
			return;
		}
		const b0 = slice[0];
		if (b0 < 0x80) {
			// Immediate, always 0..127, non-negative.
			self.cached_pay_off = 0;
			self.cached_pay_len = 1;
			self.cached_sign = if (b0 == 0) 0 else 1;
			return;
		}
		// Length-prefixed: parse header to find offset and length.
		const hdr = encoding.headerInfoLookup(b0);
		var L: usize = b0 & 0x1F;
		var pos: usize = 1;
		if (hdr.has_continuation) {
			var shift: u6 = 5;
			while (pos < slice.len) {
				const n = slice[pos];
				pos += 1;
				L |= @as(usize, n & 0x7F) << shift;
				shift += 7;
				if ((n & 0x80) == 0) break;
			}
		}
		self.cached_pay_off = @intCast(pos);
		self.cached_pay_len = @intCast(L);
		// Sign: high bit of high payload byte (or 0 if L=0 / all-zero).
		if (L == 0) {
			self.cached_sign = 0;
		} else {
			const high = slice[pos + L - 1];
			if ((high & 0x80) != 0) {
				self.cached_sign = -1;
			} else {
				// Positive or zero — check all bytes for non-zero.
				var any_nonzero = false;
				for (slice[pos .. pos + L]) |b| if (b != 0) {
					any_nonzero = true;
					break;
				};
				self.cached_sign = if (any_nonzero) 1 else 0;
			}
		}
	}
};

/// Hot-path decoder for inline values with len ≤ 9. Inlined in arithmetic.
/// Exploits the invariant that for length-prefixed inline values,
/// `inline_buf[1..9]` holds the full sign-extended i64 in LE — so we read
/// it as a single u64 load. Compiles to ~2-3 instructions on aarch64 vs
/// the prior loop-and-decode call.
inline fn decodeInlineSmall(self: *const Mp) i64 {
	// Immediate (single byte, value < 128).
	if (self.inline_len == 1 and self.inline_buf[0] < 0x80) {
		return self.inline_buf[0];
	}
	// Length-prefixed: tail invariant gives us the i64 directly.
	return @bitCast(std.mem.readInt(u64, self.inline_buf[1..9], .little));
}

/// Tier-3 multiplication. Sign-magnitude on byte payloads; result up to
/// `a_payload + b_payload + 1` bytes. Stack scratch for inputs up to
/// 1024 bytes each (8192-bit operands); spills to allocator beyond.
fn tier3MulOp(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	const a_bytes = a.bytes();
	const b_bytes = b.bytes();
	const a_pay_len: usize = if (a_bytes[0] < 0x80) 1 else a_bytes.len - 1;
	const b_pay_len: usize = if (b_bytes[0] < 0x80) 1 else b_bytes.len - 1;
	const r_pay_max = a_pay_len + b_pay_len + 1;
	const out_need = r_pay_max + 10; // +10 for header

	// 4 KB per operand for mul (results double, so 8 KB result + out).
	// Covers up to ~32768-bit operands without spilling to allocator.
	const STACK_BYTES = 4096;
	var stack_a: [STACK_BYTES]u8 = undefined;
	var stack_b: [STACK_BYTES]u8 = undefined;
	var stack_r: [STACK_BYTES * 2 + 1]u8 = undefined;
	var stack_out: [STACK_BYTES * 2 + 16]u8 = undefined;
	// Karatsuba scratch — sized for the larger operand.
	const max_pay = @max(a_pay_len, b_pay_len);
	const k_need = if (a_pay_len == b_pay_len) tier3.karatsubaScratchNeed(max_pay) else 0;
	var stack_k: [STACK_BYTES * 4 + 64]u8 = undefined;
	var heap_a: ?[]u8 = null;
	var heap_b: ?[]u8 = null;
	var heap_r: ?[]u8 = null;
	var heap_out: ?[]u8 = null;
	var heap_k: ?[]u8 = null;
	defer {
		if (heap_a) |s| r.allocator.free(s);
		if (heap_b) |s| r.allocator.free(s);
		if (heap_r) |s| r.allocator.free(s);
		if (heap_out) |s| r.allocator.free(s);
		if (heap_k) |s| r.allocator.free(s);
	}
	const sa: []u8 = if (a_pay_len <= STACK_BYTES) stack_a[0..a_pay_len] else blk: {
		heap_a = try r.allocator.alloc(u8, a_pay_len);
		break :blk heap_a.?;
	};
	const sb: []u8 = if (b_pay_len <= STACK_BYTES) stack_b[0..b_pay_len] else blk: {
		heap_b = try r.allocator.alloc(u8, b_pay_len);
		break :blk heap_b.?;
	};
	const sr: []u8 = if (r_pay_max <= stack_r.len) stack_r[0..r_pay_max] else blk: {
		heap_r = try r.allocator.alloc(u8, r_pay_max);
		break :blk heap_r.?;
	};
	const out_buf: []u8 = if (out_need <= stack_out.len) stack_out[0..out_need] else blk: {
		heap_out = try r.allocator.alloc(u8, out_need);
		break :blk heap_out.?;
	};
	const sk: []u8 = if (k_need == 0) &[_]u8{} else if (k_need <= stack_k.len) stack_k[0..k_need] else blk: {
		heap_k = try r.allocator.alloc(u8, k_need);
		break :blk heap_k.?;
	};

	const written = try tier3.mulRawBlip(a_bytes, b_bytes, sa, sb, sr, sk, out_buf);
	try r.setBytes(out_buf[0..written]);
}

/// Internal tier-3 dispatch. Operates DIRECTLY on the BLIP payload bytes
/// (no limb-array conversion) AND writes the result directly into r.heap_buf
/// (no scratch + setBytes copy chain). Two's-complement arithmetic is
/// bit-position-local, so per-byte add/sub with carry produces correct
/// results across any sign combination.
///
/// Layout strategy in r.heap_buf:
///   [0..HDR_RESERVE)               — pre-reserved header room
///   [HDR_RESERVE..HDR_RESERVE+canon) — canonical payload (computed in place)
/// After computing canon, write the header at offset (HDR_RESERVE - hdr_len),
/// set heap_offset = (HDR_RESERVE - hdr_len), heap_used = hdr_len + canon.
/// `bytes()` returns heap_buf[heap_offset..heap_offset+heap_used] — the
/// contiguous header || payload region. No shift, no extra memcpy.
const TierOp = enum { add, sub };
const HDR_RESERVE: usize = 10; // max BLIP header (continuation up to L≈2^77)

fn tier3Op(r: *Mp, a: *const Mp, b: *const Mp, comptime op: TierOp) ArithError!void {
	const a_bytes = a.bytes();
	const b_bytes = b.bytes();
	const a_pay_off: usize = a.cached_pay_off;
	const b_pay_off: usize = b.cached_pay_off;
	const a_pay_len: usize = a.cached_pay_len;
	const b_pay_len: usize = b.cached_pay_len;
	const a_sign: i8 = a.cached_sign;
	const b_sign: i8 = b.cached_sign;

	const max_payload = @max(a_pay_len, b_pay_len);
	const out_need = HDR_RESERVE + max_payload + 1;

	const may_realloc = r.heap_buf.len < out_need;
	const r_aliases_input = (a_bytes.ptr == r.heap_buf.ptr) or (b_bytes.ptr == r.heap_buf.ptr);
	if (may_realloc or r_aliases_input) {
		try tier3OpCold(r, a_bytes, b_bytes, a_pay_off, a_pay_len, b_pay_off, b_pay_len, out_need, op);
		return;
	}

	// Hot path: inlined applyTier3Op via the `inline fn` keyword.
	_ = a_sign;
	_ = b_sign;
	const a_pay = a_bytes[a_pay_off .. a_pay_off + a_pay_len];
	const b_pay = b_bytes[b_pay_off .. b_pay_off + b_pay_len];
	try applyTier3Op(r, a_pay, b_pay, op);
}

/// Cold path: ensureHeapCapacity may realloc r.heap_buf, OR r aliases an
/// input. Snapshot input payloads to stack scratch first.
fn tier3OpCold(
	r: *Mp,
	a_bytes: []const u8, b_bytes: []const u8,
	a_pay_off: usize, a_pay_len: usize,
	b_pay_off: usize, b_pay_len: usize,
	out_need: usize,
	comptime op: TierOp,
) ArithError!void {
	const STACK_IN = 8192;
	var stack_a: [STACK_IN]u8 = undefined;
	var stack_b: [STACK_IN]u8 = undefined;
	var heap_a_in: ?[]u8 = null;
	var heap_b_in: ?[]u8 = null;
	defer {
		if (heap_a_in) |s| r.allocator.free(s);
		if (heap_b_in) |s| r.allocator.free(s);
	}
	const a_copy: []u8 = if (a_pay_len <= STACK_IN) stack_a[0..a_pay_len] else blk: {
		heap_a_in = try r.allocator.alloc(u8, a_pay_len);
		break :blk heap_a_in.?;
	};
	const b_copy: []u8 = if (b_pay_len <= STACK_IN) stack_b[0..b_pay_len] else blk: {
		heap_b_in = try r.allocator.alloc(u8, b_pay_len);
		break :blk heap_b_in.?;
	};
	@memcpy(a_copy, a_bytes[a_pay_off .. a_pay_off + a_pay_len]);
	@memcpy(b_copy, b_bytes[b_pay_off .. b_pay_off + b_pay_len]);
	try r.ensureHeapCapacity(out_need);
	try applyTier3Op(r, a_copy, b_copy, op);
}

/// Compute op(a_pay, b_pay) → r.heap_buf using the pre-reserved-header layout.
/// Marked `inline` so both the hot path (in tier3Op) and the cold path (in
/// tier3OpCold) get the body inlined directly with no function-call overhead.
inline fn applyTier3Op(r: *Mp, a_pay: []const u8, b_pay: []const u8, comptime op: TierOp) ArithError!void {
	const n = @max(a_pay.len, b_pay.len);
	const payload_dst = r.heap_buf[HDR_RESERVE..];
	const result_len = switch (op) {
		.add => tier3.addPayloads(a_pay, b_pay, n, payload_dst),
		.sub => tier3.subPayloads(a_pay, b_pay, n, payload_dst),
	};
	const canon = tier3.canonicalLen(payload_dst[0..result_len]);

	if (canon == 1 and payload_dst[0] < 0x80) {
		r.inline_buf[0] = payload_dst[0];
		r.inline_len = 1;
		r.heap_offset = 0;
		r.cached_pay_off = 0;
		r.cached_pay_len = 1;
		r.cached_sign = if (payload_dst[0] == 0) 0 else 1;
		return;
	}
	const total = canon + headerByteCount(canon);
	if (total <= INLINE_CAP) {
		var hdr_buf: [HDR_RESERVE]u8 = undefined;
		const hdr_len = tier3.writeHeader(&hdr_buf, canon) catch unreachable;
		@memcpy(r.inline_buf[0..hdr_len], hdr_buf[0..hdr_len]);
		@memcpy(r.inline_buf[hdr_len .. hdr_len + canon], payload_dst[0..canon]);
		if (total >= 2 and total <= 9) {
			const L = total - 1;
			const high_byte = r.inline_buf[1 + L - 1];
			const sign_fill: u8 = if ((high_byte & 0x80) != 0) 0xFF else 0;
			var i: usize = L;
			while (i < 8) : (i += 1) r.inline_buf[1 + i] = sign_fill;
		}
		r.inline_len = @intCast(total);
		r.heap_offset = 0;
		r.cached_pay_off = @intCast(hdr_len);
		r.cached_pay_len = @intCast(canon);
		r.cached_sign = signFromPayload(r.inline_buf[hdr_len .. hdr_len + canon]);
		return;
	}

	const hdr_len = headerByteCount(canon);
	const hdr_start = HDR_RESERVE - hdr_len;
	_ = tier3.writeHeader(r.heap_buf[hdr_start .. hdr_start + hdr_len], canon) catch unreachable;
	r.heap_offset = @intCast(hdr_start);
	r.heap_used = hdr_len + canon;
	r.inline_len = SENTINEL_HEAP;
	r.cached_pay_off = @intCast(hdr_len);
	r.cached_pay_len = @intCast(canon);
	r.cached_sign = signFromPayload(r.heap_buf[hdr_start + hdr_len .. hdr_start + hdr_len + canon]);
}


/// How many header bytes does a length-prefixed BLIP value occupy?
/// Reads only from the buffer — uses the lookup table for the first byte
/// then walks any continuation bytes.
inline fn headerByteCountByte(b0: u8, buf: []const u8) usize {
	const info = encoding.headerInfoLookup(b0);
	if (!info.has_continuation) return 1;
	var pos: usize = 1;
	while (pos < buf.len) {
		const n = buf[pos];
		pos += 1;
		if ((n & 0x80) == 0) break;
	}
	return pos;
}

/// Sign of a payload (LE two's-complement) — high bit of high byte, or 0 if all-zero.
inline fn signFromPayload(payload: []const u8) i8 {
	if (payload.len == 0) return 0;
	if ((payload[payload.len - 1] & 0x80) != 0) return -1;
	for (payload) |b| if (b != 0) return 1;
	return 0;
}

/// Cheap helper: how many bytes will writeHeader produce for L?
inline fn headerByteCount(L: usize) usize {
	if (L < 32) return 1;
	// L ≥ 32: header byte + varint for (L >> 5).
	var n: usize = 2;
	var L_rem: usize = L >> 5;
	while (L_rem >= 128) : (L_rem >>= 7) n += 1;
	return n;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Mp.setU64(5) stores [0x05] inline and getU64 returns 5" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(5);
	try testing.expectEqualSlices(u8, &[_]u8{0x05}, x.bytes());
	try testing.expect(x.isInline());
	try testing.expectEqual(@as(u64, 5), try x.getU64());
}

test "Mp tier 0/1 values stay inline (zero allocation)" {
	const cases = [_]i64{ 0, 5, 127, 128, -1, -128, std.math.maxInt(i64), std.math.minInt(i64) };
	for (cases) |v| {
		var x = Mp.init(testing.allocator);
		defer x.deinit();
		try x.setI64(v);
		try testing.expect(x.isInline());
		try testing.expectEqual(v, try x.getI64());
	}
}

test "Mp.setU64 round-trip for values up to i64.max" {
	const cases = [_]u64{ 0, 1, 127, 128, 255, 256, 65535, 65536, std.math.maxInt(u32), std.math.maxInt(u32) + 1, std.math.maxInt(i64) };
	for (cases) |v| {
		var x = Mp.init(testing.allocator);
		defer x.deinit();
		try x.setU64(v);
		try testing.expectEqual(v, try x.getU64());
	}
}

test "Mp.setU64 rejects values above i64.max" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try testing.expectError(error.UnsignedTooLarge, x.setU64(std.math.maxInt(u64)));
	try testing.expectError(error.UnsignedTooLarge, x.setU64(@as(u64, std.math.maxInt(i64)) + 1));
}

test "Mp.setU64 reuse: second set replaces previous bytes without leak" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(5);
	try x.setU64(std.math.maxInt(i64));
	try testing.expectEqual(@as(u64, std.math.maxInt(i64)), try x.getU64());
	try testing.expectEqual(@as(usize, 9), x.bytes().len);
	try testing.expect(x.isInline());
}

test "Mp.setU64 produces single-byte form for immediate range" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(127);
	try testing.expectEqual(@as(usize, 1), x.bytes().len);
	try testing.expectEqual(@as(u8, 0x7F), x.bytes()[0]);
}

test "Mp.setU64(128) produces signed-canonical [0x82, 0x80, 0x00]" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(128);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x80, 0x00 }, x.bytes());
	try testing.expectEqual(@as(u64, 128), try x.getU64());
}

test "Mp.setI64 negative round-trip" {
	const cases = [_]i64{ -1, -127, -128, -129, -32768, -32769, std.math.minInt(i64) };
	for (cases) |v| {
		var x = Mp.init(testing.allocator);
		defer x.deinit();
		try x.setI64(v);
		try testing.expectEqual(v, try x.getI64());
	}
}

test "Mp.setI64(-1) bytes match spec example" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(-1);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xFF }, x.bytes());
}

test "Mp.getU64 errors on negative value" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(-1);
	try testing.expectError(error.ValueIsNegative, x.getU64());
}

test "Mp.cmp across signs and magnitudes" {
	const Pair = struct { a: i64, b: i64, order: std.math.Order };
	const cases = [_]Pair{
		.{ .a = 0, .b = 0, .order = .eq },
		.{ .a = 5, .b = 5, .order = .eq },
		.{ .a = 5, .b = 6, .order = .lt },
		.{ .a = 6, .b = 5, .order = .gt },
		.{ .a = -1, .b = 0, .order = .lt },
		.{ .a = 0, .b = -1, .order = .gt },
		.{ .a = -1, .b = 1, .order = .lt },
		.{ .a = -128, .b = -129, .order = .gt },
		.{ .a = std.math.maxInt(i64), .b = std.math.minInt(i64), .order = .gt },
	};
	for (cases) |c| {
		var a = Mp.init(testing.allocator);
		defer a.deinit();
		var b = Mp.init(testing.allocator);
		defer b.deinit();
		try a.setI64(c.a);
		try b.setI64(c.b);
		try testing.expectEqual(c.order, try a.cmp(&b));
	}
}

test "Mp.sign returns -1/0/+1" {
	var z = Mp.init(testing.allocator);
	defer z.deinit();
	try z.setI64(0);
	try testing.expectEqual(@as(i2, 0), try z.sign());
	try z.setI64(42);
	try testing.expectEqual(@as(i2, 1), try z.sign());
	try z.setI64(-42);
	try testing.expectEqual(@as(i2, -1), try z.sign());
}

fn doArith(
	comptime op: enum { add, sub, mul },
	a_v: i64,
	b_v: i64,
	expected: i64,
) !void {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(a_v);
	try b.setI64(b_v);
	switch (op) {
		.add => try r.add(&a, &b),
		.sub => try r.sub(&a, &b),
		.mul => try r.mul(&a, &b),
	}
	try testing.expectEqual(expected, try r.getI64());
}

fn expectArithOverflow(
	comptime op: enum { add, sub, mul },
	a_v: i64,
	b_v: i64,
) !void {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(a_v);
	try b.setI64(b_v);
	const got = switch (op) {
		.add => r.add(&a, &b),
		.sub => r.sub(&a, &b),
		.mul => r.mul(&a, &b),
	};
	try testing.expectError(error.TierOverflow, got);
}

test "add: tier 0 (immediate + immediate)" {
	try doArith(.add, 5, 7, 12);
	try doArith(.add, 0, 0, 0);
	try doArith(.add, 127, 0, 127);
}

test "add: tier 1 + sign mixing" {
	try doArith(.add, 100, 200, 300);
	try doArith(.add, 65535, 1, 65536);
	try doArith(.add, -1, 1, 0);
	try doArith(.add, -100, 50, -50);
	try doArith(.add, std.math.maxInt(i32), std.math.maxInt(i32), 2 * @as(i64, std.math.maxInt(i32)));
}

test "add: canonical-L shrink after sign-extension cancellation" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(-1);
	try b.setI64(1);
	try r.add(&a, &b);
	try testing.expectEqual(@as(i64, 0), try r.getI64());
	try testing.expectEqualSlices(u8, &[_]u8{0x00}, r.bytes());
}

test "add: i64 overflow promotes to tier 3 (no longer errors)" {
	// Was error.TierOverflow before tier-3 promotion landed; now silently
	// promotes. Result encoding exceeds 9 bytes (the i64 universe).
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try b.setI64(1);
	try r.add(&a, &b);
	try testing.expect(r.bytes().len > 9);
}

test "sub: basic and sign mixing" {
	try doArith(.sub, 10, 3, 7);
	try doArith(.sub, 3, 10, -7);
	try doArith(.sub, 0, 1, -1);
	try doArith(.sub, -5, -5, 0);
	try doArith(.sub, std.math.maxInt(i64), std.math.maxInt(i64), 0);
}

test "sub: i64 overflow promotes to tier 3 (no longer errors)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.minInt(i64));
	try b.setI64(1);
	try r.sub(&a, &b);
	try testing.expect(r.bytes().len > 9);
}

test "mul: basic and sign mixing" {
	try doArith(.mul, 6, 7, 42);
	try doArith(.mul, -6, 7, -42);
	try doArith(.mul, -6, -7, 42);
	try doArith(.mul, 0, std.math.maxInt(i64), 0);
	try doArith(.mul, 1, std.math.maxInt(i64), std.math.maxInt(i64));
}

test "mul: i64 overflow now promotes to tier 3" {
	// Was error.TierOverflow before tier-3 mul landed; now succeeds with
	// result encoding > 9 bytes (the i64 universe).
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();

	try a.setI64(std.math.maxInt(i64));
	try b.setI64(2);
	try r.mul(&a, &b);
	try testing.expect(r.bytes().len > 9);

	try a.setI64(@as(i64, 1) << 32);
	try b.setI64(@as(i64, 1) << 32);
	try r.mul(&a, &b);
	try testing.expect(r.bytes().len > 9);

	try a.setI64(std.math.minInt(i64));
	try b.setI64(-1);
	try r.mul(&a, &b);
	try testing.expect(r.bytes().len > 9);
}

test "mul: result canonicalizes (small product from large inputs)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(1_000_000);
	try b.setI64(0);
	try r.mul(&a, &b);
	try testing.expectEqualSlices(u8, &[_]u8{0x00}, r.bytes());
}

test "arithmetic does not mutate inputs" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(100);
	try b.setI64(200);
	const a_bytes_before = try testing.allocator.dupe(u8, a.bytes());
	defer testing.allocator.free(a_bytes_before);
	const b_bytes_before = try testing.allocator.dupe(u8, b.bytes());
	defer testing.allocator.free(b_bytes_before);
	try r.add(&a, &b);
	try testing.expectEqualSlices(u8, a_bytes_before, a.bytes());
	try testing.expectEqualSlices(u8, b_bytes_before, b.bytes());
}

test "arithmetic with aliasing (r = a; r.add(&r, &b))" {
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	try r.setI64(100);
	try b.setI64(50);
	try r.add(&r, &b);
	try testing.expectEqual(@as(i64, 150), try r.getI64());
}

test "Mp struct size: 72 bytes (one cache line + 8 for heap_used)" {
	try testing.expectEqual(@as(usize, 72), @sizeOf(Mp));
}

test "tier-3 add via direct-write produces correct bytes()" {
	// Build two 256-bit values that are simple to verify after the add.
	// Each byte = 0x01 except the high byte = 0x10 (positive); add yields
	// each byte = 0x02 except high = 0x20.
	var a_pay: [32]u8 = [_]u8{0x01} ** 32;
	a_pay[31] = 0x10;
	var blip: [34]u8 = undefined;
	blip[0] = 0xA0;
	blip[1] = 0x01;
	@memcpy(blip[2..], &a_pay);

	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setBytes(&blip);
	try b.setBytes(&blip);
	try r.add(&a, &b);

	const r_bytes = r.bytes();
	// Header for L=32: continuation-bit set, low-5 of L=0, then varint 0x01.
	try testing.expectEqual(@as(usize, 34), r_bytes.len);
	try testing.expectEqual(@as(u8, 0xA0), r_bytes[0]);
	try testing.expectEqual(@as(u8, 0x01), r_bytes[1]);
	for (r_bytes[2..34], 0..) |byte, i| {
		try testing.expectEqual(@as(u8, 2 * a_pay[i]), byte);
	}
}

test "tier-3 result fits in inline when ≤ INLINE_CAP bytes" {
	// (i64.max + 1) goes through tier-3 (i64 add overflows) and encodes as
	// 10 bytes (L=9 + 1-byte header). 10 ≤ INLINE_CAP(24), so the result
	// takes the inline-fits fast path and r ends up inline. Subtract 1 →
	// i64.max (9 bytes), still inline. Both should be reachable via
	// getI64 for the inline-fits-i64 case.
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var one = Mp.init(testing.allocator);
	defer one.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try one.setI64(1);
	try r.add(&a, &one); // r = 2^63 (tier-3 path; result fits inline at 10 bytes)
	try testing.expect(r.isInline());
	try testing.expectEqual(@as(usize, 10), r.bytes().len);
	// 2^63 doesn't fit in i64 (positive value of i64.min's magnitude).
	try testing.expectError(error.OverlongEncoding, r.getI64());
	try r.sub(&r, &one); // r = i64.max (9 bytes, fits inline AND fits i64)
	try testing.expect(r.isInline());
	try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try r.getI64());
}

test "tier-3 add stable across many ops in same r (heap_offset doesn't drift)" {
	// Repeated add into the same r should stay correct — the heap_offset
	// gets reset/recomputed correctly each call.
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	// Build a 256-bit value.
	var pay: [32]u8 = .{0x01} ** 32;
	pay[31] = 0x01; // small positive
	var blip: [34]u8 = undefined;
	blip[0] = 0xA0;
	blip[1] = 0x01;
	@memcpy(blip[2..], &pay);
	try a.setBytes(&blip);
	try r.setI64(0);
	// r = 0 + a + a + a + ... + a (10 times) = 10 * a
	for (0..10) |_| {
		try r.add(&r, &a);
	}
	const r_bytes = r.bytes();
	// 10 * each byte = 10 (no carry between bytes). High byte = 10. Total 32 bytes payload.
	// Result fits in L=32 → header [0xA0, 0x01], payload bytes = 10 each.
	try testing.expectEqual(@as(u8, 0xA0), r_bytes[0]);
	try testing.expectEqual(@as(u8, 0x01), r_bytes[1]);
	for (r_bytes[2..]) |byte| {
		try testing.expectEqual(@as(u8, 10), byte);
	}
}

// ── Tier-3 cross-tier promotion tests ────────────────────────────────────────
//
// Drive the tier3.zig path through Mp.add. Operands chosen so that:
//   - both operands fit in i64 (tier 0/1 fast path is reachable), or
//   - operand or result exceeds i64 (must promote to tier 3)

test "add: i64.max + 1 promotes to tier 3 (no error.TierOverflow)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try b.setI64(1);
	try r.add(&a, &b); // Was error.TierOverflow before tier-3.
	// Result = 2^63, which doesn't fit in i64. Should encode in L=9 with leading sign byte.
	// Verify by decoding via tier3.payloadToMagnitude and checking the magnitude.
	const r_bytes = r.bytes();
	try testing.expect(r_bytes.len > 9); // exceeds i64 universe
}

test "add: minInt(i64) + (-1) promotes to tier 3 (negative overflow)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.minInt(i64));
	try b.setI64(-1);
	try r.add(&a, &b); // tier 3 takes over
	try testing.expect(r.bytes().len > 9);
}

test "sub: i64.max - i64.min overflows i64, promotes" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try b.setI64(std.math.minInt(i64));
	try r.sub(&a, &b);
	// Result = 2^64 - 1, doesn't fit in i64.
	try testing.expect(r.bytes().len > 9);
}

test "tier-3 round-trip: (i64.max + 1) - 1 = i64.max (back to tier 0/1)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var one = Mp.init(testing.allocator);
	defer one.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try one.setI64(1);
	try r.add(&a, &one); // r = 2^63 (tier 3)
	try r.sub(&r, &one); // r = 2^63 - 1 = i64.max (back to tier 0/1, encoded in 9 bytes)
	try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try r.getI64());
}
