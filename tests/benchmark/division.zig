//! Historical division workloads with independent GMP quotient/remainder checks.
const std = @import("std");
const blip = @import("blip_mp");
const gmp = @import("gmp.zig");
test { _ = @import("division_crossover.zig"); }
pub const Kind = enum { byte_2048, chunk_2048, chunk_4096, chunk_8192, single_byte, single_chunk };
pub const Options = struct { kind: Kind, iterations: usize };
pub fn parse(args: []const []const u8) !Options {
	if (args.len != 2) return error.InvalidArguments;
	const kind = std.meta.stringToEnum(Kind, args[0]) orelse return error.InvalidArguments;
	const count = std.fmt.parseInt(usize, args[1], 10) catch return error.InvalidArguments;
	if (count == 0 or count > 1_000_000) return error.InvalidArguments;
	return .{ .kind = kind, .iterations = count };
}

pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) {
		try std.Io.File.stderr().writeStreamingAll(init.io, "\x1b[33mDEBUG BUILD!\x1b[0m Performance probe requires ReleaseFast.\n");
		return error.UnoptimizedBuild;
	}
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	if (args.len > 1 and std.mem.eql(u8, args[1], "paired")) return @import("division_crossover.zig").run(init, args[2..], .kernels);
	if (args.len > 1 and std.mem.eql(u8, args[1], "paired-fallback")) return @import("division_crossover.zig").run(init, args[2..], .fallbacks);
	const options = try parse(args[1..]);
	var fixture = try Fixture.init(std.heap.c_allocator, options.kind);
	defer fixture.deinit();
	try fixture.run();
	var cpu: [5]f64 = undefined;
	var wall: [5]f64 = undefined;
	const now = @import("immediate_add.zig").now;
	for (&cpu, &wall) |*cpu_sample, *wall_sample| {
		const wall_start = try now(.MONOTONIC);
		const cpu_start = try now(.PROCESS_CPUTIME_ID);
		for (0..options.iterations) |_| {
			try fixture.run();
			std.mem.doNotOptimizeAway(&fixture);
		}
		const cpu_end = try now(.PROCESS_CPUTIME_ID);
		const wall_end = try now(.MONOTONIC);
		if (cpu_end <= cpu_start or wall_end <= wall_start) return error.ClockFailed;
		const count: f64 = @floatFromInt(options.iterations);
		cpu_sample.* = @as(f64, @floatFromInt(cpu_end - cpu_start)) / count;
		wall_sample.* = @as(f64, @floatFromInt(wall_end - wall_start)) / count;
	}
	const report = .{
		.schema = "performance-measurement/v1", .correct = true, .build_mode = "ReleaseFast",
		.compiler = @import("builtin").zig_version_string, .method = "division-gmp-verified-v1",
		.fixture = @tagName(options.kind), .dividend_bytes = fixture.dividend.len, .divisor_bytes = fixture.divisor.len,
		.seed_usage = "fixed historical fixtures; engine seed does not alter inputs",
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID", .wall_clock = "CLOCK_MONOTONIC",
		.normalization = "nanoseconds per division plus buffer reset and full GMP quotient/remainder comparison; no subtraction",
		.allocator_coverage = "unmeasured; arena backed by c_allocator for setup; prepared work buffers",
		.warmup_iterations = 1,
		.rows = .{.{ .size = options.iterations, .samples = .{ .cpu_ns = cpu, .wall_ns = wall } }},
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), report, .{});
	try std.Io.File.stdout().writeStreamingAll(init.io, json);
	try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

test "division arguments accept all fixture kinds and reject invalid work counts" {
	for (std.enums.values(Kind)) |kind| {
		const options = try parse(&.{ @tagName(kind), "1000" });
		try std.testing.expectEqual(kind, options.kind);
		try std.testing.expectEqual(@as(usize, 1000), options.iterations);
	}
	for ([_][]const u8{ "", "0", "-1", "1000001", "x", "1,2" }) |count| {
		try std.testing.expectError(error.InvalidArguments, parse(&.{ "byte_2048", count }));
	}
	try std.testing.expectError(error.InvalidArguments, parse(&.{ "unknown", "1" }));
	try std.testing.expectError(error.InvalidArguments, parse(&.{}));
}

pub fn verify(q: []const u8, r: []const u8, expected_q: []const u8, expected_r: []const u8) !void {
	if (!std.mem.eql(u8, std.mem.trimEnd(u8, q, &.{0}), expected_q) or
		!std.mem.eql(u8, std.mem.trimEnd(u8, r, &.{0}), expected_r)) return error.IncorrectWork;
}

pub const Fixture = struct {
	arena: std.heap.ArenaAllocator,
	kind: Kind,
	dividend: []u8,
	divisor: []u8,
	quotient: []u8,
	remainder: []u8,
	work: []u8,
	scratch: []u8,
	expected_q: []u8,
	expected_r: []u8,
	pub fn init(parent: std.mem.Allocator, kind: Kind) !Fixture {
		var arena = std.heap.ArenaAllocator.init(parent);
		errdefer arena.deinit();
		const allocator = arena.allocator();
		const n: usize = switch (kind) { .chunk_4096 => 512, .chunk_8192 => 1024, else => 256 };
		const d: usize = switch (kind) { .single_byte => 1, .single_chunk => 8, else => n / 2 };
		var self: Fixture = .{
			.arena = arena, .kind = kind,
			.dividend = try allocator.alloc(u8, n), .divisor = try allocator.alloc(u8, d),
			.quotient = try allocator.alloc(u8, n + 8), .remainder = try allocator.alloc(u8, d + 8),
			.work = try allocator.alloc(u8, n + 8),
			.scratch = try allocator.alloc(u8, if (kind == .byte_2048) blip.tier3.divModKnuthScratchNeed(n, d) else 0),
			.expected_q = try allocator.alloc(u8, n), .expected_r = try allocator.alloc(u8, d),
		};
		const seed: u64 = switch (kind) {
			.byte_2048, .chunk_2048 => 0x4242_4242,
			.chunk_4096 => 0x4040_4040, .chunk_8192 => 0x8080_8080,
			.single_byte, .single_chunk => 0xABCD_1234,
		};
		var rng = std.Random.DefaultPrng.init(seed);
		const random = rng.random();
		switch (kind) {
			.chunk_2048, .chunk_4096, .chunk_8192 => {
				for (0..n / 8) |i| std.mem.writeInt(u64, self.dividend[i * 8..][0..8], random.int(u64), .little);
				for (0..d / 8) |i| std.mem.writeInt(u64, self.divisor[i * 8..][0..8], random.int(u64), .little);
				if (std.mem.readInt(u64, self.dividend[n - 8..][0..8], .little) == 0) @memset(self.dividend[n - 8..], 0xcc);
				if (std.mem.readInt(u64, self.divisor[d - 8..][0..8], .little) == 0) @memset(self.divisor[d - 8..], 0xaa);
			},
			.byte_2048 => {
				for (self.dividend) |*byte| byte.* = random.int(u8);
				for (self.divisor) |*byte| byte.* = random.int(u8);
				if (self.dividend[n - 1] == 0) self.dividend[n - 1] = 0xcc;
				if (self.divisor[d - 1] == 0) self.divisor[d - 1] = 0xaa;
			},
			.single_byte, .single_chunk => {
				for (self.dividend) |*byte| byte.* = random.int(u8);
				if (kind == .single_byte) self.divisor[0] = 0x65 else std.mem.writeInt(u64, self.divisor[0..8], 65537, .little);
			},
		}
		var a: gmp.Z = undefined;
		gmp.__gmpz_init(&a);
		defer gmp.__gmpz_clear(&a);
		var b: gmp.Z = undefined;
		gmp.__gmpz_init(&b);
		defer gmp.__gmpz_clear(&b);
		var q: gmp.Z = undefined;
		gmp.__gmpz_init(&q);
		defer gmp.__gmpz_clear(&q);
		var r: gmp.Z = undefined;
		gmp.__gmpz_init(&r);
		defer gmp.__gmpz_clear(&r);
		gmp.__gmpz_import(&a, n, -1, 1, 0, 0, self.dividend.ptr);
		gmp.__gmpz_import(&b, d, -1, 1, 0, 0, self.divisor.ptr);
		gmp.__gmpz_tdiv_qr(&q, &r, &a, &b);
		var q_len: usize = 0;
		var r_len: usize = 0;
		_ = gmp.__gmpz_export(self.expected_q.ptr, &q_len, -1, 1, 0, 0, &q);
		_ = gmp.__gmpz_export(self.expected_r.ptr, &r_len, -1, 1, 0, 0, &r);
		self.expected_q = self.expected_q[0..q_len];
		self.expected_r = self.expected_r[0..r_len];
		self.arena = arena;
		return self;
	}
	pub fn deinit(self: *Fixture) void {
		self.arena.deinit();
	}
	pub fn run(self: *Fixture) !void {
		const n = self.dividend.len;
		const d = self.divisor.len;
		switch (self.kind) {
			.byte_2048 => {
				const out = blip.tier3.divModKnuth(self.dividend, n, self.divisor, d, self.quotient, self.remainder, self.scratch);
				try verify(self.quotient[0..out.q_len], self.remainder[0..out.r_len], self.expected_q, self.expected_r);
			},
			.chunk_2048, .chunk_4096, .chunk_8192 => {
				@memcpy(self.work[0..n], self.dividend);
				@memset(self.work[n..], 0);
				const out = blip.tier3.divModKnuthU64(self.work, n / 8, self.divisor, d / 8, self.quotient, self.remainder);
				try verify(self.quotient[0 .. out.q_len * 8], self.remainder[0 .. out.r_len * 8], self.expected_q, self.expected_r);
			},
			.single_byte, .single_chunk => {
				@memcpy(self.work[0..n], self.dividend);
				const q_len, const rem: u64 = if (self.kind == .single_byte) blk: {
					const out = blip.tier3.divModSingleByte(self.work, n, 0x65);
					break :blk .{ out.q_len, out.rem };
				} else blk: {
					const out = blip.tier3.divModSingleU64(self.work, n, 65537);
					break :blk .{ out.q_len, out.rem };
				};
				std.mem.writeInt(u64, self.remainder[0..8], rem, .little);
				try verify(self.work[0..q_len], self.remainder[0..8], self.expected_q, self.expected_r);
			},
		}
	}
};

test "all historical division fixtures agree with independent GMP quotient and remainder" {
	for (std.enums.values(Kind)) |kind| {
		var fixture = try Fixture.init(std.testing.allocator, kind);
		defer fixture.deinit();
		try fixture.run();
		try fixture.run(); // Work buffers must reset between calls.
		fixture.expected_q[0] ^= 1;
		try std.testing.expectError(error.IncorrectWork, fixture.run());
	}
}

test "division oracle accepts padding and rejects wrong quotient or remainder" {
	try verify(&.{ 4, 0 }, &.{ 2, 0 }, &.{4}, &.{2});
	try std.testing.expectError(error.IncorrectWork, verify(&.{5}, &.{2}, &.{4}, &.{2}));
	try std.testing.expectError(error.IncorrectWork, verify(&.{4}, &.{1}, &.{4}, &.{2}));
	try std.testing.expectError(error.IncorrectWork, verify(&.{}, &.{}, &.{4}, &.{2}));
}
