//! Verified asymmetric multiplication and allocation-lifetime experiments.
const std = @import("std");
const blip = @import("blip_mp");
const gmp = @import("gmp.zig");

pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) {
		try std.Io.File.stderr().writeStreamingAll(init.io, "\x1b[33mDEBUG BUILD!\x1b[0m Performance probe requires ReleaseFast.\n");
		return error.UnoptimizedBuild;
	}
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	const options = try parse(args[1..]);
	const Row = struct {
		size: usize, longer_bytes: usize, iterations: usize,
		samples: struct { cpu_ns: [5]f64, wall_ns: [5]f64 },
		pair: ?struct {
			baseline_cpu_ns: [5]f64, candidate_cpu_ns: [5]f64,
			baseline_wall_ns: [5]f64, candidate_wall_ns: [5]f64,
		} = null,
	};
	var rows: [16]Row = undefined;
	for (options.sizes[0..options.count], 0..) |size, index| {
		var fixture = try Fixture.init(std.heap.c_allocator, options.shape, size);
		defer fixture.deinit();
		try fixture.run(options.kind);
		var row: Row = .{ .size = size, .longer_bytes = fixture.a.len, .iterations = options.iterations, .samples = undefined };
		if (options.kind == .paired_tail) row.pair = .{
			.baseline_cpu_ns = undefined, .candidate_cpu_ns = undefined,
			.baseline_wall_ns = undefined, .candidate_wall_ns = undefined,
		};
		for (&row.samples.cpu_ns, &row.samples.wall_ns, 0..) |*cpu, *wall, sample| {
			if (options.kind == .paired_tail) {
				const pair = try pairedSample(&fixture, timedBatch, options.iterations);
				row.pair.?.baseline_cpu_ns[sample] = pair.baseline_cpu;
				row.pair.?.candidate_cpu_ns[sample] = pair.candidate_cpu;
				row.pair.?.baseline_wall_ns[sample] = pair.baseline_wall;
				row.pair.?.candidate_wall_ns[sample] = pair.candidate_wall;
				cpu.* = (pair.baseline_cpu + pair.candidate_cpu) / 2;
				wall.* = (pair.baseline_wall + pair.candidate_wall) / 2;
			} else {
				const duration = try timedBatch(&fixture, options.kind, options.iterations);
				const count: f64 = @floatFromInt(options.iterations);
				cpu.* = @as(f64, @floatFromInt(duration.cpu)) / count;
				wall.* = @as(f64, @floatFromInt(duration.wall)) / count;
			}
		}
		rows[index] = row;
	}
	const report = .{
		.schema = "performance-measurement/v1", .correct = true, .build_mode = "ReleaseFast",
		.compiler = @import("builtin").zig_version_string,
		.method = if (options.kind == .paired_tail) "multiplication-paired-tail-v1" else "multiplication-gmp-verified-v1",
		.algorithm = @tagName(options.kind), .shape = @tagName(options.shape),
		.seed_usage = "fixed 0x579_B11F; identical operands across algorithms; engine seed does not alter inputs",
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID", .wall_clock = "CLOCK_MONOTONIC",
		.normalization = if (options.kind == .paired_tail)
			"ABBA batches; primary samples average both methods per product; pair fields preserve each component; full GMP-derived comparison included"
			else "nanoseconds per multiplication including full GMP-derived result comparison; no subtraction",
		.allocator_coverage = "c_allocator; setup outside timing; mp_cold releases result and library scratch each iteration, without flushing libc or hardware caches",
		.warmup_iterations = 1, .rows = rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), report, .{});
	try std.Io.File.stdout().writeStreamingAll(init.io, json);
	try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

pub const Kind = enum { schoolbook, blocked, mp_warm, mp_cold, blocked_tail, paired_tail };
pub const Shape = enum { below, two, above, four, eight, sixteen, tail8, tail9 };
pub const Options = struct {
	kind: Kind,
	shape: Shape,
	sizes: [16]usize,
	count: usize,
	iterations: usize,
};

const PairSample = struct {
	baseline_cpu: f64, candidate_cpu: f64,
	baseline_wall: f64, candidate_wall: f64,
};
const Timing = struct { cpu: u64, wall: u64 };
fn timedBatch(fixture: *Fixture, kind: Kind, iterations: usize) !Timing {
	const now = @import("immediate_add.zig").now;
	const wall_start = try now(.MONOTONIC);
	const cpu_start = try now(.PROCESS_CPUTIME_ID);
	for (0..iterations) |_| {
		try fixture.run(kind);
		std.mem.doNotOptimizeAway(fixture);
	}
	const cpu_end = try now(.PROCESS_CPUTIME_ID);
	const wall_end = try now(.MONOTONIC);
	if (cpu_end <= cpu_start or wall_end <= wall_start) return error.ClockFailed;
	return .{ .cpu = cpu_end - cpu_start, .wall = wall_end - wall_start };
}
fn pairedSample(state: anytype, comptime batch: anytype, iterations: usize) !PairSample {
	var result: PairSample = .{ .baseline_cpu = 0, .candidate_cpu = 0, .baseline_wall = 0, .candidate_wall = 0 };
	for ([_]Kind{ .blocked, .blocked_tail, .blocked_tail, .blocked }) |kind| {
		const duration = try batch(state, kind, iterations);
		if (kind == .blocked) {
			result.baseline_cpu += @floatFromInt(duration.cpu);
			result.baseline_wall += @floatFromInt(duration.wall);
		} else {
			result.candidate_cpu += @floatFromInt(duration.cpu);
			result.candidate_wall += @floatFromInt(duration.wall);
		}
	}
	const count: f64 = @floatFromInt(2 * iterations);
	inline for (std.meta.fields(PairSample)) |field| @field(result, field.name) /= count;
	return result;
}

test "paired multiplication balances order and normalizes both components" {
	const Fake = struct {
		position: usize = 0,
		calls: [4]usize = @splat(0),
		fn batch(self: *@This(), kind: Kind, count: usize) !Timing {
			const slot = self.position;
			self.position += 1;
			self.calls[slot] = @intFromEnum(kind);
			// A linear drift cancels when each method occupies symmetric positions.
			const duration: u64 = (if (kind == .blocked) @as(u64, 100) else 80) + slot * 10;
			return .{ .cpu = duration * count, .wall = (duration + 5) * count };
		}
	};
	var fake: Fake = .{};
	const result = try pairedSample(&fake, Fake.batch, 3);
	try std.testing.expectEqual(@as(f64, 115), result.baseline_cpu);
	try std.testing.expectEqual(@as(f64, 95), result.candidate_cpu);
	try std.testing.expectEqual(@as(f64, 120), result.baseline_wall);
	try std.testing.expectEqual(@as(f64, 100), result.candidate_wall);
	try std.testing.expectEqual(@as(usize, 4), fake.position);
	try std.testing.expectEqual(fake.calls[0], fake.calls[3]);
	try std.testing.expectEqual(fake.calls[1], fake.calls[2]);
	try std.testing.expect(fake.calls[0] != fake.calls[1]);
}

test "paired multiplication propagates an interrupted batch" {
	const Failure = struct {
		fn batch(_: void, _: Kind, _: usize) error{Injected}!Timing {
			return error.Injected;
		}
	};
	try std.testing.expectError(error.Injected, pairedSample({}, Failure.batch, 1));
}
pub fn parse(args: []const []const u8) !Options {
	if (args.len != 4) return error.InvalidArguments;
	var result: Options = .{
		.kind = std.meta.stringToEnum(Kind, args[0]) orelse return error.InvalidArguments,
		.shape = std.meta.stringToEnum(Shape, args[1]) orelse return error.InvalidArguments,
		.sizes = undefined, .count = 0,
		.iterations = std.fmt.parseInt(usize, args[3], 10) catch return error.InvalidArguments,
	};
	if (result.iterations == 0 or result.iterations > 10_000) return error.InvalidArguments;
	var sizes = std.mem.splitScalar(u8, args[2], ',');
	while (sizes.next()) |text| {
		const size = std.fmt.parseInt(usize, text, 10) catch return error.InvalidArguments;
		if (result.count == result.sizes.len or size < 64 or size > 8192) return error.InvalidArguments;
		if (result.count > 0 and size <= result.sizes[result.count - 1]) return error.InvalidArguments;
		result.sizes[result.count] = size;
		result.count += 1;
	}
	return result;
}

pub const Fixture = struct {
	allocator: std.mem.Allocator,
	arena: std.heap.ArenaAllocator,
	a: []u8,
	b: []u8,
	out: []u8,
	scratch: []u8,
	expected: []u8,
	a_mp: blip.Mp,
	b_mp: blip.Mp,
	result: blip.Mp,
	reference: blip.Mp,
	pub fn init(parent: std.mem.Allocator, shape: Shape, shorter: usize) !Fixture {
		if (shorter < 64 or shorter > 8192) return error.InvalidArguments;
		const longer = switch (shape) {
			.below => 2 * shorter - 1, .two => 2 * shorter, .above => 2 * shorter + 1,
			.four => 4 * shorter, .eight => 8 * shorter, .sixteen => 16 * shorter,
			.tail8 => 2 * shorter + 8, .tail9 => 2 * shorter + 9,
		};
		var arena = std.heap.ArenaAllocator.init(parent);
		errdefer arena.deinit();
		const allocator = arena.allocator();
		var self: Fixture = .{
			.allocator = parent, .arena = arena,
			.a = try allocator.alloc(u8, longer), .b = try allocator.alloc(u8, shorter),
			.out = try allocator.alloc(u8, longer + shorter),
			.scratch = try allocator.alloc(u8, blip.tier3.blockedScratchNeed(shorter)),
			.expected = try allocator.alloc(u8, longer + shorter),
			.a_mp = blip.Mp.init(parent), .b_mp = blip.Mp.init(parent),
			.result = blip.Mp.init(parent), .reference = blip.Mp.init(parent),
		};
		errdefer self.a_mp.deinit();
		errdefer self.b_mp.deinit();
		errdefer self.reference.deinit();
		var random = std.Random.DefaultPrng.init(0x579_B11F);
		random.random().bytes(self.a);
		random.random().bytes(self.b);
		self.a[longer - 1] = 0x51;
		self.b[shorter - 1] = 0x61;
		const length = try gmp.product(self.a, self.b, self.expected);
		self.expected = self.expected[0..length];
		try setMagnitude(allocator, &self.a_mp, self.a);
		try setMagnitude(allocator, &self.b_mp, self.b);
		try setMagnitude(allocator, &self.reference, self.expected);
		self.arena = arena;
		return self;
	}
	fn setMagnitude(allocator: std.mem.Allocator, value: *blip.Mp, magnitude: []const u8) !void {
		if (magnitude.len == 0) return value.setI64(0);
		const padding: usize = @intFromBool(magnitude[magnitude.len - 1] & 0x80 != 0);
		const encoded = try allocator.alloc(u8, magnitude.len + padding + 16);
		const header = try blip.tier3.writeHeader(encoded, magnitude.len + padding);
		@memcpy(encoded[header..][0..magnitude.len], magnitude);
		if (padding != 0) encoded[header + magnitude.len] = 0;
		try value.setBytes(encoded[0 .. header + magnitude.len + padding]);
	}
	fn resetResult(self: *Fixture) void {
		self.result.deinit();
		self.result = blip.Mp.init(self.allocator);
		blip.tier3.releaseMulScratch();
	}
	pub fn deinit(self: *Fixture) void {
		self.resetResult();
		self.a_mp.deinit();
		self.b_mp.deinit();
		self.reference.deinit();
		self.arena.deinit();
	}
	pub fn run(self: *Fixture, kind: Kind) anyerror!void {
		switch (kind) {
			.paired_tail => {
				try self.run(.blocked);
				try self.run(.blocked_tail);
			},
			.schoolbook, .blocked, .blocked_tail => {
				switch (kind) {
					.schoolbook => blip.tier3.mulMagnitudes(self.a, self.b, self.out),
					.blocked => blip.tier3.mulBlocked(self.a, self.b, self.out, self.scratch),
					.blocked_tail => blip.tier3.mulBlockedShortTail(self.a, self.b, self.out, self.scratch),
					else => unreachable,
				}
				if (!std.mem.eql(u8, std.mem.trimEnd(u8, self.out, &.{0}), self.expected)) return error.IncorrectWork;
			},
			.mp_warm, .mp_cold => {
				if (kind == .mp_cold) self.resetResult();
				defer if (kind == .mp_cold) self.resetResult();
				try self.result.mul(&self.a_mp, &self.b_mp);
				if (!std.mem.eql(u8, self.result.bytes(), self.reference.bytes())) return error.IncorrectWork;
			},
		}
	}
};

test "multiplication probe classifies algorithms shapes and bounded work" {
	for (std.enums.values(Kind)) |kind| for (std.enums.values(Shape)) |shape| {
		const options = try parse(&.{ @tagName(kind), @tagName(shape), "64,2047,2048,4096", "10" });
		try std.testing.expectEqual(kind, options.kind);
		try std.testing.expectEqual(shape, options.shape);
		try std.testing.expectEqualSlices(usize, &.{ 64, 2047, 2048, 4096 }, options.sizes[0..options.count]);
		try std.testing.expectEqual(@as(usize, 10), options.iterations);
	};
	for ([_][]const u8{ "", "0", "63", "8193", "-1", "64,", "x", "64,0", "64,64" }) |sizes| {
		try std.testing.expectError(error.InvalidArguments, parse(&.{ "blocked", "two", sizes, "1" }));
	}
	for ([_][]const u8{ "", "0", "-1", "10001", "x" }) |count| {
		try std.testing.expectError(error.InvalidArguments, parse(&.{ "blocked", "two", "64", count }));
	}
	try std.testing.expectError(error.InvalidArguments, parse(&.{ "unknown", "two", "64", "1" }));
	try std.testing.expectError(error.InvalidArguments, parse(&.{ "blocked", "unknown", "64", "1" }));
	try std.testing.expectError(error.InvalidArguments, parse(&.{ "blocked", "two", "64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80", "1" }));
	try std.testing.expectError(error.InvalidArguments, parse(&.{}));
}

test "multiplication probe verifies every shape and dispatch boundary against GMP" {
	for (std.enums.values(Shape), [_]usize{ 127, 128, 129, 256, 512, 1024, 136, 137 }) |shape, longer| {
		var fixture = try Fixture.init(std.testing.allocator, shape, 64);
		defer fixture.deinit();
		try std.testing.expectEqual(longer, fixture.a.len);
		try std.testing.expectEqual(@as(usize, 64), fixture.b.len);
		for (std.enums.values(Kind)) |kind| try fixture.run(kind);
	}
	for ([_]Shape{ .below, .two, .above }) |shape| for ([_]usize{ 2047, 2048, 2049 }) |size| {
		var fixture = try Fixture.init(std.testing.allocator, shape, size);
		defer fixture.deinit();
		for (std.enums.values(Kind)) |kind| try fixture.run(kind);
	};
}

test "multiplication probe rejects corrupted expected results for every algorithm" {
	for (std.enums.values(Kind)) |kind| {
		var fixture = try Fixture.init(std.testing.allocator, .two, 64);
		defer fixture.deinit();
		try fixture.run(kind);
		fixture.expected[0] ^= 1;
		try fixture.reference.setI64(1);
		try std.testing.expectError(error.IncorrectWork, fixture.run(kind));
	}
}

test "multiplication warm calls reuse allocation while cold calls release and allocate" {
	var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{});
	{
		var fixture = try Fixture.init(tracked.allocator(), .two, 4096);
		defer fixture.deinit();
		try fixture.run(.mp_warm);
		const warm_allocations = tracked.allocations;
		try fixture.run(.mp_warm);
		try std.testing.expectEqual(warm_allocations, tracked.allocations);
		try fixture.run(.mp_cold);
		const cold_allocations = tracked.allocations;
		try std.testing.expect(cold_allocations > warm_allocations);
		try fixture.run(.mp_cold);
		try std.testing.expect(tracked.allocations > cold_allocations);
	}
	try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
}

test "multiplication fixture cleans up after every allocation failure" {
	const Case = struct {
		fn run(allocator: std.mem.Allocator) anyerror!void {
			var fixture = try Fixture.init(allocator, .two, 64);
			defer fixture.deinit();
			for (std.enums.values(Kind)) |kind| try fixture.run(kind);
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
