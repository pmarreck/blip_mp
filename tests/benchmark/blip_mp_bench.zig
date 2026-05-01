// Tier-0/1 add throughput benchmark for blip_mp.
//
// Workload: pre-build a pool of small Mp values, then time N iterations of
//   result.add(&pool[i % POOL_SIZE], &pool[(i+1) % POOL_SIZE])
//
// Multiple value-size buckets exercised: immediate (L=0), L=1, L=2, L=3.
// Output: machine-readable summary lines (one per bucket) prefixed with "RESULT".
//
// Build (ReleaseFast is the default per build.zig):
//   nix develop -c zig build bench
// Or directly run after building:
//   ./zig-out/bin/blip_mp_bench

const std = @import("std");
const blip_mp = @import("blip_mp");
const Mp = blip_mp.Mp;

// Monotonic timing — std.time.Timer was removed in Zig 0.16 and the
// replacement (std.Io.Clock.now) requires an Io instance we'd otherwise
// not need. We're already linking libc for std.heap.c_allocator, so we
// just call clock_gettime directly.
const TimeSpec = extern struct { tv_sec: c_long, tv_nsec: c_long };
extern "c" fn clock_gettime(clk_id: c_int, tp: *TimeSpec) c_int;

fn nowNs() u64 {
	var ts: TimeSpec = undefined;
	_ = clock_gettime(@intFromEnum(std.posix.CLOCK.MONOTONIC), &ts);
	return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

const POOL_SIZE: usize = 256;
const ITERATIONS: usize = 5_000_000;

const Bucket = struct {
	name: []const u8,
	min: i64,
	max: i64,
};

const BUCKETS = [_]Bucket{
	.{ .name = "immediate (0..127)", .min = 1, .max = 127 },
	.{ .name = "L=1 (128..255)", .min = 128, .max = 255 },
	.{ .name = "L=2 (256..32767)", .min = 1000, .max = 32000 },
	.{ .name = "L=3 (32768..8M)", .min = 100_000, .max = 8_000_000 },
	.{ .name = "L=4 (>8M..2G)", .min = 10_000_000, .max = 1_000_000_000 },
};

pub fn main() !void {
	if (comptime @import("builtin").mode == .Debug) {
		std.debug.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
	}

	// libc malloc — apples-to-apples with GMP's default allocator.
	const allocator = std.heap.c_allocator;

	std.debug.print("=== blip_mp tier-0/1 add benchmark ===\n", .{});
	std.debug.print("pool_size={d} iterations={d}\n\n", .{ POOL_SIZE, ITERATIONS });

	for (BUCKETS) |bucket| {
		const ns_mp = try benchmarkMpAdd(allocator, bucket);
		std.debug.print("RESULT impl=Mp.add bucket={s} ns_per_op={d:.2}\n", .{ bucket.name, ns_mp });
		const ns_raw = try benchmarkRawAdd(allocator, bucket);
		std.debug.print("RESULT impl=raw bucket={s} ns_per_op={d:.2}\n", .{ bucket.name, ns_raw });
	}
}

// Measures the current Mp.add with per-call alloc/free.
fn benchmarkMpAdd(allocator: std.mem.Allocator, bucket: Bucket) !f64 {
	// Build a pool of POOL_SIZE values evenly spaced in [bucket.min, bucket.max].
	var pool: [POOL_SIZE]Mp = undefined;
	for (&pool, 0..) |*slot, i| {
		slot.* = Mp.init(allocator);
		const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(POOL_SIZE - 1));
		const span: f64 = @floatFromInt(bucket.max - bucket.min);
		const v: i64 = bucket.min + @as(i64, @intFromFloat(t * span));
		try slot.setI64(v);
	}
	defer for (&pool) |*slot| slot.deinit();

	var result = Mp.init(allocator);
	defer result.deinit();

	const start_ns = nowNs();
	var i: usize = 0;
	while (i < ITERATIONS) : (i += 1) {
		const a = &pool[i & (POOL_SIZE - 1)];
		const b = &pool[(i + 1) & (POOL_SIZE - 1)];
		try result.add(a, b);
	}
	const elapsed_ns = nowNs() - start_ns;

	// Sanity: prevent the optimizer from eliding the loop entirely.
	std.mem.doNotOptimizeAway(result.bytes().ptr);

	return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS));
}

// Zero-alloc tier-0/1 add: decode both operands, native i64 add, encode into
// a stack buffer. This is what an SBO Mp would do internally for L<=8 values.
// Measures the THEORETICAL upper bound of blip_mp tier-0/1 throughput once
// the heap allocation is removed from the hot path.
fn benchmarkRawAdd(allocator: std.mem.Allocator, bucket: Bucket) !f64 {
	const enc = blip_mp.encoding;

	// Same pool layout as benchmarkMpAdd, but we only need the encoded bytes —
	// not full Mp structs. Using Mp.bytes here for a clean comparison.
	var pool: [POOL_SIZE]Mp = undefined;
	for (&pool, 0..) |*slot, i| {
		slot.* = Mp.init(allocator);
		const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(POOL_SIZE - 1));
		const span: f64 = @floatFromInt(bucket.max - bucket.min);
		const v: i64 = bucket.min + @as(i64, @intFromFloat(t * span));
		try slot.setI64(v);
	}
	defer for (&pool) |*slot| slot.deinit();

	var out_buf: [16]u8 = undefined; // i64 max encoded size = 9; 16 is safe
	var written: usize = 0;

	const start_ns = nowNs();
	var i: usize = 0;
	while (i < ITERATIONS) : (i += 1) {
		const a_bytes = pool[i & (POOL_SIZE - 1)].bytes();
		const b_bytes = pool[(i + 1) & (POOL_SIZE - 1)].bytes();
		const a_dec = try enc.decodeI64(a_bytes);
		const b_dec = try enc.decodeI64(b_bytes);
		const ov = @addWithOverflow(a_dec.value, b_dec.value);
		if (ov[1] != 0) return error.TierOverflow;
		written = try enc.encodeI64Canonical(&out_buf, ov[0]);
	}
	const elapsed_ns = nowNs() - start_ns;

	std.mem.doNotOptimizeAway(&out_buf);
	std.mem.doNotOptimizeAway(&written);

	return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS));
}
