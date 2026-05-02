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
fn tier3DivModOp(q: *Mp, rem: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	const a_bytes = a.bytes();
	const b_bytes = b.bytes();
	const a_pay = a_bytes[a.cached_pay_off .. a.cached_pay_off + a.cached_pay_len];
	const b_pay = b_bytes[b.cached_pay_off .. b.cached_pay_off + b.cached_pay_len];

	const q_pay_max = a_pay.len + 2; // +1 for sign byte, +1 slack
	const r_pay_max = b_pay.len + 2;
	const work_need = tier3.divModSignedScratchNeed(a_pay.len, b_pay.len);

	// Stack scratch for small sizes; heap for large.
	const STACK_PAY = 4096;
	const STACK_WORK = 8192;
	var stack_q: [STACK_PAY]u8 = undefined;
	var stack_r: [STACK_PAY]u8 = undefined;
	var stack_w: [STACK_WORK]u8 = undefined;
	var heap_q: ?[]u8 = null;
	var heap_r: ?[]u8 = null;
	var heap_w: ?[]u8 = null;
	defer {
		if (heap_q) |s| q.allocator.free(s);
		if (heap_r) |s| rem.allocator.free(s);
		if (heap_w) |s| q.allocator.free(s);
	}
	const q_buf: []u8 = if (q_pay_max <= stack_q.len) stack_q[0..q_pay_max] else blk: {
		heap_q = try q.allocator.alloc(u8, q_pay_max);
		break :blk heap_q.?;
	};
	const r_buf: []u8 = if (r_pay_max <= stack_r.len) stack_r[0..r_pay_max] else blk: {
		heap_r = try rem.allocator.alloc(u8, r_pay_max);
		break :blk heap_r.?;
	};
	const w_buf: []u8 = if (work_need <= stack_w.len) stack_w[0..work_need] else blk: {
		heap_w = try q.allocator.alloc(u8, work_need);
		break :blk heap_w.?;
	};

	const got = tier3.divModSigned(a_pay, b_pay, q_buf, r_buf, w_buf);

	// Write canonical BLIP for q and rem from the produced two's-comp payloads.
	try writeMpFromPayload(q, q_buf[0..got.q_len]);
	try writeMpFromPayload(rem, r_buf[0..got.r_len]);
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

	// 4 KB per operand for mul (results double, so 8 KB result + out).
	// Covers up to ~32768-bit operands without spilling to allocator.
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
