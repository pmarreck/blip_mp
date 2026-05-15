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
	const stockham_scratch = try allocator.alloc(u64, N);
	defer allocator.free(stockham_scratch);

	return mulMagnitudesWithScratch(a, b, out, pa, pb, tw_fwd, tw_inv, stockham_scratch);
}

/// E.1 + E.2 — caller-supplied scratch variant of `mulMagnitudes`. The
/// caller owns five buffers covering all internal state:
///   pa, pb            : N u64 each (digit buffers)
///   tw_fwd, tw_inv    : N/2 u64 each (precomputed twiddle tables)
///   stockham_scratch  : N u64 (Stockham auto-sort ping-pong buffer)
/// where N = next_pow2(a.len + b.len).
///
/// Eliminates the 4-5 per-call alloc/free pairs that previously dominated
/// the wall-clock budget for FFT-path multiplies (each ~1-2 K ns on libc
/// malloc; ~5-10 K ns total at N=8192). With this entry point the only
/// per-call cost is the actual transform work.
///
/// Internally uses Stockham auto-sort NTT (E.2) — skips the bit-reversal
/// pass entirely, ~9% per NTT × 3 NTTs per multiply ≈ 5-8 K ns saved at
/// N=8192. The Cooley-Tukey path (`nttWithTwiddlesVec`) is preserved on
/// the type system but no longer the production path.
pub fn mulMagnitudesWithScratch(
	a: []const u8,
	b: []const u8,
	out: []u8,
	pa: []u64,
	pb: []u64,
	tw_fwd: []u64,
	tw_inv: []u64,
	stockham_scratch: []u64,
) usize {
	if (a.len == 0 or b.len == 0) return 0;
	const need_len = a.len + b.len;
	std.debug.assert(out.len >= need_len);
	std.debug.assert(need_len <= MAX_FFT_COMBINED_LEN);

	var N: usize = 1;
	while (N < need_len) N <<= 1;
	std.debug.assert(pa.len >= N);
	std.debug.assert(pb.len >= N);
	std.debug.assert(tw_fwd.len >= N / 2);
	std.debug.assert(tw_inv.len >= N / 2);
	std.debug.assert(stockham_scratch.len >= N);

	const pa_n = pa[0..N];
	const pb_n = pb[0..N];
	const tw_fwd_n = tw_fwd[0 .. N / 2];
	const tw_inv_n = tw_inv[0 .. N / 2];
	const sc_n = stockham_scratch[0..N];

	// Precompute twiddles once, reuse across 3 NTT calls (forward A,
	// forward B, inverse). Cuts per-call mulModP count nearly in half.
	const omega_n = nthRootOfUnity(N);
	const omega_n_inv = invModP(omega_n);
	tw_fwd_n[0] = 1;
	tw_inv_n[0] = 1;
	{
		var j: usize = 1;
		while (j < N / 2) : (j += 1) {
			tw_fwd_n[j] = mulModP(tw_fwd_n[j - 1], omega_n);
			tw_inv_n[j] = mulModP(tw_inv_n[j - 1], omega_n_inv);
		}
	}

	@memset(pa_n, 0);
	@memset(pb_n, 0);
	for (a, 0..) |byte, i| pa_n[i] = byte;
	for (b, 0..) |byte, i| pb_n[i] = byte;

	nttStockhamVecU4(pa_n, sc_n, tw_fwd_n);
	nttStockhamVecU4(pb_n, sc_n, tw_fwd_n);
	for (0..N) |i| pa_n[i] = mulModP(pa_n[i], pb_n[i]);
	nttStockhamVecU4(pa_n, sc_n, tw_inv_n);
	const n_inv = invModP(@intCast(N));
	for (pa_n) |*x| x.* = mulModP(x.*, n_inv);

	// Carry propagation through the byte-output buffer.
	var carry: u64 = 0;
	var i: usize = 0;
	while (i < need_len) : (i += 1) {
		const val = pa_n[i] + carry;
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

// ── NEON SIMD vectorized modular arithmetic (M6-4-A) ────────────────────────
//
// On aarch64, @Vector(2, u64) lowers to a 128-bit NEON register. Lane-wise
// arithmetic ops compile to NEON `add.2d`, `sub.2d`, etc. The conditional
// "subtract P if sum >= P" pattern lowers via @select to `cmhs.2d` + `bsl`.
//
// The 30-bit prime P = 998244353 means inputs fit in 32 bits, but we keep
// the lane width at u64 because (a) NEON has no 64x64 high-half multiply for
// the scalar Granlund-Möller magic-number reduction we want to vectorize in
// A.3, and (b) staying in u64 avoids any narrow/widen ceremony at boundaries.

/// Lane-wise (a + b) mod P. Each lane independent. Inputs assumed in [0, P).
/// Lowers to NEON add.2d + cmhs.2d + bsl on aarch64. ~1.5–2× scalar throughput
/// expected once both lanes are useful work.
///
/// Note: `corrected` uses wrapping `-%` because the un-selected lane (where
/// sum < P) would otherwise underflow and trip Debug-mode integer safety
/// checks. ReleaseFast discards the wrapped value via @select, but Debug
/// fires the panic before the select runs.
pub inline fn addModP_x2(a: @Vector(2, u64), b: @Vector(2, u64)) @Vector(2, u64) {
	const sum = a + b;
	const p_vec: @Vector(2, u64) = @splat(P);
	const ge_mask = sum >= p_vec; // @Vector(2, bool)
	const corrected = sum -% p_vec;
	return @select(u64, ge_mask, corrected, sum);
}

/// Lane-wise (a - b) mod P. Each lane independent. Inputs in [0, P).
/// `direct` uses wrapping `-%` for the same Debug-safety reason as addModP_x2.
pub inline fn subModP_x2(a: @Vector(2, u64), b: @Vector(2, u64)) @Vector(2, u64) {
	const p_vec: @Vector(2, u64) = @splat(P);
	const lt_mask = a < b; // @Vector(2, bool)
	const wrapped = a + p_vec -% b;
	const direct = a -% b;
	return @select(u64, lt_mask, wrapped, direct);
}

/// Lane-wise (a * b) mod P. Each lane independent. Inputs in [0, P), result in [0, P).
/// Approach: extract scalar, run scalar mulModP, recombine. The compiler MAY
/// auto-vectorize the magic-number `% P` lowering across the two lanes; if so
/// we get the win for free. Empirically (see microbench output) we measure
/// whether this beats two scalar calls or whether a more elaborate hand
/// vectorization is needed.
///
/// Why not a hand-rolled NEON umulh? aarch64 NEON has no `umulh.2d`; you'd
/// compose it from four umull2 (u32×u32→u64) and adds, which is more work
/// than the scalar pipeline already does. This implementation deliberately
/// goes through scalar so we can compare against that lower bound.
///
/// **2026-05-02 (M6-4-A.6):** This wrapper is preserved for callers that need
/// strict normal-form `(a*b)%P` semantics. The actual FFT path now goes
/// through `montMul_x2` (Montgomery form) — see `mulMagnitudes` and
/// `nttWithTwiddlesMontVec`. Montgomery multiplication has no `umulh`
/// dependency: it uses two 64x64→64 multiplies + one add + one shift +
/// vectorized conditional subtract, which IS NEON-friendly.
pub inline fn mulModP_x2(a: @Vector(2, u64), b: @Vector(2, u64)) @Vector(2, u64) {
	// Pull lanes into scalars, reduce, repack. The scalar `% P` lowering is
	// essentially optimal (mul + umulh + msub) and the compiler may even
	// schedule both lanes' reductions in parallel — measure to find out.
	const r0 = (a[0] * b[0]) % P;
	const r1 = (a[1] * b[1]) % P;
	return .{ r0, r1 };
}

// ── Montgomery arithmetic mod P (M6-4-A.6 / M6-4-B) ────────────────────────
//
// Montgomery form: x_m = x * R mod P where R = 2^32 (chosen so that division
// by R is a free 32-bit shift and that mod-R is a free 32-bit truncation).
// All arithmetic stays in Mont form throughout the NTT; we convert in/out at
// the boundaries (inputs once, outputs once). The big win is that Montgomery
// multiplication has no `umulh` dependency — only 64x64→64 mul + add + shift +
// conditional subtract — all of which vectorize on NEON `@Vector(2, u64)`.
//
// Algorithm (Mont reduction of T < P*R = P*2^32 < 2^62):
//   m = (T mod 2^32) * P_NEG_INV mod 2^32   // low 32-bit mul, low 32 bits
//   t = (T + m * P) >> 32                   // m*P fits in u64 (< 2^62)
//   if t >= P: t -= P                       // single conditional subtract
//
// For inputs a_m, b_m < P < 2^30: T = a_m * b_m < 2^60, satisfying T < P*R.
//
// Constants:
//   R = 2^32
//   P_NEG_INV = (-P)^(-1) mod R = R - P^(-1) mod R = 998244351
//   R2_MOD_P  = R^2 mod P = 932051910  (used to convert into Mont form)
//   ONE_MOD_P = R mod P    = 301989884  (Mont form of 1, useful as identity)
//
// To convert: x_m = mont_mul(x, R2_MOD_P).
// From Mont:  x   = mont_mul(x_m, 1).

/// (-P)^(-1) mod 2^32. Constant input to every Montgomery reduction.
pub const P_NEG_INV: u64 = 998244351;

/// R^2 mod P where R = 2^32. Used to enter Montgomery form: `toMont(x) = montMul(x, R2_MOD_P)`.
pub const R2_MOD_P: u64 = 932051910;

/// R mod P where R = 2^32. The Mont-form representation of 1 (multiplicative
/// identity in Montgomery space).
pub const ONE_MOD_P: u64 = 301989884;

/// Scalar Montgomery multiplication: returns `(a_m * b_m * R^(-1)) mod P`.
/// Both inputs and output are in Montgomery form. T = a_m * b_m must satisfy
/// T < P*R ≈ 2^62; for inputs < P < 2^30 this gives T < 2^60, well within bounds.
pub inline fn montMul(a_m: u64, b_m: u64) u64 {
	const T: u64 = a_m *% b_m;
	const m: u64 = (T & 0xFFFFFFFF) *% P_NEG_INV & 0xFFFFFFFF;
	const t: u64 = (T +% m *% P) >> 32;
	return if (t >= P) t - P else t;
}

/// Convert a normal-form residue x ∈ [0, P) into Montgomery form: x_m = x * R mod P.
pub inline fn toMont(x: u64) u64 {
	return montMul(x, R2_MOD_P);
}

/// Convert a Montgomery-form residue x_m back to normal form: x = x_m * R^(-1) mod P.
/// Implemented as `montMul(x_m, 1)` since `montMul(a, 1) = a * R^(-1) mod P`.
pub inline fn fromMont(x_m: u64) u64 {
	return montMul(x_m, 1);
}

/// Vectorized Montgomery multiplication on `@Vector(2, u64)`. Both inputs and
/// output are in Montgomery form.
///
/// **Hybrid scheduling for Apple M4:** the M4 has dual scalar mul pipes (≤2
/// 64×64 muls per cycle) but only 1–2 NEON pipes that ALSO service vector
/// add/sub/load/store. Pure-NEON Mont (using umull.2d for T=a*b) saturates
/// the NEON pipe and crowds out the surrounding butterfly ops. So we instead
/// compute `T = a*b` via two scalar 32×32→64 muls (free use of scalar pipes
/// while NEON handles the surrounding adds), then do the rest of the
/// Montgomery reduction in vector registers (mul.2s + umlal.2d + cmhs.2d).
///
/// Per-butterfly: 2 scalar muls + 3 NEON ops (vs `% P` path: 2 scalar muls +
/// 2 scalar umulh + 2 scalar msub = 6 scalar ops, no NEON math). The big
/// difference is umulh elimination — umulh has higher latency than mul on M4
/// and only one umulh-capable pipe (per Apple optimization guides).
pub inline fn montMul_x2(a_m: @Vector(2, u64), b_m: @Vector(2, u64)) @Vector(2, u64) {
	const p_neg_inv_v32: @Vector(2, u32) = @splat(@as(u32, @intCast(P_NEG_INV)));
	const p_v32: @Vector(2, u32) = @splat(@as(u32, @intCast(P)));
	const p_v: @Vector(2, u64) = @splat(P);
	const shift32: @Vector(2, u6) = @splat(32);

	// T = a*b via scalar 32×32→64 muls (use scalar pipes; cheap because
	// inputs are u32-bounded). Then pack into a vector for the reduction.
	const t0: u64 = (a_m[0] & 0xFFFFFFFF) * (b_m[0] & 0xFFFFFFFF);
	const t1: u64 = (a_m[1] & 0xFFFFFFFF) * (b_m[1] & 0xFFFFFFFF);
	const T: @Vector(2, u64) = .{ t0, t1 };

	// T_lo32 (just the low 32 bits, as u32 vector).
	const T_lo32: @Vector(2, u32) = .{ @truncate(t0), @truncate(t1) };

	// m = (T_lo32 * P_NEG_INV) low 32 bits — single mul.2s, two lanes.
	const m32: @Vector(2, u32) = T_lo32 *% p_neg_inv_v32;

	// t = (T + m * P) >> 32. m*P fits in u64; expressed via umlal.2d
	// (multiply-accumulate) the compiler will fuse into a single instruction.
	const mp: @Vector(2, u64) = @as(@Vector(2, u64), m32) *% @as(@Vector(2, u64), p_v32);
	const t = (T +% mp) >> shift32;

	// Conditional subtract: vectorized cmhs.2d + select. Wrapping `-%` so
	// the un-selected lane (t < P) doesn't trip Debug-mode integer safety.
	const ge_mask = t >= p_v;
	const corrected = t -% p_v;
	return @select(u64, ge_mask, corrected, t);
}

// ── Mont-form NTT helpers ──────────────────────────────────────────────────

/// Same iterative radix-2 Cooley-Tukey NTT as `nttWithTwiddlesVec`, but
/// operates on Montgomery-form data with Montgomery-form twiddles. The add/sub
/// operations are unchanged (Mont form is linear: `Mont(a+b) = Mont(a)+Mont(b)`),
/// only the multiplication switches to `montMul_x2`. This is the routine that
/// gives the FFT path its real win — Mp.mul drops materially at 32K+ bit.
pub fn nttWithTwiddlesMontVec(a: []u64, twiddles_m: []const u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(twiddles_m.len >= n / 2);

	bitReversePermute(a);

	var len: usize = 2;
	while (len <= n) : (len <<= 1) {
		const stride = n / len;
		const half = len >> 1;
		var i: usize = 0;
		if (half == 1) {
			// Scalar fallback for the smallest level (no pair to vectorize).
			while (i < n) : (i += len) {
				const w = twiddles_m[0]; // Mont(1) = ONE_MOD_P
				const u = a[i];
				const t = montMul(a[i + 1], w);
				a[i] = addModP(u, t);
				a[i + 1] = subModP(u, t);
			}
		} else {
			while (i < n) : (i += len) {
				var k: usize = 0;
				while (k < half) : (k += 2) {
					const w_pair: @Vector(2, u64) = .{
						twiddles_m[k * stride],
						twiddles_m[(k + 1) * stride],
					};
					const a_lo: @Vector(2, u64) = .{ a[i + k], a[i + k + 1] };
					const a_hi: @Vector(2, u64) = .{ a[i + k + half], a[i + k + 1 + half] };
					const t_pair = montMul_x2(a_hi, w_pair);
					const new_lo = addModP_x2(a_lo, t_pair);
					const new_hi = subModP_x2(a_lo, t_pair);
					a[i + k] = new_lo[0];
					a[i + k + 1] = new_lo[1];
					a[i + k + half] = new_hi[0];
					a[i + k + 1 + half] = new_hi[1];
				}
			}
		}
	}
}

// ── Vectorized NTT inner loop (M6-4-A.4) ────────────────────────────────────
//
// Same algorithm as `nttWithTwiddles`, but for level `len >= 4` (i.e.,
// `half >= 2`) the inner butterfly loop is unrolled by 2 and run through the
// `@Vector(2, u64)` modular primitives. At level `len = 2` (`half = 1`) there
// is no pair to vectorize, so we fall back to scalar for that one level.
//
// Memory layout is unchanged: lanes (k, k+1) within one block (i, len) are
// adjacent in `a[]` for both the lo (`a[i+k]`) and hi (`a[i+k+half]`) halves,
// so the loads/stores compress to two contiguous u64 pairs per butterfly pair.
// Twiddle indices `k*stride` and `(k+1)*stride` are NOT adjacent (they're
// stride apart), so we materialize the twiddle pair via two scalar reads.
pub fn nttWithTwiddlesVec(a: []u64, twiddles: []const u64) void {
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
		if (half == 1) {
			// Scalar fallback for the smallest level — no pair to vectorize.
			while (i < n) : (i += len) {
				const w = twiddles[0]; // == 1, but we read for symmetry
				const u = a[i];
				const t = mulModP(a[i + 1], w);
				a[i] = addModP(u, t);
				a[i + 1] = subModP(u, t);
			}
		} else {
			// half >= 2 and is even (always — half = len/2, len pow2 >= 4).
			while (i < n) : (i += len) {
				var k: usize = 0;
				while (k < half) : (k += 2) {
					const w_pair: @Vector(2, u64) = .{
						twiddles[k * stride],
						twiddles[(k + 1) * stride],
					};
					const a_lo: @Vector(2, u64) = .{ a[i + k], a[i + k + 1] };
					const a_hi: @Vector(2, u64) = .{ a[i + k + half], a[i + k + 1 + half] };
					const t_pair = mulModP_x2(a_hi, w_pair);
					const new_lo = addModP_x2(a_lo, t_pair);
					const new_hi = subModP_x2(a_lo, t_pair);
					a[i + k] = new_lo[0];
					a[i + k + 1] = new_lo[1];
					a[i + k + half] = new_hi[0];
					a[i + k + 1 + half] = new_hi[1];
				}
			}
		}
	}
}

// ── Stockham auto-sort NTT (M6-4-C) ─────────────────────────────────────────
//
// Cooley-Tukey requires a separate bit-reversal permutation pass before the
// butterflies. Stockham's variant interleaves the permutation INTO the
// butterflies by reading from one buffer and writing to another, with output
// indices computed so that the result lands in natural order. After log2(N)
// passes (ping-ponging buffers each pass), the data is naturally ordered. No
// explicit permutation pass.
//
// Trade-off: requires a second N-element scratch buffer (in-place is impossible
// with this index pattern). The cost-saving is the bit-reversal pass at N=8192
// is ~8K memory swaps; eliminating it across 3 NTT calls per multiply saves
// real time at large N.
//
// Buffer plumbing: pass `s` reads from `src` and writes to `dst`, then we swap
// pointers. After log2(N) passes, the natural-order output lives in:
//   - `a` if log2(N) is even (after even number of swaps)
//   - `scratch` if log2(N) is odd (we memcpy back to `a` so the output is
//     always in `a`).
//
// Index pattern (decimation-in-time, radix-2):
//   At pass s with m = 2^(s+1), m2 = m/2, L = N/m groups:
//     for q in 0..L, j in 0..m2:
//       w = twiddles[j * (N/m)]
//       x = src[q*m2 + j]              (lower half of group, source-side)
//       y = src[q*m2 + j + N/2]        (partner is N/2 away in source)
//       dst[q*m + j]      = x + w*y
//       dst[q*m + j + m2] = x - w*y
//
// We linearize the (q, j) pairs as p = 0..N/2 with q = p / m2, j = p % m2.

/// Scalar Stockham auto-sort NTT. `a` and `scratch` must be the same length
/// (a power of 2). `twiddles[j] = omega_n^j` for j in 0..n/2 (same convention
/// as `nttWithTwiddles`). On return, the natural-order transform lives in `a`;
/// `scratch` is clobbered.
pub fn nttStockham(a: []u64, scratch: []u64, twiddles: []const u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(scratch.len == n);
	std.debug.assert(twiddles.len >= n / 2);

	const half_n = n >> 1;
	var src: []u64 = a;
	var dst: []u64 = scratch;

	var m: usize = 2;
	while (m <= n) : (m <<= 1) {
		const m2 = m >> 1;
		const stride = n / m; // twiddle stride at this pass
		// L = n / m groups. Each group consumes m2 source pairs (lo at
		// q*m2+j, hi at q*m2+j+half_n) and writes m destinations.
		var q: usize = 0;
		while (q < n) : (q += m) {
			// q here is the destination block start (q*m in the formula
			// above maps to this loop's q because we iterate q_idx by m).
			const q_idx = q / m; // 0..L-1
			const src_base = q_idx * m2;
			var j: usize = 0;
			while (j < m2) : (j += 1) {
				const w = twiddles[j * stride];
				const x = src[src_base + j];
				const y = src[src_base + j + half_n];
				const t = mulModP(y, w);
				dst[q + j] = addModP(x, t);
				dst[q + j + m2] = subModP(x, t);
			}
		}
		// Ping-pong.
		const tmp = src;
		src = dst;
		dst = tmp;
	}

	// After log2(n) swaps, `src` holds the result. If log2(n) is even,
	// `src == a` already (last swap put it back). If odd, `src == scratch`
	// and we must copy into `a` so callers find the result in `a`.
	if (src.ptr != a.ptr) {
		@memcpy(a, src);
	}
}

/// Vectorized Stockham auto-sort NTT. Same algorithm as `nttStockham`, but the
/// inner butterfly loop is unrolled by 2 and run through `@Vector(2, u64)` SIMD
/// modular primitives — exactly mirroring the relationship between
/// `nttWithTwiddles` and `nttWithTwiddlesVec`.
///
/// At pass `m == 2` (m2 == 1), there is no pair to vectorize; we fall back to
/// scalar for that one level.
///
/// Note: `dst[q + j]` and `dst[q + j + m2]` are stored to two destination lanes
/// that are `m2` apart. For `m2 >= 2` we can vectorize across `j` and
/// `j+1` (which are adjacent in `dst` for both halves), exactly as the
/// Cooley-Tukey vec form does. Source loads at `src_base + j` and
/// `src_base + j + 1` are also adjacent.
pub fn nttStockhamVec(a: []u64, scratch: []u64, twiddles: []const u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(scratch.len == n);
	std.debug.assert(twiddles.len >= n / 2);

	const half_n = n >> 1;
	var src: []u64 = a;
	var dst: []u64 = scratch;

	var m: usize = 2;
	while (m <= n) : (m <<= 1) {
		const m2 = m >> 1;
		const stride = n / m;
		if (m2 == 1) {
			// Scalar fallback at the smallest level.
			var q: usize = 0;
			while (q < n) : (q += m) {
				const q_idx = q / m;
				const src_base = q_idx * m2;
				const w = twiddles[0]; // == 1
				const x = src[src_base];
				const y = src[src_base + half_n];
				const t = mulModP(y, w);
				dst[q] = addModP(x, t);
				dst[q + 1] = subModP(x, t);
			}
		} else {
			// m2 >= 2 (and is a power of 2) so we can step j by 2.
			var q: usize = 0;
			while (q < n) : (q += m) {
				const q_idx = q / m;
				const src_base = q_idx * m2;
				var j: usize = 0;
				while (j < m2) : (j += 2) {
					const w_pair: @Vector(2, u64) = .{
						twiddles[j * stride],
						twiddles[(j + 1) * stride],
					};
					const x_pair: @Vector(2, u64) = .{
						src[src_base + j],
						src[src_base + j + 1],
					};
					const y_pair: @Vector(2, u64) = .{
						src[src_base + j + half_n],
						src[src_base + j + 1 + half_n],
					};
					const t_pair = mulModP_x2(y_pair, w_pair);
					const new_lo = addModP_x2(x_pair, t_pair);
					const new_hi = subModP_x2(x_pair, t_pair);
					dst[q + j] = new_lo[0];
					dst[q + j + 1] = new_lo[1];
					dst[q + j + m2] = new_hi[0];
					dst[q + j + 1 + m2] = new_hi[1];
				}
			}
		}
		// Ping-pong.
		const tmp = src;
		src = dst;
		dst = tmp;
	}

	if (src.ptr != a.ptr) {
		@memcpy(a, src);
	}
}

/// **M6-4-E.3 (2026-05-14) — NEGATIVE EMPIRICAL RESULT.** Stockham +
/// Montgomery hybrid. The HYPOTHESIS was that combining Stockham (which
/// eliminates the bit-reversal pass) with Montgomery (which avoids the
/// `umulh` dependency in the inner mul) would compound to a 13–15% net
/// speedup over `nttStockhamVec`, hitting the M6-4-E.3 PLAN.md target
/// without writing inline asm.
///
/// Microbench reality on M-series:
///   N=8192:    nttStockhamMontVec 37050 ns vs nttStockhamVec 33235 ns → 0.90× (10% SLOWER)
///   N=32768:   nttStockhamMontVec 180515 ns vs nttStockhamVec 167765 ns → 0.93× (7% SLOWER)
///
/// Why the hybrid fails: although `montMul_x2` is ~10% faster per-call
/// than `mulModP_x2` (microbench: 0.720 vs 0.799 ns/op), the full-NTT-pass
/// inner loop is bound by L1 load/store traffic at these working sizes —
/// not mul throughput. The per-mul advantage is invisible against the
/// memory-bandwidth ceiling. AND the lane-extract / scalar-mul / lane-reinsert
/// pattern in `mulModP_x2` pairs better with the surrounding NEON adds than
/// `montMul_x2`'s mostly-vector reduction (which competes with addModP_x2 /
/// subModP_x2 for NEON pipe issue slots).
///
/// Conclusion: kept as a building block + correctness-validated reference
/// for future architectures (e.g., x86_64 Zen 4 where the Apple-specific
/// "dual scalar pipe + crowded NEON" analysis doesn't apply). NOT routed
/// into `mulMagnitudes` production path — `nttStockhamVec` remains the
/// winner on M-series.
///
/// Inputs MUST be in Montgomery form (caller converts via `toMont` before
/// the NTT and `fromMont` after the inverse). Twiddles must also be Mont-form.
///
/// Algorithm and memory layout are identical to `nttStockhamVec` — only the
/// inner mul switches from scalar `% P` to `montMul_x2`. add/sub are linear
/// under Montgomery (Mont(a+b) = Mont(a) + Mont(b)) so addModP_x2 / subModP_x2
/// are unchanged.
pub fn nttStockhamMontVec(a: []u64, scratch: []u64, twiddles_m: []const u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(scratch.len == n);
	std.debug.assert(twiddles_m.len >= n / 2);

	const half_n = n >> 1;
	var src: []u64 = a;
	var dst: []u64 = scratch;

	var m: usize = 2;
	while (m <= n) : (m <<= 1) {
		const m2 = m >> 1;
		const stride = n / m;
		if (m2 == 1) {
			// Scalar fallback at the smallest level.
			var q: usize = 0;
			while (q < n) : (q += m) {
				const q_idx = q / m;
				const src_base = q_idx * m2;
				const w = twiddles_m[0]; // Mont(1) = ONE_MOD_P
				const x = src[src_base];
				const y = src[src_base + half_n];
				const t = montMul(y, w);
				dst[q] = addModP(x, t);
				dst[q + 1] = subModP(x, t);
			}
		} else {
			var q: usize = 0;
			while (q < n) : (q += m) {
				const q_idx = q / m;
				const src_base = q_idx * m2;
				var j: usize = 0;
				while (j < m2) : (j += 2) {
					const w_pair: @Vector(2, u64) = .{
						twiddles_m[j * stride],
						twiddles_m[(j + 1) * stride],
					};
					const x_pair: @Vector(2, u64) = .{
						src[src_base + j],
						src[src_base + j + 1],
					};
					const y_pair: @Vector(2, u64) = .{
						src[src_base + j + half_n],
						src[src_base + j + 1 + half_n],
					};
					const t_pair = montMul_x2(y_pair, w_pair);
					const new_lo = addModP_x2(x_pair, t_pair);
					const new_hi = subModP_x2(x_pair, t_pair);
					dst[q + j] = new_lo[0];
					dst[q + j + 1] = new_lo[1];
					dst[q + j + m2] = new_hi[0];
					dst[q + j + 1 + m2] = new_hi[1];
				}
			}
		}
		const tmp = src;
		src = dst;
		dst = tmp;
	}

	if (src.ptr != a.ptr) {
		@memcpy(a, src);
	}
}

/// **M6-4-E.3 (2026-05-14) attempt B**: Stockham vec NTT, manually
/// unrolled by 2 (so each iteration processes 4 butterflies = 2 NEON
/// pairs instead of 1). Hypothesis: more independent work in flight gives
/// the scheduler more room to hide the mul → umulh → msub critical-path
/// latency in the per-lane scalar reduction.
///
/// At m2 == 2 the unroll exactly fills the level (one iteration per group);
/// at m2 == 1 we fall back to the existing scalar path. For m2 ≥ 4 we run
/// the unrolled body, then a tail-fixup for any odd remainder pair (since
/// m2 is always a power of 2 ≥ 2, m2 % 4 ∈ {0, 2}; the tail handles m2=2).
pub fn nttStockhamVecU4(a: []u64, scratch: []u64, twiddles: []const u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(scratch.len == n);
	std.debug.assert(twiddles.len >= n / 2);

	const half_n = n >> 1;
	var src: []u64 = a;
	var dst: []u64 = scratch;

	var m: usize = 2;
	while (m <= n) : (m <<= 1) {
		const m2 = m >> 1;
		const stride = n / m;
		if (m2 == 1) {
			// Scalar fallback at the smallest level.
			var q: usize = 0;
			while (q < n) : (q += m) {
				const q_idx = q / m;
				const src_base = q_idx * m2;
				const w = twiddles[0];
				const x = src[src_base];
				const y = src[src_base + half_n];
				const t = mulModP(y, w);
				dst[q] = addModP(x, t);
				dst[q + 1] = subModP(x, t);
			}
		} else if (m2 == 2) {
			// Single pair per group (no unroll possible — m2 == 2 means j ∈ {0}).
			var q: usize = 0;
			while (q < n) : (q += m) {
				const q_idx = q / m;
				const src_base = q_idx * m2;
				const w_pair: @Vector(2, u64) = .{ twiddles[0], twiddles[stride] };
				const x_pair: @Vector(2, u64) = .{ src[src_base], src[src_base + 1] };
				const y_pair: @Vector(2, u64) = .{ src[src_base + half_n], src[src_base + 1 + half_n] };
				const t_pair = mulModP_x2(y_pair, w_pair);
				const new_lo = addModP_x2(x_pair, t_pair);
				const new_hi = subModP_x2(x_pair, t_pair);
				dst[q] = new_lo[0];
				dst[q + 1] = new_lo[1];
				dst[q + m2] = new_hi[0];
				dst[q + m2 + 1] = new_hi[1];
			}
		} else {
			// m2 ≥ 4 — unroll body by 2 (= 4 butterflies per iteration).
			var q: usize = 0;
			while (q < n) : (q += m) {
				const q_idx = q / m;
				const src_base = q_idx * m2;
				var j: usize = 0;
				while (j < m2) : (j += 4) {
					// Pair 0: butterflies j, j+1.
					const w0: @Vector(2, u64) = .{
						twiddles[j * stride],
						twiddles[(j + 1) * stride],
					};
					const x0: @Vector(2, u64) = .{
						src[src_base + j],
						src[src_base + j + 1],
					};
					const y0: @Vector(2, u64) = .{
						src[src_base + j + half_n],
						src[src_base + j + 1 + half_n],
					};
					// Pair 1: butterflies j+2, j+3.
					const w1: @Vector(2, u64) = .{
						twiddles[(j + 2) * stride],
						twiddles[(j + 3) * stride],
					};
					const x1: @Vector(2, u64) = .{
						src[src_base + j + 2],
						src[src_base + j + 3],
					};
					const y1: @Vector(2, u64) = .{
						src[src_base + j + 2 + half_n],
						src[src_base + j + 3 + half_n],
					};
					// Compute both pairs' mods in immediate succession so the
					// scheduler can interleave the dependency chains.
					const t0 = mulModP_x2(y0, w0);
					const t1 = mulModP_x2(y1, w1);
					const lo0 = addModP_x2(x0, t0);
					const lo1 = addModP_x2(x1, t1);
					const hi0 = subModP_x2(x0, t0);
					const hi1 = subModP_x2(x1, t1);
					dst[q + j]            = lo0[0];
					dst[q + j + 1]        = lo0[1];
					dst[q + j + 2]        = lo1[0];
					dst[q + j + 3]        = lo1[1];
					dst[q + j + m2]       = hi0[0];
					dst[q + j + m2 + 1]   = hi0[1];
					dst[q + j + m2 + 2]   = hi1[0];
					dst[q + j + m2 + 3]   = hi1[1];
				}
			}
		}
		const tmp = src;
		src = dst;
		dst = tmp;
	}

	if (src.ptr != a.ptr) {
		@memcpy(a, src);
	}
}

/// **M6-4-E.3 attempt C — RESULT: no improvement over U4.** Stockham
/// vec NTT unrolled by 4 (= 8 butterflies per iteration). Tested whether
/// more ILP would keep paying off after the U4 win.
///
/// Microbench (3 runs, M-series, N=8192):
///   nttStockhamVecU4: 32045 / 30365 / 33125 ns
///   nttStockhamVecU8: 33035 / 30950 / 31620 ns
///   speedup U8/U4:    0.970× / 0.981× / 1.048× — at the noise floor
///
/// Conclusion: at U4 we appear to hit the L1 load/store-bandwidth ceiling
/// for this NTT-pass working set (~64KB at N=8192). Each butterfly moves
/// ~80 bytes (3 loads + 2 stores × 16B); 4 butterflies × 5 NEON-equiv
/// memory ops = 20 loads/cycle pressure on the LSU. More butterflies in
/// flight don't help because compute isn't the bottleneck.
///
/// Kept as a measured data point (and as the place to plug in any future
/// cache-tile-blocked variant that operates on 8 butterflies' worth of
/// data with explicit prefetch / re-use patterns). NOT wired into the
/// mulMagnitudes production path — U4 remains the winner.
pub fn nttStockhamVecU8(a: []u64, scratch: []u64, twiddles: []const u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(scratch.len == n);
	std.debug.assert(twiddles.len >= n / 2);

	const half_n = n >> 1;
	var src: []u64 = a;
	var dst: []u64 = scratch;

	var m: usize = 2;
	while (m <= n) : (m <<= 1) {
		const m2 = m >> 1;
		const stride = n / m;
		if (m2 < 8) {
			// Fall back to U4 (which itself falls back further for m2<4).
			// Avoids duplicating all the small-m2 paths here.
			nttStockhamVecU4Body(src, dst, twiddles, m, m2, stride, half_n, n);
		} else {
			// m2 ≥ 8 — unroll by 4 (= 8 butterflies per iter).
			var q: usize = 0;
			while (q < n) : (q += m) {
				const q_idx = q / m;
				const src_base = q_idx * m2;
				var j: usize = 0;
				while (j < m2) : (j += 8) {
					const w0: @Vector(2, u64) = .{ twiddles[(j + 0) * stride], twiddles[(j + 1) * stride] };
					const w1: @Vector(2, u64) = .{ twiddles[(j + 2) * stride], twiddles[(j + 3) * stride] };
					const w2: @Vector(2, u64) = .{ twiddles[(j + 4) * stride], twiddles[(j + 5) * stride] };
					const w3: @Vector(2, u64) = .{ twiddles[(j + 6) * stride], twiddles[(j + 7) * stride] };
					const x0: @Vector(2, u64) = .{ src[src_base + j + 0], src[src_base + j + 1] };
					const x1: @Vector(2, u64) = .{ src[src_base + j + 2], src[src_base + j + 3] };
					const x2: @Vector(2, u64) = .{ src[src_base + j + 4], src[src_base + j + 5] };
					const x3: @Vector(2, u64) = .{ src[src_base + j + 6], src[src_base + j + 7] };
					const y0: @Vector(2, u64) = .{ src[src_base + j + 0 + half_n], src[src_base + j + 1 + half_n] };
					const y1: @Vector(2, u64) = .{ src[src_base + j + 2 + half_n], src[src_base + j + 3 + half_n] };
					const y2: @Vector(2, u64) = .{ src[src_base + j + 4 + half_n], src[src_base + j + 5 + half_n] };
					const y3: @Vector(2, u64) = .{ src[src_base + j + 6 + half_n], src[src_base + j + 7 + half_n] };
					const t0 = mulModP_x2(y0, w0);
					const t1 = mulModP_x2(y1, w1);
					const t2 = mulModP_x2(y2, w2);
					const t3 = mulModP_x2(y3, w3);
					const lo0 = addModP_x2(x0, t0);
					const lo1 = addModP_x2(x1, t1);
					const lo2 = addModP_x2(x2, t2);
					const lo3 = addModP_x2(x3, t3);
					const hi0 = subModP_x2(x0, t0);
					const hi1 = subModP_x2(x1, t1);
					const hi2 = subModP_x2(x2, t2);
					const hi3 = subModP_x2(x3, t3);
					dst[q + j + 0] = lo0[0];
					dst[q + j + 1] = lo0[1];
					dst[q + j + 2] = lo1[0];
					dst[q + j + 3] = lo1[1];
					dst[q + j + 4] = lo2[0];
					dst[q + j + 5] = lo2[1];
					dst[q + j + 6] = lo3[0];
					dst[q + j + 7] = lo3[1];
					dst[q + j + m2 + 0] = hi0[0];
					dst[q + j + m2 + 1] = hi0[1];
					dst[q + j + m2 + 2] = hi1[0];
					dst[q + j + m2 + 3] = hi1[1];
					dst[q + j + m2 + 4] = hi2[0];
					dst[q + j + m2 + 5] = hi2[1];
					dst[q + j + m2 + 6] = hi3[0];
					dst[q + j + m2 + 7] = hi3[1];
				}
			}
		}
		const tmp = src;
		src = dst;
		dst = tmp;
	}

	if (src.ptr != a.ptr) {
		@memcpy(a, src);
	}
}

/// Helper used by nttStockhamVecU8 for small-m2 levels — runs ONE level
/// of the U4 algorithm. Exists so the U8 path can delegate without
/// re-implementing the small-m2 branches.
fn nttStockhamVecU4Body(
	src: []u64, dst: []u64, twiddles: []const u64,
	m: usize, m2: usize, stride: usize, half_n: usize, n: usize,
) void {
	if (m2 == 1) {
		var q: usize = 0;
		while (q < n) : (q += m) {
			const q_idx = q / m;
			const src_base = q_idx * m2;
			const w = twiddles[0];
			const x = src[src_base];
			const y = src[src_base + half_n];
			const t = mulModP(y, w);
			dst[q] = addModP(x, t);
			dst[q + 1] = subModP(x, t);
		}
	} else if (m2 == 2) {
		var q: usize = 0;
		while (q < n) : (q += m) {
			const q_idx = q / m;
			const src_base = q_idx * m2;
			const w_pair: @Vector(2, u64) = .{ twiddles[0], twiddles[stride] };
			const x_pair: @Vector(2, u64) = .{ src[src_base], src[src_base + 1] };
			const y_pair: @Vector(2, u64) = .{ src[src_base + half_n], src[src_base + 1 + half_n] };
			const t_pair = mulModP_x2(y_pair, w_pair);
			const new_lo = addModP_x2(x_pair, t_pair);
			const new_hi = subModP_x2(x_pair, t_pair);
			dst[q] = new_lo[0];
			dst[q + 1] = new_lo[1];
			dst[q + m2] = new_hi[0];
			dst[q + m2 + 1] = new_hi[1];
		}
	} else {
		// m2 == 4 — single U4 pass per group.
		var q: usize = 0;
		while (q < n) : (q += m) {
			const q_idx = q / m;
			const src_base = q_idx * m2;
			const w0: @Vector(2, u64) = .{ twiddles[0], twiddles[stride] };
			const w1: @Vector(2, u64) = .{ twiddles[2 * stride], twiddles[3 * stride] };
			const x0: @Vector(2, u64) = .{ src[src_base + 0], src[src_base + 1] };
			const x1: @Vector(2, u64) = .{ src[src_base + 2], src[src_base + 3] };
			const y0: @Vector(2, u64) = .{ src[src_base + 0 + half_n], src[src_base + 1 + half_n] };
			const y1: @Vector(2, u64) = .{ src[src_base + 2 + half_n], src[src_base + 3 + half_n] };
			const t0 = mulModP_x2(y0, w0);
			const t1 = mulModP_x2(y1, w1);
			const lo0 = addModP_x2(x0, t0);
			const lo1 = addModP_x2(x1, t1);
			const hi0 = subModP_x2(x0, t0);
			const hi1 = subModP_x2(x1, t1);
			dst[q + 0] = lo0[0];
			dst[q + 1] = lo0[1];
			dst[q + 2] = lo1[0];
			dst[q + 3] = lo1[1];
			dst[q + m2 + 0] = hi0[0];
			dst[q + m2 + 1] = hi0[1];
			dst[q + m2 + 2] = hi1[0];
			dst[q + m2 + 3] = hi1[1];
		}
	}
}

// ── Radix-4 NTT (M6-4-D) ───────────────────────────────────────────────────
//
// Cooley-Tukey radix-4 in-place NTT, expressed as a *fused pair of radix-2
// stages*. After bit-reversal, two consecutive radix-2 levels (call them
// inner=2M and outer=L=4M) operate on the same 4-element stride pattern:
//   indices (i+k, i+k+M, i+k+2M, i+k+3M)  — call them (a, b, c, d)
//
// The two-stage radix-2 sequence is:
//   Stage 2M (twiddle w2k = ω_L^(2k)):
//     A = a + w2k·b      B = a - w2k·b
//     C = c + w2k·d      D = c - w2k·d
//   Stage L (twiddles w_k = ω_L^k for the (A,C) pair,
//                     w_kM = ω_L^(k+M) = ω_L^k · ω_4 for the (B,D) pair):
//     a' = A + w_k·C     c' = A - w_k·C
//     b' = B + w_kM·D    d' = B - w_kM·D
//
// Mul count vs naive radix-2 two-stage (no k=0 skip): both = 4 muls per
// 4-element group.  Memory I/O per group: 4 reads + 4 writes vs 8 reads +
// 8 writes for the two separate radix-2 passes — i.e. ~2× reduction in
// L1/L2 traffic at outer levels, which is where wall-clock time lives at
// N≈8192 (working set ~64KB exceeds L1).
//
// Mixed-radix handling for log2(N) ODD (e.g. N=8192 → log2=13):
//   - bit-reverse
//   - one initial radix-2 pass at len=2  (consumes 1 stage)
//   - log4(N/2) radix-4 fused passes from L=8 up to L=N  (consumes the rest)
//
// Twiddle table convention is unchanged: twiddles[j] = ω_N^j for j ∈ [0, N/2).
// Twiddle reads at the radix-4 stage:
//   w_k   = twiddles[k     · (N/L)]
//   w_2k  = twiddles[(2k)  · (N/L)]
//   w_kM  = twiddles[(k+M) · (N/L)]   ; note (k+M)·(N/L) = k·(N/L) + N/4
// For (k+M)·(N/L) we precompute the additive constant `i_off = N/4` once.
//
// SIMD layout: process two groups (k and k+1) per inner-loop iteration via
// `@Vector(2, u64)` lanes, exactly mirroring `nttWithTwiddlesVec`. At
// `M == 1` (the smallest radix-4 stage, only present when log2(N) is even),
// adjacent groups are NOT contiguous in memory — index pattern is
// (i, i+1, i+2, i+3) per group with i stepping by 4 — so we vectorize
// across pairs of groups within an L-block, falling back to scalar when
// only 1 group fits.
pub fn nttRadix4Vec(a: []u64, twiddles: []const u64) void {
	const n = a.len;
	if (n <= 1) return;
	std.debug.assert(n & (n - 1) == 0);
	std.debug.assert(twiddles.len >= n / 2);

	bitReversePermute(a);

	const log2_n = std.math.log2_int(usize, n);
	var cur_L: usize = 1;

	// If log2(N) is odd, do one radix-2 stage at len=2 first so the
	// remaining stages fit a clean log4 ladder.
	if (log2_n & 1 == 1) {
		var i: usize = 0;
		while (i < n) : (i += 2) {
			const u = a[i];
			const t = a[i + 1]; // twiddle = 1
			a[i] = addModP(u, t);
			a[i + 1] = subModP(u, t);
		}
		cur_L = 2;
	}

	// Radix-4 fused stages: L = 4·cur_L each pass.
	while (cur_L < n) {
		const L = cur_L * 4;
		const M = L / 4;
		const stride = n / L;
		// (k+M)·stride = k·stride + M·stride = k·stride + N/4. Since the
		// twiddle table indexes ω_N^j, the offset for w_{k+M} is N/4.
		const i_off: usize = n / 4;

		var i: usize = 0;
		while (i < n) : (i += L) {
			// Per group at offset k: we touch (i+k, i+k+M, i+k+2M, i+k+3M).
			// Two consecutive groups (k, k+1) use the same stride pattern
			// shifted by 1, so their loads/stores compress to vector pairs.
			if (M == 1) {
				// Only one group per L-block — no pair to vectorize.
				const a_v = a[i];
				const b_v = a[i + 1];
				const c_v = a[i + 2];
				const d_v = a[i + 3];
				const w_k = twiddles[0];   // = 1
				const w_2k = twiddles[0];  // = 1
				const w_kM = twiddles[i_off]; // ω_4
				// Stage 2M butterflies (twiddle = 1, so multiply skipped here
				// by virtue of identity — but we keep the form for clarity).
				const tb = mulModP(b_v, w_2k);
				const A = addModP(a_v, tb);
				const B = subModP(a_v, tb);
				const td0 = mulModP(d_v, w_2k);
				const C = addModP(c_v, td0);
				const D = subModP(c_v, td0);
				// Stage L butterflies.
				const tC = mulModP(C, w_k);
				const out_a = addModP(A, tC);
				const out_c = subModP(A, tC);
				const tD = mulModP(D, w_kM);
				const out_b = addModP(B, tD);
				const out_d = subModP(B, tD);
				a[i] = out_a;
				a[i + 1] = out_b;
				a[i + 2] = out_c;
				a[i + 3] = out_d;
			} else {
				// M >= 2 (and a power of 2): vectorize two adjacent groups.
				var k: usize = 0;
				while (k < M) : (k += 2) {
					// Twiddle pairs: w_k for (k, k+1); w_2k for (2k, 2k+2);
					// w_kM for (k+M, k+1+M).
					const w_k_pair: @Vector(2, u64) = .{
						twiddles[k * stride],
						twiddles[(k + 1) * stride],
					};
					const w_2k_pair: @Vector(2, u64) = .{
						twiddles[(2 * k) * stride],
						twiddles[(2 * (k + 1)) * stride],
					};
					const w_kM_pair: @Vector(2, u64) = .{
						twiddles[k * stride + i_off],
						twiddles[(k + 1) * stride + i_off],
					};

					// Load 4-element group for k and k+1, packed into pairs.
					const av: @Vector(2, u64) = .{ a[i + k], a[i + k + 1] };
					const bv: @Vector(2, u64) = .{ a[i + k + M], a[i + k + 1 + M] };
					const cv: @Vector(2, u64) = .{ a[i + k + 2 * M], a[i + k + 1 + 2 * M] };
					const dv: @Vector(2, u64) = .{ a[i + k + 3 * M], a[i + k + 1 + 3 * M] };

					// Stage 2M butterflies (twiddle w_2k for both (a,b) and (c,d)).
					const tb = mulModP_x2(bv, w_2k_pair);
					const A = addModP_x2(av, tb);
					const B = subModP_x2(av, tb);
					const td0 = mulModP_x2(dv, w_2k_pair);
					const C = addModP_x2(cv, td0);
					const D = subModP_x2(cv, td0);

					// Stage L butterflies.
					const tC = mulModP_x2(C, w_k_pair);
					const out_a = addModP_x2(A, tC);
					const out_c = subModP_x2(A, tC);
					const tD = mulModP_x2(D, w_kM_pair);
					const out_b = addModP_x2(B, tD);
					const out_d = subModP_x2(B, tD);

					// Store back into the same 4-element-per-group layout.
					a[i + k] = out_a[0];
					a[i + k + 1] = out_a[1];
					a[i + k + M] = out_b[0];
					a[i + k + 1 + M] = out_b[1];
					a[i + k + 2 * M] = out_c[0];
					a[i + k + 1 + 2 * M] = out_c[1];
					a[i + k + 3 * M] = out_d[0];
					a[i + k + 1 + 3 * M] = out_d[1];
				}
			}
		}
		cur_L = L;
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

test "mulMagnitudesWithScratch: caller-supplied scratch matches schoolbook" {
	// E.1 — verify the scratch-supplied form produces identical output
	// to the allocator-using wrapper, with caller owning all 5 buffers
	// (pa, pb, tw_fwd, tw_inv, stockham_scratch).
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
		const need_len = c.a.len + c.b.len;
		var N: usize = 1;
		while (N < need_len) N <<= 1;
		const pa = try testing.allocator.alloc(u64, N);
		defer testing.allocator.free(pa);
		const pb = try testing.allocator.alloc(u64, N);
		defer testing.allocator.free(pb);
		const tw_fwd = try testing.allocator.alloc(u64, N / 2);
		defer testing.allocator.free(tw_fwd);
		const tw_inv = try testing.allocator.alloc(u64, N / 2);
		defer testing.allocator.free(tw_inv);
		const stockham_scratch = try testing.allocator.alloc(u64, N);
		defer testing.allocator.free(stockham_scratch);

		const ref_len = schoolbookMul(c.a, c.b, &ref_buf);
		const fft_len = mulMagnitudesWithScratch(c.a, c.b, &fft_buf, pa, pb, tw_fwd, tw_inv, stockham_scratch);
		try testing.expectEqual(ref_len, fft_len);
		try testing.expectEqualSlices(u8, ref_buf[0..ref_len], fft_buf[0..fft_len]);
	}
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

// ── M6-4-A SIMD lane-equivalence tests ──────────────────────────────────────

test "addModP_x2 / subModP_x2: edge cases (0, P-1, mid)" {
	// Hand-picked corners that exercise wrap (sum>=P, a<b) on both lanes.
	const corners = [_]struct { a0: u64, a1: u64, b0: u64, b1: u64 }{
		.{ .a0 = 0, .a1 = P - 1, .b0 = 0, .b1 = 1 },     // lane1 wraps add
		.{ .a0 = P - 1, .a1 = 5, .b0 = P - 1, .b1 = 7 }, // lane0 wraps add
		.{ .a0 = 0, .a1 = 0, .b0 = 1, .b1 = P - 1 },     // both wrap sub
		.{ .a0 = 5, .a1 = P / 2, .b0 = 7, .b1 = P / 2 }, // mixed
	};
	for (corners) |c| {
		const av: @Vector(2, u64) = .{ c.a0, c.a1 };
		const bv: @Vector(2, u64) = .{ c.b0, c.b1 };
		const got_add = addModP_x2(av, bv);
		const got_sub = subModP_x2(av, bv);
		try testing.expectEqual(addModP(c.a0, c.b0), got_add[0]);
		try testing.expectEqual(addModP(c.a1, c.b1), got_add[1]);
		try testing.expectEqual(subModP(c.a0, c.b0), got_sub[0]);
		try testing.expectEqual(subModP(c.a1, c.b1), got_sub[1]);
	}
}

test "addModP_x2 / subModP_x2: lane-equivalent to scalar on 100K random pairs" {
	var prng = std.Random.DefaultPrng.init(0x5EED1);
	const rand = prng.random();
	var i: usize = 0;
	while (i < 100_000) : (i += 1) {
		const a0 = rand.uintLessThan(u64, P);
		const a1 = rand.uintLessThan(u64, P);
		const b0 = rand.uintLessThan(u64, P);
		const b1 = rand.uintLessThan(u64, P);
		const av: @Vector(2, u64) = .{ a0, a1 };
		const bv: @Vector(2, u64) = .{ b0, b1 };
		const got_add = addModP_x2(av, bv);
		const got_sub = subModP_x2(av, bv);
		try testing.expectEqual(addModP(a0, b0), got_add[0]);
		try testing.expectEqual(addModP(a1, b1), got_add[1]);
		try testing.expectEqual(subModP(a0, b0), got_sub[0]);
		try testing.expectEqual(subModP(a1, b1), got_sub[1]);
	}
}

test "mulModP_x2: edge cases" {
	const corners = [_]struct { a0: u64, a1: u64, b0: u64, b1: u64 }{
		.{ .a0 = 0, .a1 = 0, .b0 = 0, .b1 = 0 },
		.{ .a0 = 1, .a1 = 1, .b0 = P - 1, .b1 = P - 1 },
		.{ .a0 = P - 1, .a1 = P / 2, .b0 = P - 1, .b1 = P / 2 },
		.{ .a0 = 12345, .a1 = 67890, .b0 = 11111, .b1 = 22222 },
	};
	for (corners) |c| {
		const av: @Vector(2, u64) = .{ c.a0, c.a1 };
		const bv: @Vector(2, u64) = .{ c.b0, c.b1 };
		const got = mulModP_x2(av, bv);
		try testing.expectEqual(mulModP(c.a0, c.b0), got[0]);
		try testing.expectEqual(mulModP(c.a1, c.b1), got[1]);
	}
}

test "nttWithTwiddlesVec: matches nttWithTwiddles on random inputs across sizes" {
	const sizes = [_]usize{ 2, 4, 8, 16, 64, 256, 1024, 4096, 8192 };
	for (sizes) |n| {
		const a_scalar = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_scalar);
		const a_vec = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_vec);
		const tw = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw);

		var prng = std.Random.DefaultPrng.init(0xA1B2_C3D4_E5F6 ^ n);
		const rand = prng.random();
		for (a_scalar) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(a_vec, a_scalar);

		// Build forward twiddle table.
		const omega_n = nthRootOfUnity(n);
		if (tw.len > 0) tw[0] = 1;
		var j: usize = 1;
		while (j < tw.len) : (j += 1) tw[j] = mulModP(tw[j - 1], omega_n);

		nttWithTwiddles(a_scalar, tw);
		nttWithTwiddlesVec(a_vec, tw);

		try testing.expectEqualSlices(u64, a_scalar, a_vec);
	}
}

test "nttWithTwiddlesVec: round-trip with inverse equals identity" {
	// Sanity check — uses both forward + inverse via vectorized path.
	const sizes = [_]usize{ 4, 16, 256, 1024, 4096 };
	for (sizes) |n| {
		const a = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a);
		const orig = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(orig);
		const tw_fwd = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw_fwd);
		const tw_inv = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw_inv);

		var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF ^ n);
		const rand = prng.random();
		for (a) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(orig, a);

		const omega_n = nthRootOfUnity(n);
		const omega_n_inv = invModP(omega_n);
		tw_fwd[0] = 1;
		tw_inv[0] = 1;
		var j: usize = 1;
		while (j < n / 2) : (j += 1) {
			tw_fwd[j] = mulModP(tw_fwd[j - 1], omega_n);
			tw_inv[j] = mulModP(tw_inv[j - 1], omega_n_inv);
		}

		nttWithTwiddlesVec(a, tw_fwd);
		nttWithTwiddlesVec(a, tw_inv);
		const n_inv = invModP(@intCast(n));
		for (a) |*x| x.* = mulModP(x.*, n_inv);

		try testing.expectEqualSlices(u64, orig, a);
	}
}

test "mulModP_x2: lane-equivalent to scalar on 100K random pairs" {
	var prng = std.Random.DefaultPrng.init(0x5EED2);
	const rand = prng.random();
	var i: usize = 0;
	while (i < 100_000) : (i += 1) {
		const a0 = rand.uintLessThan(u64, P);
		const a1 = rand.uintLessThan(u64, P);
		const b0 = rand.uintLessThan(u64, P);
		const b1 = rand.uintLessThan(u64, P);
		const av: @Vector(2, u64) = .{ a0, a1 };
		const bv: @Vector(2, u64) = .{ b0, b1 };
		const got = mulModP_x2(av, bv);
		try testing.expectEqual(mulModP(a0, b0), got[0]);
		try testing.expectEqual(mulModP(a1, b1), got[1]);
	}
}

// ── M6-4-A.6 / M6-4-B Montgomery tests ──────────────────────────────────────

test "Montgomery constants: math identities" {
	// Constants must satisfy:
	//   ONE_MOD_P = 2^32 mod P
	//   R2_MOD_P  = (2^32)^2 mod P
	//   P * P_NEG_INV ≡ -1 (mod 2^32)
	const R: u64 = 1 << 32;
	try testing.expectEqual(@as(u64, R % P), ONE_MOD_P);
	// Compute (R * R) mod P in u128 to avoid u64 overflow.
	const R2: u128 = @as(u128, R) * @as(u128, R);
	try testing.expectEqual(@as(u64, @intCast(R2 % P)), R2_MOD_P);
	const prod_low32: u64 = (P *% P_NEG_INV) & 0xFFFFFFFF;
	try testing.expectEqual(@as(u64, 0xFFFFFFFF), prod_low32); // P*P_NEG_INV ≡ -1 mod 2^32
}

test "montMul / toMont / fromMont: round-trip and identity" {
	// fromMont(toMont(x)) == x for any x in [0, P).
	const xs = [_]u64{ 0, 1, 2, 12345, 67890, P / 2, P - 2, P - 1 };
	for (xs) |x| {
		try testing.expectEqual(x, fromMont(toMont(x)));
	}
	// toMont(1) == ONE_MOD_P (Montgomery identity).
	try testing.expectEqual(ONE_MOD_P, toMont(1));
	// toMont(0) == 0.
	try testing.expectEqual(@as(u64, 0), toMont(0));
}

test "montMul: equivalent to (a*b)%P after toMont/fromMont wrap on 100K random pairs" {
	var prng = std.Random.DefaultPrng.init(0xCAFE_B0DE);
	const rand = prng.random();
	var i: usize = 0;
	while (i < 100_000) : (i += 1) {
		const a = rand.uintLessThan(u64, P);
		const b = rand.uintLessThan(u64, P);
		const expected = (a * b) % P;
		const got = fromMont(montMul(toMont(a), toMont(b)));
		if (got != expected) {
			std.debug.print("MISMATCH a={d} b={d} expected={d} got={d}\n", .{ a, b, expected, got });
			return error.TestFailed;
		}
	}
}

test "montMul_x2: lane-equivalent to scalar montMul on 100K random pairs (Mont-form inputs)" {
	var prng = std.Random.DefaultPrng.init(0xBEEF_B0DE);
	const rand = prng.random();
	var i: usize = 0;
	while (i < 100_000) : (i += 1) {
		const a0 = rand.uintLessThan(u64, P);
		const a1 = rand.uintLessThan(u64, P);
		const b0 = rand.uintLessThan(u64, P);
		const b1 = rand.uintLessThan(u64, P);
		// Mont-form inputs (any value in [0, P) is also a valid Mont representative).
		const av: @Vector(2, u64) = .{ a0, a1 };
		const bv: @Vector(2, u64) = .{ b0, b1 };
		const got = montMul_x2(av, bv);
		try testing.expectEqual(montMul(a0, b0), got[0]);
		try testing.expectEqual(montMul(a1, b1), got[1]);
	}
}

test "montMul_x2: edge cases (0, 1, P-1, mid)" {
	const corners = [_]struct { a0: u64, a1: u64, b0: u64, b1: u64 }{
		.{ .a0 = 0, .a1 = 0, .b0 = 0, .b1 = 0 },
		.{ .a0 = 1, .a1 = 1, .b0 = 1, .b1 = 1 },
		.{ .a0 = P - 1, .a1 = P - 1, .b0 = P - 1, .b1 = P - 1 },
		.{ .a0 = 0, .a1 = P - 1, .b0 = P - 1, .b1 = 0 },
		.{ .a0 = P / 2, .a1 = 12345, .b0 = P / 3, .b1 = 67890 },
	};
	for (corners) |c| {
		const av: @Vector(2, u64) = .{ c.a0, c.a1 };
		const bv: @Vector(2, u64) = .{ c.b0, c.b1 };
		const got = montMul_x2(av, bv);
		try testing.expectEqual(montMul(c.a0, c.b0), got[0]);
		try testing.expectEqual(montMul(c.a1, c.b1), got[1]);
	}
}

test "nttWithTwiddlesMontVec: matches nttWithTwiddles after Mont conversion across sizes" {
	// Strategy: build normal-form input + scalar twiddles. Run the scalar NTT.
	// Build Mont-form input + Mont-form twiddles. Run nttWithTwiddlesMontVec.
	// Convert vec output back from Mont. Compare to scalar output.
	const sizes = [_]usize{ 2, 4, 8, 16, 64, 256, 1024, 4096, 8192 };
	for (sizes) |n| {
		const a_scalar = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_scalar);
		const a_vec = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_vec);
		const tw = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw);
		const tw_m = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw_m);

		var prng = std.Random.DefaultPrng.init(0xA1B2_C3D4_E5F6_B0DE ^ n);
		const rand = prng.random();
		for (a_scalar) |*x| x.* = rand.uintLessThan(u64, P);
		// Build Mont-form copy of input.
		for (a_vec, a_scalar) |*xm, x| xm.* = toMont(x);

		// Twiddles in normal form (for scalar NTT) and Mont form (for vec NTT).
		const omega_n = nthRootOfUnity(n);
		if (tw.len > 0) {
			tw[0] = 1;
			tw_m[0] = ONE_MOD_P;
		}
		var j: usize = 1;
		while (j < tw.len) : (j += 1) {
			tw[j] = mulModP(tw[j - 1], omega_n);
			tw_m[j] = toMont(tw[j]);
		}

		nttWithTwiddles(a_scalar, tw);
		nttWithTwiddlesMontVec(a_vec, tw_m);

		// Convert vec output back from Mont and compare lanewise.
		for (a_vec, a_scalar) |xm, x_expected| {
			try testing.expectEqual(x_expected, fromMont(xm));
		}
	}
}

test "nttStockhamVecU8: bit-exact match vs nttStockhamVec across sizes" {
	const sizes = [_]usize{ 2, 4, 8, 16, 32, 64, 256, 1024, 4096, 8192 };
	for (sizes) |n| {
		const a_ref = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_ref);
		const sc_ref = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(sc_ref);
		const a_u8 = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_u8);
		const sc_u8 = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(sc_u8);
		const tw = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw);
		var prng = std.Random.DefaultPrng.init(0xBADC0DE_F00D_CAFE ^ n);
		const rand = prng.random();
		for (a_ref) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(a_u8, a_ref);
		const omega_n = nthRootOfUnity(n);
		if (tw.len > 0) tw[0] = 1;
		var j: usize = 1;
		while (j < tw.len) : (j += 1) tw[j] = mulModP(tw[j - 1], omega_n);
		nttStockhamVec(a_ref, sc_ref, tw);
		nttStockhamVecU8(a_u8, sc_u8, tw);
		try testing.expectEqualSlices(u64, a_ref, a_u8);
	}
}

test "nttStockhamVecU4: bit-exact match vs nttStockhamVec across sizes" {
	// U4 must produce IDENTICAL output to the by-2 vec form. Tests the
	// unrolled-by-4 inner loop covers all sizes including small m2.
	const sizes = [_]usize{ 2, 4, 8, 16, 32, 64, 256, 1024, 4096, 8192 };
	for (sizes) |n| {
		const a_ref = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_ref);
		const sc_ref = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(sc_ref);
		const a_u4 = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_u4);
		const sc_u4 = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(sc_u4);
		const tw = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw);
		var prng = std.Random.DefaultPrng.init(0xBADC0DE_FACE_F00D ^ n);
		const rand = prng.random();
		for (a_ref) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(a_u4, a_ref);
		const omega_n = nthRootOfUnity(n);
		if (tw.len > 0) tw[0] = 1;
		var j: usize = 1;
		while (j < tw.len) : (j += 1) tw[j] = mulModP(tw[j - 1], omega_n);
		nttStockhamVec(a_ref, sc_ref, tw);
		nttStockhamVecU4(a_u4, sc_u4, tw);
		try testing.expectEqualSlices(u64, a_ref, a_u4);
	}
}

test "nttStockhamMontVec: matches nttStockham after Mont conversion across sizes" {
	// Mont+Stockham hybrid (M6-4-E.3). Bit-exact equivalent of nttStockham
	// after Mont round-trip. If this passes, the hybrid is safe to wire into
	// mulMagnitudes' production path (with toMont/fromMont at the boundaries).
	const sizes = [_]usize{ 2, 4, 8, 16, 64, 256, 1024, 4096, 8192 };
	for (sizes) |n| {
		const a_scalar = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_scalar);
		const sc_scalar = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(sc_scalar);
		const a_vec = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_vec);
		const sc_vec = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(sc_vec);
		const tw = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw);
		const tw_m = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw_m);

		var prng = std.Random.DefaultPrng.init(0xC0FFEE_FACE_BEEF ^ n);
		const rand = prng.random();
		for (a_scalar) |*x| x.* = rand.uintLessThan(u64, P);
		for (a_vec, a_scalar) |*xm, x| xm.* = toMont(x);

		const omega_n = nthRootOfUnity(n);
		if (tw.len > 0) {
			tw[0] = 1;
			tw_m[0] = ONE_MOD_P;
		}
		var j: usize = 1;
		while (j < tw.len) : (j += 1) {
			tw[j] = mulModP(tw[j - 1], omega_n);
			tw_m[j] = toMont(tw[j]);
		}

		nttStockham(a_scalar, sc_scalar, tw);
		nttStockhamMontVec(a_vec, sc_vec, tw_m);

		for (a_vec, a_scalar) |xm, x_expected| {
			try testing.expectEqual(x_expected, fromMont(xm));
		}
	}
}

// ── M6-4-C Stockham auto-sort NTT tests ────────────────────────────────────

test "nttStockham: bit-exact match vs nttWithTwiddles across sizes" {
	// Stockham must produce IDENTICAL output to Cooley-Tukey for the same
	// input + twiddles. (Both compute the natural-order forward NTT.)
	const sizes = [_]usize{ 2, 4, 8, 16, 32, 64, 256, 1024, 4096, 8192 };
	for (sizes) |n| {
		const a_ref = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_ref);
		const a_st = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_st);
		const scratch = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(scratch);
		const tw = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw);

		var prng = std.Random.DefaultPrng.init(0x5704C7A4 ^ n);
		const rand = prng.random();
		for (a_ref) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(a_st, a_ref);

		// Build forward twiddle table.
		const omega_n = nthRootOfUnity(n);
		if (tw.len > 0) tw[0] = 1;
		var j: usize = 1;
		while (j < tw.len) : (j += 1) tw[j] = mulModP(tw[j - 1], omega_n);

		nttWithTwiddles(a_ref, tw);
		nttStockham(a_st, scratch, tw);

		try testing.expectEqualSlices(u64, a_ref, a_st);
	}
}

test "nttStockhamVec: bit-exact match vs nttWithTwiddlesVec across sizes" {
	const sizes = [_]usize{ 2, 4, 8, 16, 32, 64, 256, 1024, 4096, 8192 };
	for (sizes) |n| {
		const a_ref = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_ref);
		const a_st = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_st);
		const scratch = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(scratch);
		const tw = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw);

		var prng = std.Random.DefaultPrng.init(0x57C7A4_BEEF ^ n);
		const rand = prng.random();
		for (a_ref) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(a_st, a_ref);

		const omega_n = nthRootOfUnity(n);
		if (tw.len > 0) tw[0] = 1;
		var j: usize = 1;
		while (j < tw.len) : (j += 1) tw[j] = mulModP(tw[j - 1], omega_n);

		nttWithTwiddlesVec(a_ref, tw);
		nttStockhamVec(a_st, scratch, tw);

		try testing.expectEqualSlices(u64, a_ref, a_st);
	}
}

test "nttStockham[Vec]: round-trip with inverse equals identity" {
	const sizes = [_]usize{ 2, 4, 16, 256, 1024, 4096 };
	for (sizes) |n| {
		const a = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a);
		const a_v = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_v);
		const orig = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(orig);
		const scratch = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(scratch);
		const tw_fwd = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw_fwd);
		const tw_inv = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw_inv);

		var prng = std.Random.DefaultPrng.init(0xCAFE_57C7 ^ n);
		const rand = prng.random();
		for (a) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(orig, a);
		@memcpy(a_v, a);

		const omega_n = nthRootOfUnity(n);
		const omega_n_inv = invModP(omega_n);
		tw_fwd[0] = 1;
		tw_inv[0] = 1;
		var j: usize = 1;
		while (j < n / 2) : (j += 1) {
			tw_fwd[j] = mulModP(tw_fwd[j - 1], omega_n);
			tw_inv[j] = mulModP(tw_inv[j - 1], omega_n_inv);
		}

		// Scalar Stockham round-trip.
		nttStockham(a, scratch, tw_fwd);
		nttStockham(a, scratch, tw_inv);
		const n_inv = invModP(@intCast(n));
		for (a) |*x| x.* = mulModP(x.*, n_inv);
		try testing.expectEqualSlices(u64, orig, a);

		// Vec Stockham round-trip.
		nttStockhamVec(a_v, scratch, tw_fwd);
		nttStockhamVec(a_v, scratch, tw_inv);
		for (a_v) |*x| x.* = mulModP(x.*, n_inv);
		try testing.expectEqualSlices(u64, orig, a_v);
	}
}

test "nttStockham convolution theorem: invStockham(stockham(a) * stockham(b)) = a ⊛ b" {
	const a_in = [_]u64{ 3, 1, 4, 1, 5, 9, 2, 6 };
	const b_in = [_]u64{ 2, 7, 1, 8, 2, 8, 1, 8 };
	const M = a_in.len + b_in.len; // 16

	var a = [_]u64{0} ** M;
	var b = [_]u64{0} ** M;
	var scratch = [_]u64{0} ** M;
	for (a_in, 0..) |v, i| a[i] = v;
	for (b_in, 0..) |v, i| b[i] = v;

	// Build twiddles.
	var tw_fwd: [M / 2]u64 = undefined;
	var tw_inv: [M / 2]u64 = undefined;
	const omega = nthRootOfUnity(M);
	const omega_inv = invModP(omega);
	tw_fwd[0] = 1;
	tw_inv[0] = 1;
	var j: usize = 1;
	while (j < M / 2) : (j += 1) {
		tw_fwd[j] = mulModP(tw_fwd[j - 1], omega);
		tw_inv[j] = mulModP(tw_inv[j - 1], omega_inv);
	}

	nttStockham(&a, &scratch, &tw_fwd);
	nttStockham(&b, &scratch, &tw_fwd);
	var c: [M]u64 = undefined;
	for (0..M) |i| c[i] = mulModP(a[i], b[i]);
	nttStockham(&c, &scratch, &tw_inv);
	const n_inv = invModP(@intCast(M));
	for (&c) |*x| x.* = mulModP(x.*, n_inv);

	// Schoolbook reference.
	var ref = [_]u64{0} ** M;
	for (a_in, 0..) |av, i| {
		for (b_in, 0..) |bv, k| {
			ref[i + k] += av * bv;
		}
	}
	for (0..M) |i| try testing.expectEqual(ref[i], c[i]);
}

// ── Radix-4 NTT tests (M6-4-D) ──────────────────────────────────────────────

test "nttRadix4Vec: bit-exact match vs nttWithTwiddlesVec across pure-radix-4 sizes" {
	// Pure radix-4 (log2(N) even): no initial radix-2 stage needed.
	const sizes = [_]usize{ 4, 16, 64, 256, 1024, 4096 };
	for (sizes) |n| {
		const a_ref = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_ref);
		const a_r4 = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_r4);
		const tw = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw);

		var prng = std.Random.DefaultPrng.init(0xAAAA_BBBB_CCCC ^ n);
		const rand = prng.random();
		for (a_ref) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(a_r4, a_ref);

		const omega_n = nthRootOfUnity(n);
		if (tw.len > 0) tw[0] = 1;
		var j: usize = 1;
		while (j < tw.len) : (j += 1) tw[j] = mulModP(tw[j - 1], omega_n);

		nttWithTwiddlesVec(a_ref, tw);
		nttRadix4Vec(a_r4, tw);

		try testing.expectEqualSlices(u64, a_ref, a_r4);
	}
}

test "nttRadix4Vec: bit-exact match vs nttWithTwiddlesVec across mixed-radix sizes" {
	// log2(N) odd → mixed radix: one initial radix-2 + log4(N/2) radix-4 passes.
	const sizes = [_]usize{ 2, 8, 32, 128, 512, 2048, 8192 };
	for (sizes) |n| {
		const a_ref = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_ref);
		const a_r4 = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a_r4);
		const tw = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw);

		var prng = std.Random.DefaultPrng.init(0xCCCC_DDDD_EEEE ^ n);
		const rand = prng.random();
		for (a_ref) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(a_r4, a_ref);

		const omega_n = nthRootOfUnity(n);
		if (tw.len > 0) tw[0] = 1;
		var j: usize = 1;
		while (j < tw.len) : (j += 1) tw[j] = mulModP(tw[j - 1], omega_n);

		nttWithTwiddlesVec(a_ref, tw);
		nttRadix4Vec(a_r4, tw);

		try testing.expectEqualSlices(u64, a_ref, a_r4);
	}
}

test "nttRadix4Vec: round-trip with inverse equals identity" {
	const sizes = [_]usize{ 4, 8, 16, 64, 256, 1024, 2048, 4096, 8192 };
	for (sizes) |n| {
		const a = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(a);
		const orig = try testing.allocator.alloc(u64, n);
		defer testing.allocator.free(orig);
		const tw_fwd = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw_fwd);
		const tw_inv = try testing.allocator.alloc(u64, n / 2);
		defer testing.allocator.free(tw_inv);

		var prng = std.Random.DefaultPrng.init(0xEEEE_FFFF_1111 ^ n);
		const rand = prng.random();
		for (a) |*x| x.* = rand.uintLessThan(u64, P);
		@memcpy(orig, a);

		const omega_n = nthRootOfUnity(n);
		const omega_n_inv = invModP(omega_n);
		tw_fwd[0] = 1;
		tw_inv[0] = 1;
		var j: usize = 1;
		while (j < n / 2) : (j += 1) {
			tw_fwd[j] = mulModP(tw_fwd[j - 1], omega_n);
			tw_inv[j] = mulModP(tw_inv[j - 1], omega_n_inv);
		}

		nttRadix4Vec(a, tw_fwd);
		nttRadix4Vec(a, tw_inv);
		const n_inv = invModP(@intCast(n));
		for (a) |*x| x.* = mulModP(x.*, n_inv);

		try testing.expectEqualSlices(u64, orig, a);
	}
}

test "nttRadix4Vec convolution theorem: invR4(R4(a) * R4(b)) = a ⊛ b" {
	const a_in = [_]u64{ 3, 1, 4, 1, 5, 9, 2, 6 };
	const b_in = [_]u64{ 2, 7, 1, 8, 2, 8, 1, 8 };
	const M = a_in.len + b_in.len; // 16, log2=4 (pure radix-4)

	var a = [_]u64{0} ** M;
	var b = [_]u64{0} ** M;
	for (a_in, 0..) |v, i| a[i] = v;
	for (b_in, 0..) |v, i| b[i] = v;

	var tw_fwd: [M / 2]u64 = undefined;
	var tw_inv: [M / 2]u64 = undefined;
	const omega = nthRootOfUnity(M);
	const omega_inv = invModP(omega);
	tw_fwd[0] = 1;
	tw_inv[0] = 1;
	var j: usize = 1;
	while (j < M / 2) : (j += 1) {
		tw_fwd[j] = mulModP(tw_fwd[j - 1], omega);
		tw_inv[j] = mulModP(tw_inv[j - 1], omega_inv);
	}

	nttRadix4Vec(&a, &tw_fwd);
	nttRadix4Vec(&b, &tw_fwd);
	var c: [M]u64 = undefined;
	for (0..M) |i| c[i] = mulModP(a[i], b[i]);
	nttRadix4Vec(&c, &tw_inv);
	const n_inv = invModP(@intCast(M));
	for (&c) |*x| x.* = mulModP(x.*, n_inv);

	// Schoolbook reference.
	var ref = [_]u64{0} ** M;
	for (a_in, 0..) |av, i| {
		for (b_in, 0..) |bv, k| {
			ref[i + k] += av * bv;
		}
	}
	for (0..M) |i| try testing.expectEqual(ref[i], c[i]);
}
