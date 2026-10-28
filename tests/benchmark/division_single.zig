//! Variable register-sized divisors over byte payloads, verified against GMP.
const std = @import("std");
const blip = @import("blip_mp");
const gmp = @import("gmp.zig");
const Case = @import("division_competitors.zig").Case;
const timing = @import("division_crossover.zig");
const widths = [_]usize{8,9,16,17,64,65,256,257,1024,1025,4096,4097};
const divisor_widths = [_]usize{1,2,4,8};
const Method = enum { current, reciprocal, gmp };
const Options = struct { divisor_bytes: usize, sizes: [widths.len]usize, count: usize };

fn parse(args: []const []const u8) !Options {
	if (args.len!=2) return error.InvalidArguments;
	const divisor = std.fmt.parseInt(usize,args[0],10) catch return error.InvalidArguments;
	if (std.mem.indexOfScalar(usize,&divisor_widths,divisor)==null) return error.InvalidArguments;
	var options: Options = .{.divisor_bytes=divisor,.sizes=undefined,.count=0};
	var parts = std.mem.splitScalar(u8,args[1],',');
	while (parts.next()) |part| {
		const width = std.fmt.parseInt(usize,part,10) catch return error.InvalidArguments;
		if (std.mem.indexOfScalar(usize,&widths,width)==null or options.count==widths.len) return error.InvalidArguments;
		if (options.count>0 and width<=options.sizes[options.count-1]) return error.InvalidArguments;
		options.sizes[options.count]=width; options.count+=1;
	}
	return options;
}

pub const Pool = struct {
	cases: []Case, work: []u8, arena: std.heap.ArenaAllocator, q: gmp.Z, r: gmp.Z,
	pub fn init(parent: std.mem.Allocator, divisor: usize, width: usize, count: usize) !@This() {
		var arena = std.heap.ArenaAllocator.init(parent); errdefer arena.deinit();
		const allocator = arena.allocator();
		const cases = try allocator.alloc(Case,count);
		var initialized: usize = 0;
		errdefer for (cases[0..initialized]) |*case| case.deinit();
		for (cases,0..) |*case,index| {
			case.* = try Case.initSized(allocator,parent,divisor,index,width);
			initialized += 1;
		}
		const work = try allocator.alloc(u8,width+2);
		var q: gmp.Z = undefined; gmp.__gmpz_init(&q);
		var r: gmp.Z = undefined; gmp.__gmpz_init(&r);
		return .{.cases=cases,.work=work,.arena=arena,.q=q,.r=r};
	}
	pub fn run(self: *@This(), method: Method, index: usize) !void {
		const case = &self.cases[index];
		switch (method) {
			.current, .reciprocal => {
				self.work[0]=0xa5; self.work[self.work.len-1]=0xa5;
				const payload = self.work[1..self.work.len-1];
				@memcpy(payload,case.dividend);
				const divisor = asU64(case.divisor);
				var q_len: usize = undefined;
				var remainder: u64 = undefined;
				if (method == .current) {
					const got = blip.tier3.divModSingleU64(payload,payload.len,divisor);
					q_len = got.q_len; remainder = got.rem;
				} else {
					const got = blip.tier3.divModSingleReciprocal(payload,payload.len,divisor);
					q_len = got.q_len; remainder = got.rem;
				}
				if (!std.mem.eql(u8,payload[0..q_len],case.expected_q) or remainder!=asU64(case.expected_r)) return error.IncorrectWork;
				if (self.work[0]!=0xa5 or self.work[self.work.len-1]!=0xa5) return error.CanaryDamaged;
			},
			.gmp => {
				gmp.__gmpz_tdiv_qr(&self.q,&self.r,&case.ga,&case.gb);
				if (gmp.__gmpz_cmp(&self.q,&case.gq)!=0 or gmp.__gmpz_cmp(&self.r,&case.gr)!=0) return error.IncorrectWork;
			},
		}
	}
	pub fn deinit(self: *@This()) void {
		for (self.cases) |*case| case.deinit();
		gmp.__gmpz_clear(&self.q); gmp.__gmpz_clear(&self.r);
		self.arena.deinit();
	}
};

fn nativeBatch(pool: *Pool, method: Method, start: usize, count: usize, repeats: usize) !struct { cpu_ns: f64, wall_ns: f64 } {
	const Clock = struct {
		pub fn read(_: *@This(), kind: std.c.CLOCK) !u64 { return @import("immediate_add.zig").now(kind); }
	};
	var clock: Clock = .{};
	const got = try timing.timedBatch(pool,&clock,method,start,count,repeats);
	return .{.cpu_ns=got.cpu_ns,.wall_ns=got.wall_ns};
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
	return runComparison(init,args,false);
}

pub fn runReciprocal(init: std.process.Init, args: []const []const u8) !void {
	return runComparison(init,args,true);
}

fn runComparison(init: std.process.Init, args: []const []const u8, comptime reciprocal: bool) !void {
	const options = try parse(args);
	const count = 32;
	const repeats = 512;
	const methods: [2]Method = if (reciprocal) .{.current,.reciprocal} else .{.current,.gmp};
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
			const sample = try timing.pairedSample(&pool,nativeBatch,methods,count,repeats,round);
			for (&row.components,0..) |*component,mi| { component.cpu_ns[round]=sample.cpu_ns[mi]; component.wall_ns[round]=sample.wall_ns[mi]; }
			row.samples.cpu_ns[round]=(sample.cpu_ns[0]+sample.cpu_ns[1])/2;
			row.samples.wall_ns[round]=(sample.wall_ns[0]+sample.wall_ns[1])/2;
		}
		rows[index]=row;
	}
	const report = .{
		.schema="performance-measurement/v1",.correct=true,.build_mode="ReleaseFast",
		.compiler=@import("builtin").zig_version_string,.gmp_version=std.mem.span(gmp.__gmp_version),
		.method=if (reciprocal) "division-single-reciprocal-paired-v1" else "division-single-variable-paired-v1",.divisor_bytes=options.divisor_bytes,
		.divisor_min_bits=8*options.divisor_bytes-7,.divisor_max_bits=8*options.divisor_bytes,
		.cpu_clock="CLOCK_PROCESS_CPUTIME_ID",.wall_clock="CLOCK_MONOTONIC",
		.seed_usage="0xB2D151A5 + divisor_bytes*257 + index; eight normalization shifts; engine seed does not alter inputs",
		.operation=if (reciprocal) "positive byte payload divided by variable 1/2/4/8-byte magnitude; size is dividend bytes; current versus reciprocal byte kernels" else "positive byte payload divided by variable 1/2/4/8-byte magnitude; size is dividend bytes; in-place BLIP byte kernel versus GMP mpz_tdiv_qr",
		.normalization="six ABBA/BAAB half-pool samples; 512 repeats per fixture at every size; primary averages two methods; no subtraction",
		.verification="GMP references outside timing, checked against native arithmetic in tests; full quotient/remainder comparison on every call; byte-kernel canaries",
		.allocator_coverage=if (reciprocal) "prepared inputs and reused outputs; both kernels include input copy, variable divisor decode and complete comparisons; reciprocal setup included on every call; cold allocations unmeasured" else "prepared inputs and reused outputs; byte kernel includes input copy and divisor decode, GMP uses preconverted mpz inputs; comparison costs included; cold allocations unmeasured",
		.rows=rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(),report,.{});
	try std.Io.File.stdout().writeStreamingAll(init.io,json);
	try std.Io.File.stdout().writeStreamingAll(init.io,"\n");
}

test "single divisor parser classifies width pairs and ordered size lists" {
	for (0..10) |divisor| for (0..4100) |width| {
		var db: [24]u8 = undefined; var wb: [24]u8 = undefined;
		const da = try std.fmt.bufPrint(&db,"{d}",.{divisor});
		const wa = try std.fmt.bufPrint(&wb,"{d}",.{width});
		const accepted = if (parse(&.{da,wa})) |options| blk: {
			try std.testing.expectEqual(divisor,options.divisor_bytes);
			try std.testing.expectEqual(@as(usize,1),options.count);
			try std.testing.expectEqual(width,options.sizes[0]); break :blk true;
		} else |err| blk: { try std.testing.expectEqual(error.InvalidArguments,err); break :blk false; };
		const allowed_divisors = [_]usize{1,2,4,8};
		const allowed_sizes = [_]usize{8,9,16,17,64,65,256,257,1024,1025,4096,4097};
		try std.testing.expectEqual(std.mem.indexOfScalar(usize,&allowed_divisors,divisor)!=null and std.mem.indexOfScalar(usize,&allowed_sizes,width)!=null,accepted);
	};
	const options = try parse(&.{"8","8,9,16,17,64,65,256,257,1024,1025,4096,4097"});
	try std.testing.expectEqualSlices(usize,&widths,options.sizes[0..options.count]);
	for ([_][]const u8{"","8,","8,8","9,8","-1","x","18446744073709551616"}) |arg| try std.testing.expectError(error.InvalidArguments,parse(&.{"8",arg}));
	for ([_][]const u8{"","-1","x","18446744073709551616"}) |arg| try std.testing.expectError(error.InvalidArguments,parse(&.{arg,"8"}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{"8"}));
	try std.testing.expectError(error.InvalidArguments,parse(&.{"8","8","9"}));
}

fn asU64(bytes: []const u8) u64 {
	std.debug.assert(bytes.len<=8);
	var value: u64 = 0;
	for (bytes,0..) |byte,index| value |= @as(u64,byte)<<@as(u6,@intCast(8*index));
	return value;
}

test "single divisor fixtures match native division across every byte normalization shift" {
	for (divisor_widths) |divisor| inline for (.{8,16}) |width| {
		var pool = try Pool.init(std.testing.allocator,divisor,width,8); defer pool.deinit();
		for (pool.cases,0..) |case,index| {
			const a: u128 = if (width==16) std.mem.readInt(u128,case.dividend[0..16],.little) else std.mem.readInt(u64,case.dividend[0..8],.little);
			const b = asU64(case.divisor);
			var q: [16]u8 = undefined; var r: [16]u8 = undefined;
			std.mem.writeInt(u128,&q,a/b,.little); std.mem.writeInt(u128,&r,a%b,.little);
			try std.testing.expectEqualSlices(u8,std.mem.trimEnd(u8,&q,&.{0}),case.expected_q);
			try std.testing.expectEqualSlices(u8,std.mem.trimEnd(u8,&r,&.{0}),case.expected_r);
			try std.testing.expectEqual(@as(usize,8*divisor-7+index),64-@as(usize,@clz(b)));
			for (std.enums.values(Method)) |method| try pool.run(method,index);
		}
	};
}

test "single divisor probe checks aligned and partial payloads and rejects corrupted references" {
	for (divisor_widths) |divisor| for (widths) |width| {
		var pool = try Pool.init(std.testing.allocator,divisor,width,8); defer pool.deinit();
		for (0..pool.cases.len) |index| for (std.enums.values(Method)) |method| try pool.run(method,index);
		try std.testing.expectEqual(@as(u8,0xa5),pool.work[0]);
		try std.testing.expectEqual(@as(u8,0xa5),pool.work[pool.work.len-1]);
		const case = &pool.cases[0];
		case.expected_q[0] ^= 1;
		gmp.__gmpz_import(&case.gq,case.expected_q.len,-1,1,0,0,case.expected_q.ptr);
		for (std.enums.values(Method)) |method| try std.testing.expectError(error.IncorrectWork,pool.run(method,0));
		case.expected_q[0] ^= 1;
		gmp.__gmpz_import(&case.gq,case.expected_q.len,-1,1,0,0,case.expected_q.ptr);
		var bad_remainder: [8]u8 = undefined;
		std.mem.writeInt(u64,&bad_remainder,asU64(case.expected_r)+1,.little);
		case.expected_r = bad_remainder[0..std.mem.trimEnd(u8,&bad_remainder,&.{0}).len];
		gmp.__gmpz_import(&case.gr,case.expected_r.len,-1,1,0,0,case.expected_r.ptr);
		for (std.enums.values(Method)) |method| try std.testing.expectError(error.IncorrectWork,pool.run(method,0));
	};
}

test "single divisor probe releases every partial allocation" {
	const Check = struct {
		fn run(allocator: std.mem.Allocator) !void {
			var pool = try Pool.init(allocator,8,257,2); defer pool.deinit();
			for (std.enums.values(Method)) |method| try pool.run(method,0);
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator,Check.run,.{});
}
