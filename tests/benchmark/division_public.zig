//! Paired signed public division across divisor widths and quotient lengths.
const std = @import("std");
const blip = @import("blip_mp");
const Mp = blip.Mp;
const Case = @import("division_competitors.zig").Case;
const timing = @import("division_crossover.zig");
const widths = [_]usize{64,65,8192,12288,16384,16385};
const Geometry = enum { short_quotient, one_chunk_limit, two_chunk_start, balanced, long_dividend };
const Method = enum { current, burnikel_ziegler, leading_block, short_quotient };
const methods = [2]Method{.current,.burnikel_ziegler};
const Comparison = enum { public, leading, short, short_public };
const Options = struct { geometry: Geometry, sizes: [widths.len]usize, count: usize };

fn parse(args: []const []const u8) !Options {
	if (args.len != 2) return error.InvalidArguments;
	var options: Options = .{ .geometry = std.meta.stringToEnum(Geometry,args[0]) orelse return error.InvalidArguments, .sizes = undefined, .count = 0 };
	var parts = std.mem.splitScalar(u8,args[1],',');
	while (parts.next()) |part| {
		const width = std.fmt.parseInt(usize,part,10) catch return error.InvalidArguments;
		if (std.mem.indexOfScalar(usize,&widths,width) == null or options.count == widths.len) return error.InvalidArguments;
		if (options.count > 0 and width <= options.sizes[options.count-1]) return error.InvalidArguments;
		options.sizes[options.count] = width; options.count += 1;
	}
	return options;
}

fn dividendBytes(geometry: Geometry, width: usize) usize {
	return switch (geometry) { .short_quotient => width+1, .one_chunk_limit => width+7, .two_chunk_start => width+8, .balanced => 2*width, .long_dividend => 4*width };
}

const Pool = struct {
	arena: std.heap.ArenaAllocator, cases: []Case, q: Mp, r: Mp,
	fn init(parent: std.mem.Allocator, geometry: Geometry, width: usize, count: usize) !Pool {
		if (std.mem.indexOfScalar(usize,&widths,width) == null or count == 0 or count > 32) return error.InvalidArguments;
		var arena = std.heap.ArenaAllocator.init(parent); errdefer arena.deinit();
		const cases = try arena.allocator().alloc(Case,count);
		var initialized: usize = 0;
		errdefer for (cases[0..initialized]) |*case| case.deinit();
		var zero = Mp.init(parent); defer zero.deinit(); try zero.setI64(0);
		for (cases,0..) |*case,index| {
			case.* = try Case.initSized(arena.allocator(),parent,width,index,dividendBytes(geometry,width));
			initialized += 1;
			const negative_a = (index/8)%4 == 1 or (index/8)%4 == 3;
			const negative_b = (index/8)%4 >= 2;
			if (negative_a) { try case.a.sub(&zero,&case.a); try case.mr.sub(&zero,&case.mr); }
			if (negative_b) try case.b.sub(&zero,&case.b);
			if (negative_a != negative_b) try case.mq.sub(&zero,&case.mq);
		}
		return .{ .arena = arena, .cases = cases, .q = Mp.init(parent), .r = Mp.init(parent) };
	}
	fn deinit(self: *@This()) void {
		blip.tier3.releaseBzArena(); blip.tier3.releaseDivScratch();
		blip.tier3.releaseMulScratch(); blip.tier3.releaseVnScratch();
		for (self.cases) |*case| case.deinit();
		self.q.deinit(); self.r.deinit(); self.arena.deinit();
	}
	pub fn run(self: *@This(), method: Method, index: usize) !void {
		const case = &self.cases[index];
		switch (method) {
			.current => try Mp.divMod(&self.q,&self.r,&case.a,&case.b),
			.burnikel_ziegler => try Mp.divModBurnikelZiegler(&self.q,&self.r,&case.a,&case.b),
			.leading_block => try Mp.divModBurnikelZieglerLeadingBlock(&self.q,&self.r,&case.a,&case.b),
			.short_quotient => try Mp.divModBurnikelZieglerShortQuotient(&self.q,&self.r,&case.a,&case.b),
		}
		if (!std.mem.eql(u8,self.q.bytes(),case.mq.bytes()) or !std.mem.eql(u8,self.r.bytes(),case.mr.bytes())) return error.IncorrectWork;
	}
};

test "public division parser classifies complete width and geometry sets" {
	for (std.enums.values(Geometry)) |geometry| {
		var actual: [16400]bool = @splat(false); var wanted: [16400]bool = @splat(false);
		for (widths) |width| wanted[width] = true;
		for (0..actual.len) |width| {
			var buffer: [32]u8 = undefined;
			const arg = try std.fmt.bufPrint(&buffer,"{d}",.{width});
			if (parse(&.{@tagName(geometry),arg})) |options| {
				actual[width] = true;
				try std.testing.expectEqual(geometry,options.geometry);
				try std.testing.expectEqual(@as(usize,1),options.count);
				try std.testing.expectEqual(width,options.sizes[0]);
			} else |err| try std.testing.expectEqual(error.InvalidArguments,err);
		}
		try std.testing.expectEqualSlices(bool,&wanted,&actual);
	}
	const options = try parse(&.{"balanced","64,65,8192,12288,16384,16385"});
	try std.testing.expectEqualSlices(usize,&widths,options.sizes[0..options.count]);
	for ([_][]const u8{"","64,","64,64","65,64","-1","x"}) |arg| try std.testing.expectError(error.InvalidArguments,parse(&.{"balanced",arg}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{"unknown","64"}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{}));
}

test "public division corpus covers signed geometries and rejects corrupt references" {
	for (std.enums.values(Geometry)) |geometry| for ([_]usize{64,65}) |width| {
		var pool = try Pool.init(std.testing.allocator,geometry,width,32); defer pool.deinit();
		const dividend_len = switch (geometry) { .short_quotient => width+1, .one_chunk_limit => width+7, .two_chunk_start => width+8, .balanced => 2*width, .long_dividend => 4*width };
		var combinations: [4][8]usize = @splat(@splat(0));
		for (pool.cases,0..) |*case,index| {
			try std.testing.expectEqual(dividend_len,case.dividend.len);
			try std.testing.expectEqual(width,case.divisor.len);
			const sign_index = @as(usize,@intFromBool(case.a.cached_sign < 0)) + 2*@as(usize,@intFromBool(case.b.cached_sign < 0));
			const top_bit = 7-@clz(case.divisor[width-1]);
			combinations[sign_index][top_bit] += 1;
			for (std.enums.values(Method)) |method| try pool.run(method,index);
			try case.mq.setI64(0);
			for (std.enums.values(Method)) |method| try std.testing.expectError(error.IncorrectWork,pool.run(method,index));
		}
		for (combinations) |row| try std.testing.expectEqualSlices(usize,&@as([8]usize,@splat(1)),&row);
	};
}

test "public division pool releases every partial construction" {
	const Check = struct {
		fn run(allocator: std.mem.Allocator) !void {
			var pool = try Pool.init(allocator,.short_quotient,64,32); defer pool.deinit();
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator,Check.run,.{});
}

fn nativeBatch(pool: *Pool, method: Method, start: usize, count: usize, repeats: usize) !struct { cpu_ns: f64, wall_ns: f64 } {
	const Clock = struct {
		pub fn read(_: *@This(), kind: std.c.CLOCK) !u64 { return @import("immediate_add.zig").now(kind); }
	};
	var clock: Clock = .{};
	const duration = try timing.timedBatch(pool,&clock,method,start,count,repeats);
	return .{ .cpu_ns = duration.cpu_ns, .wall_ns = duration.wall_ns };
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
	return runPair(.public,init,args);
}

pub fn runLeading(init: std.process.Init, args: []const []const u8) !void {
	return runPair(.leading,init,args);
}

pub fn runShort(init: std.process.Init, args: []const []const u8, comptime against_public: bool) !void {
	return runPair(if (against_public) .short_public else .short,init,args);
}

fn runPair(comptime comparison: Comparison, init: std.process.Init, args: []const []const u8) !void {
	const pair: [2]Method = switch (comparison) {
		.public => methods, .leading => .{.burnikel_ziegler,.leading_block},
		.short => .{.leading_block,.short_quotient}, .short_public => .{.current,.short_quotient},
	};
	const options = try parse(args);
	const Component = struct { method: []const u8, cpu_ns: [6]f64, wall_ns: [6]f64 };
	const Row = struct {
		size: usize, dividend_bytes: usize, fixture_count: usize = 32, iterations: usize = 32, warmup_cases: usize = 64,
		samples: struct { cpu_ns: [6]f64, wall_ns: [6]f64 }, components: [2]Component,
	};
	var rows: [widths.len]Row = undefined;
	for (options.sizes[0..options.count],0..) |width,index| {
		var pool = try Pool.init(std.heap.c_allocator,options.geometry,width,32); defer pool.deinit();
		for (0..32) |i| for (pair) |method| try pool.run(method,i);
		var row: Row = .{ .size = width, .dividend_bytes = dividendBytes(options.geometry,width), .samples = undefined,
			.components = .{
				.{ .method = @tagName(pair[0]), .cpu_ns = undefined, .wall_ns = undefined },
				.{ .method = @tagName(pair[1]), .cpu_ns = undefined, .wall_ns = undefined },
			} };
		for (0..6) |round| {
			const sample = try timing.pairedSample(&pool,nativeBatch,pair,32,1,round);
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
		.compiler = @import("builtin").zig_version_string,
		.method = switch (comparison) {
			.public => "division-public-paired-v1", .leading => "division-leading-block-paired-v1",
			.short => "division-short-quotient-paired-v1", .short_public => "division-short-public-paired-v1",
		}, .geometry = @tagName(options.geometry),
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID", .wall_clock = "CLOCK_MONOTONIC",
		.seed_usage = "0xB2D151A5 + divisor_bytes*257 + index; four sign combinations crossed with eight normalization shifts; engine seed does not alter inputs",
		.operation = switch (comparison) {
			.public => "current public signed division versus explicit B-Z; magnitude byte widths; identical canonical BLIP input/output comparison adapters",
			.leading => "explicit signed B-Z versus leading-block shortcut; magnitude byte widths; identical canonical BLIP input/output comparison adapters",
			.short => "fixed leading-block B-Z versus short-quotient fallback; magnitude byte widths; identical canonical BLIP input/output comparison adapters",
			.short_public => "current public signed division versus short-quotient B-Z; magnitude byte widths; identical canonical BLIP input/output comparison adapters",
		},
		.normalization = "six ABBA/BAAB half-pool samples; 32 verified calls per method/sample; primary averages both methods; no subtraction",
		.verification = "GMP quotient/remainder magnitudes with truncated sign rules outside timing; full canonical-byte comparison on every call",
		.allocator_coverage = "prepared inputs, reused outputs and warmed thread-local scratch; arithmetic allocation included; cold allocation unmeasured",
		.rows = rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(),report,.{});
	try std.Io.File.stdout().writeStreamingAll(init.io,json);
	try std.Io.File.stdout().writeStreamingAll(init.io,"\n");
}
