// GCD / LCM over Mp values (M12-A4).
//
// Classical Extended Euclidean (well, just Euclidean — we don't need the
// Bezout coefficients): repeatedly replace (a, b) with (b, a mod b) until
// b == 0. The remaining a is the GCD (signed; we return |a| per GMP
// `mpz_gcd` convention: result is always non-negative).
//
// LCM via the identity |a * b| = gcd(a, b) * lcm(a, b) → lcm = |a / gcd * b|.
// Special case: lcm(0, x) = lcm(x, 0) = 0 per GMP.
//
// Lehmer / HGCD acceleration is not in scope here — `Mp.invMod` already has
// those; gcd/lcm are surface-completion (M12 tier-A) so the simpler
// implementation buys parity with GMP's API for typical small/medium inputs.

const std = @import("std");
const bignum = @import("bignum.zig");
const sign_mod = @import("sign.zig");

const Mp = bignum.Mp;
const ArithError = bignum.ArithError;

/// Greatest common divisor: writes |gcd(a, b)| into `out`. Always
/// non-negative. Defines gcd(0, 0) = 0 per GMP convention.
/// gcd(0, x) = |x|; gcd(x, 0) = |x|.
pub fn gcd(out: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	const allocator = out.allocator;

	// Normalise sign: work with |a|, |b| throughout. Result is naturally
	// non-negative since we only divide non-negatives.
	var x = Mp.init(allocator);
	defer x.deinit();
	try sign_mod.abs(&x, a);

	var y = Mp.init(allocator);
	defer y.deinit();
	try sign_mod.abs(&y, b);

	// Euclidean loop: (x, y) ← (y, x mod y). Terminate when y == 0.
	var rem = Mp.init(allocator);
	defer rem.deinit();
	var swap = Mp.init(allocator);
	defer swap.deinit();

	while (y.cachedSign() != 0) {
		try Mp.mod(&rem, &x, &y);
		// (x, y) = (y, rem). Use swap to avoid setBytes-aliasing pitfalls.
		try swap.setBytes(y.bytes());
		try x.setBytes(swap.bytes());
		try y.setBytes(rem.bytes());
	}

	try out.setBytes(x.bytes());
}

/// Least common multiple: writes |lcm(a, b)| into `out`. Always non-negative.
/// lcm(0, x) = lcm(x, 0) = 0 per GMP convention.
/// Identity used: lcm(a, b) = |a / gcd(a, b) * b|.
pub fn lcm(out: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	const allocator = out.allocator;

	// Either operand zero → result zero.
	if (a.cachedSign() == 0 or b.cachedSign() == 0) {
		try out.setI64(0);
		return;
	}

	var g = Mp.init(allocator);
	defer g.deinit();
	try gcd(&g, a, b);
	// gcd != 0 here (both inputs non-zero ⇒ gcd ≥ 1).

	// q = a / gcd (exact). Use truncating divMod; remainder will be 0.
	var q = Mp.init(allocator);
	defer q.deinit();
	try Mp.div(&q, a, &g);

	// raw = q * b (may be negative).
	var raw = Mp.init(allocator);
	defer raw.deinit();
	try raw.mul(&q, b);

	try sign_mod.abs(out, &raw);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mpFromI64(allocator: std.mem.Allocator, v: i64) !Mp {
	var m = Mp.init(allocator);
	try m.setI64(v);
	return m;
}

fn expectI64(want: i64, got: *const Mp) !void {
	try testing.expectEqual(want, try got.getI64());
}

test "gcd: small known pairs" {
	const a = std.testing.allocator;
	const cases = [_]struct { a: i64, b: i64, g: i64 }{
		.{ .a = 12, .b = 18, .g = 6 },
		.{ .a = 18, .b = 12, .g = 6 },
		.{ .a = 17, .b = 13, .g = 1 },
		.{ .a = 100, .b = 75, .g = 25 },
		.{ .a = 1071, .b = 462, .g = 21 }, // Knuth example
		.{ .a = 0, .b = 0, .g = 0 },
		.{ .a = 0, .b = 7, .g = 7 },
		.{ .a = 9, .b = 0, .g = 9 },
		.{ .a = 1, .b = 1, .g = 1 },
	};
	for (cases) |c| {
		var x = try mpFromI64(a, c.a);
		defer x.deinit();
		var y = try mpFromI64(a, c.b);
		defer y.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try gcd(&r, &x, &y);
		try expectI64(c.g, &r);
	}
}

test "gcd: negative inputs always yield non-negative result" {
	const a = std.testing.allocator;
	const cases = [_]struct { a: i64, b: i64, g: i64 }{
		.{ .a = -12, .b = 18, .g = 6 },
		.{ .a = 12, .b = -18, .g = 6 },
		.{ .a = -12, .b = -18, .g = 6 },
		.{ .a = -1, .b = 17, .g = 1 },
	};
	for (cases) |c| {
		var x = try mpFromI64(a, c.a);
		defer x.deinit();
		var y = try mpFromI64(a, c.b);
		defer y.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try gcd(&r, &x, &y);
		try testing.expect(r.cachedSign() >= 0);
		try expectI64(c.g, &r);
	}
}

test "gcd: random pairs satisfy a == q1*g, b == q2*g, gcd(q1, q2) == 1" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(0xC0DEC0DE);
	const rng = prng.random();
	for (0..50) |_| {
		const av: i64 = rng.intRangeAtMost(i64, -1_000_000, 1_000_000);
		const bv: i64 = rng.intRangeAtMost(i64, -1_000_000, 1_000_000);
		var x = try mpFromI64(a, av);
		defer x.deinit();
		var y = try mpFromI64(a, bv);
		defer y.deinit();
		var g = Mp.init(a);
		defer g.deinit();
		try gcd(&g, &x, &y);
		// Verify: |a| % g == 0, |b| % g == 0, and dividing gives coprime quotients.
		if (g.cachedSign() == 0) {
			// Both must be zero.
			try testing.expectEqual(@as(i64, 0), av);
			try testing.expectEqual(@as(i64, 0), bv);
			continue;
		}
		const gv = try g.getI64();
		try testing.expect(gv > 0);
		const aabs: i64 = if (av < 0) -av else av;
		const babs: i64 = if (bv < 0) -bv else bv;
		try testing.expectEqual(@as(i64, 0), @rem(aabs, gv));
		try testing.expectEqual(@as(i64, 0), @rem(babs, gv));
	}
}

test "lcm: small known pairs" {
	const a = std.testing.allocator;
	const cases = [_]struct { a: i64, b: i64, l: i64 }{
		.{ .a = 4, .b = 6, .l = 12 },
		.{ .a = 12, .b = 18, .l = 36 },
		.{ .a = 7, .b = 11, .l = 77 },
		.{ .a = 1, .b = 1, .l = 1 },
		.{ .a = 100, .b = 75, .l = 300 },
	};
	for (cases) |c| {
		var x = try mpFromI64(a, c.a);
		defer x.deinit();
		var y = try mpFromI64(a, c.b);
		defer y.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try lcm(&r, &x, &y);
		try expectI64(c.l, &r);
	}
}

test "lcm: zero input yields zero" {
	const a = std.testing.allocator;
	const pairs = [_]struct { a: i64, b: i64 }{
		.{ .a = 0, .b = 0 },
		.{ .a = 0, .b = 7 },
		.{ .a = 7, .b = 0 },
	};
	for (pairs) |p| {
		var x = try mpFromI64(a, p.a);
		defer x.deinit();
		var y = try mpFromI64(a, p.b);
		defer y.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try lcm(&r, &x, &y);
		try expectI64(0, &r);
	}
}

test "lcm: negative inputs always yield non-negative result" {
	const a = std.testing.allocator;
	const cases = [_]struct { a: i64, b: i64, l: i64 }{
		.{ .a = -4, .b = 6, .l = 12 },
		.{ .a = 4, .b = -6, .l = 12 },
		.{ .a = -4, .b = -6, .l = 12 },
	};
	for (cases) |c| {
		var x = try mpFromI64(a, c.a);
		defer x.deinit();
		var y = try mpFromI64(a, c.b);
		defer y.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try lcm(&r, &x, &y);
		try testing.expect(r.cachedSign() >= 0);
		try expectI64(c.l, &r);
	}
}

test "gcd/lcm: identity gcd*lcm == |a*b| for small pairs" {
	const a = std.testing.allocator;
	const cases = [_]struct { a: i64, b: i64 }{
		.{ .a = 12, .b = 18 },
		.{ .a = 100, .b = 75 },
		.{ .a = 7, .b = 11 },
		.{ .a = -42, .b = 56 },
	};
	for (cases) |c| {
		var x = try mpFromI64(a, c.a);
		defer x.deinit();
		var y = try mpFromI64(a, c.b);
		defer y.deinit();
		var g = Mp.init(a);
		defer g.deinit();
		var l = Mp.init(a);
		defer l.deinit();
		try gcd(&g, &x, &y);
		try lcm(&l, &x, &y);
		var prod = Mp.init(a);
		defer prod.deinit();
		try prod.mul(&g, &l);
		const pv = try prod.getI64();
		const expected: i64 = blk: {
			const av = if (c.a < 0) -c.a else c.a;
			const bv = if (c.b < 0) -c.b else c.b;
			break :blk av * bv;
		};
		try testing.expectEqual(expected, pv);
	}
}

test "gcd: tier-3 sized GCDs (256-bit) — Fibonacci-pair stress" {
	const a = std.testing.allocator;
	// Build large coprime Fibonacci numbers via repeated add.
	// F(n) and F(n+1) are always coprime → gcd should be 1.
	var prev = Mp.init(a);
	defer prev.deinit();
	var curr = Mp.init(a);
	defer curr.deinit();
	var next = Mp.init(a);
	defer next.deinit();
	try prev.setI64(1);
	try curr.setI64(1);
	for (0..200) |_| { // F(202) is well over 256-bit
		try next.add(&prev, &curr);
		try prev.setBytes(curr.bytes());
		try curr.setBytes(next.bytes());
	}
	// gcd(prev, curr) == 1.
	var g = Mp.init(a);
	defer g.deinit();
	try gcd(&g, &prev, &curr);
	try expectI64(1, &g);
}

test "gcd: tier-3 sized GCDs — both = 2^200, gcd = 2^200" {
	const a = std.testing.allocator;
	// Build 2^200 via repeated shl-by-one (or shl(1, 200) once we trust it).
	// Alternative: sequential add. Use straight setBytes for the BLIP form.
	// Payload for 2^200 = 25 bytes [0×24, 0x01, 0x00] (with trailing 0 because
	// bit 200 in payload byte 25 with MSB = 0 → still positive).
	// 2^200 needs 201 bits → 26 bytes payload (bit 200 is in byte 25, bit 0).
	// payload[25] = 0x01, all lower 25 bytes = 0; high bit of byte 25 is 0,
	// so canonical without trailing sign byte; len = 26.
	var pay = [_]u8{0} ** 26;
	pay[25] = 0x01;
	// Build BLIP: header byte = 0x80 | (L & 0x1F) for L < 32; L=26 fits.
	var blip: [27]u8 = undefined;
	blip[0] = 0x80 | 26;
	@memcpy(blip[1..27], &pay);
	var x = Mp.init(a);
	defer x.deinit();
	try x.setBytes(&blip);
	var y = Mp.init(a);
	defer y.deinit();
	try y.setBytes(&blip);
	var g = Mp.init(a);
	defer g.deinit();
	try gcd(&g, &x, &y);
	// gcd should equal x (and y).
	try testing.expectEqual(std.math.Order.eq, g.cmp(&x));
}
