// Sign / abs / fits predicates over Mp values (M12-A2).
//
// Mirrors GMP semantics for `mpz_neg`, `mpz_abs`, `mpz_fits_slong_p`,
// `mpz_fits_ulong_p`, `mpz_fits_sint_p`, `mpz_fits_uint_p` (with the i32/i64
// vs C-int distinction made explicit by the function names — caller picks
// the integer width they care about, no platform-dependence).

const std = @import("std");
const bignum = @import("bignum.zig");

const Mp = bignum.Mp;
const ArithError = bignum.ArithError;

/// Negation: writes -a into `out`. Implemented as `out = 0 - a` so all the
/// canonicalisation, alloc-reuse and tier-3 promotion logic in Mp.sub is
/// reused (including the i64.minInt → tier-3 promotion edge case).
pub fn neg(out: *Mp, a: *const Mp) ArithError!void {
	var zero = Mp.init(out.allocator);
	defer zero.deinit();
	try zero.setI64(0);
	try out.sub(&zero, a);
}

/// Absolute value: writes |a| into `out`. Branches on cachedSign — copying
/// the bytes for non-negative inputs and routing through `neg` for negatives.
pub fn abs(out: *Mp, a: *const Mp) ArithError!void {
	if (a.cachedSign() >= 0) {
		// Copy via setBytes — handles aliasing (out == a) by reading bytes()
		// before any internal state changes.
		try out.setBytes(a.bytes());
		return;
	}
	try neg(out, a);
}

/// True iff the value fits in an `i64`. Canonical BLIP payload of length ≤ 8
/// IS exactly the two's-complement i64 range — by construction.
pub fn fitsI64(self: *const Mp) bool {
	if (self.cachedSign() == 0) return true;
	return self.cached_pay_len <= 8;
}

/// True iff the value is non-negative and fits in a `u64` (i.e. magnitude
/// bit-length ≤ 64).
pub fn fitsU64(self: *const Mp) bool {
	if (self.cachedSign() < 0) return false;
	if (self.cachedSign() == 0) return true;
	return self.bitLen() <= 64;
}

/// True iff the value fits in an `i32`. Canonical BLIP payload of length ≤ 4
/// IS exactly the two's-complement i32 range.
pub fn fitsI32(self: *const Mp) bool {
	if (self.cachedSign() == 0) return true;
	return self.cached_pay_len <= 4;
}

/// True iff the value is non-negative and fits in a `u32`.
pub fn fitsU32(self: *const Mp) bool {
	if (self.cachedSign() < 0) return false;
	if (self.cachedSign() == 0) return true;
	return self.bitLen() <= 32;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectI64(want: i64, got: *const Mp) !void {
	try testing.expectEqual(want, try got.getI64());
}

test "sign: neg small positives, negatives, zero" {
	const a = std.testing.allocator;
	const cases = [_]i64{ 0, 1, -1, 7, -7, 0x12345678, -0x12345678, std.math.maxInt(i32), std.math.minInt(i32) };
	for (cases) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try neg(&r, &x);
		try expectI64(-v, &r);
	}
}

test "sign: neg of i64 minInt promotes to tier-3 (since -minInt overflows i64)" {
	const a = std.testing.allocator;
	var x = try Mp.fromI64(a, std.math.minInt(i64));
	defer x.deinit();
	var r = Mp.init(a);
	defer r.deinit();
	try neg(&r, &x);
	// Result is 2^63 — positive, doesn't fit in i64 but fits in u64.
	try testing.expect(!fitsI64(&r));
	try testing.expect(fitsU64(&r));
	try testing.expectEqual(@as(usize, 64), r.bitLen());
	try testing.expectEqual(@as(i8, 1), r.cachedSign());
	try testing.expectEqual(@as(u1, 1), r.bitAt(63));
	try testing.expectEqual(@as(u1, 0), r.bitAt(62));
	try testing.expectEqual(@as(u1, 0), r.bitAt(0));
}

test "sign: neg of neg = identity" {
	const a = std.testing.allocator;
	const cases = [_]i64{ 1, -1, 0xDEAD, -0xDEAD, std.math.maxInt(i32) };
	for (cases) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		var r1 = Mp.init(a);
		defer r1.deinit();
		var r2 = Mp.init(a);
		defer r2.deinit();
		try neg(&r1, &x);
		try neg(&r2, &r1);
		try expectI64(v, &r2);
	}
}

test "sign: abs positives unchanged, negatives flipped, zero == zero" {
	const a = std.testing.allocator;
	const cases = [_]i64{ 0, 1, -1, 0x1234, -0x1234, std.math.maxInt(i32), std.math.minInt(i32) };
	for (cases) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try abs(&r, &x);
		const want: i64 = if (v < 0) -v else v;
		try expectI64(want, &r);
	}
}

test "sign: abs of i64 minInt → 2^63 (tier-3)" {
	const a = std.testing.allocator;
	var x = try Mp.fromI64(a, std.math.minInt(i64));
	defer x.deinit();
	var r = Mp.init(a);
	defer r.deinit();
	try abs(&r, &x);
	try testing.expect(!fitsI64(&r));
	try testing.expect(fitsU64(&r));
	try testing.expectEqual(@as(usize, 64), r.bitLen());
	try testing.expectEqual(@as(i8, 1), r.cachedSign());
}

test "sign: abs aliasing — abs(x, x) works" {
	const a = std.testing.allocator;
	var x = try Mp.fromI64(a, -42);
	defer x.deinit();
	try abs(&x, &x);
	try expectI64(42, &x);
}

test "sign: fitsI64 boundary values" {
	const a = std.testing.allocator;
	const fits = [_]i64{ 0, 1, -1, std.math.maxInt(i64), std.math.minInt(i64), std.math.maxInt(i32) };
	for (fits) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		try testing.expect(fitsI64(&x));
	}
	// 2^63 (just past i64.maxInt) does NOT fit i64.
	var big = Mp.init(a);
	defer big.deinit();
	var minInt = try Mp.fromI64(a, std.math.minInt(i64));
	defer minInt.deinit();
	try neg(&big, &minInt); // 2^63
	try testing.expect(!fitsI64(&big));
}

test "sign: fitsU64 boundary values" {
	const a = std.testing.allocator;
	// Positive values that fit u64.
	const fits_pos = [_]i64{ 0, 1, std.math.maxInt(i64) };
	for (fits_pos) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		try testing.expect(fitsU64(&x));
	}
	// Negatives never fit u64.
	const negs = [_]i64{ -1, std.math.minInt(i64) };
	for (negs) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		try testing.expect(!fitsU64(&x));
	}
	// 2^63 fits u64.
	var minInt = try Mp.fromI64(a, std.math.minInt(i64));
	defer minInt.deinit();
	var pow63 = Mp.init(a);
	defer pow63.deinit();
	try neg(&pow63, &minInt);
	try testing.expect(fitsU64(&pow63));
	// 2^64 - 1 fits u64. setU64 rejects values > i64.maxInt; build via setBytes.
	// payload = [0xFF×8, 0x00] (9 bytes; trailing zero so high bit isn't set
	// → reads as positive value with magnitude 2^64-1).
	var max_u64 = Mp.init(a);
	defer max_u64.deinit();
	const blip_max_u64 = [_]u8{ 0x89, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
	try max_u64.setBytes(&blip_max_u64);
	try testing.expect(fitsU64(&max_u64));
	try testing.expectEqual(@as(usize, 64), max_u64.bitLen());
	// 2^64 doesn't fit u64.
	var pow64 = Mp.init(a);
	defer pow64.deinit();
	const blip_pow64 = [_]u8{ 0x89, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
	try pow64.setBytes(&blip_pow64);
	try testing.expect(!fitsU64(&pow64));
}

test "sign: fitsI32 boundary values" {
	const a = std.testing.allocator;
	const fits = [_]i64{ 0, 1, -1, std.math.maxInt(i32), std.math.minInt(i32) };
	for (fits) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		try testing.expect(fitsI32(&x));
	}
	const dont_fit = [_]i64{ std.math.maxInt(i32) + 1, std.math.minInt(i32) - 1, std.math.maxInt(i64) };
	for (dont_fit) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		try testing.expect(!fitsI32(&x));
	}
}

test "sign: fitsU32 boundary values" {
	const a = std.testing.allocator;
	const fits_pos = [_]i64{ 0, 1, std.math.maxInt(u32) };
	for (fits_pos) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		try testing.expect(fitsU32(&x));
	}
	// Negative never fits.
	{
		var x = try Mp.fromI64(a, -1);
		defer x.deinit();
		try testing.expect(!fitsU32(&x));
	}
	// 2^32 doesn't fit u32.
	{
		var x = try Mp.fromI64(a, @as(i64, 1) << 32);
		defer x.deinit();
		try testing.expect(!fitsU32(&x));
	}
}
