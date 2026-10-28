//! Verified small-input workload. Native sums are independent of BLIP encoding.
const std = @import("std");
const blip = @import("blip_mp");

pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) {
		try std.Io.File.stderr().writeStreamingAll(init.io, "DEBUG BUILD! Performance probe requires ReleaseFast.\n");
		return error.UnoptimizedBuild;
	}
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	if (args.len != 3) return error.InvalidArguments;
	const options = try parse(&.{ args[1], args[2] });
	var work = try Workload.init(std.heap.c_allocator, options.kind);
	defer work.deinit();
	const warmup_iterations = 250_000;
	try verify(try work.run(warmup_iterations), expected(options.kind, warmup_iterations));
	const wanted = expected(options.kind, options.iterations);
	var cpu: [5]f64 = undefined;
	var wall: [5]f64 = undefined;
	for (&cpu, &wall) |*cpu_sample, *wall_sample| {
		const wall_start = try now(.MONOTONIC);
		const cpu_start = try now(.PROCESS_CPUTIME_ID);
		const checksum = try work.run(options.iterations);
		const cpu_end = try now(.PROCESS_CPUTIME_ID);
		const wall_end = try now(.MONOTONIC);
		try verify(checksum, wanted);
		if (cpu_end <= cpu_start or wall_end <= wall_start) return error.ClockFailed;
		const count: f64 = @floatFromInt(options.iterations);
		cpu_sample.* = @as(f64, @floatFromInt(cpu_end - cpu_start)) / count;
		wall_sample.* = @as(f64, @floatFromInt(wall_end - wall_start)) / count;
	}
	const report = .{
		.schema = "performance-measurement/v1",
		.correct = true,
		.build_mode = "ReleaseFast",
		.compiler = @import("builtin").zig_version_string,
		.fixture = @tagName(options.kind),
		.method = "immediate-add-checksum-v1",
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID",
		.wall_clock = "CLOCK_MONOTONIC",
		.normalization = "nanoseconds per add plus result decode and checksum; no subtraction",
		.allocator_coverage = "unmeasured; c_allocator for fixture setup, inline arithmetic results",
		.seed_usage = "deterministic historical fixture; seed does not alter inputs",
		.warmup_iterations = warmup_iterations,
		.checksum = wanted,
		.rows = .{.{ .size = options.iterations, .samples = .{ .cpu_ns = cpu, .wall_ns = wall } }},
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), report, .{});
	try std.Io.File.stdout().writeStreamingAll(init.io, json);
	try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

const TimeSpec = extern struct { seconds: c_long, nanoseconds: c_long };
extern "c" fn clock_gettime(clock: c_int, time: *TimeSpec) c_int;
fn now(clock: std.c.CLOCK) !u64 {
	var time: TimeSpec = .{ .seconds = 0, .nanoseconds = 0 };
	const status = clock_gettime(@intCast(@intFromEnum(clock)), &time);
	return timestamp(status, time.seconds, time.nanoseconds);
}

pub const pool_size = 256;
pub const Kind = enum { mixed, immediate, promoted };

pub fn value(kind: Kind, index: usize) i64 {
	const minimum: i64, const maximum: i64 = switch (kind) {
		.mixed => .{ 1, 127 },
		.immediate => .{ 1, 63 },
		.promoted => .{ 64, 127 },
	};
	// Preserve the historical floating-point fixture construction exactly.
	const t = @as(f64, @floatFromInt(index)) / (pool_size - 1);
	return minimum + @as(i64, @intFromFloat(t * @as(f64, @floatFromInt(maximum - minimum))));
}

pub fn expected(kind: Kind, iterations: usize) u64 {
	var sum: u64 = 0;
	for (0..iterations) |i| {
		sum += @intCast(value(kind, i % pool_size) + value(kind, (i + 1) % pool_size));
	}
	return sum;
}

pub fn verify(actual: u64, wanted: u64) !void {
	if (actual != wanted) return error.IncorrectWork;
}

pub const Workload = struct {
	allocator: std.mem.Allocator,
	pool: []blip.Mp,
	result: blip.Mp,
	pub fn init(allocator: std.mem.Allocator, kind: Kind) !Workload {
		const pool = try allocator.alloc(blip.Mp, pool_size);
		errdefer allocator.free(pool);
		var initialized: usize = 0;
		errdefer for (pool[0..initialized]) |*item| item.deinit();
		for (pool, 0..) |*item, i| {
			item.* = blip.Mp.init(allocator);
			initialized += 1;
			try item.setI64(value(kind, i));
		}
		return .{ .allocator = allocator, .pool = pool, .result = blip.Mp.init(allocator) };
	}
	pub fn deinit(self: *Workload) void {
		for (self.pool) |*item| item.deinit();
		self.allocator.free(self.pool);
		self.result.deinit();
	}
	pub fn run(self: *Workload, iterations: usize) !u64 {
		var sum: u64 = 0;
		for (0..iterations) |i| {
			try self.result.add(&self.pool[i % pool_size], &self.pool[(i + 1) % pool_size]);
			const result = self.result.bytes();
			std.mem.doNotOptimizeAway(result);
			const decoded = (try blip.encoding.decodeI64(result)).value;
			if (decoded < 0 or decoded > 254) return error.IncorrectWork;
			sum += @intCast(decoded);
		}
		return sum;
	}
};

pub fn timestamp(status: c_int, seconds: i64, nanoseconds: i64) !u64 {
	if (status != 0 or seconds < 0 or nanoseconds < 0 or nanoseconds >= 1_000_000_000) return error.ClockFailed;
	const whole = std.math.mul(u64, @intCast(seconds), 1_000_000_000) catch return error.ClockFailed;
	return std.math.add(u64, whole, @intCast(nanoseconds)) catch error.ClockFailed;
}

pub const Options = struct { kind: Kind, iterations: usize };
pub fn parse(args: []const []const u8) !Options {
	if (args.len != 2) return error.InvalidArguments;
	const kind = std.meta.stringToEnum(Kind, args[0]) orelse return error.InvalidArguments;
	const iterations = std.fmt.parseInt(usize, args[1], 10) catch return error.InvalidArguments;
	if (iterations == 0 or iterations > 100_000_000) return error.InvalidArguments;
	return .{ .kind = kind, .iterations = iterations };
}

test "CLI accepts all fixtures and rejects invalid or unbounded iteration counts" {
	for (std.enums.values(Kind)) |kind| {
		const options = try parse(&.{ @tagName(kind), "256" });
		try std.testing.expectEqual(kind, options.kind);
		try std.testing.expectEqual(@as(usize, 256), options.iterations);
	}
	for ([_][]const u8{ "", "0", "-1", "1,2", "abc", "100000001", "18446744073709551616" }) |bad| {
		try std.testing.expectError(error.InvalidArguments, parse(&.{ "mixed", bad }));
	}
	try std.testing.expectError(error.InvalidArguments, parse(&.{ "invalid", "256" }));
	try std.testing.expectError(error.InvalidArguments, parse(&.{}));
	try std.testing.expectError(error.InvalidArguments, parse(&.{ "mixed", "256", "extra" }));
}

test "clock conversion propagates errors and rejects malformed times" {
	try std.testing.expectEqual(@as(u64, 2_000_000_003), try timestamp(0, 2, 3));
	try std.testing.expectError(error.ClockFailed, timestamp(-1, 2, 3));
	try std.testing.expectError(error.ClockFailed, timestamp(0, -1, 0));
	try std.testing.expectError(error.ClockFailed, timestamp(0, 0, -1));
	try std.testing.expectError(error.ClockFailed, timestamp(0, 0, 1_000_000_000));
	try std.testing.expectError(error.ClockFailed, timestamp(0, std.math.maxInt(i64), 0));
}

test "measured kernel agrees with native sums at cycle and tail boundaries" {
	for (std.enums.values(Kind)) |kind| {
		var work = try Workload.init(std.testing.allocator, kind);
		defer work.deinit();
		for ([_]usize{ 1, 255, 256, 257, 1024 }) |iterations| {
			try std.testing.expectEqual(expected(kind, iterations), try work.run(iterations));
		}
	}
}

test "oracle detects corrupted inputs to the measured kernel" {
	for (std.enums.values(Kind)) |kind| {
		var work = try Workload.init(std.testing.allocator, kind);
		defer work.deinit();
		try work.pool[0].setI64(0);
		try std.testing.expectError(error.IncorrectWork, verify(try work.run(pool_size), expected(kind, pool_size)));
	}
}

test "oracle rejects wrong and skipped work across each fixture" {
	for (std.enums.values(Kind)) |kind| {
		const wanted = expected(kind, pool_size);
		try verify(wanted, wanted);
		try std.testing.expectError(error.IncorrectWork, verify(wanted + 1, wanted));
		try std.testing.expectError(error.IncorrectWork, verify(0, wanted));
		try std.testing.expectError(error.IncorrectWork, verify(wanted - @as(u64, @intCast(value(kind, 0) + value(kind, 1))), wanted));
	}
}

test "fixture sets preserve historical mixed promotion and isolate controls" {
	for (std.enums.values(Kind)) |kind| {
		var promotions: usize = 0;
		for (0..pool_size) |i| {
			const a = value(kind, i);
			const b = value(kind, (i + 1) % pool_size);
			try std.testing.expect(a >= 1 and a <= 127);
			try std.testing.expect(b >= 1 and b <= 127);
			if (a + b >= 128) promotions += 1;
		}
		try std.testing.expectEqual(@as(usize, switch (kind) {
			.mixed => 128,
			.immediate => 0,
			.promoted => pool_size,
		}), promotions);
	}
}
