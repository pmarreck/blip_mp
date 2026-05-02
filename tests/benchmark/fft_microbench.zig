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

	std.debug.print("\n--- speedup vs scalar (>1.0 = SIMD wins) ---\n", .{});
	std.debug.print("addModP: {d:.2}x\n", .{ns_add / (ns_add_x2 / 2.0)});
	std.debug.print("subModP: {d:.2}x\n", .{ns_sub / (ns_sub_x2 / 2.0)});
	std.debug.print("mulModP: {d:.2}x\n", .{ns_mul / (ns_mul_x2 / 2.0)});
}
