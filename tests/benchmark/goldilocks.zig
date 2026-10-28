//! Contemporaneous Stockham, paired radix-2 and fused Goldilocks measurements.
const std = @import("std");
const blip = @import("blip_mp");
const fft = blip.fft;
const Layout = enum { stockham, paired, fused, truncated, hybrid };
const Mode = enum { product, passes, truncated, hybrid };
fn layouts(mode: Mode) [3]Layout {
	if (mode == .hybrid) return .{ .fused, .truncated, .hybrid };
	return if (mode == .truncated) .{ .stockham, .fused, .truncated } else .{ .stockham, .paired, .fused };
}
const Options = struct { mode: Mode, sizes: [16]usize, count: usize, iterations: usize };
const Timing = struct { cpu: u64, wall: u64 };
const Sample = struct { cpu: [3]f64, wall: [3]f64 };

pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) {
		try std.Io.File.stderr().writeStreamingAll(init.io, "\x1b[33mDEBUG BUILD!\x1b[0m Performance probe requires ReleaseFast.\n");
		return error.UnoptimizedBuild;
	}
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	const options = try parse(args[1..]);
	const Component = struct { layout: []const u8, cpu_ns: [6]f64, wall_ns: [6]f64 };
	const Row = struct {
		size: usize, transform_length: usize, iterations: usize,
		samples: struct { cpu_ns: [6]f64, wall_ns: [6]f64 }, components: [3]Component,
	};
	var rows: [16]Row = undefined;
	for (options.sizes[0..options.count], 0..) |size, index| {
		var fixture = try Fixture.init(std.heap.c_allocator, options.mode, size);
		defer fixture.deinit();
		var row: Row = .{ .size = size, .transform_length = fixture.n, .iterations = options.iterations, .samples = undefined, .components = undefined };
		for (layouts(options.mode), 0..) |layout, i| {
			try fixture.run(layout);
			row.components[i] = .{ .layout = @tagName(layout), .cpu_ns = undefined, .wall_ns = undefined };
		}
		for (0..6) |round| {
			const sample = try balancedSample(&fixture, timedBatch, layouts(options.mode), options.iterations, round);
			var cpu: f64 = 0;
			var wall: f64 = 0;
			for (&row.components, 0..) |*component, i| {
				component.cpu_ns[round] = sample.cpu[i]; component.wall_ns[round] = sample.wall[i];
				cpu += sample.cpu[i]; wall += sample.wall[i];
			}
			row.samples.cpu_ns[round] = cpu / 3; row.samples.wall_ns[round] = wall / 3;
		}
		rows[index] = row;
	}
	const report = .{
		.schema = "performance-measurement/v1", .correct = true, .build_mode = "ReleaseFast",
		.compiler = @import("builtin").zig_version_string,
		.method = switch (options.mode) { .hybrid => "gold-hybrid-products-v1", .truncated => "gold-truncated-products-v1", else => "gold-paired-layouts-v1" }, .mode = @tagName(options.mode),
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID", .wall_clock = "CLOCK_MONOTONIC",
		.seed_usage = "fixed 0x601D_B3AC; identical inputs across layouts; engine seed does not alter inputs",
		.normalization = "rotating ABCCBA batches; primary samples average all layouts per operation; components preserve individual means; no subtraction",
		.operation = if (options.mode != .passes) "complete product with packing, twiddle preparation, carry output and GMP-derived byte comparison" else "forward/inverse pair, unscaled, including input restore and complete canonical-residue comparison",
		.allocator_coverage = "c_allocator arena; fixture and scratch allocation outside timing, reused across all layouts",
		.warmup_per_layout = 1, .rows = rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), report, .{});
	try std.Io.File.stdout().writeStreamingAll(init.io, json);
	try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
fn validSize(mode: Mode, size: usize) bool {
	return size >= 64 and size <= fft.GOLD_MAX_FFT_COMBINED_LEN / 2 and
		(mode != .passes or size & (size - 1) == 0);
}
fn parse(args: []const []const u8) !Options {
	if (args.len != 3) return error.InvalidArguments;
	var result: Options = .{
		.mode = std.meta.stringToEnum(Mode, args[0]) orelse return error.InvalidArguments,
		.sizes = undefined, .count = 0,
		.iterations = std.fmt.parseInt(usize, args[2], 10) catch return error.InvalidArguments,
	};
	if (result.iterations == 0 or result.iterations > 64) return error.InvalidArguments;
	var sizes = std.mem.splitScalar(u8, args[1], ',');
	while (sizes.next()) |text| {
		const size = std.fmt.parseInt(usize, text, 10) catch return error.InvalidArguments;
		if (result.count == result.sizes.len or !validSize(result.mode, size)) return error.InvalidArguments;
		if (result.count > 0 and size <= result.sizes[result.count - 1]) return error.InvalidArguments;
		result.sizes[result.count] = size;
		result.count += 1;
	}
	return result;
}
fn balancedSample(state: anytype, comptime batch: anytype, methods: [3]Layout, iterations: usize, round: usize) !Sample {
	var sample: Sample = .{ .cpu = @splat(0), .wall = @splat(0) };
	for ([_]usize{0, 1, 2, 2, 1, 0}) |position| {
		const index = (position + round % 3) % 3;
		const duration = try batch(state, methods[index], iterations);
		sample.cpu[index] += @floatFromInt(duration.cpu);
		sample.wall[index] += @floatFromInt(duration.wall);
	}
	const count: f64 = @floatFromInt(2 * iterations);
	for (&sample.cpu, &sample.wall) |*cpu, *wall| { cpu.* /= count; wall.* /= count; }
	return sample;
}

fn timedBatch(fixture: *Fixture, layout: Layout, iterations: usize) !Timing {
	const now = @import("immediate_add.zig").now;
	const wall_start = try now(.MONOTONIC);
	const cpu_start = try now(.PROCESS_CPUTIME_ID);
	for (0..iterations) |_| {
		try fixture.run(layout);
		std.mem.doNotOptimizeAway(fixture);
	}
	const cpu_end = try now(.PROCESS_CPUTIME_ID);
	const wall_end = try now(.MONOTONIC);
	if (cpu_end <= cpu_start or wall_end <= wall_start) return error.ClockFailed;
	return .{ .cpu = cpu_end - cpu_start, .wall = wall_end - wall_start };
}

const Fixture = struct {
	arena: std.heap.ArenaAllocator,
	mode: Mode,
	n: usize,
	a: []u8, b: []u8, out: []u8,
	pa: []u8, pb: []u8, tw_fwd: []u8, tw_inv: []u8, scratch: []u8,
	expected: []u8,
	fn init(parent: std.mem.Allocator, mode: Mode, size: usize) !Fixture {
		if (!validSize(mode, size)) return error.InvalidArguments;
		var arena = std.heap.ArenaAllocator.init(parent);
		errdefer arena.deinit();
		const allocator = arena.allocator();
		var n: usize = 1;
		while (n < size) n <<= 1;
		const bytes = n * fft.gold_residue.slot_bytes;
		const work = try allocator.alloc(u8, 4 * bytes);
		@memset(work, 0xa5);
		const pa = work[0..bytes];
		const tw_fwd = work[2 * bytes .. 5 * bytes / 2];
		const tw_inv = work[5 * bytes / 2 .. 3 * bytes];
		const a = try allocator.alloc(u8, if (mode != .passes) size else bytes);
		const b = try allocator.alloc(u8, if (mode != .passes) size else 0);
		const out = if (mode != .passes) try allocator.alloc(u8, 2 * size) else pa;
		var expected = try allocator.alloc(u8, out.len);
		var rng = std.Random.DefaultPrng.init(0x601D_B3AC);
		if (mode != .passes) {
			rng.random().bytes(a); rng.random().bytes(b);
			a[size - 1] |= 1; b[size - 1] |= 1;
			const length = try @import("gmp.zig").product(a, b, expected);
			expected = expected[0..length];
		} else {
			@memset(a, 0xa5); @memset(expected, 0xa5);
			const root = fft.goldNthRootOfUnity(n);
			const inverse_root = fft.goldInvMod(root);
			var forward: u64 = 1;
			var inverse: u64 = 1;
			for (0..n / 2) |i| {
				fft.gold_residue.write(tw_fwd, i, forward);
				fft.gold_residue.write(tw_inv, i, inverse);
				forward = fft.goldMulMod(forward, root);
				inverse = fft.goldMulMod(inverse, inverse_root);
			}
			for (0..n) |i| {
				const value = switch (i) { 0 => 0, 1 => 1, 2 => fft.GOLDILOCKS_P - 1, else => rng.random().uintLessThan(u64, fft.GOLDILOCKS_P) };
				fft.gold_residue.write(a, i, value);
				fft.gold_residue.write(expected, i, @intCast((@as(u128, value) * n) % fft.GOLDILOCKS_P));
			}
		}
		return .{ .arena = arena, .mode = mode, .n = n, .a = a, .b = b, .out = out, .expected = expected,
			.pa = pa, .pb = work[bytes .. 2 * bytes], .tw_fwd = tw_fwd, .tw_inv = tw_inv, .scratch = work[3 * bytes ..] };
	}
	fn run(self: *@This(), layout: Layout) !void {
		inline for (std.enums.values(Layout)) |method| {
			if (layout == method) {
				if (self.mode != .passes) {
					const len = if (method == .hybrid)
						fft.goldMulMagnitudesTruncatedFused(self.a, self.b, self.out, self.pa, self.pb, self.tw_fwd, self.tw_inv)
					else if (method == .truncated)
						fft.goldMulMagnitudesTruncated(self.a, self.b, self.out, self.pa, self.pb, self.tw_fwd, self.tw_inv)
					else fft.goldMulMagnitudesWithLayout(@enumFromInt(@intFromEnum(method)), self.a, self.b, self.out, self.pa, self.pb, self.tw_fwd, self.tw_inv, if (method == .stockham) self.scratch else &.{});
					if (!std.mem.eql(u8, self.expected, self.out[0..len])) return error.IncorrectWork;
				} else {
					if (method == .truncated or method == .hybrid) return error.InvalidArguments;
					@memcpy(self.pa, self.a);
					if (method == .stockham) {
						fft.goldNttStockham(self.pa, self.scratch, self.tw_fwd);
						fft.goldNttStockham(self.pa, self.scratch, self.tw_inv);
					} else {
						fft.goldNttForwardPaired(method == .fused, self.pa, self.tw_fwd);
						fft.goldNttInversePaired(method == .fused, self.pa, self.tw_inv);
					}
					for (0..self.n) |i| if (!std.mem.eql(u8, fft.gold_residue.encoded(self.expected, i), fft.gold_residue.encoded(self.pa, i))) return error.IncorrectWork;
				}
				return;
			}
		}
		unreachable;
	}
	fn deinit(self: *@This()) void { self.arena.deinit(); }
};

test "Goldilocks probe classifies modes sizes and bounded iteration counts" {
	for (std.enums.values(Mode)) |mode| {
		const options = try parse(&.{ @tagName(mode), "64,4096,262144", "2" });
		try std.testing.expectEqual(mode, options.mode);
		try std.testing.expectEqualSlices(usize, &.{64, 4096, 262144}, options.sizes[0..options.count]);
		try std.testing.expectEqual(@as(usize, 2), options.iterations);
		for ([_][]const u8{"", "0", "63", "262145", "64,", "64,64", "128,64", "x"}) |sizes| {
			try std.testing.expectError(error.InvalidArguments, parse(&.{@tagName(mode), sizes, "2"}));
		}
		for ([_][]const u8{"", "0", "-1", "65", "x"}) |iterations| {
			try std.testing.expectError(error.InvalidArguments, parse(&.{@tagName(mode), "64", iterations}));
		}
	}
	const values = [_][]const u8{"64", "65", "127", "128", "129", "262144"};
	var accepted: [values.len]bool = undefined;
	for (values, 0..) |size, i| accepted[i] = if (parse(&.{"passes", size, "1"})) |_| true else |_| false;
	try std.testing.expectEqualSlices(bool, &.{true, false, false, true, false, true}, &accepted);
	for (values) |size| _ = try parse(&.{"product", size, "1"});
	for (values) |size| _ = try parse(&.{"truncated", size, "1"});
	for (values) |size| _ = try parse(&.{"hybrid", size, "1"});
	try std.testing.expectError(error.InvalidArguments, parse(&.{"unknown", "64", "1"}));
	try std.testing.expectError(error.InvalidArguments, parse(&.{"product", "64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80", "1"}));
	try std.testing.expectError(error.InvalidArguments, parse(&.{}));
}

test "Goldilocks batches balance three methods and cancel linear drift" {
	const Fake = struct {
		position: usize = 0,
		calls: [6]Layout = undefined,
		fn batch(self: *@This(), layout: Layout, count: usize) !Timing {
			const index: usize = @intFromEnum(layout);
			const duration: u64 = 100 - 20 * index + 10 * self.position;
			self.calls[self.position] = layout;
			self.position += 1;
			return .{.cpu = duration * count, .wall = (duration + 5) * count};
		}
	};
	const orders = [_][6]Layout{
		.{.stockham, .paired, .fused, .fused, .paired, .stockham},
		.{.paired, .fused, .stockham, .stockham, .fused, .paired},
		.{.fused, .stockham, .paired, .paired, .stockham, .fused},
	};
	for (orders, 0..) |order, round| {
		var fake: Fake = .{};
		const sample = try balancedSample(&fake, Fake.batch, layouts(.product), 3, round);
		try std.testing.expectEqualSlices(f64, &.{125, 105, 85}, &sample.cpu);
		try std.testing.expectEqualSlices(f64, &.{130, 110, 90}, &sample.wall);
		try std.testing.expectEqualSlices(Layout, &order, &fake.calls);
		try std.testing.expectEqual(@as(usize, 6), fake.position);
	}
}

test "Goldilocks batches propagate errors" {
	const Failure = struct {
		fn batch(_: void, _: Layout, _: usize) error{Injected}!Timing { return error.Injected; }
	};
	try std.testing.expectError(error.Injected, balancedSample({}, Failure.batch, layouts(.product), 1, 0));
}

test "Goldilocks fixtures verify products and passes and reject corrupted results" {
	for (std.enums.values(Mode)) |mode| {
		for ([_]usize{64, 65, 128, 257, 4096}) |size| {
			if (mode == .passes and size & (size - 1) != 0) continue;
			var fixture = try Fixture.init(std.testing.allocator, mode, size);
			defer fixture.deinit();
			for (layouts(mode)) |layout| try fixture.run(layout);
			fixture.expected[0] ^= 1;
			for (layouts(mode)) |layout| try std.testing.expectError(error.IncorrectWork, fixture.run(layout));
		}
	}
}

test "Goldilocks fixtures clean up every allocation failure" {
	const Case = struct {
		fn run(allocator: std.mem.Allocator) anyerror!void {
			for (std.enums.values(Mode)) |mode| {
				var fixture = try Fixture.init(allocator, mode, 64);
				defer fixture.deinit();
				for (layouts(mode)) |layout| try fixture.run(layout);
			}
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
