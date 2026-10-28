//! Signed small-divisor comparison fixtures, including the reciprocal boundary.
const std = @import("std");
const blip = @import("blip_mp");
const Mp = blip.Mp;
const gmp = @import("gmp.zig");
const Base = @import("division_single.zig").Pool;
const Method = enum { current, reciprocal, gmp };
const widths = [_]usize{8,9,16,17,63,64,65,256,257,1024,1025,4096,4097};
const Comparison = enum { public, gmp };
const Options = struct { comparison: Comparison, divisor_bytes: usize, sizes: [widths.len]usize, count: usize };

fn parse(args: []const []const u8) !Options {
	if (args.len!=3) return error.InvalidArguments;
	const comparison = std.meta.stringToEnum(Comparison,args[0]) orelse return error.InvalidArguments;
	const divisor = std.fmt.parseInt(usize,args[1],10) catch return error.InvalidArguments;
	if (std.mem.indexOfScalar(usize,&.{1,2,4,8},divisor)==null) return error.InvalidArguments;
	var options: Options = .{.comparison=comparison,.divisor_bytes=divisor,.sizes=undefined,.count=0};
	var parts = std.mem.splitScalar(u8,args[2],',');
	while (parts.next()) |part| {
		const width = std.fmt.parseInt(usize,part,10) catch return error.InvalidArguments;
		if (std.mem.indexOfScalar(usize,&widths,width)==null or options.count==widths.len) return error.InvalidArguments;
		if (options.count>0 and width<=options.sizes[options.count-1]) return error.InvalidArguments;
		options.sizes[options.count]=width; options.count+=1;
	}
	return options;
}

fn nativeBatch(pool: *Pool, method: Method, start: usize, count: usize, repeats: usize) !struct { cpu_ns: f64, wall_ns: f64 } {
	const Clock = struct {
		pub fn read(_: *@This(), kind: std.c.CLOCK) !u64 { return @import("immediate_add.zig").now(kind); }
	};
	var clock: Clock = .{};
	const got = try @import("division_crossover.zig").timedBatch(pool,&clock,method,start,count,repeats);
	return .{.cpu_ns=got.cpu_ns,.wall_ns=got.wall_ns};
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
	const options = try parse(args);
	const count = 32;
	const repeats = 512;
	const methods: [2]Method = if (options.comparison==.public) .{.current,.reciprocal} else .{.gmp,.reciprocal};
	const Component = struct { method: []const u8, cpu_ns: [6]f64, wall_ns: [6]f64 };
	const Row = struct {
		size: usize, fixture_count: usize = count, iterations: usize = count*repeats, warmup_cases: usize = 2*count,
		samples: struct { cpu_ns: [6]f64, wall_ns: [6]f64 }, components: [2]Component,
	};
	var rows: [widths.len]Row = undefined;
	for (options.sizes[0..options.count],0..) |width,index| {
		var pool = try Pool.init(std.heap.c_allocator,options.divisor_bytes,width,count); defer pool.deinit();
		for (0..count) |i| for (methods) |method| try pool.run(method,i);
		var row: Row = .{.size=width,.samples=undefined,.components=undefined};
		for (&row.components,methods) |*component,method| component.*=.{.method=@tagName(method),.cpu_ns=undefined,.wall_ns=undefined};
		for (0..6) |round| {
			const sample = try @import("division_crossover.zig").pairedSample(&pool,nativeBatch,methods,count,repeats,round);
			for (&row.components,0..) |*component,mi| { component.cpu_ns[round]=sample.cpu_ns[mi]; component.wall_ns[round]=sample.wall_ns[mi]; }
			row.samples.cpu_ns[round]=(sample.cpu_ns[0]+sample.cpu_ns[1])/2;
			row.samples.wall_ns[round]=(sample.wall_ns[0]+sample.wall_ns[1])/2;
		}
		rows[index]=row;
	}
	const report = .{
		.schema="performance-measurement/v1",.correct=true,.build_mode="ReleaseFast",
		.compiler=@import("builtin").zig_version_string,.gmp_version=std.mem.span(gmp.__gmp_version),
		.method=if (options.comparison==.public) "division-single-signed-public-paired-v1" else "division-single-signed-gmp-paired-v1",
		.divisor_bytes=options.divisor_bytes,.divisor_min_bits=8*options.divisor_bytes-7,.divisor_max_bits=8*options.divisor_bytes,
		.cpu_clock="CLOCK_PROCESS_CPUTIME_ID",.wall_clock="CLOCK_MONOTONIC",
		.seed_usage="0xB2D151A5 + divisor_bytes*257 + index; eight normalization shifts in each of four sign combinations; engine seed does not alter inputs",
		.operation="signed truncated quotient and remainder; variable 1/2/4/8-byte divisor magnitude; size is dividend magnitude bytes; reciprocal entry retains original kernel below 64 bytes",
		.normalization="six ABBA/BAAB half-pool samples; 512 repeats per fixture; primary averages two methods; no subtraction",
		.verification="GMP references outside timing, native signed oracle in tests; complete canonical BLIP or GMP quotient/remainder comparison on every call",
		.allocator_coverage="prepared signed inputs, reused outputs and warmed scratch; both BLIP entries called without inlining; BLIP conversion, arithmetic allocation and encoding included; GMP uses preconverted mpz inputs; full comparisons included; cold allocation unmeasured",
		.rows=rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(),report,.{});
	try std.Io.File.stdout().writeStreamingAll(init.io,json);
	try std.Io.File.stdout().writeStreamingAll(init.io,"\n");
}

test "signed small-divisor parser classifies comparisons and complete width sets" {
	const divisor_widths = [_]usize{1,2,4,8};
	const dividend_widths = [_]usize{8,9,16,17,63,64,65,256,257,1024,1025,4096,4097};
	for (std.enums.values(Comparison)) |comparison| for (0..10) |divisor| for (0..4100) |width| {
		var db: [24]u8 = undefined; var wb: [24]u8 = undefined;
		const da = try std.fmt.bufPrint(&db,"{d}",.{divisor}); const wa = try std.fmt.bufPrint(&wb,"{d}",.{width});
		const accepted = if (parse(&.{@tagName(comparison),da,wa})) |options| blk: {
			try std.testing.expectEqual(comparison,options.comparison);
			try std.testing.expectEqual(divisor,options.divisor_bytes);
			try std.testing.expectEqual(@as(usize,1),options.count);
			try std.testing.expectEqual(width,options.sizes[0]); break :blk true;
		} else |err| blk: { try std.testing.expectEqual(error.InvalidArguments,err); break :blk false; };
		try std.testing.expectEqual(std.mem.indexOfScalar(usize,&divisor_widths,divisor)!=null and std.mem.indexOfScalar(usize,&dividend_widths,width)!=null,accepted);
	};
	const options = try parse(&.{"public","8","8,9,16,17,63,64,65,256,257,1024,1025,4096,4097"});
	try std.testing.expectEqualSlices(usize,&dividend_widths,options.sizes[0..options.count]);
	for ([_][]const u8{"","8,","8,8","9,8","-1","x","18446744073709551616"}) |arg| try std.testing.expectError(error.InvalidArguments,parse(&.{"public","8",arg}));
	for ([_][]const u8{"","-1","x","18446744073709551616"}) |arg| try std.testing.expectError(error.InvalidArguments,parse(&.{"public",arg,"8"}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{"unknown","8","8"}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{"public","8"}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{"public","8","8","9"}));
}

const Pool = struct {
	base: Base, q: Mp, r: Mp,
	fn init(parent: std.mem.Allocator, divisor: usize, width: usize, count: usize) !@This() {
		var base = try Base.init(parent,divisor,width,count);
		errdefer {
			blip.tier3.releaseDivScratch(); blip.tier3.releaseMulScratch(); blip.tier3.releaseVnScratch();
			base.deinit();
		}
		var zero = Mp.init(parent); defer zero.deinit(); try zero.setI64(0);
		for (base.cases,0..) |*case,index| {
			const negative_a = (index/8)%4==1 or (index/8)%4==3;
			const negative_b = (index/8)%4>=2;
			if (negative_a) {
				try case.a.sub(&zero,&case.a); try case.mr.sub(&zero,&case.mr);
				gmp.__gmpz_neg(&case.ga,&case.ga); gmp.__gmpz_neg(&case.gr,&case.gr);
			}
			if (negative_b) { try case.b.sub(&zero,&case.b); gmp.__gmpz_neg(&case.gb,&case.gb); }
			if (negative_a!=negative_b) { try case.mq.sub(&zero,&case.mq); gmp.__gmpz_neg(&case.gq,&case.gq); }
		}
		return .{.base=base,.q=Mp.init(parent),.r=Mp.init(parent)};
	}
	pub fn run(self: *@This(), method: Method, index: usize) !void {
		const case = &self.base.cases[index];
		switch (method) {
			.current => try @call(.never_inline,Mp.divMod,.{&self.q,&self.r,&case.a,&case.b}),
			.reciprocal => try @call(.never_inline,Mp.divModSmallReciprocal,.{&self.q,&self.r,&case.a,&case.b}),
			.gmp => return self.base.run(.gmp,index),
		}
		if (!std.mem.eql(u8,self.q.bytes(),case.mq.bytes()) or !std.mem.eql(u8,self.r.bytes(),case.mr.bytes())) return error.IncorrectWork;
	}
	fn deinit(self: *@This()) void {
		blip.tier3.releaseDivScratch();
		blip.tier3.releaseMulScratch();
		blip.tier3.releaseVnScratch();
		self.q.deinit(); self.r.deinit(); self.base.deinit();
	}
};

fn asSigned(value: *const Mp) i256 {
	const payload = value.payload();
	var bytes: [32]u8 = @splat(if (payload[payload.len-1]&0x80!=0) 255 else 0);
	@memcpy(bytes[0..payload.len],payload);
	return std.mem.readInt(i256,&bytes,.little);
}

test "signed small-divisor fixtures agree with native signed division in every sign and normalization" {
	for ([_]usize{1,2,4,8}) |divisor| for ([_]usize{8,16}) |width| {
		var pool = try Pool.init(std.testing.allocator,divisor,width,32); defer pool.deinit();
		for (pool.base.cases,0..) |*case,index| {
			const a = asSigned(&case.a); const b = asSigned(&case.b);
			try std.testing.expectEqual(@divTrunc(a,b),asSigned(&case.mq));
			try std.testing.expectEqual(@rem(a,b),asSigned(&case.mr));
			try std.testing.expectEqual((index/8)%4==1 or (index/8)%4==3,a<0);
			try std.testing.expectEqual((index/8)%4>=2,b<0);
			for (std.enums.values(Method)) |method| try pool.run(method,index);
		}
	};
}

test "signed reciprocal preserves GMP results and input-output aliases across its cutoff and heap boundary" {
	for ([_]usize{1,2,4,8,9}) |divisor| for ([_]usize{16,63,64,65,257,4097}) |width| {
		var pool = try Pool.init(std.testing.allocator,divisor,width,32); defer pool.deinit();
		for (pool.base.cases,0..) |*case,index| {
			for (std.enums.values(Method)) |method| try pool.run(method,index);
			for ([_]bool{false,true}) |swap| {
				var a = Mp.init(std.testing.allocator); defer a.deinit();
				var b = Mp.init(std.testing.allocator); defer b.deinit();
				try a.setBytes(case.a.bytes()); try b.setBytes(case.b.bytes());
				const q = if (swap) &b else &a; const r = if (swap) &a else &b;
				try Mp.divModSmallReciprocal(q,r,&a,&b);
				try std.testing.expectEqualSlices(u8,case.mq.bytes(),q.bytes());
				try std.testing.expectEqualSlices(u8,case.mr.bytes(),r.bytes());
			}
		}
	};
}

test "signed small-divisor comparison rejects separately corrupted quotient and remainder references" {
	for ([_]bool{false,true}) |remainder| {
		var pool = try Pool.init(std.testing.allocator,8,65,32); defer pool.deinit();
		const index = 24;
		const case = &pool.base.cases[index];
		for (std.enums.values(Method)) |method| try pool.run(method,index);
		if (remainder) {
			try case.mr.setBytes(case.b.bytes());
			gmp.__gmpz_import(&case.gr,case.divisor.len,-1,1,0,0,case.divisor.ptr);
		} else {
			try case.mq.setI64(0);
			gmp.__gmpz_import(&case.gq,0,-1,1,0,0,case.divisor.ptr);
		}
		for (std.enums.values(Method)) |method| try std.testing.expectError(error.IncorrectWork,pool.run(method,index));
	}
}

test "signed reciprocal releases partial construction and cold scratch on allocation failure" {
	const Check = struct {
		fn run(allocator: std.mem.Allocator, width: usize, count: usize) !void {
			blip.tier3.releaseDivScratch();
			var pool = try Pool.init(allocator,8,width,count); defer pool.deinit();
			try pool.run(.reciprocal,count-1);
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator,Check.run,.{@as(usize,257),@as(usize,25)});
	try std.testing.checkAllAllocationFailures(std.testing.allocator,Check.run,.{@as(usize,4097),@as(usize,1)});
}
