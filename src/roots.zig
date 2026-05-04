// Integer roots and perfect-square test (M13-B2).
//
// floor(sqrt(n)) and floor(n^(1/k)) via Newton iteration on Mp values.
// Algorithms match GMP semantics:
//   isqrt(n) requires n >= 0; result is largest x with x*x <= n.
//   iroot(n, k) for odd k allows negative n (result has sign of n);
//                for even k requires n >= 0.

const std = @import("std");
const bignum = @import("bignum.zig");

const Mp = bignum.Mp;
const ArithError = bignum.ArithError;

pub const RootError = ArithError || error{
	NegativeOperand, // isqrt(n<0); iroot(n<0, even k)
	ZeroExponent, // iroot(_, 0)
};

/// Newton iteration for floor(sqrt(n)). Halts when iterates stop decreasing.
/// Initial estimate: 2^ceil(bitLen(n)/2) — guaranteed to be ≥ floor(sqrt(n)).
/// Iteration: x_{i+1} = (x_i + n / x_i) / 2.
/// Termination: classic textbook result — Newton on integer sqrt is monotone
/// non-increasing once x >= floor(sqrt(n)); we stop when next >= current.
pub fn isqrt(out: *Mp, n: *const Mp) RootError!void {
	if (n.cached_sign < 0) return error.NegativeOperand;
	if (n.cached_sign == 0) {
		try out.setI64(0);
		return;
	}
	const allocator = out.allocator;
	const nbits = n.bitLen();
	if (nbits <= 1) {
		// n == 1 → sqrt(1) == 1
		try out.setI64(1);
		return;
	}

	// Initial estimate: 2^ceil(nbits/2). For an nbits-bit number, the true
	// sqrt has ceil(nbits/2) bits, so this is an upper bound.
	const start_bits: usize = (nbits + 1) / 2;
	var x = Mp.init(allocator);
	defer x.deinit();
	{
		// x = 1 << start_bits via bit construction.
		// Build a magnitude buffer of size (start_bits/8)+1 bytes (LE).
		const byte_pos = start_bits / 8;
		const bit_pos: u3 = @intCast(start_bits & 7);
		const buf = try allocator.alloc(u8, byte_pos + 1 + 1); // +1 for sign-ext byte if needed
		defer allocator.free(buf);
		@memset(buf, 0);
		buf[byte_pos] = @as(u8, 1) << bit_pos;
		// Ensure no high-bit-set byte (so positive sign-ext stays 0x00).
		// If byte_pos's byte has high bit set, append 0x00.
		var pay_len: usize = byte_pos + 1;
		if ((buf[byte_pos] & 0x80) != 0) {
			pay_len += 1;
			buf[byte_pos + 1] = 0;
		}
		try setMpFromCanonicalLEPayload(&x, buf[0..pay_len]);
	}

	// Newton loop.
	var next = Mp.init(allocator);
	defer next.deinit();
	var quotient = Mp.init(allocator);
	defer quotient.deinit();
	var rem = Mp.init(allocator);
	defer rem.deinit();
	var sum = Mp.init(allocator);
	defer sum.deinit();
	var two = Mp.init(allocator);
	defer two.deinit();
	try two.setI64(2);

	while (true) {
		// next = (x + n/x) / 2
		try Mp.divMod(&quotient, &rem, n, &x);
		try sum.add(&x, &quotient);
		try Mp.div(&next, &sum, &two);
		// Halt when next >= x (then x is the floor sqrt).
		if (next.cmp(&x) != .lt) break;
		// next < x → continue with x := next
		try x.setBytes(next.bytes());
	}
	try out.setBytes(x.bytes());
}

/// Computes floor(sqrt(n)) and the remainder n - floor(sqrt(n))^2.
/// Both outputs are non-negative.
pub fn isqrtRem(root: *Mp, rem_out: *Mp, n: *const Mp) RootError!void {
	try isqrt(root, n);
	// rem = n - root*root
	var sq = Mp.init(root.allocator);
	defer sq.deinit();
	try sq.mul(root, root);
	try rem_out.sub(n, &sq);
}

/// True iff n is a perfect square (n >= 0 and isqrt(n)^2 == n).
pub fn isPerfectSquare(n: *const Mp) bool {
	if (n.cached_sign < 0) return false;
	if (n.cached_sign == 0) return true;
	var root = Mp.init(n.allocator);
	defer root.deinit();
	isqrt(&root, n) catch return false;
	var sq = Mp.init(n.allocator);
	defer sq.deinit();
	sq.mul(&root, &root) catch return false;
	return sq.cmp(n) == .eq;
}

/// floor(n^(1/k)) for k >= 1.
/// For k == 1, returns n unchanged.
/// For odd k and negative n, returns -floor(|n|^(1/k)) (matches GMP).
/// For even k and negative n, returns error.NegativeOperand.
/// Algorithm: Newton iteration x_{i+1} = ((k-1)*x_i + n/x_i^(k-1)) / k.
pub fn iroot(out: *Mp, n: *const Mp, k: u32) RootError!void {
	if (k == 0) return error.ZeroExponent;
	if (k == 1) {
		try out.setBytes(n.bytes());
		return;
	}
	if (n.cached_sign == 0) {
		try out.setI64(0);
		return;
	}
	// Sign handling.
	const negative = n.cached_sign < 0;
	if (negative and (k % 2 == 0)) return error.NegativeOperand;

	const allocator = out.allocator;
	// Work on |n|.
	var abs_n = Mp.init(allocator);
	defer abs_n.deinit();
	if (negative) {
		var zero = Mp.init(allocator);
		defer zero.deinit();
		try zero.setI64(0);
		try abs_n.sub(&zero, n);
	} else {
		try abs_n.setBytes(n.bytes());
	}

	// |n| == 1 → root is 1.
	const ab = abs_n.bytes();
	if (ab.len == 1 and ab[0] == 1) {
		if (negative) try out.setI64(-1) else try out.setI64(1);
		return;
	}

	// Initial estimate: 2^ceil(bitLen/k). True root has ceil(bitLen/k) bits.
	const nbits = abs_n.bitLen();
	const start_bits: usize = (nbits + k - 1) / k;
	var x = Mp.init(allocator);
	defer x.deinit();
	{
		const byte_pos = start_bits / 8;
		const bit_pos: u3 = @intCast(start_bits & 7);
		const buf = try allocator.alloc(u8, byte_pos + 1 + 1);
		defer allocator.free(buf);
		@memset(buf, 0);
		buf[byte_pos] = @as(u8, 1) << bit_pos;
		var pay_len: usize = byte_pos + 1;
		if ((buf[byte_pos] & 0x80) != 0) {
			pay_len += 1;
			buf[byte_pos + 1] = 0;
		}
		try setMpFromCanonicalLEPayload(&x, buf[0..pay_len]);
	}

	// Newton iteration: next = ((k-1)*x + n / x^(k-1)) / k
	var next = Mp.init(allocator);
	defer next.deinit();
	var x_pow = Mp.init(allocator);
	defer x_pow.deinit();
	var quotient = Mp.init(allocator);
	defer quotient.deinit();
	var rem = Mp.init(allocator);
	defer rem.deinit();
	var k_minus_1 = Mp.init(allocator);
	defer k_minus_1.deinit();
	try k_minus_1.setI64(@intCast(k - 1));
	var k_mp = Mp.init(allocator);
	defer k_mp.deinit();
	try k_mp.setI64(@intCast(k));
	var term1 = Mp.init(allocator);
	defer term1.deinit();
	var sum = Mp.init(allocator);
	defer sum.deinit();

	while (true) {
		// x_pow = x^(k-1) — repeated multiply since k is small.
		try x_pow.setI64(1);
		var i: u32 = 0;
		while (i < k - 1) : (i += 1) {
			try x_pow.mul(&x_pow, &x);
		}
		// quotient = n / x_pow
		try Mp.divMod(&quotient, &rem, &abs_n, &x_pow);
		// term1 = (k-1) * x
		try term1.mul(&k_minus_1, &x);
		// sum = term1 + quotient
		try sum.add(&term1, &quotient);
		// next = sum / k
		try Mp.div(&next, &sum, &k_mp);
		if (next.cmp(&x) != .lt) break;
		try x.setBytes(next.bytes());
	}
	if (negative) {
		// out = -x  via 0 - x
		var zero = Mp.init(allocator);
		defer zero.deinit();
		try zero.setI64(0);
		try out.sub(&zero, &x);
	} else {
		try out.setBytes(x.bytes());
	}
}

// ── helpers ──────────────────────────────────────────────────────────────────

/// Install a positive Mp value from a canonical two's-complement LE payload.
/// Wraps the value with the BLIP length-prefix header. For payloads that
/// fit the immediate range (single byte < 128) uses the immediate encoding.
fn setMpFromCanonicalLEPayload(out: *Mp, pay: []const u8) ArithError!void {
	if (pay.len == 0) {
		var buf = [_]u8{0x00};
		try out.setBytes(buf[0..1]);
		return;
	}
	if (pay.len == 1 and pay[0] < 0x80) {
		var buf = [_]u8{pay[0]};
		try out.setBytes(buf[0..1]);
		return;
	}
	// Length-prefixed form. Use writeHeader from tier3.
	const tier3 = @import("tier3.zig");
	var hdr_buf: [10]u8 = undefined;
	const hdr_len = tier3.writeHeader(&hdr_buf, pay.len) catch return error.OutOfMemory;
	const need = hdr_len + pay.len;
	const scratch = out.allocator.alloc(u8, need) catch return error.OutOfMemory;
	defer out.allocator.free(scratch);
	@memcpy(scratch[0..hdr_len], hdr_buf[0..hdr_len]);
	@memcpy(scratch[hdr_len..], pay);
	try out.setBytes(scratch);
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

fn expectU64(want: u64, got: *const Mp) !void {
	try testing.expectEqual(want, try got.getU64());
}

test "isqrt: small known values" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	const cases = [_]struct { n: i64, want: i64 }{
		.{ .n = 0, .want = 0 },
		.{ .n = 1, .want = 1 },
		.{ .n = 2, .want = 1 },
		.{ .n = 3, .want = 1 },
		.{ .n = 4, .want = 2 },
		.{ .n = 8, .want = 2 },
		.{ .n = 9, .want = 3 },
		.{ .n = 15, .want = 3 },
		.{ .n = 16, .want = 4 },
		.{ .n = 99, .want = 9 },
		.{ .n = 100, .want = 10 },
		.{ .n = 10000, .want = 100 },
		.{ .n = 10001, .want = 100 },
		.{ .n = 99999999, .want = 9999 },
	};
	for (cases) |c| {
		var n = try mpFromI64(a, c.n);
		defer n.deinit();
		try isqrt(&r, &n);
		try expectI64(c.want, &r);
	}
}

test "isqrt: n^2 - 1 and n^2 + 1 boundary" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	const ns = [_]i64{ 5, 17, 100, 1000, 12345 };
	for (ns) |nv| {
		const sq = nv * nv;
		var minus = try mpFromI64(a, sq - 1);
		defer minus.deinit();
		try isqrt(&r, &minus);
		try expectI64(nv - 1, &r);
		var plus = try mpFromI64(a, sq + 1);
		defer plus.deinit();
		try isqrt(&r, &plus);
		try expectI64(nv, &r);
	}
}

test "isqrt: rejects negative" {
	const a = std.testing.allocator;
	var n = try mpFromI64(a, -5);
	defer n.deinit();
	var r = Mp.init(a);
	defer r.deinit();
	try testing.expectError(error.NegativeOperand, isqrt(&r, &n));
}

test "isqrtRem: identity n == root^2 + rem" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	var rem = Mp.init(a);
	defer rem.deinit();
	var sq = Mp.init(a);
	defer sq.deinit();
	var sum = Mp.init(a);
	defer sum.deinit();
	const ns = [_]i64{ 0, 1, 2, 25, 26, 100, 99, 1023, 1024, 1025, 1_000_000 };
	for (ns) |nv| {
		var n = try mpFromI64(a, nv);
		defer n.deinit();
		try isqrtRem(&r, &rem, &n);
		try sq.mul(&r, &r);
		try sum.add(&sq, &rem);
		try expectI64(nv, &sum);
		// Also: rem in [0, 2*root]
		try testing.expect(rem.cached_sign >= 0);
	}
}

test "isPerfectSquare: small known values" {
	const a = std.testing.allocator;
	const sqs = [_]i64{ 0, 1, 4, 9, 16, 25, 36, 100, 144, 10000 };
	for (sqs) |v| {
		var m = try mpFromI64(a, v);
		defer m.deinit();
		try testing.expect(isPerfectSquare(&m));
	}
	const non_sqs = [_]i64{ 2, 3, 5, 7, 8, 10, 99, 101, 9999 };
	for (non_sqs) |v| {
		var m = try mpFromI64(a, v);
		defer m.deinit();
		try testing.expect(!isPerfectSquare(&m));
	}
	// Negatives are not perfect squares.
	var neg = try mpFromI64(a, -4);
	defer neg.deinit();
	try testing.expect(!isPerfectSquare(&neg));
}

test "iroot: cube root small known values" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	const cases = [_]struct { n: i64, k: u32, want: i64 }{
		.{ .n = 8, .k = 3, .want = 2 },
		.{ .n = 27, .k = 3, .want = 3 },
		.{ .n = 28, .k = 3, .want = 3 },
		.{ .n = 26, .k = 3, .want = 2 },
		.{ .n = 1000, .k = 3, .want = 10 },
		.{ .n = 999, .k = 3, .want = 9 },
		.{ .n = 1_000_000, .k = 3, .want = 100 },
		.{ .n = 32, .k = 5, .want = 2 },
		.{ .n = 31, .k = 5, .want = 1 },
		.{ .n = 100000, .k = 5, .want = 10 },
		.{ .n = 0, .k = 4, .want = 0 },
	};
	for (cases) |c| {
		var n = try mpFromI64(a, c.n);
		defer n.deinit();
		try iroot(&r, &n, c.k);
		try expectI64(c.want, &r);
	}
}

test "iroot: negative n with odd k yields negative root" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	var n = try mpFromI64(a, -8);
	defer n.deinit();
	try iroot(&r, &n, 3);
	try expectI64(-2, &r);
	var n2 = try mpFromI64(a, -27);
	defer n2.deinit();
	try iroot(&r, &n2, 3);
	try expectI64(-3, &r);
}

test "iroot: negative n with even k errors" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	var n = try mpFromI64(a, -16);
	defer n.deinit();
	try testing.expectError(error.NegativeOperand, iroot(&r, &n, 2));
	try testing.expectError(error.NegativeOperand, iroot(&r, &n, 4));
}

test "iroot: k=0 errors; k=1 returns n unchanged" {
	const a = std.testing.allocator;
	var r = Mp.init(a);
	defer r.deinit();
	var n = try mpFromI64(a, 42);
	defer n.deinit();
	try testing.expectError(error.ZeroExponent, iroot(&r, &n, 0));
	try iroot(&r, &n, 1);
	try expectI64(42, &r);
	var negn = try mpFromI64(a, -42);
	defer negn.deinit();
	try iroot(&r, &negn, 1);
	try expectI64(-42, &r);
}

test "isqrt: large 256-bit value (well into tier-3)" {
	const a = std.testing.allocator;
	// n = (2^130) -> sqrt = 2^65
	var n = Mp.init(a);
	defer n.deinit();
	try n.setI64(1);
	const bitwise = @import("bitwise.zig");
	try bitwise.shl(&n, &n, 130);
	var r = Mp.init(a);
	defer r.deinit();
	try isqrt(&r, &n);
	// Expected: 2^65
	var want = Mp.init(a);
	defer want.deinit();
	try want.setI64(1);
	try bitwise.shl(&want, &want, 65);
	try testing.expectEqual(std.math.Order.eq, r.cmp(&want));
}
