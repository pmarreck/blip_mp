// fp.zig — exact arbitrary-precision fixed-point arithmetic.
//
// Built on top of `Mp`. Each value carries its own (mantissa, scale, base).
// The design goal is to disrupt IEEE754 by being correct-by-construction
// where IEEE754 is convenient-by-default:
//   - No NaN, no ±∞: ops error rather than silently produce a poison value.
//   - No signed zero: zero is zero.
//   - No denormals: representation has nothing special at any boundary.
//   - No silent precision loss: division either succeeds exactly, takes a
//     caller-supplied precision budget, or returns an exact (quot, rem).
//
// "Dynamic precision" — every value carries its own scale exponent, mirroring
// blip_mp's variable-length self-describing storage philosophy.
//
// Status: M14 scaffold (PLAN.md §M14). This file currently exposes the type
// and lifecycle; arithmetic, IO, and rounding land incrementally under TDD.
// Placeholder tests below name the contracts via SkipZigTest stubs so
// `./test` shows the surface as a queued TODO list while the suite stays green.

const std = @import("std");
const bignum = @import("bignum.zig");
const Mp = bignum.Mp;

pub const Base = enum(u8) {
	binary = 2,
	decimal = 10,
};

pub const Fp = struct {
	mantissa: Mp,
	scale: i32,
	base: Base,

	pub fn init(allocator: std.mem.Allocator) Fp {
		return .{
			.mantissa = Mp.init(allocator),
			.scale = 0,
			.base = .decimal,
		};
	}

	pub fn deinit(self: *Fp) void {
		self.mantissa.deinit();
		self.scale = 0;
	}

	/// True if the value is exactly zero (mantissa == 0, scale ignored).
	/// No signed-zero distinction.
	pub fn isZero(self: *const Fp) bool {
		return self.mantissa.cachedSign() == 0;
	}

	/// Set the value to mantissa × base^scale where mantissa is an i64.
	/// The base is whichever the Fp is currently configured for.
	pub fn setI64(self: *Fp, mantissa: i64, scale: i32, base: Base) FpError!void {
		try self.mantissa.setI64(mantissa);
		self.scale = scale;
		self.base = base;
	}

	/// Set self = num/den exactly in base 10. Errors with NonTerminatingExpansion
	/// when the reduced denominator has any prime factor other than 2 or 5.
	/// Special cases: num=0 → zero with scale=0; den=0 → DivisionByZero.
	pub fn setRationalDecimal(self: *Fp, num: i64, den: i64) FpError!void {
		return setRational(self, num, den, .decimal);
	}

	/// Set self = num/den exactly in base 2. Errors with NonTerminatingExpansion
	/// when the reduced denominator has any prime factor other than 2.
	pub fn setRationalBinary(self: *Fp, num: i64, den: i64) FpError!void {
		return setRational(self, num, den, .binary);
	}

	/// Decode an IEEE754 double bit-exactly into a base=2 Fp. NaN and ±∞
	/// have no exact rational representation — they error NotRepresentable
	/// (the user must explicitly opt out of IEEE754's footguns rather than
	/// silently smuggling them through).
	///
	/// Layout reminder: f64 = (sign:1, exp:11 bias=1023, mantissa:52).
	///   normalized: value = (-1)^sign × (1<<52 | mant) × 2^(exp - 1023 - 52)
	///   subnormal:  value = (-1)^sign × mant × 2^(-1074)
	///   ±0:         exp=0, mant=0 — collapses to our zero (no signed zero)
	///   NaN/inf:    exp=2047 — error
	pub fn setF64(self: *Fp, v: f64) FpError!void {
		const bits: u64 = @bitCast(v);
		const sign_bit: u1 = @intCast((bits >> 63) & 1);
		const exp: u11 = @intCast((bits >> 52) & 0x7FF);
		const mant: u52 = @intCast(bits & 0xFFFFFFFFFFFFF);
		if (exp == 0x7FF) return error.NotRepresentable; // NaN or ±∞
		if (exp == 0 and mant == 0) {
			try self.mantissa.setI64(0);
			self.scale = 0;
			self.base = .binary;
			return;
		}
		var raw_mant: u64 = undefined;
		var actual_exp: i32 = undefined;
		if (exp == 0) {
			// Subnormal.
			raw_mant = mant;
			actual_exp = -1074; // -1022 - 52
		} else {
			// Normalized: implicit leading 1 + 52 mantissa bits = 53.
			raw_mant = (@as(u64, 1) << 52) | mant;
			actual_exp = @as(i32, exp) - 1023 - 52;
		}
		// raw_mant fits in i64 (≤ 2^53 - 1 < 2^63). Apply sign separately.
		const signed_mant: i64 = if (sign_bit == 1)
			-@as(i64, @intCast(raw_mant))
		else
			@intCast(raw_mant);
		try self.mantissa.setI64(signed_mant);
		self.scale = actual_exp;
		self.base = .binary;
	}

	/// Encode self as IEEE754 double, ONLY if exactly representable. Errors:
	///   error.NonTerminatingExpansion — original is decimal with no
	///     terminating binary form (e.g. 0.1₁₀).
	///   error.NotRepresentable — value's significand needs more than 53
	///     bits, OR magnitude is outside f64's normal/subnormal range.
	///
	/// Caller wanting silent rounding should call .canonicalize() then
	/// roundToScale(target_scale=-52 - E, mode=.banker) first, then this.
	/// (No silent IEEE754 rounding is provided here on purpose.)
	pub fn getF64Exact(self: *const Fp) FpError!f64 {
		if (self.isZero()) return 0.0;
		const allocator = self.mantissa.allocator;
		const blip_mp_root = @import("blip_mp.zig");
		// Convert to base=2 first; toBinary errors NonTerminatingExpansion when
		// the original is decimal with infinite binary expansion.
		var binary = Fp.init(allocator);
		defer binary.deinit();
		try toBinary(&binary, self);
		try binary.canonicalize();
		var mag = Mp.init(allocator);
		defer mag.deinit();
		try blip_mp_root.sign.abs(&mag, &binary.mantissa);
		const bl: usize = mag.bitLen();
		if (bl > 53) return error.NotRepresentable;
		const negative = binary.mantissa.cachedSign() < 0;
		// Unbiased exponent E: value = (mantissa-with-implicit-1) × 2^E,
		// equivalent to mag × 2^scale where mag's high bit is at position bl-1.
		const E: i64 = @as(i64, binary.scale) + @as(i64, @intCast(bl)) - 1;
		if (E > 1023) return error.NotRepresentable; // overflow
		const m = try mag.getU64();
		// Subnormal range: E < -1022. Encoded mantissa = mag × 2^(scale + 1074).
		if (E < -1022) {
			const shift_left: i64 = @as(i64, binary.scale) + 1074;
			if (shift_left < 0) return error.NotRepresentable; // smaller than smallest subnormal
			const subnormal_mant: u64 = m << @intCast(shift_left);
			const sign_bit: u64 = if (negative) (@as(u64, 1) << 63) else 0;
			return @bitCast(sign_bit | subnormal_mant);
		}
		// Normalized: pad mag to 53 bits (top bit = implicit 1), then drop top bit.
		const padded: u64 = m << @intCast(53 - bl);
		const stored_mant: u64 = padded & ((@as(u64, 1) << 52) - 1);
		const stored_exp: u64 = @intCast(E + 1023);
		const sign_bit: u64 = if (negative) (@as(u64, 1) << 63) else 0;
		return @bitCast(sign_bit | (stored_exp << 52) | stored_mant);
	}

	/// Encode self as IEEE754 double, rounding per `mode` if not exactly
	/// representable in 53 bits. Differs from `getF64Exact` in that >53-bit
	/// significands are rounded (with the caller's chosen mode) rather than
	/// rejected. Errors:
	///   error.NonTerminatingExpansion — original is decimal AND mode is
	///     `.exact_or_error` AND no terminating binary form exists.
	///     (Other modes silently round through the binary expansion.)
	///   error.NotRepresentable — magnitude exceeds f64's normal range
	///     (E > 1023 after rounding) or, for `.exact_or_error` mode,
	///     mantissa exceeds 53 bits.
	///
	/// Algorithm:
	///   1. Convert to base=2 (toBinary may error NonTerminating).
	///   2. canonicalize.
	///   3. If bitLen ≤ 53 and in range, encode directly (delegated).
	///   4. Else round mantissa down to 53 bits using
	///      roundToScale(target_scale = scale + (bitLen - 53), mode).
	///      A carry that pushes bitLen to 54 → shift right 1, exp += 1.
	///   5. Encode the renormalized result.
	pub fn getF64(self: *const Fp, mode: RoundMode) FpError!f64 {
		// Exact-or-error mode: reuse getF64Exact verbatim — same semantics
		// (NonTerminating on decimal-with-no-terminating-binary, NotRepresentable
		// on >53 bits). Avoids accidentally smuggling rounding under the
		// "no rounding" mode.
		if (mode == .exact_or_error) return self.getF64Exact();
		if (self.isZero()) return 0.0;
		const allocator = self.mantissa.allocator;
		const blip_mp_root = @import("blip_mp.zig");
		// Step 1+2: bring to canonical base=2.
		var binary = Fp.init(allocator);
		defer binary.deinit();
		try toBinary(&binary, self);
		try binary.canonicalize();
		var mag = Mp.init(allocator);
		defer mag.deinit();
		try blip_mp_root.sign.abs(&mag, &binary.mantissa);
		const bl: usize = mag.bitLen();
		// Step 3: if already ≤ 53 bits, no rounding needed — delegate.
		if (bl <= 53) {
			const E_check: i64 = @as(i64, binary.scale) + @as(i64, @intCast(bl)) - 1;
			if (E_check <= 1023) return binary.getF64Exact();
			return error.NotRepresentable;
		}
		// Step 4: drop (bl - 53) low bits of |mantissa| with chosen rounding.
		// roundToScale operates on the signed mantissa directly — easier than
		// re-deriving the rounding here.
		const drop: i32 = @intCast(bl - 53);
		const new_target: i32 = binary.scale + drop;
		var rounded = Fp.init(allocator);
		defer rounded.deinit();
		try roundToScale(&rounded, &binary, new_target, mode);
		try rounded.canonicalize();
		// Re-derive bitLen of rounded magnitude — the carry from rounding
		// could have promoted 53 → 54 bits (e.g. all-ones rounded up).
		var rmag = Mp.init(allocator);
		defer rmag.deinit();
		try blip_mp_root.sign.abs(&rmag, &rounded.mantissa);
		var rbl: usize = rmag.bitLen();
		if (rbl == 0) return 0.0; // rounded all the way to zero (very subnormal)
		if (rbl > 53) {
			// Carry pushed past 53 bits — strip one low bit and bump scale.
			// Since we just rounded to a multiple of 2^new_target, the low bit
			// must be 0; canonicalize already handled this iff the value's
			// 2-adic valuation aligns. Defensive: shift right by (rbl - 53)
			// and bump scale by the same.
			const extra: u32 = @intCast(rbl - 53);
			try shrInPlace(&rmag, extra);
			const new_scale_i64: i64 = @as(i64, rounded.scale) + @as(i64, extra);
			if (new_scale_i64 > std.math.maxInt(i32)) return error.NotRepresentable;
			rounded.scale = @intCast(new_scale_i64);
			rbl = rmag.bitLen();
			// Re-apply sign for encoding consistency (we'll use rmag below).
			if (rounded.mantissa.cachedSign() < 0) {
				var negated = Mp.init(allocator);
				defer negated.deinit();
				try blip_mp_root.sign.neg(&negated, &rmag);
				try copyInto(&rounded.mantissa, &negated);
			} else {
				try copyInto(&rounded.mantissa, &rmag);
			}
		}
		// Step 5: encode rounded value via getF64Exact (now ≤ 53 bits).
		const E: i64 = @as(i64, rounded.scale) + @as(i64, @intCast(rbl)) - 1;
		if (E > 1023) return error.NotRepresentable;
		return rounded.getF64Exact();
	}

	/// Parse `s` as a fixed-point literal in `base`. Accepts optional leading
	/// '-', optional fractional part with '.' separator. Bases 2/8/10/16
	/// supported (delegated to Mp.setStr). The radix point is splice-only —
	/// we just track its position to set scale; the integer-side and
	/// fractional-side digits are concatenated and parsed as one Mp integer.
	///
	/// Examples:
	///   "3.14"  → mantissa=314, scale=-2
	///   "0.125" → mantissa=125, scale=-3
	///   "-0.5"  → mantissa=-5,  scale=-1
	///   ".5"    → mantissa=5,   scale=-1
	///   "100"   → mantissa=100, scale=0
	///   "0.11" base=2 → mantissa=3, scale=-2
	pub fn setStr(self: *Fp, s: []const u8, base: Base) FpError!void {
		if (s.len == 0) return error.EmptyString;
		const allocator = self.mantissa.allocator;
		// Find optional minus.
		var negative = false;
		var start: usize = 0;
		if (s[0] == '-') {
			negative = true;
			start = 1;
		}
		if (start >= s.len) return error.EmptyString;
		// Find the radix point (at most one).
		var dot_pos: ?usize = null;
		var i: usize = start;
		while (i < s.len) : (i += 1) {
			if (s[i] == '.') {
				if (dot_pos != null) return error.InvalidDigit;
				dot_pos = i;
			}
		}
		// Build the digit string (no '.', no '-') as a contiguous slice that
		// the Mp parser can consume.
		const digits_len = (s.len - start) - (if (dot_pos != null) @as(usize, 1) else 0);
		if (digits_len == 0) return error.EmptyString;
		var digits = try allocator.alloc(u8, digits_len + (if (negative) @as(usize, 1) else 0));
		defer allocator.free(digits);
		var pos: usize = 0;
		if (negative) {
			digits[0] = '-';
			pos = 1;
		}
		var k: usize = start;
		while (k < s.len) : (k += 1) {
			if (s[k] == '.') continue;
			digits[pos] = s[k];
			pos += 1;
		}
		const blip_mp_root = @import("blip_mp.zig");
		try blip_mp_root.string_io.setStr(&self.mantissa, digits, @intFromEnum(base));
		// Compute scale based on how many digits sat after the radix point.
		const frac_len: usize = if (dot_pos) |dp| (s.len - 1 - dp) else 0;
		if (frac_len > std.math.maxInt(i32)) return error.OutputBufferTooSmall;
		self.scale = -@as(i32, @intCast(frac_len));
		self.base = base;
	}

	/// Strip trailing factors-of-base from the mantissa and bump scale by the
	/// same count. Two Fps numerically equal in the same base reach the same
	/// (mantissa, scale) post-canonicalize, so direct field equality becomes
	/// a valid eq test on canonical inputs. Zero is a special case — its
	/// scale collapses to 0 unconditionally.
	pub fn canonicalize(self: *Fp) FpError!void {
		if (self.mantissa.cachedSign() == 0) {
			self.scale = 0;
			return;
		}
		switch (self.base) {
			.binary => {
				// 2-adic valuation = position of first 1-bit in two's-complement form,
				// which scan1 surfaces. Works for negative mantissas too — the 2-adic
				// valuation of a value equals that of its magnitude.
				const blip_mp_root = @import("blip_mp.zig");
				const tz: usize = blip_mp_root.scan.scan1(&self.mantissa, 0);
				if (tz == 0) return;
				try shrInPlace(&self.mantissa, tz);
				self.scale += @intCast(tz);
			},
			.decimal => {
				var divisor = Mp.init(self.mantissa.allocator);
				defer divisor.deinit();
				try divisor.setI64(10);
				var quot = Mp.init(self.mantissa.allocator);
				defer quot.deinit();
				var rem = Mp.init(self.mantissa.allocator);
				defer rem.deinit();
				while (true) {
					try Mp.divMod(&quot, &rem, &self.mantissa, &divisor);
					if (rem.cachedSign() != 0) break;
					try copyInto(&self.mantissa, &quot);
					self.scale += 1;
				}
			},
		}
	}
};

/// Copy src's value into dst (dst may already hold a value).
fn copyInto(dst: *Mp, src: *const Mp) FpError!void {
	try dst.setBytes(src.bytes());
}

/// In-place shr without round-trip through bitwise.shr (which allocates a
/// fresh Mp via setBytes underneath anyway, but expressing here keeps the
/// fp.zig module from depending on bitwise.zig directly).
fn shrInPlace(m: *Mp, n: usize) FpError!void {
	const blip_mp_root = @import("blip_mp.zig");
	var tmp = Mp.init(m.allocator);
	defer tmp.deinit();
	try blip_mp_root.bitwise.shr(&tmp, m, n);
	try copyInto(m, &tmp);
}

/// Three-way numerical compare. Errors on mixed bases — caller must explicitly
/// convert (toBinary / toDecimal) first; we don't paper over the lossiness.
pub fn cmp(a: *const Fp, b: *const Fp) (FpError || error{MixedBases})!std.math.Order {
	if (a.base != b.base) return error.MixedBases;
	const a_sign = a.mantissa.cachedSign();
	const b_sign = b.mantissa.cachedSign();
	if (a_sign != b_sign) return std.math.order(a_sign, b_sign);
	if (a_sign == 0) return .eq;
	// Same base, same sign, both non-zero. Align scales by lifting the
	// higher-scaled mantissa down to the lower scale via mul by base^Δ.
	if (a.scale == b.scale) return a.mantissa.cmp(&b.mantissa);
	const allocator = a.mantissa.allocator;
	var a_aligned = Mp.init(allocator);
	defer a_aligned.deinit();
	var b_aligned = Mp.init(allocator);
	defer b_aligned.deinit();
	try copyInto(&a_aligned, &a.mantissa);
	try copyInto(&b_aligned, &b.mantissa);
	if (a.scale > b.scale) {
		try liftMantissa(&a_aligned, a.base, @intCast(a.scale - b.scale));
	} else {
		try liftMantissa(&b_aligned, b.base, @intCast(b.scale - a.scale));
	}
	return a_aligned.cmp(&b_aligned);
}

/// Numerical equality (same base required). Convenience over cmp.
pub fn eq(a: *const Fp, b: *const Fp) (FpError || error{MixedBases})!bool {
	return (try cmp(a, b)) == .eq;
}

/// out = a + b. Operands must share a base (else error.MixedBases).
/// Output scale is min(a.scale, b.scale); the higher-scaled operand's
/// mantissa is lifted by base^Δscale before mantissa addition. Exact.
pub fn add(out: *Fp, a: *const Fp, b: *const Fp) (FpError || error{MixedBases})!void {
	return addOrSub(out, a, b, .add);
}

/// out = a - b. Same alignment rule as add.
pub fn sub(out: *Fp, a: *const Fp, b: *const Fp) (FpError || error{MixedBases})!void {
	return addOrSub(out, a, b, .sub);
}

const AddOrSub = enum { add, sub };

fn addOrSub(
	out: *Fp,
	a: *const Fp,
	b: *const Fp,
	comptime op: AddOrSub,
) (FpError || error{MixedBases})!void {
	if (a.base != b.base) return error.MixedBases;
	const allocator = out.mantissa.allocator;
	var a_aligned = Mp.init(allocator);
	defer a_aligned.deinit();
	var b_aligned = Mp.init(allocator);
	defer b_aligned.deinit();
	try copyInto(&a_aligned, &a.mantissa);
	try copyInto(&b_aligned, &b.mantissa);
	const out_scale: i32 = @min(a.scale, b.scale);
	if (a.scale > b.scale) {
		try liftMantissa(&a_aligned, a.base, @intCast(a.scale - b.scale));
	} else if (b.scale > a.scale) {
		try liftMantissa(&b_aligned, b.base, @intCast(b.scale - a.scale));
	}
	switch (op) {
		.add => try out.mantissa.add(&a_aligned, &b_aligned),
		.sub => try out.mantissa.sub(&a_aligned, &b_aligned),
	}
	out.scale = out_scale;
	out.base = a.base;
}

/// out = a / b, exact, or error.NonTerminatingExpansion if a/b can't be
/// represented in `base` with finite digits. The cornerstone of the
/// no-silent-rounding philosophy: callers who want exact get exact, or a
/// loud error pointing them at divPrecision / divQR.
pub fn divExact(out: *Fp, a: *const Fp, b: *const Fp) (FpError || error{MixedBases})!void {
	if (a.base != b.base) return error.MixedBases;
	if (b.mantissa.cachedSign() == 0) return error.DivisionByZero;
	if (a.mantissa.cachedSign() == 0) {
		try out.mantissa.setI64(0);
		out.scale = 0;
		out.base = a.base;
		return;
	}
	const allocator = out.mantissa.allocator;
	// Reduce mantissas by their gcd, working on absolute values; track sign
	// separately so we never feed a negative into the prime-factor strippers.
	const a_neg = a.mantissa.cachedSign() < 0;
	const b_neg = b.mantissa.cachedSign() < 0;
	const result_negative = a_neg != b_neg;
	const blip_mp_root = @import("blip_mp.zig");
	var num = Mp.init(allocator);
	defer num.deinit();
	var den = Mp.init(allocator);
	defer den.deinit();
	try blip_mp_root.sign.abs(&num, &a.mantissa);
	try blip_mp_root.sign.abs(&den, &b.mantissa);
	{
		var g = Mp.init(allocator);
		defer g.deinit();
		try blip_mp_root.gcd.gcd(&g, &num, &den);
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		try Mp.div(&tmp, &num, &g);
		try copyInto(&num, &tmp);
		try Mp.div(&tmp, &den, &g);
		try copyInto(&den, &tmp);
	}
	// Strip 2s from den. scan1 gives the 2-adic valuation of |den| in one shot.
	const a_count: u32 = blk: {
		const tz = blip_mp_root.scan.scan1(&den, 0);
		if (tz == 0) break :blk 0;
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		try blip_mp_root.bitwise.shr(&tmp, &den, tz);
		try copyInto(&den, &tmp);
		break :blk @intCast(tz);
	};
	// Strip 5s from den (decimal only).
	var b_count: u32 = 0;
	if (a.base == .decimal) {
		var five = Mp.init(allocator);
		defer five.deinit();
		try five.setI64(5);
		var quot = Mp.init(allocator);
		defer quot.deinit();
		var rem = Mp.init(allocator);
		defer rem.deinit();
		while (true) {
			try Mp.divMod(&quot, &rem, &den, &five);
			if (rem.cachedSign() != 0) break;
			try copyInto(&den, &quot);
			b_count += 1;
		}
	}
	// If anything remains in den, the expansion is non-terminating.
	{
		var one = Mp.init(allocator);
		defer one.deinit();
		try one.setI64(1);
		if (den.cmp(&one) != .eq) return error.NonTerminatingExpansion;
	}
	// Compute the multiplier base^max - the prime-power gap on each side.
	const max_count: u32 = @max(a_count, b_count);
	// Multiply num by 2^(max-a_count).
	if (max_count > a_count) {
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		try blip_mp_root.bitwise.shl(&tmp, &num, max_count - a_count);
		try copyInto(&num, &tmp);
	}
	// Multiply num by 5^(max-b_count) for decimal.
	if (a.base == .decimal and max_count > b_count) {
		var five_pow = Mp.init(allocator);
		defer five_pow.deinit();
		try five_pow.setI64(1);
		var five = Mp.init(allocator);
		defer five.deinit();
		try five.setI64(5);
		var i: u32 = 0;
		while (i < max_count - b_count) : (i += 1) {
			var tmp = Mp.init(allocator);
			defer tmp.deinit();
			try tmp.mul(&five_pow, &five);
			try copyInto(&five_pow, &tmp);
		}
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		try tmp.mul(&num, &five_pow);
		try copyInto(&num, &tmp);
	}
	// Apply sign and emit.
	if (result_negative) {
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		try blip_mp_root.sign.neg(&tmp, &num);
		try copyInto(&out.mantissa, &tmp);
	} else {
		try copyInto(&out.mantissa, &num);
	}
	const scale_diff: i64 = @as(i64, a.scale) - @as(i64, b.scale) - @as(i64, max_count);
	if (scale_diff > std.math.maxInt(i32) or scale_diff < std.math.minInt(i32)) {
		return error.OutputBufferTooSmall;
	}
	out.scale = @intCast(scale_diff);
	out.base = a.base;
}

/// quot, rem = a / b such that `quot * b + rem == a` EXACTLY.
/// quot is an integer (scale = 0); rem has the same base as the inputs and
/// whatever scale falls out of `a - quot*b`. Reconstruction is bit-exact.
///
/// quot is computed via roundToMp(a/b_pseudo, .toward_zero) — i.e. the
/// truncated integer quotient. rem = a - quot * b.
pub fn divQR(quot: *Fp, rem: *Fp, a: *const Fp, b: *const Fp) (FpError || error{MixedBases})!void {
	if (a.base != b.base) return error.MixedBases;
	if (b.mantissa.cachedSign() == 0) return error.DivisionByZero;
	const allocator = quot.mantissa.allocator;
	if (a.mantissa.cachedSign() == 0) {
		try quot.setI64(0, 0, a.base);
		try rem.setI64(0, 0, a.base);
		return;
	}
	// Step 1: compute the true integer quotient. We need enough fractional
	// precision to round to integer correctly, then take floor toward zero.
	// |a / b| ≤ |a.mantissa| / |b.mantissa| × base^(a.scale - b.scale).
	// One extra digit of precision is enough to make the trunc decision.
	var pseudo = Fp.init(allocator);
	defer pseudo.deinit();
	_ = try divPrecision(&pseudo, a, b, 1);
	// Step 2: round to integer (Mp), toward zero (truncating-quot semantics).
	var q_mp = Mp.init(allocator);
	defer q_mp.deinit();
	try roundToMp(&q_mp, &pseudo, .toward_zero);
	// Step 3: install quot as Fp scale=0.
	try copyInto(&quot.mantissa, &q_mp);
	quot.scale = 0;
	quot.base = a.base;
	// Step 4: rem = a - quot * b. Use the full mul + sub paths so the result
	// scale lands at min(a.scale, b.scale) and reconstruction is exact.
	var prod = Fp.init(allocator);
	defer prod.deinit();
	try mul(&prod, quot, b);
	try sub(rem, a, &prod);
}

/// out = a / b at most `max_scale_digits` more fractional digits than the
/// dividend already has. Returns true if the result is BIT-EXACT, false if
/// the function had to truncate. Caller picks how to react to inexactness
/// — the function never silently rounds without surfacing the choice.
///
/// Algorithm: scale up |num| by base^max_scale_digits, divMod by |den|,
/// take the floor of the magnitude, re-apply sign. Exactness == (rem == 0).
pub fn divPrecision(
	out: *Fp,
	a: *const Fp,
	b: *const Fp,
	max_scale_digits: u32,
) (FpError || error{MixedBases})!bool {
	if (a.base != b.base) return error.MixedBases;
	if (b.mantissa.cachedSign() == 0) return error.DivisionByZero;
	if (a.mantissa.cachedSign() == 0) {
		try out.mantissa.setI64(0);
		out.scale = 0;
		out.base = a.base;
		return true;
	}
	const allocator = out.mantissa.allocator;
	const blip_mp_root = @import("blip_mp.zig");
	const a_neg = a.mantissa.cachedSign() < 0;
	const b_neg = b.mantissa.cachedSign() < 0;
	const result_negative = a_neg != b_neg;

	var num = Mp.init(allocator);
	defer num.deinit();
	var den = Mp.init(allocator);
	defer den.deinit();
	try blip_mp_root.sign.abs(&num, &a.mantissa);
	try blip_mp_root.sign.abs(&den, &b.mantissa);

	// Lift |num| by base^max_scale_digits.
	if (max_scale_digits > 0) {
		switch (a.base) {
			.binary => {
				var tmp = Mp.init(allocator);
				defer tmp.deinit();
				try blip_mp_root.bitwise.shl(&tmp, &num, max_scale_digits);
				try copyInto(&num, &tmp);
			},
			.decimal => {
				var ten = Mp.init(allocator);
				defer ten.deinit();
				try ten.setI64(10);
				var i: u32 = 0;
				while (i < max_scale_digits) : (i += 1) {
					var tmp = Mp.init(allocator);
					defer tmp.deinit();
					try tmp.mul(&num, &ten);
					try copyInto(&num, &tmp);
				}
			},
		}
	}
	// quot = lifted_num / den; rem == 0 ↔ exact.
	var quot = Mp.init(allocator);
	defer quot.deinit();
	var rem = Mp.init(allocator);
	defer rem.deinit();
	try Mp.divMod(&quot, &rem, &num, &den);
	const exact = rem.cachedSign() == 0;

	if (result_negative) {
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		try blip_mp_root.sign.neg(&tmp, &quot);
		try copyInto(&out.mantissa, &tmp);
	} else {
		try copyInto(&out.mantissa, &quot);
	}
	const scale_diff: i64 = @as(i64, a.scale) - @as(i64, b.scale) - @as(i64, max_scale_digits);
	if (scale_diff > std.math.maxInt(i32) or scale_diff < std.math.minInt(i32)) {
		return error.OutputBufferTooSmall;
	}
	out.scale = @intCast(scale_diff);
	out.base = a.base;
	return exact;
}

/// out = x converted to base=10. ALWAYS exact: any base=2 dyadic rational
/// has a finite decimal expansion (because 1/2 = 5/10).
///
/// Algorithm:
///   x.scale ≥ 0:  out = mantissa × 2^scale (multiply out the powers of 2),
///                 out.scale = 0.
///   x.scale < 0:  1/2^k = 5^k / 10^k, so mantissa × 2^-k = (mantissa × 5^k) × 10^-k.
///                 out.mantissa = mantissa × 5^k, out.scale = -k.
pub fn toDecimal(out: *Fp, x: *const Fp) FpError!void {
	if (x.base == .decimal) {
		try copyInto(&out.mantissa, &x.mantissa);
		out.scale = x.scale;
		out.base = .decimal;
		return;
	}
	const allocator = out.mantissa.allocator;
	const blip_mp_root = @import("blip_mp.zig");
	if (x.scale >= 0) {
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		try copyInto(&tmp, &x.mantissa);
		if (x.scale > 0) {
			var lifted = Mp.init(allocator);
			defer lifted.deinit();
			try blip_mp_root.bitwise.shl(&lifted, &tmp, @intCast(x.scale));
			try copyInto(&out.mantissa, &lifted);
		} else {
			try copyInto(&out.mantissa, &tmp);
		}
		out.scale = 0;
		out.base = .decimal;
		return;
	}
	// x.scale < 0
	const k: u32 = @intCast(-x.scale);
	// Build 5^k.
	var five_pow = Mp.init(allocator);
	defer five_pow.deinit();
	try five_pow.setI64(1);
	{
		var five = Mp.init(allocator);
		defer five.deinit();
		try five.setI64(5);
		var i: u32 = 0;
		while (i < k) : (i += 1) {
			var tmp = Mp.init(allocator);
			defer tmp.deinit();
			try tmp.mul(&five_pow, &five);
			try copyInto(&five_pow, &tmp);
		}
	}
	var product = Mp.init(allocator);
	defer product.deinit();
	try product.mul(&x.mantissa, &five_pow);
	try copyInto(&out.mantissa, &product);
	out.scale = x.scale; // -k
	out.base = .decimal;
}

/// out = x converted to base=2. NOT always exact: a decimal rational like
/// 0.1 has no terminating binary expansion (1/10 = 1/(2·5), the 5 is the
/// problem). Errors NonTerminatingExpansion when the conversion would lose
/// precision — the user must explicitly opt into rounding via divPrecision
/// or equivalent.
///
/// Algorithm:
///   x.scale ≥ 0:  10^k = 2^k × 5^k, so mantissa × 10^k = (mantissa × 5^k) × 2^k.
///                 Always exact.
///   x.scale < 0:  10^-k = 1/(2^k × 5^k). For exactness, mantissa must be
///                 divisible by 5^k. Strip 5^k; result = (mantissa / 5^k) × 2^-k.
pub fn toBinary(out: *Fp, x: *const Fp) FpError!void {
	if (x.base == .binary) {
		try copyInto(&out.mantissa, &x.mantissa);
		out.scale = x.scale;
		out.base = .binary;
		return;
	}
	const allocator = out.mantissa.allocator;
	const blip_mp_root = @import("blip_mp.zig");
	if (x.scale >= 0) {
		// mantissa × 5^scale × 2^scale.
		var five_pow = Mp.init(allocator);
		defer five_pow.deinit();
		try five_pow.setI64(1);
		var five = Mp.init(allocator);
		defer five.deinit();
		try five.setI64(5);
		var i: i32 = 0;
		while (i < x.scale) : (i += 1) {
			var tmp = Mp.init(allocator);
			defer tmp.deinit();
			try tmp.mul(&five_pow, &five);
			try copyInto(&five_pow, &tmp);
		}
		var prod = Mp.init(allocator);
		defer prod.deinit();
		try prod.mul(&x.mantissa, &five_pow);
		try copyInto(&out.mantissa, &prod);
		out.scale = x.scale;
		out.base = .binary;
		return;
	}
	// x.scale < 0: need mantissa to be divisible by 5^k where k = -x.scale.
	const k: u32 = @intCast(-x.scale);
	var num = Mp.init(allocator);
	defer num.deinit();
	try blip_mp_root.sign.abs(&num, &x.mantissa);
	const negative = x.mantissa.cachedSign() < 0;
	var five = Mp.init(allocator);
	defer five.deinit();
	try five.setI64(5);
	var i: u32 = 0;
	while (i < k) : (i += 1) {
		var quot = Mp.init(allocator);
		defer quot.deinit();
		var rem = Mp.init(allocator);
		defer rem.deinit();
		try Mp.divMod(&quot, &rem, &num, &five);
		if (rem.cachedSign() != 0) return error.NonTerminatingExpansion;
		try copyInto(&num, &quot);
	}
	if (negative) {
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		try blip_mp_root.sign.neg(&tmp, &num);
		try copyInto(&out.mantissa, &tmp);
	} else {
		try copyInto(&out.mantissa, &num);
	}
	out.scale = x.scale; // -k
	out.base = .binary;
}

pub const RoundMode = enum {
	exact_or_error,    // refuse to lose info; error.NonTerminatingExpansion otherwise
	toward_zero,       // truncate magnitude (drop discarded digits)
	toward_pos_inf,    // ceiling: +1 magnitude on positives if any discarded digit nonzero
	toward_neg_inf,    // floor:   +1 magnitude on negatives if any discarded digit nonzero
	half_up,           // ties go away from zero
	half_down,         // ties go toward zero
	half_to_even,      // banker's: ties prefer even quot
	half_to_odd,       // ties prefer odd quot
};

/// Round `a` to a target scale exponent. delta = target_scale - a.scale:
///   delta < 0  → no info loss; lift mantissa by base^|delta|.
///   delta > 0  → divide mantissa by base^delta; rounding mode dictates
///                what to do with the remainder.
///   delta == 0 → copy.
pub fn roundToScale(out: *Fp, a: *const Fp, target_scale: i32, mode: RoundMode) FpError!void {
	const allocator = out.mantissa.allocator;
	const blip_mp_root = @import("blip_mp.zig");
	if (target_scale == a.scale) {
		try copyInto(&out.mantissa, &a.mantissa);
		out.scale = a.scale;
		out.base = a.base;
		return;
	}
	if (target_scale < a.scale) {
		// Gain precision — multiply by base^(a.scale - target_scale). Exact.
		const k: u32 = @intCast(a.scale - target_scale);
		try copyInto(&out.mantissa, &a.mantissa);
		try liftMantissa(&out.mantissa, a.base, k);
		out.scale = target_scale;
		out.base = a.base;
		return;
	}
	// target_scale > a.scale — discard low digits with chosen rounding.
	const delta: u32 = @intCast(target_scale - a.scale);
	// Build divisor = base^delta.
	var divisor = Mp.init(allocator);
	defer divisor.deinit();
	switch (a.base) {
		.binary => {
			try divisor.setI64(1);
			var lifted = Mp.init(allocator);
			defer lifted.deinit();
			try blip_mp_root.bitwise.shl(&lifted, &divisor, delta);
			try copyInto(&divisor, &lifted);
		},
		.decimal => {
			try divisor.setI64(1);
			var ten = Mp.init(allocator);
			defer ten.deinit();
			try ten.setI64(10);
			var i: u32 = 0;
			while (i < delta) : (i += 1) {
				var tmp = Mp.init(allocator);
				defer tmp.deinit();
				try tmp.mul(&divisor, &ten);
				try copyInto(&divisor, &tmp);
			}
		},
	}
	// Operate on |mantissa|; track sign separately so rounding semantics are clear.
	const negative = a.mantissa.cachedSign() < 0;
	var abs_m = Mp.init(allocator);
	defer abs_m.deinit();
	try blip_mp_root.sign.abs(&abs_m, &a.mantissa);
	var quot = Mp.init(allocator);
	defer quot.deinit();
	var rem = Mp.init(allocator);
	defer rem.deinit();
	try Mp.divMod(&quot, &rem, &abs_m, &divisor);
	const rem_zero = rem.cachedSign() == 0;
	// Rounding decision: should we add 1 to the magnitude of quot?
	var bump: bool = false;
	switch (mode) {
		.exact_or_error => {
			if (!rem_zero) return error.NonTerminatingExpansion;
		},
		.toward_zero => {},
		.toward_pos_inf => {
			if (!rem_zero and !negative) bump = true;
		},
		.toward_neg_inf => {
			if (!rem_zero and negative) bump = true;
		},
		.half_up => {
			// 2*rem >= divisor → bump magnitude (ties round away from zero)
			var two_rem = Mp.init(allocator);
			defer two_rem.deinit();
			var two = Mp.init(allocator);
			defer two.deinit();
			try two.setI64(2);
			try two_rem.mul(&rem, &two);
			if (two_rem.cmp(&divisor) != .lt) bump = true;
		},
		.half_down => {
			// 2*rem > divisor → bump (ties truncate toward zero)
			var two_rem = Mp.init(allocator);
			defer two_rem.deinit();
			var two = Mp.init(allocator);
			defer two.deinit();
			try two.setI64(2);
			try two_rem.mul(&rem, &two);
			if (two_rem.cmp(&divisor) == .gt) bump = true;
		},
		.half_to_even, .half_to_odd => {
			var two_rem = Mp.init(allocator);
			defer two_rem.deinit();
			var two = Mp.init(allocator);
			defer two.deinit();
			try two.setI64(2);
			try two_rem.mul(&rem, &two);
			const cmp_res = two_rem.cmp(&divisor);
			if (cmp_res == .gt) {
				bump = true;
			} else if (cmp_res == .eq) {
				// Tie: bump iff quot's parity opposes the target parity.
				const quot_low = blip_mp_root.scan.scan1(&quot, 0);
				const quot_is_odd = quot_low == 0 and quot.cachedSign() != 0;
				if (mode == .half_to_even and quot_is_odd) bump = true;
				if (mode == .half_to_odd and !quot_is_odd) bump = true;
			}
		},
	}
	if (bump) {
		var one = Mp.init(allocator);
		defer one.deinit();
		try one.setI64(1);
		var bumped = Mp.init(allocator);
		defer bumped.deinit();
		try bumped.add(&quot, &one);
		try copyInto(&quot, &bumped);
	}
	if (negative) {
		var negated = Mp.init(allocator);
		defer negated.deinit();
		try blip_mp_root.sign.neg(&negated, &quot);
		try copyInto(&out.mantissa, &negated);
	} else {
		try copyInto(&out.mantissa, &quot);
	}
	out.scale = target_scale;
	out.base = a.base;
}

/// Round `a` to an integer Mp via roundToScale at scale=0, then peel off
/// the mantissa. Mode applies to the discarded fractional digits.
pub fn roundToMp(out: *Mp, a: *const Fp, mode: RoundMode) FpError!void {
	var rounded = Fp.init(a.mantissa.allocator);
	defer rounded.deinit();
	try roundToScale(&rounded, a, 0, mode);
	try copyInto(out, &rounded.mantissa);
}

/// Format `x` in its native base as a canonical decimal/binary/hex string:
/// no scientific notation, no superfluous zeros (assumes the input is
/// already canonicalized — call `canonicalize` first if unsure).
///
/// Algorithm: render |mantissa| in `base` via Mp.toString, then splice in
/// the radix point at position determined by `scale`:
///   scale ≥ 0: pad with `scale` trailing zeros (integer or scaled-up int).
///   scale < 0, len > -scale: split: "{int_part}.{frac_part}".
///   scale < 0, len ≤ -scale: prepend "0.{leading_zeros}{mantissa}".
pub fn toStringCanonical(allocator: std.mem.Allocator, x: *const Fp) FpError![]u8 {
	if (x.mantissa.cachedSign() == 0) {
		const out = try allocator.alloc(u8, 1);
		out[0] = '0';
		return out;
	}
	const blip_mp_root = @import("blip_mp.zig");
	// Render the magnitude.
	var mag = Mp.init(allocator);
	defer mag.deinit();
	try blip_mp_root.sign.abs(&mag, &x.mantissa);
	const radix: u8 = @intFromEnum(x.base);
	const mag_str = try blip_mp_root.string_io.toString(&mag, allocator, radix);
	defer allocator.free(mag_str);
	const negative = x.mantissa.cachedSign() < 0;
	const sign_len: usize = if (negative) 1 else 0;
	if (x.scale >= 0) {
		// Append `scale` trailing zeros to the magnitude.
		const pad: usize = @intCast(x.scale);
		const out = try allocator.alloc(u8, sign_len + mag_str.len + pad);
		var pos: usize = 0;
		if (negative) {
			out[0] = '-';
			pos = 1;
		}
		@memcpy(out[pos .. pos + mag_str.len], mag_str);
		pos += mag_str.len;
		@memset(out[pos..], '0');
		return out;
	}
	const frac_digits: usize = @intCast(-x.scale);
	if (mag_str.len > frac_digits) {
		// "{int}.{frac}" form.
		const int_len = mag_str.len - frac_digits;
		const out = try allocator.alloc(u8, sign_len + mag_str.len + 1);
		var pos: usize = 0;
		if (negative) {
			out[0] = '-';
			pos = 1;
		}
		@memcpy(out[pos .. pos + int_len], mag_str[0..int_len]);
		pos += int_len;
		out[pos] = '.';
		pos += 1;
		@memcpy(out[pos..], mag_str[int_len..]);
		return out;
	} else {
		// "0.{zeros}{mag}" form.
		const leading_zeros = frac_digits - mag_str.len;
		const out = try allocator.alloc(u8, sign_len + 2 + leading_zeros + mag_str.len);
		var pos: usize = 0;
		if (negative) {
			out[0] = '-';
			pos = 1;
		}
		out[pos] = '0';
		out[pos + 1] = '.';
		pos += 2;
		@memset(out[pos .. pos + leading_zeros], '0');
		pos += leading_zeros;
		@memcpy(out[pos..], mag_str);
		return out;
	}
}

/// Format `x` with EXACTLY `frac_digits` digits after the radix point. Pads
/// with trailing zeros if the canonical form has fewer; rounds (banker's /
/// half-to-even) if more. Honors sign. With `frac_digits == 0`, no decimal
/// point is written.
///
/// Algorithm: roundToScale(target_scale = -frac_digits, .half_to_even) →
/// the result has scale = -frac_digits exactly (no canonicalize), so
/// toStringCanonical naturally renders the right number of fractional
/// digits — except when mantissa rounds to zero, in which case canonical
/// returns "0" and we pad here.
pub fn toStringFixed(allocator: std.mem.Allocator, x: *const Fp, frac_digits: u32) FpError![]u8 {
	if (frac_digits > std.math.maxInt(i32)) return error.OutputBufferTooSmall;
	const target_scale: i32 = -@as(i32, @intCast(frac_digits));
	var rounded = Fp.init(allocator);
	defer rounded.deinit();
	try roundToScale(&rounded, x, target_scale, .half_to_even);
	// Zero mantissa: canonical returns just "0" — manually build "0.000…".
	if (rounded.mantissa.cachedSign() == 0) {
		if (frac_digits == 0) {
			const out = try allocator.alloc(u8, 1);
			out[0] = '0';
			return out;
		}
		const fd: usize = @intCast(frac_digits);
		const out = try allocator.alloc(u8, 2 + fd);
		out[0] = '0';
		out[1] = '.';
		@memset(out[2..], '0');
		return out;
	}
	// Non-zero: rounded.scale == target_scale, so toStringCanonical gives
	// exactly frac_digits fractional digits.
	return toStringCanonical(allocator, &rounded);
}

/// Format `x` in scientific notation: `[-]M.MMMeE` for decimal, `[-]M.MMMpE`
/// for binary (C99 hex-float style — but with binary digits, not hex).
/// Mantissa side always has exactly one significant digit before the point.
/// If the mantissa magnitude is a single digit, the radix point is omitted
/// ("5e0" not "5.e0"). Zero renders as "0".
///
/// Algorithm: canonicalize a working copy, render the magnitude in `base`,
/// compute exponent = scale + (digit_count - 1), splice in radix point after
/// the leading digit.
pub fn toStringScientific(allocator: std.mem.Allocator, x: *const Fp) FpError![]u8 {
	if (x.mantissa.cachedSign() == 0) {
		const out = try allocator.alloc(u8, 1);
		out[0] = '0';
		return out;
	}
	const blip_mp_root = @import("blip_mp.zig");
	// Work on a canonicalized copy so trailing-zero stripping pulls scale
	// up the way "1.5e3" expects (1500 → 15 × 10^2 → exp=3).
	var work = Fp.init(allocator);
	defer work.deinit();
	try copyInto(&work.mantissa, &x.mantissa);
	work.scale = x.scale;
	work.base = x.base;
	try work.canonicalize();
	// Render magnitude.
	var mag = Mp.init(allocator);
	defer mag.deinit();
	try blip_mp_root.sign.abs(&mag, &work.mantissa);
	const radix: u8 = @intFromEnum(work.base);
	const mag_str = try blip_mp_root.string_io.toString(&mag, allocator, radix);
	defer allocator.free(mag_str);
	const num_digits: i64 = @intCast(mag_str.len);
	const exp_val: i64 = @as(i64, work.scale) + num_digits - 1;
	// Format the exponent — sign is implied by leading '-' from std.fmt.
	const exp_buf = try std.fmt.allocPrint(allocator, "{d}", .{exp_val});
	defer allocator.free(exp_buf);
	const exp_char: u8 = switch (work.base) {
		.decimal => 'e',
		.binary => 'p',
	};
	const negative = work.mantissa.cachedSign() < 0;
	const sign_len: usize = if (negative) 1 else 0;
	// Layout: [-]D[.DDD…]<e|p><exp>
	// If num_digits == 1, no '.' or fractional digits.
	const has_frac = mag_str.len > 1;
	const frac_len: usize = if (has_frac) mag_str.len - 1 else 0;
	const dot_len: usize = if (has_frac) 1 else 0;
	const total_len = sign_len + 1 + dot_len + frac_len + 1 + exp_buf.len;
	const out = try allocator.alloc(u8, total_len);
	var pos: usize = 0;
	if (negative) {
		out[0] = '-';
		pos = 1;
	}
	out[pos] = mag_str[0];
	pos += 1;
	if (has_frac) {
		out[pos] = '.';
		pos += 1;
		@memcpy(out[pos .. pos + frac_len], mag_str[1..]);
		pos += frac_len;
	}
	out[pos] = exp_char;
	pos += 1;
	@memcpy(out[pos .. pos + exp_buf.len], exp_buf);
	return out;
}

/// out = a * b. Exact-by-construction: mantissas multiply, scales sum.
/// No precision loss possible. Operands must share a base.
pub fn mul(out: *Fp, a: *const Fp, b: *const Fp) (FpError || error{MixedBases})!void {
	if (a.base != b.base) return error.MixedBases;
	try out.mantissa.mul(&a.mantissa, &b.mantissa);
	// Cast each i32 to i64 to detect overflow, then narrow back. In practice
	// callers won't construct scales beyond a few thousand, so overflow is
	// only a concern at hand-constructed extremes.
	const sum: i64 = @as(i64, a.scale) + @as(i64, b.scale);
	if (sum > std.math.maxInt(i32) or sum < std.math.minInt(i32)) {
		return error.OutputBufferTooSmall;
	}
	out.scale = @intCast(sum);
	out.base = a.base;
}

/// Multiply mantissa by base^k in place. Used by cmp to align scales.
fn liftMantissa(m: *Mp, base: Base, k: u32) FpError!void {
	if (k == 0) return;
	const allocator = m.allocator;
	switch (base) {
		.binary => {
			const blip_mp_root = @import("blip_mp.zig");
			var tmp = Mp.init(allocator);
			defer tmp.deinit();
			try blip_mp_root.bitwise.shl(&tmp, m, k);
			try copyInto(m, &tmp);
		},
		.decimal => {
			// Multiply by 10^k. Build the multiplier via repeated ×10 on a
			// local Mp; could be smarter (powI of 10 chunked) but small k is
			// the common case in cmp.
			var ten = Mp.init(allocator);
			defer ten.deinit();
			try ten.setI64(10);
			var i: u32 = 0;
			while (i < k) : (i += 1) {
				var tmp = Mp.init(allocator);
				defer tmp.deinit();
				try tmp.mul(m, &ten);
				try copyInto(m, &tmp);
			}
		},
	}
}

/// Common implementation for setRationalDecimal / setRationalBinary.
///
/// Algorithm (base=10):
///   1. Reduce num/den by gcd(|num|, |den|).
///   2. Strip 2s and 5s from den; let a = #2s, b = #5s removed.
///   3. If anything remains in den after stripping, the expansion is
///      non-terminating (denominator has a prime factor other than 2 or 5).
///   4. scale = -max(a, b).
///   5. mantissa = num × 2^(max(a,b)-a) × 5^(max(a,b)-b).
///
/// Base=2 is the same minus the 5-factor track.
fn setRational(self: *Fp, num: i64, den: i64, base: Base) FpError!void {
	if (den == 0) return error.DivisionByZero;
	if (num == 0) {
		try self.mantissa.setI64(0);
		self.scale = 0;
		self.base = base;
		return;
	}
	// Track sign separately; do all arithmetic on magnitudes.
	const negative = (num < 0) != (den < 0);
	var num_mag: u64 = if (num < 0) @bitCast(-num) else @intCast(num);
	var den_mag: u64 = if (den < 0) @bitCast(-den) else @intCast(den);
	// Reduce by gcd. Euclid on u64 is fine for the i64 input range.
	{
		var a = num_mag;
		var b = den_mag;
		while (b != 0) {
			const t = a % b;
			a = b;
			b = t;
		}
		num_mag /= a;
		den_mag /= a;
	}
	// Strip 2s.
	var a_count: u32 = 0;
	while (den_mag % 2 == 0) {
		den_mag /= 2;
		a_count += 1;
	}
	// Strip 5s only when base is decimal.
	var b_count: u32 = 0;
	if (base == .decimal) {
		while (den_mag % 5 == 0) {
			den_mag /= 5;
			b_count += 1;
		}
	}
	if (den_mag != 1) return error.NonTerminatingExpansion;
	const max_count: u32 = @max(a_count, b_count);
	// Compute the multiplier that brings the mantissa up to scale=-max_count.
	// Decimal: 2^(max-a) * 5^(max-b). Binary: just 2^(max-a) — there's no
	// 5-track because base=2's only allowed prime is 2.
	var multiplier: u64 = 1;
	{
		var k: u32 = 0;
		while (k < max_count - a_count) : (k += 1) {
			multiplier *= 2;
		}
		if (base == .decimal) {
			k = 0;
			while (k < max_count - b_count) : (k += 1) {
				multiplier *= 5;
			}
		}
	}
	// mantissa = num_mag * multiplier (sign re-applied). u128 to avoid overflow
	// when both num_mag and multiplier are large.
	const big: u128 = @as(u128, num_mag) * @as(u128, multiplier);
	if (big > std.math.maxInt(i64)) {
		// Promote into Mp via setBytes. Build via two-step: load u64 halves.
		// For now, the i64-input path can't actually exceed i64 range here in
		// practice (num was an i64; multiplier comes from den which was i64;
		// product up to ~i64×i64). But just in case, fall back to wide setBytes.
		var lo_buf: [16]u8 = undefined;
		std.mem.writeInt(u128, &lo_buf, big, .little);
		// Build a BLIP slice from the magnitude.
		// Quickest: setU64 the low 64, then if high != 0 manually combine.
		// Simplest defensive path: error out — caller passing this large of a
		// product to a u64-input rational is misuse.
		return error.OutputBufferTooSmall;
	}
	const mant_signed: i64 = if (negative) -@as(i64, @intCast(big)) else @intCast(big);
	try self.mantissa.setI64(mant_signed);
	self.scale = -@as(i32, @intCast(max_count));
	self.base = base;
}

pub const FpError = error{
	NonTerminatingExpansion, // exact representation in this base would require infinite digits
	UnsupportedBase,
	DivisionByZero,
	EmptyString,
	InvalidDigit,
	NotRepresentable, // setF64(NaN/inf), getF64 of value outside f64's range or not exactly representable
} || bignum.SetError || bignum.ArithError || std.mem.Allocator.Error;

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "M14-1: Fp.init produces a zero value, default base = decimal, scale = 0" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try testing.expect(x.isZero());
	try testing.expectEqual(@as(i32, 0), x.scale);
	try testing.expectEqual(Base.decimal, x.base);
}

test "M14-1: Fp.init / deinit round-trip leaks no memory" {
	var x = Fp.init(testing.allocator);
	x.deinit();
	// testing.allocator (GeneralPurposeAllocator) panics on leak — silent pass = no leak.
}

test "M14-1: setI64 stores mantissa, scale, base verbatim" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(314, -2, .decimal);
	try testing.expectEqual(@as(i64, 314), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -2), x.scale);
	try testing.expectEqual(Base.decimal, x.base);
}

test "M14-1: setI64 with negative mantissa preserves sign" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(-12345, 3, .binary);
	try testing.expectEqual(@as(i64, -12345), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, 3), x.scale);
	try testing.expectEqual(Base.binary, x.base);
}

test "M14-1: setI64(0, _, _) keeps isZero() true regardless of scale/base" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(0, 999, .binary);
	try testing.expect(x.isZero());
	try x.setI64(0, -42, .decimal);
	try testing.expect(x.isZero());
}

// Queued failing tests for upcoming M14-N work. Each one names the contract
// the implementation must honor. Skipped while pending so the suite stays
// green; remove the skip line as each feature lands.

test "M14-1: setRationalDecimal(2, 5) → mantissa=4 scale=-1 (i.e., 0.4)" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalDecimal(2, 5);
	try testing.expectEqual(@as(i64, 4), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), x.scale);
	try testing.expectEqual(Base.decimal, x.base);
}

test "M14-1: setRationalDecimal(1, 4) → mantissa=25 scale=-2 (i.e., 0.25)" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalDecimal(1, 4);
	try testing.expectEqual(@as(i64, 25), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -2), x.scale);
}

test "M14-1: setRationalDecimal(1, 8) → mantissa=125 scale=-3" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalDecimal(1, 8);
	try testing.expectEqual(@as(i64, 125), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -3), x.scale);
}

test "M14-1: setRationalDecimal(3, 2) → mantissa=15 scale=-1 (1.5)" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalDecimal(3, 2);
	try testing.expectEqual(@as(i64, 15), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), x.scale);
}

test "M14-1: setRationalDecimal(7, 1) → mantissa=7 scale=0 (integer)" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalDecimal(7, 1);
	try testing.expectEqual(@as(i64, 7), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, 0), x.scale);
}

test "M14-1: setRationalDecimal(-1, 4) → mantissa=-25 scale=-2 (-0.25)" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalDecimal(-1, 4);
	try testing.expectEqual(@as(i64, -25), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -2), x.scale);
}

test "M14-1: setRationalDecimal(0, anything) → zero with scale=0" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalDecimal(0, 17);
	try testing.expect(x.isZero());
	try testing.expectEqual(@as(i32, 0), x.scale);
}

test "M14-1: setRationalDecimal(_, 0) errors DivisionByZero" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try testing.expectError(error.DivisionByZero, x.setRationalDecimal(1, 0));
}

test "M14-1: setRationalDecimal(1, 3) errors with NonTerminatingExpansion" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try testing.expectError(error.NonTerminatingExpansion, x.setRationalDecimal(1, 3));
}

test "M14-1: setRationalDecimal(2, 6) reduces 2/6=1/3 → NonTerminating" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try testing.expectError(error.NonTerminatingExpansion, x.setRationalDecimal(2, 6));
}

test "M14-1: setRationalDecimal(3, 6) reduces 3/6=1/2 → 0.5" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalDecimal(3, 6);
	try testing.expectEqual(@as(i64, 5), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), x.scale);
}

test "M14-1: setRationalBinary(1, 8) → mantissa=1 scale=-3 (i.e., 0.001₂ = 0.125)" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalBinary(1, 8);
	try testing.expectEqual(@as(i64, 1), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -3), x.scale);
	try testing.expectEqual(Base.binary, x.base);
}

test "M14-1: setRationalBinary(1, 5) errors NonTerminatingExpansion (5 isn't a power of 2)" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try testing.expectError(error.NonTerminatingExpansion, x.setRationalBinary(1, 5));
}

test "M14-1: setRationalBinary(3, 4) reduces to 3 × 2^-2" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setRationalBinary(3, 4);
	try testing.expectEqual(@as(i64, 3), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -2), x.scale);
}

test "M14-1: setStr(\"3.14\") base=10 → mantissa=314 scale=-2" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("3.14", .decimal);
	try testing.expectEqual(@as(i64, 314), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -2), x.scale);
}

test "M14-1: setStr(\"0.125\") → mantissa=125 scale=-3" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("0.125", .decimal);
	try testing.expectEqual(@as(i64, 125), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -3), x.scale);
}

test "M14-1: setStr(\"-0.5\") → mantissa=-5 scale=-1" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("-0.5", .decimal);
	try testing.expectEqual(@as(i64, -5), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), x.scale);
}

test "M14-1: setStr(\"100\") → mantissa=100 scale=0 (integer)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("100", .decimal);
	try testing.expectEqual(@as(i64, 100), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, 0), x.scale);
}

test "M14-1: setStr(\".5\") → mantissa=5 scale=-1" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr(".5", .decimal);
	try testing.expectEqual(@as(i64, 5), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), x.scale);
}

test "M14-1: setStr(\"100.\") → mantissa=100 scale=0 (trailing dot OK)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("100.", .decimal);
	try testing.expectEqual(@as(i64, 100), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, 0), x.scale);
}

test "M14-1: setStr(\"0\") → zero" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("0", .decimal);
	try testing.expect(x.isZero());
}

test "M14-1: setStr(\"\") errors EmptyString" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try testing.expectError(error.EmptyString, x.setStr("", .decimal));
}

test "M14-1: setStr(\"3.1.4\") errors InvalidDigit" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try testing.expectError(error.InvalidDigit, x.setStr("3.1.4", .decimal));
}

test "M14-1: setStr(\"0.11\", binary) → mantissa=3 scale=-2 (= 0.75 dec)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("0.11", .binary);
	try testing.expectEqual(@as(i64, 3), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -2), x.scale);
}

test "M14-1: setStr / toStringCanonical round-trip — full IEEE754 disruption demo" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setStr("0.1", .decimal);
	try y.setStr("0.2", .decimal);
	try add(&r, &x, &y);
	try r.canonicalize();
	const s = try toStringCanonical(a, &r);
	defer a.free(s);
	try testing.expectEqualStrings("0.3", s);
}

test "M14-2: canonicalize strips trailing zeros — 1.500 → 1.5 (mantissa=1500 scale=-3 → 15 scale=-1)" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(1500, -3, .decimal);
	try x.canonicalize();
	try testing.expectEqual(@as(i64, 15), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), x.scale);
}

test "M14-2: canonicalize on integer with trailing zeros: 1500 → 15 × 10^2" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(1500, 0, .decimal);
	try x.canonicalize();
	try testing.expectEqual(@as(i64, 15), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, 2), x.scale);
}

test "M14-2: canonicalize: zero gets scale=0 regardless of starting scale" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(0, -7, .decimal);
	try x.canonicalize();
	try testing.expectEqual(@as(i32, 0), x.scale);
	try testing.expect(x.isZero());
}

test "M14-2: canonicalize: already-canonical leaves Fp unchanged" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(13, -1, .decimal);
	try x.canonicalize();
	try testing.expectEqual(@as(i64, 13), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), x.scale);
}

test "M14-2: canonicalize binary: 12 = 0b1100 → 3 × 2^2" {
	var x = Fp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(12, 0, .binary);
	try x.canonicalize();
	try testing.expectEqual(@as(i64, 3), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, 2), x.scale);
}

test "M14-2: cmp aligns scales — 0.1 == 0.10 == 0.100 base=10" {
	var a = Fp.init(testing.allocator);
	defer a.deinit();
	var b = Fp.init(testing.allocator);
	defer b.deinit();
	var c = Fp.init(testing.allocator);
	defer c.deinit();
	try a.setI64(1, -1, .decimal);    // 0.1
	try b.setI64(10, -2, .decimal);   // 0.10
	try c.setI64(100, -3, .decimal);  // 0.100
	try testing.expectEqual(std.math.Order.eq, try cmp(&a, &b));
	try testing.expectEqual(std.math.Order.eq, try cmp(&b, &c));
	try testing.expectEqual(std.math.Order.eq, try cmp(&a, &c));
}

test "M14-2: cmp orders distinct values correctly across scales" {
	var a = Fp.init(testing.allocator);
	defer a.deinit();
	var b = Fp.init(testing.allocator);
	defer b.deinit();
	try a.setI64(1, -1, .decimal);    // 0.1
	try b.setI64(11, -2, .decimal);   // 0.11
	try testing.expectEqual(std.math.Order.lt, try cmp(&a, &b));
	try testing.expectEqual(std.math.Order.gt, try cmp(&b, &a));
}

test "M14-2: cmp negatives" {
	var a = Fp.init(testing.allocator);
	defer a.deinit();
	var b = Fp.init(testing.allocator);
	defer b.deinit();
	try a.setI64(-1, -1, .decimal);   // -0.1
	try b.setI64(1, -1, .decimal);    // 0.1
	try testing.expectEqual(std.math.Order.lt, try cmp(&a, &b));
}

test "M14-2: cmp zero handling — 0 == 0 regardless of scale/base" {
	var a = Fp.init(testing.allocator);
	defer a.deinit();
	var b = Fp.init(testing.allocator);
	defer b.deinit();
	try a.setI64(0, -3, .decimal);
	try b.setI64(0, 5, .decimal);
	try testing.expectEqual(std.math.Order.eq, try cmp(&a, &b));
}

test "M14-2: cmp errors on mixed bases" {
	var a = Fp.init(testing.allocator);
	defer a.deinit();
	var b = Fp.init(testing.allocator);
	defer b.deinit();
	try a.setI64(1, -1, .decimal);
	try b.setI64(1, -1, .binary);
	try testing.expectError(error.MixedBases, cmp(&a, &b));
}

test "M14-2: eq returns true for numerically-equal values regardless of scale" {
	var a = Fp.init(testing.allocator);
	defer a.deinit();
	var b = Fp.init(testing.allocator);
	defer b.deinit();
	try a.setI64(1, -1, .decimal);
	try b.setI64(100, -3, .decimal);
	try testing.expect(try eq(&a, &b));
}

test "M14-2: eq returns false for distinct values" {
	var a = Fp.init(testing.allocator);
	defer a.deinit();
	var b = Fp.init(testing.allocator);
	defer b.deinit();
	try a.setI64(1, -1, .decimal);
	try b.setI64(2, -1, .decimal);
	try testing.expect(!(try eq(&a, &b)));
}

test "M14-3: 0.1 + 0.2 == 0.3 EXACTLY (the IEEE754 disruption headline)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setRationalDecimal(1, 10);
	try y.setRationalDecimal(2, 10);
	try expected.setRationalDecimal(3, 10);
	try add(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-3: add aligns scales — 0.5 + 0.25 == 0.75" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setRationalDecimal(1, 2);    // 0.5
	try y.setRationalDecimal(1, 4);    // 0.25
	try expected.setRationalDecimal(3, 4); // 0.75
	try add(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-3: add x + 0 == x" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var z = Fp.init(a);
	defer z.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setRationalDecimal(7, 4); // 1.75
	try z.setI64(0, 0, .decimal);
	try add(&r, &x, &z);
	try testing.expect(try eq(&r, &x));
}

test "M14-3: add mixes sign — 0.5 + (-0.3) == 0.2" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setRationalDecimal(1, 2);     // 0.5
	try y.setRationalDecimal(-3, 10);   // -0.3
	try expected.setRationalDecimal(1, 5); // 0.2
	try add(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-3: add binary base — 0.5 + 0.25 = 0.75" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setRationalBinary(1, 2);
	try y.setRationalBinary(1, 4);
	try expected.setRationalBinary(3, 4);
	try add(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-3: add errors on mixed bases" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(1, 0, .decimal);
	try y.setI64(1, 0, .binary);
	try testing.expectError(error.MixedBases, add(&r, &x, &y));
}

test "M14-3: sub — 0.3 - 0.1 == 0.2" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setRationalDecimal(3, 10);
	try y.setRationalDecimal(1, 10);
	try expected.setRationalDecimal(2, 10);
	try sub(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-3: sub — x - x == 0" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setRationalDecimal(7, 4);
	try sub(&r, &x, &x);
	try testing.expect(r.isZero());
}

test "M14-3: mul is always exact — 0.5 * 0.2 == 0.1" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setRationalDecimal(1, 2);    // 0.5
	try y.setRationalDecimal(1, 5);    // 0.2
	try expected.setRationalDecimal(1, 10); // 0.1
	try mul(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-3: mul x * 0 == 0" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var z = Fp.init(a);
	defer z.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setRationalDecimal(355, 100);
	try z.setI64(0, 0, .decimal);
	try mul(&r, &x, &z);
	try testing.expect(r.isZero());
}

test "M14-3: mul x * 1 == x" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var one = Fp.init(a);
	defer one.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setRationalDecimal(7, 4);
	try one.setI64(1, 0, .decimal);
	try mul(&r, &x, &one);
	try testing.expect(try eq(&r, &x));
}

test "M14-3: mul scales sum correctly: 1.5 × 2.0 = 3.0 (mantissa 30, scale -1 → canonical 3, scale 0)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setRationalDecimal(3, 2); // 1.5
	try y.setI64(2, 0, .decimal);   // 2.0
	try expected.setI64(3, 0, .decimal);
	try mul(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-4: divExact(1, 4) base=10 → 0.25 (terminates: 4 = 2^2)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setI64(1, 0, .decimal);
	try y.setI64(4, 0, .decimal);
	try expected.setRationalDecimal(1, 4); // 0.25
	try divExact(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-4: divExact(5, 8) base=10 → 0.625" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setI64(5, 0, .decimal);
	try y.setI64(8, 0, .decimal);
	try expected.setRationalDecimal(625, 1000); // 0.625
	try divExact(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-4: divExact preserves sign — -1/4 → -0.25" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setI64(-1, 0, .decimal);
	try y.setI64(4, 0, .decimal);
	try expected.setRationalDecimal(-1, 4);
	try divExact(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-4: divExact respects existing scales — 0.5 / 0.25 = 2" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setRationalDecimal(1, 2); // 0.5
	try y.setRationalDecimal(1, 4); // 0.25
	try expected.setI64(2, 0, .decimal);
	try divExact(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-4: divExact(1, 3) base=10 errors NonTerminatingExpansion" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(1, 0, .decimal);
	try y.setI64(3, 0, .decimal);
	try testing.expectError(error.NonTerminatingExpansion, divExact(&r, &x, &y));
}

test "M14-4: divExact(1, 7) base=10 errors NonTerminatingExpansion" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(1, 0, .decimal);
	try y.setI64(7, 0, .decimal);
	try testing.expectError(error.NonTerminatingExpansion, divExact(&r, &x, &y));
}

test "M14-4: divExact(_ , 0) errors DivisionByZero" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var z = Fp.init(a);
	defer z.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(7, 0, .decimal);
	try z.setI64(0, 0, .decimal);
	try testing.expectError(error.DivisionByZero, divExact(&r, &x, &z));
}

test "M14-4: divExact 0/x = 0" {
	const a = testing.allocator;
	var z = Fp.init(a);
	defer z.deinit();
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try z.setI64(0, 0, .decimal);
	try x.setI64(7, 0, .decimal);
	try divExact(&r, &z, &x);
	try testing.expect(r.isZero());
}

test "M14-4: divExact binary 1/8 → 0.125 (1 × 2^-3)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setI64(1, 0, .binary);
	try y.setI64(8, 0, .binary);
	try expected.setRationalBinary(1, 8);
	try divExact(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-4: divExact binary 1/3 errors (3 is not a power of 2)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(1, 0, .binary);
	try y.setI64(3, 0, .binary);
	try testing.expectError(error.NonTerminatingExpansion, divExact(&r, &x, &y));
}

test "M14-4: divExact 6/4 reduces to 3/2 → 1.5" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setI64(6, 0, .decimal);
	try y.setI64(4, 0, .decimal);
	try expected.setRationalDecimal(3, 2);
	try divExact(&r, &x, &y);
	try testing.expect(try eq(&r, &expected));
}

test "M14-4: divPrecision(1, 4, max=5) base=10 → exact (25000 × 10^-5 = 0.25), reports exact=true" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	var expected = Fp.init(a);
	defer expected.deinit();
	try x.setI64(1, 0, .decimal);
	try y.setI64(4, 0, .decimal);
	try expected.setRationalDecimal(1, 4);
	const exact = try divPrecision(&r, &x, &y, 5);
	try testing.expect(exact);
	try testing.expect(try eq(&r, &expected));
}

test "M14-4: divPrecision(1, 3, max=5) base=10 → inexact, mantissa=33333 scale=-5" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(1, 0, .decimal);
	try y.setI64(3, 0, .decimal);
	const exact = try divPrecision(&r, &x, &y, 5);
	try testing.expect(!exact);
	try testing.expectEqual(@as(i64, 33333), try r.mantissa.getI64());
	try testing.expectEqual(@as(i32, -5), r.scale);
}

test "M14-4: divPrecision(22, 7, max=10) base=10 ≈ 3.1428571428" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(22, 0, .decimal);
	try y.setI64(7, 0, .decimal);
	const exact = try divPrecision(&r, &x, &y, 10);
	try testing.expect(!exact);
	try testing.expectEqual(@as(i64, 31428571428), try r.mantissa.getI64());
	try testing.expectEqual(@as(i32, -10), r.scale);
}

test "M14-4: divPrecision preserves sign — -1/3 max=4 → -3333 × 10^-4" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(-1, 0, .decimal);
	try y.setI64(3, 0, .decimal);
	const exact = try divPrecision(&r, &x, &y, 4);
	try testing.expect(!exact);
	try testing.expectEqual(@as(i64, -3333), try r.mantissa.getI64());
	try testing.expectEqual(@as(i32, -4), r.scale);
}

test "M14-4: divPrecision errors on division by zero" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var z = Fp.init(a);
	defer z.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(1, 0, .decimal);
	try z.setI64(0, 0, .decimal);
	try testing.expectError(error.DivisionByZero, divPrecision(&r, &x, &z, 5));
}

test "M14-4: divPrecision binary — 1/3 max=8 truncates" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setI64(1, 0, .binary);
	try y.setI64(3, 0, .binary);
	const exact = try divPrecision(&r, &x, &y, 8);
	try testing.expect(!exact);
	// 1/3 in binary at 8 fractional bits: 0.01010101 = 0x55 = 85
	// Result: mantissa=85, scale=-8. 85 × 2^-8 = 85/256 ≈ 0.332 ≈ 1/3 - tiny
	try testing.expectEqual(@as(i64, 85), try r.mantissa.getI64());
	try testing.expectEqual(@as(i32, -8), r.scale);
}

test "M14-4: divQR reconstructs: quot * divisor + rem == dividend" {
	const a = testing.allocator;
	var num = Fp.init(a);
	defer num.deinit();
	var den = Fp.init(a);
	defer den.deinit();
	var q = Fp.init(a);
	defer q.deinit();
	var rem = Fp.init(a);
	defer rem.deinit();
	// 22 / 7 = 3 r 1
	try num.setI64(22, 0, .decimal);
	try den.setI64(7, 0, .decimal);
	try divQR(&q, &rem, &num, &den);
	try testing.expectEqual(@as(i64, 3), try q.mantissa.getI64());
	try testing.expectEqual(@as(i64, 1), try rem.mantissa.getI64());
	// Reconstruct: quot * den + rem == num
	var prod = Fp.init(a);
	defer prod.deinit();
	var sum = Fp.init(a);
	defer sum.deinit();
	try mul(&prod, &q, &den);
	try add(&sum, &prod, &rem);
	try testing.expect(try eq(&sum, &num));
}

test "M14-4: divQR with fractional dividend — 0.5 / 0.2 = 2 r 0.1" {
	const a = testing.allocator;
	var num = Fp.init(a);
	defer num.deinit();
	var den = Fp.init(a);
	defer den.deinit();
	var q = Fp.init(a);
	defer q.deinit();
	var rem = Fp.init(a);
	defer rem.deinit();
	try num.setRationalDecimal(1, 2);
	try den.setRationalDecimal(1, 5);
	try divQR(&q, &rem, &num, &den);
	// quotient should be 2 (integer floor of 2.5)
	try testing.expectEqual(@as(i64, 2), try q.mantissa.getI64());
	// rem = num - q*den = 0.5 - 2*0.2 = 0.1 — must reconstruct exactly
	var prod = Fp.init(a);
	defer prod.deinit();
	var sum = Fp.init(a);
	defer sum.deinit();
	try mul(&prod, &q, &den);
	try add(&sum, &prod, &rem);
	try testing.expect(try eq(&sum, &num));
}

test "M14-4: divQR by zero errors" {
	const a = testing.allocator;
	var num = Fp.init(a);
	defer num.deinit();
	var den = Fp.init(a);
	defer den.deinit();
	var q = Fp.init(a);
	defer q.deinit();
	var rem = Fp.init(a);
	defer rem.deinit();
	try num.setI64(7, 0, .decimal);
	try den.setI64(0, 0, .decimal);
	try testing.expectError(error.DivisionByZero, divQR(&q, &rem, &num, &den));
}

test "M14-4: divQR negative dividend — -22 / 7 follows truncating-quot semantics" {
	const a = testing.allocator;
	var num = Fp.init(a);
	defer num.deinit();
	var den = Fp.init(a);
	defer den.deinit();
	var q = Fp.init(a);
	defer q.deinit();
	var rem = Fp.init(a);
	defer rem.deinit();
	try num.setI64(-22, 0, .decimal);
	try den.setI64(7, 0, .decimal);
	try divQR(&q, &rem, &num, &den);
	// Reconstruction must be exact regardless of rounding direction.
	var prod = Fp.init(a);
	defer prod.deinit();
	var sum = Fp.init(a);
	defer sum.deinit();
	try mul(&prod, &q, &den);
	try add(&sum, &prod, &rem);
	try testing.expect(try eq(&sum, &num));
}

test "M14-5: toDecimal of base=10 fp is a trivial copy" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	try x.setRationalDecimal(7, 4); // 1.75
	try toDecimal(&y, &x);
	try testing.expect(try eq(&x, &y));
}

test "M14-5: toDecimal of base=2 0.5 (1 × 2^-1) → 5 × 10^-1 = 0.5 (always exact)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	try x.setI64(1, -1, .binary); // 0.5 in binary
	try toDecimal(&y, &x);
	try testing.expectEqual(Base.decimal, y.base);
	try testing.expectEqual(@as(i64, 5), try y.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), y.scale);
}

test "M14-5: toDecimal positive-scale binary — 3 × 2^4 = 48" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	try x.setI64(3, 4, .binary); // 3 × 16 = 48
	try toDecimal(&y, &x);
	try testing.expectEqual(@as(i64, 48), try y.mantissa.getI64());
	try testing.expectEqual(@as(i32, 0), y.scale);
}

test "M14-5: toDecimal of binary -1 × 2^-3 = -0.125" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	try x.setI64(-1, -3, .binary);
	try toDecimal(&y, &x);
	const s = try toStringCanonical(a, &y);
	defer a.free(s);
	try testing.expectEqualStrings("-0.125", s);
}

test "M14-5: toBinary of base=2 fp is a trivial copy" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	try x.setRationalBinary(3, 4);
	try toBinary(&y, &x);
	try testing.expect(try eq(&x, &y));
}

test "M14-5: toBinary of decimal 0.5 → 5 × 2^-1 (terminates)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	try x.setRationalDecimal(1, 2); // 5 × 10^-1
	try toBinary(&y, &x);
	try testing.expectEqual(Base.binary, y.base);
	// 0.5 = 1 × 2^-1; the toBinary impl divides 5 by 5^1 and gives 1 × 2^-1.
	try testing.expectEqual(@as(i64, 1), try y.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), y.scale);
}

test "M14-5: toBinary of decimal 0.1 errors NonTerminatingExpansion (the IEEE754 confession)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	try x.setRationalDecimal(1, 10);
	try testing.expectError(error.NonTerminatingExpansion, toBinary(&y, &x));
}

test "M14-5: toBinary of decimal integer 25 → 25 × 2^0 (always exact for integers)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	try x.setI64(25, 0, .decimal);
	try toBinary(&y, &x);
	try testing.expectEqual(@as(i64, 25), try y.mantissa.getI64());
	try testing.expectEqual(@as(i32, 0), y.scale);
}

test "M14-6: roundToScale(.exact_or_error) errors when target scale would lose info" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setStr("3.14", .decimal); // mant=314 scale=-2
	try testing.expectError(error.NonTerminatingExpansion, roundToScale(&r, &x, -1, .exact_or_error));
}

test "M14-6: roundToScale(.exact_or_error) succeeds when no info would be lost" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setStr("3.10", .decimal); // mant=310 scale=-2
	try roundToScale(&r, &x, -1, .exact_or_error);
	try testing.expectEqual(@as(i64, 31), try r.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), r.scale);
}

test "M14-6: roundToScale extends precision when target_scale < a.scale (always exact)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setStr("3.14", .decimal); // scale=-2
	try roundToScale(&r, &x, -4, .exact_or_error); // gain 2 digits
	try testing.expectEqual(@as(i64, 31400), try r.mantissa.getI64());
	try testing.expectEqual(@as(i32, -4), r.scale);
}

test "M14-6: roundToScale(.toward_zero) truncates magnitude — positives" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setStr("3.19", .decimal);
	try roundToScale(&r, &x, -1, .toward_zero);
	try testing.expectEqual(@as(i64, 31), try r.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), r.scale);
}

test "M14-6: roundToScale(.toward_zero) truncates magnitude — negatives" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setStr("-3.19", .decimal);
	try roundToScale(&r, &x, -1, .toward_zero);
	try testing.expectEqual(@as(i64, -31), try r.mantissa.getI64());
}

test "M14-6: roundToScale(.toward_pos_inf) — ceiling, positives go up" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setStr("3.11", .decimal);
	try roundToScale(&r, &x, -1, .toward_pos_inf);
	try testing.expectEqual(@as(i64, 32), try r.mantissa.getI64());
	// negatives: ceiling of -3.19 at scale -1 == -3.1 (toward zero from below)
	try x.setStr("-3.19", .decimal);
	try roundToScale(&r, &x, -1, .toward_pos_inf);
	try testing.expectEqual(@as(i64, -31), try r.mantissa.getI64());
}

test "M14-6: roundToScale(.toward_neg_inf) — floor, negatives go down" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setStr("-3.11", .decimal);
	try roundToScale(&r, &x, -1, .toward_neg_inf);
	try testing.expectEqual(@as(i64, -32), try r.mantissa.getI64());
	try x.setStr("3.19", .decimal);
	try roundToScale(&r, &x, -1, .toward_neg_inf);
	try testing.expectEqual(@as(i64, 31), try r.mantissa.getI64());
}

test "M14-6: roundToScale(.half_up) — ties round away from zero" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	// 2.5 → 3
	try x.setStr("2.5", .decimal);
	try roundToScale(&r, &x, 0, .half_up);
	try testing.expectEqual(@as(i64, 3), try r.mantissa.getI64());
	// -2.5 → -3 (away from zero)
	try x.setStr("-2.5", .decimal);
	try roundToScale(&r, &x, 0, .half_up);
	try testing.expectEqual(@as(i64, -3), try r.mantissa.getI64());
	// 2.4 → 2 (under tie threshold)
	try x.setStr("2.4", .decimal);
	try roundToScale(&r, &x, 0, .half_up);
	try testing.expectEqual(@as(i64, 2), try r.mantissa.getI64());
	// 2.6 → 3
	try x.setStr("2.6", .decimal);
	try roundToScale(&r, &x, 0, .half_up);
	try testing.expectEqual(@as(i64, 3), try r.mantissa.getI64());
}

test "M14-6: roundToScale(.half_to_even) banker's rounding — ties go to even" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	// 2.5 → 2 (2 is even)
	try x.setStr("2.5", .decimal);
	try roundToScale(&r, &x, 0, .half_to_even);
	try testing.expectEqual(@as(i64, 2), try r.mantissa.getI64());
	// 3.5 → 4 (4 is even)
	try x.setStr("3.5", .decimal);
	try roundToScale(&r, &x, 0, .half_to_even);
	try testing.expectEqual(@as(i64, 4), try r.mantissa.getI64());
	// -2.5 → -2 (mag 2 is even)
	try x.setStr("-2.5", .decimal);
	try roundToScale(&r, &x, 0, .half_to_even);
	try testing.expectEqual(@as(i64, -2), try r.mantissa.getI64());
	// 2.51 → 3 (over the tie threshold)
	try x.setStr("2.51", .decimal);
	try roundToScale(&r, &x, 0, .half_to_even);
	try testing.expectEqual(@as(i64, 3), try r.mantissa.getI64());
}

test "M14-6: roundToScale binary base — 0.111₂ rounded to scale -1 (.half_up) = 0.1₂ × 2^0 boundary" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	// 0.111 binary = 7 × 2^-3 = 0.875 dec
	try x.setI64(7, -3, .binary);
	try roundToScale(&r, &x, -1, .half_up);
	// 7 / 4 = (1, 3); 2*3 = 6 > 4 → round up → 2 mag.
	// Result: 2 × 2^-1 = 1.0 dec.
	try testing.expectEqual(@as(i64, 2), try r.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), r.scale);
}

test "M14-6: roundToMp drops fractional part — π → 3 (toward_zero)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var r = Mp.init(a);
	defer r.deinit();
	try x.setStr("3.14159", .decimal);
	try roundToMp(&r, &x, .toward_zero);
	try testing.expectEqual(@as(i64, 3), try r.getI64());
	// Half-up rounds up: 3.5 → 4
	try x.setStr("3.5", .decimal);
	try roundToMp(&r, &x, .half_up);
	try testing.expectEqual(@as(i64, 4), try r.getI64());
	// Banker on 2.5 → 2
	try x.setStr("2.5", .decimal);
	try roundToMp(&r, &x, .half_to_even);
	try testing.expectEqual(@as(i64, 2), try r.getI64());
}

test "M14-7: toStringCanonical of 0 → \"0\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	const s = try toStringCanonical(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("0", s);
}

test "M14-7: toStringCanonical of 314 × 10^-2 → \"3.14\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(314, -2, .decimal);
	const s = try toStringCanonical(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("3.14", s);
}

test "M14-7: toStringCanonical of 125 × 10^-3 → \"0.125\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(125, -3, .decimal);
	const s = try toStringCanonical(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("0.125", s);
}

test "M14-7: toStringCanonical of 25 × 10^-3 → \"0.025\" (leading zero pad)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(25, -3, .decimal);
	const s = try toStringCanonical(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("0.025", s);
}

test "M14-7: toStringCanonical of 15 × 10^2 → \"1500\" (positive scale)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(15, 2, .decimal);
	const s = try toStringCanonical(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("1500", s);
}

test "M14-7: toStringCanonical preserves sign — -1/4 → \"-0.25\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setRationalDecimal(-1, 4);
	const s = try toStringCanonical(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("-0.25", s);
}

test "M14-7: HEADLINE — toStringCanonical(0.1 + 0.2) prints exactly \"0.3\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var r = Fp.init(a);
	defer r.deinit();
	try x.setRationalDecimal(1, 10);
	try y.setRationalDecimal(2, 10);
	try add(&r, &x, &y);
	try r.canonicalize();
	const s = try toStringCanonical(a, &r);
	defer a.free(s);
	try testing.expectEqualStrings("0.3", s);
}

test "M14-7: toStringCanonical binary 11 × 2^-2 → \"0.11\" (= 0.75 dec)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setRationalBinary(3, 4); // 3 × 2^-2 = 0.11 binary = 0.75 decimal
	const s = try toStringCanonical(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("0.11", s);
}

test "M14-8: setF64(0.0) → zero" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setF64(0.0);
	try testing.expect(x.isZero());
}

test "M14-8: setF64(-0.0) → zero (no signed zero distinction)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setF64(-0.0);
	try testing.expect(x.isZero());
}

test "M14-8: setF64(1.0) canonicalizes to 1 × 2^0" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setF64(1.0);
	try x.canonicalize();
	try testing.expectEqual(@as(i64, 1), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, 0), x.scale);
	try testing.expectEqual(Base.binary, x.base);
}

test "M14-8: setF64(0.5) canonicalizes to 1 × 2^-1" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setF64(0.5);
	try x.canonicalize();
	try testing.expectEqual(@as(i64, 1), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -1), x.scale);
}

test "M14-8: setF64(-2.0) → -1 × 2^1 after canonicalize" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setF64(-2.0);
	try x.canonicalize();
	try testing.expectEqual(@as(i64, -1), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, 1), x.scale);
}

test "M14-8: setF64(0.1) — proves IEEE754 lies (non-canonical-1)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setF64(0.1);
	try x.canonicalize();
	// 0.1f64 is exactly 0xCCCCCCCCCCCCCD × 2^-55 = 3602879701896397 × 2^-55
	// (the mantissa with one trailing zero bit stripped from raw 0x1999999999999A × 2^-56)
	try testing.expectEqual(@as(i64, 3602879701896397), try x.mantissa.getI64());
	try testing.expectEqual(@as(i32, -55), x.scale);
}

test "M14-8 KILLSHOT: setF64(0.1) → toDecimal → prints the exact 55-digit lie IEEE754 hides" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var d = Fp.init(a);
	defer d.deinit();
	try x.setF64(0.1);
	try toDecimal(&d, &x);
	try d.canonicalize();
	const s = try toStringCanonical(a, &d);
	defer a.free(s);
	try testing.expectEqualStrings("0.1000000000000000055511151231257827021181583404541015625", s);
}

test "M14-8 KILLSHOT 2: setF64(0.1) + setF64(0.2) ≠ setF64(0.3) (the famous IEEE754 disaster)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	var y = Fp.init(a);
	defer y.deinit();
	var z = Fp.init(a);
	defer z.deinit();
	var s = Fp.init(a);
	defer s.deinit();
	try x.setF64(0.1);
	try y.setF64(0.2);
	try z.setF64(0.3);
	try add(&s, &x, &y);
	try testing.expect(!(try eq(&s, &z))); // s and z DIFFER — IEEE754 caught in the act
}

test "M14-8: setF64(NaN) errors NotRepresentable" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	const nan = std.math.nan(f64);
	try testing.expectError(error.NotRepresentable, x.setF64(nan));
}

test "M14-8: setF64(+inf) errors NotRepresentable" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	const inf = std.math.inf(f64);
	try testing.expectError(error.NotRepresentable, x.setF64(inf));
}

test "M14-8: setF64(-inf) errors NotRepresentable" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	const inf = -std.math.inf(f64);
	try testing.expectError(error.NotRepresentable, x.setF64(inf));
}

test "M14-8: getF64Exact round-trips setF64 — 0.0, 1.0, 0.5, -0.25, π-as-f64" {
	const a = testing.allocator;
	const cases = [_]f64{ 0.0, 1.0, -1.0, 0.5, -0.25, 0.1, 0.2, 0.3, 1024.0, -1024.0, 3.14159, std.math.floatMin(f64) };
	for (cases) |v| {
		var x = Fp.init(a);
		defer x.deinit();
		try x.setF64(v);
		const round_tripped = try x.getF64Exact();
		try testing.expectEqual(v, round_tripped);
	}
}

test "M14-8: getF64Exact errors NotRepresentable for values needing >53 mantissa bits" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	// Mantissa with 54 significant bits: 2^53 + 1.
	try x.setI64(@as(i64, 1) << 53 | 1, 0, .binary);
	try testing.expectError(error.NotRepresentable, x.getF64Exact());
}

test "M14-8: getF64Exact errors NotRepresentable on decimal non-terminating in binary" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setRationalDecimal(1, 10); // 0.1 decimal — no terminating binary
	try testing.expectError(error.NonTerminatingExpansion, x.getF64Exact());
}

test "M14-8: getF64Exact recovers a decimal value that DOES have an exact binary form" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setRationalDecimal(1, 4); // 0.25 — exact in both bases
	try testing.expectEqual(@as(f64, 0.25), try x.getF64Exact());
}

// ── M14-7b: toStringFixed ──────────────────────────────────────────────────

test "M14-7b: toStringFixed pads canonical with trailing zeros (3.14, 4) → \"3.1400\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("3.14", .decimal);
	const s = try toStringFixed(a, &x, 4);
	defer a.free(s);
	try testing.expectEqualStrings("3.1400", s);
}

test "M14-7b: toStringFixed with frac_digits matching scale (0.1, 2) → \"0.10\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("0.1", .decimal);
	const s = try toStringFixed(a, &x, 2);
	defer a.free(s);
	try testing.expectEqualStrings("0.10", s);
}

test "M14-7b: toStringFixed truncates with banker's rounding (3.149, 2) → \"3.15\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("3.149", .decimal);
	const s = try toStringFixed(a, &x, 2);
	defer a.free(s);
	try testing.expectEqualStrings("3.15", s);
}

test "M14-7b: toStringFixed banker tie-to-even (2.5, 0) → \"2\" (no decimal point)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("2.5", .decimal);
	const s = try toStringFixed(a, &x, 0);
	defer a.free(s);
	try testing.expectEqualStrings("2", s);
}

test "M14-7b: toStringFixed banker on negative tie (-0.125, 2) → \"-0.12\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("-0.125", .decimal);
	const s = try toStringFixed(a, &x, 2);
	defer a.free(s);
	try testing.expectEqualStrings("-0.12", s);
}

test "M14-7b: toStringFixed of zero pads with zeros (0, 3) → \"0.000\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(0, 0, .decimal);
	const s = try toStringFixed(a, &x, 3);
	defer a.free(s);
	try testing.expectEqualStrings("0.000", s);
}

test "M14-7b: toStringFixed of zero with frac_digits=0 → \"0\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(0, 0, .decimal);
	const s = try toStringFixed(a, &x, 0);
	defer a.free(s);
	try testing.expectEqualStrings("0", s);
}

test "M14-7b: toStringFixed of integer (42, 2) → \"42.00\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(42, 0, .decimal);
	const s = try toStringFixed(a, &x, 2);
	defer a.free(s);
	try testing.expectEqualStrings("42.00", s);
}

test "M14-7b: toStringFixed in binary base (0.5_b, 3) → \"0.100\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("0.1", .binary); // 1 × 2^-1
	const s = try toStringFixed(a, &x, 3);
	defer a.free(s);
	try testing.expectEqualStrings("0.100", s);
}

// ── M14-7c: toStringScientific ─────────────────────────────────────────────

test "M14-7c: toStringScientific decimal 3.14 → \"3.14e0\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("3.14", .decimal);
	const s = try toStringScientific(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("3.14e0", s);
}

test "M14-7c: toStringScientific decimal 0.001 → \"1e-3\" (no fractional digits)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("0.001", .decimal);
	const s = try toStringScientific(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("1e-3", s);
}

test "M14-7c: toStringScientific decimal 1500 → \"1.5e3\" (canonical strips trailing zeros)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(1500, 0, .decimal);
	const s = try toStringScientific(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("1.5e3", s);
}

test "M14-7c: toStringScientific decimal -0.025 → \"-2.5e-2\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setStr("-0.025", .decimal);
	const s = try toStringScientific(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("-2.5e-2", s);
}

test "M14-7c: toStringScientific zero → \"0\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(0, 0, .decimal);
	const s = try toStringScientific(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("0", s);
}

test "M14-7c: toStringScientific decimal single digit 5 → \"5e0\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(5, 0, .decimal);
	const s = try toStringScientific(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("5e0", s);
}

test "M14-7c: toStringScientific binary 0.75 = 3 × 2^-2 → \"1.1p-1\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(3, -2, .binary);
	const s = try toStringScientific(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("1.1p-1", s);
}

test "M14-7c: toStringScientific binary 1 → \"1p0\"" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(1, 0, .binary);
	const s = try toStringScientific(a, &x);
	defer a.free(s);
	try testing.expectEqualStrings("1p0", s);
}

// ── M14-8: getF64(mode) ────────────────────────────────────────────────────

test "M14-8: getF64(.exact_or_error) on exact value matches getF64Exact" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setRationalDecimal(1, 4); // 0.25
	try testing.expectEqual(@as(f64, 0.25), try x.getF64(.exact_or_error));
}

test "M14-8: getF64(.exact_or_error) on >53-bit value errors NotRepresentable (matches getF64Exact)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(@as(i64, 1) << 53 | 1, 0, .binary); // 2^53 + 1
	try testing.expectError(error.NotRepresentable, x.getF64(.exact_or_error));
}

test "M14-8: getF64(.half_to_even) rounds 2^53 + 1 → 2^53 (banker tie picks even)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(@as(i64, 1) << 53 | 1, 0, .binary); // 2^53 + 1
	// Nearest f64 below: 2^53. Above: 2^53 + 2 (gap is 2 at this magnitude).
	// 2^53 + 1 is exactly halfway. Banker rounds to even → 2^53.
	const got = try x.getF64(.half_to_even);
	try testing.expectEqual(@as(f64, @floatFromInt(@as(i64, 1) << 53)), got);
}

test "M14-8: getF64(.half_to_even) rounds 2^53 + 3 → 2^53 + 4 (banker tie picks even)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(@as(i64, 1) << 53 | 3, 0, .binary); // 2^53 + 3
	// Nearest f64 below: 2^53 + 2. Above: 2^53 + 4. 2^53+3 is halfway.
	// Banker → even → 2^53 + 4.
	const got = try x.getF64(.half_to_even);
	try testing.expectEqual(@as(f64, @floatFromInt((@as(i64, 1) << 53) + 4)), got);
}

test "M14-8: getF64(.toward_zero) on 2^53 + 1 → 2^53" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(@as(i64, 1) << 53 | 1, 0, .binary);
	const got = try x.getF64(.toward_zero);
	try testing.expectEqual(@as(f64, @floatFromInt(@as(i64, 1) << 53)), got);
}

test "M14-8: getF64(.toward_pos_inf) on 2^53 + 1 → 2^53 + 2" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(@as(i64, 1) << 53 | 1, 0, .binary);
	const got = try x.getF64(.toward_pos_inf);
	try testing.expectEqual(@as(f64, @floatFromInt((@as(i64, 1) << 53) + 2)), got);
}

test "M14-8: getF64(any mode) on decimal-with-no-terminating-binary still errors NonTerminating" {
	// Per spec: toBinary errors before rounding kicks in. The brief calls
	// this out explicitly — the caller chose decimal; we don't smuggle a
	// silent decimal→binary truncation under the hood.
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setRationalDecimal(1, 10); // 0.1₁₀
	try testing.expectError(error.NonTerminatingExpansion, x.getF64(.half_to_even));
	try testing.expectError(error.NonTerminatingExpansion, x.getF64(.toward_zero));
}

test "M14-8: getF64(.half_to_even) carry-up case: 2^54 - 1 → 2^54" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	// 2^54 - 1 = 0x3FFFFFFFFFFFFF — 54 bits all set.
	try x.setI64((@as(i64, 1) << 54) - 1, 0, .binary);
	// Half-to-even: drop bit 0 (which is 1), tie? No — we drop 1 bit only,
	// and the dropped value is exactly half. quot's low bit is 1 (odd) before
	// rounding; banker bumps to even → 2^53. Then carry: 2^53 + 1 then
	// renormalized? Actually quot = (2^54 - 1) >> 1 = 2^53 - 1 (odd, banker
	// bumps), → 2^53. So result = 2^53 × 2 = 2^54.
	const got = try x.getF64(.half_to_even);
	try testing.expectEqual(@as(f64, @floatFromInt(@as(i64, 1) << 54)), got);
}

test "M14-8: getF64(.half_to_even) on negative 2^53 + 1 → -(2^53)" {
	const a = testing.allocator;
	var x = Fp.init(a);
	defer x.deinit();
	try x.setI64(-(@as(i64, 1) << 53 | 1), 0, .binary);
	const got = try x.getF64(.half_to_even);
	try testing.expectEqual(@as(f64, -@as(f64, @floatFromInt(@as(i64, 1) << 53))), got);
}
