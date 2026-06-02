// Combinatorial Mp helpers (M13-B4): factorial, binomial, fibonacci.
//
// Pure-Zig, builds on existing Mp.mul/add/sub. Iterative loops where the
// algorithm is straightforward; fast-doubling recurrence for fibonacci.

const std = @import("std");
const bignum = @import("bignum.zig");

const Mp = bignum.Mp;
const ArithError = bignum.ArithError;

/// out = n!  (0! = 1).
/// Iterative product. Caller's `out` is reused as accumulator (zero alloc
/// per multiply once it grows past INLINE_CAP).
pub fn factorial(out: *Mp, n: u32) ArithError!void {
	try out.setI64(1);
	if (n < 2) return;
	var k: u32 = 2;
	var multiplier = Mp.init(out.allocator);
	defer multiplier.deinit();
	while (k <= n) : (k += 1) {
		try multiplier.setI64(@intCast(k));
		try out.mul(out, &multiplier);
	}
}

/// out = C(n, k) = n! / (k! * (n-k)!).
/// Returns 0 when k > n. Uses the multiplicative identity:
///   C(n, k) = C(n, k-1) * (n - k + 1) / k
/// Each step's division is exact, so we can use truncating divMod with
/// remainder discarded.
/// Symmetry: C(n, k) == C(n, n-k); we pick the smaller k to minimise work.
pub fn binomial(out: *Mp, n: u32, k_in: u32) ArithError!void {
	if (k_in > n) {
		try out.setI64(0);
		return;
	}
	// Symmetry: choose the smaller k.
	var k: u32 = k_in;
	if (k > n - k) k = n - k;
	if (k == 0) {
		try out.setI64(1);
		return;
	}
	try out.setI64(1);
	var multiplier = Mp.init(out.allocator);
	defer multiplier.deinit();
	var divisor = Mp.init(out.allocator);
	defer divisor.deinit();
	var remainder = Mp.init(out.allocator);
	defer remainder.deinit();
	var i: u32 = 1;
	while (i <= k) : (i += 1) {
		// out *= (n - i + 1)
		try multiplier.setI64(@intCast(n - i + 1));
		try out.mul(out, &multiplier);
		// out /= i  (exact)
		try divisor.setI64(@intCast(i));
		try Mp.divMod(out, &remainder, out, &divisor);
	}
}

/// out = F(n) where F(0)=0, F(1)=1, F(n)=F(n-1)+F(n-2).
/// Fast-doubling recursion (iterative top-down using the bit pattern of n):
///   F(2k)   = F(k) * (2*F(k+1) - F(k))
///   F(2k+1) = F(k)^2 + F(k+1)^2
/// O(log n) Mp multiplications instead of O(n) additions.
pub fn fibonacci(out: *Mp, n: u32) ArithError!void {
	if (n == 0) {
		try out.setI64(0);
		return;
	}
	const allocator = out.allocator;
	// We carry (a, b) = (F(m), F(m+1)) and grow m by either doubling or
	// doubling-plus-one according to the bits of n from MSB to LSB.
	var a = Mp.init(allocator);
	defer a.deinit();
	var b = Mp.init(allocator);
	defer b.deinit();
	try a.setI64(0); // F(0)
	try b.setI64(1); // F(1)

	// Scratch values.
	var t1 = Mp.init(allocator);
	defer t1.deinit();
	var t2 = Mp.init(allocator);
	defer t2.deinit();
	var c = Mp.init(allocator);
	defer c.deinit();
	var d = Mp.init(allocator);
	defer d.deinit();
	var two = Mp.init(allocator);
	defer two.deinit();
	try two.setI64(2);

	// Highest set bit position of n.
	const nbits: u5 = @intCast(31 - @clz(n));
	var bit_index: i32 = nbits;
	while (bit_index >= 0) : (bit_index -= 1) {
		const bi: u5 = @intCast(bit_index);
		// c = a * (2*b - a)  → F(2m)
		try t1.mul(&b, &two);          // 2b
		try t1.sub(&t1, &a);           // 2b - a
		try c.mul(&a, &t1);            // a * (2b - a) = F(2m)
		// d = a*a + b*b      → F(2m+1)
		try t1.mul(&a, &a);            // a^2
		try t2.mul(&b, &b);            // b^2
		try d.add(&t1, &t2);           // F(2m+1)

		const bit: u32 = (n >> bi) & 1;
		if (bit == 1) {
			// (a, b) = (d, c+d)   — m becomes 2m+1
			try t1.add(&c, &d);
			try a.setBytes(d.bytes());
			try b.setBytes(t1.bytes());
		} else {
			// (a, b) = (c, d)     — m becomes 2m
			try a.setBytes(c.bytes());
			try b.setBytes(d.bytes());
		}
	}
	try out.setBytes(a.bytes());
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectI64(want: i64, got: *const Mp) !void {
	try testing.expectEqual(want, try got.getI64());
}

fn expectU64(want: u64, got: *const Mp) !void {
	try testing.expectEqual(want, try got.getU64());
}

test "factorial: small known values" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	try factorial(&r, 0);
	try expectI64(1, &r);
	try factorial(&r, 1);
	try expectI64(1, &r);
	try factorial(&r, 5);
	try expectI64(120, &r);
	try factorial(&r, 10);
	try expectI64(3628800, &r);
	try factorial(&r, 20);
	try expectU64(2432902008176640000, &r);
}

test "factorial: 25! exceeds u64; check via decimal residues" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	try factorial(&r, 25);
	// 25! = 15511210043330985984000000  (26 digits)
	// Verify by repeated div by 10^6 and check residues:
	//   floor / 10^0  → 25! → mod 10^6 = 0
	//   floor / 10^6  → 15511210043330985984 → mod 10^6 = 985984
	//   floor / 10^12 → 15511210043330 → mod 10^6 = 43330
	//   floor / 10^18 → 15511210 → mod 10^6 = 511210
	//   floor / 10^24 → 15 → mod 10^6 = 15
	var divisor = Mp.init(a);
	defer divisor.deinit();
	try divisor.setI64(1000000);
	var rem = Mp.init(a);
	defer rem.deinit();
	try Mp.divMod(&r, &rem, &r, &divisor);
	try expectI64(0, &rem);
	try Mp.divMod(&r, &rem, &r, &divisor);
	try expectI64(985984, &rem);
	try Mp.divMod(&r, &rem, &r, &divisor);
	try expectI64(43330, &rem);
	try Mp.divMod(&r, &rem, &r, &divisor);
	try expectI64(511210, &rem);
	try Mp.divMod(&r, &rem, &r, &divisor);
	try expectI64(15, &rem);
}

test "binomial: edge cases" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	// k > n → 0
	try binomial(&r, 5, 6);
	try expectI64(0, &r);
	// k == 0 → 1
	try binomial(&r, 100, 0);
	try expectI64(1, &r);
	// k == n → 1
	try binomial(&r, 100, 100);
	try expectI64(1, &r);
	// n == 0 → 1 only when k == 0
	try binomial(&r, 0, 0);
	try expectI64(1, &r);
}

test "binomial: small known values" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	try binomial(&r, 5, 2);
	try expectI64(10, &r);
	try binomial(&r, 6, 3);
	try expectI64(20, &r);
	try binomial(&r, 10, 4);
	try expectI64(210, &r);
	try binomial(&r, 20, 10);
	try expectI64(184756, &r);
	try binomial(&r, 50, 25);
	try expectI64(126410606437752, &r);
}

test "binomial: symmetry C(n, k) == C(n, n-k)" {
	const a = std.testing.allocator;
	var r1 = Mp.init(a);
	defer r1.deinit();
	var r2 = Mp.init(a);
	defer r2.deinit();
	const cases = [_]struct { n: u32, k: u32 }{
		.{ .n = 10, .k = 3 }, .{ .n = 17, .k = 5 }, .{ .n = 50, .k = 7 }, .{ .n = 100, .k = 33 },
	};
	for (cases) |c| {
		try binomial(&r1, c.n, c.k);
		try binomial(&r2, c.n, c.n - c.k);
		try testing.expectEqual(std.math.Order.eq, r1.cmp(&r2));
	}
}

test "fibonacci: small known values" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	const expect = [_]i64{ 0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610 };
	for (expect, 0..) |want, i| {
		try fibonacci(&r, @intCast(i));
		try expectI64(want, &r);
	}
}

test "fibonacci: F(50) and F(80)" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	try fibonacci(&r, 50);
	try expectU64(12586269025, &r);
	try fibonacci(&r, 80);
	try expectU64(23416728348467685, &r);
}

test "fibonacci: F(100) (35-digit number — check via decimal residues)" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	try fibonacci(&r, 100);
	// F(100) = 354224848179261915075  (21 digits)
	// Verify by repeated mod by 10^10:
	//   354224848179261915075 mod 10^10 == 9261915075
	//   /10^10 = 35422484817 → mod 10^10 == 5422484817
	//   /10^10 = 3 → mod 10^10 == 3
	var divisor = Mp.init(a);
	defer divisor.deinit();
	try divisor.setI64(10_000_000_000);
	var rem = Mp.init(a);
	defer rem.deinit();
	try Mp.divMod(&r, &rem, &r, &divisor);
	try expectI64(9261915075, &rem);
	try Mp.divMod(&r, &rem, &r, &divisor);
	try expectI64(5422484817, &rem);
	try Mp.divMod(&r, &rem, &r, &divisor);
	try expectI64(3, &rem);
}

test "fibonacci: identity F(n+1) = F(n) + F(n-1) over a sweep" {
	const a = std.testing.allocator;
	var fn_ = Mp.init(a);
	defer fn_.deinit();
	var fnm1 = Mp.init(a);
	defer fnm1.deinit();
	var fnp1 = Mp.init(a);
	defer fnp1.deinit();
	var sum = Mp.init(a);
	defer sum.deinit();
	var i: u32 = 1;
	while (i < 200) : (i += 1) {
		try fibonacci(&fn_, i);
		try fibonacci(&fnm1, i - 1);
		try fibonacci(&fnp1, i + 1);
		try sum.add(&fn_, &fnm1);
		try testing.expectEqual(std.math.Order.eq, sum.cmp(&fnp1));
	}
}
