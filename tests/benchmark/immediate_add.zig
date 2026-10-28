//! Verified small-input workload. Native sums are independent of BLIP encoding.
const std = @import("std");
const blip = @import("blip_mp");

test {
	_ = @import("linux_counters.zig");
}

pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) {
		try std.Io.File.stderr().writeStreamingAll(init.io, "DEBUG BUILD! Performance probe requires ReleaseFast.\n");
		return error.UnoptimizedBuild;
	}
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	if (args.len != 3) return error.InvalidArguments;
	if (std.mem.eql(u8, args[1], "interleaved")) {
		if (@import("builtin").os.tag != .linux) return error.LinuxCountersRequired;
		const options = try parse(&.{ "mixed", args[2] });
		var backend: @import("linux_counters.zig").Native = .{};
		var clock: NativeClock = .{};
		const report = interleaved(&backend, &clock, std.heap.c_allocator, options.iterations, 250_000) catch |err| {
			const message = try std.fmt.allocPrint(init.arena.allocator(), "counter diagnostic failed: {s}; Linux errno {s}\n", .{ @errorName(err), @tagName(backend.last_errno) });
			try std.Io.File.stderr().writeStreamingAll(init.io, message);
			return err;
		};
		const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), report, .{});
		try std.Io.File.stdout().writeStreamingAll(init.io, json);
		try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
		return;
	}
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
pub fn scheduled(round: usize, position: usize) Kind { return @enumFromInt((round % 3 + position) % 3); }

const Samples = struct {
	cpu_ns: [6]f64,
	wall_ns: [6]f64,
	cycles: [6]f64,
	instructions: [6]f64,
	enabled_ns: [6]u64,
	running_ns: [6]u64,
};
const Diagnostic = struct {
	schema: []const u8 = "performance-measurement/v1",
	correct: bool = true,
	build_mode: []const u8 = "ReleaseFast",
	compiler: []const u8 = @import("builtin").zig_version_string,
	method: []const u8 = "interleaved-add-counters-v1",
	cpu_clock: []const u8 = "CLOCK_PROCESS_CPUTIME_ID",
	wall_clock: []const u8 = "CLOCK_MONOTONIC",
	counter_scope: []const u8 = "calling thread, user space only; grouped CPU cycles and retired instructions; no multiplexing",
	normalization: []const u8 = "per addition including decode/checksum; counters also include clock boundaries; no subtraction",
	allocator_coverage: []const u8 = "unmeasured; c_allocator fixture setup, inline arithmetic results",
	fixture_order: []const u8 = "mixed/immediate/promoted rotated left each round; six rounds",
	comparison_scope: []const u8 = "mixed CPU samples only; all other samples are supplemental diagnostics",
	warmup_iterations: usize = 250_000,
	checksums: [3]u64,
	fixtures: [3]Samples,
	rows: [1]struct { size: usize, samples: Samples },
};

const NativeClock = struct {
	pub fn read(_: *NativeClock, clock: std.c.CLOCK) !u64 { return now(clock); }
};

fn interleaved(backend: anytype, clock: anytype, allocator: std.mem.Allocator, iterations: usize, warmup: usize) !Diagnostic {
	var group = try @import("linux_counters.zig").Group(@TypeOf(backend.*)).init(backend);
	defer group.deinit();
	var workloads: [3]Workload = undefined;
	var initialized: usize = 0;
	defer for (workloads[0..initialized]) |*work| work.deinit();
	var checksums: [3]u64 = undefined;
	for (std.enums.values(Kind), 0..) |kind, index| {
		workloads[index] = try Workload.init(allocator, kind);
		initialized += 1;
		checksums[index] = expected(kind, iterations);
		try verify(try workloads[index].run(warmup), expected(kind, warmup));
	}
	var fixtures: [3]Samples = undefined;
	const count: f64 = @floatFromInt(iterations);
	for (0..6) |round| {
		for (0..3) |position| {
			const index = @intFromEnum(scheduled(round, position));
			try group.begin();
			const wall_start = try clock.read(.MONOTONIC);
			const cpu_start = try clock.read(.PROCESS_CPUTIME_ID);
			const checksum = try workloads[index].run(iterations);
			const cpu_end = try clock.read(.PROCESS_CPUTIME_ID);
			const wall_end = try clock.read(.MONOTONIC);
			const counters = try group.finish();
			try verify(checksum, checksums[index]);
			if (cpu_end <= cpu_start or wall_end <= wall_start) return error.ClockFailed;
			fixtures[index].cpu_ns[round] = @as(f64, @floatFromInt(cpu_end - cpu_start)) / count;
			fixtures[index].wall_ns[round] = @as(f64, @floatFromInt(wall_end - wall_start)) / count;
			fixtures[index].cycles[round] = @as(f64, @floatFromInt(counters.cycles)) / count;
			fixtures[index].instructions[round] = @as(f64, @floatFromInt(counters.instructions)) / count;
			fixtures[index].enabled_ns[round] = counters.enabled_ns;
			fixtures[index].running_ns[round] = counters.running_ns;
		}
	}
	return .{ .warmup_iterations = warmup, .checksums = checksums, .fixtures = fixtures, .rows = .{.{ .size = iterations, .samples = fixtures[0] }} };
}

const FakeClock = struct {
	ticks: u64 = 0,
	fail: bool = false,
	pub fn read(self: *FakeClock, _: std.c.CLOCK) !u64 {
		if (self.fail) return error.ClockFailed;
		self.ticks += 100;
		return self.ticks;
	}
};

test "diagnostic normalizes each fixture using supplied clocks and verifies real sums" {
	var backend: @import("linux_counters.zig").Fake = .{};
	var clock: FakeClock = .{};
	const report = try interleaved(&backend, &clock, std.testing.allocator, 256, 1);
	try std.testing.expectEqualDeep([3]u64{ 32516, 16130, 48644 }, report.checksums);
	try std.testing.expectEqual(@as(usize, 1), report.warmup_iterations);
	try std.testing.expectEqual(@as(usize, 256), report.rows[0].size);
	try std.testing.expectEqualDeep(report.fixtures[0], report.rows[0].samples);
	for (report.fixtures) |samples| {
		try std.testing.expectEqualDeep([_]f64{100.0 / 256.0} ** 6, samples.cpu_ns);
		try std.testing.expectEqualDeep([_]f64{300.0 / 256.0} ** 6, samples.wall_ns);
		try std.testing.expectEqualDeep([_]f64{40.0 / 256.0} ** 6, samples.cycles);
		try std.testing.expectEqualDeep([_]f64{20.0 / 256.0} ** 6, samples.instructions);
		try std.testing.expectEqualDeep([_]u64{10} ** 6, samples.enabled_ns);
		try std.testing.expectEqualDeep(samples.enabled_ns, samples.running_ns);
	}
	try std.testing.expectEqual(@as(u64, 18), backend.reads);
	try std.testing.expectEqual([2]bool{ false, false }, backend.live);
}

test "diagnostic clock failure closes active counters and releases fixtures" {
	var backend: @import("linux_counters.zig").Fake = .{};
	var clock: FakeClock = .{ .fail = true };
	try std.testing.expectError(error.ClockFailed, interleaved(&backend, &clock, std.testing.allocator, 256, 1));
	try std.testing.expect(!backend.active);
	try std.testing.expectEqual([2]bool{ false, false }, backend.live);
}

test "interleaved rounds visit every fixture and balance its position" {
	var positions = [_][3]usize{.{ 0, 0, 0 }} ** 3;
	for (0..6) |round| {
		var seen = [_]bool{false} ** 3;
		for (0..3) |position| {
			const index = @intFromEnum(scheduled(round, position));
			try std.testing.expect(!seen[index]);
			seen[index] = true;
			positions[index][position] += 1;
		}
		try std.testing.expectEqual([3]bool{ true, true, true }, seen);
	}
	try std.testing.expectEqualDeep([3][3]usize{ .{ 2, 2, 2 }, .{ 2, 2, 2 }, .{ 2, 2, 2 } }, positions);
}

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
