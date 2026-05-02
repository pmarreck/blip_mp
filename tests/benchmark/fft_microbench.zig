// FFT inner-loop microbench: isolate per-call cost of mulModP / addModP /
// subModP (and their @Vector(2, u64) SIMD counterparts) with no FFT setup,
// no allocation, no cache effects beyond a tiny input pool.
//
// Inputs are read from a 256-element pool seeded by a deterministic PRNG so
// the compiler can't precompute results. Outputs are folded back into the
// pool and the final XOR is fed to std.mem.doNotOptimizeAway, preventing
// dead-code elimination of the entire loop body.
//
// Build (ReleaseFast is the default):
//   nix build .#packages.aarch64-darwin.bench
//   ./result/bin/fft_microbench
//
// Output format (one line per impl):
//   RESULT impl=<name> ns_per_op=<float>

const std = @import("std");
const fft = @import("blip_mp").fft;

// Monotonic timing — std.time.Timer was removed in Zig 0.16. Use libc
// clock_gettime directly (we already link libc for c_allocator parity).
const TimeSpec = extern struct { tv_sec: c_long, tv_nsec: c_long };
extern "c" fn clock_gettime(clk_id: c_int, tp: *TimeSpec) c_int;

fn nowNs() u64 {
	var ts: TimeSpec = undefined;
	_ = clock_gettime(@intFromEnum(std.posix.CLOCK.MONOTONIC), &ts);
	return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

const POOL_SIZE: usize = 256;
const ITERS: usize = 10_000_000;

// Build a deterministic pool of inputs in [0, P).
fn buildPool(seed: u64) [POOL_SIZE]u64 {
	var pool: [POOL_SIZE]u64 = undefined;
	var prng = std.Random.DefaultPrng.init(seed);
	const r = prng.random();
	for (&pool) |*x| x.* = r.uintLessThan(u64, fft.P);
	return pool;
}

fn buildPoolVec(seed: u64) [POOL_SIZE]@Vector(2, u64) {
	var pool: [POOL_SIZE]@Vector(2, u64) = undefined;
	var prng = std.Random.DefaultPrng.init(seed);
	const r = prng.random();
	for (&pool) |*x| {
		const a = r.uintLessThan(u64, fft.P);
		const b = r.uintLessThan(u64, fft.P);
		x.* = .{ a, b };
	}
	return pool;
}

// ── Scalar benches ──────────────────────────────────────────────────────────
//
// Loop discipline: indices are pure functions of `i` (not the result), so the
// CPU can overlap iterations — this measures *throughput*, not latency. The
// XOR fold into `acc` and the doNotOptimizeAway after the loop together
// prevent the compiler from removing the work; `acc` doesn't gate the next
// iteration's input fetches.

fn benchAddModP(pool_a: *const [POOL_SIZE]u64, pool_b: *const [POOL_SIZE]u64) f64 {
	var acc: u64 = 0;
	const start = nowNs();
	var i: usize = 0;
	while (i < ITERS) : (i += 1) {
		const a = pool_a[i & (POOL_SIZE - 1)];
		const b = pool_b[(i *% 2654435761) & (POOL_SIZE - 1)];
		acc ^= fft.addModP(a, b);
	}
	const elapsed = nowNs() - start;
	std.mem.doNotOptimizeAway(&acc);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERS));
}

fn benchSubModP(pool_a: *const [POOL_SIZE]u64, pool_b: *const [POOL_SIZE]u64) f64 {
	var acc: u64 = 0;
	const start = nowNs();
	var i: usize = 0;
	while (i < ITERS) : (i += 1) {
		const a = pool_a[i & (POOL_SIZE - 1)];
		const b = pool_b[(i *% 2654435761) & (POOL_SIZE - 1)];
		acc ^= fft.subModP(a, b);
	}
	const elapsed = nowNs() - start;
	std.mem.doNotOptimizeAway(&acc);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERS));
}

fn benchMulModP(pool_a: *const [POOL_SIZE]u64, pool_b: *const [POOL_SIZE]u64) f64 {
	var acc: u64 = 0;
	const start = nowNs();
	var i: usize = 0;
	while (i < ITERS) : (i += 1) {
		const a = pool_a[i & (POOL_SIZE - 1)];
		const b = pool_b[(i *% 2654435761) & (POOL_SIZE - 1)];
		acc ^= fft.mulModP(a, b);
	}
	const elapsed = nowNs() - start;
	std.mem.doNotOptimizeAway(&acc);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERS));
}

// ── Vector (2-lane) benches ─────────────────────────────────────────────────
//
// Each iteration processes 2 scalar-equivalent operations, so the natural
// reporting unit is "ns per vector op". We also print "ns per scalar-equiv"
// (= ns_per_vec_op / 2) so it lines up against scalar numbers.

fn benchAddModP_x2(pool_a: *const [POOL_SIZE]@Vector(2, u64), pool_b: *const [POOL_SIZE]@Vector(2, u64)) f64 {
	var acc: @Vector(2, u64) = .{ 0, 0 };
	const start = nowNs();
	var i: usize = 0;
	while (i < ITERS) : (i += 1) {
		const a = pool_a[i & (POOL_SIZE - 1)];
		const b = pool_b[(i *% 2654435761) & (POOL_SIZE - 1)];
		acc ^= fft.addModP_x2(a, b);
	}
	const elapsed = nowNs() - start;
	std.mem.doNotOptimizeAway(&acc);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERS));
}

fn benchSubModP_x2(pool_a: *const [POOL_SIZE]@Vector(2, u64), pool_b: *const [POOL_SIZE]@Vector(2, u64)) f64 {
	var acc: @Vector(2, u64) = .{ 0, 0 };
	const start = nowNs();
	var i: usize = 0;
	while (i < ITERS) : (i += 1) {
		const a = pool_a[i & (POOL_SIZE - 1)];
		const b = pool_b[(i *% 2654435761) & (POOL_SIZE - 1)];
		acc ^= fft.subModP_x2(a, b);
	}
	const elapsed = nowNs() - start;
	std.mem.doNotOptimizeAway(&acc);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERS));
}

fn benchMulModP_x2(pool_a: *const [POOL_SIZE]@Vector(2, u64), pool_b: *const [POOL_SIZE]@Vector(2, u64)) f64 {
	var acc: @Vector(2, u64) = .{ 0, 0 };
	const start = nowNs();
	var i: usize = 0;
	while (i < ITERS) : (i += 1) {
		const a = pool_a[i & (POOL_SIZE - 1)];
		const b = pool_b[(i *% 2654435761) & (POOL_SIZE - 1)];
		acc ^= fft.mulModP_x2(a, b);
	}
	const elapsed = nowNs() - start;
	std.mem.doNotOptimizeAway(&acc);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERS));
}

// Scalar Montgomery (mont form inputs/outputs).
fn benchMontMul(pool_a: *const [POOL_SIZE]u64, pool_b: *const [POOL_SIZE]u64) f64 {
	var acc: u64 = 0;
	const start = nowNs();
	var i: usize = 0;
	while (i < ITERS) : (i += 1) {
		const a = pool_a[i & (POOL_SIZE - 1)];
		const b = pool_b[(i *% 2654435761) & (POOL_SIZE - 1)];
		acc ^= fft.montMul(a, b);
	}
	const elapsed = nowNs() - start;
	std.mem.doNotOptimizeAway(&acc);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERS));
}

// Vector Montgomery — the M6-4-A.6 / M6-4-B replacement for mulModP_x2 in
// the FFT inner loop. Inputs/outputs are Mont-form residues in [0, P).
fn benchMontMul_x2(pool_a: *const [POOL_SIZE]@Vector(2, u64), pool_b: *const [POOL_SIZE]@Vector(2, u64)) f64 {
	var acc: @Vector(2, u64) = .{ 0, 0 };
	const start = nowNs();
	var i: usize = 0;
	while (i < ITERS) : (i += 1) {
		const a = pool_a[i & (POOL_SIZE - 1)];
		const b = pool_b[(i *% 2654435761) & (POOL_SIZE - 1)];
		acc ^= fft.montMul_x2(a, b);
	}
	const elapsed = nowNs() - start;
	std.mem.doNotOptimizeAway(&acc);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERS));
}

// ── Full-NTT microbench (M6-4-A.4) ──────────────────────────────────────────
//
// Times one in-place NTT pass at N=8192 for both the scalar and vectorized
// implementations. We do NOT include twiddle-table setup or input refresh in
// the timed window — but we DO restore the input buffer between iterations
// (the NTT is destructive). Every iteration runs on the same data so caches
// stay hot; the goal is to compare the two inner-loop implementations under
// identical conditions, not to model end-to-end multiply cost.

const NTT_N: usize = 8192;
const NTT_ITERS: usize = 200;

fn benchNttScalar(orig: *const [NTT_N]u64, work: *[NTT_N]u64, tw: *const [NTT_N / 2]u64) f64 {
	var elapsed: u64 = 0;
	var i: usize = 0;
	while (i < NTT_ITERS) : (i += 1) {
		@memcpy(work, orig);
		const t0 = nowNs();
		fft.nttWithTwiddles(work, tw);
		elapsed += nowNs() - t0;
	}
	std.mem.doNotOptimizeAway(work);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(NTT_ITERS));
}

fn benchNttVec(orig: *const [NTT_N]u64, work: *[NTT_N]u64, tw: *const [NTT_N / 2]u64) f64 {
	var elapsed: u64 = 0;
	var i: usize = 0;
	while (i < NTT_ITERS) : (i += 1) {
		@memcpy(work, orig);
		const t0 = nowNs();
		fft.nttWithTwiddlesVec(work, tw);
		elapsed += nowNs() - t0;
	}
	std.mem.doNotOptimizeAway(work);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(NTT_ITERS));
}

// Mont-form NTT: orig and tw_m must be in Mont form before the call.
fn benchNttMontVec(orig_m: *const [NTT_N]u64, work: *[NTT_N]u64, tw_m: *const [NTT_N / 2]u64) f64 {
	var elapsed: u64 = 0;
	var i: usize = 0;
	while (i < NTT_ITERS) : (i += 1) {
		@memcpy(work, orig_m);
		const t0 = nowNs();
		fft.nttWithTwiddlesMontVec(work, tw_m);
		elapsed += nowNs() - t0;
	}
	std.mem.doNotOptimizeAway(work);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(NTT_ITERS));
}

// Stockham auto-sort vec NTT — needs scratch ping-pong buffer.
fn benchNttStockhamVec(orig: *const [NTT_N]u64, work: *[NTT_N]u64, scratch: *[NTT_N]u64, tw: *const [NTT_N / 2]u64) f64 {
	var elapsed: u64 = 0;
	var i: usize = 0;
	while (i < NTT_ITERS) : (i += 1) {
		@memcpy(work, orig);
		const t0 = nowNs();
		fft.nttStockhamVec(work, scratch, tw);
		elapsed += nowNs() - t0;
	}
	std.mem.doNotOptimizeAway(work);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(NTT_ITERS));
}

// Radix-4 NTT (M6-4-D): mixed-radix at N=8192 (one initial radix-2 pass +
// 6 radix-4 passes). Same in-place, bit-reversal-based call shape as
// nttWithTwiddlesVec.
fn benchNttRadix4Vec(orig: *const [NTT_N]u64, work: *[NTT_N]u64, tw: *const [NTT_N / 2]u64) f64 {
	var elapsed: u64 = 0;
	var i: usize = 0;
	while (i < NTT_ITERS) : (i += 1) {
		@memcpy(work, orig);
		const t0 = nowNs();
		fft.nttRadix4Vec(work, tw);
		elapsed += nowNs() - t0;
	}
	std.mem.doNotOptimizeAway(work);
	return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(NTT_ITERS));
}

pub fn main() !void {
	if (comptime @import("builtin").mode == .Debug) {
		std.debug.print("\x1b[33mDEBUG BUILD — bench numbers will be meaningless!\x1b[0m\n", .{});
	}

	// Scalar pools
	const pool_a = buildPool(0xCAFE_BABE);
	const pool_b = buildPool(0x1337_BEEF);
	// Vector pools (independent seeds so lane data is uncorrelated with scalars)
	const vpool_a = buildPoolVec(0xDEAD_F00D);
	const vpool_b = buildPoolVec(0xFEED_C0DE);

	std.debug.print("=== fft_microbench (iters={d}) ===\n\n", .{ITERS});

	// Warm-up pass to avoid first-iter cache miss skewing the small-ns
	// scalar benches.
	_ = benchAddModP(&pool_a, &pool_b);

	const ns_add = benchAddModP(&pool_a, &pool_b);
	std.debug.print("RESULT impl=addModP_scalar ns_per_op={d:.3}\n", .{ns_add});

	const ns_sub = benchSubModP(&pool_a, &pool_b);
	std.debug.print("RESULT impl=subModP_scalar ns_per_op={d:.3}\n", .{ns_sub});

	const ns_mul = benchMulModP(&pool_a, &pool_b);
	std.debug.print("RESULT impl=mulModP_scalar ns_per_op={d:.3}\n", .{ns_mul});

	std.debug.print("\n--- vector x2 (ns_per_vec_op | ns_per_scalar_equiv) ---\n", .{});

	const ns_add_x2 = benchAddModP_x2(&vpool_a, &vpool_b);
	std.debug.print("RESULT impl=addModP_x2 ns_per_op={d:.3} ns_per_scalar_equiv={d:.3}\n", .{ ns_add_x2, ns_add_x2 / 2.0 });

	const ns_sub_x2 = benchSubModP_x2(&vpool_a, &vpool_b);
	std.debug.print("RESULT impl=subModP_x2 ns_per_op={d:.3} ns_per_scalar_equiv={d:.3}\n", .{ ns_sub_x2, ns_sub_x2 / 2.0 });

	const ns_mul_x2 = benchMulModP_x2(&vpool_a, &vpool_b);
	std.debug.print("RESULT impl=mulModP_x2 ns_per_op={d:.3} ns_per_scalar_equiv={d:.3}\n", .{ ns_mul_x2, ns_mul_x2 / 2.0 });

	const ns_mont_scalar = benchMontMul(&pool_a, &pool_b);
	std.debug.print("RESULT impl=montMul_scalar ns_per_op={d:.3}\n", .{ns_mont_scalar});

	const ns_mont_x2 = benchMontMul_x2(&vpool_a, &vpool_b);
	std.debug.print("RESULT impl=montMul_x2 ns_per_op={d:.3} ns_per_scalar_equiv={d:.3}\n", .{ ns_mont_x2, ns_mont_x2 / 2.0 });

	std.debug.print("\n--- speedup vs scalar (>1.0 = SIMD wins) ---\n", .{});
	std.debug.print("addModP: {d:.2}x\n", .{ns_add / (ns_add_x2 / 2.0)});
	std.debug.print("subModP: {d:.2}x\n", .{ns_sub / (ns_sub_x2 / 2.0)});
	std.debug.print("mulModP: {d:.2}x\n", .{ns_mul / (ns_mul_x2 / 2.0)});
	std.debug.print("montMul: {d:.2}x (vec vs scalar Mont)\n", .{ns_mont_scalar / (ns_mont_x2 / 2.0)});
	std.debug.print("mulModP_x2 vs montMul_x2 (lower is better): scalar%P_vec={d:.3} mont_vec={d:.3}\n", .{ ns_mul_x2, ns_mont_x2 });

	// ── Full NTT bench at N=8192 ─────────────────────────────────────────
	std.debug.print("\n--- full NTT pass at N={d} (iters={d}) ---\n", .{ NTT_N, NTT_ITERS });

	var orig: [NTT_N]u64 = undefined;
	var prng = std.Random.DefaultPrng.init(0xCAFE_F00D_BEEF_BABE);
	const r = prng.random();
	for (&orig) |*x| x.* = r.uintLessThan(u64, fft.P);

	var tw: [NTT_N / 2]u64 = undefined;
	const omega_n = fft.nthRootOfUnity(NTT_N);
	tw[0] = 1;
	{
		var j: usize = 1;
		while (j < NTT_N / 2) : (j += 1) tw[j] = fft.mulModP(tw[j - 1], omega_n);
	}

	var work: [NTT_N]u64 = undefined;

	// Warm-up pass (cache prime, branch predictor warm).
	_ = benchNttScalar(&orig, &work, &tw);

	const ns_ntt_scalar = benchNttScalar(&orig, &work, &tw);
	std.debug.print("RESULT impl=nttWithTwiddles_scalar n={d} ns_per_pass={d:.0}\n", .{ NTT_N, ns_ntt_scalar });

	const ns_ntt_vec = benchNttVec(&orig, &work, &tw);
	std.debug.print("RESULT impl=nttWithTwiddlesVec n={d} ns_per_pass={d:.0}\n", .{ NTT_N, ns_ntt_vec });

	std.debug.print("NTT speedup (vec vs scalar): {d:.2}x\n", .{ns_ntt_scalar / ns_ntt_vec});

	// Mont-form NTT: orig_m + tw_m built from `orig` and `tw` via toMont.
	var orig_m: [NTT_N]u64 = undefined;
	var tw_m: [NTT_N / 2]u64 = undefined;
	for (orig_m[0..], orig[0..]) |*xm, x| xm.* = fft.toMont(x);
	for (tw_m[0..], tw[0..]) |*xm, x| xm.* = fft.toMont(x);

	_ = benchNttMontVec(&orig_m, &work, &tw_m); // warm-up
	const ns_ntt_mont_vec = benchNttMontVec(&orig_m, &work, &tw_m);
	std.debug.print("RESULT impl=nttWithTwiddlesMontVec n={d} ns_per_pass={d:.0}\n", .{ NTT_N, ns_ntt_mont_vec });
	std.debug.print("Mont NTT speedup (mont_vec vs scalar): {d:.2}x\n", .{ns_ntt_scalar / ns_ntt_mont_vec});
	std.debug.print("Mont NTT speedup (mont_vec vs %P_vec): {d:.2}x\n", .{ns_ntt_vec / ns_ntt_mont_vec});

	// Stockham auto-sort vec NTT — eliminates the bit-reversal pass at the
	// cost of a second N-element buffer for ping-ponging.
	var st_scratch: [NTT_N]u64 = undefined;
	_ = benchNttStockhamVec(&orig, &work, &st_scratch, &tw); // warm-up
	const ns_ntt_stockham_vec = benchNttStockhamVec(&orig, &work, &st_scratch, &tw);
	std.debug.print("RESULT impl=nttStockhamVec n={d} ns_per_pass={d:.0}\n", .{ NTT_N, ns_ntt_stockham_vec });
	std.debug.print("Stockham vs Cooley-Tukey vec ({d}x) — lower is better\n", .{1});
	std.debug.print("Stockham NTT speedup (stockham_vec vs %P_vec): {d:.2}x\n", .{ns_ntt_vec / ns_ntt_stockham_vec});
	std.debug.print("Stockham NTT speedup (stockham_vec vs scalar): {d:.2}x\n", .{ns_ntt_scalar / ns_ntt_stockham_vec});

	// Radix-4 mixed-radix vec NTT (M6-4-D): same call shape as
	// nttWithTwiddlesVec; in-place, bit-reversal-based, fused two-stage radix-2.
	_ = benchNttRadix4Vec(&orig, &work, &tw); // warm-up
	const ns_ntt_r4_vec = benchNttRadix4Vec(&orig, &work, &tw);
	std.debug.print("RESULT impl=nttRadix4Vec n={d} ns_per_pass={d:.0}\n", .{ NTT_N, ns_ntt_r4_vec });
	std.debug.print("Radix-4 NTT speedup (r4_vec vs %P_vec): {d:.2}x\n", .{ns_ntt_vec / ns_ntt_r4_vec});
	std.debug.print("Radix-4 NTT speedup (r4_vec vs scalar): {d:.2}x\n", .{ns_ntt_scalar / ns_ntt_r4_vec});
}
