//! Identical-input Burnikel–Ziegler and chunk-reading Knuth comparisons.
const std = @import("std");
const tier3 = @import("blip_mp").tier3;
const gmp = @import("gmp.zig");
const widths = [_]usize{ 8, 9, 16, 31, 32, 63, 64, 65, 127, 128, 129, 256, 512, 1024, 2048, 4096 };
const Options = struct { sizes: [widths.len]usize, count: usize };

fn parse(args: []const []const u8) !Options {
	if (args.len != 1) return error.InvalidArguments;
	var options: Options = .{ .sizes = undefined, .count = 0 };
	var parts = std.mem.splitScalar(u8, args[0], ',');
	while (parts.next()) |part| {
		const width = std.fmt.parseInt(usize, part, 10) catch return error.InvalidArguments;
		if (std.mem.indexOfScalar(usize, &widths, width) == null or options.count == widths.len) return error.InvalidArguments;
		if (options.count > 0 and width <= options.sizes[options.count - 1]) return error.InvalidArguments;
		options.sizes[options.count] = width;
		options.count += 1;
	}
	return options;
}

const Method = enum { knuth, burnikel_ziegler_byte_fallback, burnikel_ziegler_chunk_fallback, burnikel_ziegler_cutoff128, production };
pub const Comparison = enum { kernels, fallbacks, cutoffs };
fn comparisonMethods(comparison: Comparison) [2]Method {
	return switch (comparison) {
		.kernels => .{ .knuth, .burnikel_ziegler_byte_fallback },
		.fallbacks => .{ .burnikel_ziegler_byte_fallback, .burnikel_ziegler_chunk_fallback },
		.cutoffs => .{ .burnikel_ziegler_chunk_fallback, .burnikel_ziegler_cutoff128 },
	};
}

test "division comparison selects the intended algorithm pairs" {
	const expected = [_][2]Method{ .{.knuth,.burnikel_ziegler_byte_fallback}, .{.burnikel_ziegler_byte_fallback,.burnikel_ziegler_chunk_fallback}, .{.burnikel_ziegler_chunk_fallback,.burnikel_ziegler_cutoff128} };
	for (std.enums.values(Comparison), expected) |comparison, methods| {
		try std.testing.expectEqualSlices(Method, &methods, &comparisonMethods(comparison));
	}
}
const Timing = struct { cpu_ns: f64, wall_ns: f64 };
const Sample = struct { cpu_ns: [2]f64, wall_ns: [2]f64 };

fn pairedSample(state: anytype, comptime batch: anytype, methods: [2]Method, count: usize, repeats: usize, round: usize) !Sample {
	if (count == 0 or count % 2 != 0 or repeats == 0) return error.InvalidArguments;
	const order: [4]usize = if (round % 2 == 0) .{0,1,1,0} else .{1,0,0,1};
	var sample: Sample = .{ .cpu_ns = @splat(0), .wall_ns = @splat(0) };
	for (order, 0..) |method, position| {
		const timing = try batch(state, methods[method], if (position < 2) 0 else count / 2, count / 2, repeats);
		sample.cpu_ns[method] += timing.cpu_ns;
		sample.wall_ns[method] += timing.wall_ns;
	}
	const operations: f64 = @floatFromInt(count * repeats);
	for (&sample.cpu_ns, &sample.wall_ns) |*cpu, *wall| { cpu.* /= operations; wall.* /= operations; }
	return sample;
}

pub fn timedBatch(work: anytype, clock: anytype, method: anytype, start: usize, count: usize, repeats: usize) !Timing {
	if (count == 0 or repeats == 0) return error.InvalidArguments;
	const wall_start = try clock.read(.MONOTONIC);
	const cpu_start = try clock.read(.PROCESS_CPUTIME_ID);
	for (start .. start + count) |index| for (0..repeats) |_| {
		try work.run(method, index);
		std.mem.doNotOptimizeAway(work);
	};
	const cpu_end = try clock.read(.PROCESS_CPUTIME_ID);
	const wall_end = try clock.read(.MONOTONIC);
	if (cpu_end <= cpu_start or wall_end <= wall_start) return error.ClockFailed;
	return .{ .cpu_ns = @floatFromInt(cpu_end - cpu_start), .wall_ns = @floatFromInt(wall_end - wall_start) };
}

test "paired division batches cover each input equally and cancel linear drift" {
	const Fake = struct {
		position: usize = 0,
		calls: [4]Method = undefined,
		visits: [5][8]usize = @splat(@splat(0)),
		fn batch(self: *@This(), method: Method, start: usize, count: usize, repeats: usize) !Timing {
			const index: usize = @intFromEnum(method);
			for (start .. start + count) |i| self.visits[index][i] += repeats;
			self.calls[self.position] = method;
			const duration: f64 = @floatFromInt((100 - 20 * index + 10 * self.position) * count * repeats);
			self.position += 1;
			return .{ .cpu_ns = duration, .wall_ns = duration + @as(f64, @floatFromInt(5 * count * repeats)) };
		}
	};
	const orders = [_][4]Method{
		.{.knuth,.burnikel_ziegler_byte_fallback,.burnikel_ziegler_byte_fallback,.knuth}, .{.burnikel_ziegler_byte_fallback,.knuth,.knuth,.burnikel_ziegler_byte_fallback},
		.{.burnikel_ziegler_byte_fallback,.burnikel_ziegler_chunk_fallback,.burnikel_ziegler_chunk_fallback,.burnikel_ziegler_byte_fallback},
		.{.burnikel_ziegler_chunk_fallback,.burnikel_ziegler_byte_fallback,.burnikel_ziegler_byte_fallback,.burnikel_ziegler_chunk_fallback},
		.{.burnikel_ziegler_chunk_fallback,.burnikel_ziegler_cutoff128,.burnikel_ziegler_cutoff128,.burnikel_ziegler_chunk_fallback},
		.{.burnikel_ziegler_cutoff128,.burnikel_ziegler_chunk_fallback,.burnikel_ziegler_chunk_fallback,.burnikel_ziegler_cutoff128},
	};
	const pairs = [_][2]Method{ .{.knuth,.burnikel_ziegler_byte_fallback}, .{.burnikel_ziegler_byte_fallback,.burnikel_ziegler_chunk_fallback}, .{.burnikel_ziegler_chunk_fallback,.burnikel_ziegler_cutoff128} };
	const expected_cpu = [_][2]f64{ .{115,95}, .{95,75}, .{75,55} };
	const expected_wall = [_][2]f64{ .{120,100}, .{100,80}, .{80,60} };
	for (orders, 0..) |order, round| {
		const methods = pairs[round / 2];
		var state: Fake = .{};
		const sample = try pairedSample(&state, Fake.batch, methods, 8, 3, round);
		try std.testing.expectEqualSlices(f64, &expected_cpu[round / 2], &sample.cpu_ns);
		try std.testing.expectEqualSlices(f64, &expected_wall[round / 2], &sample.wall_ns);
		try std.testing.expectEqualSlices(Method, &order, &state.calls);
		for (state.visits, 0..) |visits, method| {
			const expected_visits: [8]usize = @splat(if (method == round / 2 or method == round / 2 + 1) 3 else 0);
			try std.testing.expectEqualSlices(usize, &expected_visits, &visits);
		}
	}
	var state: Fake = .{};
	const methods: [2]Method = .{.knuth,.burnikel_ziegler_byte_fallback};
	for ([_]usize{0,1,7}) |count| try std.testing.expectError(error.InvalidArguments, pairedSample(&state, Fake.batch, methods, count, 3, 0));
	try std.testing.expectError(error.InvalidArguments, pairedSample(&state, Fake.batch, methods, 8, 0, 0));
	const Failure = struct {
		fn batch(_: void, _: Method, _: usize, _: usize, _: usize) error{Injected}!Timing { return error.Injected; }
	};
	try std.testing.expectError(error.Injected, pairedSample({}, Failure.batch, methods, 8, 1, 0));
}

test "division timing checks work counts clock resolution and failures" {
	const Work = struct {
		calls: usize = 0, fail: bool = false,
		fn run(self: *@This(), method: Method, index: usize) !void {
			if (self.fail) return error.IncorrectWork;
			try std.testing.expectEqual(Method.knuth, method);
			try std.testing.expectEqual(@as(usize, 2) + self.calls / 3, index);
			self.calls += 1;
		}
	};
	const Clock = struct {
		index: usize = 0, times: [4]u64 = .{100,200,600,900}, fail: bool = false,
		fn read(self: *@This(), _: std.c.CLOCK) !u64 {
			if (self.fail) return error.InjectedClock;
			defer self.index += 1;
			return self.times[self.index];
		}
	};
	var work: Work = .{}; var clock: Clock = .{};
	const timing = try timedBatch(&work, &clock, .knuth, 2, 4, 3);
	try std.testing.expectEqual(@as(usize, 12), work.calls);
	try std.testing.expectEqual(@as(f64, 400), timing.cpu_ns);
	try std.testing.expectEqual(@as(f64, 800), timing.wall_ns);
	work = .{}; clock = .{};
	try std.testing.expectError(error.InvalidArguments, timedBatch(&work, &clock, .knuth, 2, 0, 3));
	try std.testing.expectError(error.InvalidArguments, timedBatch(&work, &clock, .knuth, 2, 4, 0));
	work = .{ .fail = true }; clock = .{};
	try std.testing.expectError(error.IncorrectWork, timedBatch(&work, &clock, .knuth, 2, 4, 3));
	work = .{}; clock = .{ .fail = true };
	try std.testing.expectError(error.InjectedClock, timedBatch(&work, &clock, .knuth, 2, 4, 3));
	for ([_][4]u64{ .{100,200,200,900}, .{100,200,199,900}, .{100,200,600,100}, .{100,200,600,99} }) |times| {
		work = .{}; clock = .{ .times = times };
		try std.testing.expectError(error.ClockFailed, timedBatch(&work, &clock, .knuth, 2, 4, 3));
	}
}

const Case = struct { dividend: []u8, divisor: []u8, expected_q: []u8, expected_r: []u8 };

fn nativeBatch(fixture: *Fixture, method: Method, start: usize, count: usize, repeats: usize) !Timing {
	const Clock = struct {
		fn read(_: *@This(), kind: std.c.CLOCK) !u64 { return @import("immediate_add.zig").now(kind); }
	};
	var clock: Clock = .{};
	return timedBatch(fixture, &clock, method, start, count, repeats);
}

pub fn run(init: std.process.Init, args: []const []const u8, comparison: Comparison) !void {
	const options = try parse(args);
	const methods = comparisonMethods(comparison);
	const case_count = 256;
	const repeats = 4;
	const Component = struct { method: []const u8, cpu_ns: [5]f64, wall_ns: [5]f64 };
	const Row = struct {
		size: usize, fixture_count: usize = case_count, iterations: usize = case_count * repeats, warmup_cases: usize = 2 * case_count,
		samples: struct { cpu_ns: [5]f64, wall_ns: [5]f64 }, components: [2]Component,
	};
	var rows: [widths.len]Row = undefined;
	for (options.sizes[0..options.count], 0..) |width, index| {
		var fixture = try Fixture.init(std.heap.c_allocator, width, case_count);
		defer fixture.deinit();
		for (0..case_count) |i| {
			for (methods) |method| try fixture.run(method, i);
		}
		var row: Row = .{ .size = width, .samples = undefined, .components = .{
			.{ .method = @tagName(methods[0]), .cpu_ns = undefined, .wall_ns = undefined },
			.{ .method = @tagName(methods[1]), .cpu_ns = undefined, .wall_ns = undefined },
		} };
		for (0..5) |round| {
			const sample = try pairedSample(&fixture, nativeBatch, methods, case_count, repeats, round);
			for (&row.components, 0..) |*component, method| {
				component.cpu_ns[round] = sample.cpu_ns[method];
				component.wall_ns[round] = sample.wall_ns[method];
			}
			row.samples.cpu_ns[round] = (sample.cpu_ns[0] + sample.cpu_ns[1]) / 2;
			row.samples.wall_ns[round] = (sample.wall_ns[0] + sample.wall_ns[1]) / 2;
		}
		rows[index] = row;
	}
	const report = .{
		.schema = "performance-measurement/v1", .correct = true, .build_mode = "ReleaseFast",
		.compiler = @import("builtin").zig_version_string,
		.method = switch (comparison) {
			.kernels => "division-paired-kernels-v1",
			.fallbacks => "division-paired-fallbacks-v1",
			.cutoffs => "division-paired-cutoffs-v1",
		},
		.comparison = @tagName(comparison),
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID", .wall_clock = "CLOCK_MONOTONIC",
		.seed_usage = "0xB2D151A5 + divisor_bytes*257 + case_index; all eight normalization shifts; engine seed does not alter inputs",
		.normalization = "ABBA/BAAB half-pool batches; four repetitions per case; 1024 verified divisions per method/sample; primary averages both methods; no subtraction",
		.operation = "2:1 dividend/divisor magnitude byte widths; row size is divisor bytes; complete byte-wrapper setup, full quotient/remainder and canary checks",
		.allocator_coverage = "fixtures and GMP outside timing; arithmetic uses one reset arena with retained capacity, warmed for both methods; reset and output poisoning included; cold allocation unmeasured",
		.rows = rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), report, .{});
	try std.Io.File.stdout().writeStreamingAll(init.io, json);
	try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

const Fixture = struct {
	cases: []Case,
	arena: std.heap.ArenaAllocator,
	scratch: std.heap.ArenaAllocator,
	quotient: []u8,
	remainder: []u8,
	fn init(parent: std.mem.Allocator, width: usize, count: usize) !Fixture {
		if (std.mem.indexOfScalar(usize, &widths, width) == null or count == 0 or count > 256) return error.InvalidArguments;
		var arena = std.heap.ArenaAllocator.init(parent);
		errdefer arena.deinit();
		const allocator = arena.allocator();
		const cases = try allocator.alloc(Case, count);
		for (cases, 0..) |*case, index| {
			const dividend = try allocator.alloc(u8, 2 * width);
			const divisor = try allocator.alloc(u8, width);
			const expected_q = try allocator.alloc(u8, dividend.len);
			const expected_r = try allocator.alloc(u8, divisor.len);
			var rng = std.Random.DefaultPrng.init(0xB2D1_51A5 + width * 257 + index);
			rng.random().bytes(dividend); rng.random().bytes(divisor);
			if (index % 16 == 0) { @memset(dividend, 255); @memset(divisor, 255); }
			dividend[dividend.len - 1] |= 0x80;
			const top = @as(u8, 1) << @as(u3, @intCast(index % 8));
			divisor[width - 1] = (divisor[width - 1] & (top - 1)) | top;
			var a: gmp.Z = undefined; gmp.__gmpz_init(&a); defer gmp.__gmpz_clear(&a);
			var b: gmp.Z = undefined; gmp.__gmpz_init(&b); defer gmp.__gmpz_clear(&b);
			var q: gmp.Z = undefined; gmp.__gmpz_init(&q); defer gmp.__gmpz_clear(&q);
			var r: gmp.Z = undefined; gmp.__gmpz_init(&r); defer gmp.__gmpz_clear(&r);
			gmp.__gmpz_import(&a, dividend.len, -1, 1, 0, 0, dividend.ptr);
			gmp.__gmpz_import(&b, divisor.len, -1, 1, 0, 0, divisor.ptr);
			gmp.__gmpz_tdiv_qr(&q, &r, &a, &b);
			var q_len: usize = 0; var r_len: usize = 0;
			_ = gmp.__gmpz_export(expected_q.ptr, &q_len, -1, 1, 0, 0, &q);
			_ = gmp.__gmpz_export(expected_r.ptr, &r_len, -1, 1, 0, 0, &r);
			case.* = .{ .dividend = dividend, .divisor = divisor, .expected_q = expected_q[0..q_len], .expected_r = expected_r[0..r_len] };
		}
		const quotient = try allocator.alloc(u8, 2 * width + 2);
		const remainder = try allocator.alloc(u8, width + 2);
		return .{ .cases = cases, .arena = arena, .scratch = std.heap.ArenaAllocator.init(parent), .quotient = quotient, .remainder = remainder };
	}
	fn run(self: *@This(), method: Method, index: usize) !void {
		if (!self.scratch.reset(.retain_capacity)) return error.OutOfMemory;
		@memset(self.quotient, 0xa5); @memset(self.remainder, 0xa5);
		const case = &self.cases[index];
		const q = self.quotient[1 .. self.quotient.len - 1];
		const r = self.remainder[1 .. self.remainder.len - 1];
		const q_len, const r_len = switch (method) {
			.knuth => blk: {
				const got = try tier3.divModKnuthU64Bytes(case.dividend, case.dividend.len, case.divisor, case.divisor.len, q, r, self.scratch.allocator());
				break :blk .{ got.q_len, got.r_len };
			},
			.burnikel_ziegler_byte_fallback => blk: {
				const got = try tier3.divModBurnikelZieglerByteFallback(case.dividend, case.dividend.len, case.divisor, case.divisor.len, q, r, self.scratch.allocator());
				break :blk .{ got.q_len, got.r_len };
			},
			.burnikel_ziegler_chunk_fallback => blk: {
				const got = try tier3.divModBurnikelZieglerChunkFallback(case.dividend, case.dividend.len, case.divisor, case.divisor.len, q, r, self.scratch.allocator());
				break :blk .{ got.q_len, got.r_len };
			},
			.burnikel_ziegler_cutoff128 => blk: {
				const got = try tier3.divModBurnikelZieglerCutoff128(case.dividend, case.dividend.len, case.divisor, case.divisor.len, q, r, self.scratch.allocator());
				break :blk .{ got.q_len, got.r_len };
			},
			.production => blk: {
				const got = try tier3.divModBurnikelZiegler(case.dividend, case.dividend.len, case.divisor, case.divisor.len, q, r, self.scratch.allocator());
				break :blk .{ got.q_len, got.r_len };
			},
		};
		if (!std.mem.eql(u8, q[0..q_len], case.expected_q) or !std.mem.eql(u8, r[0..r_len], case.expected_r)) return error.IncorrectWork;
		if (self.quotient[0] != 0xa5 or self.quotient[self.quotient.len - 1] != 0xa5 or self.remainder[0] != 0xa5 or self.remainder[self.remainder.len - 1] != 0xa5) return error.CanaryDamaged;
	}
	fn deinit(self: *@This()) void {
		tier3.releaseVnScratch();
		self.scratch.deinit();
		self.arena.deinit();
	}
};

test "paired division fixtures release partial allocations" {
	const FailureCase = struct {
		fn run(allocator: std.mem.Allocator) !void {
			var fixture = try Fixture.init(allocator, 128, 2);
			defer fixture.deinit();
			inline for (std.enums.values(Method)) |method| try fixture.run(method, 0);
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.run, .{});
}

test "paired division fixtures verify all methods and reject a corrupt GMP quotient" {
	for (widths) |width| {
		var fixture = try Fixture.init(std.testing.allocator, width, 8);
		defer fixture.deinit();
		for (0..fixture.cases.len) |i| {
			inline for (std.enums.values(Method)) |method| try fixture.run(method, i);
			fixture.cases[i].expected_q[0] ^= 1;
			inline for (std.enums.values(Method)) |method| try std.testing.expectError(error.IncorrectWork, fixture.run(method, i));
		}
	}
}

test "paired division sizes classify the bounded width set and ordered lists" {
	var accepted: [4100]bool = @splat(false);
	var expected: [4100]bool = @splat(false);
	for (widths) |width| expected[width] = true;
	for (0..accepted.len) |width| {
		var buffer: [24]u8 = undefined;
		const text = try std.fmt.bufPrint(&buffer, "{d}", .{width});
		accepted[width] = if (parse(&.{text})) |_| true else |_| false;
	}
	try std.testing.expectEqualSlices(bool, &expected, &accepted);
	const options = try parse(&.{"8,9,16,31,32,63,64,65,127,128,129,256,512,1024,2048,4096"});
	try std.testing.expectEqualSlices(usize, &widths, options.sizes[0..options.count]);
	for ([_][]const u8{ "", "0", "64,", "64,64", "128,64", "-1", "x", "18446744073709551616" }) |invalid| {
		try std.testing.expectError(error.InvalidArguments, parse(&.{invalid}));
	}
	try std.testing.expectError(error.InvalidArguments, parse(&.{}));
	try std.testing.expectError(error.InvalidArguments, parse(&.{"64", "128"}));
}
