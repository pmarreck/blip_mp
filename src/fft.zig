// FFT-based multiplication for very large bignums via Number-Theoretic
// Transform (NTT) over a prime field.
//
// Algorithm (Schönhage-Strassen variant):
//   1. Treat each operand as a sequence of "digits" in base B (here B = 256,
//      i.e., one byte per digit).
//   2. Pad both digit sequences to a power-of-2 length N where
//      N ≥ a_digits + b_digits (so the cyclic convolution equals the
//      acyclic convolution we actually want).
//   3. Forward NTT both digit sequences.
//   4. Pointwise multiply the transformed sequences (mod p).
//   5. Inverse NTT.
//   6. Carry-propagate the resulting digit sequence back to bytes.
//
// Asymptotic O(n log n log log n) — beats Karatsuba's O(n^1.58) and
// Toom-3's O(n^1.46) at large operand sizes.
//
// **Limb-independent BLIP-paradigm note:** the NTT array IS a u64 array
// internally, but it's algorithm-internal scratch (the transformed digit
// values), NOT a parallel storage of the operand. We read bytes from BLIP
// encodings as digits at the entry boundary; we write the carry-propagated
// result back to BLIP bytes at the exit. The bytes remain canonical
// throughout — same paradigm as Karatsuba's u64 chunked reads.
//
// **Single-prime variant:** uses p = 998244353 (= 119·2^23 + 1, a "Fermat-
// friendly" prime supporting transforms up to length 2^23). With byte-
// digits this covers operand sizes up to ~7.5K bytes (60K-bit) before
// risking pointwise-product overflow. Beyond that we'd need a second prime
// + CRT (future work, see M6-3.14).
//
// References:
//   - Cooley & Tukey, "An algorithm for the machine calculation of
//     complex Fourier series" (1965)
//   - Schönhage & Strassen, "Schnelle Multiplikation großer Zahlen" (1971)

const std = @import("std");

// ── Field parameters (single-prime variant) ──────────────────────────────────

/// Prime modulus. 998244353 = 119 * 2^23 + 1. Supports NTT lengths up to 2^23.
pub const P: u64 = 998244353;

/// A primitive root of P (i.e., its order in (Z/pZ)* is p-1).
/// 3 is a primitive root of 998244353.
pub const PRIMITIVE_ROOT: u64 = 3;

/// Largest NTT length our prime can support.
pub const MAX_NTT_LEN: usize = 1 << 23;

// ── Modular arithmetic ──────────────────────────────────────────────────────

/// (a + b) mod P. Both inputs assumed to be in [0, P).
pub inline fn addModP(a: u64, b: u64) u64 {
	const sum = a + b;
	return if (sum >= P) sum - P else sum;
}

/// (a - b) mod P. Both inputs assumed to be in [0, P).
pub inline fn subModP(a: u64, b: u64) u64 {
	return if (a >= b) a - b else a + P - b;
}

/// (a * b) mod P. Inputs in [0, P). Result in [0, P).
/// P fits in 30 bits, so a*b fits in 60 bits — well within u64 — then we
/// reduce by `% P`. The compiler turns this into a UMULH+UMSUB or similar
/// on aarch64 (no asm needed).
pub inline fn mulModP(a: u64, b: u64) u64 {
	return (a * b) % P;
}

/// b^e mod P. Standard square-and-multiply.
pub fn powMod(b: u64, e: u64, m: u64) u64 {
	var base = b % m;
	var exp = e;
	var result: u64 = 1;
	while (exp > 0) {
		if (exp & 1 == 1) result = (result * base) % m;
		base = (base * base) % m;
		exp >>= 1;
	}
	return result;
}

// ── Primitive Nth root of unity ─────────────────────────────────────────────

/// Returns ω such that ω^N ≡ 1 (mod P) and no smaller positive power. N must
/// be a power of 2 dividing (P - 1) = 119 * 2^23. So N ≤ 2^23.
pub fn nthRootOfUnity(N: usize) u64 {
	std.debug.assert(N > 0 and N <= MAX_NTT_LEN);
	std.debug.assert(N & (N - 1) == 0); // power of 2
	// ω = g^((P-1)/N) mod P
	const exponent: u64 = (P - 1) / @as(u64, @intCast(N));
	return powMod(PRIMITIVE_ROOT, exponent, P);
}

/// Modular inverse of x mod P, via Fermat's little theorem: x^(P-2) ≡ x⁻¹.
pub inline fn invModP(x: u64) u64 {
	return powMod(x, P - 2, P);
}

// ── Bit-reversal permutation ────────────────────────────────────────────────

/// In-place bit-reversal permutation. For each index i, swap a[i] with
/// a[bitreverse(i, log2(n))]. Used by iterative Cooley-Tukey NTT to put
/// inputs in the order the radix-2 butterfly expects.
pub fn bitReversePermute(a: []u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0); // power of 2
	var j: usize = 0;
	var i: usize = 1;
	while (i < n) : (i += 1) {
		// Compute next bit-reversed counter j.
		var bit = n >> 1;
		while (j & bit != 0) {
			j ^= bit;
			bit >>= 1;
		}
		j ^= bit;
		if (i < j) std.mem.swap(u64, &a[i], &a[j]);
	}
}

// ── Forward / inverse NTT ───────────────────────────────────────────────────

/// In-place radix-2 Cooley-Tukey Number-Theoretic Transform.
/// `a.len` must be a power of 2 ≤ MAX_NTT_LEN. All elements must be in [0, P).
/// `invert = false` → forward transform with primitive Nth root of unity ω.
/// `invert = true`  → inverse transform with ω⁻¹, then scale by N⁻¹ at end.
pub fn ntt(a: []u64, invert: bool) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(n <= MAX_NTT_LEN);

	bitReversePermute(a);

	// Iterative butterflies, doubling block size each round.
	var len: usize = 2;
	while (len <= n) : (len <<= 1) {
		const w_len = blk: {
			const root = nthRootOfUnity(len);
			break :blk if (invert) invModP(root) else root;
		};
		var i: usize = 0;
		while (i < n) : (i += len) {
			var w: u64 = 1;
			var k: usize = 0;
			const half = len >> 1;
			while (k < half) : (k += 1) {
				const u = a[i + k];
				const t = mulModP(a[i + k + half], w);
				a[i + k] = addModP(u, t);
				a[i + k + half] = subModP(u, t);
				w = mulModP(w, w_len);
			}
		}
	}

	if (invert) {
		const n_inv = invModP(@intCast(n));
		for (a) |*x| x.* = mulModP(x.*, n_inv);
	}
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "addModP / subModP basic" {
	try testing.expectEqual(@as(u64, 5), addModP(2, 3));
	try testing.expectEqual(@as(u64, 0), addModP(P - 1, 1));
	try testing.expectEqual(@as(u64, 1), addModP(P - 1, 2));
	try testing.expectEqual(@as(u64, 1), subModP(3, 2));
	try testing.expectEqual(@as(u64, P - 1), subModP(0, 1));
}

test "mulModP basic" {
	try testing.expectEqual(@as(u64, 6), mulModP(2, 3));
	try testing.expectEqual(@as(u64, 0), mulModP(0, 12345));
	// (P-1) * (P-1) mod P = 1 (since (P-1) ≡ -1, (-1)*(-1) = 1)
	try testing.expectEqual(@as(u64, 1), mulModP(P - 1, P - 1));
}

test "powMod identities" {
	// g^(P-1) ≡ 1 mod P (Fermat's little theorem, since g is a primitive root)
	try testing.expectEqual(@as(u64, 1), powMod(PRIMITIVE_ROOT, P - 1, P));
	// 0^anything (positive) = 0
	try testing.expectEqual(@as(u64, 0), powMod(0, 5, P));
	// anything^0 = 1
	try testing.expectEqual(@as(u64, 1), powMod(12345, 0, P));
}

test "nthRootOfUnity: ω^N = 1 and ω^(N/2) = -1 = P-1" {
	const sizes = [_]usize{ 2, 4, 8, 16, 256, 4096, 8192 };
	for (sizes) |N| {
		const omega = nthRootOfUnity(N);
		try testing.expectEqual(@as(u64, 1), powMod(omega, @intCast(N), P));
		try testing.expectEqual(@as(u64, P - 1), powMod(omega, @intCast(N / 2), P));
	}
}

test "invModP: x * x⁻¹ ≡ 1 (mod P)" {
	const cases = [_]u64{ 2, 3, 7, 12345, 998244352 };
	for (cases) |x| {
		const inv = invModP(x);
		try testing.expectEqual(@as(u64, 1), mulModP(x, inv));
	}
}

test "bitReversePermute: involution (applying twice = identity)" {
	const sizes = [_]usize{ 2, 4, 8, 16, 64, 256 };
	for (sizes) |n| {
		const a = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a);
		for (a, 0..) |*x, i| x.* = @intCast(i * 7 + 3);
		const orig = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(orig);
		@memcpy(orig, a);
		bitReversePermute(a);
		bitReversePermute(a);
		try testing.expectEqualSlices(u64, orig, a);
	}
}

test "bitReversePermute: known small case" {
	// n=8: bit-reverse of {0,1,2,3,4,5,6,7} = {0,4,2,6,1,5,3,7}.
	var a = [_]u64{ 0, 1, 2, 3, 4, 5, 6, 7 };
	bitReversePermute(&a);
	try testing.expectEqualSlices(u64, &.{ 0, 4, 2, 6, 1, 5, 3, 7 }, &a);
}

test "ntt round-trip: invNtt(ntt(a)) == a" {
	const sizes = [_]usize{ 2, 4, 8, 16, 64, 256, 1024 };
	for (sizes) |n| {
		const a = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a);
		const orig = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(orig);
		var prng = std.Random.DefaultPrng.init(0xBADCAB);
		const rand = prng.random();
		for (a) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(orig, a);
		ntt(a, false);
		ntt(a, true);
		try testing.expectEqualSlices(u64, orig, a);
	}
}

test "ntt convolution theorem: invNtt(ntt(a) * ntt(b)) = a ⊛ b (acyclic via zero pad)" {
	// Multiply two small "polynomials" via NTT and compare to schoolbook.
	const a_in = [_]u64{ 3, 1, 4, 1, 5, 9, 2, 6 };
	const b_in = [_]u64{ 2, 7, 1, 8, 2, 8, 1, 8 };
	const M = a_in.len + b_in.len; // 16, already power of 2.

	var a = [_]u64{0} ** M;
	var b = [_]u64{0} ** M;
	for (a_in, 0..) |v, i| a[i] = v;
	for (b_in, 0..) |v, i| b[i] = v;

	ntt(&a, false);
	ntt(&b, false);
	var c: [M]u64 = undefined;
	for (0..M) |i| c[i] = mulModP(a[i], b[i]);
	ntt(&c, true);

	// Schoolbook reference.
	var ref = [_]u64{0} ** M;
	for (a_in, 0..) |av, i| {
		for (b_in, 0..) |bv, j| {
			ref[i + j] += av * bv;
		}
	}
	for (0..M) |i| {
		try testing.expectEqual(ref[i], c[i]);
	}
}
