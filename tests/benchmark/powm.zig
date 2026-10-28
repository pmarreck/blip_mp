//! GMP-verified modular exponentiation using the retained 256-value workload.
const std = @import("std");
const blip = @import("blip_mp");
const Mp = blip.Mp;
const gmp = @import("gmp.zig");
const legacy = @import("blip_mp_bench.zig");
const widths = [_]usize{ 64, 128, 256, 384, 512, 768, 1024, 1536, 2048, 3072 };
const Options = struct { sizes: [widths.len]usize, count: usize, paired: bool = false };

const Method = enum { general, symmetric };
const PairSample = struct { cpu_ns: [2]f64, wall_ns: [2]f64 };
fn pairedSample(work: anytype, comptime batch: anytype, count: usize, round: usize) !PairSample {
	if (count == 0 or count % 2 != 0) return error.InvalidArguments;
	var result: PairSample = .{ .cpu_ns = .{0,0}, .wall_ns = .{0,0} };
	for ([_]usize{0,1,1,0}, 0..) |position, visit| {
		const method = (position + round % 2) % 2;
		const timing = try batch(work, @as(Method, @enumFromInt(method)), if (visit < 2) 0 else count / 2, count / 2);
		result.cpu_ns[method] += timing.cpu_ns / 2;
		result.wall_ns[method] += timing.wall_ns / 2;
	}
	return result;
}

fn parse(args: []const []const u8) !Options {
	const paired = args.len == 2 and std.mem.eql(u8, args[0], "paired");
	if (args.len != 1 and !paired) return error.InvalidArguments;
	var options: Options = .{ .sizes = undefined, .count = 0, .paired = paired };
	var values = std.mem.splitScalar(u8, args[args.len - 1], ',');
	while (values.next()) |value| {
		const bits = std.fmt.parseInt(usize, value, 10) catch return error.InvalidArguments;
		if (std.mem.indexOfScalar(usize, &widths, bits) == null or options.count == widths.len) return error.InvalidArguments;
		if (options.count != 0 and bits <= options.sizes[options.count - 1]) return error.InvalidArguments;
		options.sizes[options.count] = bits;
		options.count += 1;
	}
	return options;
}
pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) {
		try std.Io.File.stderr().writeStreamingAll(init.io, "\x1b[33mDEBUG BUILD!\x1b[0m Performance probe requires ReleaseFast.\n");
		return error.UnoptimizedBuild;
	}
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	const options = try parse(args[1..]);
	const Component = struct { method: []const u8, cpu_ns: [5]f64, wall_ns: [5]f64 };
	const Row = struct { size: usize, iterations: usize = 256, fixture_count: usize = 256, warmup_cases: usize = 256, samples: struct { cpu_ns: [5]f64, wall_ns: [5]f64 }, components: ?[2]Component = null };
	var rows: [widths.len]Row = undefined;
	for (options.sizes[0..options.count], 0..) |bits, index| {
		var fixture = try Fixture.init(std.heap.c_allocator, bits, 256);
		defer fixture.deinit();
		var row: Row = .{ .size = bits, .samples = undefined };
		if (options.paired) {
			for (0..fixture.cases.len) |i| try fixture.runWith(.general, i);
			for (0..fixture.cases.len) |i| try fixture.runWith(.symmetric, i);
			row.warmup_cases = 512;
			row.components = .{
				.{ .method = "general", .cpu_ns = undefined, .wall_ns = undefined },
				.{ .method = "symmetric", .cpu_ns = undefined, .wall_ns = undefined },
			};
			for (0..5) |round| {
				const timing = try pairedSample(&fixture, timedPairedBatch, fixture.cases.len, round);
				for (&row.components.?, 0..) |*component, method| {
					component.cpu_ns[round] = timing.cpu_ns[method];
					component.wall_ns[round] = timing.wall_ns[method];
				}
				row.samples.cpu_ns[round] = (timing.cpu_ns[0] + timing.cpu_ns[1]) / 2;
				row.samples.wall_ns[round] = (timing.wall_ns[0] + timing.wall_ns[1]) / 2;
			}
		} else {
			for (0..fixture.cases.len) |i| try fixture.run(i);
			var clock: NativeClock = .{};
			for (&row.samples.cpu_ns, &row.samples.wall_ns) |*cpu, *wall| {
				const timing = try sample(&fixture, &clock, fixture.cases.len);
				cpu.* = timing.cpu_ns; wall.* = timing.wall_ns;
			}
		}
		rows[index] = row;
	}
	const report = .{
		.schema = "performance-measurement/v1", .correct = true, .build_mode = "ReleaseFast",
		.compiler = @import("builtin").zig_version_string, .method = if (options.paired) "powm-paired-squaring-v1" else "powm-gmp-verified-v1",
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID", .wall_clock = "CLOCK_MONOTONIC",
		.seed_usage = "retained seeds 0xBA5E+i, 0x77+i, 0x70D+i for base/exponent/modulus; engine seed does not alter inputs",
		.normalization = if (options.paired) "rotating ABBA/BAAB half-pool batches; 256 verified public calls per method per sample; primary averages both methods; no subtraction" else "nanoseconds per Mp.powm plus full GMP-derived result comparison; one complete 256-case pool per sample; no subtraction",
		.operation = "positive base and exponent using retained byte-width distributions; odd modulus; public setup and reduction included",
		.allocator_coverage = "c_allocator; fixtures and GMP references outside timing; reused output; arithmetic allocations included",
		.rows = rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), report, .{});
	try std.Io.File.stdout().writeStreamingAll(init.io, json);
	try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

const Timing = struct { cpu_ns: f64, wall_ns: f64 };
const NativeClock = struct {
	fn read(_: *@This(), kind: std.c.CLOCK) !u64 { return @import("immediate_add.zig").now(kind); }
};

fn timedPairedBatch(fixture: *Fixture, method: Method, start: usize, count: usize) !Timing {
	const Work = struct {
		fixture: *Fixture, method: Method, start: usize,
		fn run(self: *@This(), index: usize) !void { return self.fixture.runWith(self.method, self.start + index); }
	};
	var work: Work = .{ .fixture = fixture, .method = method, .start = start };
	var clock: NativeClock = .{};
	return sample(&work, &clock, count);
}
fn sample(work: anytype, clock: anytype, count: usize) !Timing {
	if (count == 0) return error.InvalidArguments;
	const wall_start = try clock.read(.MONOTONIC);
	const cpu_start = try clock.read(.PROCESS_CPUTIME_ID);
	for (0..count) |index| {
		try work.run(index);
		std.mem.doNotOptimizeAway(work);
	}
	const cpu_end = try clock.read(.PROCESS_CPUTIME_ID);
	const wall_end = try clock.read(.MONOTONIC);
	if (cpu_end <= cpu_start or wall_end <= wall_start) return error.ClockFailed;
	const denominator: f64 = @floatFromInt(count);
	return .{ .cpu_ns = @as(f64, @floatFromInt(cpu_end - cpu_start)) / denominator, .wall_ns = @as(f64, @floatFromInt(wall_end - wall_start)) / denominator };
}

fn releaseCaches() void {
	blip.tier3.releaseBzArena();
	blip.tier3.releaseMulScratch();
	blip.tier3.releaseDivScratch();
	blip.tier3.releaseVnScratch();
	blip.tier3.releaseFftScratch();
	blip.tier3.releaseGoldFftScratch();
}

fn reference(a: *const Mp, exponent: *const Mp, modulus: *const Mp, output: []u8) !usize {
	if (output.len < modulus.payload().len) return error.BufferTooSmall;
	var ga: gmp.Z = undefined; gmp.__gmpz_init(&ga); defer gmp.__gmpz_clear(&ga);
	var ge: gmp.Z = undefined; gmp.__gmpz_init(&ge); defer gmp.__gmpz_clear(&ge);
	var gm: gmp.Z = undefined; gmp.__gmpz_init(&gm); defer gmp.__gmpz_clear(&gm);
	var result: gmp.Z = undefined; gmp.__gmpz_init(&result); defer gmp.__gmpz_clear(&result);
	gmp.__gmpz_import(&ga, a.payload().len, -1, 1, 0, 0, a.payload().ptr);
	gmp.__gmpz_import(&ge, exponent.payload().len, -1, 1, 0, 0, exponent.payload().ptr);
	gmp.__gmpz_import(&gm, modulus.payload().len, -1, 1, 0, 0, modulus.payload().ptr);
	gmp.__gmpz_powm(&result, &ga, &ge, &gm);
	var length: usize = 0;
	_ = gmp.__gmpz_export(output.ptr, &length, -1, 1, 0, 0, &result);
	return length;
}

const Case = struct {
	a: Mp, exponent: Mp, modulus: Mp, expected: []u8,
	fn init(allocator: std.mem.Allocator, bits: usize, index: usize) !Case {
		var a = try legacy.buildRandomPositiveMp(allocator, bits / 8, 0xBA5E + index);
		errdefer a.deinit();
		var exponent = try legacy.buildRandomPositiveMp(allocator, bits / 8, 0x77 + index);
		errdefer exponent.deinit();
		var modulus = try legacy.buildRandomPositiveOddMp(allocator, bits / 8, 0x70D + index);
		errdefer modulus.deinit();
		const raw = try allocator.alloc(u8, bits / 8);
		defer allocator.free(raw);
		const length = try reference(&a, &exponent, &modulus, raw);
		return .{ .a = a, .exponent = exponent, .modulus = modulus, .expected = try allocator.dupe(u8, raw[0..length]) };
	}
	fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
		self.a.deinit(); self.exponent.deinit(); self.modulus.deinit();
		allocator.free(self.expected);
	}
};

const Fixture = struct {
	allocator: std.mem.Allocator, cases: []Case, output: Mp,
	fn init(allocator: std.mem.Allocator, bits: usize, count: usize) !Fixture {
		if (std.mem.indexOfScalar(usize, &widths, bits) == null or count == 0 or count > 256) return error.InvalidArguments;
		const cases = try allocator.alloc(Case, count);
		errdefer allocator.free(cases);
		var initialized: usize = 0;
		errdefer for (cases[0..initialized]) |*case| case.deinit(allocator);
		for (cases, 0..) |*case, index| {
			case.* = try Case.init(allocator, bits, index);
			initialized += 1;
		}
		return .{ .allocator = allocator, .cases = cases, .output = Mp.init(allocator) };
	}
	fn run(self: *@This(), index: usize) !void {
		const case = &self.cases[index];
		try Mp.powm(&self.output, &case.a, &case.exponent, &case.modulus);
		try self.verify(case);
	}
	fn runWith(self: *@This(), method: Method, index: usize) !void {
		const case = &self.cases[index];
		switch (method) {
			.general => try Mp.powmGeneral(&self.output, &case.a, &case.exponent, &case.modulus),
			.symmetric => try Mp.powmSymmetric(&self.output, &case.a, &case.exponent, &case.modulus),
		}
		try self.verify(case);
	}
	fn verify(self: *@This(), case: *const Case) !void {
		const actual = std.mem.trimEnd(u8, self.output.payload(), &.{0});
		if (try self.output.sign() < 0 or !std.mem.eql(u8, actual, case.expected)) return error.IncorrectWork;
	}
	fn corrupt(self: *@This(), index: usize) void { self.cases[index].expected[0] ^= 1; }
	fn deinit(self: *@This()) void {
		releaseCaches();
		self.output.deinit();
		for (self.cases) |*case| case.deinit(self.allocator);
		self.allocator.free(self.cases);
	}
};

test "powm probe accepts only ordered supported widths" {
	const all = try parse(&.{"512,1024,2048,3072"});
	try std.testing.expectEqualSlices(usize, &.{512,1024,2048,3072}, all.sizes[0..all.count]);
	const paired = try parse(&.{"paired", "512,3072"});
	try std.testing.expectEqualSlices(usize, &.{512,3072}, paired.sizes[0..paired.count]);
	for ([_][]const u8{"", "0", "511", "513", "4096", "512,", "512,512", "1024,512", "x"}) |value|
		try std.testing.expectError(error.InvalidArguments, parse(&.{value}));
	try std.testing.expectError(error.InvalidArguments, parse(&.{}));
	try std.testing.expectError(error.InvalidArguments, parse(&.{"512", "1024"}));
}

test "powm boundary probe accepts the complete small-width classifier set" {
	const all = try parse(&.{"paired", "64,128,256,384,512,768,1024,1536,2048,3072"});
	try std.testing.expectEqualSlices(usize, &.{64,128,256,384,512,768,1024,1536,2048,3072}, all.sizes[0..all.count]);
	for ([_][]const u8{"63","65","192","255","257","383","385","767","769","1535","1537","3073","4096","128,64","64,64"}) |value| {
		try std.testing.expectError(error.InvalidArguments, parse(&.{value}));
		try std.testing.expectError(error.InvalidArguments, parse(&.{"paired",value}));
	}
}

test "powm sampling preserves work counts, distinct clocks and error paths" {
	const Work = struct {
		count: usize = 0, fail: bool = false,
		fn run(self: *@This(), index: usize) !void {
			if (self.fail) return error.IncorrectWork;
			try std.testing.expectEqual(self.count, index);
			self.count += 1;
		}
	};
	const Clock = struct {
		times: [4]u64 = .{100, 200, 600, 900}, index: usize = 0, fail: bool = false,
		fn read(self: *@This(), kind: std.c.CLOCK) !u64 {
			if (self.fail) return error.InjectedClockFailure;
			try std.testing.expectEqual(if (self.index == 0 or self.index == 3) std.c.CLOCK.MONOTONIC else std.c.CLOCK.PROCESS_CPUTIME_ID, kind);
			defer self.index += 1;
			return self.times[self.index];
		}
	};
	var work: Work = .{};
	var clock: Clock = .{};
	const got = try sample(&work, &clock, 4);
	try std.testing.expectEqualDeep(Timing{ .cpu_ns = 100, .wall_ns = 200 }, got);
	try std.testing.expectEqual(@as(usize, 4), work.count);
	try std.testing.expectEqual(@as(usize, 4), clock.index);
	try std.testing.expectError(error.InvalidArguments, sample(&work, &clock, 0));
	work = .{ .fail = true }; clock = .{};
	try std.testing.expectError(error.IncorrectWork, sample(&work, &clock, 4));
	work = .{}; clock = .{ .fail = true };
	try std.testing.expectError(error.InjectedClockFailure, sample(&work, &clock, 4));
	for ([_][4]u64{ .{100,200,200,900}, .{100,200,199,900}, .{100,200,600,100}, .{100,200,600,99} }) |times| {
		work = .{}; clock = .{ .times = times };
		try std.testing.expectError(error.ClockFailed, sample(&work, &clock, 4));
	}
}

test "powm fixture verifies retained inputs and rejects a corrupted oracle" {
	for (widths) |bits| {
		var fixture = try Fixture.init(std.testing.allocator, bits, 2);
		defer fixture.deinit();
		for (0..2) |i| {
			try fixture.run(i);
			try fixture.runWith(.general, i);
			try fixture.runWith(.symmetric, i);
			fixture.corrupt(i);
			try std.testing.expectError(error.IncorrectWork, fixture.run(i));
			try std.testing.expectError(error.IncorrectWork, fixture.runWith(.general, i));
			try std.testing.expectError(error.IncorrectWork, fixture.runWith(.symmetric, i));
		}
	}
}

test "powm fixture releases every partial allocation" {
	const FailureCase = struct {
		fn run(allocator: std.mem.Allocator) anyerror!void {
			var fixture = try Fixture.init(allocator, 512, 1);
			defer fixture.deinit();
			try fixture.run(0);
			try fixture.runWith(.general, 0);
			try fixture.runWith(.symmetric, 0);
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.run, .{});
}

test "paired powm batches cover identical cases and cancel linear drift" {
	const State = struct {
		calls: usize = 0, round: usize, fail: bool = false,
		fn batch(self: *@This(), method: Method, start: usize, count: usize) !Timing {
			if (self.fail) return error.IncorrectWork;
			const order = [_]usize{0,1,1,0};
			try std.testing.expectEqual((order[self.calls] + self.round % 2) % 2, @intFromEnum(method));
			try std.testing.expectEqual(@as(usize, 2), count);
			try std.testing.expectEqual(if (self.calls < 2) @as(usize, 0) else 2, start);
			const cpu: f64 = @floatFromInt(100 * (1 + @as(usize, @intFromEnum(method))) + 10 * self.calls);
			self.calls += 1;
			return .{ .cpu_ns = cpu, .wall_ns = 2 * cpu };
		}
	};
	for (0..6) |round| {
		var state: State = .{ .round = round };
		const got = try pairedSample(&state, State.batch, 4, round);
		try std.testing.expectEqualDeep(PairSample{ .cpu_ns = .{115,215}, .wall_ns = .{230,430} }, got);
		try std.testing.expectEqual(@as(usize, 4), state.calls);
	}
	var bad: State = .{ .round = 0, .fail = true };
	try std.testing.expectError(error.IncorrectWork, pairedSample(&bad, State.batch, 4, 0));
	for ([_]usize{0,1,3}) |count| try std.testing.expectError(error.InvalidArguments, pairedSample(&bad, State.batch, count, 0));
}

test "powm GMP oracle agrees with native modular powers including zero and unit modulus" {
	var a = Mp.init(std.testing.allocator); defer a.deinit();
	var e = Mp.init(std.testing.allocator); defer e.deinit();
	var m = Mp.init(std.testing.allocator); defer m.deinit();
	for ([_]u64{0, 1, 2, 17, 256}) |base| for ([_]u64{0, 1, 2, 63}) |exponent| for ([_]u64{1, 3, 17, 257, 65537}) |modulus| {
		try a.setU64(base); try e.setU64(exponent); try m.setU64(modulus);
		var expected: u64 = 1 % modulus;
		for (0..exponent) |_| expected = @intCast((@as(u128, expected) * base) % modulus);
		var actual: [8]u8 = @splat(0);
		_ = try reference(&a, &e, &m, &actual);
		try std.testing.expectEqual(expected, std.mem.readInt(u64, &actual, .little));
	};
}
