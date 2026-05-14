// c_api.zig — public C FFI for blip_mp.
//
// This is the layer that downstream C/Rust/Lua/Python consumers link
// against. The exported symbols mirror `include/blip_mp.h`. All internal
// allocations go through `std.heap.c_allocator` so the lifetime model
// matches libc (callers may freely mix blip_mp handles with their own
// malloc'd memory).
//
// Error mapping: Zig errors are flattened into the small set of
// BLIP_MP_ERR_* integer codes declared in the header. Unknown errors fall
// back to BLIP_MP_ERR_INVALID_INPUT (paranoid default).

const std = @import("std");
const blip_mp = @import("blip_mp.zig");
const Mp = blip_mp.Mp;

const allocator = std.heap.c_allocator;

// Public error codes — kept in lockstep with include/blip_mp.h.
pub const BLIP_MP_OK: c_int = 0;
pub const BLIP_MP_ERR_DIVISION_BY_ZERO: c_int = 1;
pub const BLIP_MP_ERR_OUT_OF_MEMORY: c_int = 2;
pub const BLIP_MP_ERR_NOT_IMPLEMENTED: c_int = 3;
pub const BLIP_MP_ERR_INVALID_INPUT: c_int = 4;
pub const BLIP_MP_ERR_OUT_OF_RANGE: c_int = 5;
pub const BLIP_MP_ERR_NO_INVERSE: c_int = 6;
pub const BLIP_MP_ERR_NEGATIVE_OPERAND: c_int = 7;
pub const BLIP_MP_ERR_BUFFER_TOO_SMALL: c_int = 8;
pub const BLIP_MP_ERR_MIXED_BASES: c_int = 9;
pub const BLIP_MP_ERR_NON_TERMINATING: c_int = 10;
pub const BLIP_MP_ERR_NOT_REPRESENTABLE: c_int = 11;

/// Translate a Zig error from any of `Mp`'s error sets into the C code
/// surface. Centralised so every export uses the same mapping rules.
fn mapError(err: anyerror) c_int {
	return switch (err) {
		error.DivisionByZero => BLIP_MP_ERR_DIVISION_BY_ZERO,
		error.OutOfMemory => BLIP_MP_ERR_OUT_OF_MEMORY,
		error.NotImplementedTier3, error.NegativeExponentNotSupported => BLIP_MP_ERR_NOT_IMPLEMENTED,
		error.UnsignedTooLarge, error.OutputBufferTooSmall, error.TierOverflow => BLIP_MP_ERR_OUT_OF_RANGE,
		error.SentinelValue, error.ValueIsNegative => BLIP_MP_ERR_OUT_OF_RANGE,
		error.NegativeOperand => BLIP_MP_ERR_NEGATIVE_OPERAND,
		error.BufferTooSmall, error.UnexpectedEndOfInput, error.OverlongEncoding => BLIP_MP_ERR_INVALID_INPUT,
		error.EmptyString, error.InvalidDigit, error.UnsupportedBase => BLIP_MP_ERR_INVALID_INPUT,
		error.ZeroExponent, error.ModulusMustBeOddPositive => BLIP_MP_ERR_INVALID_INPUT,
		error.MixedBases => BLIP_MP_ERR_MIXED_BASES,
		error.NonTerminatingExpansion => BLIP_MP_ERR_NON_TERMINATING,
		error.NotRepresentable => BLIP_MP_ERR_NOT_REPRESENTABLE,
		else => BLIP_MP_ERR_INVALID_INPUT,
	};
}

// --- Lifecycle ---------------------------------------------------------

export fn blip_mp_create() ?*Mp {
	const mp = allocator.create(Mp) catch return null;
	mp.* = Mp.init(allocator);
	return mp;
}

export fn blip_mp_destroy(mp: ?*Mp) void {
	if (mp) |m| {
		m.deinit();
		allocator.destroy(m);
	}
}

// --- Setters / getters -------------------------------------------------

export fn blip_mp_set_i64(mp: *Mp, value: i64) c_int {
	mp.setI64(value) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_get_i64(mp: *const Mp, out: *i64) c_int {
	const v = mp.getI64() catch |e| return mapError(e);
	out.* = v;
	return BLIP_MP_OK;
}

export fn blip_mp_set_u64(mp: *Mp, value: u64) c_int {
	mp.setU64(value) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_get_u64(mp: *const Mp, out: *u64) c_int {
	const v = mp.getU64() catch |e| return mapError(e);
	out.* = v;
	return BLIP_MP_OK;
}

// --- Bit access ---------------------------------------------------------

// Returns the i-th bit of the magnitude (0 or 1). i indexes from the LSB.
// Out-of-range bit positions read as 0 (the magnitude implicitly extends with
// leading zeros). Sign is ignored (operates on the absolute magnitude).
// Used by downstream consumers implementing custom scalar-mul / sliding-window
// algorithms over the BLIP-encoded value.
export fn blip_mp_bit_at(mp: *const Mp, i: usize) c_int {
	return @intCast(mp.bitAt(i));
}

// Returns the bit length of the magnitude (1 + position of the highest set
// bit). Returns 0 for value 0. Sign is ignored.
export fn blip_mp_bit_len(mp: *const Mp) usize {
	return mp.bitLen();
}

export fn blip_mp_set_bytes(mp: *Mp, bytes: [*]const u8, len: usize) c_int {
	const slice = bytes[0..len];
	mp.setBytes(slice) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_byte_len(mp: *const Mp) usize {
	return mp.bytes().len;
}

export fn blip_mp_bytes(mp: ?*const Mp) ?[*]const u8 {
	if (mp) |m| {
		const b = m.bytes();
		if (b.len == 0) return null;
		return b.ptr;
	}
	return null;
}

// --- Comparison / sign --------------------------------------------------

export fn blip_mp_cmp(a: *const Mp, b: *const Mp) c_int {
	// Mp.cmp is now error-free and tier-3-aware (sign-first dispatch +
	// byte-level magnitude comparison; no i64 overflow risk).
	return switch (a.cmp(b)) {
		.lt => -1,
		.eq => 0,
		.gt => 1,
	};
}

export fn blip_mp_sign(mp: *const Mp) c_int {
	return @intCast(mp.cachedSign());
}

export fn blip_mp_is_zero(mp: *const Mp) c_int {
	return if (mp.cachedSign() == 0) 1 else 0;
}

// --- Arithmetic --------------------------------------------------------

export fn blip_mp_add(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	r.add(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_sub(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	r.sub(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_mul(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	r.mul(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_div(q: *Mp, a: *const Mp, b: *const Mp) c_int {
	q.div(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_mod(rem: *Mp, a: *const Mp, b: *const Mp) c_int {
	rem.mod(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_div_mod(q: *Mp, rem: *Mp, a: *const Mp, b: *const Mp) c_int {
	Mp.divMod(q, rem, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_powm(r: *Mp, base: *const Mp, exp: *const Mp, m: *const Mp) c_int {
	r.powm(base, exp, m) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_inv_mod(r: *Mp, a: *const Mp, m: *const Mp) c_int {
	const ok = r.invMod(a, m) catch |e| return mapError(e);
	return if (ok) BLIP_MP_OK else BLIP_MP_ERR_NO_INVERSE;
}

// --- Bitwise (M12-A1) ---------------------------------------------------

export fn blip_mp_and(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	blip_mp.bitwise.bitwiseAnd(r, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_or(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	blip_mp.bitwise.bitwiseOr(r, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_xor(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	blip_mp.bitwise.bitwiseXor(r, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_not(r: *Mp, a: *const Mp) c_int {
	blip_mp.bitwise.bitwiseNot(r, a) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_shl(r: *Mp, a: *const Mp, n: usize) c_int {
	blip_mp.bitwise.shl(r, a, n) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_shr(r: *Mp, a: *const Mp, n: usize) c_int {
	blip_mp.bitwise.shr(r, a, n) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

// --- Sign / abs / fits (M12-A2) -----------------------------------------

export fn blip_mp_neg(r: *Mp, a: *const Mp) c_int {
	blip_mp.sign.neg(r, a) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_abs(r: *Mp, a: *const Mp) c_int {
	blip_mp.sign.abs(r, a) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fits_i64(mp: *const Mp) c_int {
	return if (blip_mp.sign.fitsI64(mp)) 1 else 0;
}

export fn blip_mp_fits_u64(mp: *const Mp) c_int {
	return if (blip_mp.sign.fitsU64(mp)) 1 else 0;
}

export fn blip_mp_fits_i32(mp: *const Mp) c_int {
	return if (blip_mp.sign.fitsI32(mp)) 1 else 0;
}

export fn blip_mp_fits_u32(mp: *const Mp) c_int {
	return if (blip_mp.sign.fitsU32(mp)) 1 else 0;
}

// --- popcount / scan (M12-A6) -------------------------------------------

export fn blip_mp_popcount(mp: *const Mp) usize {
	return blip_mp.scan.popcount(mp);
}

export fn blip_mp_scan0(mp: *const Mp, start: usize) usize {
	return blip_mp.scan.scan0(mp, start);
}

export fn blip_mp_scan1(mp: *const Mp, start: usize) usize {
	return blip_mp.scan.scan1(mp, start);
}

// --- GCD / LCM (M12-A4) -------------------------------------------------

export fn blip_mp_gcd(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	blip_mp.gcd.gcd(r, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_lcm(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	blip_mp.gcd.lcm(r, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

// --- Random (M12-A5) ----------------------------------------------------
//
// Opaque RNG handle backed by std.Random.DefaultPrng. Allocated on the heap
// so it has stable identity / lifetime independent of the caller's stack.

const Rng = std.Random.DefaultPrng;

export fn blip_mp_rng_create(seed: u64) ?*Rng {
	const r = allocator.create(Rng) catch return null;
	r.* = Rng.init(seed);
	return r;
}

export fn blip_mp_rng_destroy(rng: ?*Rng) void {
	if (rng) |r| allocator.destroy(r);
}

export fn blip_mp_set_random_bits(mp: *Mp, rng: *Rng, bits: usize) c_int {
	blip_mp.random_mp.setRandomBits(mp, rng.random(), bits) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_set_random_below(mp: *Mp, rng: *Rng, n: *const Mp) c_int {
	blip_mp.random_mp.setRandomBelow(mp, rng.random(), n) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

// --- String I/O (M12-A3) ------------------------------------------------

export fn blip_mp_set_str(mp: *Mp, str: [*]const u8, str_len: usize, base: u8) c_int {
	const slice = str[0..str_len];
	blip_mp.string_io.setStr(mp, slice, base) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

/// Format mp in `base` (2/8/10/16) into the caller's buffer.
/// Always writes the required length to *required (= length of the formatted
/// string, NOT including a trailing NUL). If buf_len < required, returns
/// BLIP_MP_ERR_BUFFER_TOO_SMALL and the buffer contents are unspecified —
/// caller should reallocate to *required and retry. If buf_len >= required+1
/// the result is NUL-terminated for C convenience.
export fn blip_mp_to_string(
	mp: *const Mp,
	base: u8,
	buf: [*]u8,
	buf_len: usize,
	required: *usize,
) c_int {
	const s = blip_mp.string_io.toString(mp, allocator, base) catch |e| return mapError(e);
	defer allocator.free(s);
	required.* = s.len;
	if (buf_len < s.len) return BLIP_MP_ERR_BUFFER_TOO_SMALL;
	@memcpy(buf[0..s.len], s);
	if (buf_len > s.len) buf[s.len] = 0; // NUL-terminate when room
	return BLIP_MP_OK;
}

// --- Primality (M13-B1) -------------------------------------------------

export fn blip_mp_is_probably_prime(
	mp: *const Mp,
	rng: *Rng,
	witnesses: u32,
	out: *c_int,
) c_int {
	const verdict = blip_mp.primes.isProbablyPrime(mp, allocator, rng.random(), witnesses) catch |e| return mapError(e);
	out.* = if (verdict) 1 else 0;
	return BLIP_MP_OK;
}

export fn blip_mp_next_prime(out: *Mp, n: *const Mp, rng: *Rng) c_int {
	blip_mp.primes.nextPrime(out, n, allocator, rng.random()) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

// --- Roots (M13-B2) -----------------------------------------------------

export fn blip_mp_isqrt(out: *Mp, n: *const Mp) c_int {
	blip_mp.roots.isqrt(out, n) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_isqrt_rem(root: *Mp, rem: *Mp, n: *const Mp) c_int {
	blip_mp.roots.isqrtRem(root, rem, n) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_iroot(out: *Mp, n: *const Mp, k: u32) c_int {
	blip_mp.roots.iroot(out, n, k) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_is_perfect_square(mp: *const Mp) c_int {
	return if (blip_mp.roots.isPerfectSquare(mp)) 1 else 0;
}

// --- Symbols (M13-B3) ---------------------------------------------------

export fn blip_mp_jacobi(a: *const Mp, n: *const Mp, out: *c_int) c_int {
	const v = blip_mp.symbols.jacobi(a, n, allocator) catch |e| return mapError(e);
	out.* = @intCast(v);
	return BLIP_MP_OK;
}

export fn blip_mp_legendre(a: *const Mp, p: *const Mp, out: *c_int) c_int {
	const v = blip_mp.symbols.legendre(a, p, allocator) catch |e| return mapError(e);
	out.* = @intCast(v);
	return BLIP_MP_OK;
}

export fn blip_mp_kronecker(a: *const Mp, n: *const Mp, out: *c_int) c_int {
	const v = blip_mp.symbols.kronecker(a, n, allocator) catch |e| return mapError(e);
	out.* = @intCast(v);
	return BLIP_MP_OK;
}

// --- Combinatorial (M13-B4) ---------------------------------------------

export fn blip_mp_factorial(out: *Mp, n: u32) c_int {
	blip_mp.combinatorial.factorial(out, n) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_binomial(out: *Mp, n: u32, k: u32) c_int {
	blip_mp.combinatorial.binomial(out, n, k) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fibonacci(out: *Mp, n: u32) c_int {
	blip_mp.combinatorial.fibonacci(out, n) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

// ──────────────────────────────────────────────────────────────────────
// Fp — exact arbitrary-precision fixed-point (M14)
// ──────────────────────────────────────────────────────────────────────
//
// The IEEE754-disruption type. Each Fp carries (mantissa, scale, base);
// every operation either succeeds bit-exactly, takes a caller-supplied
// precision budget, or errors loudly. No NaN, no ±∞, no signed zero,
// no denormals, no silent rounding.

const Fp = blip_mp.Fp;

// Mirror the Zig Base enum's wire values exactly.
pub const BLIP_MP_FP_BASE_BINARY: c_int = 2;
pub const BLIP_MP_FP_BASE_DECIMAL: c_int = 10;

// Round modes — wire values match the Zig enum's ordinals.
pub const BLIP_MP_FP_ROUND_EXACT_OR_ERROR: c_int = 0;
pub const BLIP_MP_FP_ROUND_TOWARD_ZERO: c_int = 1;
pub const BLIP_MP_FP_ROUND_TOWARD_POS_INF: c_int = 2;
pub const BLIP_MP_FP_ROUND_TOWARD_NEG_INF: c_int = 3;
pub const BLIP_MP_FP_ROUND_HALF_UP: c_int = 4;
pub const BLIP_MP_FP_ROUND_HALF_DOWN: c_int = 5;
pub const BLIP_MP_FP_ROUND_HALF_TO_EVEN: c_int = 6;
pub const BLIP_MP_FP_ROUND_HALF_TO_ODD: c_int = 7;

fn baseFromC(b: c_int) ?blip_mp.fp.Base {
	return switch (b) {
		BLIP_MP_FP_BASE_BINARY => .binary,
		BLIP_MP_FP_BASE_DECIMAL => .decimal,
		else => null,
	};
}

fn roundFromC(m: c_int) ?blip_mp.fp.RoundMode {
	if (m < 0 or m > 7) return null;
	return @enumFromInt(@as(u3, @intCast(m)));
}

// --- Lifecycle ---------------------------------------------------------

export fn blip_mp_fp_create() ?*Fp {
	const fp = allocator.create(Fp) catch return null;
	fp.* = Fp.init(allocator);
	return fp;
}

export fn blip_mp_fp_destroy(fp: ?*Fp) void {
	if (fp) |f| {
		f.deinit();
		allocator.destroy(f);
	}
}

// --- Construction ------------------------------------------------------

export fn blip_mp_fp_set_i64(fp: *Fp, mantissa: i64, scale: i32, base: c_int) c_int {
	const b = baseFromC(base) orelse return BLIP_MP_ERR_INVALID_INPUT;
	fp.setI64(mantissa, scale, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fp_set_rational_decimal(fp: *Fp, num: i64, den: i64) c_int {
	fp.setRationalDecimal(num, den) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fp_set_rational_binary(fp: *Fp, num: i64, den: i64) c_int {
	fp.setRationalBinary(num, den) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fp_set_str(fp: *Fp, str: [*]const u8, str_len: usize, base: c_int) c_int {
	const b = baseFromC(base) orelse return BLIP_MP_ERR_INVALID_INPUT;
	const slice = str[0..str_len];
	fp.setStr(slice, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fp_set_f64(fp: *Fp, v: f64) c_int {
	fp.setF64(v) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

// --- Queries -----------------------------------------------------------

export fn blip_mp_fp_is_zero(fp: *const Fp) c_int {
	return if (fp.isZero()) 1 else 0;
}

export fn blip_mp_fp_get_base(fp: *const Fp) c_int {
	return @intFromEnum(fp.base);
}

export fn blip_mp_fp_get_scale(fp: *const Fp) i32 {
	return fp.scale;
}

/// Borrowed pointer into `fp.mantissa`. Valid until the next mutating
/// call on `fp`. Caller MUST NOT destroy the returned Mp (it's owned by
/// the Fp). Caller MAY pass it to read-only `blip_mp_*` operations.
export fn blip_mp_fp_get_mantissa(fp: *Fp) *blip_mp.Mp {
	return &fp.mantissa;
}

// --- Canonical form ----------------------------------------------------

export fn blip_mp_fp_canonicalize(fp: *Fp) c_int {
	fp.canonicalize() catch |e| return mapError(e);
	return BLIP_MP_OK;
}

// --- Comparison --------------------------------------------------------

export fn blip_mp_fp_cmp(a: *const Fp, b: *const Fp, out: *c_int) c_int {
	const order = blip_mp.fp.cmp(a, b) catch |e| return mapError(e);
	out.* = switch (order) {
		.lt => -1,
		.eq => 0,
		.gt => 1,
	};
	return BLIP_MP_OK;
}

export fn blip_mp_fp_eq(a: *const Fp, b: *const Fp, out: *c_int) c_int {
	const eq_val = blip_mp.fp.eq(a, b) catch |e| return mapError(e);
	out.* = if (eq_val) 1 else 0;
	return BLIP_MP_OK;
}

// --- Arithmetic --------------------------------------------------------

export fn blip_mp_fp_add(r: *Fp, a: *const Fp, b: *const Fp) c_int {
	blip_mp.fp.add(r, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fp_sub(r: *Fp, a: *const Fp, b: *const Fp) c_int {
	blip_mp.fp.sub(r, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fp_mul(r: *Fp, a: *const Fp, b: *const Fp) c_int {
	blip_mp.fp.mul(r, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fp_div_exact(r: *Fp, a: *const Fp, b: *const Fp) c_int {
	blip_mp.fp.divExact(r, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

/// Caller passes `max_scale_digits`. *out_exact is set to 1 if the result
/// is bit-exact, 0 if it had to truncate. Lossiness never silent.
export fn blip_mp_fp_div_precision(
	r: *Fp,
	a: *const Fp,
	b: *const Fp,
	max_scale_digits: u32,
	out_exact: *c_int,
) c_int {
	const exact = blip_mp.fp.divPrecision(r, a, b, max_scale_digits) catch |e| return mapError(e);
	out_exact.* = if (exact) 1 else 0;
	return BLIP_MP_OK;
}

// --- Cross-base conversion --------------------------------------------

export fn blip_mp_fp_to_decimal(out: *Fp, x: *const Fp) c_int {
	blip_mp.fp.toDecimal(out, x) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fp_to_binary(out: *Fp, x: *const Fp) c_int {
	blip_mp.fp.toBinary(out, x) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

// --- Rounding ----------------------------------------------------------

export fn blip_mp_fp_round_to_scale(out: *Fp, a: *const Fp, target_scale: i32, mode: c_int) c_int {
	const m = roundFromC(mode) orelse return BLIP_MP_ERR_INVALID_INPUT;
	blip_mp.fp.roundToScale(out, a, target_scale, m) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_fp_round_to_mp(out: *blip_mp.Mp, a: *const Fp, mode: c_int) c_int {
	const m = roundFromC(mode) orelse return BLIP_MP_ERR_INVALID_INPUT;
	blip_mp.fp.roundToMp(out, a, m) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

// --- String I/O --------------------------------------------------------

/// Format `fp` as a canonical string into the caller's buffer. Writes
/// the required length to *required (excluding any NUL). If buf_len <
/// required, returns BUFFER_TOO_SMALL — caller realloc-then-retry pattern.
/// When buf_len > required, the buffer is NUL-terminated for C convenience.
export fn blip_mp_fp_to_string_canonical(
	fp: *const Fp,
	buf: [*]u8,
	buf_len: usize,
	required: *usize,
) c_int {
	const s = blip_mp.fp.toStringCanonical(allocator, fp) catch |e| return mapError(e);
	defer allocator.free(s);
	required.* = s.len;
	if (buf_len < s.len) return BLIP_MP_ERR_BUFFER_TOO_SMALL;
	@memcpy(buf[0..s.len], s);
	if (buf_len > s.len) buf[s.len] = 0;
	return BLIP_MP_OK;
}

// Force the linker to retain every exported symbol when compiled as part
// of a library (otherwise ReleaseFast may strip unreferenced exports).
comptime {
	_ = blip_mp_create;
	_ = blip_mp_set_u64;
	_ = blip_mp_get_u64;
	_ = blip_mp_bit_at;
	_ = blip_mp_bit_len;
	_ = blip_mp_destroy;
	_ = blip_mp_set_i64;
	_ = blip_mp_get_i64;
	_ = blip_mp_set_bytes;
	_ = blip_mp_byte_len;
	_ = blip_mp_bytes;
	_ = blip_mp_cmp;
	_ = blip_mp_sign;
	_ = blip_mp_is_zero;
	_ = blip_mp_add;
	_ = blip_mp_sub;
	_ = blip_mp_mul;
	_ = blip_mp_div;
	_ = blip_mp_mod;
	_ = blip_mp_div_mod;
	_ = blip_mp_powm;
	_ = blip_mp_inv_mod;
	// M12 / M13 additions
	_ = blip_mp_and;
	_ = blip_mp_or;
	_ = blip_mp_xor;
	_ = blip_mp_not;
	_ = blip_mp_shl;
	_ = blip_mp_shr;
	_ = blip_mp_neg;
	_ = blip_mp_abs;
	_ = blip_mp_fits_i64;
	_ = blip_mp_fits_u64;
	_ = blip_mp_fits_i32;
	_ = blip_mp_fits_u32;
	_ = blip_mp_popcount;
	_ = blip_mp_scan0;
	_ = blip_mp_scan1;
	_ = blip_mp_gcd;
	_ = blip_mp_lcm;
	_ = blip_mp_rng_create;
	_ = blip_mp_rng_destroy;
	_ = blip_mp_set_random_bits;
	_ = blip_mp_set_random_below;
	_ = blip_mp_set_str;
	_ = blip_mp_to_string;
	_ = blip_mp_is_probably_prime;
	_ = blip_mp_next_prime;
	_ = blip_mp_isqrt;
	_ = blip_mp_isqrt_rem;
	_ = blip_mp_iroot;
	_ = blip_mp_is_perfect_square;
	_ = blip_mp_jacobi;
	_ = blip_mp_legendre;
	_ = blip_mp_kronecker;
	_ = blip_mp_factorial;
	_ = blip_mp_binomial;
	_ = blip_mp_fibonacci;
	// M14 Fp additions
	_ = blip_mp_fp_create;
	_ = blip_mp_fp_destroy;
	_ = blip_mp_fp_set_i64;
	_ = blip_mp_fp_set_rational_decimal;
	_ = blip_mp_fp_set_rational_binary;
	_ = blip_mp_fp_set_str;
	_ = blip_mp_fp_set_f64;
	_ = blip_mp_fp_is_zero;
	_ = blip_mp_fp_get_base;
	_ = blip_mp_fp_get_scale;
	_ = blip_mp_fp_get_mantissa;
	_ = blip_mp_fp_canonicalize;
	_ = blip_mp_fp_cmp;
	_ = blip_mp_fp_eq;
	_ = blip_mp_fp_add;
	_ = blip_mp_fp_sub;
	_ = blip_mp_fp_mul;
	_ = blip_mp_fp_div_exact;
	_ = blip_mp_fp_div_precision;
	_ = blip_mp_fp_to_decimal;
	_ = blip_mp_fp_to_binary;
	_ = blip_mp_fp_round_to_scale;
	_ = blip_mp_fp_round_to_mp;
	_ = blip_mp_fp_to_string_canonical;
}
