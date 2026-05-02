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
const ITERATIONS_SMALL: usize = 5_000_000;
const ITERATIONS_LARGE: usize = 500_000; // big values: 10x fewer iterations

const Bucket = struct {
	name: []const u8,
	min: i64,
	max: i64,
};

const BUCKETS = [_]Bucket{
	.{ .name = "L=0 (immediate, 0..127)", .min = 1, .max = 127 },
	.{ .name = "L=2 (128..32K)", .min = 128, .max = 32000 },
	.{ .name = "L=3 (~16-bit..~24-bit)", .min = 100_000, .max = 8_000_000 },
	.{ .name = "L=4 (~32-bit)", .min = 10_000_000, .max = 1_000_000_000 },
};

// Large-value buckets: random-ish bit patterns of fixed width. Sweep across
// the spectrum from 128-bit (just past the inline boundary) to 32768-bit
// (paranoid RSA). The 128/192-bit cases test the inline-but-tier-3 path
// (encoded value still fits in INLINE_CAP=24 bytes); larger sizes go to heap.
const LargeBucket = struct {
	name: []const u8,
	bits: usize, // bit-width of the value
};

const LARGE_BUCKETS = [_]LargeBucket{
	.{ .name = "128-bit",   .bits = 128 },
	.{ .name = "192-bit",   .bits = 192 },
	.{ .name = "256-bit",   .bits = 256 },
	.{ .name = "384-bit",   .bits = 384 },
	.{ .name = "512-bit",   .bits = 512 },
	.{ .name = "768-bit",   .bits = 768 },
	.{ .name = "1024-bit",  .bits = 1024 },
	.{ .name = "1536-bit",  .bits = 1536 },
	.{ .name = "2048-bit",  .bits = 2048 },
	.{ .name = "3072-bit",  .bits = 3072 },
	.{ .name = "4096-bit",  .bits = 4096 },
	.{ .name = "6144-bit",  .bits = 6144 },
	.{ .name = "8192-bit",  .bits = 8192 },
	.{ .name = "16384-bit", .bits = 16384 },
	.{ .name = "32768-bit", .bits = 32768 },
	.{ .name = "49152-bit", .bits = 49152 },
};

const LARGEST_BYTES: usize = 32768 / 8; // 4096 bytes

pub fn main() !void {
	if (comptime @import("builtin").mode == .Debug) {
		std.debug.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
	}

	// libc malloc — apples-to-apples with GMP's default allocator.
	const allocator = std.heap.c_allocator;

	std.debug.print("=== blip_mp add benchmark ===\n", .{});
	std.debug.print("small_iters={d} large_iters={d}\n\n", .{ ITERATIONS_SMALL, ITERATIONS_LARGE });

	for (BUCKETS) |bucket| {
		const ns_mp = try benchmarkMpAdd(allocator, bucket);
		std.debug.print("RESULT impl=Mp.add bucket={s} ns_per_op={d:.2}\n", .{ bucket.name, ns_mp });
		const ns_raw = try benchmarkRawAdd(allocator, bucket);
		std.debug.print("RESULT impl=raw bucket={s} ns_per_op={d:.2}\n", .{ bucket.name, ns_raw });
	}

	// Large-value buckets exercise the tier-3 byte-direct path.
	for (LARGE_BUCKETS) |lb| {
		const ns = try benchmarkMpAddLarge(allocator, lb);
		std.debug.print("RESULT impl=Mp.add bucket={s} ns_per_op={d:.2}\n", .{ lb.name, ns });
	}

	// Multiplication sweep — same bucket sizes as add. Iterations scale down
	// for large sizes (mul is O(n^1.58) Karatsuba / O(n^2) schoolbook).
	std.debug.print("\n--- multiplication ---\n", .{});
	for (LARGE_BUCKETS) |lb| {
		const ns = try benchmarkMpMulLarge(allocator, lb);
		std.debug.print("RESULT impl=Mp.mul bucket={s} ns_per_op={d:.2}\n", .{ lb.name, ns });
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
	while (i < ITERATIONS_SMALL) : (i += 1) {
		const a = &pool[i & (POOL_SIZE - 1)];
		const b = &pool[(i + 1) & (POOL_SIZE - 1)];
		try result.add(a, b);
	}
	const elapsed_ns = nowNs() - start_ns;

	std.mem.doNotOptimizeAway(result.bytes().ptr);
	return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS_SMALL));
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
	while (i < ITERATIONS_SMALL) : (i += 1) {
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
	return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS_SMALL));
}

// Large-value bench: build a pool of POOL_SIZE bigints with the given bit
// width, time Mp.add (which routes to tier 3 internally for sizes > i64).
fn benchmarkMpAddLarge(allocator: std.mem.Allocator, lb: LargeBucket) !f64 {
	const byte_count = lb.bits / 8;
	var pool: [POOL_SIZE]blip_mp.Mp = undefined;
	for (&pool, 0..) |*slot, i| {
		slot.* = blip_mp.Mp.init(allocator);
		// Build payload from heap-allocated buffer (avoids huge stack frames
		// for large bit widths).
		const payload = try allocator.alloc(u8, byte_count);
		defer allocator.free(payload);
		var rng = std.Random.DefaultPrng.init(0xCAFE_BEEF + i);
		const r = rng.random();
		for (payload) |*p| p.* = r.int(u8);
		payload[byte_count - 1] &= 0x7F; // ensure positive
		const blip_buf = try allocator.alloc(u8, byte_count + 16);
		defer allocator.free(blip_buf);
		const hdr_len = try blip_mp.tier3.writeHeader(blip_buf, byte_count);
		@memcpy(blip_buf[hdr_len .. hdr_len + byte_count], payload);
		try slot.setBytes(blip_buf[0 .. hdr_len + byte_count]);
	}
	defer for (&pool) |*slot| slot.deinit();

	var result = blip_mp.Mp.init(allocator);
	defer result.deinit();

	const start_ns = nowNs();
	var i: usize = 0;
	while (i < ITERATIONS_LARGE) : (i += 1) {
		const a = &pool[i & (POOL_SIZE - 1)];
		const b = &pool[(i + 1) & (POOL_SIZE - 1)];
		try result.add(a, b);
	}
	const elapsed_ns = nowNs() - start_ns;

	std.mem.doNotOptimizeAway(result.bytes().ptr);
	return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS_LARGE));
}

// Mul-specific iteration count: scales down with bit width (mul is O(n^2)
// or O(n^1.58); want bench to complete in reasonable time).
fn mulIters(bits: usize) usize {
	if (bits <= 256) return 500_000;
	if (bits <= 1024) return 100_000;
	if (bits <= 4096) return 20_000;
	return 5_000; // 8K-bit and up
}

fn benchmarkMpMulLarge(allocator: std.mem.Allocator, lb: LargeBucket) !f64 {
	const byte_count = lb.bits / 8;
	var pool: [POOL_SIZE]blip_mp.Mp = undefined;
	for (&pool, 0..) |*slot, i| {
		slot.* = blip_mp.Mp.init(allocator);
		const payload = try allocator.alloc(u8, byte_count);
		defer allocator.free(payload);
		var rng = std.Random.DefaultPrng.init(0xCAFE_BEEF + i);
		const r = rng.random();
		for (payload) |*p| p.* = r.int(u8);
		payload[byte_count - 1] &= 0x7F;
		const blip_buf = try allocator.alloc(u8, byte_count + 16);
		defer allocator.free(blip_buf);
		const hdr_len = try blip_mp.tier3.writeHeader(blip_buf, byte_count);
		@memcpy(blip_buf[hdr_len .. hdr_len + byte_count], payload);
		try slot.setBytes(blip_buf[0 .. hdr_len + byte_count]);
	}
	defer for (&pool) |*slot| slot.deinit();

	var result = blip_mp.Mp.init(allocator);
	defer result.deinit();

	const iters = mulIters(lb.bits);
	const start_ns = nowNs();
	var i: usize = 0;
	while (i < iters) : (i += 1) {
		const a = &pool[i & (POOL_SIZE - 1)];
		const b = &pool[(i + 1) & (POOL_SIZE - 1)];
		try result.mul(a, b);
	}
	const elapsed_ns = nowNs() - start_ns;

	std.mem.doNotOptimizeAway(result.bytes().ptr);
	return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iters));
}
