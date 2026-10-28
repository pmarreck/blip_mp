//! Verified inverse-modulo workloads retained from the former unit benchmark.
const std = @import("std");
const blip = @import("blip_mp");
const Mp = blip.Mp;

pub const Algorithm = enum { lehmer, hgcd, recursive, stein };
pub const widths = [_]usize{ 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048, 4096, 8192 };
pub const repetitions = [_]usize{ 2000, 1500, 1000, 700, 500, 400, 300, 250, 200, 100, 25, 8 };

pub const Options = struct { algorithm: Algorithm, indexes: [widths.len]usize, count: usize };
pub fn parse(args: []const []const u8) !Options {
	if (args.len != 2) return error.InvalidArguments;
	var options: Options = .{ .algorithm = std.meta.stringToEnum(Algorithm, args[0]) orelse return error.InvalidArguments, .indexes = undefined, .count = 0 };
	var values = std.mem.splitScalar(u8, args[1], ',');
	while (values.next()) |value| {
		const bits = std.fmt.parseInt(usize, value, 10) catch return error.InvalidArguments;
		const index = std.mem.indexOfScalar(usize, &widths, bits) orelse return error.InvalidArguments;
		if (options.algorithm == .recursive and bits > 4096) return error.InvalidArguments;
		if (options.count == widths.len or (options.count > 0 and index <= options.indexes[options.count - 1])) return error.InvalidArguments;
		options.indexes[options.count] = index;
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
	defer blip.tier3.releaseBzArena();
	defer blip.tier3.releaseMulScratch();
	defer blip.tier3.releaseDivScratch();
	defer blip.tier3.releaseVnScratch();
	const Row = struct { size: usize, modulus_bits: usize, iterations: usize, inverse_exists: bool, samples: struct { cpu_ns: [5]f64, wall_ns: [5]f64 } };
	var rows: [widths.len]Row = undefined;
	const now = @import("immediate_add.zig").now;
	for (options.indexes[0..options.count], 0..) |index, row_index| {
		var fixture = try Fixture.init(std.heap.c_allocator, widths[index]);
		defer fixture.deinit();
		var result = Mp.init(std.heap.c_allocator);
		defer result.deinit();
		try verify(&result, try run(options.algorithm, &result, &fixture), fixture.expected, fixture.has_inverse);
		const iterations = repetitions[index];
		rows[row_index] = .{ .size = widths[index], .modulus_bits = fixture.m.bitLen(), .iterations = iterations, .inverse_exists = fixture.has_inverse, .samples = undefined };
		for (&rows[row_index].samples.cpu_ns, &rows[row_index].samples.wall_ns) |*cpu, *wall| {
			const wall_start = try now(.MONOTONIC);
			const cpu_start = try now(.PROCESS_CPUTIME_ID);
			for (0..iterations) |_| {
				const ok = try run(options.algorithm, &result, &fixture);
				std.mem.doNotOptimizeAway(result.bytes());
				try verify(&result, ok, fixture.expected, fixture.has_inverse);
			}
			const cpu_end = try now(.PROCESS_CPUTIME_ID);
			const wall_end = try now(.MONOTONIC);
			if (cpu_end <= cpu_start or wall_end <= wall_start) return error.ClockFailed;
			cpu.* = @as(f64, @floatFromInt(cpu_end - cpu_start)) / @as(f64, @floatFromInt(iterations));
			wall.* = @as(f64, @floatFromInt(wall_end - wall_start)) / @as(f64, @floatFromInt(iterations));
		}
	}
	const report = .{
		.schema = "performance-measurement/v1", .correct = true, .build_mode = "ReleaseFast",
		.compiler = @import("builtin").zig_version_string, .method = "inverse-gmp-verified-v1",
		.algorithm = @tagName(options.algorithm), .fixture_seed = "0xBABE_CAFE_F00D",
		.size_definition = "nominal signed-payload bits; modulus_bits is the significant width used by algorithm dispatch",
		.seed_usage = "fixed historical fixtures; engine seed does not alter inputs",
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID", .wall_clock = "CLOCK_MONOTONIC",
		.normalization = "nanoseconds per inverse plus full GMP-result comparison; no subtraction",
		.allocator_coverage = "unmeasured; c_allocator, prepared inputs and reused result; kernel allocation included",
		.warmup_iterations = 1, .rows = rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), report, .{});
	try std.Io.File.stdout().writeStreamingAll(init.io, json);
	try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

test "probe argument classifier accepts supported sets and bounds recursive widths" {
	for (std.enums.values(Algorithm)) |algorithm| {
		for (widths, 0..) |bits, index| {
			var buffer: [32]u8 = undefined;
			const size = try std.fmt.bufPrint(&buffer, "{d}", .{bits});
			if (algorithm == .recursive and bits > 4096) {
				try std.testing.expectError(error.InvalidArguments, parse(&.{ @tagName(algorithm), size }));
			} else {
				const options = try parse(&.{ @tagName(algorithm), size });
				try std.testing.expectEqual(algorithm, options.algorithm);
				try std.testing.expectEqual(@as(usize, 1), options.count);
				try std.testing.expectEqual(index, options.indexes[0]);
			}
		}
	}
	const options = try parse(&.{ "lehmer", "64,128,8192" });
	try std.testing.expectEqualSlices(usize, &.{ 0, 2, 11 }, options.indexes[0..options.count]);
	for ([_][]const u8{ "", "0", "63", "65", "-1", "64,", ",64", "64,64", "128,64", "64,x", "16384" }) |sizes| {
		try std.testing.expectError(error.InvalidArguments, parse(&.{ "lehmer", sizes }));
	}
	try std.testing.expectError(error.InvalidArguments, parse(&.{}));
	try std.testing.expectError(error.InvalidArguments, parse(&.{ "unknown", "64" }));
}

fn magnitude(value: *const Mp) ![]const u8 {
	if (try value.sign() < 0) return error.IncorrectWork;
	const bytes = value.bytes();
	const header = try blip.tier3.parseHeader(bytes);
	const payload = if (bytes[0] < 128) bytes else bytes[header.bytes_consumed..][0..header.L];
	return std.mem.trimEnd(u8, payload, &.{0});
}

pub fn verify(result: *const Mp, actual_exists: bool, wanted: []const u8, expected_exists: bool) !void {
	if (actual_exists != expected_exists) return error.IncorrectWork;
	if (actual_exists and !std.mem.eql(u8, try magnitude(result), wanted)) return error.IncorrectWork;
}

const gmp = @import("gmp.zig");
const Z = gmp.Z;

pub const Fixture = struct {
	allocator: std.mem.Allocator,
	a: Mp,
	m: Mp,
	expected: []u8,
	has_inverse: bool,
	pub fn init(allocator: std.mem.Allocator, bits: usize) !Fixture {
		if (std.mem.indexOfScalar(usize, &widths, bits) == null) return error.InvalidArguments;
		var a = Mp.init(allocator);
		errdefer a.deinit();
		var m = Mp.init(allocator);
		errdefer m.deinit();
		const raw = try allocator.alloc(u8, 1024);
		defer allocator.free(raw);
		const encoded = try allocator.alloc(u8, 1100);
		defer allocator.free(encoded);
		var rng = std.Random.DefaultPrng.init(0xBABE_CAFE_F00D);
		const random = rng.random();
		for (widths) |width| {
			const length = width / 8;
			random.bytes(raw[0..length]);
			if (width == bits) {
				raw[length - 1] &= 0x7f;
				const header = try blip.tier3.writeHeader(encoded, length);
				@memcpy(encoded[header..][0..length], raw[0..length]);
				try a.setBytes(encoded[0 .. header + length]);
			}
			random.bytes(raw[0..length]);
			if (width == bits) {
				raw[length - 1] = (raw[length - 1] & 0x7f) | 0x40;
				raw[0] |= 1;
				const header = try blip.tier3.writeHeader(encoded, length);
				@memcpy(encoded[header..][0..length], raw[0..length]);
				try m.setBytes(encoded[0 .. header + length]);
				break;
			}
		}
		var ga: Z = undefined;
		gmp.__gmpz_init(&ga);
		defer gmp.__gmpz_clear(&ga);
		var gm: Z = undefined;
		gmp.__gmpz_init(&gm);
		defer gmp.__gmpz_clear(&gm);
		var inverse: Z = undefined;
		gmp.__gmpz_init(&inverse);
		defer gmp.__gmpz_clear(&inverse);
		const a_bytes = try magnitude(&a);
		const m_bytes = try magnitude(&m);
		gmp.__gmpz_import(&ga, a_bytes.len, -1, 1, 0, 0, a_bytes.ptr);
		gmp.__gmpz_import(&gm, m_bytes.len, -1, 1, 0, 0, m_bytes.ptr);
		const exists = gmp.__gmpz_invert(&inverse, &ga, &gm) != 0;
		var length: usize = 0;
		if (exists) _ = gmp.__gmpz_export(raw.ptr, &length, -1, 1, 0, 0, &inverse);
		return .{ .allocator = allocator, .a = a, .m = m,
			.expected = try allocator.dupe(u8, raw[0..length]), .has_inverse = exists };
	}
	pub fn deinit(self: *Fixture) void {
		self.a.deinit();
		self.m.deinit();
		self.allocator.free(self.expected);
	}
};

pub fn run(algorithm: Algorithm, result: *Mp, fixture: *const Fixture) !bool {
	return switch (algorithm) {
		.lehmer => Mp.invModLehmer(result, &fixture.a, &fixture.m),
		.hgcd => Mp.invModHGCD(result, &fixture.a, &fixture.m),
		.recursive => Mp.invModHGCDRecursive(result, &fixture.a, &fixture.m),
		.stein => Mp.invModStein(result, &fixture.a, &fixture.m),
	};
}

test "every historical inverse fixture agrees with GMP for all bounded algorithms" {
	defer blip.tier3.releaseBzArena();
	defer blip.tier3.releaseMulScratch();
	defer blip.tier3.releaseDivScratch();
	defer blip.tier3.releaseVnScratch();
	var result = Mp.init(std.testing.allocator);
	defer result.deinit();
	for (widths) |bits| {
		var fixture = try Fixture.init(std.testing.allocator, bits);
		defer fixture.deinit();
		try std.testing.expectEqual(bits - 1, fixture.m.bitLen());
		for (std.enums.values(Algorithm)) |algorithm| {
			if (algorithm == .recursive and bits > 4096) continue;
			const ok = try run(algorithm, &result, &fixture);
			try verify(&result, ok, fixture.expected, fixture.has_inverse);
		}
	}
}

test "inverse oracle rejects wrong values, signs and existence flags" {
	var result = Mp.init(std.testing.allocator);
	defer result.deinit();
	try result.setI64(4);
	try verify(&result, true, &.{4}, true);
	try std.testing.expectError(error.IncorrectWork, verify(&result, false, &.{4}, true));
	try std.testing.expectError(error.IncorrectWork, verify(&result, true, &.{}, false));
	try result.setI64(5);
	try std.testing.expectError(error.IncorrectWork, verify(&result, true, &.{4}, true));
	try result.setI64(-4);
	try std.testing.expectError(error.IncorrectWork, verify(&result, true, &.{4}, true));
	try verify(&result, false, &.{}, false);
}
