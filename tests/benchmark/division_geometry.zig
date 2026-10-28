//! Matched byte kernels with independent dividend-length and divisor-length axes.
const std = @import("std");
const competitors = @import("division_competitors.zig");
const Fixture = competitors.Fixture;
const methods = [2]competitors.Method{.knuth,.selected_bz};
const wide_methods = [2]competitors.Method{.short_carry,.wide_quotient};
const widths = [_]usize{64,4096,8192,16384};
const extras = [_]usize{1,7,8,16,32,64,128,256,512,1024,2048,4096,8192,16384};
const wide_widths = [_]usize{64,4094,4096,4097,4098,8192,8194,16384,16385,16386};
const wide_extras = [_]usize{1,7,8,16,32,64,128,256,512,1024,2047,2048,2049,4096,8192,16384};
const Options = struct { width: usize, sizes: [wide_extras.len+1]usize, count: usize };

fn parseWide(args: []const []const u8) !Options { return parseWith(true,args); }

test "wide quotient geometry classifies boundary and neighboring width sets" {
	var actual_widths: [16388]bool = @splat(false);
	var expected_widths: [16388]bool = @splat(false);
	for (wide_widths) |width| expected_widths[width] = true;
	for (0..actual_widths.len) |width| {
		var buffer: [24]u8 = undefined;
		const text = try std.fmt.bufPrint(&buffer,"{d}",.{width});
		actual_widths[width] = if (parseWide(&.{text,"1"})) |_| true else |err| blk: {
			try std.testing.expectEqual(error.InvalidArguments,err); break :blk false;
		};
	}
	try std.testing.expectEqualSlices(bool,&expected_widths,&actual_widths);
	for (wide_widths) |width| {
		var width_buffer: [24]u8 = undefined;
		const width_text = try std.fmt.bufPrint(&width_buffer,"{d}",.{width});
		var actual: [16388]bool = @splat(false);
		var expected: [16388]bool = @splat(false);
		for (wide_extras) |extra| if (extra <= width) { expected[extra] = true; };
		expected[width] = true;
		for (0..actual.len) |extra| {
			var buffer: [24]u8 = undefined;
			const text = try std.fmt.bufPrint(&buffer,"{d}",.{extra});
			if (parseWide(&.{width_text,text})) |options| {
				actual[extra] = true;
				try std.testing.expectEqual(width,options.width);
				try std.testing.expectEqual(@as(usize,1),options.count);
				try std.testing.expectEqual(extra,options.sizes[0]);
			} else |err| try std.testing.expectEqual(error.InvalidArguments,err);
		}
		try std.testing.expectEqualSlices(bool,&expected,&actual);
	}
	const options = try parseWide(&.{"4097","7,8,2047,2048,2049,4097"});
	try std.testing.expectEqualSlices(usize,&.{7,8,2047,2048,2049,4097},options.sizes[0..options.count]);
	for ([_][]const u8{"","7,","7,7","8,7","-1","x","18446744073709551616","7,8192"}) |arg| try std.testing.expectError(error.InvalidArguments,parseWide(&.{"4097",arg}));
	try std.testing.expectError(error.InvalidArguments,parseWide(&.{}));
	try std.testing.expectError(error.InvalidArguments,parseWide(&.{"4097"}));
	try std.testing.expectError(error.InvalidArguments,parseWide(&.{"4097","7","8"}));
}

test "wide quotient neighboring fixtures preserve complete GMP references" {
	for ([_]usize{4094,4096,4097,4098}) |width| for ([_]usize{8,2048,2049}) |gap| {
		var fixture = try Fixture.initSized(std.testing.allocator,width,8,width+gap); defer fixture.deinit();
		for (0..8) |index| {
			for ([_]competitors.Method{.short_carry,.wide_quotient}) |method| try fixture.run(method,index);
			try fixture.corruptQuotient(index);
			for ([_]competitors.Method{.short_carry,.wide_quotient}) |method| try std.testing.expectError(error.IncorrectWork,fixture.run(method,index));
		}
	};
}

fn parse(args: []const []const u8) !Options {
	return parseWith(false,args);
}

fn parseWith(comptime wide: bool, args: []const []const u8) !Options {
	const allowed_widths: []const usize = if (wide) &wide_widths else &widths;
	const allowed_extras: []const usize = if (wide) &wide_extras else &extras;
	if (args.len != 2) return error.InvalidArguments;
	const width = std.fmt.parseInt(usize,args[0],10) catch return error.InvalidArguments;
	if (std.mem.indexOfScalar(usize,allowed_widths,width) == null) return error.InvalidArguments;
	var options: Options = .{.width=width,.sizes=undefined,.count=0};
	var parts = std.mem.splitScalar(u8,args[1],',');
	while (parts.next()) |part| {
		const extra = std.fmt.parseInt(usize,part,10) catch return error.InvalidArguments;
		if (extra > width or (std.mem.indexOfScalar(usize,allowed_extras,extra) == null and (!wide or extra != width)) or options.count == options.sizes.len) return error.InvalidArguments;
		if (options.count > 0 and extra <= options.sizes[options.count-1]) return error.InvalidArguments;
		options.sizes[options.count] = extra; options.count += 1;
	}
	return options;
}

test "division geometry parser classifies complete width and extra-byte sets" {
	var actual_widths: [16386]bool = @splat(false);
	var expected_widths: [16386]bool = @splat(false);
	for (widths) |width| expected_widths[width] = true;
	for (0..actual_widths.len) |width| {
		var buffer: [24]u8 = undefined;
		const text = try std.fmt.bufPrint(&buffer,"{d}",.{width});
		actual_widths[width] = if (parse(&.{text,"1"})) |_| true else |err| blk: {
			try std.testing.expectEqual(error.InvalidArguments,err); break :blk false;
		};
	}
	try std.testing.expectEqualSlices(bool,&expected_widths,&actual_widths);
	for (widths) |width| {
		var width_buffer: [24]u8 = undefined;
		const width_text = try std.fmt.bufPrint(&width_buffer,"{d}",.{width});
		var actual: [16386]bool = @splat(false);
		var expected: [16386]bool = @splat(false);
		for (extras) |extra| if (extra <= width) { expected[extra] = true; };
		for (0..actual.len) |extra| {
			var buffer: [24]u8 = undefined;
			const text = try std.fmt.bufPrint(&buffer,"{d}",.{extra});
			if (parse(&.{width_text,text})) |options| {
				actual[extra] = true;
				try std.testing.expectEqual(width,options.width);
				try std.testing.expectEqual(@as(usize,1),options.count);
				try std.testing.expectEqual(extra,options.sizes[0]);
			} else |err| try std.testing.expectEqual(error.InvalidArguments,err);
		}
		try std.testing.expectEqualSlices(bool,&expected,&actual);
	}
	const options = try parse(&.{"64","1,7,8,16,32,64"});
	try std.testing.expectEqualSlices(usize,&.{1,7,8,16,32,64},options.sizes[0..options.count]);
	for ([_][]const u8{"","1,","1,1","8,7","-1","x","18446744073709551616","1,128"}) |arg| try std.testing.expectError(error.InvalidArguments,parse(&.{"64",arg}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{"64"}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{"64","1","7"}));
}

test "division geometry covers normalization shifts and rejects corrupted references" {
	for ([_]usize{1,7,8,16,32,64}) |extra| {
		var fixture = try Fixture.initSized(std.testing.allocator,64,32,64+extra);
		defer fixture.deinit();
		var shifts: [8]usize = @splat(0);
		for (fixture.cases,0..) |case,index| {
			try std.testing.expectEqual(64+extra,case.dividend.len);
			try std.testing.expectEqual(@as(usize,64),case.divisor.len);
			shifts[@clz(case.divisor[63])] += 1;
			for (methods) |method| try fixture.run(method,index);
			try fixture.corruptQuotient(index);
			for (methods) |method| try std.testing.expectError(error.IncorrectWork,fixture.run(method,index));
		}
		try std.testing.expectEqualSlices(usize,&.{4,4,4,4,4,4,4,4},&shifts);
	}
}

test "division geometry fixtures and both kernels release partial allocations" {
	const Check = struct {
		fn run(allocator: std.mem.Allocator) !void {
			var fixture = try Fixture.initSized(allocator,64,2,72); defer fixture.deinit();
			for (0..2) |index| for (methods) |method| try fixture.run(method,index);
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator,Check.run,.{});
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
	return runWith(false,init,args);
}

pub fn runWide(init: std.process.Init, args: []const []const u8) !void {
	return runWith(true,init,args);
}

fn runWith(comptime wide: bool, init: std.process.Init, args: []const []const u8) !void {
	const options = if (wide) try parseWide(args) else try parse(args);
	const pair = if (wide) wide_methods else methods;
	const Component = struct { method: []const u8, cpu_ns: [6]f64, wall_ns: [6]f64 };
	const Row = struct {
		size: usize, dividend_bytes: usize, fixture_count: usize = 32, iterations: usize = 32, warmup_cases: usize = 64,
		samples: struct { cpu_ns: [6]f64, wall_ns: [6]f64 }, components: [2]Component,
	};
	var rows: [wide_extras.len+1]Row = undefined;
	for (options.sizes[0..options.count],0..) |extra,index| {
		const repeats = @import("division_crossover.zig").nativeRepeats(options.width);
		var fixture = try Fixture.initSized(std.heap.c_allocator,options.width,32,options.width+extra);
		defer fixture.deinit();
		for (0..32) |i| for (pair) |method| try fixture.run(method,i);
		var row: Row = .{.size=extra,.dividend_bytes=options.width+extra,.iterations=32*repeats,.samples=undefined,.components=undefined};
		for (&row.components,pair) |*component,method| component.* = .{.method=@tagName(method),.cpu_ns=undefined,.wall_ns=undefined};
		for (0..6) |round| {
			const sample = try @import("division_crossover.zig").pairedSample(&fixture,competitors.nativeBatch,pair,32,repeats,round);
			for (&row.components,0..) |*component,i| {
				component.cpu_ns[round] = sample.cpu_ns[i]; component.wall_ns[round] = sample.wall_ns[i];
			}
			row.samples.cpu_ns[round] = (sample.cpu_ns[0]+sample.cpu_ns[1])/2;
			row.samples.wall_ns[round] = (sample.wall_ns[0]+sample.wall_ns[1])/2;
		}
		rows[index] = row;
	}
	const report = .{
		.schema="performance-measurement/v1",.correct=true,.build_mode="ReleaseFast",
		.compiler=@import("builtin").zig_version_string,.method=if (wide) "division-wide-quotient-paired-v1" else "division-geometry-paired-v2",
		.divisor_bytes=options.width,.cpu_clock="CLOCK_PROCESS_CPUTIME_ID",.wall_clock="CLOCK_MONOTONIC",
		.seed_usage="0xB2D151A5 + divisor_bytes*257 + index; eight normalization shifts; engine seed does not alter inputs",
		.operation=if (wide) "positive magnitude byte buffers; size is dividend bytes minus divisor bytes, not actual quotient width; fixed short-carry B-Z versus wider outer fallback" else "positive magnitude byte buffers; size is dividend bytes minus divisor bytes, not actual quotient width; paired Knuth and selected B-Z",
		.normalization="six ABBA/BAAB half-pool samples; iterations gives verified calls per method/sample; 16 repeats at widths <=128, otherwise one; primary averages both methods; no subtraction",
		.verification="GMP references outside timing; full quotient and remainder magnitude comparison plus output canaries on every call",
		.allocator_coverage="prepared inputs and warmed scratch; each byte kernel resets an arena retaining capacity and poisons outputs; arithmetic allocation included; cold allocation unmeasured",
		.rows=rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(),report,.{});
	try std.Io.File.stdout().writeStreamingAll(init.io,json);
	try std.Io.File.stdout().writeStreamingAll(init.io,"\n");
}
