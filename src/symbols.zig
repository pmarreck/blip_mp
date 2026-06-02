// Jacobi / Legendre / Kronecker symbols (M13-B3).
//
// These are number-theoretic functions over integers that take values
// in {-1, 0, +1}. The Jacobi symbol generalises the Legendre symbol from
// odd primes to any odd positive modulus; Kronecker further extends to
// arbitrary integers. Standard quadratic-reciprocity recursion is used.
//
// References: Crandall & Pomerance, "Prime Numbers" §2.3.5;
//             Cohen, "A Course in Computational Algebraic Number Theory" §1.4.

const std = @import("std");
const bignum = @import("bignum.zig");
const bitwise = @import("bitwise.zig");

const Mp = bignum.Mp;
const ArithError = bignum.ArithError;

pub const SymbolError = ArithError || error{
	ModulusMustBeOddPositive, // jacobi/legendre received n that's even or non-positive
};

/// Returns the low byte of the magnitude of `m`. For tier 0/1 with
/// canonical encoding, this is the low payload byte. We need parity
/// (low bit) and (m mod 8) (low 3 bits) for the Jacobi reciprocity rules.
fn lowByteMag(m: *const Mp) u8 {
	const pay = m.payload();
	if (pay.len == 0) return 0;
	if (m.cached_sign > 0) return pay[0];
	// Negative: magnitude byte 0 is (~payload[0] + 1) trunc — but we only
	// need the low bits which always satisfy (mag low byte) == (-payload low byte).
	// For our use we compute magnitude of |m| via subtraction up the call
	// chain; this helper is only invoked on positive magnitudes.
	return pay[0];
}

/// Compare *magnitudes* (absolute values) of two non-negative Mps for
/// equality with the constant 1. Used by the symbol algorithms which
/// reduce until one operand becomes 1.
fn isOneMag(m: *const Mp) bool {
	if (m.cached_sign != 1) return false;
	const pay = m.payload();
	if (pay.len < 1) return false;
	if (pay[0] != 1) return false;
	// All other bytes must be 0 (sign-extension only).
	var i: usize = 1;
	while (i < pay.len) : (i += 1) if (pay[i] != 0) return false;
	return true;
}

/// Reduce `a` to a non-negative value strictly less than `n`.
/// Both `a` and `n` are passed by value; the result lands in `out`.
/// `n` must be positive.
fn reduceMod(out: *Mp, a: *const Mp, n: *const Mp) ArithError!void {
	try out.mod(a, n);
	if (out.cached_sign < 0) try out.add(out, n);
}

/// Jacobi symbol (a / n) for n > 0, n odd.
/// Returns -1, 0, or +1.
/// Algorithm: standard quadratic-reciprocity recursion with bit-tricks for
/// the (2/n) case ((-1)^((n^2-1)/8)) and the reciprocity sign flip
/// ((-1)^((a-1)(n-1)/4)).
pub fn jacobi(a: *const Mp, n: *const Mp, allocator: std.mem.Allocator) SymbolError!i2 {
	if (n.cached_sign != 1) return error.ModulusMustBeOddPositive;
	const n_low = lowByteMag(n);
	if ((n_low & 1) == 0) return error.ModulusMustBeOddPositive;

	// Working copies that we mutate.
	var aa = Mp.init(allocator);
	defer aa.deinit();
	var nn = Mp.init(allocator);
	defer nn.deinit();
	try nn.setBytes(n.bytes());
	try reduceMod(&aa, a, &nn);

	var result: i2 = 1;

	while (true) {
		if (aa.cached_sign == 0) {
			// (0/n): 1 iff n == 1, else 0.
			if (isOneMag(&nn)) return result;
			return 0;
		}
		// Strip factors of 2.
		while (true) {
			const a_low = lowByteMag(&aa);
			if ((a_low & 1) == 1) break;
			// aa /= 2
			try bitwise.shr(&aa, &aa, 1);
			// (2/n) = +1 if n ≡ ±1 (mod 8); -1 if n ≡ ±3 (mod 8).
			const n_mod8: u8 = lowByteMag(&nn) & 7;
			if (n_mod8 == 3 or n_mod8 == 5) result = -result;
		}
		// Now aa is odd. If aa == 1, the recursion bottoms out.
		if (isOneMag(&aa)) return result;
		// Reciprocity: swap (aa, nn). Sign flip: (-1)^((aa-1)(nn-1)/4)
		// equivalently: flip sign if both aa ≡ 3 (mod 4) and nn ≡ 3 (mod 4).
		const a_mod4 = lowByteMag(&aa) & 3;
		const n_mod4 = lowByteMag(&nn) & 3;
		if (a_mod4 == 3 and n_mod4 == 3) result = -result;
		// swap (aa, nn) — temp via setBytes
		var tmp = Mp.init(allocator);
		defer tmp.deinit();
		try tmp.setBytes(aa.bytes());
		try aa.setBytes(nn.bytes());
		try nn.setBytes(tmp.bytes());
		// reduce: aa = aa mod nn
		try reduceMod(&aa, &aa, &nn);
	}
}

/// Legendre symbol (a / p) for p odd prime.
/// Aliased to jacobi (mathematically equivalent when p is prime;
/// caller's responsibility to ensure p is prime — caller may use
/// `primes.isProbablyPrime` to verify).
pub fn legendre(a: *const Mp, p: *const Mp, allocator: std.mem.Allocator) SymbolError!i2 {
	return jacobi(a, p, allocator);
}

/// Kronecker symbol (a / n), the full extension of Jacobi to arbitrary integer n.
/// Definitions used:
///   (a / 0) = 1 if a == ±1, else 0
///   (a / -1) = 1 if a >= 0, -1 if a < 0
///   (a / 2) = 0 if a is even
///            +1 if a ≡ ±1 (mod 8)
///            -1 if a ≡ ±3 (mod 8)
///   For odd positive n, (a/n) == jacobi(a, n).
///   Multiplicativity in the lower argument is preserved.
pub fn kronecker(a: *const Mp, n: *const Mp, allocator: std.mem.Allocator) SymbolError!i2 {
	// Special cases for n.
	if (n.cached_sign == 0) {
		// (a / 0) = 1 iff a == ±1.
		const a_pay = a.payload();
		if (a_pay.len == 1 and a_pay[0] == 1) return 1; // a == 1
		// a == -1 → canonical encoding: single payload byte 0xFF.
		if (a_pay.len == 1 and a_pay[0] == 0xFF) return 1;
		return 0;
	}

	// Sign flip: (a / -n) = (a / -1) * (a / n_abs)
	// (a / -1) = 1 if a >= 0, else -1.
	var sign_factor: i2 = 1;
	var n_abs = Mp.init(allocator);
	defer n_abs.deinit();
	if (n.cached_sign < 0) {
		var zero = Mp.init(allocator);
		defer zero.deinit();
		try zero.setI64(0);
		try n_abs.sub(&zero, n);
		if (a.cached_sign < 0) sign_factor = -sign_factor;
	} else {
		try n_abs.setBytes(n.bytes());
	}

	// Strip powers of 2 from n_abs and apply (a/2) factor each time.
	while (true) {
		const n_low = lowByteMag(&n_abs);
		if ((n_low & 1) == 1) break; // n_abs is odd → done
		// (a / 2) factor
		const a_low = lowByteMag(a);
		if ((a_low & 1) == 0) return 0;
		const a_mod8 = a_low & 7;
		if (a_mod8 == 3 or a_mod8 == 5) sign_factor = -sign_factor;
		try bitwise.shr(&n_abs, &n_abs, 1);
	}

	// n_abs is now odd and positive.
	if (isOneMag(&n_abs)) return sign_factor;
	// Pass to jacobi.
	const j = try jacobi(a, &n_abs, allocator);
	const product: i2 = @intCast(@as(i32, sign_factor) * @as(i32, j));
	return product;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "jacobi: known small values" {
	const a = std.testing.allocator;
	// Reference: standard table values.
	const cases = [_]struct { ai: i64, n: i64, want: i2 }{
		.{ .ai = 0, .n = 1, .want = 1 },
		.{ .ai = 0, .n = 3, .want = 0 },
		.{ .ai = 1, .n = 3, .want = 1 },
		.{ .ai = 2, .n = 3, .want = -1 },
		.{ .ai = 1, .n = 15, .want = 1 },
		.{ .ai = 2, .n = 15, .want = 1 },
		.{ .ai = 3, .n = 15, .want = 0 }, // gcd(3,15) = 3 ≠ 1
		.{ .ai = 4, .n = 15, .want = 1 }, // 4 = 2^2 → (2/15)^2 = 1
		.{ .ai = 5, .n = 21, .want = 1 },
		.{ .ai = 7, .n = 9, .want = 1 },
		// More table entries: (a/p) for odd prime p.
		.{ .ai = 2, .n = 5, .want = -1 },
		.{ .ai = 2, .n = 7, .want = 1 },
		.{ .ai = 2, .n = 11, .want = -1 },
		.{ .ai = 2, .n = 13, .want = -1 },
		.{ .ai = 3, .n = 5, .want = -1 },
		.{ .ai = 3, .n = 7, .want = -1 },
		.{ .ai = 3, .n = 11, .want = 1 },
		.{ .ai = 3, .n = 13, .want = 1 },
	};
	for (cases) |c| {
		var ai = try Mp.fromI64(a, c.ai);
		defer ai.deinit();
		var n = try Mp.fromI64(a, c.n);
		defer n.deinit();
		const got = try jacobi(&ai, &n, a);
		try testing.expectEqual(c.want, got);
	}
}

test "jacobi: rejects even or non-positive n" {
	const a = std.testing.allocator;
	var ai = try Mp.fromI64(a, 5);
	defer ai.deinit();
	var n_even = try Mp.fromI64(a, 6);
	defer n_even.deinit();
	try testing.expectError(error.ModulusMustBeOddPositive, jacobi(&ai, &n_even, a));
	var n_zero = try Mp.fromI64(a, 0);
	defer n_zero.deinit();
	try testing.expectError(error.ModulusMustBeOddPositive, jacobi(&ai, &n_zero, a));
	var n_neg = try Mp.fromI64(a, -3);
	defer n_neg.deinit();
	try testing.expectError(error.ModulusMustBeOddPositive, jacobi(&ai, &n_neg, a));
}

test "jacobi: multiplicativity J(ab/n) == J(a/n) * J(b/n)" {
	const a = std.testing.allocator;
	const ns = [_]i64{ 3, 5, 7, 9, 15, 21, 25, 35, 45, 99 };
	const xs = [_]i64{ 1, 2, 3, 5, 7, 11, 13 };
	const ys = [_]i64{ 2, 4, 5, 7, 11, 13, 17 };
	for (ns) |nv| {
		var n = try Mp.fromI64(a, nv);
		defer n.deinit();
		for (xs) |xv| {
			var x = try Mp.fromI64(a, xv);
			defer x.deinit();
			for (ys) |yv| {
				var y = try Mp.fromI64(a, yv);
				defer y.deinit();
				var prod = try Mp.fromI64(a, xv * yv);
				defer prod.deinit();
				const j_x = try jacobi(&x, &n, a);
				const j_y = try jacobi(&y, &n, a);
				const j_prod = try jacobi(&prod, &n, a);
				const expected: i2 = @intCast(@as(i32, j_x) * @as(i32, j_y));
				try testing.expectEqual(expected, j_prod);
			}
		}
	}
}

test "jacobi: J(0, n) == 0 for n > 1; J(0, 1) == 1" {
	const a = std.testing.allocator;
	var zero = try Mp.fromI64(a, 0);
	defer zero.deinit();
	var one = try Mp.fromI64(a, 1);
	defer one.deinit();
	try testing.expectEqual(@as(i2, 1), try jacobi(&zero, &one, a));
	const n_vals = [_]i64{ 3, 5, 7, 9, 15, 27, 99 };
	for (n_vals) |nv| {
		var n = try Mp.fromI64(a, nv);
		defer n.deinit();
		try testing.expectEqual(@as(i2, 0), try jacobi(&zero, &n, a));
	}
}

test "legendre: alias to jacobi for prime moduli" {
	const a = std.testing.allocator;
	const cases = [_]struct { ai: i64, p: i64 }{
		.{ .ai = 1, .p = 7 },
		.{ .ai = 2, .p = 7 },
		.{ .ai = 3, .p = 11 },
		.{ .ai = 4, .p = 13 },
		.{ .ai = 7, .p = 19 },
	};
	for (cases) |c| {
		var ai = try Mp.fromI64(a, c.ai);
		defer ai.deinit();
		var p = try Mp.fromI64(a, c.p);
		defer p.deinit();
		try testing.expectEqual(try jacobi(&ai, &p, a), try legendre(&ai, &p, a));
	}
}

test "kronecker: Kr(a/2)" {
	const a = std.testing.allocator;
	var two = try Mp.fromI64(a, 2);
	defer two.deinit();
	const cases = [_]struct { v: i64, want: i2 }{
		.{ .v = 0, .want = 0 },
		.{ .v = 1, .want = 1 }, // 1 mod 8 = 1
		.{ .v = 3, .want = -1 }, // 3 mod 8 = 3
		.{ .v = 5, .want = -1 }, // 5 mod 8 = 5
		.{ .v = 7, .want = 1 }, // 7 mod 8 = 7
		.{ .v = 9, .want = 1 }, // 9 mod 8 = 1
		.{ .v = 11, .want = -1 },
		.{ .v = 13, .want = -1 },
		.{ .v = 15, .want = 1 },
		.{ .v = 2, .want = 0 }, // even
		.{ .v = 4, .want = 0 },
	};
	for (cases) |c| {
		var ai = try Mp.fromI64(a, c.v);
		defer ai.deinit();
		try testing.expectEqual(c.want, try kronecker(&ai, &two, a));
	}
}

test "kronecker: extends jacobi for odd positive n" {
	const a = std.testing.allocator;
	const ns = [_]i64{ 3, 5, 7, 9, 15, 21, 27, 35, 99 };
	const as_v = [_]i64{ 0, 1, 2, 3, 5, 7, 11, 13, 17 };
	for (ns) |nv| {
		var n = try Mp.fromI64(a, nv);
		defer n.deinit();
		for (as_v) |av| {
			var ai = try Mp.fromI64(a, av);
			defer ai.deinit();
			const k = try kronecker(&ai, &n, a);
			const j = try jacobi(&ai, &n, a);
			try testing.expectEqual(j, k);
		}
	}
}

test "kronecker: handles n == 0" {
	const a = std.testing.allocator;
	var zero = try Mp.fromI64(a, 0);
	defer zero.deinit();
	var one = try Mp.fromI64(a, 1);
	defer one.deinit();
	var minus_one = try Mp.fromI64(a, -1);
	defer minus_one.deinit();
	var seven = try Mp.fromI64(a, 7);
	defer seven.deinit();
	try testing.expectEqual(@as(i2, 1), try kronecker(&one, &zero, a));
	try testing.expectEqual(@as(i2, 1), try kronecker(&minus_one, &zero, a));
	try testing.expectEqual(@as(i2, 0), try kronecker(&seven, &zero, a));
	try testing.expectEqual(@as(i2, 0), try kronecker(&zero, &zero, a));
}

test "kronecker: handles negative n" {
	const a = std.testing.allocator;
	// (a / -1) = 1 if a >= 0, -1 if a < 0
	var neg_one = try Mp.fromI64(a, -1);
	defer neg_one.deinit();
	var pos = try Mp.fromI64(a, 5);
	defer pos.deinit();
	var neg = try Mp.fromI64(a, -5);
	defer neg.deinit();
	try testing.expectEqual(@as(i2, 1), try kronecker(&pos, &neg_one, a));
	try testing.expectEqual(@as(i2, -1), try kronecker(&neg, &neg_one, a));
	// (3 / -7) = (3 / -1) * (3 / 7) = 1 * (-1) = -1
	var three = try Mp.fromI64(a, 3);
	defer three.deinit();
	var minus_seven = try Mp.fromI64(a, -7);
	defer minus_seven.deinit();
	try testing.expectEqual(@as(i2, -1), try kronecker(&three, &minus_seven, a));
}
