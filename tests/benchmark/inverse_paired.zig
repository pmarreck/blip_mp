//! Exact-width inverse comparison around the recursive entry threshold.
const std = @import("std");
const blip = @import("blip_mp");
const inverse = @import("inverse.zig");
const methods = [2]inverse.Algorithm{ .hgcd, .recursive };
const Options = struct { sizes: [3]usize, count: usize };

fn parse(args: []const []const u8) !Options {
	if (args.len != 1) return error.InvalidArguments;
	var options: Options = .{ .sizes = undefined, .count = 0 };
	var parts = std.mem.splitScalar(u8,args[0],',');
	while (parts.next()) |part| {
		const bits = std.fmt.parseInt(usize,part,10) catch return error.InvalidArguments;
		if (bits < 4095 or bits > 4097 or options.count == 3) return error.InvalidArguments;
		if (options.count > 0 and bits <= options.sizes[options.count-1]) return error.InvalidArguments;
		options.sizes[options.count] = bits; options.count += 1;
	}
	return options;
}

const Pool = struct {
	allocator: std.mem.Allocator, cases: []inverse.Fixture, result: blip.Mp,
	fn init(allocator: std.mem.Allocator, bits: usize, count: usize) !Pool {
		if (bits < 4095 or bits > 4097 or count == 0 or count > 16) return error.InvalidArguments;
		const cases = try allocator.alloc(inverse.Fixture,count);
		errdefer allocator.free(cases);
		var initialized: usize = 0;
		errdefer for (cases[0..initialized]) |*fixture| fixture.deinit();
		for (cases,0..) |*fixture,index| {
			fixture.* = try inverse.Fixture.initExactCase(allocator,bits,index);
			initialized += 1;
		}
		return .{ .allocator = allocator, .cases = cases, .result = blip.Mp.init(allocator) };
	}
	fn deinit(self: *@This()) void {
		for (self.cases) |*fixture| fixture.deinit();
		self.allocator.free(self.cases); self.result.deinit();
	}
	pub fn run(self: *@This(), method: inverse.Algorithm, index: usize) !void {
		const fixture = &self.cases[index];
		const exists = try inverse.run(method,&self.result,fixture);
		try inverse.verify(&self.result,exists,fixture.expected,fixture.has_inverse);
	}
};

test "paired inverse widths classify the complete bounded set" {
	var actual: [4100]bool = @splat(false);
	var wanted: [4100]bool = @splat(false);
	for (4095..4098) |bits| wanted[bits] = true;
	for (0..actual.len) |bits| {
		var buffer: [32]u8 = undefined;
		const argument = try std.fmt.bufPrint(&buffer,"{d}",.{bits});
		if (parse(&.{argument})) |options| {
			actual[bits] = true;
			try std.testing.expectEqual(@as(usize,1),options.count);
			try std.testing.expectEqual(bits,options.sizes[0]);
		} else |err| try std.testing.expectEqual(error.InvalidArguments,err);
	}
	try std.testing.expectEqualSlices(bool,&wanted,&actual);
	const options = try parse(&.{"4095,4096,4097"});
	try std.testing.expectEqualSlices(usize,&.{4095,4096,4097},options.sizes[0..options.count]);
	for ([_][]const u8{"",",4095","4095,","4095,4095","4097,4096","4096,x","-1","18446744073709551615"}) |arg| try std.testing.expectError(error.InvalidArguments,parse(&.{arg}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{"4096","4097"}));
}

test "paired inverse pool verifies both algorithms and rejects corrupted reference" {
	defer blip.tier3.releaseBzArena(); defer blip.tier3.releaseMulScratch();
	defer blip.tier3.releaseDivScratch(); defer blip.tier3.releaseVnScratch();
	var pool = try Pool.init(std.testing.allocator,4096,16);
	defer pool.deinit();
	for (methods) |method| for ([_]usize{0,14,15}) |index| try pool.run(method,index);
	pool.cases[14].expected[0] ^= 1;
	for (methods) |method| try std.testing.expectError(error.IncorrectWork,pool.run(method,14));
	for ([_]usize{0,17}) |count| try std.testing.expectError(error.InvalidArguments,Pool.init(std.testing.allocator,4096,count));
}

test "paired inverse pool releases every partial construction" {
	const Check = struct {
		fn run(allocator: std.mem.Allocator) !void {
			var pool = try Pool.init(allocator,4096,2); defer pool.deinit();
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator,Check.run,.{});
}

const timing = @import("division_crossover.zig");
fn nativeBatch(pool: *Pool, method: inverse.Algorithm, start: usize, count: usize, repeats: usize) !struct { cpu_ns: f64, wall_ns: f64 } {
	const Clock = struct {
		pub fn read(_: *@This(), kind: std.c.CLOCK) !u64 { return @import("immediate_add.zig").now(kind); }
	};
	var clock: Clock = .{};
	const duration = try timing.timedBatch(pool,&clock,method,start,count,repeats);
	return .{ .cpu_ns = duration.cpu_ns, .wall_ns = duration.wall_ns };
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
	const options = try parse(args);
	defer blip.tier3.releaseBzArena(); defer blip.tier3.releaseMulScratch();
	defer blip.tier3.releaseDivScratch(); defer blip.tier3.releaseVnScratch();
	const Component = struct { method: []const u8, cpu_ns: [6]f64, wall_ns: [6]f64 };
	const Row = struct {
		size: usize, modulus_bits: usize, fixture_count: usize = 16, iterations: usize = 16, warmup_cases: usize = 32,
		inverse_count: usize, samples: struct { cpu_ns: [6]f64, wall_ns: [6]f64 }, components: [2]Component,
	};
	var rows: [3]Row = undefined;
	for (options.sizes[0..options.count],0..) |bits,index| {
		var pool = try Pool.init(std.heap.c_allocator,bits,16); defer pool.deinit();
		var inverse_count: usize = 0;
		for (pool.cases,0..) |fixture,i| {
			if (fixture.has_inverse) inverse_count += 1;
			for (methods) |method| try pool.run(method,i);
		}
		var row: Row = .{ .size = bits, .modulus_bits = bits, .inverse_count = inverse_count, .samples = undefined,
			.components = .{
				.{ .method = "hgcd", .cpu_ns = undefined, .wall_ns = undefined },
				.{ .method = "recursive", .cpu_ns = undefined, .wall_ns = undefined },
			} };
		for (0..6) |round| {
			const sample = try timing.pairedSample(&pool,nativeBatch,methods,16,1,round);
			for (&row.components,0..) |*component,i| {
				component.cpu_ns[round] = sample.cpu_ns[i]; component.wall_ns[round] = sample.wall_ns[i];
			}
			row.samples.cpu_ns[round] = (sample.cpu_ns[0]+sample.cpu_ns[1])/2;
			row.samples.wall_ns[round] = (sample.wall_ns[0]+sample.wall_ns[1])/2;
		}
		rows[index] = row;
	}
	const report = .{
		.schema = "performance-measurement/v1", .correct = true, .build_mode = "ReleaseFast",
		.compiler = @import("builtin").zig_version_string, .method = "inverse-exact-paired-v1",
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID", .wall_clock = "CLOCK_MONOTONIC",
		.seed_usage = "(0xEAC74096 XOR modulus_bits) + index*65537; engine seed does not alter inputs",
		.operation = "exact 4095/4096/4097-bit odd modulus; fourteen seeded operands one bit smaller, then one and zero controls",
		.normalization = "six ABBA/BAAB half-pool samples; 16 verified inverses per method/sample; primary averages both methods; no subtraction",
		.verification = "GMP inverse existence and full magnitude comparison for every call; GMP calculation outside timing",
		.allocator_coverage = "unmeasured; prepared inputs and reused result; arithmetic allocation included",
		.rows = rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(),report,.{});
	try std.Io.File.stdout().writeStreamingAll(init.io,json);
	try std.Io.File.stdout().writeStreamingAll(init.io,"\n");
}
