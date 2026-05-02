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
/// reduce by `% P`. Since P is comptime, the compiler lowers `% P` to a
/// magic-number multiply (Granlund-Möller) on aarch64 — ~5 cycles vs ~10
/// for hardware udiv.
///
/// **Hand-rolled Barrett experiment (2026-05-02):** Tried Barrett with
/// M = floor(2^64 / P) = 18479187002 and a single conditional subtract.
/// Provably correct (passes 100K random tests + 8240 GMP cross-checks),
/// but **measurably SLOWER** than `% P` in the FFT benchmarks: 202386 ns
/// vs 191583 ns at 32K-bit Mp.mul (~5% regression). Asm inspection
/// shows why: the compiler's `% P` lowering produces a 3-instruction
/// inner loop body (`mul, umulh, msub`) with the magic-constant load
/// hoisted out, while Barrett needs `mul, umulh, madd, add, cmp, csel`
/// (6 instructions) for the conditional subtract that the compiler's
/// tighter precision avoids. Conclusion: LLVM's magic-number lowering
/// for a 30-bit comptime divisor is essentially optimal — no Barrett
/// formulation in u64 arithmetic can beat it without losing the
/// correction step. Left here as a documented null-result so future
/// agents don't re-explore the same dead end.
///
/// **Prior bug (2026-05 abandoned attempt):** used M = floor(2^60 / P)
/// with shift k = 60. The Barrett bound `q - q_hat <= 2` requires
/// `k >= bitlen(P) + bitlen(x_max)`, NOT just `k = bitlen(P)`.
/// With k = 60, q_hat can undershoot by ~2^30, leaving r many P's
/// above the modulus.
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

/// Iterative radix-2 Cooley-Tukey NTT using precomputed twiddles.
/// `twiddles[j] = omega_n^j` for j in 0..n/2, where omega_n is the chosen
/// (forward = ω; inverse = ω⁻¹) primitive nth root of unity. Caller is
/// responsible for the inverse-transform 1/N scaling pass; this routine
/// performs only the butterflies.
///
/// At level `len`, butterfly k uses twiddle omega_n^(k * (n/len)) — i.e., we
/// stride into the same precomputed table rather than recomputing per-level.
/// This collapses 1 mulModP per butterfly vs. the naive
/// "running w = w * w_len" form.
pub fn nttWithTwiddles(a: []u64, twiddles: []const u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(twiddles.len >= n / 2);

	bitReversePermute(a);

	var len: usize = 2;
	while (len <= n) : (len <<= 1) {
		const stride = n / len;
		const half = len >> 1;
		var i: usize = 0;
		while (i < n) : (i += len) {
			var k: usize = 0;
			while (k < half) : (k += 1) {
				const w = twiddles[k * stride];
				const u = a[i + k];
				const t = mulModP(a[i + k + half], w);
				a[i + k] = addModP(u, t);
				a[i + k + half] = subModP(u, t);
			}
		}
	}
}

/// Convenience wrapper that builds the twiddle table on the stack and runs
/// `nttWithTwiddles`, then scales by N⁻¹ on inverse. For test/use up to
/// n = 8192 (twiddle table = 32 KB on the stack). Production path
/// (`mulMagnitudes`) computes twiddles once on the heap and shares them
/// across the three NTT calls (forward A, forward B, inverse).
pub fn ntt(a: []u64, invert: bool) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(n <= 8192); // stack twiddles cap

	var tw_buf: [4096]u64 = undefined;
	const tw = tw_buf[0 .. n / 2];
	const omega_n = blk: {
		const root = nthRootOfUnity(n);
		break :blk if (invert) invModP(root) else root;
	};
	tw[0] = 1;
	var j: usize = 1;
	while (j < n / 2) : (j += 1) tw[j] = mulModP(tw[j - 1], omega_n);

	nttWithTwiddles(a, tw);

	if (invert) {
		const n_inv = invModP(@intCast(n));
		for (a) |*x| x.* = mulModP(x.*, n_inv);
	}
}

// ── Byte-magnitude FFT multiplication ───────────────────────────────────────

/// Maximum combined operand length (a.len + b.len) supportable by the
/// single-prime variant. Constraint: at NTT length N (next pow2 ≥ a.len+b.len),
/// each pointwise convolution sum is ≤ N · 255² and must fit in one residue
/// mod P. Worst case: a_len = b_len, max_sum = min(a_len, b_len) · 255² < P.
/// Empirically: at a_len = b_len = 4096, max_sum ≈ 2.66·10⁸ < P ≈ 9.98·10⁸.
/// Add a comfortable margin: cap at a_len + b_len ≤ 14000.
pub const MAX_FFT_COMBINED_LEN: usize = 14000;

/// Multiply two unsigned magnitudes (little-endian byte arrays) via NTT.
/// Returns the byte length of the product (trailing zeros trimmed).
///
/// Preconditions:
///   - a.len + b.len ≤ MAX_FFT_COMBINED_LEN
///   - out.len ≥ a.len + b.len
///
/// Algorithm: zero-pad both operands to power-of-2 length N, forward-NTT,
/// pointwise-multiply mod P, inverse-NTT, then byte-carry-propagate the
/// resulting digit-sum array back to bytes.
pub fn mulMagnitudes(allocator: std.mem.Allocator, a: []const u8, b: []const u8, out: []u8) !usize {
	if (a.len == 0 or b.len == 0) return 0;
	const need_len = a.len + b.len;
	std.debug.assert(out.len >= need_len);
	std.debug.assert(need_len <= MAX_FFT_COMBINED_LEN);

	var N: usize = 1;
	while (N < need_len) N <<= 1;

	const pa = try allocator.alloc(u64, N);
	defer allocator.free(pa);
	const pb = try allocator.alloc(u64, N);
	defer allocator.free(pb);
	const tw_fwd = try allocator.alloc(u64, N / 2);
	defer allocator.free(tw_fwd);
	const tw_inv = try allocator.alloc(u64, N / 2);
	defer allocator.free(tw_inv);

	// Precompute twiddles once, reuse across 3 NTT calls (forward A,
	// forward B, inverse). Cuts per-call mulModP count nearly in half.
	const omega_n = nthRootOfUnity(N);
	const omega_n_inv = invModP(omega_n);
	tw_fwd[0] = 1;
	tw_inv[0] = 1;
	{
		var j: usize = 1;
		while (j < N / 2) : (j += 1) {
			tw_fwd[j] = mulModP(tw_fwd[j - 1], omega_n);
			tw_inv[j] = mulModP(tw_inv[j - 1], omega_n_inv);
		}
	}

	@memset(pa, 0);
	@memset(pb, 0);
	for (a, 0..) |byte, i| pa[i] = byte;
	for (b, 0..) |byte, i| pb[i] = byte;

	nttWithTwiddles(pa, tw_fwd);
	nttWithTwiddles(pb, tw_fwd);
	for (0..N) |i| pa[i] = mulModP(pa[i], pb[i]);
	nttWithTwiddles(pa, tw_inv);
	const n_inv = invModP(@intCast(N));
	for (pa) |*x| x.* = mulModP(x.*, n_inv);

	// Carry propagation through the byte-output buffer.
	var carry: u64 = 0;
	var i: usize = 0;
	while (i < need_len) : (i += 1) {
		const val = pa[i] + carry;
		out[i] = @truncate(val & 0xFF);
		carry = val >> 8;
	}
	std.debug.assert(carry == 0);

	var len = need_len;
	while (len > 0 and out[len - 1] == 0) len -= 1;
	return len;
}

// ── Two-prime CRT NTT (extended-range variant) ──────────────────────────────
//
// The single-prime path above caps min(a,b) * 65025 < P ≈ 9.98e8, i.e. ~7K
// bytes per operand for equal sizes. To extend the range we run the entire
// pointwise convolution under TWO different NTT-friendly primes and combine
// the per-digit residues via the Chinese Remainder Theorem (CRT). Each digit
// is then known exactly modulo p1 * p2 ≈ 2^59, big enough to hold sums up to
// ~32K bytes per operand (max digit sum = 32768 * 65025 ≈ 2.13e9 << 2^59).
//
// Architecture: the NTT primitives are parameterized over a `Field` struct
// (the prime, primitive root, and supported transform length). The original
// single-prime API (`mulMagnitudes`, `mulModP`, `nttWithTwiddles`, etc.)
// stays untouched so all existing tests and callers keep working.

/// Compile-time description of an NTT-friendly prime field.
pub const Field = struct {
	p: u64,
	primitive_root: u64,
	max_ntt_len: usize,

	/// (a + b) mod self.p. Inputs assumed in [0, self.p).
	pub inline fn addMod(comptime self: Field, a: u64, b: u64) u64 {
		const sum = a + b;
		return if (sum >= self.p) sum - self.p else sum;
	}

	/// (a - b) mod self.p. Inputs in [0, self.p).
	pub inline fn subMod(comptime self: Field, a: u64, b: u64) u64 {
		return if (a >= b) a - b else a + self.p - b;
	}

	/// (a * b) mod self.p. Each prime fits in 30 bits so a*b fits in 60 bits;
	/// the Zig compiler lowers `% self.p` to a magic-number multiply (constant
	/// divisor known at comptime).
	pub inline fn mulMod(comptime self: Field, a: u64, b: u64) u64 {
		return (a * b) % self.p;
	}

	/// b^e mod self.p via square-and-multiply.
	pub fn powMod(comptime self: Field, b: u64, e: u64) u64 {
		var base = b % self.p;
		var exp = e;
		var result: u64 = 1;
		while (exp > 0) {
			if (exp & 1 == 1) result = self.mulMod(result, base);
			base = self.mulMod(base, base);
			exp >>= 1;
		}
		return result;
	}

	/// Modular inverse via Fermat's little theorem.
	pub inline fn invMod(comptime self: Field, x: u64) u64 {
		return self.powMod(x, self.p - 2);
	}

	/// Primitive Nth root of unity, N a power of 2 ≤ self.max_ntt_len.
	pub fn nthRootOfUnity(comptime self: Field, N: usize) u64 {
		std.debug.assert(N > 0 and N <= self.max_ntt_len);
		std.debug.assert(N & (N - 1) == 0);
		const exp: u64 = (self.p - 1) / @as(u64, @intCast(N));
		return self.powMod(self.primitive_root, exp);
	}
};

/// Field 1: the same prime used by the single-prime path.
/// 998244353 = 119 * 2^23 + 1, primitive root 3. NTT lengths up to 2^23.
pub const F1: Field = .{ .p = 998244353, .primitive_root = 3, .max_ntt_len = 1 << 23 };

/// Field 2: a second NTT-friendly prime, coprime with F1.
/// 985661441 = 235 * 2^22 + 1, primitive root 3. NTT lengths up to 2^22.
/// Combined modulus p1 * p2 ≈ 9.84 × 10^17 ≈ 2^59.77 — comfortably within
/// u64 and far above any per-digit convolution sum we will generate.
pub const F2: Field = .{ .p = 985661441, .primitive_root = 3, .max_ntt_len = 1 << 22 };

/// Modular inverse of F1.p (mod F2.p), precomputed at comptime for the
/// CRT (Garner) reconstruction. Computing it inside `mulMagnitudesCRT`
/// would needlessly recompute on every call.
pub const F1_INV_MOD_F2: u64 = F2.invMod(F1.p % F2.p);

/// Generic iterative radix-2 Cooley-Tukey NTT. Same algorithm as
/// `nttWithTwiddles` but parameterized by a comptime field.
pub fn nttGeneric(comptime field: Field, a: []u64, twiddles: []const u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(twiddles.len >= n / 2);

	bitReversePermute(a);

	var len: usize = 2;
	while (len <= n) : (len <<= 1) {
		const stride = n / len;
		const half = len >> 1;
		var i: usize = 0;
		while (i < n) : (i += len) {
			var k: usize = 0;
			while (k < half) : (k += 1) {
				const w = twiddles[k * stride];
				const u = a[i + k];
				const t = field.mulMod(a[i + k + half], w);
				a[i + k] = field.addMod(u, t);
				a[i + k + half] = field.subMod(u, t);
			}
		}
	}
}

/// Run the full convolution (forward A, forward B, pointwise mul, inverse,
/// 1/N scale) under one field. Output is the per-digit residue mod field.p.
fn convolveOnce(
	comptime field: Field,
	allocator: std.mem.Allocator,
	a: []const u8,
	b: []const u8,
	N: usize,
	out: []u64,
) !void {
	std.debug.assert(out.len == N);
	std.debug.assert(N <= field.max_ntt_len);

	const pa = try allocator.alloc(u64, N);
	defer allocator.free(pa);
	const pb = try allocator.alloc(u64, N);
	defer allocator.free(pb);
	const tw_fwd = try allocator.alloc(u64, N / 2);
	defer allocator.free(tw_fwd);
	const tw_inv = try allocator.alloc(u64, N / 2);
	defer allocator.free(tw_inv);

	const omega_n = field.nthRootOfUnity(N);
	const omega_n_inv = field.invMod(omega_n);
	tw_fwd[0] = 1;
	tw_inv[0] = 1;
	{
		var j: usize = 1;
		while (j < N / 2) : (j += 1) {
			tw_fwd[j] = field.mulMod(tw_fwd[j - 1], omega_n);
			tw_inv[j] = field.mulMod(tw_inv[j - 1], omega_n_inv);
		}
	}

	@memset(pa, 0);
	@memset(pb, 0);
	for (a, 0..) |byte, i| pa[i] = byte;
	for (b, 0..) |byte, i| pb[i] = byte;

	nttGeneric(field, pa, tw_fwd);
	nttGeneric(field, pb, tw_fwd);
	for (0..N) |i| pa[i] = field.mulMod(pa[i], pb[i]);
	nttGeneric(field, pa, tw_inv);
	const n_inv = field.invMod(@intCast(N));
	for (pa, 0..) |x, i| out[i] = field.mulMod(x, n_inv);
}

/// CRT combine using Garner's form. Given r1 ≡ x (mod p1) and r2 ≡ x (mod p2)
/// with 0 ≤ x < p1*p2, returns x. All in u64 since p1*p2 < 2^60.
inline fn crtCombine(r1: u64, r2: u64) u64 {
	// diff = (r2 - r1) mod p2
	const diff = if (r2 >= r1) r2 - r1 else r2 + F2.p - r1;
	// k = diff * F1_INV_MOD_F2 mod p2
	const k = (diff * F1_INV_MOD_F2) % F2.p;
	// x = r1 + p1 * k  (fits in u64 since r1 < p1, k < p2, p1*p2 < 2^60)
	return r1 + F1.p * k;
}

/// Maximum combined operand length supported by the two-prime CRT variant.
/// Constraint: NTT length must be ≤ min(F1.max_ntt_len, F2.max_ntt_len) = 2^22.
/// And per-digit sum must fit in p1*p2 (~2^60); for byte digits this is
/// min(a,b) * 65025 < 2^60, far beyond what NTT length restricts.
/// Practical cap: a.len + b.len ≤ 2^22 = 4194304 bytes. We cap at 65536 to
/// keep allocations sane (the four u64 arrays at N=2^17 already cost 4 MB).
pub const MAX_FFT_CRT_COMBINED_LEN: usize = 65536;

/// Multiply two unsigned magnitudes via two-prime NTT + CRT reconstruction.
/// Same I/O contract as `mulMagnitudes` but supports operands up to ~32K bytes
/// each (256K bits combined). Internally runs the convolution twice — once
/// under F1, once under F2 — then merges via Garner's CRT to recover each
/// per-digit sum exactly, before the byte carry-propagation pass.
pub fn mulMagnitudesCRT(
	allocator: std.mem.Allocator,
	a: []const u8,
	b: []const u8,
	out: []u8,
) !usize {
	if (a.len == 0 or b.len == 0) return 0;
	const need_len = a.len + b.len;
	std.debug.assert(out.len >= need_len);
	std.debug.assert(need_len <= MAX_FFT_CRT_COMBINED_LEN);

	var N: usize = 1;
	while (N < need_len) N <<= 1;
	std.debug.assert(N <= F1.max_ntt_len);
	std.debug.assert(N <= F2.max_ntt_len);

	const c1 = try allocator.alloc(u64, N);
	defer allocator.free(c1);
	const c2 = try allocator.alloc(u64, N);
	defer allocator.free(c2);

	try convolveOnce(F1, allocator, a, b, N, c1);
	try convolveOnce(F2, allocator, a, b, N, c2);

	// CRT-merge each digit, then carry-propagate to bytes. We reuse `c1`
	// as the merged digit buffer to avoid another N-element allocation.
	for (0..N) |i| c1[i] = crtCombine(c1[i], c2[i]);

	var carry: u64 = 0;
	var i: usize = 0;
	while (i < need_len) : (i += 1) {
		const val = c1[i] + carry;
		out[i] = @truncate(val & 0xFF);
		carry = val >> 8;
	}
	std.debug.assert(carry == 0);

	var len = need_len;
	while (len > 0 and out[len - 1] == 0) len -= 1;
	return len;
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

test "mulModP edge cases" {
	try testing.expectEqual(@as(u64, 0), mulModP(0, 0));
	try testing.expectEqual(@as(u64, 1), mulModP(1, 1));
	try testing.expectEqual(@as(u64, 1), mulModP(P - 1, P - 1));
	try testing.expectEqual(@as(u64, P - 1), mulModP(P - 1, 1));
	try testing.expectEqual(@as(u64, P - 1), mulModP(1, P - 1));
	try testing.expectEqual(@as(u64, ((P / 2) * (P / 2)) % P), mulModP(P / 2, P / 2));
	try testing.expectEqual(@as(u64, ((P - 2) * (P - 2)) % P), mulModP(P - 2, P - 2));
}

test "Barrett mulModP matches (a*b)%P on 100K random inputs" {
	var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE);
	const rand = prng.random();
	var i: usize = 0;
	while (i < 100_000) : (i += 1) {
		const a = rand.uintLessThan(u64, P);
		const b = rand.uintLessThan(u64, P);
		const expected = (a * b) % P;
		const got = mulModP(a, b);
		if (got != expected) {
			std.debug.print("MISMATCH a={d} b={d} expected={d} got={d}\n", .{ a, b, expected, got });
			return error.TestFailed;
		}
	}
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

// Schoolbook unsigned multiply: little-endian byte arrays. Returns out length.
fn schoolbookMul(a: []const u8, b: []const u8, out: []u8) usize {
	@memset(out[0 .. a.len + b.len], 0);
	for (a, 0..) |av, i| {
		var carry: u32 = 0;
		for (b, 0..) |bv, j| {
			const cur: u32 = @as(u32, out[i + j]) + @as(u32, av) * @as(u32, bv) + carry;
			out[i + j] = @truncate(cur & 0xFF);
			carry = cur >> 8;
		}
		out[i + b.len] = @truncate(carry);
	}
	var len = a.len + b.len;
	while (len > 0 and out[len - 1] == 0) len -= 1;
	return len;
}

test "mulMagnitudes: matches schoolbook on small known cases" {
	const cases = [_]struct {
		a: []const u8,
		b: []const u8,
	}{
		.{ .a = &.{1}, .b = &.{1} },
		.{ .a = &.{0xFF}, .b = &.{0xFF} },
		.{ .a = &.{ 0x12, 0x34 }, .b = &.{ 0x56, 0x78 } },
		.{ .a = &.{ 0xFF, 0xFF, 0xFF, 0xFF }, .b = &.{ 0xFF, 0xFF, 0xFF, 0xFF } },
	};
	for (cases) |c| {
		var ref_buf: [16]u8 = undefined;
		var fft_buf: [16]u8 = undefined;
		const ref_len = schoolbookMul(c.a, c.b, &ref_buf);
		const fft_len = try mulMagnitudes(testing.allocator, c.a, c.b, &fft_buf);
		try testing.expectEqual(ref_len, fft_len);
		try testing.expectEqualSlices(u8, ref_buf[0..ref_len], fft_buf[0..fft_len]);
	}
}

test "mulMagnitudes: matches schoolbook on random sizes 64..2048 bytes" {
	var prng = std.Random.DefaultPrng.init(0xCAFEBABEDEADBEEF);
	const rand = prng.random();
	const sizes = [_]usize{ 64, 128, 256, 512, 1024, 2048 };
	for (sizes) |sz| {
		const a = try testing.allocator.alloc(u8, sz);
		defer testing.allocator.free(a);
		const b = try testing.allocator.alloc(u8, sz);
		defer testing.allocator.free(b);
		const ref = try testing.allocator.alloc(u8, 2 * sz);
		defer testing.allocator.free(ref);
		const got = try testing.allocator.alloc(u8, 2 * sz);
		defer testing.allocator.free(got);

		for (a) |*x| x.* = rand.int(u8);
		for (b) |*x| x.* = rand.int(u8);
		// Ensure top bytes are non-zero so neither operand is "shorter than declared".
		a[sz - 1] = (a[sz - 1] | 0x80);
		b[sz - 1] = (b[sz - 1] | 0x80);

		const ref_len = schoolbookMul(a, b, ref);
		const got_len = try mulMagnitudes(testing.allocator, a, b, got);
		try testing.expectEqual(ref_len, got_len);
		try testing.expectEqualSlices(u8, ref[0..ref_len], got[0..got_len]);
	}
}

test "mulMagnitudes: unequal operand lengths" {
	var prng = std.Random.DefaultPrng.init(0x1234567890ABCDEF);
	const rand = prng.random();
	const pairs = [_]struct { a: usize, b: usize }{
		.{ .a = 100, .b = 50 },
		.{ .a = 1, .b = 4096 },
		.{ .a = 4096, .b = 1 },
		.{ .a = 3000, .b = 1500 },
	};
	for (pairs) |p| {
		const a = try testing.allocator.alloc(u8, p.a);
		defer testing.allocator.free(a);
		const b = try testing.allocator.alloc(u8, p.b);
		defer testing.allocator.free(b);
		const ref = try testing.allocator.alloc(u8, p.a + p.b);
		defer testing.allocator.free(ref);
		const got = try testing.allocator.alloc(u8, p.a + p.b);
		defer testing.allocator.free(got);

		for (a) |*x| x.* = rand.int(u8);
		for (b) |*x| x.* = rand.int(u8);
		a[p.a - 1] |= 0x80;
		b[p.b - 1] |= 0x80;

		const ref_len = schoolbookMul(a, b, ref);
		const got_len = try mulMagnitudes(testing.allocator, a, b, got);
		try testing.expectEqual(ref_len, got_len);
		try testing.expectEqualSlices(u8, ref[0..ref_len], got[0..got_len]);
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

// ── Two-prime CRT NTT tests ─────────────────────────────────────────────────

test "mulMagnitudesCRT: matches schoolbook on small known cases" {
	const cases = [_]struct {
		a: []const u8,
		b: []const u8,
	}{
		.{ .a = &.{1}, .b = &.{1} },
		.{ .a = &.{0xFF}, .b = &.{0xFF} },
		.{ .a = &.{ 0x12, 0x34 }, .b = &.{ 0x56, 0x78 } },
		.{ .a = &.{ 0xFF, 0xFF, 0xFF, 0xFF }, .b = &.{ 0xFF, 0xFF, 0xFF, 0xFF } },
	};
	for (cases) |c| {
		var ref_buf: [16]u8 = undefined;
		var fft_buf: [16]u8 = undefined;
		const ref_len = schoolbookMul(c.a, c.b, &ref_buf);
		const fft_len = try mulMagnitudesCRT(testing.allocator, c.a, c.b, &fft_buf);
		try testing.expectEqual(ref_len, fft_len);
		try testing.expectEqualSlices(u8, ref_buf[0..ref_len], fft_buf[0..fft_len]);
	}
}

test "mulMagnitudesCRT: matches schoolbook at 1024 bytes (within single-prime range)" {
	const sz: usize = 1024;
	var prng = std.Random.DefaultPrng.init(0xDEADBEEFCAFEBABE);
	const rand = prng.random();
	const a = try testing.allocator.alloc(u8, sz);
	defer testing.allocator.free(a);
	const b = try testing.allocator.alloc(u8, sz);
	defer testing.allocator.free(b);
	const ref = try testing.allocator.alloc(u8, 2 * sz);
	defer testing.allocator.free(ref);
	const got = try testing.allocator.alloc(u8, 2 * sz);
	defer testing.allocator.free(got);

	for (a) |*x| x.* = rand.int(u8);
	for (b) |*x| x.* = rand.int(u8);
	a[sz - 1] |= 0x80;
	b[sz - 1] |= 0x80;

	const ref_len = schoolbookMul(a, b, ref);
	const got_len = try mulMagnitudesCRT(testing.allocator, a, b, got);
	try testing.expectEqual(ref_len, got_len);
	try testing.expectEqualSlices(u8, ref[0..ref_len], got[0..got_len]);
}

test "mulMagnitudesCRT: matches schoolbook at 16384 bytes per operand (beyond single-prime)" {
	const sz: usize = 16384;
	var prng = std.Random.DefaultPrng.init(0xABCDEF0123456789);
	const rand = prng.random();
	const a = try testing.allocator.alloc(u8, sz);
	defer testing.allocator.free(a);
	const b = try testing.allocator.alloc(u8, sz);
	defer testing.allocator.free(b);
	const ref = try testing.allocator.alloc(u8, 2 * sz);
	defer testing.allocator.free(ref);
	const got = try testing.allocator.alloc(u8, 2 * sz);
	defer testing.allocator.free(got);

	for (a) |*x| x.* = rand.int(u8);
	for (b) |*x| x.* = rand.int(u8);
	a[sz - 1] |= 0x80;
	b[sz - 1] |= 0x80;

	const ref_len = schoolbookMul(a, b, ref);
	const got_len = try mulMagnitudesCRT(testing.allocator, a, b, got);
	try testing.expectEqual(ref_len, got_len);
	try testing.expectEqualSlices(u8, ref[0..ref_len], got[0..got_len]);
}

test "mulMagnitudesCRT: 100-iter random fuzz at sizes 4096..16384 bytes" {
	var prng = std.Random.DefaultPrng.init(0x0F0E0D0C0B0A0908);
	const rand = prng.random();
	var iter: usize = 0;
	while (iter < 100) : (iter += 1) {
		// Random sizes in [4096, 16384].
		const sa = 4096 + rand.uintLessThan(usize, 16384 - 4096 + 1);
		const sb = 4096 + rand.uintLessThan(usize, 16384 - 4096 + 1);
		const a = try testing.allocator.alloc(u8, sa);
		defer testing.allocator.free(a);
		const b = try testing.allocator.alloc(u8, sb);
		defer testing.allocator.free(b);
		const ref = try testing.allocator.alloc(u8, sa + sb);
		defer testing.allocator.free(ref);
		const got = try testing.allocator.alloc(u8, sa + sb);
		defer testing.allocator.free(got);

		for (a) |*x| x.* = rand.int(u8);
		for (b) |*x| x.* = rand.int(u8);
		a[sa - 1] |= 0x80;
		b[sb - 1] |= 0x80;

		const ref_len = schoolbookMul(a, b, ref);
		const got_len = try mulMagnitudesCRT(testing.allocator, a, b, got);
		try testing.expectEqual(ref_len, got_len);
		try testing.expectEqualSlices(u8, ref[0..ref_len], got[0..got_len]);
	}
}
