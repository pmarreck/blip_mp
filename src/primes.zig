// Probabilistic primality testing (M13-B1).
//
// Miller-Rabin primality test with deterministic small-prime trial division
// as a fast composite filter. Uses existing Mp.powm for the modular
// exponentiation step. Caller controls witness count (more witnesses ↦
// stronger probabilistic guarantee — error bound (1/4)^witnesses).
//
// References: Crandall & Pomerance, "Prime Numbers" §3.5;
//             Knuth TAOCP vol 2 §4.5.4.

const std = @import("std");
const bignum = @import("bignum.zig");
const bitwise = @import("bitwise.zig");

const Mp = bignum.Mp;
const ArithError = bignum.ArithError;

/// First 54 primes (all primes < 256). Used for trial division to quickly
/// reject most composites before invoking Miller-Rabin. The list cap of 256
/// is convenient because each entry fits in a u8.
const SMALL_PRIMES: [54]u16 = .{
	2, 3, 5, 7, 11, 13, 17, 19, 23, 29,
	31, 37, 41, 43, 47, 53, 59, 61, 67, 71,
	73, 79, 83, 89, 97, 101, 103, 107, 109, 113,
	127, 131, 137, 139, 149, 151, 157, 163, 167, 173,
	179, 181, 191, 193, 197, 199, 211, 223, 227, 229,
	233, 239, 241, 251,
};

/// Convert an Mp to its low u64 magnitude (used to test small-n cases by
/// value comparison). Returns the actual u64 magnitude when the value fits;
/// for larger values returns u64.max as a sentinel meaning "too big".
fn fitU64Mag(self: *const Mp) u64 {
	if (self.cached_sign == 0) return 0;
	const pay = self.payload();
	// Compute byte length of magnitude.
	if (self.cached_sign > 0) {
		var byte_len = pay.len;
		while (byte_len > 0 and pay[byte_len - 1] == 0) byte_len -= 1;
		if (byte_len > 8) return std.math.maxInt(u64);
		var v: u64 = 0;
		var i: usize = byte_len;
		while (i > 0) {
			i -= 1;
			v = (v << 8) | pay[i];
		}
		return v;
	}
	// Negatives: not used by the prime test (they're rejected upfront), but
	// be safe — return maxInt.
	return std.math.maxInt(u64);
}

/// Test whether `self` (positive Mp) is exactly equal to the small u64 value `v`.
fn eqU64(self: *const Mp, v: u64) bool {
	const m = fitU64Mag(self);
	if (m == std.math.maxInt(u64)) return false;
	return m == v;
}

/// Compute `self mod p` where p is a small u32, returning u32 directly.
/// Walks payload bytes high-to-low; quasi-Horner (acc * 256 + byte) mod p.
/// Caller's responsibility: `self` must be non-negative.
fn modSmall(self: *const Mp, p: u32) u32 {
	if (self.cached_sign == 0) return 0;
	const pay = self.payload();
	// Find magnitude byte length (positives may have a 0x00 sign-extension byte).
	var mag_len = pay.len;
	while (mag_len > 0 and pay[mag_len - 1] == 0) mag_len -= 1;
	if (mag_len == 0) return 0;
	var acc: u64 = 0;
	var i: usize = mag_len;
	while (i > 0) {
		i -= 1;
		acc = ((acc << 8) | @as(u64, pay[i])) % @as(u64, p);
	}
	return @intCast(acc);
}

/// Miller-Rabin probable-prime test for positive odd `n`.
/// Decomposes n - 1 = 2^s * d (d odd), then tests `witnesses` random bases
/// a in [2, n-2]. Returns false at the first witness; true if all pass.
/// Pre: n >= 3, n odd. Caller must ensure these.
fn millerRabin(n: *const Mp, allocator: std.mem.Allocator, rng: std.Random, witnesses: u32) !bool {
	// n_minus_1 = n - 1
	var n_minus_1 = Mp.init(allocator);
	defer n_minus_1.deinit();
	var one = Mp.init(allocator);
	defer one.deinit();
	try one.setI64(1);
	try n_minus_1.sub(n, &one);

	// d = n_minus_1 with trailing factors of 2 stripped; s counts how many.
	var d = Mp.init(allocator);
	defer d.deinit();
	try d.setBytes(n_minus_1.bytes());
	var s: usize = 0;
	while (true) {
		const pay = d.payload();
		if (pay.len == 0 or (pay[0] & 1) == 1) break;
		try bitwise.shr(&d, &d, 1);
		s += 1;
	}

	// n_minus_2 = n - 2 (used to bound random witness range).
	var n_minus_2 = Mp.init(allocator);
	defer n_minus_2.deinit();
	var two = Mp.init(allocator);
	defer two.deinit();
	try two.setI64(2);
	try n_minus_2.sub(n, &two);

	const n_bits = n.bitLen();

	var w: u32 = 0;
	while (w < witnesses) : (w += 1) {
		// Pick random a in [2, n-2]. We sample bits up to n_bits then reject
		// values < 2 or > n-2. For typical primes n >> 4, rejection is rare.
		var a = Mp.init(allocator);
		defer a.deinit();
		try randomBelow(&a, &n_minus_2, rng);
		// shift to [2, n-2]: a = (random in [0, n-3]) + 2
		try a.add(&a, &two);

		// x = a^d mod n
		var x = Mp.init(allocator);
		defer x.deinit();
		try x.powm(&a, &d, n);

		// If x == 1 or x == n-1, possibly prime — go to next witness.
		if (eqU64(&x, 1) or x.cmp(&n_minus_1) == .eq) continue;

		// Square s-1 times; if any becomes n-1, possibly prime.
		var found_nm1 = false;
		var i: usize = 0;
		while (i + 1 < s) : (i += 1) {
			try x.mul(&x, &x);
			try Mp.mod(&x, &x, n);
			if (x.cmp(&n_minus_1) == .eq) {
				found_nm1 = true;
				break;
			}
			if (eqU64(&x, 1)) {
				// Found a non-trivial sqrt of 1 → n is composite.
				return false;
			}
		}
		if (!found_nm1) return false;
		_ = n_bits;
	}
	return true;
}

/// Sample a uniform random non-negative Mp in [0, upper). `upper` must be > 0.
/// Implementation: sample bits up to bitLen(upper), reject samples >= upper.
fn randomBelow(out: *Mp, upper: *const Mp, rng: std.Random) !void {
	const allocator = out.allocator;
	const ubits = upper.bitLen();
	if (ubits == 0) {
		// upper == 0 → can't sample; degenerate. Set to 0.
		try out.setI64(0);
		return;
	}
	const byte_len = (ubits + 7) / 8;
	const buf = try allocator.alloc(u8, byte_len + 1);
	defer allocator.free(buf);
	while (true) {
		rng.bytes(buf[0..byte_len]);
		// Mask the top byte to keep us within bitLen bits.
		const top_extra: u3 = @intCast((byte_len * 8 - ubits) & 7);
		buf[byte_len - 1] &= (@as(u8, 0xFF) >> top_extra);
		// Append a 0x00 sign-extension byte if needed.
		var pay_len = byte_len;
		if (byte_len > 0 and (buf[byte_len - 1] & 0x80) != 0) {
			buf[byte_len] = 0;
			pay_len = byte_len + 1;
		}
		try setMpFromCanonicalLEPayload(out, buf[0..pay_len]);
		// Reject if out >= upper.
		if (out.cmp(upper) == .lt) return;
	}
}

/// Helper: install a canonical LE payload (already 2's-complement form) as a
/// positive Mp value. Mirrors roots.zig's helper to keep modules independent.
fn setMpFromCanonicalLEPayload(out: *Mp, pay: []const u8) ArithError!void {
	if (pay.len == 0) {
		var buf = [_]u8{0x00};
		try out.setBytes(buf[0..1]);
		return;
	}
	// Trim trailing 0x00 sign-extension bytes (canonicalise) but keep the
	// last 0x00 if needed to disambiguate sign.
	var n = pay.len;
	while (n > 1) {
		if (pay[n - 1] == 0 and (pay[n - 2] & 0x80) == 0) {
			n -= 1;
			continue;
		}
		break;
	}
	if (n == 1 and pay[0] < 0x80) {
		var buf = [_]u8{pay[0]};
		try out.setBytes(buf[0..1]);
		return;
	}
	if (n == 1 and pay[0] == 0) {
		var buf = [_]u8{0x00};
		try out.setBytes(buf[0..1]);
		return;
	}
	const tier3 = @import("tier3.zig");
	var hdr_buf: [10]u8 = undefined;
	const hdr_len = tier3.writeHeader(&hdr_buf, n) catch return error.OutOfMemory;
	const need = hdr_len + n;
	const scratch = out.allocator.alloc(u8, need) catch return error.OutOfMemory;
	defer out.allocator.free(scratch);
	@memcpy(scratch[0..hdr_len], hdr_buf[0..hdr_len]);
	@memcpy(scratch[hdr_len..], pay[0..n]);
	try out.setBytes(scratch);
}

/// Probabilistic primality test. Returns:
///   - false if `self` is provably composite
///   - true if `self` passes `witnesses` rounds of Miller-Rabin (probably prime)
/// For `witnesses` rounds, the error probability is ≤ (1/4)^witnesses.
/// Negatives, 0, and 1 return false (none are prime).
pub fn isProbablyPrime(
	self: *const Mp,
	allocator: std.mem.Allocator,
	rng: std.Random,
	witnesses: u32,
) !bool {
	if (self.cached_sign <= 0) return false;
	// Small case via fitU64Mag.
	const v = fitU64Mag(self);
	if (v != std.math.maxInt(u64)) {
		// 0 / 1 / negatives handled above; check small-n directly.
		if (v < 2) return false;
		if (v == 2) return true;
		if ((v & 1) == 0) return false;
		// Look up in SMALL_PRIMES: linear scan — only up to 251.
		if (v <= 251) {
			for (SMALL_PRIMES) |p| {
				if (@as(u64, p) == v) return true;
				if (@as(u64, p) > v) return false;
			}
			return false;
		}
		// Fall through to trial division + Miller-Rabin for larger u64s.
	}

	// Trial-divide by SMALL_PRIMES first (fast composite rejection).
	for (SMALL_PRIMES) |p| {
		const r = modSmall(self, @as(u32, p));
		if (r == 0) {
			// self is divisible by p. If self == p, it's prime; else composite.
			if (v != std.math.maxInt(u64) and v == @as(u64, p)) return true;
			return false;
		}
	}

	// Miller-Rabin proper.
	const w = if (witnesses == 0) 1 else witnesses;
	return millerRabin(self, allocator, rng, w);
}

/// Find the smallest prime > n. Uses isProbablyPrime with a moderate
/// witness count. For n < 2 returns 2.
pub fn nextPrime(out: *Mp, n: *const Mp, allocator: std.mem.Allocator, rng: std.Random) !void {
	// Handle small / negative cases: nextPrime(<2) == 2.
	if (n.cached_sign <= 0) {
		try out.setI64(2);
		return;
	}
	const v_in = fitU64Mag(n);
	if (v_in != std.math.maxInt(u64) and v_in < 2) {
		try out.setI64(2);
		return;
	}

	// Start from n + 1; bump to next odd; then step by 2.
	var cand = Mp.init(allocator);
	defer cand.deinit();
	var one = Mp.init(allocator);
	defer one.deinit();
	try one.setI64(1);
	try cand.add(n, &one);
	// If cand is even, bump by 1 (to make odd).  Also handle the special
	// case of cand == 2 (which is prime).
	const cand_v = fitU64Mag(&cand);
	if (cand_v == 2) {
		try out.setI64(2);
		return;
	}
	const cand_pay = cand.payload();
	if (cand_pay.len > 0 and (cand_pay[0] & 1) == 0) {
		try cand.add(&cand, &one);
	}

	var two = Mp.init(allocator);
	defer two.deinit();
	try two.setI64(2);

	// Loop until prime. Use 20 witnesses (error ≤ 4^-20 ≈ 9e-13).
	const w: u32 = 20;
	while (true) {
		const ok = try isProbablyPrime(&cand, allocator, rng, w);
		if (ok) {
			try out.setBytes(cand.bytes());
			return;
		}
		try cand.add(&cand, &two);
	}
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn deterministicRng() std.Random {
	const seed: u64 = 0xC0FFEE_C0DE_1234;
	const S = struct {
		var prng: std.Random.DefaultPrng = undefined;
	};
	S.prng = std.Random.DefaultPrng.init(seed);
	return S.prng.random();
}

test "isProbablyPrime: known small primes" {
	const a = std.testing.allocator;
	const primes = [_]i64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 97, 8191, 524287, 2147483647 };
	const rng = deterministicRng();
	for (primes) |p| {
		var m = try Mp.fromI64(a, p);
		defer m.deinit();
		const ok = try isProbablyPrime(&m, a, rng, 10);
		if (!ok) {
			std.debug.print("FAIL: claimed {d} composite\n", .{p});
		}
		try testing.expect(ok);
	}
}

test "isProbablyPrime: known small composites" {
	const a = std.testing.allocator;
	const composites = [_]i64{ 0, 1, 4, 6, 8, 9, 10, 12, 14, 15, 21, 25, 27, 33, 35, 49, 51, 91, 121, 169 };
	const rng = deterministicRng();
	for (composites) |c| {
		var m = try Mp.fromI64(a, c);
		defer m.deinit();
		const ok = try isProbablyPrime(&m, a, rng, 10);
		if (ok) {
			std.debug.print("FAIL: claimed {d} prime\n", .{c});
		}
		try testing.expect(!ok);
	}
}

test "isProbablyPrime: Carmichael numbers (Miller-Rabin must catch as composite)" {
	const a = std.testing.allocator;
	const carmichaels = [_]i64{ 561, 1729, 2465, 6601, 10585 };
	const rng = deterministicRng();
	for (carmichaels) |c| {
		var m = try Mp.fromI64(a, c);
		defer m.deinit();
		const ok = try isProbablyPrime(&m, a, rng, 10);
		if (ok) std.debug.print("FAIL: Carmichael {d} claimed prime\n", .{c});
		try testing.expect(!ok);
	}
}

test "isProbablyPrime: negatives are not prime" {
	const a = std.testing.allocator;
	const rng = deterministicRng();
	const negs = [_]i64{ -1, -2, -3, -7, -11, -10000 };
	for (negs) |v| {
		var m = try Mp.fromI64(a, v);
		defer m.deinit();
		try testing.expect(!try isProbablyPrime(&m, a, rng, 5));
	}
}

test "nextPrime: small cases" {
	const a = std.testing.allocator;
	const rng = deterministicRng();
	const cases = [_]struct { n: i64, want: i64 }{
		.{ .n = -5, .want = 2 },
		.{ .n = 0, .want = 2 },
		.{ .n = 1, .want = 2 },
		.{ .n = 2, .want = 3 },
		.{ .n = 3, .want = 5 },
		.{ .n = 5, .want = 7 },
		.{ .n = 7, .want = 11 },
		.{ .n = 13, .want = 17 },
		.{ .n = 100, .want = 101 },
		.{ .n = 7919, .want = 7927 },
	};
	for (cases) |c| {
		var n = try Mp.fromI64(a, c.n);
		defer n.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try nextPrime(&r, &n, a, rng);
		const got = try r.getI64();
		if (got != c.want) {
			std.debug.print("nextPrime({d}): want {d} got {d}\n", .{ c.n, c.want, got });
		}
		try testing.expectEqual(c.want, got);
	}
}
