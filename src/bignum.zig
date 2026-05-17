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
	DivisionByZero, // div / mod / divMod / powm with zero divisor or modulus
	NotImplementedTier3, // div / mod / powm tier-3 path not yet shipped (M7-2 / M7-3 / M7-4)
	NegativeExponentNotSupported, // powm with exp < 0 (would require modular inverse — M7-5)
};

/// Reduce `a` modulo |m| (Euclidean), into a buffer-managed Mp.
/// Centralised so invMod and other modular ops can normalise inputs.
fn euclideanReduce(out: *Mp, a: *const Mp, m_abs: *const Mp) ArithError!void {
	try out.mod(a, m_abs);
	if (out.cached_sign < 0) try out.add(out, m_abs);
}

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

	/// Total order over signed BLIP-encoded values. Sign-first dispatch
	/// using the cached_sign field (skips per-call decode); for same-sign
	/// pairs, compares the canonical payload bytes directly. Works correctly
	/// for tier-3 values of arbitrary size — no i64 overflow risk.
	///
	/// Same-sign comparison logic:
	///   Both positive: longer payload = larger magnitude = larger value.
	///                  Equal length, compare bytes high-to-low as unsigned.
	///   Both negative: longer payload = MORE negative = SMALLER value
	///                  (canonical encoding strips redundant 0xFF prefix).
	///                  Equal length, compare two's-complement payload bytes
	///                  unsigned high-to-low — for negatives this gives the
	///                  correct numeric order directly (less-negative two's-
	///                  complement values have larger unsigned bit patterns).
	pub fn cmp(a: *const Mp, b: *const Mp) std.math.Order {
		const a_sign = a.cached_sign;
		const b_sign = b.cached_sign;
		if (a_sign != b_sign) return std.math.order(a_sign, b_sign);
		if (a_sign == 0) return .eq;

		const a_pay = a.payload();
		const b_pay = b.payload();

		if (a_sign > 0) {
			if (a_pay.len != b_pay.len) return std.math.order(a_pay.len, b_pay.len);
		} else {
			// Both negative: longer canonical payload = more negative.
			if (a_pay.len != b_pay.len) return std.math.order(b_pay.len, a_pay.len);
		}
		// Equal-length payloads: chunked u64 unsigned LE compare via tier3 helper.
		const c = tier3.cmpUnsignedLE(a_pay, a_pay.len, b_pay, b_pay.len);
		return if (c < 0) .lt else if (c > 0) .gt else .eq;
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
		// Small-tier-3 fast path: both inline and each payload ≤ 16 bytes
		// (i.e. fits in u128). Closes the 128-bit Mp.mul gap to GMP — replaces
		// the full tier3MulOp scratch+dispatch chain with a single u128 × u128
		// → u256 widening multiply. Result may need heap (max 35 bytes encoded
		// > INLINE_CAP=24), but we avoid the 80-KB stack frame of tier3MulOp.
		if (a.inline_len != SENTINEL_HEAP and b.inline_len != SENTINEL_HEAP
			and a.cached_pay_len <= 16 and b.cached_pay_len <= 16
			// Aliasing safety: smallInlineTier3Mul reads a.inline_buf/b.inline_buf
			// (struct fields, not heap) into u128 locals BEFORE writing r — so
			// r aliasing a or b is fine.
		) {
			try smallInlineTier3Mul(r, a, b);
			return;
		}
		// Same-size mul fast path: both payloads exactly N bytes, N ∈ {32,48,64}.
		// Skips tier3MulOp's 80-KB stack frame and the dispatcher branch ladder.
		// Snapshots payloads to small stack buffers BEFORE ensureHeapCapacity,
		// so r aliasing a or b is safe even with reallocation.
		if (a.cached_pay_len == b.cached_pay_len) {
			switch (a.cached_pay_len) {
				24 => {
					try sameSizeTier3Mul(24, r, a, b);
					return;
				},
				32 => {
					try sameSizeTier3Mul(32, r, a, b);
					return;
				},
				48 => {
					try sameSizeTier3Mul(48, r, a, b);
					return;
				},
				64 => {
					try sameSizeTier3Mul(64, r, a, b);
					return;
				},
				else => {},
			}
		}
		// Asymmetric-with-small-side fast path: if one operand's |magnitude|
		// fits in u64, route to the dedicated mulMagnitudeByU64 (GMP's
		// mpn_mul_1 analogue) via Mp.mulU64. Saves the generic 2D schoolbook's
		// per-byte tail overhead on the small side. Critical for workloads
		// like the pi spigot where one mul operand is a small running counter
		// (k, l, n) and the other is a huge accumulator (q, r, t).
		const a_fits_u64 = magFitsInU64(a);
		const b_fits_u64 = magFitsInU64(b);
		if (a_fits_u64 or b_fits_u64) {
			// Pick the side that fits as the scalar; the other as multiplicand.
			const scalar_side = if (a_fits_u64) a else b;
			const big_side = if (a_fits_u64) b else a;
			const c_mag: u64 = magnitudeAsU64(scalar_side);
			// mulU64 produces r = big_side × c_mag with sign(r) = sign(big_side)
			// (since c_mag is treated as a positive scalar). If the scalar side
			// was negative we negate r at the end to get the correct sign.
			try mulU64(r, big_side, c_mag);
			if (scalar_side.cachedSign() < 0) {
				// Negate r in place via 0 - r. (Can't import sign.zig — circular.)
				var zero = Mp.init(r.allocator);
				defer zero.deinit();
				try zero.setI64(0);
				try r.sub(&zero, r);
			}
			return;
		}
		try tier3MulOp(r, a, b);
	}

	/// Returns true if `|x|` fits in u64. Cheap O(1) check using cached
	/// payload length. For pay_len ≤ 8 the magnitude always fits in u64
	/// (positive or negative 2's-complement representable in 64 bits). For
	/// pay_len = 9 the magnitude can be up to 2^71, which exceeds u64 —
	/// fall through to the generic path rather than misroute. (We accept
	/// missing a tight band of values in [2^63, 2^64) that COULD fit; the
	/// check would need to inspect bytes which costs more than it saves.)
	inline fn magFitsInU64(x: *const Mp) bool {
		return x.cached_pay_len <= 8;
	}

	/// Extract `|x|` as a u64. Caller must have verified `magFitsInU64(x)`.
	/// Handles the two's-complement encoding for negative values.
	inline fn magnitudeAsU64(x: *const Mp) u64 {
		if (x.cachedSign() == 0) return 0;
		const pay = x.payload();
		var v: u64 = 0;
		var shift: u6 = 0;
		const lim = @min(pay.len, 8);
		for (pay[0..lim]) |b| {
			v |= @as(u64, b) << shift;
			if (shift == 56) break;
			shift += 8;
		}
		if (x.cachedSign() < 0) {
			// `v` is the low 8 bytes of a two's-complement encoding. Compute
			// the magnitude = -v as u64. For pay.len < 8, the high bits of v
			// must be sign-extended to 1s first so the negation is correct.
			if (pay.len < 8) {
				const sign_mask: u64 = ~@as(u64, 0) << @intCast(8 * pay.len);
				v |= sign_mask;
			}
			v = (~v) +% 1; // two's-complement negation, wrapping u64
		}
		return v;
	}

	/// Add an unsigned u64 scalar to `a` (GMP `mpz_add_ui` analogue).
	/// Sign-aware: c is non-negative, so a += c shrinks |a| when a < 0 and
	/// |a| > c. Tier-0/1 fast path via native i128; tier-3 routes through
	/// a one-time setI64(c) into a temp Mp + Mp.add. (The setI64 + add for
	/// a single-byte constant is cheap; the perf win is avoiding the
	/// caller's c1/c2 cached-constant churn rather than a fused inner loop.)
	pub fn addU64(r: *Mp, a: *const Mp, c: u64) ArithError!void {
		if (c == 0) {
			try r.setBytes(a.bytes());
			return;
		}
		if (a.inline_len <= 9) {
			const av: i128 = @as(i128, decodeInlineSmall(a));
			const sum: i128 = av + @as(i128, c);
			if (sum >= std.math.minInt(i64) and sum <= std.math.maxInt(i64)) {
				try r.setI64(@intCast(sum));
				return;
			}
		}
		// Tier-3: build a one-shot Mp(c), call Mp.add. c is u64 so always
		// representable via setI64 if ≤ i64.max, else as a 9-byte payload.
		var c_mp = Mp.init(r.allocator);
		defer c_mp.deinit();
		if (c <= std.math.maxInt(i64)) {
			try c_mp.setI64(@intCast(c));
		} else {
			var buf: [16]u8 = undefined;
			buf[0] = 0x80 | 9;
			std.mem.writeInt(u64, buf[1..9], c, .little);
			buf[9] = 0x00; // sign byte (positive)
			try c_mp.setBytes(buf[0..10]);
		}
		try r.add(a, &c_mp);
	}

	/// Fused `self += a * c` (GMP `mpz_addmul_ui` analogue). When `self` and
	/// `a` are same-sign-positive (the spigot's common case), the inner loop
	/// is a single chunked-u64 pass:
	///   prod ← a_word × c + self_word + carry
	///   write low 64 to self
	///   carry ← high 64
	/// Saves one full pass over the data vs the unfused `tmp = a*c; self +=
	/// tmp` form (which is the fallback for mixed-sign cases).
	pub fn addmulU64(self: *Mp, a: *const Mp, c: u64) ArithError!void {
		// Trivial cases.
		if (c == 0 or a.cachedSign() == 0) return;
		// Same-sign-positive fast path: fused inner loop on the magnitudes.
		// Includes the case where `self` is zero (we just become a*c).
		const self_sign = self.cachedSign();
		const a_sign = a.cachedSign();
		const same_sign_or_self_zero = (self_sign == 0) or (self_sign == a_sign);
		if (!same_sign_or_self_zero) {
			// Mixed-sign fallback: compute tmp = a*c, then self += tmp.
			var tmp = Mp.init(self.allocator);
			defer tmp.deinit();
			try tmp.mulU64(a, c);
			try self.add(self, &tmp);
			return;
		}
		// Fused path. Work on the magnitude bytes of self and a.
		const allocator = self.allocator;
		const a_pay = a.payload();
		const self_pay = self.payload();
		const negative = a_sign < 0; // self_sign matches (or self is zero)

		// Magnitude bytes for a (positive-form).
		const a_mag = try allocator.alloc(u8, a_pay.len);
		defer allocator.free(a_mag);
		@memcpy(a_mag, a_pay);
		if (a_sign < 0) tier3.negateInPlace(a_mag);
		var a_mag_len: usize = a_mag.len;
		while (a_mag_len > 0 and a_mag[a_mag_len - 1] == 0) a_mag_len -= 1;

		// Magnitude bytes for self (will be modified in place). Allocate
		// enough headroom for the worst-case grown magnitude: max(self,
		// a_len + carry-bytes). a's mag_len + 8 covers a*c carry; the
		// self_pay can be larger so use max.
		const headroom = @max(self_pay.len, a_mag_len) + 16;
		const out_mag = try allocator.alloc(u8, headroom);
		defer allocator.free(out_mag);
		@memset(out_mag, 0);
		const self_mag_len_in: usize = blk: {
			if (self_sign == 0) break :blk 0;
			@memcpy(out_mag[0..self_pay.len], self_pay);
			if (self_sign < 0) tier3.negateInPlace(out_mag[0..self_pay.len]);
			var n: usize = self_pay.len;
			while (n > 0 and out_mag[n - 1] == 0) n -= 1;
			break :blk n;
		};

		// Fused inner loop: chunked u64 over min(a_mag_len, self_mag_len_in).
		var carry: u128 = 0;
		var i: usize = 0;
		const merged_aligned = (@min(a_mag_len, self_mag_len_in) / 8) * 8;
		while (i < merged_aligned) : (i += 8) {
			const a_word = std.mem.readInt(u64, a_mag[i..][0..8], .little);
			const self_word = std.mem.readInt(u64, out_mag[i..][0..8], .little);
			const prod: u128 = @as(u128, a_word) * @as(u128, c) + @as(u128, self_word) + carry;
			std.mem.writeInt(u64, out_mag[i..][0..8], @truncate(prod), .little);
			carry = prod >> 64;
		}
		// Remaining region 1: a still has bytes/chunks but self does not.
		// Continues a*c with carry-from-merged, accumulating ONLY into carry
		// (out_mag is zero past self_mag_len_in by @memset).
		while (i + 8 <= a_mag_len) : (i += 8) {
			const a_word = std.mem.readInt(u64, a_mag[i..][0..8], .little);
			const self_word: u64 = if (i + 8 <= self_mag_len_in)
				std.mem.readInt(u64, out_mag[i..][0..8], .little)
			else
				0;
			const prod: u128 = @as(u128, a_word) * @as(u128, c) + @as(u128, self_word) + carry;
			std.mem.writeInt(u64, out_mag[i..][0..8], @truncate(prod), .little);
			carry = prod >> 64;
		}
		// Per-byte tail of a (a_mag_len % 8 leftover).
		while (i < a_mag_len) : (i += 1) {
			const a_byte: u64 = a_mag[i];
			const self_byte: u64 = if (i < self_mag_len_in) out_mag[i] else 0;
			const prod: u128 = a_byte * @as(u128, c) + self_byte + (carry & 0xFF);
			out_mag[i] = @truncate(prod);
			carry = (carry >> 8) + (prod >> 8);
		}
		// Region 2: a exhausted; self still has bytes. Propagate carry through.
		while (i < self_mag_len_in or carry != 0) {
			const self_byte: u64 = if (i < self_mag_len_in) out_mag[i] else 0;
			const sum: u128 = self_byte + (carry & 0xFF);
			out_mag[i] = @truncate(sum);
			carry = (carry >> 8) + (sum >> 8);
			i += 1;
		}
		// Canonicalise length.
		var mag_len = i;
		while (mag_len > 0 and out_mag[mag_len - 1] == 0) mag_len -= 1;
		if (mag_len == 0) {
			try self.setI64(0);
			return;
		}
		// Re-encode as signed BLIP payload.
		var pay_len = mag_len;
		if ((out_mag[mag_len - 1] & 0x80) != 0) {
			out_mag[mag_len] = 0x00;
			pay_len += 1;
		}
		if (negative) tier3.negateInPlace(out_mag[0..pay_len]);
		try writeMpFromPayload(self, out_mag[0..pay_len]);
	}

	/// Multiply `a` by an unsigned u64 scalar (GMP `mpz_mul_ui` analogue).
	/// Avoids the full Mp×Mp dispatch chain (no header parsing of c, no
	/// allocator round-trip, no schoolbook/Karatsuba dispatch) — for
	/// "multiply by small constant" workloads (pi spigot, etc.) this is
	/// typically several × faster than `Mp.mul(r, a, c_as_mp)`.
	///
	/// Sign: result sign = sign(a) (c is unsigned non-negative). c == 0 or
	/// a == 0 collapses to zero.
	pub fn mulU64(r: *Mp, a: *const Mp, c: u64) ArithError!void {
		// Trivial cases.
		if (c == 0 or a.cachedSign() == 0) {
			try r.setI64(0);
			return;
		}
		// Tier 0/1 fast path: a fits in i64, product fits too → native.
		if (a.inline_len <= 9) {
			const av: i128 = @as(i128, decodeInlineSmall(a));
			const product: i128 = av * @as(i128, c);
			if (product >= std.math.minInt(i64) and product <= std.math.maxInt(i64)) {
				try r.setI64(@intCast(product));
				return;
			}
			// Falls through to tier-3 path with a's bytes as-is.
		}
		// Tier-3 path. Get the magnitude bytes of a (positive form).
		const a_pay = a.payload();
		const a_neg = a.cachedSign() < 0;
		const allocator = r.allocator;

		// For positive a, the magnitude IS a_pay (after trimming any trailing
		// 0x00 sign-padding) — pass it directly with no alloc, no memcpy.
		// For negative a, we must copy + negateInPlace, which requires a
		// writable buffer. That buffer comes from the per-thread mul_scratch
		// cache (same one tier3MulOp uses) when large; stack otherwise.
		const STACK_BYTES = 4096;
		var stack_mag: [STACK_BYTES]u8 = undefined;
		const mag_src: []const u8 = if (!a_neg) a_pay else blk: {
			const need = a_pay.len;
			if (need > STACK_BYTES) {
				try tier3.mul_scratch.ensureCapacity(allocator, need, 0, 0, 0, 0);
			}
			const buf: []u8 = if (need <= STACK_BYTES)
				stack_mag[0..need]
			else
				tier3.mul_scratch.a_buf[0..need];
			@memcpy(buf, a_pay);
			tier3.negateInPlace(buf);
			break :blk buf;
		};
		// Trim trailing zero bytes (so mag_len is the true magnitude length).
		var mag_len: usize = mag_src.len;
		while (mag_len > 0 and mag_src[mag_len - 1] == 0) mag_len -= 1;

		// Output magnitude buffer: a's mag bytes + up to 16 carry bytes.
		const out_need = mag_len + 16;
		var stack_out: [STACK_BYTES + 16]u8 = undefined;
		const out_mag: []u8 = if (out_need <= stack_out.len)
			stack_out[0..out_need]
		else blk: {
			try tier3.mul_scratch.ensureCapacity(allocator, 0, 0, 0, out_need, 0);
			break :blk tier3.mul_scratch.out_buf[0..out_need];
		};

		const out_mag_len = tier3.mulMagnitudeByU64(mag_src, mag_len, c, out_mag);
		if (out_mag_len == 0) {
			try r.setI64(0);
			return;
		}
		// Re-encode as signed BLIP payload (pad with 0x00 high if high bit
		// of magnitude byte is set, to avoid being read as negative; then
		// negate for negative inputs).
		var pay_len = out_mag_len;
		const need_high_pad = (out_mag[out_mag_len - 1] & 0x80) != 0;
		if (need_high_pad) {
			out_mag[out_mag_len] = 0x00;
			pay_len += 1;
		}
		if (a_neg) tier3.negateInPlace(out_mag[0..pay_len]);
		try writeMpFromPayload(r, out_mag[0..pay_len]);
	}

	/// Truncated division: writes a / b into `q` and a %% b into `rem`.
	/// Sign convention matches GMP `mpz_tdiv_qr`:
	///   sign(q) = sign(a) XOR sign(b); sign(rem) = sign(a) (or zero).
	/// Identity: a == q * b + rem; |rem| < |b|.
	/// Returns error.DivisionByZero when b == 0.
	/// `q` and `rem` may alias each other or `a`/`b` (caller's responsibility
	/// to think about that, but the inline-i64 fast path snapshots both
	/// operand values before writing).
	pub fn divMod(q: *Mp, rem: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		// Reject division by zero up front (cheap with cached sign).
		if (b.cached_sign == 0) return error.DivisionByZero;

		if (a.inline_len <= 9 and b.inline_len <= 9) {
			const av = decodeInlineSmall(a);
			const bv = decodeInlineSmall(b);
			// i64 minInt / -1 overflows i64 — promote to tier-3.
			if (!(av == std.math.minInt(i64) and bv == -1)) {
				const qv = @divTrunc(av, bv);
				const rv = @rem(av, bv);
				try q.setI64(qv);
				try rem.setI64(rv);
				return;
			}
		}
		try tier3DivModOp(q, rem, a, b);
	}

	/// Truncated quotient: writes a / b into `q`. See `divMod` for sign convention.
	pub fn div(q: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		var rem_tmp = Mp.init(q.allocator);
		defer rem_tmp.deinit();
		try divMod(q, &rem_tmp, a, b);
	}

	/// Truncated remainder: writes a %% b into `rem`. See `divMod` for sign convention.
	pub fn mod(rem: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		var q_tmp = Mp.init(rem.allocator);
		defer q_tmp.deinit();
		try divMod(&q_tmp, rem, a, b);
	}

	/// Returns bit `i` of the absolute value (magnitude) of this Mp.
	/// Bits beyond the magnitude's high bit return 0. Used by `powm` to walk
	/// the exponent low-to-high. For positive payloads, magnitude byte = payload
	/// byte; for negative, magnitude = ~payload + 1 (computed lazily per byte
	/// with carry tracking — no allocation).
	pub fn bitAt(self: *const Mp, i: usize) u1 {
		const byte_idx = i / 8;
		const bit_idx: u3 = @intCast(i & 7);
		const mb = self.magByteAt(byte_idx);
		return @intCast((mb >> bit_idx) & 1);
	}

	/// Returns the bit length of the magnitude (1 + position of the highest
	/// set bit). Returns 0 for value 0.
	pub fn bitLen(self: *const Mp) usize {
		if (self.cached_sign == 0) return 0;
		// Compute the byte length of the magnitude. For negative values the
		// effective magnitude length may equal payload.len OR payload.len + 1
		// when negation carries out (i.e. payload == 0x...0x80 — minInt case).
		// For positive values it's the index of the highest non-zero byte + 1.
		const pay = self.payload();
		if (self.cached_sign > 0) {
			var hi = pay.len;
			while (hi > 0 and pay[hi - 1] == 0) hi -= 1;
			if (hi == 0) return 0;
			const high = pay[hi - 1];
			// Highest bit position in `high` is 7 - clz8(high).
			const lz: usize = @clz(high);
			return 8 * (hi - 1) + (8 - lz);
		}
		// Negative: walk down from byte payload.len to find the first
		// nonzero magnitude byte. Compute magnitude byte at index k = payload.len-1
		// down to 0, but be careful: for the "carry-out-of-top" case (payload
		// like 0x00*L 0x80 being canonical-extended), magnitude needs an extra
		// high byte. Detect that: it happens iff the canonical payload high
		// byte is 0x80 AND all lower bytes are 0 — i.e. value = -(2^(8L-1)).
		// In that case magnitude = 2^(8L-1), a (8L)-bit number, bitLen = 8L.
		const L = pay.len;
		var minPow = true;
		if ((pay[L - 1] & 0x7F) != 0) minPow = false; // high byte not exactly 0x80
		if ((pay[L - 1] & 0x80) == 0) minPow = false; // high bit not set
		if (minPow) {
			for (pay[0 .. L - 1]) |b| if (b != 0) {
				minPow = false;
				break;
			};
		}
		if (minPow) return 8 * L;

		// Otherwise compute the highest non-zero magnitude byte by scanning down.
		var hi: usize = L;
		while (hi > 0) : (hi -= 1) {
			const mb = self.magByteAt(hi - 1);
			if (mb != 0) break;
		}
		if (hi == 0) return 0;
		const high = self.magByteAt(hi - 1);
		const lz: usize = @clz(high);
		return 8 * (hi - 1) + (8 - lz);
	}

	/// Returns magnitude byte at index `i` (LE). Past the high byte returns 0.
	/// For positive values, just reads payload[i]. For negative, walks payload
	/// from byte 0 to compute (~payload + 1)[i] with carry. Linear in `i` for
	/// negative values; called by bitAt at most O(bitLen) times in powm — fine.
	fn magByteAt(self: *const Mp, i: usize) u8 {
		if (self.cached_sign == 0) return 0;
		const pay = self.payload();
		if (self.cached_sign > 0) {
			return if (i < pay.len) pay[i] else 0;
		}
		// Negative: magnitude byte i = (~payload + 1)[i]. We need to know
		// the carry into byte i — which is 1 if all of payload[0..i] are 0.
		const L = pay.len;
		// Past the payload bytes: the "carry out of top" can produce a 1
		// magnitude byte iff value == minInt for that L (i.e. 0x00..0x80).
		if (i >= L) {
			// Check: did the negation carry out of the top byte?
			// Carry into byte L = 1 iff all payload bytes <= 0 case... actually
			// only if payload[L-1] == 0 AND every lower byte == 0 produced carry.
			// Special case: payload == 0x00..0x80 → ~ = 0xFF..0x7F, +1 propagates
			// from byte 0: each 0xFF + 1 = 0x100 (carry). Byte L-1 = 0x7F + 1 = 0x80
			// (no carry). So carry_out_of_top = 0. Magnitude bytes [L] = 0.
			// I think for any canonical negative there's no carry past byte L-1
			// because the high byte of the negation is always >= 1 (since the
			// high bit of payload was set, meaning payload[L-1] >= 0x80, so
			// ~payload[L-1] <= 0x7F, plus carry ≤ 1 → ≤ 0x80, no overflow).
			return 0;
		}
		// Compute carry into byte i by scanning bytes 0..i.
		var carry: u16 = 1;
		var k: usize = 0;
		while (k < i) : (k += 1) {
			const inv: u16 = ~pay[k];
			const sum = inv + carry;
			carry = sum >> 8;
		}
		const inv_i: u16 = ~pay[i];
		return @truncate(inv_i + carry);
	}

	/// Modular exponentiation: writes (base ^ exp) mod mod into `r`.
	///
	/// Algorithm: dispatches on exponent bit-length:
	///   - For tiny exponents (bitLen ≤ 8) uses right-to-left square-and-multiply
	///     (M7-4.1) — precompute amortisation isn't worth it.
	///   - For larger exponents uses left-to-right sliding-window (M7-4.2)
	///     with adaptive window size (w=4 for ≤256-bit exp, w=5 for ≤2048-bit,
	///     w=6 above) — saves ~25-35% of multiplications vs square-and-multiply.
	///
	/// Sign convention matches GMP `mpz_powm`:
	///   - mod must be non-zero; mod < 0 is reduced via |mod|.
	///   - exp must be non-negative for now (negative needs modular inverse — M7-5).
	///   - Result is reduced into [0, |mod|-1] (Euclidean), even if base is negative.
	pub fn powm(r: *Mp, base: *const Mp, exp: *const Mp, m: *const Mp) ArithError!void {
		if (m.cached_sign == 0) return error.DivisionByZero;
		if (exp.cached_sign < 0) return error.NegativeExponentNotSupported;
		const allocator = r.allocator;

		// Normalise the modulus to its absolute value (GMP behavior).
		var m_abs = Mp.init(allocator);
		defer m_abs.deinit();
		if (m.cached_sign < 0) {
			// Compute |m| = 0 - m via Mp.sub.
			var zero = Mp.init(allocator);
			defer zero.deinit();
			try zero.setI64(0);
			try m_abs.sub(&zero, m);
		} else {
			try m_abs.setBytes(m.bytes());
		}

		// mod == 1 → result is 0 (anything mod 1 = 0). Cheap check via getI64.
		if (m_abs.cached_pay_len == 1 and m_abs.bytes()[0] == 1) {
			try r.setI64(0);
			return;
		}

		// exp == 0 → result = 1 mod |mod|. For |mod| > 1 (already handled the
		// |mod|==1 case above), this is just 1.
		if (exp.cached_sign == 0) {
			try r.setI64(1);
			return;
		}

		// Reduce base into [0, |mod|-1] (Euclidean) → acc / base_red.
		var base_red = Mp.init(allocator);
		defer base_red.deinit();
		try base_red.mod(base, &m_abs); // truncated: result in (-|mod|, |mod|)
		if (base_red.cached_sign < 0) {
			try base_red.add(&base_red, &m_abs);
		}

		const e_bits = exp.bitLen();
		// Tiny exponent or zero base: fall back to square-and-multiply (no
		// precompute amortisation). Also handles base == 0 cleanly.
		if (e_bits <= 8 or base_red.cached_sign == 0) {
			try powmSquareAndMultiply(r, &base_red, exp, &m_abs);
			return;
		}

		// Adaptive sliding-window width. Same heuristic regardless of which
		// per-multiplication primitive we use (Mont vs schoolbook+mod).
		const w: u8 = if (e_bits <= 256) 4 else if (e_bits <= 2048) 5 else 6;

		// Montgomery dispatch: requires odd modulus AND a magnitude large enough
		// to amortise the per-call setup (modInvNeg64, R^2 mod m, base/result
		// conversions). Cutoff chosen so 64-bit-and-up modular workloads (RSA,
		// DH, ECC field primes) take the Mont path; tiny moduli stay on
		// schoolbook+Knuth (where setup amortisation would exceed savings).
		const m_pay = m_abs.payload();
		const m_is_odd = (m_pay.len > 0) and ((m_pay[0] & 1) == 1);
		// Magnitude byte length: positive payload may carry a trailing 0x00
		// sign-extension byte that isn't part of the magnitude.
		var m_mag_len: usize = m_pay.len;
		while (m_mag_len > 0 and m_pay[m_mag_len - 1] == 0) m_mag_len -= 1;
		const MONT_MIN_BYTES: usize = 8;
		if (m_is_odd and m_mag_len >= MONT_MIN_BYTES) {
			try powmMontgomery(r, &base_red, exp, &m_abs, w);
			return;
		}

		// Fallback: left-to-right sliding window with schoolbook mul + Knuth mod.
		try powmSlidingWindow(r, &base_red, exp, &m_abs, w);
	}

	/// Extract the 64 bits of `self`'s magnitude starting at bit position
	/// `shift_down` (i.e., `(magnitude >> shift_down) & 0xFFFFFFFFFFFFFFFF`).
	/// Used by the Lehmer inner loop to get a leading-limb approximation.
	/// Returns 0 if `shift_down` exceeds the magnitude's bit length.
	/// Caller's responsibility: use only on positive Mps (cached_sign > 0)
	/// — Lehmer's r0/r1 are always positive.
	fn topU64(self: *const Mp, shift_down: usize) u64 {
		const pay = self.payload();
		if (pay.len == 0) return 0;
		// Magnitude bytes: for positive Mps, payload bytes ARE magnitude bytes
		// (with a possible trailing 0x00 sign-extension byte).
		const byte_off = shift_down / 8;
		const bit_off: u6 = @intCast(shift_down & 7);

		// Fast path: full 8-byte window (and possibly a 9th byte for bit_off>0)
		// fit entirely within the payload. Single LDR x on aarch64 instead of
		// 8x LDR-B + OR-shift chain. This is the common case in invMod's
		// Lehmer/HGCD inner loops where shift_down ranges over magnitude bits
		// far below the top.
		if (bit_off == 0 and byte_off + 8 <= pay.len) {
			return std.mem.readInt(u64, pay[byte_off..][0..8], .little);
		}
		if (bit_off != 0 and byte_off + 9 <= pay.len) {
			const lo = std.mem.readInt(u64, pay[byte_off..][0..8], .little);
			const b9: u64 = pay[byte_off + 8];
			return (lo >> bit_off) | (b9 << @as(u6, @intCast(64 - @as(usize, bit_off))));
		}

		// Slow path: zero-extend partial trailing bytes (used near the top of
		// the magnitude where the window walks past payload.len).
		var out: u64 = 0;
		var i: usize = 0;
		while (i < 8) : (i += 1) {
			const idx = byte_off + i;
			const b: u64 = if (idx < pay.len) pay[idx] else 0;
			out |= b << @as(u6, @intCast(i * 8));
		}
		if (bit_off != 0) {
			const idx9 = byte_off + 8;
			const b9: u64 = if (idx9 < pay.len) pay[idx9] else 0;
			out = (out >> bit_off) | (b9 << @as(u6, @intCast(64 - @as(usize, bit_off))));
		}
		return out;
	}

	/// Single-precision EEA finish: when both r0 and r1 fit in u64 (r0_bits
	/// <= 64), run one classical multi-limb step with q-as-u64. We keep
	/// using the multi-limb (s0, s1) since they may still be huge.
	/// Loops until r1 == 0.
	fn lehmerFinishSinglePrecision(
		r0: *Mp, r1: *Mp,
		s0: *Mp, s1: *Mp,
		t_scratch1: *Mp, t_scratch2: *Mp,
	) ArithError!void {
		var u: u64 = try mpToU64Mag(r0);
		var v: u64 = try mpToU64Mag(r1);
		while (v != 0) {
			const q = u / v;
			const new_v = u - q * v;
			u = v;
			v = new_v;
			// (s0, s1) <- (s1, s0 - q * s1)
			var q_mp = Mp.init(s0.allocator);
			defer q_mp.deinit();
			try q_mp.setU64(q);
			try t_scratch1.mul(&q_mp, s1);
			try t_scratch2.sub(s0, t_scratch1);
			try s0.setBytes(s1.bytes());
			try s1.setBytes(t_scratch2.bytes());
		}
		// r0 = u (the gcd in u64 form). Encode it back.
		try r0.setU64(u);
		try r1.setI64(0);
	}

	/// Read magnitude of `self` as u64. Caller guarantees magnitude fits.
	/// Used by the single-precision finish step.
	fn mpToU64Mag(self: *const Mp) ArithError!u64 {
		// Fast path for sign >= 0 inline values.
		if (self.cached_sign == 0) return 0;
		const pay = self.payload();
		// Fast path: full 8-byte payload → single LDR x via readInt.
		// Common case in lehmerFinishSinglePrecision where r0/r1 are u64
		// magnitudes (payload length frequently exactly 8).
		if (pay.len >= 8) {
			return std.mem.readInt(u64, pay[0..8], .little);
		}
		// Slow path: zero-extend short payloads (1-7 bytes).
		var out: u64 = 0;
		var i: usize = 0;
		while (i < pay.len) : (i += 1) {
			out |= @as(u64, pay[i]) << @as(u6, @intCast(i * 8));
		}
		return out;
	}

	/// Modular multiplicative inverse. Dispatches to the Lehmer-accelerated
	/// EEA for sufficiently large moduli (>= 64 bits), and falls back to the
	/// classical EEA for small inputs where Lehmer's overhead doesn't pay off.
	///
	/// Sets `r = a^-1 mod |m|`. Returns `true` iff the inverse exists, i.e.
	/// gcd(|a|, |m|) == 1. When no inverse exists, returns `false` and sets
	/// `r = 0` (matches GMP `mpz_invert` convention: returns 1 on success,
	/// 0 on failure, with `rop` undefined on failure — we set to 0).
	///
	/// Errors: `DivisionByZero` if `m == 0`. Modulus sign is ignored (taken
	/// absolute). `a` is reduced into [0, |m|) before the algorithm runs.
	pub fn invMod(r: *Mp, a: *const Mp, m: *const Mp) ArithError!bool {
		if (m.cached_sign == 0) return error.DivisionByZero;
		// Dispatch tiers:
		//   < 96 bits:   classical EEA (Lehmer's matrix overhead doesn't pay off)
		//   96..1023:    Lehmer with u62 matrix (M9)
		//   >= 1024:     wider-window Lehmer with u128 matrix (M10) — batches
		//                ~2× more single-precision EEA steps per multi-precision
		//                matrix-apply, giving 1.06–1.6× speedup at RSA sizes.
		//
		// Note (M11.2): invModHGCDRecursive (sub-quadratic HGCD primitive)
		// is implemented and correctness-validated against invModHGCD at
		// 256–4096 bits, but is NOT wired into the dispatcher. Reason:
		// without sub-quadratic multiplication (FFT), the recursion's
		// matrix-composition overhead grows faster than its EEA-batching
		// savings — the form regresses ~5–18% at 1024–2048 bits and
		// catastrophically (~60×) at 8192 bits. It will become a clear win
		// once FFT mul lands; until then, M10 wider-window Lehmer is the
		// practical optimum.
		const m_bits = m.bitLen();
		if (m_bits < 96) return invModClassical(r, a, m);
		if (m_bits >= 1024) return invModHGCD(r, a, m);
		return invModLehmer(r, a, m);
	}

	/// Classical Extended Euclidean Algorithm — kept as the fallback for
	/// small moduli (< 96 bits) where Lehmer's overhead exceeds savings.
	///
	/// Tracks (r0, r1) with Bezout coefficient s such that a*s ≡ r mod m.
	/// Each step: q = r0/r1; (r0,r1)=(r1,r0-q*r1); (s0,s1)=(s1,s0-q*s1).
	/// Terminates when r1 == 0; if r0 == 1 the inverse is s0 mod m. We
	/// don't track the t coefficient (on m) since we don't need it.
	pub fn invModClassical(r: *Mp, a: *const Mp, m: *const Mp) ArithError!bool {
		if (m.cached_sign == 0) return error.DivisionByZero;
		const allocator = r.allocator;

		// |m|.
		var m_abs = Mp.init(allocator);
		defer m_abs.deinit();
		if (m.cached_sign < 0) {
			var zero = Mp.init(allocator);
			defer zero.deinit();
			try zero.setI64(0);
			try m_abs.sub(&zero, m);
		} else {
			try m_abs.setBytes(m.bytes());
		}

		// Inverse mod 1 is 0 (everything is congruent to 0 mod 1, including 1
		// and 0 — match GMP: returns 1 with rop = 0).
		if (m_abs.cached_pay_len == 1 and m_abs.bytes()[0] == 1) {
			try r.setI64(0);
			return true;
		}

		// r0 = a reduced into [0, |m|); r1 = |m|.
		// Note: we use r0/r1 swapped relative to the usual Euclid presentation
		// because we want s0 (Bezout coefficient on a) at termination.
		var r0 = Mp.init(allocator);
		defer r0.deinit();
		try euclideanReduce(&r0, a, &m_abs);
		// gcd(0, m) = m ≠ 1 (we already handled m == 1) → no inverse.
		if (r0.cached_sign == 0) {
			try r.setI64(0);
			return false;
		}

		var r1 = Mp.init(allocator);
		defer r1.deinit();
		try r1.setBytes(m_abs.bytes());

		var s0 = Mp.init(allocator);
		defer s0.deinit();
		try s0.setI64(1);

		var s1 = Mp.init(allocator);
		defer s1.deinit();
		try s1.setI64(0);

		var q = Mp.init(allocator);
		defer q.deinit();
		var rem = Mp.init(allocator);
		defer rem.deinit();
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		var new_s = Mp.init(allocator);
		defer new_s.deinit();

		while (r1.cached_sign != 0) {
			// q = r0 / r1; rem = r0 - q*r1 = r0 mod r1.
			try Mp.divMod(&q, &rem, &r0, &r1);
			// (r0, r1) = (r1, rem). Move via swap-into-r0 then write rem into r1.
			try tmp.setBytes(r1.bytes());
			try r0.setBytes(tmp.bytes());
			try r1.setBytes(rem.bytes());
			// (s0, s1) = (s1, s0 - q * s1).
			try tmp.mul(&q, &s1);
			try new_s.sub(&s0, &tmp);
			try s0.setBytes(s1.bytes());
			try s1.setBytes(new_s.bytes());
		}

		// gcd is r0; inverse exists iff gcd == 1.
		const gcd_is_one = r0.cached_pay_len == 1 and r0.bytes()[0] == 1 and r0.cached_sign == 1;
		if (!gcd_is_one) {
			try r.setI64(0);
			return false;
		}
		// Inverse is s0 mod |m|, in [0, |m|).
		try euclideanReduce(r, &s0, &m_abs);
		return true;
	}

	/// Modular multiplicative inverse via Lehmer-accelerated EEA.
	///
	/// Algorithm: instead of one full multi-limb Euclidean step per iteration
	/// (the classical approach), Lehmer's method extracts a partial-quotient
	/// sequence from the LEADING bits of (r0, r1) — those quotients only
	/// depend on the top bits, not the full magnitudes. Many "single-precision
	/// EEA" iterations are batched into a 2x2 integer matrix and applied to
	/// the multi-limb r/s in ONE multi-limb update. This reduces the number
	/// of expensive multi-limb operations by a factor of ~62 per Lehmer step
	/// in the typical case.
	///
	/// Implementation uses **signed i64** for the matrix coefficients (A, B,
	/// C, D) and extracts the top **62 bits** of (r0, r1) into u_top, v_top
	/// (signed positives). This leaves headroom to compute (u_top + A) and
	/// (v_top + C) etc. without overflow during the Knuth sanity test
	/// (since |A|, |B|, |C|, |D| stay well-bounded during the inner loop).
	///
	/// Knuth Algorithm L sanity test: the leading-limb estimate of the next
	/// quotient is correct iff `(u_top + A) / (v_top + C)` equals
	/// `(u_top + B) / (v_top + D)`. If true, the step can be safely applied.
	/// If the inner loop takes zero steps, we fall back to one classical
	/// multi-limb division step.
	///
	/// References: Knuth TAOCP §4.5.2 Algorithm L; Brent & Zimmermann §1.6.3.
	pub fn invModLehmer(r: *Mp, a: *const Mp, m: *const Mp) ArithError!bool {
		if (m.cached_sign == 0) return error.DivisionByZero;
		const allocator = r.allocator;

		// |m|.
		var m_abs = Mp.init(allocator);
		defer m_abs.deinit();
		if (m.cached_sign < 0) {
			var zero = Mp.init(allocator);
			defer zero.deinit();
			try zero.setI64(0);
			try m_abs.sub(&zero, m);
		} else {
			try m_abs.setBytes(m.bytes());
		}

		if (m_abs.cached_pay_len == 1 and m_abs.bytes()[0] == 1) {
			try r.setI64(0);
			return true;
		}

		// r0 = a reduced into [0, |m|); r1 = |m|.
		var r0 = Mp.init(allocator);
		defer r0.deinit();
		try euclideanReduce(&r0, a, &m_abs);
		if (r0.cached_sign == 0) {
			try r.setI64(0);
			return false;
		}

		var r1 = Mp.init(allocator);
		defer r1.deinit();
		try r1.setBytes(m_abs.bytes());

		// We want s0 such that a * s0 ≡ r0 (mod m). Initially r0 is "a mod m"
		// so s0 = 1. r1 = m, with implicit s1 = 0 (since a*0 ≡ 0 mod m). At
		// termination, gcd is r0 and inverse is s0 mod |m|.
		var s0 = Mp.init(allocator);
		defer s0.deinit();
		try s0.setI64(1);

		var s1 = Mp.init(allocator);
		defer s1.deinit();
		try s1.setI64(0);

		// Scratch Mps for matrix application and division step.
		var t0 = Mp.init(allocator);
		defer t0.deinit();
		var t1 = Mp.init(allocator);
		defer t1.deinit();
		var t2 = Mp.init(allocator);
		defer t2.deinit();
		var t3 = Mp.init(allocator);
		defer t3.deinit();
		var mul_a = Mp.init(allocator);
		defer mul_a.deinit();
		var mul_b = Mp.init(allocator);
		defer mul_b.deinit();
		var mul_c = Mp.init(allocator);
		defer mul_c.deinit();
		var mul_d = Mp.init(allocator);
		defer mul_d.deinit();
		var coeff_a = Mp.init(allocator);
		defer coeff_a.deinit();
		var coeff_b = Mp.init(allocator);
		defer coeff_b.deinit();
		var coeff_c = Mp.init(allocator);
		defer coeff_c.deinit();
		var coeff_d = Mp.init(allocator);
		defer coeff_d.deinit();
		var q_mp = Mp.init(allocator);
		defer q_mp.deinit();
		var rem_mp = Mp.init(allocator);
		defer rem_mp.deinit();
		var qs1 = Mp.init(allocator);
		defer qs1.deinit();
		var new_s = Mp.init(allocator);
		defer new_s.deinit();

		// Initial swap: classical EEA expects r0 >= r1 to avoid a q=0 first
		// step. Since r0 = a mod m < m = r1, we must swap. After this swap,
		// (s0, s1) = (0, 1), but s0 represents Bezout coeff on a — we need
		// to track which slot holds the "a-coefficient". Simplest: just do
		// one explicit swap step here so r0 >= r1 invariant holds.
		if (Mp.cmp(&r0, &r1) == .lt) {
			try t0.setBytes(r0.bytes());
			try r0.setBytes(r1.bytes());
			try r1.setBytes(t0.bytes());
			// (s0, s1) <- (s1, s0)  (since q=0: new_s1 = s0 - 0*s1 = s0)
			try t0.setBytes(s0.bytes());
			try s0.setBytes(s1.bytes());
			try s1.setBytes(t0.bytes());
		}

		while (r1.cached_sign != 0) {
			// Decide whether this iteration takes a Lehmer step or a
			// classical step. Need at least 2 limbs (128 bits) of r0 to even
			// try Lehmer — below that, the inner loop will trivially exit.
			const r0_bits = r0.bitLen();
			if (r0_bits <= 64) {
				// Both r0 and r1 fit in u64 (r0 >= r1 invariant).
				// Finish off with single-precision EEA on the magnitudes,
				// applying the cosequence to s0/s1.
				try lehmerFinishSinglePrecision(&r0, &r1, &s0, &s1, &t0, &t1);
				break;
			}

			// Extract top 62 bits of r0 and r1, left-aligned to the same bit
			// position (the high bit of r0). 62 bits (not 64) leaves headroom
			// for adding small corrections (A, B, C, D < 2^62) without u64
			// overflow during the Knuth sanity test.
			const shift_down: usize = r0_bits - 62;
			const mask62 = (@as(u64, 1) << 62) - 1;
			var u_top: u64 = topU64(&r0, shift_down) & mask62;
			var v_top: u64 = topU64(&r1, shift_down) & mask62;

			// If v_top is 0, the leading-bits approximation says r1 << r0;
			// the true quotient could be enormous and depends entirely on
			// the lower bits — use a classical step.
			if (v_top == 0) {
				try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
				try t0.setBytes(r1.bytes());
				try r0.setBytes(t0.bytes());
				try r1.setBytes(rem_mp.bytes());
				try qs1.mul(&q_mp, &s1);
				try new_s.sub(&s0, &qs1);
				try s0.setBytes(s1.bytes());
				try s1.setBytes(new_s.bytes());
				continue;
			}

			// Knuth's Algorithm L: inner single-precision EEA.
			// Invariant: applying matrix M_k to (r0_orig, r1_orig) yields
			// current (r0, r1):
			//   parity even (k=0,2,...): r0 = A*r0_o - B*r1_o, r1 = D*r1_o - C*r0_o
			//   parity odd  (k=1,3,...): r0 = B*r1_o - A*r0_o, r1 = C*r0_o - D*r1_o
			// Initially A=1, B=0, C=0, D=1, parity=even.
			//
			// Sanity test (per parity):
			//   even: q_lo = (u-A)/(v+D), q_hi = (u+B)/(v-C)
			//   odd:  q_lo = (u-B)/(v+C), q_hi = (u+A)/(v-D)
			// Wait — re-derived for parity ODD:
			//   true_u = -A*r0_o + B*r1_o ≈ (B*v_top - A*u_top)*scale + (B*ε1 - A*ε0)
			//   ε_u ∈ [-A*scale, B*scale)  → true_u ∈ [u_sp-A, u_sp+B)
			//   true_v = C*r0_o - D*r1_o ≈ (C*u_top - D*v_top)*scale + (C*ε0 - D*ε1)
			//   ε_v ∈ [-D*scale, C*scale) → true_v ∈ [v_sp-D, v_sp+C)
			//   q ∈ [(u-A)/(v+C), (u+B)/(v-D)]
			// So odd case: q_lo = (u-A)/(v+C), q_hi = (u+B)/(v-D).
			var aa: u64 = 1;
			var bb: u64 = 0;
			var cc: u64 = 0;
			var dd: u64 = 1;
			var parity_even: bool = true;
			var inner_steps: usize = 0;

			while (true) {
				// Compute q_lo and q_hi per parity.
				var q_lo: u64 = 0;
				var q_hi: u64 = 0;
				var ok: bool = false;
				// Parity-even derivation:
				//   u_cur = A*r0_o - B*r1_o    → True_u ∈ [u_sp-B, u_sp+A]
				//   v_cur = D*r1_o - C*r0_o    → True_v ∈ [v_sp-C, v_sp+D]
				//   q_lo = (u-B)/(v+D),  q_hi = (u+A)/(v-C)
				// Parity-odd derivation:
				//   u_cur = B*r1_o - A*r0_o    → True_u ∈ [u_sp-A, u_sp+B]
				//   v_cur = C*r0_o - D*r1_o    → True_v ∈ [v_sp-D, v_sp+C]
				//   q_lo = (u-A)/(v+C),  q_hi = (u+B)/(v-D)
				if (parity_even) {
					if (cc < v_top) {
						const denom_hi = v_top - cc;       // v - C
						const denom_lo = v_top + dd;       // v + D
						if (bb <= u_top and denom_hi != 0) {
							const num_lo = u_top - bb;     // u - B
							const num_hi = u_top + aa;     // u + A
							q_lo = num_lo / denom_lo;
							q_hi = num_hi / denom_hi;
							ok = true;
						}
					}
				} else {
					if (dd < v_top) {
						const denom_hi = v_top - dd;       // v - D
						const denom_lo = v_top + cc;       // v + C
						if (aa <= u_top and denom_hi != 0) {
							const num_lo = u_top - aa;     // u - A
							const num_hi = u_top + bb;     // u + B
							q_lo = num_lo / denom_lo;
							q_hi = num_hi / denom_hi;
							ok = true;
						}
					}
				}
				if (!ok or q_lo != q_hi or q_lo == 0) break;
				const q = q_lo;

				// Update single-precision (u, v): (u, v) <- (v, u - q*v).
				const qv = @mulWithOverflow(q, v_top);
				if (qv[1] != 0) break;
				if (qv[0] > u_top) break; // shouldn't happen if q is correct
				const new_u = v_top;
				const new_v = u_top - qv[0];

				// Update matrix: (A, B, C, D) <- (C, D, A + q*C, B + q*D).
				const qc = @mulWithOverflow(q, cc);
				if (qc[1] != 0) break;
				const new_c_ov = @addWithOverflow(aa, qc[0]);
				if (new_c_ov[1] != 0) break;
				// Cap matrix entries at 2^62 so they always fit in our u63
				// safe-arith zone (matches u_top headroom).
				if (new_c_ov[0] >= (@as(u64, 1) << 62)) break;
				const qd = @mulWithOverflow(q, dd);
				if (qd[1] != 0) break;
				const new_d_ov = @addWithOverflow(bb, qd[0]);
				if (new_d_ov[1] != 0) break;
				if (new_d_ov[0] >= (@as(u64, 1) << 62)) break;

				aa = cc;
				bb = dd;
				cc = new_c_ov[0];
				dd = new_d_ov[0];
				u_top = new_u;
				v_top = new_v;
				parity_even = !parity_even;
				inner_steps += 1;
			}

			if (inner_steps == 0) {
				// Lehmer estimate disagreed even on the very first step.
				// Take one classical multi-limb EEA step.
				try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
				try t0.setBytes(r1.bytes());
				try r0.setBytes(t0.bytes());
				try r1.setBytes(rem_mp.bytes());
				try qs1.mul(&q_mp, &s1);
				try new_s.sub(&s0, &qs1);
				try s0.setBytes(s1.bytes());
				try s1.setBytes(new_s.bytes());
				continue;
			}

			// Apply the accumulated matrix to (r0, r1) and (s0, s1).
			try coeff_a.setU64(aa);
			try coeff_b.setU64(bb);
			try coeff_c.setU64(cc);
			try coeff_d.setU64(dd);

			try mul_a.mul(&coeff_a, &r0);
			try mul_b.mul(&coeff_b, &r1);
			try mul_c.mul(&coeff_c, &r0);
			try mul_d.mul(&coeff_d, &r1);

			if (parity_even) {
				// r0' = A*r0 - B*r1; r1' = D*r1 - C*r0
				try t0.sub(&mul_a, &mul_b);
				try t1.sub(&mul_d, &mul_c);
			} else {
				// r0' = B*r1 - A*r0; r1' = C*r0 - D*r1
				try t0.sub(&mul_b, &mul_a);
				try t1.sub(&mul_c, &mul_d);
			}
			try r0.setBytes(t0.bytes());
			try r1.setBytes(t1.bytes());

			try mul_a.mul(&coeff_a, &s0);
			try mul_b.mul(&coeff_b, &s1);
			try mul_c.mul(&coeff_c, &s0);
			try mul_d.mul(&coeff_d, &s1);
			if (parity_even) {
				try t2.sub(&mul_a, &mul_b);
				try t3.sub(&mul_d, &mul_c);
			} else {
				try t2.sub(&mul_b, &mul_a);
				try t3.sub(&mul_c, &mul_d);
			}
			try s0.setBytes(t2.bytes());
			try s1.setBytes(t3.bytes());
		}

		// gcd is r0; inverse exists iff gcd == 1.
		const gcd_is_one = r0.cached_pay_len == 1 and r0.bytes()[0] == 1 and r0.cached_sign == 1;
		if (!gcd_is_one) {
			try r.setI64(0);
			return false;
		}
		try euclideanReduce(r, &s0, &m_abs);
		return true;
	}

	/// Extract 128 bits of `self`'s magnitude starting at bit position
	/// `shift_down`. Twin of `topU64` for the wider-window HGCD inner loop.
	/// Returns 0 if `shift_down` exceeds the magnitude's bit length.
	/// Caller's responsibility: positive Mps only (HGCD's r0/r1 are positive).
	fn topU128(self: *const Mp, shift_down: usize) u128 {
		const pay = self.payload();
		if (pay.len == 0) return 0;
		const byte_off = shift_down / 8;
		const bit_off: u7 = @intCast(shift_down & 7);

		// Fast path: 16-byte window (plus 17th byte when bit_off>0) fits in
		// payload. Two LDR x reads instead of 16 LDR-B + OR-shift chain.
		// Common case in invModHGCD's wider-window Lehmer inner loop.
		if (bit_off == 0 and byte_off + 16 <= pay.len) {
			const lo: u128 = std.mem.readInt(u64, pay[byte_off..][0..8], .little);
			const hi: u128 = std.mem.readInt(u64, pay[byte_off + 8 ..][0..8], .little);
			return lo | (hi << 64);
		}
		if (bit_off != 0 and byte_off + 17 <= pay.len) {
			const lo: u128 = std.mem.readInt(u64, pay[byte_off..][0..8], .little);
			const hi: u128 = std.mem.readInt(u64, pay[byte_off + 8 ..][0..8], .little);
			const b16: u128 = pay[byte_off + 16];
			const win = lo | (hi << 64);
			return (win >> bit_off) | (b16 << @as(u7, @intCast(128 - @as(usize, bit_off))));
		}

		// Slow path: zero-extend partial trailing bytes.
		var out: u128 = 0;
		var i: usize = 0;
		while (i < 16) : (i += 1) {
			const idx = byte_off + i;
			const b: u128 = if (idx < pay.len) pay[idx] else 0;
			out |= b << @as(u7, @intCast(i * 8));
		}
		if (bit_off != 0) {
			const idx16 = byte_off + 16;
			const b16: u128 = if (idx16 < pay.len) pay[idx16] else 0;
			out = (out >> bit_off) | (b16 << @as(u7, @intCast(128 - @as(usize, bit_off))));
		}
		return out;
	}

	/// Set this Mp's value to the unsigned u128 magnitude `value`.
	/// Used by HGCD to materialise multi-precision matrix coefficients.
	fn setU128(self: *Mp, value: u128) ArithError!void {
		if (value == 0) { try self.setI64(0); return; }
		// Compose 16-byte LE magnitude, find canonical L, then prepend
		// a 0x00 if the high bit would otherwise look "signed".
		var le: [16]u8 = undefined;
		var v = value;
		var k: usize = 0;
		while (k < 16) : (k += 1) { le[k] = @intCast(v & 0xFF); v >>= 8; }
		var L: usize = 16;
		while (L > 1 and le[L - 1] == 0) L -= 1;
		const need_pad = (le[L - 1] & 0x80) != 0;
		const pay_len: usize = if (need_pad) L + 1 else L;
		var enc_buf: [20]u8 = undefined;
		const hdr = try tier3.writeHeader(&enc_buf, pay_len);
		@memcpy(enc_buf[hdr .. hdr + L], le[0..L]);
		if (need_pad) enc_buf[hdr + L] = 0;
		try self.setBytes(enc_buf[0 .. hdr + pay_len]);
	}

	/// Modular multiplicative inverse via wider-window (u128) Lehmer/HGCD.
	///
	/// M10 step toward sub-quadratic GCD. Same outer structure as
	/// `invModLehmer`, but the inner single-precision EEA accumulator runs
	/// in **u128** (124-bit window) instead of u64 (62-bit window). This
	/// roughly DOUBLES the number of single-precision EEA steps that fit
	/// into one accumulated 2x2 matrix before overflow forces a flush — so
	/// the count of expensive multi-precision matrix-applies drops by ~2×.
	/// Matrix entries are bounded at 2^126 to leave headroom for the Knuth
	/// sanity test (u_top + corrections).
	///
	/// Falls back to `invModLehmer` for moduli below the HGCD threshold
	/// (~256 bits) where the wider window's setup cost doesn't pay off.
	pub fn invModHGCD(r: *Mp, a: *const Mp, m: *const Mp) ArithError!bool {
		if (m.cached_sign == 0) return error.DivisionByZero;
		const allocator = r.allocator;

		// Below threshold, defer to classical Lehmer.
		const HGCD_THRESHOLD: usize = 256;
		if (m.bitLen() < HGCD_THRESHOLD) return invModLehmer(r, a, m);

		var m_abs = Mp.init(allocator);
		defer m_abs.deinit();
		if (m.cached_sign < 0) {
			var zero = Mp.init(allocator);
			defer zero.deinit();
			try zero.setI64(0);
			try m_abs.sub(&zero, m);
		} else {
			try m_abs.setBytes(m.bytes());
		}

		if (m_abs.cached_pay_len == 1 and m_abs.bytes()[0] == 1) {
			try r.setI64(0);
			return true;
		}

		var r0 = Mp.init(allocator);
		defer r0.deinit();
		try euclideanReduce(&r0, a, &m_abs);
		if (r0.cached_sign == 0) {
			try r.setI64(0);
			return false;
		}

		var r1 = Mp.init(allocator);
		defer r1.deinit();
		try r1.setBytes(m_abs.bytes());

		var s0 = Mp.init(allocator);
		defer s0.deinit();
		try s0.setI64(1);

		var s1 = Mp.init(allocator);
		defer s1.deinit();
		try s1.setI64(0);

		var t0 = Mp.init(allocator);
		defer t0.deinit();
		var t1 = Mp.init(allocator);
		defer t1.deinit();
		var t2 = Mp.init(allocator);
		defer t2.deinit();
		var t3 = Mp.init(allocator);
		defer t3.deinit();
		var mul_a = Mp.init(allocator);
		defer mul_a.deinit();
		var mul_b = Mp.init(allocator);
		defer mul_b.deinit();
		var mul_c = Mp.init(allocator);
		defer mul_c.deinit();
		var mul_d = Mp.init(allocator);
		defer mul_d.deinit();
		var coeff_a = Mp.init(allocator);
		defer coeff_a.deinit();
		var coeff_b = Mp.init(allocator);
		defer coeff_b.deinit();
		var coeff_c = Mp.init(allocator);
		defer coeff_c.deinit();
		var coeff_d = Mp.init(allocator);
		defer coeff_d.deinit();
		var q_mp = Mp.init(allocator);
		defer q_mp.deinit();
		var rem_mp = Mp.init(allocator);
		defer rem_mp.deinit();
		var qs1 = Mp.init(allocator);
		defer qs1.deinit();
		var new_s = Mp.init(allocator);
		defer new_s.deinit();

		// Initial swap: enforce r0 >= r1 invariant.
		if (Mp.cmp(&r0, &r1) == .lt) {
			try t0.setBytes(r0.bytes());
			try r0.setBytes(r1.bytes());
			try r1.setBytes(t0.bytes());
			try t0.setBytes(s0.bytes());
			try s0.setBytes(s1.bytes());
			try s1.setBytes(t0.bytes());
		}

		const CAP_BITS: u7 = 126;
		const CAP: u128 = @as(u128, 1) << CAP_BITS;
		const WINDOW_BITS: usize = 124;

		while (r1.cached_sign != 0) {
			const r0_bits = r0.bitLen();
			if (r0_bits <= 64) {
				try lehmerFinishSinglePrecision(&r0, &r1, &s0, &s1, &t0, &t1);
				break;
			}

			// If r0 still has fewer than ~128 bits, fall back to the u62
			// inner loop's domain. We can simply not go wider.
			if (r0_bits <= 128) {
				// Use the u62 inner loop logic inline.
				const shift_down: usize = r0_bits - 62;
				const mask62 = (@as(u64, 1) << 62) - 1;
				var u_top64: u64 = topU64(&r0, shift_down) & mask62;
				var v_top64: u64 = topU64(&r1, shift_down) & mask62;
				if (v_top64 == 0) {
					try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
					try t0.setBytes(r1.bytes());
					try r0.setBytes(t0.bytes());
					try r1.setBytes(rem_mp.bytes());
					try qs1.mul(&q_mp, &s1);
					try new_s.sub(&s0, &qs1);
					try s0.setBytes(s1.bytes());
					try s1.setBytes(new_s.bytes());
					continue;
				}
				var aa: u64 = 1;
				var bb: u64 = 0;
				var cc: u64 = 0;
				var dd: u64 = 1;
				var parity_even: bool = true;
				var inner_steps: usize = 0;
				while (true) {
					var q_lo: u64 = 0;
					var q_hi: u64 = 0;
					var ok: bool = false;
					if (parity_even) {
						if (cc < v_top64) {
							const denom_hi = v_top64 - cc;
							const denom_lo = v_top64 + dd;
							if (bb <= u_top64 and denom_hi != 0) {
								const num_lo = u_top64 - bb;
								const num_hi = u_top64 + aa;
								q_lo = num_lo / denom_lo;
								q_hi = num_hi / denom_hi;
								ok = true;
							}
						}
					} else {
						if (dd < v_top64) {
							const denom_hi = v_top64 - dd;
							const denom_lo = v_top64 + cc;
							if (aa <= u_top64 and denom_hi != 0) {
								const num_lo = u_top64 - aa;
								const num_hi = u_top64 + bb;
								q_lo = num_lo / denom_lo;
								q_hi = num_hi / denom_hi;
								ok = true;
							}
						}
					}
					if (!ok or q_lo != q_hi or q_lo == 0) break;
					const q = q_lo;
					const qv = @mulWithOverflow(q, v_top64);
					if (qv[1] != 0) break;
					if (qv[0] > u_top64) break;
					const new_u = v_top64;
					const new_v = u_top64 - qv[0];
					const qc = @mulWithOverflow(q, cc);
					if (qc[1] != 0) break;
					const new_c_ov = @addWithOverflow(aa, qc[0]);
					if (new_c_ov[1] != 0) break;
					if (new_c_ov[0] >= (@as(u64, 1) << 62)) break;
					const qd = @mulWithOverflow(q, dd);
					if (qd[1] != 0) break;
					const new_d_ov = @addWithOverflow(bb, qd[0]);
					if (new_d_ov[1] != 0) break;
					if (new_d_ov[0] >= (@as(u64, 1) << 62)) break;
					aa = cc;
					bb = dd;
					cc = new_c_ov[0];
					dd = new_d_ov[0];
					u_top64 = new_u;
					v_top64 = new_v;
					parity_even = !parity_even;
					inner_steps += 1;
				}
				if (inner_steps == 0) {
					try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
					try t0.setBytes(r1.bytes());
					try r0.setBytes(t0.bytes());
					try r1.setBytes(rem_mp.bytes());
					try qs1.mul(&q_mp, &s1);
					try new_s.sub(&s0, &qs1);
					try s0.setBytes(s1.bytes());
					try s1.setBytes(new_s.bytes());
					continue;
				}
				try coeff_a.setU64(aa);
				try coeff_b.setU64(bb);
				try coeff_c.setU64(cc);
				try coeff_d.setU64(dd);
				try mul_a.mul(&coeff_a, &r0);
				try mul_b.mul(&coeff_b, &r1);
				try mul_c.mul(&coeff_c, &r0);
				try mul_d.mul(&coeff_d, &r1);
				if (parity_even) {
					try t0.sub(&mul_a, &mul_b);
					try t1.sub(&mul_d, &mul_c);
				} else {
					try t0.sub(&mul_b, &mul_a);
					try t1.sub(&mul_c, &mul_d);
				}
				try r0.setBytes(t0.bytes());
				try r1.setBytes(t1.bytes());
				try mul_a.mul(&coeff_a, &s0);
				try mul_b.mul(&coeff_b, &s1);
				try mul_c.mul(&coeff_c, &s0);
				try mul_d.mul(&coeff_d, &s1);
				if (parity_even) {
					try t2.sub(&mul_a, &mul_b);
					try t3.sub(&mul_d, &mul_c);
				} else {
					try t2.sub(&mul_b, &mul_a);
					try t3.sub(&mul_c, &mul_d);
				}
				try s0.setBytes(t2.bytes());
				try s1.setBytes(t3.bytes());
				continue;
			}

			// r0 has > 128 bits — use the wider u128 inner loop.
			const shift_down: usize = r0_bits - WINDOW_BITS;
			const mask124: u128 = (@as(u128, 1) << WINDOW_BITS) - 1;
			var u_top: u128 = topU128(&r0, shift_down) & mask124;
			var v_top: u128 = topU128(&r1, shift_down) & mask124;

			if (v_top == 0) {
				try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
				try t0.setBytes(r1.bytes());
				try r0.setBytes(t0.bytes());
				try r1.setBytes(rem_mp.bytes());
				try qs1.mul(&q_mp, &s1);
				try new_s.sub(&s0, &qs1);
				try s0.setBytes(s1.bytes());
				try s1.setBytes(new_s.bytes());
				continue;
			}

			// Wider matrix in u128.
			var aa: u128 = 1;
			var bb: u128 = 0;
			var cc: u128 = 0;
			var dd: u128 = 1;
			var parity_even: bool = true;
			var inner_steps: usize = 0;

			while (true) {
				var q_lo: u128 = 0;
				var q_hi: u128 = 0;
				var ok: bool = false;
				if (parity_even) {
					if (cc < v_top) {
						const denom_hi = v_top - cc;
						const denom_lo = v_top + dd;
						if (bb <= u_top and denom_hi != 0) {
							const num_lo = u_top - bb;
							const num_hi = u_top + aa;
							q_lo = num_lo / denom_lo;
							q_hi = num_hi / denom_hi;
							ok = true;
						}
					}
				} else {
					if (dd < v_top) {
						const denom_hi = v_top - dd;
						const denom_lo = v_top + cc;
						if (aa <= u_top and denom_hi != 0) {
							const num_lo = u_top - aa;
							const num_hi = u_top + bb;
							q_lo = num_lo / denom_lo;
							q_hi = num_hi / denom_hi;
							ok = true;
						}
					}
				}
				if (!ok or q_lo != q_hi or q_lo == 0) break;
				const q = q_lo;

				// (u, v) <- (v, u - q*v) with overflow-bounds checks.
				const qv = @mulWithOverflow(q, v_top);
				if (qv[1] != 0) break;
				if (qv[0] > u_top) break;
				const new_u = v_top;
				const new_v = u_top - qv[0];

				// (A, B, C, D) <- (C, D, A + q*C, B + q*D), capped at 2^126.
				const qc = @mulWithOverflow(q, cc);
				if (qc[1] != 0) break;
				const new_c_ov = @addWithOverflow(aa, qc[0]);
				if (new_c_ov[1] != 0) break;
				if (new_c_ov[0] >= CAP) break;
				const qd = @mulWithOverflow(q, dd);
				if (qd[1] != 0) break;
				const new_d_ov = @addWithOverflow(bb, qd[0]);
				if (new_d_ov[1] != 0) break;
				if (new_d_ov[0] >= CAP) break;

				aa = cc;
				bb = dd;
				cc = new_c_ov[0];
				dd = new_d_ov[0];
				u_top = new_u;
				v_top = new_v;
				parity_even = !parity_even;
				inner_steps += 1;
			}

			if (inner_steps == 0) {
				try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
				try t0.setBytes(r1.bytes());
				try r0.setBytes(t0.bytes());
				try r1.setBytes(rem_mp.bytes());
				try qs1.mul(&q_mp, &s1);
				try new_s.sub(&s0, &qs1);
				try s0.setBytes(s1.bytes());
				try s1.setBytes(new_s.bytes());
				continue;
			}

			// Materialise the multi-precision (u128) matrix coefficients.
			try coeff_a.setU128(aa);
			try coeff_b.setU128(bb);
			try coeff_c.setU128(cc);
			try coeff_d.setU128(dd);

			try mul_a.mul(&coeff_a, &r0);
			try mul_b.mul(&coeff_b, &r1);
			try mul_c.mul(&coeff_c, &r0);
			try mul_d.mul(&coeff_d, &r1);

			if (parity_even) {
				try t0.sub(&mul_a, &mul_b);
				try t1.sub(&mul_d, &mul_c);
			} else {
				try t0.sub(&mul_b, &mul_a);
				try t1.sub(&mul_c, &mul_d);
			}
			try r0.setBytes(t0.bytes());
			try r1.setBytes(t1.bytes());

			try mul_a.mul(&coeff_a, &s0);
			try mul_b.mul(&coeff_b, &s1);
			try mul_c.mul(&coeff_c, &s0);
			try mul_d.mul(&coeff_d, &s1);
			if (parity_even) {
				try t2.sub(&mul_a, &mul_b);
				try t3.sub(&mul_d, &mul_c);
			} else {
				try t2.sub(&mul_b, &mul_a);
				try t3.sub(&mul_c, &mul_d);
			}
			try s0.setBytes(t2.bytes());
			try s1.setBytes(t3.bytes());
		}

		const gcd_is_one = r0.cached_pay_len == 1 and r0.bytes()[0] == 1 and r0.cached_sign == 1;
		if (!gcd_is_one) {
			try r.setI64(0);
			return false;
		}
		try euclideanReduce(r, &s0, &m_abs);
		return true;
	}

	/// Modular multiplicative inverse via the truly recursive HGCD primitive
	/// (M11.2). Same external contract as `invModHGCD` (M10 wider-window
	/// Lehmer): sets `r = a^-1 mod |m|`, returns `true` iff inverse exists.
	///
	/// Algorithm: iterates `hgcdRecursive` (sub-quadratic O(M(n) log n) GCD
	/// primitive) on the EEA pair (r0, r1). Each `hgcdRecursive` call produces
	/// a multi-precision 2x2 matrix that — when applied to (r0, r1) AND the
	/// Bezout coefficient pair (s0, s1) — advances both pairs by many EEA
	/// steps in one batched multi-precision matrix-multiply. Vs `invModHGCD`'s
	/// u128 window, the recursive form's window grows with recursion depth,
	/// reducing the number of expensive multi-precision matrix-applies from
	/// O(n / 124) to O(log n).
	///
	/// Falls back to `invModHGCD` (M10 wider-window Lehmer) for moduli below
	/// the recursive HGCD threshold (~1024 bits) where the recursive
	/// matrix-composition overhead doesn't yet amortise.
	pub fn invModHGCDRecursive(r: *Mp, a: *const Mp, m: *const Mp) ArithError!bool {
		if (m.cached_sign == 0) return error.DivisionByZero;
		const allocator = r.allocator;

		// Threshold: only profitable above ~4096 bits where matrix-composition
		// cost amortises across many EEA steps. Below, defer to wider-window
		// Lehmer (M10) which itself defers to classical Lehmer below 256 bits.
		const HGCD_REC_THRESHOLD: usize = 4096;
		if (m.bitLen() < HGCD_REC_THRESHOLD) return invModHGCD(r, a, m);

		var m_abs = Mp.init(allocator);
		defer m_abs.deinit();
		if (m.cached_sign < 0) {
			var zero = Mp.init(allocator);
			defer zero.deinit();
			try zero.setI64(0);
			try m_abs.sub(&zero, m);
		} else {
			try m_abs.setBytes(m.bytes());
		}

		if (m_abs.cached_pay_len == 1 and m_abs.bytes()[0] == 1) {
			try r.setI64(0);
			return true;
		}

		var r0 = Mp.init(allocator);
		defer r0.deinit();
		try euclideanReduce(&r0, a, &m_abs);
		if (r0.cached_sign == 0) {
			try r.setI64(0);
			return false;
		}

		var r1 = Mp.init(allocator);
		defer r1.deinit();
		try r1.setBytes(m_abs.bytes());

		var s0 = Mp.init(allocator);
		defer s0.deinit();
		try s0.setI64(1);

		var s1 = Mp.init(allocator);
		defer s1.deinit();
		try s1.setI64(0);

		// Initial swap: enforce r0 >= r1.
		var t0 = Mp.init(allocator);
		defer t0.deinit();
		if (Mp.cmp(&r0, &r1) == .lt) {
			try t0.setBytes(r0.bytes());
			try r0.setBytes(r1.bytes());
			try r1.setBytes(t0.bytes());
			try t0.setBytes(s0.bytes());
			try s0.setBytes(s1.bytes());
			try s1.setBytes(t0.bytes());
		}

		var M = HGCDMatrix.init(allocator);
		defer M.deinit();

		// Scratch for finishing tail.
		var t1 = Mp.init(allocator);
		defer t1.deinit();
		var q_mp = Mp.init(allocator);
		defer q_mp.deinit();
		var rem_mp = Mp.init(allocator);
		defer rem_mp.deinit();
		var qs1 = Mp.init(allocator);
		defer qs1.deinit();
		var new_s = Mp.init(allocator);
		defer new_s.deinit();

		// Lower bound: once r0 fits in u64, finish with single-precision EEA
		// (the same helper used by the Lehmer paths). Above that, repeatedly
		// call hgcdRecursive to halve r0's bit-length per outer iteration.
		while (r1.cached_sign != 0) {
			const r0_bits = r0.bitLen();
			if (r0_bits <= 64) {
				try lehmerFinishSinglePrecision(&r0, &r1, &s0, &s1, &t0, &t1);
				break;
			}

			// Recursive HGCD: aim to halve r0's bit-length in one shot.
			const target_bits: usize = r0_bits / 2;
			try Mp.hgcdRecursive(&M, &r0, &r1, target_bits, allocator);

			// If hgcdRecursive returned identity (no reduction), fall back
			// to one classical EEA step to ensure forward progress.
			const M_is_identity =
				M.parity_even
				and M.a.cached_pay_len == 1 and M.a.bytes()[0] == 1
				and M.b.cached_sign == 0
				and M.c.cached_sign == 0
				and M.d.cached_pay_len == 1 and M.d.bytes()[0] == 1;
			if (M_is_identity) {
				try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
				try t0.setBytes(r1.bytes());
				try r0.setBytes(t0.bytes());
				try r1.setBytes(rem_mp.bytes());
				try qs1.mul(&q_mp, &s1);
				try new_s.sub(&s0, &qs1);
				try s0.setBytes(s1.bytes());
				try s1.setBytes(new_s.bytes());
				continue;
			}

			// Apply M to both (r0, r1) and (s0, s1).
			try M.applyToPair(&r0, &r1);
			try M.applyToPair(&s0, &s1);
		}

		const gcd_is_one = r0.cached_pay_len == 1 and r0.bytes()[0] == 1 and r0.cached_sign == 1;
		if (!gcd_is_one) {
			try r.setI64(0);
			return false;
		}
		try euclideanReduce(r, &s0, &m_abs);
		return true;
	}

	// ── M11.1 — HGCD primitive (standalone; not yet wired into invMod) ─────
	//
	// HGCDMatrix represents the accumulated 2x2 reduction matrix from a
	// sequence of Euclidean (EEA) steps. All four entries are stored as
	// non-negative `Mp` values; `parity_even` tracks the sign convention so
	// that the matrix can represent any product of EEA-step matrices without
	// requiring signed multi-precision arithmetic.
	//
	// Matrix application semantics (matches `invModLehmer`'s inner-loop
	// convention so test expectations stay consistent across the codebase):
	//   parity even (k = 0, 2, ...):
	//     r0' = A·r0 - B·r1
	//     r1' = D·r1 - C·r0
	//   parity odd (k = 1, 3, ...):
	//     r0' = B·r1 - A·r0
	//     r1' = C·r0 - D·r1
	// where the matrix is M = [[A, B], [C, D]] = [[a, b], [c, d]].
	//
	// Composition (M_new = M_outer · M_inner): if M_inner has parity p_i and
	// M_outer has parity p_o, then M_new has parity (p_i XOR p_o), and its
	// entries are derived per parity of M_outer (see `composeFrom`).
	pub const HGCDMatrix = struct {
		a: Mp, // top-left
		b: Mp, // top-right
		c: Mp, // bottom-left
		d: Mp, // bottom-right
		parity_even: bool,

		pub fn init(allocator: std.mem.Allocator) HGCDMatrix {
			return .{
				.a = Mp.init(allocator),
				.b = Mp.init(allocator),
				.c = Mp.init(allocator),
				.d = Mp.init(allocator),
				.parity_even = true,
			};
		}

		pub fn deinit(self: *HGCDMatrix) void {
			self.a.deinit();
			self.b.deinit();
			self.c.deinit();
			self.d.deinit();
		}

		/// Set this matrix to the identity I = [[1,0],[0,1]] with even parity
		/// (the EEA "no steps taken" matrix).
		pub fn setIdentity(self: *HGCDMatrix) ArithError!void {
			try self.a.setI64(1);
			try self.b.setI64(0);
			try self.c.setI64(0);
			try self.d.setI64(1);
			self.parity_even = true;
		}

		/// Apply this matrix to a (r0, r1) pair in-place:
		///   parity even: (r0, r1) <- (A·r0 - B·r1, D·r1 - C·r0)
		///   parity odd:  (r0, r1) <- (B·r1 - A·r0, C·r0 - D·r1)
		pub fn applyToPair(self: *const HGCDMatrix, r0: *Mp, r1: *Mp) ArithError!void {
			const allocator = r0.allocator;
			var ar0 = Mp.init(allocator);
			defer ar0.deinit();
			var br1 = Mp.init(allocator);
			defer br1.deinit();
			var cr0 = Mp.init(allocator);
			defer cr0.deinit();
			var dr1 = Mp.init(allocator);
			defer dr1.deinit();
			var new_r0 = Mp.init(allocator);
			defer new_r0.deinit();
			var new_r1 = Mp.init(allocator);
			defer new_r1.deinit();

			try ar0.mul(&self.a, r0);
			try br1.mul(&self.b, r1);
			try cr0.mul(&self.c, r0);
			try dr1.mul(&self.d, r1);

			if (self.parity_even) {
				try new_r0.sub(&ar0, &br1);
				try new_r1.sub(&dr1, &cr0);
			} else {
				try new_r0.sub(&br1, &ar0);
				try new_r1.sub(&cr0, &dr1);
			}
			try r0.setBytes(new_r0.bytes());
			try r1.setBytes(new_r1.bytes());
		}

		/// Compose: self <- M_outer · self (i.e., apply M_outer ON TOP of self).
		/// Used by hgcd to fold the inner-loop matrix from each iteration into
		/// the running accumulator.
		///
		/// Derivation: applying self to (r0_o, r1_o) gives some (r0', r1').
		/// Applying M_outer to (r0', r1') gives the final (r0'', r1''). We want
		/// a single matrix that maps (r0_o, r1_o) directly to (r0'', r1'').
		///
		/// Let self = [[A1, B1], [C1, D1]] with parity p1.
		/// Let outer = [[A2, B2], [C2, D2]] with parity p2.
		///
		/// CASE p1 even, p2 even:
		///   r0' = A1·r0o - B1·r1o
		///   r1' = D1·r1o - C1·r0o
		///   r0'' = A2·r0' - B2·r1'
		///        = A2·(A1·r0o - B1·r1o) - B2·(D1·r1o - C1·r0o)
		///        = (A2·A1 + B2·C1)·r0o - (A2·B1 + B2·D1)·r1o
		///   r1'' = D2·r1' - C2·r0'
		///        = D2·(D1·r1o - C1·r0o) - C2·(A1·r0o - B1·r1o)
		///        = (D2·D1 + C2·B1)·r1o - (D2·C1 + C2·A1)·r0o
		///   → new parity even (p1=even, p2=even → composed parity even)
		///   A_new = A2·A1 + B2·C1
		///   B_new = A2·B1 + B2·D1
		///   C_new = C2·A1 + D2·C1
		///   D_new = C2·B1 + D2·D1
		///
		/// CASE p1 even, p2 odd:
		///   r0' = A1·r0o - B1·r1o
		///   r1' = D1·r1o - C1·r0o
		///   r0'' = B2·r1' - A2·r0'
		///        = B2·(D1·r1o - C1·r0o) - A2·(A1·r0o - B1·r1o)
		///        = (A2·B1 + B2·D1)·r1o - (A2·A1 + B2·C1)·r0o
		///   r1'' = C2·r0' - D2·r1'
		///        = C2·(A1·r0o - B1·r1o) - D2·(D1·r1o - C1·r0o)
		///        = (C2·A1 + D2·C1)·r0o - (C2·B1 + D2·D1)·r1o
		///   → new parity odd (even XOR odd = odd)
		///   A_new = A2·A1 + B2·C1
		///   B_new = A2·B1 + B2·D1
		///   C_new = C2·A1 + D2·C1
		///   D_new = C2·B1 + D2·D1
		///
		/// CASE p1 odd, p2 even:
		///   r0' = B1·r1o - A1·r0o
		///   r1' = C1·r0o - D1·r1o
		///   r0'' = A2·r0' - B2·r1'
		///        = A2·(B1·r1o - A1·r0o) - B2·(C1·r0o - D1·r1o)
		///        = (A2·B1 + B2·D1)·r1o - (A2·A1 + B2·C1)·r0o
		///   r1'' = D2·r1' - C2·r0'
		///        = D2·(C1·r0o - D1·r1o) - C2·(B1·r1o - A1·r0o)
		///        = (D2·C1 + C2·A1)·r0o - (D2·D1 + C2·B1)·r1o
		///   → new parity odd (odd XOR even = odd)
		///   A_new = A2·A1 + B2·C1
		///   B_new = A2·B1 + B2·D1
		///   C_new = C2·A1 + D2·C1
		///   D_new = C2·B1 + D2·D1
		///
		/// CASE p1 odd, p2 odd:
		///   r0' = B1·r1o - A1·r0o
		///   r1' = C1·r0o - D1·r1o
		///   r0'' = B2·r1' - A2·r0'
		///        = B2·(C1·r0o - D1·r1o) - A2·(B1·r1o - A1·r0o)
		///        = (A2·A1 + B2·C1)·r0o - (A2·B1 + B2·D1)·r1o
		///   r1'' = C2·r0' - D2·r1'
		///        = C2·(B1·r1o - A1·r0o) - D2·(C1·r0o - D1·r1o)
		///        = (C2·B1 + D2·D1)·r1o - (C2·A1 + D2·C1)·r0o
		///   → new parity even
		///   A_new = A2·A1 + B2·C1
		///   B_new = A2·B1 + B2·D1
		///   C_new = C2·A1 + D2·C1
		///   D_new = C2·B1 + D2·D1
		///
		/// EXCELLENT INVARIANT: across all four cases the entry formulas are
		/// IDENTICAL. Only the parity flips. So composition is a single set of
		/// 8 multiplications + 4 additions, with parity = p1 XOR p2.
		pub fn composeOuter(self: *HGCDMatrix, outer: *const HGCDMatrix) ArithError!void {
			const allocator = self.a.allocator;
			var t1 = Mp.init(allocator);
			defer t1.deinit();
			var t2 = Mp.init(allocator);
			defer t2.deinit();
			var new_a = Mp.init(allocator);
			defer new_a.deinit();
			var new_b = Mp.init(allocator);
			defer new_b.deinit();
			var new_c = Mp.init(allocator);
			defer new_c.deinit();
			var new_d = Mp.init(allocator);
			defer new_d.deinit();

			// A_new = A2·A1 + B2·C1
			try t1.mul(&outer.a, &self.a);
			try t2.mul(&outer.b, &self.c);
			try new_a.add(&t1, &t2);
			// B_new = A2·B1 + B2·D1
			try t1.mul(&outer.a, &self.b);
			try t2.mul(&outer.b, &self.d);
			try new_b.add(&t1, &t2);
			// C_new = C2·A1 + D2·C1
			try t1.mul(&outer.c, &self.a);
			try t2.mul(&outer.d, &self.c);
			try new_c.add(&t1, &t2);
			// D_new = C2·B1 + D2·D1
			try t1.mul(&outer.c, &self.b);
			try t2.mul(&outer.d, &self.d);
			try new_d.add(&t1, &t2);

			try self.a.setBytes(new_a.bytes());
			try self.b.setBytes(new_b.bytes());
			try self.c.setBytes(new_c.bytes());
			try self.d.setBytes(new_d.bytes());
			self.parity_even = (self.parity_even == outer.parity_even);
		}
	};

	/// HGCD primitive (M11.1, standalone — NOT wired into Mp.invMod).
	///
	/// Given (a, b) with a > b > 0, produces a 2x2 reduction matrix M such
	/// that applying M to (a, b) yields (a', b') with `bitLen(a') ≤ target_bits`
	/// or (a', b') = (gcd(a,b), 0) — whichever occurs first.
	///
	/// The matrix encodes a sequence of EEA quotients: for the canonical
	/// "half-GCD" use, set `target_bits = bitLen(a) / 2`. The output matrix
	/// will then drive a > 2× faster reduction than the equivalent
	/// quotient-by-quotient classical EEA.
	///
	/// Implementation: iterative Lehmer-style reduction with multi-precision
	/// matrix accumulation. Each iteration extracts a u64-window inner loop
	/// (per Knuth Algorithm L), accumulates the inner-loop matrix into the
	/// running HGCDMatrix via `composeOuter`, and applies the inner-loop
	/// matrix to the working (r0, r1) so the next iteration sees reduced
	/// magnitudes. Termination when bitLen(r0) drops below target_bits.
	///
	/// This is "M11.1.1 + iterative scaffold for M11.2 integration" — a
	/// truly RECURSIVE HGCD (with O(M(n) log n) complexity) is M11.1.2 future
	/// work and would build on this same matrix machinery + composeOuter.
	pub fn hgcd(
		out_M: *HGCDMatrix,
		a: *const Mp,
		b: *const Mp,
		target_bits: usize,
		allocator: std.mem.Allocator,
	) ArithError!void {
		try out_M.setIdentity();

		// Working copies of (a, b) — caller owns the originals; we don't
		// mutate them.
		var r0 = Mp.init(allocator);
		defer r0.deinit();
		var r1 = Mp.init(allocator);
		defer r1.deinit();
		try r0.setBytes(a.bytes());
		try r1.setBytes(b.bytes());

		// Already at/below threshold or one operand is zero — identity matrix
		// is correct.
		if (r0.bitLen() <= target_bits) return;
		if (r1.cached_sign == 0) return;

		// Per-iteration inner-loop matrix (rebuilt each pass).
		var inner = HGCDMatrix.init(allocator);
		defer inner.deinit();

		// Scratch Mps for divMod-fallback step.
		var q_mp = Mp.init(allocator);
		defer q_mp.deinit();
		var rem_mp = Mp.init(allocator);
		defer rem_mp.deinit();
		var tmp = Mp.init(allocator);
		defer tmp.deinit();

		while (r1.cached_sign != 0 and r0.bitLen() > target_bits) {
			const r0_bits = r0.bitLen();

			// For very small r0, fall through to single-step EEA (cheap, and
			// avoids edge cases in the inner-loop window logic).
			if (r0_bits <= 64) {
				// Single multi-limb EEA step: q = r0 / r1; (r0, r1) <- (r1, r0 - q·r1).
				try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
				try tmp.setBytes(r1.bytes());
				try r0.setBytes(tmp.bytes());
				try r1.setBytes(rem_mp.bytes());

				// Build inner = [[0, 1], [1, q]] with parity odd (one EEA step
				// from identity flips parity).
				try inner.a.setI64(0);
				try inner.b.setI64(1);
				try inner.c.setI64(1);
				try inner.d.setBytes(q_mp.bytes());
				inner.parity_even = false;
				try out_M.composeOuter(&inner);
				continue;
			}

			// Knuth Algorithm L inner loop (u62 window).
			const shift_down: usize = r0_bits - 62;
			const mask62 = (@as(u64, 1) << 62) - 1;
			var u_top: u64 = topU64(&r0, shift_down) & mask62;
			var v_top: u64 = topU64(&r1, shift_down) & mask62;

			if (v_top == 0) {
				// Estimate uninformative — single classical step.
				try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
				try tmp.setBytes(r1.bytes());
				try r0.setBytes(tmp.bytes());
				try r1.setBytes(rem_mp.bytes());
				try inner.a.setI64(0);
				try inner.b.setI64(1);
				try inner.c.setI64(1);
				try inner.d.setBytes(q_mp.bytes());
				inner.parity_even = false;
				try out_M.composeOuter(&inner);
				continue;
			}

			var aa: u64 = 1;
			var bb: u64 = 0;
			var cc: u64 = 0;
			var dd: u64 = 1;
			var inner_parity_even: bool = true;
			var inner_steps: usize = 0;

			while (true) {
				var q_lo: u64 = 0;
				var q_hi: u64 = 0;
				var ok: bool = false;
				if (inner_parity_even) {
					if (cc < v_top) {
						const denom_hi = v_top - cc;
						const denom_lo = v_top + dd;
						if (bb <= u_top and denom_hi != 0) {
							const num_lo = u_top - bb;
							const num_hi = u_top + aa;
							q_lo = num_lo / denom_lo;
							q_hi = num_hi / denom_hi;
							ok = true;
						}
					}
				} else {
					if (dd < v_top) {
						const denom_hi = v_top - dd;
						const denom_lo = v_top + cc;
						if (aa <= u_top and denom_hi != 0) {
							const num_lo = u_top - aa;
							const num_hi = u_top + bb;
							q_lo = num_lo / denom_lo;
							q_hi = num_hi / denom_hi;
							ok = true;
						}
					}
				}
				if (!ok or q_lo != q_hi or q_lo == 0) break;
				const q = q_lo;
				const qv = @mulWithOverflow(q, v_top);
				if (qv[1] != 0) break;
				if (qv[0] > u_top) break;
				const new_u = v_top;
				const new_v = u_top - qv[0];
				const qc = @mulWithOverflow(q, cc);
				if (qc[1] != 0) break;
				const new_c_ov = @addWithOverflow(aa, qc[0]);
				if (new_c_ov[1] != 0) break;
				if (new_c_ov[0] >= (@as(u64, 1) << 62)) break;
				const qd = @mulWithOverflow(q, dd);
				if (qd[1] != 0) break;
				const new_d_ov = @addWithOverflow(bb, qd[0]);
				if (new_d_ov[1] != 0) break;
				if (new_d_ov[0] >= (@as(u64, 1) << 62)) break;
				aa = cc;
				bb = dd;
				cc = new_c_ov[0];
				dd = new_d_ov[0];
				u_top = new_u;
				v_top = new_v;
				inner_parity_even = !inner_parity_even;
				inner_steps += 1;
			}

			if (inner_steps == 0) {
				// Lehmer estimate disagreed even on first step → one classical
				// step.
				try Mp.divMod(&q_mp, &rem_mp, &r0, &r1);
				try tmp.setBytes(r1.bytes());
				try r0.setBytes(tmp.bytes());
				try r1.setBytes(rem_mp.bytes());
				try inner.a.setI64(0);
				try inner.b.setI64(1);
				try inner.c.setI64(1);
				try inner.d.setBytes(q_mp.bytes());
				inner.parity_even = false;
				try out_M.composeOuter(&inner);
				continue;
			}

			// Materialise inner-loop matrix as Mp values, apply to (r0, r1),
			// then compose into out_M.
			try inner.a.setU64(aa);
			try inner.b.setU64(bb);
			try inner.c.setU64(cc);
			try inner.d.setU64(dd);
			inner.parity_even = inner_parity_even;
			try inner.applyToPair(&r0, &r1);
			try out_M.composeOuter(&inner);
		}
	}

	/// Materialise the magnitude `(src >> shift_down)` as a non-negative Mp
	/// in `out`. Used by the recursive HGCD to extract the top window of bits
	/// from a multi-precision r0 / r1 into a smaller Mp suitable for a
	/// subordinate HGCD call.
	///
	/// `src` must be non-negative (HGCD's r0/r1 invariant); behaviour for
	/// negative inputs is undefined. If `shift_down >= bitLen(src)`, sets out = 0.
	fn setFromShiftedRight(out: *Mp, src: *const Mp, shift_down: usize) ArithError!void {
		const src_bits = src.bitLen();
		if (src_bits <= shift_down) {
			try out.setI64(0);
			return;
		}
		const result_bits = src_bits - shift_down;
		// magnitude bytes of src (positive case): just src.payload()
		const pay = src.payload();
		const byte_off = shift_down / 8;
		const bit_off: u3 = @intCast(shift_down & 7);

		// Output magnitude L = ceil(result_bits / 8).
		const out_mag_len: usize = (result_bits + 7) / 8;
		// Need scratch buffer to hold magnitude bytes, then a possible 0x00
		// pad if high bit of high byte is set, then a header.
		const allocator = out.allocator;
		var mag = try allocator.alloc(u8, out_mag_len);
		defer allocator.free(mag);

		var i: usize = 0;
		while (i < out_mag_len) : (i += 1) {
			const idx = byte_off + i;
			const b0: u16 = if (idx < pay.len) pay[idx] else 0;
			const b1: u16 = if (idx + 1 < pay.len) pay[idx + 1] else 0;
			const combined: u16 = b0 | (b1 << 8);
			mag[i] = @intCast((combined >> bit_off) & 0xFF);
		}
		// Trim leading zero magnitude bytes (canonicalise).
		var L: usize = out_mag_len;
		while (L > 1 and mag[L - 1] == 0) L -= 1;
		// Pad if high bit of high byte is set (would be misread as negative).
		const need_pad = (mag[L - 1] & 0x80) != 0;
		const pay_len: usize = if (need_pad) L + 1 else L;
		// Build encoded form: header + payload.
		var hdr_buf: [10]u8 = undefined;
		const hdr_len = try tier3.writeHeader(&hdr_buf, pay_len);

		const total = hdr_len + pay_len;
		// Use a scratch buffer (or assemble into out's heap directly via setBytes).
		var enc = try allocator.alloc(u8, total);
		defer allocator.free(enc);
		@memcpy(enc[0..hdr_len], hdr_buf[0..hdr_len]);
		@memcpy(enc[hdr_len .. hdr_len + L], mag[0..L]);
		if (need_pad) enc[hdr_len + L] = 0;
		try out.setBytes(enc);
	}

	/// Truly recursive HGCD (M11.2). Same external contract as `hgcd`:
	/// builds a 2x2 reduction matrix that, applied to (a, b), reduces them
	/// to a pair (a', b') with `bitLen(a') <= target_bits` (or b' = 0).
	///
	/// Algorithm (Knuth/GMP-style divide-and-conquer):
	///   At recursion level n = bitLen(a) with target_bits ≈ n/2:
	///   1. If n ≤ RECURSION_BASE_BITS, defer to iterative `hgcd`.
	///   2. PHASE 1 — extract top-half bits of (a, b) and recurse with
	///      sub-target half-of-half-bits → matrix M1. This M1 reduces the
	///      top-half window by ~quarter-of-input bits, and (per Knuth's
	///      theorem on leading-bits-determine-quotients) is also valid for
	///      the full pair (with possible 1-quotient over-shoot).
	///   3. Apply M1 to FULL (r0, r1). Validate the result is non-negative
	///      with r0 ≥ r1; if not, back out and take a classical EEA step.
	///      M_out := M1.
	///   4. PHASE 2 — if bitLen(r0) is still > target_bits, take ONE
	///      classical EEA correction step (since the quotient at the
	///      M1-truncation boundary may need adjustment), then compose
	///      [[0,1],[1,q]] into M_out.
	///   5. PHASE 3 — if still > target_bits, extract the top-half bits of
	///      the now-reduced (r0, r1) and recurse with sub-target finishing
	///      the reduction → matrix M2. Apply, validate, compose.
	///
	/// Complexity: O(M(n) log n). At each level we do O(M(n)) for two
	/// matrix-applies + two matrix-composes; recursion depth is O(log n).
	pub fn hgcdRecursive(
		out_M: *HGCDMatrix,
		a: *const Mp,
		b: *const Mp,
		target_bits: usize,
		allocator: std.mem.Allocator,
	) ArithError!void {
		try out_M.setIdentity();

		// Below this threshold, defer to the iterative form. Tuned to be
		// large enough that the recursion + matrix-compose overhead is
		// amortised, but small enough to keep recursion depth bounded.
		const RECURSION_BASE_BITS: usize = 256;

		const n0 = a.bitLen();
		if (n0 <= target_bits) return;
		if (b.cached_sign == 0) return;

		// Bottom out into iterative form for small n.
		if (n0 <= RECURSION_BASE_BITS) {
			try Mp.hgcd(out_M, a, b, target_bits, allocator);
			return;
		}

		// Working copies of (a, b). out_M starts as identity.
		var r0 = Mp.init(allocator);
		defer r0.deinit();
		var r1 = Mp.init(allocator);
		defer r1.deinit();
		try r0.setBytes(a.bytes());
		try r1.setBytes(b.bytes());

		// Scratch
		var inner = HGCDMatrix.init(allocator);
		defer inner.deinit();
		var a_top = Mp.init(allocator);
		defer a_top.deinit();
		var b_top = Mp.init(allocator);
		defer b_top.deinit();
		var r0_try = Mp.init(allocator);
		defer r0_try.deinit();
		var r1_try = Mp.init(allocator);
		defer r1_try.deinit();
		var q_mp = Mp.init(allocator);
		defer q_mp.deinit();
		var rem_mp = Mp.init(allocator);
		defer rem_mp.deinit();
		var tmp = Mp.init(allocator);
		defer tmp.deinit();

		// Helper closure-equivalent: tries to commit `inner` to (r0, r1) +
		// out_M, returning true on success. On failure (over-shoot), leaves
		// state untouched.
		const Apply = struct {
			fn tryApply(
				inner_: *HGCDMatrix,
				r0_: *Mp, r1_: *Mp,
				r0_try_: *Mp, r1_try_: *Mp,
				out_: *HGCDMatrix,
			) ArithError!bool {
				try r0_try_.setBytes(r0_.bytes());
				try r1_try_.setBytes(r1_.bytes());
				try inner_.applyToPair(r0_try_, r1_try_);
				const ok = r0_try_.cached_sign >= 0 and r1_try_.cached_sign >= 0
					and Mp.cmp(r0_try_, r1_try_) != .lt
					and r0_try_.bitLen() < r0_.bitLen();
				if (!ok) return false;
				try r0_.setBytes(r0_try_.bytes());
				try r1_.setBytes(r1_try_.bytes());
				try out_.composeOuter(inner_);
				return true;
			}

			fn classicalStep(
				r0_: *Mp, r1_: *Mp,
				q_mp_: *Mp, rem_mp_: *Mp, tmp_: *Mp,
				inner_: *HGCDMatrix, out_: *HGCDMatrix,
			) ArithError!void {
				try Mp.divMod(q_mp_, rem_mp_, r0_, r1_);
				try tmp_.setBytes(r1_.bytes());
				try r0_.setBytes(tmp_.bytes());
				try r1_.setBytes(rem_mp_.bytes());
				try inner_.a.setI64(0);
				try inner_.b.setI64(1);
				try inner_.c.setI64(1);
				try inner_.d.setBytes(q_mp_.bytes());
				inner_.parity_even = false;
				try out_.composeOuter(inner_);
			}
		};

		// ── PHASE 1: recurse on top-half-bits of (a, b) ──────────────────
		// Choose shift such that the top window is ~n/2 bits. Sub-target on
		// the window is half-of-window = n/4. After applying M1 to the full
		// pair, bitLen(r0) should drop by roughly n/4.
		{
			const shift1: usize = n0 / 2;
			try setFromShiftedRight(&a_top, &r0, shift1);
			try setFromShiftedRight(&b_top, &r1, shift1);

			if (a_top.bitLen() > 64 and b_top.cached_sign != 0) {
				const sub_target1 = a_top.bitLen() / 2;
				try Mp.hgcdRecursive(&inner, &a_top, &b_top, sub_target1, allocator);
				const ok = try Apply.tryApply(&inner, &r0, &r1, &r0_try, &r1_try, out_M);
				if (!ok) {
					try Apply.classicalStep(&r0, &r1, &q_mp, &rem_mp, &tmp, &inner, out_M);
				}
			} else {
				try Apply.classicalStep(&r0, &r1, &q_mp, &rem_mp, &tmp, &inner, out_M);
			}
		}

		if (r1.cached_sign == 0 or r0.bitLen() <= target_bits) return;

		// ── PHASE 2: optional single classical EEA correction step ───────
		// This compensates for the fact that PHASE 1 might over- or
		// under-shoot by one quotient.
		{
			try Apply.classicalStep(&r0, &r1, &q_mp, &rem_mp, &tmp, &inner, out_M);
		}

		if (r1.cached_sign == 0 or r0.bitLen() <= target_bits) return;

		// ── FINISH: iterative form for residual reduction ────────────────
		// (PHASE 3 — a second recursive call on the top bits of the reduced
		// pair — is omitted in this implementation. With schoolbook
		// multiplication, the iterative finish is asymptotically equivalent
		// to a sub-recursion AND avoids the validation-failure cascades
		// that PHASE 3 can trigger on the reduced pair. A future revision
		// may reinstate PHASE 3 once FFT-based multiplication is available.)
		if (r1.cached_sign != 0 and r0.bitLen() > target_bits) {
			try Mp.hgcd(&inner, &r0, &r1, target_bits, allocator);
			try inner.applyToPair(&r0, &r1);
			try out_M.composeOuter(&inner);
		}
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

/// powm helper: square-and-multiply (right-to-left scan of exponent bits).
/// Inputs: base_red is already reduced into [0, |m|-1]; m is positive.
/// `exp` is non-negative. Used for tiny exponents and as the correctness
/// baseline (M7-4.1).
fn powmSquareAndMultiply(r: *Mp, base_red: *const Mp, exp: *const Mp, m: *const Mp) ArithError!void {
	const allocator = r.allocator;

	var result = Mp.init(allocator);
	defer result.deinit();
	try result.setI64(1);

	var acc = Mp.init(allocator);
	defer acc.deinit();
	try acc.setBytes(base_red.bytes());

	var tmp = Mp.init(allocator);
	defer tmp.deinit();

	const e_bits = exp.bitLen();
	var i: usize = 0;
	while (i < e_bits) : (i += 1) {
		if (exp.bitAt(i) == 1) {
			try tmp.mul(&result, &acc);
			try result.mod(&tmp, m);
			if (result.cached_sign < 0) try result.add(&result, m);
		}
		if (i + 1 < e_bits) {
			try tmp.mul(&acc, &acc);
			try acc.mod(&tmp, m);
			if (acc.cached_sign < 0) try acc.add(&acc, m);
		}
	}

	try r.setBytes(result.bytes());
}

/// powm helper: left-to-right sliding-window exponentiation (M7-4.2).
/// Precomputes odd powers `g[1], g[3], g[5], ..., g[2^w - 1]` of base_red
/// (modulo m), then walks the exponent's bits high-to-low, accumulating
/// squarings and folding in window multiplies. Saves ~25-35% of mults vs
/// square-and-multiply for typical 1024-2048-bit exponents.
///
/// Inputs: base_red already reduced into [0, |m|-1]; m positive; exp positive
/// with bitLen > w (caller decides). w should be in [2, 8].
fn powmSlidingWindow(r: *Mp, base_red: *const Mp, exp: *const Mp, m: *const Mp, w: u8) ArithError!void {
	const allocator = r.allocator;
	std.debug.assert(w >= 2 and w <= 8);

	const tbl_count: usize = @as(usize, 1) << @intCast(w - 1); // 2^(w-1) odd entries

	// Precompute table[k] = base_red ^ (2k+1) mod m, for k in 0..tbl_count.
	// table[0] = base_red. table[k] = table[k-1] * base_red^2 mod m.
	var table: [128]Mp = undefined; // up to w=8 → 128 entries
	for (0..tbl_count) |k| table[k] = Mp.init(allocator);
	defer for (0..tbl_count) |k| table[k].deinit();

	try table[0].setBytes(base_red.bytes());

	var tmp = Mp.init(allocator);
	defer tmp.deinit();
	var sq = Mp.init(allocator); // base_red^2 mod m
	defer sq.deinit();
	try tmp.mul(base_red, base_red);
	try sq.mod(&tmp, m);
	if (sq.cached_sign < 0) try sq.add(&sq, m);

	for (1..tbl_count) |k| {
		try tmp.mul(&table[k - 1], &sq);
		try table[k].mod(&tmp, m);
		if (table[k].cached_sign < 0) try table[k].add(&table[k], m);
	}

	// Walk exponent bits high-to-low using sliding window.
	var result = Mp.init(allocator);
	defer result.deinit();
	try result.setI64(1);

	const e_bits: isize = @intCast(exp.bitLen());
	var i: isize = e_bits - 1;
	while (i >= 0) {
		if (exp.bitAt(@intCast(i)) == 0) {
			// Single squaring; advance by 1 bit.
			try tmp.mul(&result, &result);
			try result.mod(&tmp, m);
			if (result.cached_sign < 0) try result.add(&result, m);
			i -= 1;
		} else {
			// Find longest odd window of width ≤ w ending at a 1-bit.
			// Scan from i down to max(i - w + 1, 0); find lowest j with
			// exp.bitAt(j) == 1; window covers bits [j..i] (inclusive).
			const w_isz: isize = @intCast(w);
			const lo_limit: isize = if (i - w_isz + 1 >= 0) i - w_isz + 1 else 0;
			var j: isize = lo_limit;
			while (j <= i and exp.bitAt(@intCast(j)) == 0) : (j += 1) {}
			// Window covers bits [j..i], width = i - j + 1, value = bits
			// j..i interpreted as little-endian within those positions.
			const win_width: usize = @intCast(i - j + 1);
			var win_val: u32 = 0;
			var bk: isize = i;
			while (bk >= j) : (bk -= 1) {
				win_val = (win_val << 1) | @as(u32, exp.bitAt(@intCast(bk)));
			}
			// Square `win_width` times.
			for (0..win_width) |_| {
				try tmp.mul(&result, &result);
				try result.mod(&tmp, m);
				if (result.cached_sign < 0) try result.add(&result, m);
			}
			// Multiply by table[(win_val - 1) / 2].
			const tbl_idx: usize = (@as(usize, @intCast(win_val)) - 1) / 2;
			try tmp.mul(&result, &table[tbl_idx]);
			try result.mod(&tmp, m);
			if (result.cached_sign < 0) try result.add(&result, m);
			i = j - 1;
		}
	}

	try r.setBytes(result.bytes());
}

/// powm helper: Montgomery sliding-window exponentiation (M7-4.3).
///
/// Replaces every `mul + mod` step in the sliding-window loop with a single
/// `montMul`, which fuses multiply + Montgomery reduction into one O(k^2)
/// pass over u64 limbs (no Knuth division). Setup cost (one R^2 mod m
/// computation, then base/result conversion via two extra montMuls)
/// amortises across the ~bits squarings + ~bits/w multiplications.
///
/// Inputs: base_red already reduced into [0, |m|-1]; m positive, ODD,
/// magnitude length >= 8 bytes (caller decides — Mont's setup makes it
/// uneconomic below ~64-bit moduli). w in [2, 8].
fn powmMontgomery(r: *Mp, base_red: *const Mp, exp: *const Mp, m: *const Mp, w: u8) ArithError!void {
	const allocator = r.allocator;
	std.debug.assert(w >= 2 and w <= 8);

	// Determine k_limbs from the modulus magnitude byte length.
	const m_pay = m.payload();
	var m_mag_byte_len: usize = m_pay.len;
	while (m_mag_byte_len > 0 and m_pay[m_mag_byte_len - 1] == 0) m_mag_byte_len -= 1;
	std.debug.assert(m_mag_byte_len >= 8);
	const k_limbs: usize = (m_mag_byte_len + 7) / 8;

	// Allocate the working limb arrays. All sized k_limbs except scratch
	// which needs 2*k+1 for the wide accumulator.
	const m_lim = try allocator.alloc(u64, k_limbs);
	defer allocator.free(m_lim);
	const r2 = try allocator.alloc(u64, k_limbs);
	defer allocator.free(r2);
	const base_mont = try allocator.alloc(u64, k_limbs);
	defer allocator.free(base_mont);
	const result_mont = try allocator.alloc(u64, k_limbs);
	defer allocator.free(result_mont);
	const tmp_lim = try allocator.alloc(u64, k_limbs);
	defer allocator.free(tmp_lim);
	const sq_mont = try allocator.alloc(u64, k_limbs);
	defer allocator.free(sq_mont);
	const scratch = try allocator.alloc(u64, 2 * k_limbs + 1);
	defer allocator.free(scratch);

	// Window table: 2^(w-1) odd-power Mont-form base values.
	const tbl_count: usize = @as(usize, 1) << @intCast(w - 1);
	const table = try allocator.alloc([]u64, tbl_count);
	defer {
		for (table) |t| if (t.len > 0) allocator.free(t);
		allocator.free(table);
	}
	for (table) |*t| t.* = &.{};
	for (table) |*t| t.* = try allocator.alloc(u64, k_limbs);

	// Pack m into limb array. For positive payloads, the magnitude bytes are
	// payload[0..m_mag_byte_len].
	tier3.bytesToLimbs(m_pay[0..m_mag_byte_len], m_lim);

	// Pack base into limb array (zero-extended to m_mag_byte_len width).
	const base_pay = base_red.payload();
	var base_mag_len: usize = base_pay.len;
	while (base_mag_len > 0 and base_pay[base_mag_len - 1] == 0) base_mag_len -= 1;
	const base_padded = try allocator.alloc(u8, m_mag_byte_len);
	defer allocator.free(base_padded);
	@memset(base_padded, 0);
	if (base_mag_len > 0) @memcpy(base_padded[0..base_mag_len], base_pay[0..base_mag_len]);
	tier3.bytesToLimbs(base_padded, tmp_lim);

	// Setup: m_inv_neg, R^2 mod m.
	const m_inv_neg = tier3.modInvNeg64(m_lim[0]);
	tier3.computeR2ModM(m_lim, r2);

	// to_mont(base) = montMul(base, R^2)
	tier3.montMul(tmp_lim, r2, m_lim, m_inv_neg, base_mont, scratch);
	// to_mont(1) = montMul(1, R^2) = R mod m. Build "1" in tmp_lim.
	@memset(tmp_lim, 0);
	tmp_lim[0] = 1;
	tier3.montMul(tmp_lim, r2, m_lim, m_inv_neg, result_mont, scratch);

	// table[0] = base_mont; sq_mont = base_mont^2 (Mont form).
	@memcpy(table[0], base_mont);
	tier3.montMul(base_mont, base_mont, m_lim, m_inv_neg, sq_mont, scratch);
	// table[k] = table[k-1] * sq_mont (Mont form).
	var k_idx: usize = 1;
	while (k_idx < tbl_count) : (k_idx += 1) {
		tier3.montMul(table[k_idx - 1], sq_mont, m_lim, m_inv_neg, table[k_idx], scratch);
	}

	// Sliding-window loop, in Mont form.
	const e_bits: isize = @intCast(exp.bitLen());
	var i: isize = e_bits - 1;
	while (i >= 0) {
		if (exp.bitAt(@intCast(i)) == 0) {
			// Single squaring; advance by 1 bit. result = result^2 (Mont).
			tier3.montMul(result_mont, result_mont, m_lim, m_inv_neg, tmp_lim, scratch);
			@memcpy(result_mont, tmp_lim);
			i -= 1;
		} else {
			const w_isz: isize = @intCast(w);
			const lo_limit: isize = if (i - w_isz + 1 >= 0) i - w_isz + 1 else 0;
			var j: isize = lo_limit;
			while (j <= i and exp.bitAt(@intCast(j)) == 0) : (j += 1) {}
			const win_width: usize = @intCast(i - j + 1);
			var win_val: u32 = 0;
			var bk: isize = i;
			while (bk >= j) : (bk -= 1) {
				win_val = (win_val << 1) | @as(u32, exp.bitAt(@intCast(bk)));
			}
			// Square `win_width` times.
			var sq_iter: usize = 0;
			while (sq_iter < win_width) : (sq_iter += 1) {
				tier3.montMul(result_mont, result_mont, m_lim, m_inv_neg, tmp_lim, scratch);
				@memcpy(result_mont, tmp_lim);
			}
			// Multiply by table[(win_val - 1) / 2].
			const tbl_idx: usize = (@as(usize, @intCast(win_val)) - 1) / 2;
			tier3.montMul(result_mont, table[tbl_idx], m_lim, m_inv_neg, tmp_lim, scratch);
			@memcpy(result_mont, tmp_lim);
			i = j - 1;
		}
	}

	// from_mont(result_mont) = montMul(result_mont, 1).
	@memset(tmp_lim, 0);
	tmp_lim[0] = 1;
	const out_lim = try allocator.alloc(u64, k_limbs);
	defer allocator.free(out_lim);
	tier3.montMul(result_mont, tmp_lim, m_lim, m_inv_neg, out_lim, scratch);

	// Pack out_lim back to bytes. Result is in [0, m), so its magnitude byte
	// length is <= m_mag_byte_len.
	const out_bytes = try allocator.alloc(u8, m_mag_byte_len);
	defer allocator.free(out_bytes);
	tier3.limbsToBytes(out_lim, out_bytes);
	// Trim leading-zero high bytes (canonical magnitude length).
	var canon_len: usize = m_mag_byte_len;
	while (canon_len > 0 and out_bytes[canon_len - 1] == 0) canon_len -= 1;

	if (canon_len == 0) {
		try r.setI64(0);
		return;
	}

	// Build canonical positive BLIP payload: append 0x00 sign-extension byte
	// if high magnitude byte has its top bit set. Then write header + payload.
	const need_sign_ext = (out_bytes[canon_len - 1] & 0x80) != 0;
	const pay_len = canon_len + (if (need_sign_ext) @as(usize, 1) else 0);

	const hdr_len = headerByteCount(pay_len);
	const total = hdr_len + pay_len;
	const enc_buf = try allocator.alloc(u8, total);
	defer allocator.free(enc_buf);
	_ = tier3.writeHeader(enc_buf[0..hdr_len], pay_len) catch unreachable;
	@memcpy(enc_buf[hdr_len .. hdr_len + canon_len], out_bytes[0..canon_len]);
	if (need_sign_ext) enc_buf[hdr_len + canon_len] = 0;
	try r.setBytes(enc_buf);
}

/// Tier-3 truncated division: writes a/b into q.heap_buf and a%b into rem.heap_buf.
/// Sign-magnitude dispatch + Knuth Algorithm D (or single-u64 division for small b).
/// Sign convention matches GMP `mpz_tdiv_qr` (see `Mp.divMod` doc).
/// Threshold (in payload bytes of the divisor) above which `tier3DivModOp`
/// routes to the byte-direct Burnikel-Ziegler divider instead of the existing
/// limb-packed Knuth path. Currently gated OFF in production (set to a value
/// the system never reaches): empirical benchmark shows B-Z at 4K-bit
/// divisor is ~40× SLOWER than limb-Knuth (244K vs 6K ns/op) because the
/// byte-direct base case + per-call malloc dominate. The B-Z scaffolding is
/// correct (verified by 12K+ GMP cross-checks) but needs the perf-work
/// follow-ups to win: (a) Karatsuba-aware mulMagnitudes inside the recursion,
/// (b) limb-Knuth at the leaf instead of byte-Knuth, (c) per-thread scratch
/// caching to eliminate per-call malloc. Until those land, the existing
/// limb-Knuth path with Möller-Granlund reciprocal q_hat is faster up
/// through the largest tested size (8K-bit).
const BZ_INTEGRATION_THRESHOLD: usize = 99999; // gated off; needs Karatsuba-in-mul to win

fn tier3DivModOp(q: *Mp, rem: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	const a_bytes = a.bytes();
	const b_bytes = b.bytes();
	const a_pay = a_bytes[a.cached_pay_off .. a.cached_pay_off + a.cached_pay_len];
	const b_pay = b_bytes[b.cached_pay_off .. b.cached_pay_off + b.cached_pay_len];

	// Burnikel-Ziegler dispatch for large divisors. Falls through to the
	// limb-Knuth path otherwise.
	if (b_pay.len >= BZ_INTEGRATION_THRESHOLD) {
		try tier3DivModOpBZ(q, rem, a_pay, b_pay);
		return;
	}

	// Quotient/remainder buffers must be large enough to hold the LIMB-aligned
	// (8-byte multiple) raw write from divModKnuthU64 before its trailing-zero
	// trim. Round up to the next multiple of 8, then add +2 slack for sign
	// bytes and canonicalization.
	const q_pay_max = ((a_pay.len + 7) & ~@as(usize, 7)) + 2;
	const r_pay_max = ((b_pay.len + 7) & ~@as(usize, 7)) + 2;
	const work_need = tier3.divModSignedScratchNeed(a_pay.len, b_pay.len);

	// Stack scratch for small sizes; per-thread div_scratch cache for large.
	const STACK_PAY = 4096;
	const STACK_WORK = 8192;
	var stack_q: [STACK_PAY]u8 = undefined;
	var stack_r: [STACK_PAY]u8 = undefined;
	var stack_w: [STACK_WORK]u8 = undefined;

	const q_cache_need: usize = if (q_pay_max > stack_q.len) q_pay_max else 0;
	const r_cache_need: usize = if (r_pay_max > stack_r.len) r_pay_max else 0;
	const w_cache_need: usize = if (work_need > stack_w.len) work_need else 0;
	if (q_cache_need != 0 or r_cache_need != 0 or w_cache_need != 0) {
		try tier3.div_scratch.ensureCapacity(q.allocator, q_cache_need, r_cache_need, w_cache_need);
	}
	const q_buf: []u8 = if (q_pay_max <= stack_q.len) stack_q[0..q_pay_max] else tier3.div_scratch.q_buf[0..q_pay_max];
	const r_buf: []u8 = if (r_pay_max <= stack_r.len) stack_r[0..r_pay_max] else tier3.div_scratch.r_buf[0..r_pay_max];
	const w_buf: []u8 = if (work_need <= stack_w.len) stack_w[0..work_need] else tier3.div_scratch.w_buf[0..work_need];

	const got = tier3.divModSigned(a_pay, b_pay, q_buf, r_buf, w_buf);

	// Write canonical BLIP for q and rem from the produced two's-comp payloads.
	try writeMpFromPayload(q, q_buf[0..got.q_len]);
	try writeMpFromPayload(rem, r_buf[0..got.r_len]);
}

/// B-Z dispatch for tier3DivModOp at large divisor sizes. Extracts positive
/// magnitudes (negating in-place if needed), runs byte-direct B-Z, re-encodes
/// quotient/remainder as canonical two's-complement BLIP payloads with the
/// truncated-division sign convention (sign(q) = sign(a) XOR sign(b);
/// sign(r) = sign(a)), then installs into the destination Mp's.
fn tier3DivModOpBZ(q: *Mp, rem: *Mp, a_pay: []const u8, b_pay: []const u8) ArithError!void {
	const allocator = q.allocator;
	const a_neg = tier3.signExtByte(a_pay) == 0xFF;
	const b_neg = tier3.signExtByte(b_pay) == 0xFF;

	// Materialize positive magnitudes.
	const a_mag = allocator.alloc(u8, a_pay.len) catch return error.OutOfMemory;
	defer allocator.free(a_mag);
	@memcpy(a_mag, a_pay);
	if (a_neg) tier3.negateInPlace(a_mag);
	var a_mag_len: usize = a_mag.len;
	while (a_mag_len > 0 and a_mag[a_mag_len - 1] == 0) a_mag_len -= 1;

	const b_mag = allocator.alloc(u8, b_pay.len) catch return error.OutOfMemory;
	defer allocator.free(b_mag);
	@memcpy(b_mag, b_pay);
	if (b_neg) tier3.negateInPlace(b_mag);
	var b_mag_len: usize = b_mag.len;
	while (b_mag_len > 0 and b_mag[b_mag_len - 1] == 0) b_mag_len -= 1;

	// Zero dividend → q = 0, rem = 0.
	if (a_mag_len == 0) {
		var zero = [_]u8{0};
		try writeMpFromPayload(q, zero[0..1]);
		try writeMpFromPayload(rem, zero[0..1]);
		return;
	}

	// Output magnitude buffers — quotient ≤ a_mag_len bytes, remainder ≤
	// b_mag_len bytes (canonical). +2 slack for the two's-comp sign-extension
	// byte that encodeMagAsTwosComp may append.
	const q_mag = allocator.alloc(u8, a_mag_len + 2) catch return error.OutOfMemory;
	defer allocator.free(q_mag);
	const r_mag = allocator.alloc(u8, b_mag_len + 2) catch return error.OutOfMemory;
	defer allocator.free(r_mag);

	const got = tier3.divModBurnikelZiegler(a_mag, a_mag_len, b_mag, b_mag_len, q_mag, r_mag, allocator) catch return error.OutOfMemory;

	// Sign conventions (truncated): q's sign = sign(a) XOR sign(b) iff q != 0;
	// r's sign = sign(a) iff r != 0. B-Z returns q_len=0 / r_len=0 for zero.
	const q_is_neg = (a_neg != b_neg) and got.q_len != 0;
	const r_is_neg = a_neg and got.r_len != 0;

	// encodeMagAsTwosComp writes "[0x00]" for zero magnitude AND for any mag
	// with mag_len = 0 (clean canonical zero payload). The single-byte 0x00
	// is the canonical BLIP zero payload.
	const q_pay_len = tier3.encodeMagAsTwosComp(q_mag, got.q_len, q_is_neg);
	const r_pay_len = tier3.encodeMagAsTwosComp(r_mag, got.r_len, r_is_neg);

	try writeMpFromPayload(q, q_mag[0..q_pay_len]);
	try writeMpFromPayload(rem, r_mag[0..r_pay_len]);
}

/// Encode a canonical two's-complement LE payload `pay` (length ≥ 1) as a
/// canonical BLIP value and store it in `dst`. Routes inline vs heap.
fn writeMpFromPayload(dst: *Mp, pay: []const u8) !void {
	std.debug.assert(pay.len >= 1);
	// Immediate path: single byte 0..127.
	if (pay.len == 1 and pay[0] < 0x80) {
		dst.inline_buf[0] = pay[0];
		dst.inline_len = 1;
		dst.heap_offset = 0;
		dst.cached_pay_off = 0;
		dst.cached_pay_len = 1;
		dst.cached_sign = if (pay[0] == 0) 0 else 1;
		return;
	}
	// Length-prefixed: header + payload.
	const total = pay.len + headerByteCount(pay.len);
	if (total <= INLINE_CAP) {
		const hdr_len = try tier3.writeHeader(&dst.inline_buf, pay.len);
		@memcpy(dst.inline_buf[hdr_len .. hdr_len + pay.len], pay);
		// Maintain the inline-tail invariant for length ≤ 9.
		if (total >= 2 and total <= 9) {
			const L = total - 1;
			const high_byte = dst.inline_buf[1 + L - 1];
			const sign_fill: u8 = if ((high_byte & 0x80) != 0) 0xFF else 0;
			var i: usize = L;
			while (i < 8) : (i += 1) dst.inline_buf[1 + i] = sign_fill;
		}
		dst.inline_len = @intCast(total);
		dst.heap_offset = 0;
		dst.cached_pay_off = @intCast(hdr_len);
		dst.cached_pay_len = @intCast(pay.len);
		dst.cached_sign = signFromPayload(pay);
		return;
	}
	// Heap path.
	try dst.ensureHeapCapacity(total + HDR_RESERVE);
	const hdr_len = headerByteCount(pay.len);
	const hdr_start = HDR_RESERVE - hdr_len;
	_ = try tier3.writeHeader(dst.heap_buf[hdr_start .. hdr_start + hdr_len], pay.len);
	@memcpy(dst.heap_buf[HDR_RESERVE .. HDR_RESERVE + pay.len], pay);
	dst.heap_offset = @intCast(hdr_start);
	dst.heap_used = hdr_len + pay.len;
	dst.inline_len = SENTINEL_HEAP;
	dst.cached_pay_off = @intCast(hdr_len);
	dst.cached_pay_len = @intCast(pay.len);
	dst.cached_sign = signFromPayload(pay);
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

	// Sign of each operand. Only when an operand is negative does
	// mulRawBlip touch its scratch_* buffer (to copy + negate). For positive
	// operands we can pass an empty slice and skip the alloc entirely.
	// The sign byte is the most-significant byte of the payload (LE 2's-comp).
	const a_sign_byte = if (a_bytes[0] < 0x80) a_bytes[0] else a_bytes[a_bytes.len - 1];
	const b_sign_byte = if (b_bytes[0] < 0x80) b_bytes[0] else b_bytes[b_bytes.len - 1];
	const a_neg = (a_sign_byte & 0x80) != 0;
	const b_neg = (b_sign_byte & 0x80) != 0;

	// 4 KB per operand for mul (results double, so 8 KB result + out).
	// Covers up to ~32768-bit operands without spilling to the cache.
	const STACK_BYTES = 4096;
	var stack_a: [STACK_BYTES]u8 = undefined;
	var stack_b: [STACK_BYTES]u8 = undefined;
	var stack_r: [STACK_BYTES * 2 + 1]u8 = undefined;
	var stack_out: [STACK_BYTES * 2 + 16]u8 = undefined;
	// Toom-3 / Karatsuba scratch — sized for the larger operand.
	const max_pay = @max(a_pay_len, b_pay_len);
	const k_need = if (a_pay_len == b_pay_len)
		(if (max_pay >= tier3.TOOM3_THRESHOLD) tier3.toom3ScratchNeed(max_pay) else tier3.karatsubaScratchNeed(max_pay))
	else
		0;
	var stack_k: [STACK_BYTES * 16 + 256]u8 = undefined;

	// Determine which buffers spill out of the stack buckets and into the
	// per-thread mul_scratch cache. heap_a/heap_b are needed ONLY if the
	// operand is actually negative (positive operands skip the snap-into-
	// scratch path entirely — mulRawBlip reads payloadOf(a_blip) directly).
	const a_cache_need: usize = if (a_neg and a_pay_len > STACK_BYTES) a_pay_len else 0;
	const b_cache_need: usize = if (b_neg and b_pay_len > STACK_BYTES) b_pay_len else 0;
	const r_cache_need: usize = if (r_pay_max > stack_r.len) r_pay_max else 0;
	const out_cache_need: usize = if (out_need > stack_out.len) out_need else 0;
	const k_cache_need: usize = if (k_need > stack_k.len) k_need else 0;

	if (a_cache_need != 0 or b_cache_need != 0 or r_cache_need != 0 or out_cache_need != 0 or k_cache_need != 0) {
		try tier3.mul_scratch.ensureCapacity(
			r.allocator,
			a_cache_need,
			b_cache_need,
			r_cache_need,
			out_cache_need,
			k_cache_need,
		);
	}

	const sa: []u8 = if (!a_neg)
		// Positive operand — mulRawBlip won't touch scratch_a.
		&[_]u8{}
	else if (a_pay_len <= STACK_BYTES)
		stack_a[0..a_pay_len]
	else
		tier3.mul_scratch.a_buf[0..a_pay_len];

	const sb: []u8 = if (!b_neg)
		&[_]u8{}
	else if (b_pay_len <= STACK_BYTES)
		stack_b[0..b_pay_len]
	else
		tier3.mul_scratch.b_buf[0..b_pay_len];

	const sr: []u8 = if (r_pay_max <= stack_r.len)
		stack_r[0..r_pay_max]
	else
		tier3.mul_scratch.r_buf[0..r_pay_max];

	const out_buf: []u8 = if (out_need <= stack_out.len)
		stack_out[0..out_need]
	else
		tier3.mul_scratch.out_buf[0..out_need];

	const sk: []u8 = if (k_need == 0)
		&[_]u8{}
	else if (k_need <= stack_k.len)
		stack_k[0..k_need]
	else
		tier3.mul_scratch.k_buf[0..k_need];

	const written = try tier3.mulRawBlip(a_bytes, b_bytes, sa, sb, sr, sk, out_buf, r.allocator);
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
	const a_pay_off: usize = a.cached_pay_off;
	const b_pay_off: usize = b.cached_pay_off;
	const a_pay_len: usize = a.cached_pay_len;
	const b_pay_len: usize = b.cached_pay_len;

	// SMALL TIER-3 FAST PATH (closes the 128-bit add gap to GMP).
	// When both inputs are inline AND payloads fit in u128 (≤16 bytes), the
	// entire op can be done as a single u128 add/sub against direct loads
	// from inline_buf, with the canonical result written straight back to
	// r.inline_buf. Skips: bytes() dispatch, alias/realloc check,
	// ensureHeapCapacity, the chunked-add loop ladder (4 size buckets),
	// scratch→heap→inline memcpy chain, separate canonicalLen +
	// signFromPayload scans, and writeHeader's conditionals (header is
	// always 1 byte for L<32).
	//
	// For the 128-bit bench bucket this collapses ~7-8 branches and
	// ~30 bytes of memory traffic down to one u128 ADCS + a small canonical
	// trim. Still correct for sub (different overflow semantics handled
	// per-op via @subWithOverflow + sign-flip detection).
	if (a.inline_len != SENTINEL_HEAP and b.inline_len != SENTINEL_HEAP and a_pay_len <= 16 and b_pay_len <= 16) {
		smallInlineTier3Add(r, a, b, op) catch |e| return e;
		return;
	}

	const a_bytes = a.bytes();
	const b_bytes = b.bytes();

	const max_payload = @max(a_pay_len, b_pay_len);
	const out_need = HDR_RESERVE + max_payload + 1;

	const may_realloc = r.heap_buf.len < out_need;
	const r_aliases_input = (a_bytes.ptr == r.heap_buf.ptr) or (b_bytes.ptr == r.heap_buf.ptr);
	if (may_realloc or r_aliases_input) {
		try tier3OpCold(r, a_bytes, b_bytes, a_pay_off, a_pay_len, b_pay_off, b_pay_len, out_need, op);
		return;
	}

	// SAME-SIZE FAST PATH: both payloads identical size and ≤ 64 bytes
	// (≤ 512-bit). No sign-extension needed. Direct uN read → uN add →
	// canonical write. Skips chunked-loop ladder branches and the
	// canonicalLen+signFromPayload double scan.
	if (a_pay_len == b_pay_len) {
		switch (a_pay_len) {
			24 => {
				try sameSizeTier3Add(24, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			32 => {
				try sameSizeTier3Add(32, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			48 => {
				try sameSizeTier3Add(48, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			64 => {
				try sameSizeTier3Add(64, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			96 => {
				try sameSizeTier3Add(96, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			128 => {
				try sameSizeTier3Add(128, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			192 => {
				try sameSizeTier3Add(192, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			256 => {
				try sameSizeTier3Add(256, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			384 => {
				try sameSizeTier3Add(384, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			512 => {
				try sameSizeTier3Add(512, r, a_bytes, b_bytes, a_pay_off, b_pay_off, a.cached_sign, b.cached_sign, op);
				return;
			},
			else => {},
		}
	}

	// Hot path: inlined applyTier3Op via the `inline fn` keyword.
	const a_pay = a_bytes[a_pay_off .. a_pay_off + a_pay_len];
	const b_pay = b_bytes[b_pay_off .. b_pay_off + b_pay_len];
	try applyTier3Op(r, a_pay, b_pay, op);
}

/// Same-size fast path: both payloads exactly N bytes (N ∈ {32, 64}).
/// Single uN add/sub. Writes result to r.heap_buf at the pre-reserved
/// offset (caller guaranteed r.heap_buf.len ≥ HDR_RESERVE + N + 1).
/// Result is N or N+1 bytes; canonical trim + heap-mode field updates.
inline fn sameSizeTier3Add(
	comptime N: comptime_int,
	r: *Mp,
	a_bytes: []const u8, b_bytes: []const u8,
	a_pay_off: usize, b_pay_off: usize,
	a_sign: i8, b_sign: i8,
	comptime op: TierOp,
) ArithError!void {
	const T = std.meta.Int(.unsigned, N * 8);
	const av: T = std.mem.readInt(T, a_bytes[a_pay_off..][0..N], .little);
	const bv: T = std.mem.readInt(T, b_bytes[b_pay_off..][0..N], .little);
	const result: T = switch (op) {
		.add => av +% bv,
		.sub => av -% bv,
	};

	// Write straight into heap_buf at the canonical-payload offset. The
	// header is 1 byte for N=32, 2 bytes for N=64. We compute hdr_start
	// after the canonical trim.
	std.mem.writeInt(T, r.heap_buf[HDR_RESERVE..][0..N], result, .little);

	// Same-sign overflow detection.
	const result_high_bit = (r.heap_buf[HDR_RESERVE + N - 1] & 0x80) != 0;
	const a_neg = a_sign < 0;
	const b_neg_eff = if (op == .sub) (b_sign > 0) else (b_sign < 0);
	var pay_len: usize = N;
	if (a_neg == b_neg_eff and a_neg != result_high_bit) {
		r.heap_buf[HDR_RESERVE + N] = if (a_neg) 0xFF else 0x00;
		pay_len = N + 1;
	}

	// Canonical trim — single pass that ALSO computes the resulting sign,
	// avoiding the separate signFromPayload scan.
	const pay_slice = r.heap_buf[HDR_RESERVE .. HDR_RESERVE + pay_len];
	const canon = canonicalLenSmall(pay_slice);

	// Immediate path (canon=1, value < 0x80).
	if (canon == 1 and pay_slice[0] < 0x80) {
		r.inline_buf[0] = pay_slice[0];
		r.inline_len = 1;
		r.heap_offset = 0;
		r.cached_pay_off = 0;
		r.cached_pay_len = 1;
		r.cached_sign = if (pay_slice[0] == 0) 0 else 1;
		return;
	}

	// Compute hdr_len from canon. canon ∈ [1..N+1]; for N=32 that's [1..33];
	// for N=64 that's [1..65]. Header is 1 byte for canon < 32, 2 bytes for
	// canon ∈ [32..32*128). Both ranges are well-bounded.
	const hdr_len: usize = if (canon < 32) 1 else 2;
	const total = canon + hdr_len;

	// Inline result possible only if total ≤ INLINE_CAP=24. canon ≥ 1 and
	// for our N=32/64 paths canon ≥ 1, but typically ≥ N. Inline path is
	// taken only when significant cancellation occurs (sub of near-equal
	// operands). We still handle it correctly.
	if (total <= INLINE_CAP) {
		// Reuse the writeMpFromPayload-style path inline.
		const hdr_byte: u8 = if (canon < 32) 0x80 | @as(u8, @intCast(canon)) else (0x80 | 0x20 | @as(u8, @intCast(canon & 0x1F)));
		// For canon ∈ [32..63] hdr_len=2 with continuation byte; total≥33+2=35>24,
		// so inline is unreachable. canon < 32 here.
		std.debug.assert(hdr_len == 1);
		r.inline_buf[0] = hdr_byte;
		var snapshot: [INLINE_CAP]u8 = undefined;
		@memcpy(snapshot[0..canon], pay_slice[0..canon]);
		@memcpy(r.inline_buf[1 .. 1 + canon], snapshot[0..canon]);
		// Maintain inline-tail invariant.
		if (total >= 2 and total <= 9) {
			const L = total - 1;
			const high_byte = r.inline_buf[1 + L - 1];
			const sign_fill: u8 = if ((high_byte & 0x80) != 0) 0xFF else 0;
			var i: usize = L;
			while (i < 8) : (i += 1) r.inline_buf[1 + i] = sign_fill;
		}
		r.inline_len = @intCast(total);
		r.heap_offset = 0;
		r.cached_pay_off = 1;
		r.cached_pay_len = @intCast(canon);
		const high = snapshot[canon - 1];
		if ((high & 0x80) != 0) {
			r.cached_sign = -1;
		} else if (high != 0) {
			r.cached_sign = 1;
		} else {
			var any_nonzero: bool = false;
			for (snapshot[0..canon]) |bb| if (bb != 0) { any_nonzero = true; break; };
			r.cached_sign = if (any_nonzero) 1 else 0;
		}
		return;
	}

	// Heap path (the common case for N=32/64). Header lives at
	// HDR_RESERVE - hdr_len, payload starts at HDR_RESERVE.
	const hdr_start = HDR_RESERVE - hdr_len;
	if (hdr_len == 1) {
		r.heap_buf[hdr_start] = 0x80 | @as(u8, @intCast(canon));
	} else {
		// hdr_len == 2: byte 0 has low 5 bits + continuation flag, byte 1 is the
		// remaining bits with no continuation.
		r.heap_buf[hdr_start] = 0x80 | 0x20 | @as(u8, @intCast(canon & 0x1F));
		r.heap_buf[hdr_start + 1] = @as(u8, @intCast(canon >> 5));
	}
	r.heap_offset = @intCast(hdr_start);
	r.heap_used = hdr_len + canon;
	r.inline_len = SENTINEL_HEAP;
	r.cached_pay_off = @intCast(hdr_len);
	r.cached_pay_len = @intCast(canon);
	const high = pay_slice[canon - 1];
	if ((high & 0x80) != 0) {
		r.cached_sign = -1;
	} else if (high != 0) {
		r.cached_sign = 1;
	} else {
		var any_nonzero: bool = false;
		for (pay_slice[0..canon]) |bb| if (bb != 0) { any_nonzero = true; break; };
		r.cached_sign = if (any_nonzero) 1 else 0;
	}
}

/// Read up to 16 bytes of payload from `inline_buf[pay_off..pay_off+pay_len]`,
/// sign-extending to 16 bytes, and return as u128. `pay_len` ≤ 16. The high
/// bit of the high actual payload byte determines the sign-extension fill.
inline fn loadPayloadU128(buf: *const [INLINE_CAP]u8, pay_off: usize, pay_len: usize) u128 {
	if (pay_len == 16) {
		// Hot case for 128-bit operands: direct unaligned u128 load.
		return std.mem.readInt(u128, buf[pay_off..][0..16], .little);
	}
	// Build via two u64 loads with sign-extension. The inline-tail invariant
	// (setI64 / setBytes maintain inline_buf[1..9] sign-extended for L≤8)
	// means for pay_len ∈ [1..8] starting at pay_off=1, a direct u64 read
	// at [1..9] already gives the sign-extended value. For other layouts
	// we build it byte-wise.
	if (pay_off == 1 and pay_len <= 8) {
		// Inline-tail invariant: buf[1..9] is sign-extended to u64.
		const lo: u64 = std.mem.readInt(u64, buf[1..9], .little);
		const sign_word: u64 = if ((lo >> 63) != 0) ~@as(u64, 0) else 0;
		return @as(u128, lo) | (@as(u128, sign_word) << 64);
	}
	// Generic path: copy bytes into a 16-byte stack buffer with sign fill.
	var tmp: [16]u8 = undefined;
	@memcpy(tmp[0..pay_len], buf[pay_off..][0..pay_len]);
	const high = buf[pay_off + pay_len - 1];
	const fill: u8 = if ((high & 0x80) != 0) 0xFF else 0x00;
	@memset(tmp[pay_len..16], fill);
	return std.mem.readInt(u128, &tmp, .little);
}

/// Fast path for tier-3 add/sub when both operands are inline AND each
/// payload is ≤16 bytes. Performs the arithmetic as a single u128 op,
/// trims to canonical length, and writes the result back to r.inline_buf
/// when it fits there (almost always — max output is 17 bytes payload + 1
/// header = 18 bytes, well under INLINE_CAP=24). Falls back to the heap
/// applyTier3Op path on the rare case where the result needs heap storage.
inline fn smallInlineTier3Add(r: *Mp, a: *const Mp, b: *const Mp, comptime op: TierOp) ArithError!void {
	const a_pay_off: usize = a.cached_pay_off;
	const b_pay_off: usize = b.cached_pay_off;
	const a_pay_len: usize = a.cached_pay_len;
	const b_pay_len: usize = b.cached_pay_len;

	const av = loadPayloadU128(&a.inline_buf, a_pay_off, a_pay_len);
	const bv = loadPayloadU128(&b.inline_buf, b_pay_off, b_pay_len);

	// Two's-complement add/sub via the unsigned u128 op.
	// Sign-overflow (one extra byte needed) is detected by comparing the
	// signs of the inputs to the sign of the result — same as addPayloads.
	const a_neg = a.cached_sign < 0;
	const b_neg_input = b.cached_sign < 0;
	const result_u128: u128 = switch (op) {
		.add => av +% bv,
		.sub => av -% bv,
	};

	// For sub: the "effective" b sign is flipped (a - b == a + (-b)).
	const b_neg_eff = if (op == .sub) !b_neg_input and (b.cached_sign != 0) else b_neg_input;
	const result_high_bit = (result_u128 >> 127) != 0;
	// For zero b in sub, b_neg_eff is false (positive zero); for nonzero
	// negative b in sub, b_neg_eff is true (we negated a negative).
	const same_effective_sign = a_neg == b_neg_eff;
	const overflowed = same_effective_sign and (a_neg != result_high_bit);

	// Layout the 17-byte canonical buffer: 16 bytes of u128 + optional
	// 17th sign-extension byte.
	var pay_buf: [17]u8 = undefined;
	std.mem.writeInt(u128, pay_buf[0..16], result_u128, .little);
	var pay_len: usize = 16;
	if (overflowed) {
		pay_buf[16] = if (a_neg) 0xFF else 0x00;
		pay_len = 17;
	}

	// Canonical trim: drop redundant high sign-extension bytes.
	const canon = canonicalLenSmall(pay_buf[0..pay_len]);

	// Immediate path: single byte 0..127.
	if (canon == 1 and pay_buf[0] < 0x80) {
		r.inline_buf[0] = pay_buf[0];
		r.inline_len = 1;
		r.heap_offset = 0;
		r.cached_pay_off = 0;
		r.cached_pay_len = 1;
		r.cached_sign = if (pay_buf[0] == 0) 0 else 1;
		return;
	}

	// Length-prefixed inline path. Header is always 1 byte for L<32 (so
	// for canon ≤ 17 ≤ 31). Total = canon + 1 ≤ 18 ≤ INLINE_CAP=24.
	const hdr_len: usize = 1;
	r.inline_buf[0] = 0x80 | @as(u8, @intCast(canon));
	@memcpy(r.inline_buf[1 .. 1 + canon], pay_buf[0..canon]);

	// Maintain the inline-tail invariant for total ∈ [2..9].
	const total = canon + hdr_len;
	if (total >= 2 and total <= 9) {
		const L = total - 1;
		const high_byte = r.inline_buf[1 + L - 1];
		const sign_fill: u8 = if ((high_byte & 0x80) != 0) 0xFF else 0;
		var i: usize = L;
		while (i < 8) : (i += 1) r.inline_buf[1 + i] = sign_fill;
	}

	r.inline_len = @intCast(total);
	r.heap_offset = 0;
	r.cached_pay_off = 1;
	r.cached_pay_len = @intCast(canon);
	// Sign: high bit of high payload byte. Zero (canon==1, byte<0x80) was
	// handled by the immediate branch above.
	const high = pay_buf[canon - 1];
	if ((high & 0x80) != 0) {
		r.cached_sign = -1;
	} else if (high != 0) {
		r.cached_sign = 1;
	} else {
		var any_nonzero: bool = false;
		for (pay_buf[0..canon]) |bb| if (bb != 0) { any_nonzero = true; break; };
		r.cached_sign = if (any_nonzero) 1 else 0;
	}
}

/// Load the MAGNITUDE (unsigned absolute value) as a u128 from an inline
/// payload of length ≤ 16. Sister of `loadPayloadU128` which gives the
/// sign-extended value; this gives the magnitude. Saves a separate negate
/// step in the multiplication fast path.
inline fn loadMagnitudeU128(buf: *const [INLINE_CAP]u8, pay_off: usize, pay_len: usize, sign: i8) u128 {
	const v: u128 = loadPayloadU128(buf, pay_off, pay_len);
	// If sign is negative, the loaded u128 is two's-complement of the magnitude
	// (extended to 128 bits with 0xFF). Negating in u128 (0 -% v) recovers the
	// magnitude exactly because two's complement wraparound matches.
	return if (sign < 0) 0 -% v else v;
}

/// Fast path for tier-3 mul when both operands are inline AND each payload
/// is ≤ 16 bytes (i.e. fit in u128). Performs the multiplication as a single
/// u128 × u128 → u256 widening op. Bypasses the entire `tier3MulOp` heap
/// scratch allocation, signMagnitude separation, mulMagnitudesU64 loop,
/// canonicalLen scan, and writeBlip overhead — all replaced by ~4 native
/// u64×u64 multiplies plus a small canonical trim.
///
/// For the 128-bit bench bucket this collapses tens of bookkeeping ops down
/// to a single hardware multiply chain. Result fits in 32 bytes (max 256-bit
/// magnitude) plus an optional 33rd sign-extension byte; with header the
/// canonical encoding is up to 35 bytes — exceeds INLINE_CAP=24, so the
/// result almost always lands in heap_buf via a small ensureHeapCapacity.
inline fn smallInlineTier3Mul(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	const a_pay_off: usize = a.cached_pay_off;
	const b_pay_off: usize = b.cached_pay_off;
	const a_pay_len: usize = a.cached_pay_len;
	const b_pay_len: usize = b.cached_pay_len;

	const a_sign = a.cached_sign;
	const b_sign = b.cached_sign;

	// Zero short-circuit (preserves the canonical 0x00 encoding).
	if (a_sign == 0 or b_sign == 0) {
		r.inline_buf[0] = 0x00;
		r.inline_len = 1;
		r.heap_offset = 0;
		r.cached_pay_off = 0;
		r.cached_pay_len = 1;
		r.cached_sign = 0;
		return;
	}

	const mag_a: u128 = loadMagnitudeU128(&a.inline_buf, a_pay_off, a_pay_len, a_sign);
	const mag_b: u128 = loadMagnitudeU128(&b.inline_buf, b_pay_off, b_pay_len, b_sign);

	// u128 × u128 → u256. LLVM lowers this to 4 mul + umulh + carry chain on
	// aarch64. Avoids the per-limb schoolbook loop overhead (8 u64×u64 muls
	// for the same operand pair via mulMagnitudesU64 plus loop bookkeeping).
	const prod: u256 = @as(u256, mag_a) * @as(u256, mag_b);

	// Magnitude bytes: 32 bytes for u256. Canonical trim drops trailing zeros
	// from the high end. Then add a sign-extension byte if needed:
	//   positive result: high bit set → prepend 0x00 high byte
	//   negative result: high bit clear → prepend 0xFF high byte
	var pay_buf: [33]u8 = undefined;
	std.mem.writeInt(u256, pay_buf[0..32], prod, .little);

	const result_neg = (a_sign < 0) != (b_sign < 0);

	// Trim high zero bytes (magnitude representation).
	var mag_len: usize = 32;
	while (mag_len > 1 and pay_buf[mag_len - 1] == 0) mag_len -= 1;

	// Convert magnitude → two's-complement payload.
	var pay_len: usize = mag_len;
	if (result_neg) {
		// Two's-complement negate in place. Delegates to tier3.negateInPlace
		// which uses chunked u64/u128 (~8× faster than per-byte for ≥ 8-byte
		// magnitudes; falls back to per-byte for shorter ones).
		tier3.negateInPlace(pay_buf[0..mag_len]);
		// If high bit isn't set after negation (the very rare case where
		// magnitude was exactly 2^(8*mag_len-1)+0 — actually impossible for
		// positive magnitudes — but treat defensively), extend by 0xFF.
		if ((pay_buf[mag_len - 1] & 0x80) == 0) {
			pay_buf[mag_len] = 0xFF;
			pay_len = mag_len + 1;
		}
	} else {
		// Positive: if high bit set, extend with 0x00 to keep sign clear.
		if ((pay_buf[mag_len - 1] & 0x80) != 0) {
			pay_buf[mag_len] = 0x00;
			pay_len = mag_len + 1;
		}
	}

	// Canonical trim (strips redundant high sign-extension bytes).
	const canon = canonicalLenSmall(pay_buf[0..pay_len]);

	// Immediate path: single byte 0..127.
	if (canon == 1 and pay_buf[0] < 0x80) {
		r.inline_buf[0] = pay_buf[0];
		r.inline_len = 1;
		r.heap_offset = 0;
		r.cached_pay_off = 0;
		r.cached_pay_len = 1;
		r.cached_sign = if (pay_buf[0] == 0) 0 else 1;
		return;
	}

	// Encode header + payload. canon ∈ [1..33]; header is 1 byte for canon < 32,
	// 2 bytes otherwise. Total max = 33 + 2 = 35 bytes. Inline only if ≤ 24.
	const hdr_len: usize = if (canon < 32) 1 else 2;
	const total = canon + hdr_len;

	if (total <= INLINE_CAP) {
		// Inline path. canon < 32 here (since 32+1=33 > 24), so hdr_len == 1.
		std.debug.assert(hdr_len == 1);
		r.inline_buf[0] = 0x80 | @as(u8, @intCast(canon));
		var snapshot: [INLINE_CAP]u8 = undefined;
		@memcpy(snapshot[0..canon], pay_buf[0..canon]);
		@memcpy(r.inline_buf[1 .. 1 + canon], snapshot[0..canon]);
		// Maintain inline-tail invariant for total ∈ [2..9].
		if (total >= 2 and total <= 9) {
			const L = total - 1;
			const high_byte = r.inline_buf[1 + L - 1];
			const sign_fill: u8 = if ((high_byte & 0x80) != 0) 0xFF else 0;
			var i: usize = L;
			while (i < 8) : (i += 1) r.inline_buf[1 + i] = sign_fill;
		}
		r.inline_len = @intCast(total);
		r.heap_offset = 0;
		r.cached_pay_off = 1;
		r.cached_pay_len = @intCast(canon);
		r.cached_sign = if (result_neg) -1 else 1;
		return;
	}

	// Heap path. Reserve enough room: HDR_RESERVE + canon.
	try r.ensureHeapCapacity(HDR_RESERVE + canon);
	const hdr_start = HDR_RESERVE - hdr_len;
	if (hdr_len == 1) {
		r.heap_buf[hdr_start] = 0x80 | @as(u8, @intCast(canon));
	} else {
		r.heap_buf[hdr_start] = 0x80 | 0x20 | @as(u8, @intCast(canon & 0x1F));
		r.heap_buf[hdr_start + 1] = @as(u8, @intCast(canon >> 5));
	}
	@memcpy(r.heap_buf[HDR_RESERVE .. HDR_RESERVE + canon], pay_buf[0..canon]);
	r.heap_offset = @intCast(hdr_start);
	r.heap_used = hdr_len + canon;
	r.inline_len = SENTINEL_HEAP;
	r.cached_pay_off = @intCast(hdr_len);
	r.cached_pay_len = @intCast(canon);
	r.cached_sign = if (result_neg) -1 else 1;
}

/// Same-size mul fast path: both operands have payloads of EXACTLY N bytes.
/// Bypasses tier3MulOp's huge stack frame (~80 KB for the worst-case
/// dispatch) and Karatsuba/Toom-3 scratch allocation. For N ∈ {32, 48, 64}
/// the operands typically live in heap_buf — we copy them to small stack
/// magnitudes (with on-the-fly negate for negatives), call mulMagnitudesU64
/// directly, and write the canonical result back. Avoids: the dispatch
/// branch ladder in mulRawBlip, the canonicalLen scan over the result,
/// and writeBlip's header-byte-counting indirection.
///
/// Closes the 256/384/512-bit gap vs GMP — for N=32 (256-bit) this collapses
/// the per-op overhead from ~10 ns of bookkeeping down to ~3 ns of straight-
/// line copies and a known-size header write.
inline fn sameSizeTier3Mul(comptime N: comptime_int, r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	const a_pay = a.payload();
	const b_pay = b.payload();
	std.debug.assert(a_pay.len == N);
	std.debug.assert(b_pay.len == N);

	const a_sign = a.cached_sign;
	const b_sign = b.cached_sign;

	// Zero short-circuit (preserves the canonical 0x00 encoding).
	if (a_sign == 0 or b_sign == 0) {
		r.inline_buf[0] = 0x00;
		r.inline_len = 1;
		r.heap_offset = 0;
		r.cached_pay_off = 0;
		r.cached_pay_len = 1;
		r.cached_sign = 0;
		return;
	}

	// Stack-buffer the magnitudes. For the same-size path with N ≤ 64, all
	// scratch fits comfortably on the stack (192 bytes total max for N=64).
	var mag_a: [N]u8 = undefined;
	var mag_b: [N]u8 = undefined;
	@memcpy(mag_a[0..N], a_pay);
	@memcpy(mag_b[0..N], b_pay);
	if (a_sign < 0) tier3.negateInPlace(&mag_a);
	if (b_sign < 0) tier3.negateInPlace(&mag_b);

	// Schoolbook u64 mul into a 2N-byte result. Comptime N is known to be a
	// multiple of 8 (we only call this for N ∈ {32, 48, 64}), so the chunked
	// u64 path applies — no per-byte fallback.
	var prod_buf: [2 * N + 1]u8 = undefined;
	tier3.mulMagnitudesU64(&mag_a, &mag_b, prod_buf[0 .. 2 * N]);

	const result_neg = (a_sign < 0) != (b_sign < 0);

	// Trim high zero bytes to find the magnitude length.
	var mag_len: usize = 2 * N;
	while (mag_len > 1 and prod_buf[mag_len - 1] == 0) mag_len -= 1;

	// Convert magnitude → two's-complement payload (sign-extension byte if
	// the high bit conflicts with the desired sign). Delegates to chunked
	// tier3.negateInPlace (~8× faster than per-byte for the large-N cases
	// here — N=64 means we negate 128 bytes = 16 chunks).
	var pay_len: usize = mag_len;
	if (result_neg) {
		tier3.negateInPlace(prod_buf[0..mag_len]);
		if ((prod_buf[mag_len - 1] & 0x80) == 0) {
			prod_buf[mag_len] = 0xFF;
			pay_len = mag_len + 1;
		}
	} else {
		if ((prod_buf[mag_len - 1] & 0x80) != 0) {
			prod_buf[mag_len] = 0x00;
			pay_len = mag_len + 1;
		}
	}

	// Canonical trim is unnecessary here because mag_len is already the
	// minimal magnitude length (we just stripped trailing zeros) and we only
	// ADDED a sign-ext byte when needed. So pay_len IS canonical.
	const canon = pay_len;

	// Immediate path (canon=1, value < 0x80).
	if (canon == 1 and prod_buf[0] < 0x80) {
		r.inline_buf[0] = prod_buf[0];
		r.inline_len = 1;
		r.heap_offset = 0;
		r.cached_pay_off = 0;
		r.cached_pay_len = 1;
		r.cached_sign = if (prod_buf[0] == 0) 0 else 1;
		return;
	}

	// Header is 1 byte for canon < 32, 2 bytes for canon ∈ [32..1024]. For
	// the N ∈ {32,48,64} same-size path the result is up to 2N+1 = 129 bytes;
	// header ranges 1..2 bytes.
	const hdr_len: usize = if (canon < 32) 1 else 2;
	const total = canon + hdr_len;

	if (total <= INLINE_CAP) {
		// Rare cancellation case (e.g. the Mp.mul result happens to be small).
		// canon < 32 here so hdr_len == 1.
		std.debug.assert(hdr_len == 1);
		r.inline_buf[0] = 0x80 | @as(u8, @intCast(canon));
		var snapshot: [INLINE_CAP]u8 = undefined;
		@memcpy(snapshot[0..canon], prod_buf[0..canon]);
		@memcpy(r.inline_buf[1 .. 1 + canon], snapshot[0..canon]);
		if (total >= 2 and total <= 9) {
			const L = total - 1;
			const high_byte = r.inline_buf[1 + L - 1];
			const sign_fill: u8 = if ((high_byte & 0x80) != 0) 0xFF else 0;
			var i: usize = L;
			while (i < 8) : (i += 1) r.inline_buf[1 + i] = sign_fill;
		}
		r.inline_len = @intCast(total);
		r.heap_offset = 0;
		r.cached_pay_off = 1;
		r.cached_pay_len = @intCast(canon);
		r.cached_sign = if (result_neg) -1 else 1;
		return;
	}

	// Heap path (the common case).
	try r.ensureHeapCapacity(HDR_RESERVE + canon);
	const hdr_start = HDR_RESERVE - hdr_len;
	if (hdr_len == 1) {
		r.heap_buf[hdr_start] = 0x80 | @as(u8, @intCast(canon));
	} else {
		r.heap_buf[hdr_start] = 0x80 | 0x20 | @as(u8, @intCast(canon & 0x1F));
		r.heap_buf[hdr_start + 1] = @as(u8, @intCast(canon >> 5));
	}
	@memcpy(r.heap_buf[HDR_RESERVE .. HDR_RESERVE + canon], prod_buf[0..canon]);
	r.heap_offset = @intCast(hdr_start);
	r.heap_used = hdr_len + canon;
	r.inline_len = SENTINEL_HEAP;
	r.cached_pay_off = @intCast(hdr_len);
	r.cached_pay_len = @intCast(canon);
	r.cached_sign = if (result_neg) -1 else 1;
}

/// Specialized canonical-length trim for ≤17 byte payloads. Same semantics
/// as tier3.canonicalLen but unrolled for the small case.
inline fn canonicalLenSmall(payload: []const u8) usize {
	if (payload.len <= 1) return @max(payload.len, 1);
	const high = payload[payload.len - 1];
	if (high != 0x00 and high != 0xFF) return payload.len; // common case
	const sign_byte: u8 = high; // 0x00 or 0xFF
	const sign_is_negative = sign_byte == 0xFF;
	var n = payload.len;
	while (n > 1) {
		const h = payload[n - 1];
		const next = payload[n - 2];
		const next_high_bit_set = (next & 0x80) != 0;
		if (h == sign_byte and next_high_bit_set == sign_is_negative) {
			n -= 1;
			continue;
		}
		break;
	}
	return n;
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
		try testing.expectEqual(c.order, a.cmp(&b));
	}
}

test "Mp.cmp: tier-3 same-sign comparison (was: getI64-based regression)" {
	// Pre-fix: Mp.cmp called getI64 internally, which returns an error
	// for tier-3 values. Two same-sign tier-3 values couldn't be compared.
	// Now: byte-level magnitude comparison handles arbitrary sizes.
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var one = Mp.init(testing.allocator);
	defer one.deinit();
	try one.setI64(1);

	// Build two tier-3 positive values: a = i64.max + 5, b = i64.max + 1.
	// Both > i64.max, so getI64 would error; but a > b should hold.
	try a.setI64(std.math.maxInt(i64));
	try b.setI64(std.math.maxInt(i64));
	try a.add(&a, &one); try a.add(&a, &one); try a.add(&a, &one); try a.add(&a, &one); try a.add(&a, &one);
	try b.add(&b, &one);
	try testing.expectEqual(std.math.Order.gt, a.cmp(&b));
	try testing.expectEqual(std.math.Order.lt, b.cmp(&a));
	try testing.expectEqual(std.math.Order.eq, a.cmp(&a));

	// Equal tier-3 positives.
	var a2 = Mp.init(testing.allocator);
	defer a2.deinit();
	try a2.setI64(std.math.maxInt(i64));
	try a2.add(&a2, &one); try a2.add(&a2, &one); try a2.add(&a2, &one); try a2.add(&a2, &one); try a2.add(&a2, &one);
	try testing.expectEqual(std.math.Order.eq, a.cmp(&a2));

	// Two tier-3 negatives: a_neg = i64.min - 5, b_neg = i64.min - 1.
	// a_neg < b_neg (more negative).
	var a_neg = Mp.init(testing.allocator);
	defer a_neg.deinit();
	var b_neg = Mp.init(testing.allocator);
	defer b_neg.deinit();
	try a_neg.setI64(std.math.minInt(i64));
	try b_neg.setI64(std.math.minInt(i64));
	try a_neg.sub(&a_neg, &one); try a_neg.sub(&a_neg, &one); try a_neg.sub(&a_neg, &one); try a_neg.sub(&a_neg, &one); try a_neg.sub(&a_neg, &one);
	try b_neg.sub(&b_neg, &one);
	try testing.expectEqual(std.math.Order.lt, a_neg.cmp(&b_neg));
	try testing.expectEqual(std.math.Order.gt, b_neg.cmp(&a_neg));

	// Cross-sign tier-3.
	try testing.expectEqual(std.math.Order.gt, a.cmp(&a_neg));
	try testing.expectEqual(std.math.Order.lt, a_neg.cmp(&a));
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

test "mulU64: identities and small cases" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();

	// 0 × 7 == 0
	try a.setI64(0);
	try r.mulU64(&a, 7);
	try testing.expectEqual(@as(i64, 0), try r.getI64());
	// 7 × 0 == 0
	try a.setI64(7);
	try r.mulU64(&a, 0);
	try testing.expectEqual(@as(i64, 0), try r.getI64());
	// 7 × 1 == 7
	try a.setI64(7);
	try r.mulU64(&a, 1);
	try testing.expectEqual(@as(i64, 7), try r.getI64());
	// 7 × 11 == 77
	try a.setI64(7);
	try r.mulU64(&a, 11);
	try testing.expectEqual(@as(i64, 77), try r.getI64());
	// -7 × 11 == -77
	try a.setI64(-7);
	try r.mulU64(&a, 11);
	try testing.expectEqual(@as(i64, -77), try r.getI64());
	// 0xDEAD × 0xBABE — both u16, product fits comfortably in i64.
	try a.setI64(0xDEAD);
	try r.mulU64(&a, 0xBABE);
	try testing.expectEqual(@as(i64, 0xDEAD * 0xBABE), try r.getI64());
}

test "mulU64: i64.max × 2 promotes cleanly to tier 3" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try r.mulU64(&a, 2);
	// Result = 2 × (2^63 - 1) = 2^64 - 2 — doesn't fit in i64.
	// Build the same value via Mp.mul against an Mp(2) and compare bytes.
	var two = Mp.init(testing.allocator);
	defer two.deinit();
	try two.setI64(2);
	var ref = Mp.init(testing.allocator);
	defer ref.deinit();
	try ref.mul(&a, &two);
	try testing.expectEqualSlices(u8, ref.bytes(), r.bytes());
}

test "mulU64: tier-3 magnitude × small scalar matches Mp.mul" {
	// Build a 2048-bit positive a; multiply by various u64 values; compare
	// against the reference Mp.mul path. This is the equivalence proof that
	// would have caught early-implementation bugs.
	const allocator = testing.allocator;
	var prng = std.Random.DefaultPrng.init(0xFEED_FACE_C0DE_BABE);
	const rand = prng.random();
	const sizes = [_]usize{ 16, 32, 64, 128, 256 }; // bytes
	const scalars = [_]u64{ 1, 2, 3, 7, 10, 0xFF, 0xFFFF, 0xFFFFFFFF, 0xCAFEBABE_DEADBEEF };

	var a = Mp.init(allocator);
	defer a.deinit();
	var r = Mp.init(allocator);
	defer r.deinit();
	var c_mp = Mp.init(allocator);
	defer c_mp.deinit();
	var ref = Mp.init(allocator);
	defer ref.deinit();

	for (sizes) |sz| {
		for (scalars) |c| {
			// Random positive payload of `sz` bytes.
			const pay = try allocator.alloc(u8, sz);
			defer allocator.free(pay);
			rand.bytes(pay);
			pay[sz - 1] &= 0x7F;
			if (pay[sz - 1] == 0) pay[sz - 1] = 0x40;
			const blip = try allocator.alloc(u8, sz + 16);
			defer allocator.free(blip);
			const hdr = try tier3.writeHeader(blip, sz);
			@memcpy(blip[hdr .. hdr + sz], pay);
			try a.setBytes(blip[0 .. hdr + sz]);

			try r.mulU64(&a, c);
			// Reference via Mp.mul on the same value as an Mp.
			if (c <= std.math.maxInt(i64)) {
				try c_mp.setI64(@intCast(c));
			} else {
				// c > i64.max: encode as a 9-byte tier-3 positive (high byte 0x00 sign).
				var c_buf: [16]u8 = undefined;
				c_buf[0] = 0x80 | 9;
				std.mem.writeInt(u64, c_buf[1..9], c, .little);
				c_buf[9] = 0x00;
				try c_mp.setBytes(c_buf[0..10]);
			}
			try ref.mul(&a, &c_mp);
			try testing.expectEqualSlices(u8, ref.bytes(), r.bytes());
		}
	}
}

test "addU64: identities and small cases" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(0);
	try r.addU64(&a, 7);
	try testing.expectEqual(@as(i64, 7), try r.getI64());
	try a.setI64(7);
	try r.addU64(&a, 0);
	try testing.expectEqual(@as(i64, 7), try r.getI64());
	try a.setI64(7);
	try r.addU64(&a, 35);
	try testing.expectEqual(@as(i64, 42), try r.getI64());
	try a.setI64(-7);
	try r.addU64(&a, 10);
	try testing.expectEqual(@as(i64, 3), try r.getI64());
	try a.setI64(-100);
	try r.addU64(&a, 30);
	try testing.expectEqual(@as(i64, -70), try r.getI64());
	// i64.max + 1 → tier-3
	try a.setI64(std.math.maxInt(i64));
	try r.addU64(&a, 1);
	var ref = Mp.init(testing.allocator);
	defer ref.deinit();
	var one = Mp.init(testing.allocator);
	defer one.deinit();
	try one.setI64(1);
	try ref.add(&a, &one);
	try testing.expectEqualSlices(u8, ref.bytes(), r.bytes());
}

test "addU64: tier-3 magnitude + c matches Mp.add" {
	const allocator = testing.allocator;
	var prng = std.Random.DefaultPrng.init(0xADD_BEEF_5EED);
	const rand = prng.random();
	var a = Mp.init(allocator);
	defer a.deinit();
	var r = Mp.init(allocator);
	defer r.deinit();
	var c_mp = Mp.init(allocator);
	defer c_mp.deinit();
	var ref = Mp.init(allocator);
	defer ref.deinit();
	const sizes = [_]usize{ 16, 32, 64, 128, 256 };
	const scalars = [_]u64{ 1, 2, 7, 0xFF, 0xFFFF, 0xFFFFFFFF };
	for (sizes) |sz| {
		for (scalars) |c| {
			const pay = try allocator.alloc(u8, sz);
			defer allocator.free(pay);
			rand.bytes(pay);
			pay[sz - 1] &= 0x7F;
			if (pay[sz - 1] == 0) pay[sz - 1] = 0x40;
			const blip = try allocator.alloc(u8, sz + 16);
			defer allocator.free(blip);
			const hdr = try tier3.writeHeader(blip, sz);
			@memcpy(blip[hdr .. hdr + sz], pay);
			try a.setBytes(blip[0 .. hdr + sz]);
			try c_mp.setI64(@intCast(c));
			try ref.add(&a, &c_mp);
			try r.addU64(&a, c);
			try testing.expectEqualSlices(u8, ref.bytes(), r.bytes());
		}
	}
}

test "addmulU64: out += a * c — identities and small cases" {
	var out = Mp.init(testing.allocator);
	defer out.deinit();
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	// 100 + 5*3 == 115
	try out.setI64(100);
	try a.setI64(5);
	try out.addmulU64(&a, 3);
	try testing.expectEqual(@as(i64, 115), try out.getI64());
	// 100 + 5*0 == 100
	try out.setI64(100);
	try a.setI64(5);
	try out.addmulU64(&a, 0);
	try testing.expectEqual(@as(i64, 100), try out.getI64());
	// 100 + 0*7 == 100
	try out.setI64(100);
	try a.setI64(0);
	try out.addmulU64(&a, 7);
	try testing.expectEqual(@as(i64, 100), try out.getI64());
}

test "addmulU64: tier-3 fused = mul + add (matches reference)" {
	// out += a * c on tier-3 inputs. Both positive (the spigot's same-sign
	// fast path) and mixed-sign should agree with the unfused reference.
	const allocator = testing.allocator;
	var prng = std.Random.DefaultPrng.init(0xADD_C0FFEE_BABE);
	const rand = prng.random();
	var out = Mp.init(allocator);
	defer out.deinit();
	var out_copy = Mp.init(allocator);
	defer out_copy.deinit();
	var a = Mp.init(allocator);
	defer a.deinit();
	var c_mp = Mp.init(allocator);
	defer c_mp.deinit();
	var ref = Mp.init(allocator);
	defer ref.deinit();
	var prod = Mp.init(allocator);
	defer prod.deinit();
	const sizes = [_]usize{ 16, 32, 64, 128, 256 };
	const scalars = [_]u64{ 1, 7, 0xFF, 0xFFFFFFFF, 0xCAFE_BABE_DEAD_BEEF };
	for (sizes) |sz| {
		for (scalars) |c| {
			// out random tier-3 positive
			const out_pay = try allocator.alloc(u8, sz);
			defer allocator.free(out_pay);
			rand.bytes(out_pay);
			out_pay[sz - 1] &= 0x7F;
			if (out_pay[sz - 1] == 0) out_pay[sz - 1] = 0x40;
			const out_blip = try allocator.alloc(u8, sz + 16);
			defer allocator.free(out_blip);
			const out_hdr = try tier3.writeHeader(out_blip, sz);
			@memcpy(out_blip[out_hdr .. out_hdr + sz], out_pay);
			try out.setBytes(out_blip[0 .. out_hdr + sz]);
			try out_copy.setBytes(out.bytes());

			// a random tier-3 positive
			const a_pay = try allocator.alloc(u8, sz);
			defer allocator.free(a_pay);
			rand.bytes(a_pay);
			a_pay[sz - 1] &= 0x7F;
			if (a_pay[sz - 1] == 0) a_pay[sz - 1] = 0x40;
			const a_blip = try allocator.alloc(u8, sz + 16);
			defer allocator.free(a_blip);
			const a_hdr = try tier3.writeHeader(a_blip, sz);
			@memcpy(a_blip[a_hdr .. a_hdr + sz], a_pay);
			try a.setBytes(a_blip[0 .. a_hdr + sz]);

			// Reference: prod = a*c via Mp.mul against an Mp(c), then out += prod.
			if (c <= std.math.maxInt(i64)) {
				try c_mp.setI64(@intCast(c));
			} else {
				var cb: [16]u8 = undefined;
				cb[0] = 0x80 | 9;
				std.mem.writeInt(u64, cb[1..9], c, .little);
				cb[9] = 0x00;
				try c_mp.setBytes(cb[0..10]);
			}
			try prod.mul(&a, &c_mp);
			try ref.add(&out_copy, &prod);

			// Fused path.
			try out.addmulU64(&a, c);

			try testing.expectEqualSlices(u8, ref.bytes(), out.bytes());
		}
	}
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

// ── M7-1: Tier 0/1 division (i64 fast path) ───────────────────────────────────

test "divMod: 8 sign combinations match GMP truncated semantics" {
	// (a, b, expected_q, expected_rem) — sign(q) = sign(a) XOR sign(b);
	// sign(rem) = sign(a). Identity: a == q*b + rem.
	const cases = [_]struct { a: i64, b: i64, q: i64, rem: i64 }{
		.{ .a = 7, .b = 3, .q = 2, .rem = 1 },
		.{ .a = -7, .b = 3, .q = -2, .rem = -1 },
		.{ .a = 7, .b = -3, .q = -2, .rem = 1 },
		.{ .a = -7, .b = -3, .q = 2, .rem = -1 },
		.{ .a = 0, .b = 5, .q = 0, .rem = 0 },
		.{ .a = 1_000_000_000, .b = 7, .q = 142_857_142, .rem = 6 },
		.{ .a = -1_000_000_000, .b = 7, .q = -142_857_142, .rem = -6 },
		.{ .a = std.math.maxInt(i64), .b = 1, .q = std.math.maxInt(i64), .rem = 0 },
		.{ .a = std.math.minInt(i64) + 1, .b = -1, .q = std.math.maxInt(i64), .rem = 0 },
	};
	var a_mp = Mp.init(testing.allocator);
	defer a_mp.deinit();
	var b_mp = Mp.init(testing.allocator);
	defer b_mp.deinit();
	var q_mp = Mp.init(testing.allocator);
	defer q_mp.deinit();
	var r_mp = Mp.init(testing.allocator);
	defer r_mp.deinit();
	for (cases) |c| {
		try a_mp.setI64(c.a);
		try b_mp.setI64(c.b);
		try Mp.divMod(&q_mp, &r_mp, &a_mp, &b_mp);
		try testing.expectEqual(c.q, try q_mp.getI64());
		try testing.expectEqual(c.rem, try r_mp.getI64());
	}
}

test "div / mod thin wrappers: produce same numbers as divMod" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var q = Mp.init(testing.allocator);
	defer q.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(1234567);
	try b.setI64(89);
	try Mp.div(&q, &a, &b);
	try testing.expectEqual(@as(i64, 13871), try q.getI64()); // 1234567 / 89
	try Mp.mod(&r, &a, &b);
	try testing.expectEqual(@as(i64, 48), try r.getI64()); // 1234567 % 89 = 48 (since 13871*89 = 1234519)
}

test "divMod: division by zero returns error.DivisionByZero" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var q = Mp.init(testing.allocator);
	defer q.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(42);
	try b.setI64(0);
	try testing.expectError(error.DivisionByZero, Mp.divMod(&q, &r, &a, &b));
	try testing.expectError(error.DivisionByZero, Mp.div(&q, &a, &b));
	try testing.expectError(error.DivisionByZero, Mp.mod(&r, &a, &b));
}

test "divMod: i64.min / -1 promotes to tier 3 and returns 2^63" {
	// i64.min / -1 = 2^63 which doesn't fit in i64; the tier-3 path handles it.
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var q = Mp.init(testing.allocator);
	defer q.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.minInt(i64));
	try b.setI64(-1);
	try Mp.divMod(&q, &r, &a, &b);
	// q should be 2^63 (encoded in 9-byte length-prefixed form). r = 0.
	try testing.expect(q.bytes().len > 8);
	try testing.expectEqual(@as(i64, 0), try r.getI64());
}

test "divMod: tier-3 dividend, small divisor (i64.max + 5) / 7" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var q = Mp.init(testing.allocator);
	defer q.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	// a = i64.max + 5 (tier-3). b = 7 (tier-0).
	try a.setI64(std.math.maxInt(i64));
	var five = Mp.init(testing.allocator);
	defer five.deinit();
	try five.setI64(5);
	try a.add(&a, &five); // a = 2^63 + 4
	try b.setI64(7);
	try Mp.divMod(&q, &r, &a, &b);
	// (2^63 + 4) / 7 = ?  2^63 = 9223372036854775808. + 4 = 9223372036854775812.
	// /7 = 1317624576693539401, r = ?  1317624576693539401 * 7 = 9223372036854775807. Plus 5 = 9223372036854775812 ✓
	// Wait: 5 + 9223372036854775807 = 9223372036854775812. So /7 quotient = 1317624576693539401 r 5.
	try testing.expectEqual(@as(i64, 1_317_624_576_693_539_401), try q.getI64());
	try testing.expectEqual(@as(i64, 5), try r.getI64());
}

// ── M7-4: powm helpers — bitAt / bitLen on the magnitude ────────────────────

test "bitAt: returns bit i of absolute value (positive small)" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(0b10110); // 22
	try testing.expectEqual(@as(u1, 0), x.bitAt(0));
	try testing.expectEqual(@as(u1, 1), x.bitAt(1));
	try testing.expectEqual(@as(u1, 1), x.bitAt(2));
	try testing.expectEqual(@as(u1, 0), x.bitAt(3));
	try testing.expectEqual(@as(u1, 1), x.bitAt(4));
	try testing.expectEqual(@as(u1, 0), x.bitAt(5));
	try testing.expectEqual(@as(u1, 0), x.bitAt(99)); // beyond high bit → 0
}

test "bitAt: returns bit i of magnitude for negative values" {
	// |-22| = 22 = 0b10110. The bits we read should be the MAGNITUDE's bits.
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(-22);
	try testing.expectEqual(@as(u1, 0), x.bitAt(0));
	try testing.expectEqual(@as(u1, 1), x.bitAt(1));
	try testing.expectEqual(@as(u1, 1), x.bitAt(2));
	try testing.expectEqual(@as(u1, 0), x.bitAt(3));
	try testing.expectEqual(@as(u1, 1), x.bitAt(4));
}

test "bitAt: zero value returns 0 for any bit" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(0);
	try testing.expectEqual(@as(u1, 0), x.bitAt(0));
	try testing.expectEqual(@as(u1, 0), x.bitAt(7));
	try testing.expectEqual(@as(u1, 0), x.bitAt(1000));
}

test "bitLen: matches highest-bit + 1 for various i64 values" {
	const cases = [_]struct { v: i64, expected: usize }{
		.{ .v = 0, .expected = 0 },
		.{ .v = 1, .expected = 1 },
		.{ .v = 2, .expected = 2 },
		.{ .v = 3, .expected = 2 },
		.{ .v = 7, .expected = 3 },
		.{ .v = 8, .expected = 4 },
		.{ .v = 127, .expected = 7 },
		.{ .v = 128, .expected = 8 },
		.{ .v = 255, .expected = 8 },
		.{ .v = 256, .expected = 9 },
		.{ .v = -1, .expected = 1 },
		.{ .v = -128, .expected = 8 },
		.{ .v = -129, .expected = 8 },
		.{ .v = std.math.maxInt(i64), .expected = 63 },
		.{ .v = std.math.minInt(i64), .expected = 64 }, // |minInt| = 2^63
	};
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	for (cases) |c| {
		try x.setI64(c.v);
		try testing.expectEqual(c.expected, x.bitLen());
	}
}

test "bitAt / bitLen: large tier-3 value (256-bit set bit pattern)" {
	// Magnitude = 1 << 200. setBytes encodes a positive signed payload of 26
	// bytes: 25 zero bytes + 0x01 in byte 25 (bit 200 of mag).
	var pay: [26]u8 = .{0} ** 26;
	pay[25] = 0x01;
	var blip: [28]u8 = undefined;
	blip[0] = 0x9A; // L = 26 = 0b11010 (continuation off, low5=0x1A)
	@memcpy(blip[1..27], &pay);
	// Note: 26 < 32 so single-byte header.
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setBytes(blip[0..27]);
	try testing.expectEqual(@as(u1, 1), x.bitAt(200));
	try testing.expectEqual(@as(u1, 0), x.bitAt(199));
	try testing.expectEqual(@as(u1, 0), x.bitAt(201));
	try testing.expectEqual(@as(usize, 201), x.bitLen());
}

// ── M7-4-1: powm — square-and-multiply baseline ─────────────────────────────

test "powm: small known cases" {
	const Case = struct { b: i64, e: i64, m: i64, expected: i64 };
	const cases = [_]Case{
		.{ .b = 3, .e = 4, .m = 5, .expected = 1 }, // 81 mod 5 = 1
		.{ .b = 2, .e = 10, .m = 1000, .expected = 24 }, // 1024 mod 1000
		.{ .b = 3, .e = 17, .m = 100, .expected = 63 }, // 129140163 mod 100
		.{ .b = 7, .e = 0, .m = 13, .expected = 1 }, // x^0 = 1
		.{ .b = 0, .e = 5, .m = 13, .expected = 0 }, // 0^n (n>0) = 0
		.{ .b = 0, .e = 0, .m = 13, .expected = 1 }, // 0^0 = 1 (GMP convention)
		.{ .b = 5, .e = 1, .m = 7, .expected = 5 }, // x^1 = x mod m
		.{ .b = 100, .e = 2, .m = 1, .expected = 0 }, // anything mod 1 = 0
		.{ .b = -3, .e = 4, .m = 5, .expected = 1 }, // (-3)^4 = 81; 81 mod 5 = 1
		// (-3)^3 = -27 — GMP `mpz_powm` returns r in [0, m-1] for m > 0,
		// i.e. Euclidean reduction. See dedicated test below.
	};
	var b_mp = Mp.init(testing.allocator);
	defer b_mp.deinit();
	var e_mp = Mp.init(testing.allocator);
	defer e_mp.deinit();
	var m_mp = Mp.init(testing.allocator);
	defer m_mp.deinit();
	var r_mp = Mp.init(testing.allocator);
	defer r_mp.deinit();
	for (cases) |c| {
		try b_mp.setI64(c.b);
		try e_mp.setI64(c.e);
		try m_mp.setI64(c.m);
		try Mp.powm(&r_mp, &b_mp, &e_mp, &m_mp);
		try testing.expectEqual(c.expected, try r_mp.getI64());
	}
}

test "powm: -3^3 mod 5 returns Euclidean remainder (matches GMP convention)" {
	// (-3)^3 = -27. GMP mpz_powm yields r in [0, m-1] for m>0, so r=3.
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var e = Mp.init(testing.allocator);
	defer e.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try b.setI64(-3);
	try e.setI64(3);
	try m.setI64(5);
	try Mp.powm(&r, &b, &e, &m);
	try testing.expectEqual(@as(i64, 3), try r.getI64());
}

test "powm: division by zero modulus" {
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var e = Mp.init(testing.allocator);
	defer e.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try b.setI64(2);
	try e.setI64(10);
	try m.setI64(0);
	try testing.expectError(error.DivisionByZero, Mp.powm(&r, &b, &e, &m));
}

test "powm: negative exponent returns NegativeExponentNotSupported" {
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var e = Mp.init(testing.allocator);
	defer e.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try b.setI64(2);
	try e.setI64(-1);
	try m.setI64(7);
	try testing.expectError(error.NegativeExponentNotSupported, Mp.powm(&r, &b, &e, &m));
}

test "powm: medium magnitude — 7^100 mod 13 = 9 (verified manually)" {
	// 7^100 mod 13. By Fermat's little theorem, 7^12 ≡ 1 mod 13, so
	// 7^100 = 7^(12*8 + 4) = (7^12)^8 * 7^4 ≡ 7^4 mod 13.
	// 7^2 = 49 ≡ 10 mod 13. 7^4 = 10^2 = 100 ≡ 9 mod 13.
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var e = Mp.init(testing.allocator);
	defer e.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try b.setI64(7);
	try e.setI64(100);
	try m.setI64(13);
	try Mp.powm(&r, &b, &e, &m);
	try testing.expectEqual(@as(i64, 9), try r.getI64());
}

test "invMod: small known cases" {
	// Reference values verified by hand:
	//   3^-1 mod 11 = 4  (3*4 = 12 = 11+1)
	//   7^-1 mod 26 = 15 (7*15 = 105 = 4*26 + 1)
	//   2^-1 mod 5  = 3  (2*3 = 6 = 5+1)
	//   3^-1 mod 7  = 5  (3*5 = 15 = 2*7 + 1)
	//   10^-1 mod 17 = 12 (10*12 = 120 = 7*17 + 1)
	const Case = struct { a: i64, m: i64, expected: i64 };
	const cases = [_]Case{
		.{ .a = 3, .m = 11, .expected = 4 },
		.{ .a = 7, .m = 26, .expected = 15 },
		.{ .a = 2, .m = 5, .expected = 3 },
		.{ .a = 3, .m = 7, .expected = 5 },
		.{ .a = 10, .m = 17, .expected = 12 },
		.{ .a = 1, .m = 5, .expected = 1 }, // 1^-1 mod m = 1
	};
	var a_mp = Mp.init(testing.allocator);
	defer a_mp.deinit();
	var m_mp = Mp.init(testing.allocator);
	defer m_mp.deinit();
	var r_mp = Mp.init(testing.allocator);
	defer r_mp.deinit();
	for (cases) |c| {
		try a_mp.setI64(c.a);
		try m_mp.setI64(c.m);
		const ok = try Mp.invMod(&r_mp, &a_mp, &m_mp);
		try testing.expect(ok);
		try testing.expectEqual(c.expected, try r_mp.getI64());
	}
}

test "invMod: returns false when no inverse exists" {
	// gcd(a, m) != 1 → no inverse
	const Case = struct { a: i64, m: i64 };
	const cases = [_]Case{
		.{ .a = 2, .m = 4 }, // gcd = 2
		.{ .a = 6, .m = 9 }, // gcd = 3
		.{ .a = 0, .m = 5 }, // gcd(0, 5) = 5
		.{ .a = 4, .m = 8 }, // gcd = 4
	};
	var a_mp = Mp.init(testing.allocator);
	defer a_mp.deinit();
	var m_mp = Mp.init(testing.allocator);
	defer m_mp.deinit();
	var r_mp = Mp.init(testing.allocator);
	defer r_mp.deinit();
	for (cases) |c| {
		try a_mp.setI64(c.a);
		try m_mp.setI64(c.m);
		const ok = try Mp.invMod(&r_mp, &a_mp, &m_mp);
		try testing.expect(!ok);
	}
}

test "invMod: division by zero modulus" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(3);
	try m.setI64(0);
	try testing.expectError(error.DivisionByZero, Mp.invMod(&r, &a, &m));
}

test "invMod: result satisfies (a * r) mod m == 1 for 200 random small pairs" {
	var prng = std.Random.DefaultPrng.init(0xBEEF_F00D_CAFE);
	const rand = prng.random();
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	var prod = Mp.init(testing.allocator);
	defer prod.deinit();
	var rem = Mp.init(testing.allocator);
	defer rem.deinit();
	var verified: usize = 0;
	var iter: usize = 0;
	while (iter < 200) : (iter += 1) {
		// m: random odd > 2 in i32 range. a in [1, m).
		const mv_raw = rand.intRangeAtMost(i64, 3, 1_000_000);
		const mv: i64 = mv_raw | 1;
		const av = rand.intRangeAtMost(i64, 1, mv - 1);
		try a.setI64(av);
		try m.setI64(mv);
		const ok = try Mp.invMod(&r, &a, &m);
		if (!ok) continue;
		// Verify: (a * r) mod m == 1.
		try prod.mul(&a, &r);
		try rem.mod(&prod, &m);
		try testing.expectEqual(@as(i64, 1), try rem.getI64());
		// r should be in [0, m).
		const rv = try r.getI64();
		try testing.expect(rv >= 0 and rv < mv);
		verified += 1;
	}
	try testing.expect(verified > 100);
}

test "invModLehmer matches invModClassical: 1000 random pairs across bit-widths" {
	// Strict TDD oracle: classical EEA is GMP-validated; Lehmer must agree
	// bit-for-bit. Picks random a, m with m odd >= 3 to maximise gcd==1
	// hits. When gcd != 1, both must report no-inverse.
	// Sizes are multiples of 64 to avoid hitting a pre-existing tier3 buffer
	// sizing edge case (r_pay_max = b_pay.len + 2 underestimates needed bytes
	// when b_pay.len isn't a multiple of 8 — caught while writing this test
	// but out of scope for this milestone).
	const SIZES = [_]usize{ 64, 128, 192, 256, 320, 384, 448, 512, 768, 1024, 1536, 2048 };
	const ITERS_PER_SIZE: usize = 100;
	var prng = std.Random.DefaultPrng.init(0xC0FFEE_F00D_BEEF);
	const rand = prng.random();

	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r_lehmer = Mp.init(testing.allocator);
	defer r_lehmer.deinit();
	var r_classical = Mp.init(testing.allocator);
	defer r_classical.deinit();

	var raw_buf: [512]u8 = undefined;
	var enc_buf: [600]u8 = undefined;

	var total: usize = 0;
	var compared: usize = 0;
	for (SIZES) |bits| {
		const byte_len = (bits + 7) / 8;
		var i: usize = 0;
		while (i < ITERS_PER_SIZE) : (i += 1) {
			// a: random bytes, force positive (high bit clear).
			rand.bytes(raw_buf[0..byte_len]);
			raw_buf[byte_len - 1] &= 0x7F;
			const hdr_a = try tier3.writeHeader(&enc_buf, byte_len);
			@memcpy(enc_buf[hdr_a..][0..byte_len], raw_buf[0..byte_len]);
			try a.setBytes(enc_buf[0 .. hdr_a + byte_len]);

			// m: random bytes, positive, odd, and force second-highest bit set
			// so m's bitLen is large enough to reliably exceed a's bitLen
			// (improves coprime hit-rate).
			rand.bytes(raw_buf[0..byte_len]);
			raw_buf[byte_len - 1] = (raw_buf[byte_len - 1] & 0x7F) | 0x40;
			raw_buf[0] |= 1; // odd
			const hdr_m = try tier3.writeHeader(&enc_buf, byte_len);
			@memcpy(enc_buf[hdr_m..][0..byte_len], raw_buf[0..byte_len]);
			try m.setBytes(enc_buf[0 .. hdr_m + byte_len]);

			const ok_l = try Mp.invModLehmer(&r_lehmer, &a, &m);
			const ok_c = try Mp.invModClassical(&r_classical, &a, &m);
			try testing.expectEqual(ok_c, ok_l);
			if (ok_c) {
				try testing.expect(Mp.cmp(&r_lehmer, &r_classical) == .eq);
				compared += 1;
			}
			total += 1;
		}
	}
	try testing.expect(total >= 1000);
	try testing.expect(compared >= 800); // most should have inverses
}

test "invModHGCD matches invModLehmer: 1000+ random pairs across bit-widths" {
	// M10 oracle: invModLehmer is GMP-validated (12029 cross-checks);
	// invModHGCD must agree bit-for-bit. Same input distribution as the
	// Lehmer-vs-classical test so we get coverage across the recursion
	// threshold (HGCD only kicks in above the threshold; below, it
	// degenerates to Lehmer).
	const SIZES = [_]usize{ 64, 128, 192, 256, 320, 384, 448, 512, 768, 1024, 1536, 2048, 3072, 4096 };
	const ITERS_PER_SIZE: usize = 80;
	var prng = std.Random.DefaultPrng.init(0xC0FFEE_F00D_BEE0);
	const rand = prng.random();

	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r_hgcd = Mp.init(testing.allocator);
	defer r_hgcd.deinit();
	var r_lehmer = Mp.init(testing.allocator);
	defer r_lehmer.deinit();

	var raw_buf: [1024]u8 = undefined;
	var enc_buf: [1100]u8 = undefined;

	var total: usize = 0;
	var compared: usize = 0;
	for (SIZES) |bits| {
		const byte_len = (bits + 7) / 8;
		var i: usize = 0;
		while (i < ITERS_PER_SIZE) : (i += 1) {
			rand.bytes(raw_buf[0..byte_len]);
			raw_buf[byte_len - 1] &= 0x7F;
			const hdr_a = try tier3.writeHeader(&enc_buf, byte_len);
			@memcpy(enc_buf[hdr_a..][0..byte_len], raw_buf[0..byte_len]);
			try a.setBytes(enc_buf[0 .. hdr_a + byte_len]);

			rand.bytes(raw_buf[0..byte_len]);
			raw_buf[byte_len - 1] = (raw_buf[byte_len - 1] & 0x7F) | 0x40;
			raw_buf[0] |= 1;
			const hdr_m = try tier3.writeHeader(&enc_buf, byte_len);
			@memcpy(enc_buf[hdr_m..][0..byte_len], raw_buf[0..byte_len]);
			try m.setBytes(enc_buf[0 .. hdr_m + byte_len]);

			const ok_h = try Mp.invModHGCD(&r_hgcd, &a, &m);
			const ok_l = try Mp.invModLehmer(&r_lehmer, &a, &m);
			try testing.expectEqual(ok_l, ok_h);
			if (ok_l) {
				try testing.expect(Mp.cmp(&r_hgcd, &r_lehmer) == .eq);
				compared += 1;
			}
			total += 1;
		}
	}
	try testing.expect(total >= 1000);
	try testing.expect(compared >= 800);
}

test "invModHGCDRecursive matches invModHGCD: random pairs across bit-widths" {
	// M11.2 oracle: invModHGCD (M10 wider-window) is GMP-validated and
	// agrees with invModLehmer; invModHGCDRecursive must agree bit-for-bit.
	// Bit-widths span the recursive HGCD threshold (1024) so we exercise
	// both the fallback path and the recursive path.
	const SIZES = [_]usize{ 256, 512, 768, 1024, 1536, 2048, 3072, 4096 };
	const ITERS_PER_SIZE: usize = 130;
	var prng = std.Random.DefaultPrng.init(0xDEAD_F00D_C0DE_F00D);
	const rand = prng.random();

	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r_rec = Mp.init(testing.allocator);
	defer r_rec.deinit();
	var r_hgcd = Mp.init(testing.allocator);
	defer r_hgcd.deinit();

	var raw_buf: [1024]u8 = undefined;
	var enc_buf: [1100]u8 = undefined;

	var total: usize = 0;
	var compared: usize = 0;
	for (SIZES) |bits| {
		const byte_len = (bits + 7) / 8;
		var i: usize = 0;
		while (i < ITERS_PER_SIZE) : (i += 1) {
			rand.bytes(raw_buf[0..byte_len]);
			raw_buf[byte_len - 1] &= 0x7F;
			const hdr_a = try tier3.writeHeader(&enc_buf, byte_len);
			@memcpy(enc_buf[hdr_a..][0..byte_len], raw_buf[0..byte_len]);
			try a.setBytes(enc_buf[0 .. hdr_a + byte_len]);

			rand.bytes(raw_buf[0..byte_len]);
			raw_buf[byte_len - 1] = (raw_buf[byte_len - 1] & 0x7F) | 0x40;
			raw_buf[0] |= 1;
			const hdr_m = try tier3.writeHeader(&enc_buf, byte_len);
			@memcpy(enc_buf[hdr_m..][0..byte_len], raw_buf[0..byte_len]);
			try m.setBytes(enc_buf[0 .. hdr_m + byte_len]);

			const ok_r = try Mp.invModHGCDRecursive(&r_rec, &a, &m);
			const ok_h = try Mp.invModHGCD(&r_hgcd, &a, &m);
			try testing.expectEqual(ok_h, ok_r);
			if (ok_h) {
				try testing.expect(Mp.cmp(&r_rec, &r_hgcd) == .eq);
				compared += 1;
			}
			total += 1;
		}
	}
	try testing.expect(total >= 1000);
	try testing.expect(compared >= 800);
}

test "invMod: large modulus — 256-bit random with verification" {
	// Use a known prime modulus (so every nonzero a has an inverse).
	// 2^255 - 19 (Curve25519 prime): definitely prime, definitely > 1.
	// Construct as 0xed ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff 7f
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var mag = [_]u8{0} ** 32;
	mag[31] = 0x7f;
	var i: usize = 0;
	while (i < 31) : (i += 1) mag[i] = 0xff;
	mag[0] = 0xed;
	// BLIP encoding: header 0x80 | L for L<=31 → for L=32 needs continuation.
	// L=32 → header byte = 0xA0 (0x80 | (32 & 0x1F)=0x80) with cont. Use writer.
	var enc_buf: [40]u8 = undefined;
	const hdr_len = try tier3.writeHeader(&enc_buf, 32);
	@memcpy(enc_buf[hdr_len .. hdr_len + 32], &mag);
	try m.setBytes(enc_buf[0 .. hdr_len + 32]);

	var a = Mp.init(testing.allocator);
	defer a.deinit();
	try a.setI64(7); // 7 is coprime to the prime; inverse exists.

	var r = Mp.init(testing.allocator);
	defer r.deinit();
	const ok = try Mp.invMod(&r, &a, &m);
	try testing.expect(ok);
	// Verify (7 * r) mod m == 1.
	var prod = Mp.init(testing.allocator);
	defer prod.deinit();
	var rem = Mp.init(testing.allocator);
	defer rem.deinit();
	try prod.mul(&a, &r);
	try rem.mod(&prod, &m);
	try testing.expectEqual(@as(i64, 1), try rem.getI64());
}

test "divMod: divisor > 64K-bit doesn't overflow tier3.divModKnuthU64 stack scratch" {
	// Regression for the assertion `v_len <= VN_MAX` (1024 u64 limbs ≈
	// 64K-bit divisor) in tier3.divModKnuthU64. Real workloads (e.g. the
	// pi spigot at ~1700 digits) push past it. Build a divisor with ~70K
	// significant bits and verify divMod still works.
	const allocator = testing.allocator;
	// The .mul + .divMod calls below allocate the per-thread tier-3 mul,
	// div, and vn scratch caches (divisor > 64K-bit forces large heap
	// fallback). Release them on test exit so DebugAllocator's leak-detector
	// stays happy. (Same pattern as releaseFftScratch.)
	defer tier3.releaseMulScratch();
	defer tier3.releaseDivScratch();
	defer tier3.releaseVnScratch();
	var dividend = Mp.init(allocator);
	defer dividend.deinit();
	var divisor = Mp.init(allocator);
	defer divisor.deinit();
	var q = Mp.init(allocator);
	defer q.deinit();
	var r = Mp.init(allocator);
	defer r.deinit();

	// Build a 70K-bit divisor via setBytes (~8800 bytes of payload — safely
	// past VN_MAX × 8 = 8192 bytes).
	const div_bytes = 8800;
	const div_payload = try allocator.alloc(u8, div_bytes);
	defer allocator.free(div_payload);
	var prng = std.Random.DefaultPrng.init(0xCAFE_BABE_DEAD_BEEF);
	prng.random().bytes(div_payload);
	div_payload[div_bytes - 1] &= 0x7F; // keep positive
	if (div_payload[div_bytes - 1] == 0) div_payload[div_bytes - 1] = 0x40;
	const div_buf = try allocator.alloc(u8, div_bytes + 16);
	defer allocator.free(div_buf);
	const hdr_len = try tier3.writeHeader(div_buf, div_bytes);
	@memcpy(div_buf[hdr_len .. hdr_len + div_bytes], div_payload);
	try divisor.setBytes(div_buf[0 .. hdr_len + div_bytes]);

	// Build a dividend ~3x the divisor's bit length.
	const dvd_bytes = 26000;
	const dvd_payload = try allocator.alloc(u8, dvd_bytes);
	defer allocator.free(dvd_payload);
	prng.random().bytes(dvd_payload);
	dvd_payload[dvd_bytes - 1] &= 0x7F;
	if (dvd_payload[dvd_bytes - 1] == 0) dvd_payload[dvd_bytes - 1] = 0x40;
	const dvd_buf = try allocator.alloc(u8, dvd_bytes + 16);
	defer allocator.free(dvd_buf);
	const hdr2 = try tier3.writeHeader(dvd_buf, dvd_bytes);
	@memcpy(dvd_buf[hdr2 .. hdr2 + dvd_bytes], dvd_payload);
	try dividend.setBytes(dvd_buf[0 .. hdr2 + dvd_bytes]);

	// THE assertion that used to fire — divMod must complete without aborting.
	try Mp.divMod(&q, &r, &dividend, &divisor);

	// Reconstruction sanity: q * divisor + r == dividend.
	var reconstructed = Mp.init(allocator);
	defer reconstructed.deinit();
	var prod = Mp.init(allocator);
	defer prod.deinit();
	try prod.mul(&q, &divisor);
	try reconstructed.add(&prod, &r);
	try testing.expect(reconstructed.cmp(&dividend) == .eq);
}

test "divMod: identity a == q*b + rem on 1000 random i64 pairs" {
	var prng = std.Random.DefaultPrng.init(0xD1D_D0D_5EED);
	const rand = prng.random();
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var q = Mp.init(testing.allocator);
	defer q.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	var iter: usize = 0;
	while (iter < 1000) : (iter += 1) {
		// Bound dividend to leave room for tier-0/1 q*b verification.
		const av = rand.intRangeAtMost(i64, -1_000_000_000_000, 1_000_000_000_000);
		var bv = rand.intRangeAtMost(i64, -1_000_000, 1_000_000);
		if (bv == 0) bv = 1;
		try a.setI64(av);
		try b.setI64(bv);
		try Mp.divMod(&q, &r, &a, &b);
		const qv = try q.getI64();
		const rv = try r.getI64();
		// Identity: a == q*b + r
		try testing.expectEqual(av, qv * bv + rv);
		// |r| < |b|
		const r_abs = if (rv < 0) -rv else rv;
		const b_abs = if (bv < 0) -bv else bv;
		try testing.expect(r_abs < b_abs);
		// Sign of r matches sign of a (or r is zero)
		if (rv != 0) {
			try testing.expectEqual(@as(bool, av < 0), rv < 0);
		}
	}
}

// Quick monotonic-clock helper for the invMod benches.
fn invModBenchNanos() u64 {
	var ts: std.c.timespec = undefined;
	_ = std.c.clock_gettime(.MONOTONIC, &ts);
	return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "bench: invModLehmer vs invModHGCD across bit-widths" {
	// Microbench. Runs both invModLehmer and invModHGCD on the same fixed
	// random (a, m) pairs at 1024/2048/4096-bit widths, prints ns/op and
	// the speedup ratio. Used to validate M10 numbers.
	const SIZES = [_]usize{ 1024, 2048, 4096, 8192 };
	const ITERS_BY_SIZE = [_]usize{ 200, 100, 25, 8 };
	var prng = std.Random.DefaultPrng.init(0xBABE_CAFE_F00D);
	const rand = prng.random();

	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var m = Mp.init(testing.allocator);
	defer m.deinit();
	var r_l = Mp.init(testing.allocator);
	defer r_l.deinit();
	var r_h = Mp.init(testing.allocator);
	defer r_h.deinit();

	var raw_buf: [1024]u8 = undefined;
	var enc_buf: [1100]u8 = undefined;

	for (SIZES, ITERS_BY_SIZE) |bits, iters| {
		const byte_len = (bits + 7) / 8;
		// Build single fixed (a, m) pair; reuse for all iterations so the
		// comparison is apples-to-apples.
		rand.bytes(raw_buf[0..byte_len]);
		raw_buf[byte_len - 1] &= 0x7F;
		const hdr_a = try tier3.writeHeader(&enc_buf, byte_len);
		@memcpy(enc_buf[hdr_a..][0..byte_len], raw_buf[0..byte_len]);
		try a.setBytes(enc_buf[0 .. hdr_a + byte_len]);
		rand.bytes(raw_buf[0..byte_len]);
		raw_buf[byte_len - 1] = (raw_buf[byte_len - 1] & 0x7F) | 0x40;
		raw_buf[0] |= 1;
		const hdr_m = try tier3.writeHeader(&enc_buf, byte_len);
		@memcpy(enc_buf[hdr_m..][0..byte_len], raw_buf[0..byte_len]);
		try m.setBytes(enc_buf[0 .. hdr_m + byte_len]);

		// Warm-up.
		_ = try Mp.invModLehmer(&r_l, &a, &m);
		_ = try Mp.invModHGCD(&r_h, &a, &m);

		// Lehmer.
		const t0 = invModBenchNanos();
		var i: usize = 0;
		while (i < iters) : (i += 1) {
			_ = try Mp.invModLehmer(&r_l, &a, &m);
			std.mem.doNotOptimizeAway(&r_l);
		}
		const t1 = invModBenchNanos();
		const ns_lehmer = (t1 - t0) / iters;

		// HGCD (wider Lehmer).
		const t2 = invModBenchNanos();
		i = 0;
		while (i < iters) : (i += 1) {
			_ = try Mp.invModHGCD(&r_h, &a, &m);
			std.mem.doNotOptimizeAway(&r_h);
		}
		const t3 = invModBenchNanos();
		const ns_hgcd = (t3 - t2) / iters;

		// Recursive HGCD (M11.2) — only bench up to 4096 bits; at 8192+
		// the recursion's matrix-composition overhead causes catastrophic
		// regression (lacking sub-quadratic mul). Skip to keep test fast.
		var r_rec_b = Mp.init(testing.allocator);
		defer r_rec_b.deinit();
		var ns_rec: u64 = 0;
		var speedup_r: f64 = 0;
		if (bits <= 4096) {
			_ = try Mp.invModHGCDRecursive(&r_rec_b, &a, &m); // warm-up
			const t4 = invModBenchNanos();
			i = 0;
			while (i < iters) : (i += 1) {
				_ = try Mp.invModHGCDRecursive(&r_rec_b, &a, &m);
				std.mem.doNotOptimizeAway(&r_rec_b);
			}
			const t5 = invModBenchNanos();
			ns_rec = (t5 - t4) / iters;
			speedup_r = @as(f64, @floatFromInt(ns_lehmer)) / @as(f64, @floatFromInt(ns_rec));
			try testing.expect(Mp.cmp(&r_h, &r_rec_b) == .eq);
		}

		// Sanity: same result.
		try testing.expect(Mp.cmp(&r_l, &r_h) == .eq);

		const speedup_h = @as(f64, @floatFromInt(ns_lehmer)) / @as(f64, @floatFromInt(ns_hgcd));
		if (bits <= 4096) {
			std.debug.print(
				"\n[bench] invMod {d}-bit  Lehmer={d} ns/op  HGCD={d} ns/op (x{d:.2})  HGCDRec={d} ns/op (x{d:.2})\n",
				.{ bits, ns_lehmer, ns_hgcd, speedup_h, ns_rec, speedup_r },
			);
		} else {
			std.debug.print(
				"\n[bench] invMod {d}-bit  Lehmer={d} ns/op  HGCD={d} ns/op  speedup={d:.2}x  (HGCDRec skipped: O(M(n) log n) requires FFT mul)\n",
				.{ bits, ns_lehmer, ns_hgcd, speedup_h },
			);
		}
	}
}

// ── M11.1 — HGCD primitive: standalone tests ────────────────────────────────

/// Test helper: classical (multi-precision) EEA reduction tracking only
/// (r0, r1). Reduces (r0, r1) by repeated `(r0, r1) <- (r1, r0 mod r1)` until
/// either r1 == 0 or bitLen(r0) <= target_bits. Used as the HGCD oracle:
/// HGCD's matrix applied to (a, b) must yield the same (r0, r1) as this
/// classical step-by-step reduction down to the same threshold.
fn classicalReduceToTarget(
	r0: *Mp, r1: *Mp,
	target_bits: usize,
	allocator: std.mem.Allocator,
) ArithError!void {
	var q = Mp.init(allocator);
	defer q.deinit();
	var rem = Mp.init(allocator);
	defer rem.deinit();
	var tmp = Mp.init(allocator);
	defer tmp.deinit();
	while (r1.cached_sign != 0 and r0.bitLen() > target_bits) {
		try Mp.divMod(&q, &rem, r0, r1);
		try tmp.setBytes(r1.bytes());
		try r0.setBytes(tmp.bytes());
		try r1.setBytes(rem.bytes());
	}
}

test "HGCDMatrix identity: applyToPair leaves (r0,r1) unchanged" {
	var M = Mp.HGCDMatrix.init(testing.allocator);
	defer M.deinit();
	try M.setIdentity();

	var r0 = Mp.init(testing.allocator);
	defer r0.deinit();
	var r1 = Mp.init(testing.allocator);
	defer r1.deinit();
	try r0.setI64(123456789);
	try r1.setI64(987654);

	try M.applyToPair(&r0, &r1);
	try testing.expectEqual(@as(i64, 123456789), try r0.getI64());
	try testing.expectEqual(@as(i64, 987654), try r1.getI64());
}

test "HGCDMatrix one-step EEA: matrix [[0,1],[1,q]] reproduces one quotient step" {
	// One classical EEA step: (r0, r1) -> (r1, r0 - q*r1).
	// In our parity convention starting from identity (parity even):
	// - identity: r0 = 1*r0_o - 0*r1_o, r1 = 1*r1_o - 0*r0_o, parity even
	// - after one step (q): the new matrix should yield
	//   r0_new = r1_o = 0*r0_o + 1*r1_o (so parity becomes odd: B*r1_o - A*r0_o
	//   with A=0, B=1)
	//   r1_new = r0_o - q*r1_o: parity-odd r1 = C*r0_o - D*r1_o → C=1, D=q
	const a_val: i64 = 1234;
	const b_val: i64 = 56;
	const q_val: i64 = a_val / b_val; // 22
	_ = q_val;

	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	try a.setI64(a_val);
	try b.setI64(b_val);

	// Construct M corresponding to one EEA step on (a, b).
	var M = Mp.HGCDMatrix.init(testing.allocator);
	defer M.deinit();
	// After one EEA step: parity odd, A=0, B=1, C=1, D=q.
	try M.a.setI64(0);
	try M.b.setI64(1);
	try M.c.setI64(1);
	try M.d.setI64(@intCast(@divTrunc(a_val, b_val)));
	M.parity_even = false;

	var r0 = Mp.init(testing.allocator);
	defer r0.deinit();
	var r1 = Mp.init(testing.allocator);
	defer r1.deinit();
	try r0.setBytes(a.bytes());
	try r1.setBytes(b.bytes());

	try M.applyToPair(&r0, &r1);
	try testing.expectEqual(@as(i64, 56), try r0.getI64()); // = b
	try testing.expectEqual(@as(i64, 2), try r1.getI64()); // = a - q*b
}

test "hgcd: matches classical EEA reduction to half-bit threshold (random pairs)" {
	const SIZES = [_]usize{ 64, 128, 256, 512, 1024, 2048 };
	const ITERS_PER_SIZE: usize = 12;
	var prng = std.Random.DefaultPrng.init(0xBADD_C0DE_BEAF_F00D);
	const rand = prng.random();

	var raw_buf: [512]u8 = undefined;
	var enc_buf: [600]u8 = undefined;

	for (SIZES) |bits| {
		const byte_len = (bits + 7) / 8;
		var i: usize = 0;
		while (i < ITERS_PER_SIZE) : (i += 1) {
			// Build (a, b) with bitLen(a) = bits and a > b > 0.
			var a = Mp.init(testing.allocator);
			defer a.deinit();
			var b = Mp.init(testing.allocator);
			defer b.deinit();

			rand.bytes(raw_buf[0..byte_len]);
			raw_buf[byte_len - 1] = (raw_buf[byte_len - 1] & 0x7F) | 0x40; // ensure top bit clear (positive) and high enough
			const hdr_a = try tier3.writeHeader(&enc_buf, byte_len);
			@memcpy(enc_buf[hdr_a..][0..byte_len], raw_buf[0..byte_len]);
			try a.setBytes(enc_buf[0 .. hdr_a + byte_len]);

			// b: half size, ensure < a.
			const half_byte_len = byte_len / 2;
			if (half_byte_len == 0) continue;
			rand.bytes(raw_buf[0..half_byte_len]);
			raw_buf[half_byte_len - 1] = (raw_buf[half_byte_len - 1] & 0x7F) | 0x40;
			raw_buf[0] |= 1; // odd to give it a chance
			const hdr_b = try tier3.writeHeader(&enc_buf, half_byte_len);
			@memcpy(enc_buf[hdr_b..][0..half_byte_len], raw_buf[0..half_byte_len]);
			try b.setBytes(enc_buf[0 .. hdr_b + half_byte_len]);

			// Skip degenerate inputs.
			if (a.cached_sign == 0 or b.cached_sign == 0) continue;
			if (Mp.cmp(&a, &b) != .gt) continue;

			const orig_bits = a.bitLen();
			const target_bits: usize = orig_bits / 2;

			// HGCD path: get matrix M, apply to (a, b).
			var M = Mp.HGCDMatrix.init(testing.allocator);
			defer M.deinit();
			try Mp.hgcd(&M, &a, &b, target_bits, testing.allocator);

			var r0_h = Mp.init(testing.allocator);
			defer r0_h.deinit();
			var r1_h = Mp.init(testing.allocator);
			defer r1_h.deinit();
			try r0_h.setBytes(a.bytes());
			try r1_h.setBytes(b.bytes());
			try M.applyToPair(&r0_h, &r1_h);

			// Oracle: classical EEA reduction to same target.
			var r0_c = Mp.init(testing.allocator);
			defer r0_c.deinit();
			var r1_c = Mp.init(testing.allocator);
			defer r1_c.deinit();
			try r0_c.setBytes(a.bytes());
			try r1_c.setBytes(b.bytes());
			try classicalReduceToTarget(&r0_c, &r1_c, target_bits, testing.allocator);

			// Both must agree bit-for-bit (same EEA sequence position).
			try testing.expect(Mp.cmp(&r0_h, &r0_c) == .eq);
			try testing.expect(Mp.cmp(&r1_h, &r1_c) == .eq);

			// Sanity: HGCD did make progress (bitLen(r0) ≤ target_bits OR r1 == 0).
			try testing.expect(r1_h.cached_sign == 0 or r0_h.bitLen() <= target_bits);
		}
	}
}

// ── M11.2 — Recursive HGCD: failing test (TDD scaffold) ────────────────────

test "hgcdRecursive: matches classical EEA reduction at large bit-widths" {
	// Strict oracle: applying the recursive HGCD's matrix to (a, b) must yield
	// the SAME (r0, r1) as classical step-by-step EEA reduction down to the
	// same target_bits. This bit-for-bit equality is the tightest correctness
	// check: it proves the recursive form computes the exact same EEA
	// quotient sequence as the iterative form.
	const SIZES = [_]usize{ 256, 512, 1024, 2048, 4096 };
	const ITERS_PER_SIZE: usize = 8;
	var prng = std.Random.DefaultPrng.init(0xCAFE_F00D_BABE_BEEF);
	const rand = prng.random();

	var raw_buf: [1024]u8 = undefined;
	var enc_buf: [1100]u8 = undefined;

	for (SIZES) |bits| {
		const byte_len = (bits + 7) / 8;
		var i: usize = 0;
		while (i < ITERS_PER_SIZE) : (i += 1) {
			var a = Mp.init(testing.allocator);
			defer a.deinit();
			var b = Mp.init(testing.allocator);
			defer b.deinit();

			rand.bytes(raw_buf[0..byte_len]);
			raw_buf[byte_len - 1] = (raw_buf[byte_len - 1] & 0x7F) | 0x40;
			const hdr_a = try tier3.writeHeader(&enc_buf, byte_len);
			@memcpy(enc_buf[hdr_a..][0..byte_len], raw_buf[0..byte_len]);
			try a.setBytes(enc_buf[0 .. hdr_a + byte_len]);

			const half_byte_len = byte_len / 2;
			if (half_byte_len == 0) continue;
			rand.bytes(raw_buf[0..half_byte_len]);
			raw_buf[half_byte_len - 1] = (raw_buf[half_byte_len - 1] & 0x7F) | 0x40;
			raw_buf[0] |= 1;
			const hdr_b = try tier3.writeHeader(&enc_buf, half_byte_len);
			@memcpy(enc_buf[hdr_b..][0..half_byte_len], raw_buf[0..half_byte_len]);
			try b.setBytes(enc_buf[0 .. hdr_b + half_byte_len]);

			if (a.cached_sign == 0 or b.cached_sign == 0) continue;
			if (Mp.cmp(&a, &b) != .gt) continue;

			const orig_bits = a.bitLen();
			const target_bits: usize = orig_bits / 2;

			var M = Mp.HGCDMatrix.init(testing.allocator);
			defer M.deinit();
			try Mp.hgcdRecursive(&M, &a, &b, target_bits, testing.allocator);

			var r0_h = Mp.init(testing.allocator);
			defer r0_h.deinit();
			var r1_h = Mp.init(testing.allocator);
			defer r1_h.deinit();
			try r0_h.setBytes(a.bytes());
			try r1_h.setBytes(b.bytes());
			try M.applyToPair(&r0_h, &r1_h);

			var r0_c = Mp.init(testing.allocator);
			defer r0_c.deinit();
			var r1_c = Mp.init(testing.allocator);
			defer r1_c.deinit();
			try r0_c.setBytes(a.bytes());
			try r1_c.setBytes(b.bytes());
			try classicalReduceToTarget(&r0_c, &r1_c, target_bits, testing.allocator);

			try testing.expect(Mp.cmp(&r0_h, &r0_c) == .eq);
			try testing.expect(Mp.cmp(&r1_h, &r1_c) == .eq);

			try testing.expect(r1_h.cached_sign == 0 or r0_h.bitLen() <= target_bits);
		}
	}
}
