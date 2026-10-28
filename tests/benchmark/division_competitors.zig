//! Identical-input division across public BLIP, its kernels, and GMP.
const std = @import("std");
const blip = @import("blip_mp");
const Mp = blip.Mp;
const gmp = @import("gmp.zig");
const widths = [_]usize{ 8,16,32,64,128,256,512,1024,2048,4096,8192,16384 };
pub const Method = enum { public_blip, knuth, bz128, gmp, selected_bz };
const original_methods = [4]Method{.public_blip,.knuth,.bz128,.gmp};
const selected_methods = [4]Method{.public_blip,.knuth,.selected_bz,.gmp};
const Timing = struct { cpu_ns: f64, wall_ns: f64 };
const Sample = struct { cpu_ns: [4]f64, wall_ns: [4]f64 };
const Options = struct { sizes: [widths.len]usize, count: usize };

test "selected B-Z divides a normalized one-block value without recursive allocations" {
	// A normalized n-byte divisor is at least half the n-byte range. The
	// largest n-byte dividend therefore has q=1 and needs one subtraction.
	// Eight allocations cover the existing top-level byte buffers; denying
	// every later allocation proves this case avoids the recursive divider.
	for ([_]usize{64,128,256}) |width| {
		var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
		const a = arena.allocator();
		const u = try a.alloc(u8,width); @memset(u,255);
		const v = try a.alloc(u8,width); @memset(v,0); v[width-1] = 128;
		const q = try a.alloc(u8,3); @memset(q,0xa5);
		const r = try a.alloc(u8,width+2); @memset(r,0xa5);
		var control = std.testing.FailingAllocator.init(std.testing.allocator,.{.fail_index=8});
		try std.testing.expectError(error.OutOfMemory,blip.tier3.divModBurnikelZieglerCutoff128(u,width,v,width,q[1..2],r[1..width+1],control.allocator()));
		try std.testing.expect(control.has_induced_failure);
		try std.testing.expectEqual(control.allocated_bytes,control.freed_bytes);
		inline for (.{blip.tier3.divModBurnikelZieglerLeadingBlock,blip.tier3.divModBurnikelZiegler}) |divide| {
			var limited = std.testing.FailingAllocator.init(std.testing.allocator,.{.fail_index=8});
			const got = try divide(u,width,v,width,q[1..2],r[1..width+1],limited.allocator());
			try std.testing.expectEqual(@as(usize,1),got.q_len);
			try std.testing.expectEqual(width,got.r_len);
			try std.testing.expectEqualSlices(u8,&.{0xa5,1,0xa5},q);
			try std.testing.expectEqual(@as(u8,127),r[width]);
			for (r[1..width]) |byte| try std.testing.expectEqual(@as(u8,255),byte);
			try std.testing.expectEqual(@as(u8,0xa5),r[0]);
			try std.testing.expectEqual(@as(u8,0xa5),r[width+1]);
			try std.testing.expectEqual(limited.allocated_bytes,limited.freed_bytes);
		}
	}
}

fn parse(args: []const []const u8) !Options {
	if (args.len != 1) return error.InvalidArguments;
	var options: Options = .{ .sizes = undefined, .count = 0 };
	var parts = std.mem.splitScalar(u8,args[0],',');
	while (parts.next()) |part| {
		const width = std.fmt.parseInt(usize,part,10) catch return error.InvalidArguments;
		if (std.mem.indexOfScalar(usize,&widths,width) == null or options.count == widths.len) return error.InvalidArguments;
		if (options.count > 0 and width <= options.sizes[options.count-1]) return error.InvalidArguments;
		options.sizes[options.count] = width;
		options.count += 1;
	}
	return options;
}

test "short quotient dispatch classifies the one-chunk length bound before recursive allocation" {
	inline for (.{blip.tier3.divModBurnikelZieglerShortQuotient,blip.tier3.divModBurnikelZiegler}) |divide| for ([_]usize{64,128,256}) |width| {
		var accepted: [16]bool = @splat(false);
		const expected: [16]bool = .{true,true,true,true,true,true,true,true,false,false,false,false,false,false,false,false};
		for (0..accepted.len) |extra| {
			var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
			const a = arena.allocator();
			// u = beta^(width+extra)-1, v = beta^(width-1).
			// Thus q has extra+1 bytes of 255; r has width-1 bytes of 255.
			// Two high zero bytes prove the decision uses the trimmed length.
			const u = try a.alloc(u8,width+extra+2); @memset(u,255); @memset(u[width+extra..],0);
			const v = try a.alloc(u8,width); @memset(v,0); v[width-1] = 1;
			const q = try a.alloc(u8,extra+3); @memset(q,0xa5);
			const r = try a.alloc(u8,width+2); @memset(r,0xa5);
			var limited = std.testing.FailingAllocator.init(std.testing.allocator,.{.fail_index=1});
			if (divide(u,u.len,v,width,q[1..extra+2],r[1..width+1],limited.allocator())) |got| {
				accepted[extra] = true;
				try std.testing.expectEqual(extra+1,got.q_len);
				try std.testing.expectEqual(width-1,got.r_len);
				for (q[1..extra+2]) |byte| try std.testing.expectEqual(@as(u8,255),byte);
				for (r[1..width]) |byte| try std.testing.expectEqual(@as(u8,255),byte);
				try std.testing.expectEqual(@as(u8,0xa5),q[0]);
				try std.testing.expectEqual(@as(u8,0xa5),q[extra+2]);
				try std.testing.expectEqual(@as(u8,0xa5),r[0]);
				try std.testing.expectEqual(@as(u8,0xa5),r[width+1]);
			} else |err| try std.testing.expectEqual(error.OutOfMemory,err);
			try std.testing.expectEqual(limited.allocated_bytes,limited.freed_bytes);
		}
		try std.testing.expectEqualSlices(bool,&expected,&accepted);
	};
}

test "B-Z uses a short carried remainder to avoid recursive allocation" {
	for ([_]usize{64,65,128,256}) |width| for ([_]usize{0,7}) |index| {
		var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
		const a = arena.allocator();
		var case = try Case.initSized(a,std.testing.allocator,width,index,2*width); defer case.deinit();
		const q = try a.alloc(u8,width+3);
		const r = try a.alloc(u8,width+2);
		var allocations: [3]usize = undefined;
		inline for (.{blip.tier3.divModBurnikelZieglerShortQuotient,blip.tier3.divModBurnikelZieglerShortCarry,blip.tier3.divModBurnikelZiegler},0..) |divide,method| {
			@memset(q,0xa5); @memset(r,0xa5);
			var counted = std.testing.FailingAllocator.init(std.testing.allocator,.{});
			const got = try divide(case.dividend,case.dividend.len,case.divisor,width,q[1..width+2],r[1..width+1],counted.allocator());
			try std.testing.expectEqualSlices(u8,case.expected_q,q[1..1+got.q_len]);
			try std.testing.expectEqualSlices(u8,case.expected_r,r[1..1+got.r_len]);
			try std.testing.expectEqual(@as(u8,0xa5),q[0]);
			try std.testing.expectEqual(@as(u8,0xa5),q[width+2]);
			try std.testing.expectEqual(@as(u8,0xa5),r[0]);
			try std.testing.expectEqual(@as(u8,0xa5),r[width+1]);
			try std.testing.expectEqual(counted.allocated_bytes,counted.freed_bytes);
			allocations[method] = counted.alloc_index;
		}
		// Index zero normalizes a dense 2n-byte dividend into 2n+1 bytes:
		// its initial carried remainder is one byte. Index seven needs no
		// normalization shift, and odd divisors already use the Knuth leaf.
		if (width%2 == 0 and index == 0) {
			try std.testing.expect(allocations[1] < allocations[0]);
		} else try std.testing.expectEqual(allocations[0],allocations[1]);
		try std.testing.expectEqual(allocations[1],allocations[2]);
	};
}

test "short carry division handles exact blocks followed by zero and small blocks" {
	for ([_]usize{64,256}) |width| {
		var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
		const a = arena.allocator();
		const u = try a.alloc(u8,3*width); @memset(u,0); u[u.len-1] = 128; u[0] = 123;
		const v = try a.alloc(u8,width); @memset(v,0); v[width-1] = 128;
		const q = try a.alloc(u8,2*width+3); @memset(q,0xa5);
		const r = try a.alloc(u8,width+2); @memset(r,0xa5);
		const got = try blip.tier3.divModBurnikelZieglerShortCarry(u,u.len,v,width,q[1..2*width+2],r[1..width+1],std.testing.allocator);
		try std.testing.expectEqual(2*width+1,got.q_len);
		try std.testing.expectEqual(@as(usize,1),got.r_len);
		for (q[1..2*width+1]) |byte| try std.testing.expectEqual(@as(u8,0),byte);
		try std.testing.expectEqual(@as(u8,1),q[2*width+1]);
		try std.testing.expectEqual(@as(u8,123),r[1]);
		try std.testing.expectEqual(@as(u8,0xa5),q[0]);
		try std.testing.expectEqual(@as(u8,0xa5),q[2*width+2]);
		try std.testing.expectEqual(@as(u8,0xa5),r[0]);
		try std.testing.expectEqual(@as(u8,0xa5),r[width+1]);
	}
}

fn balancedSample(state: anytype, comptime batch: anytype, count: usize, repeats: usize, round: usize) !Sample {
	return sampleWith(original_methods,state,batch,count,repeats,round);
}

fn selectedSample(state: anytype, comptime batch: anytype, count: usize, repeats: usize, round: usize) !Sample {
	return sampleWith(selected_methods,state,batch,count,repeats,round);
}

fn sampleWith(comptime methods: [4]Method, state: anytype, comptime batch: anytype, count: usize, repeats: usize, round: usize) !Sample {
	if (count == 0 or count % 2 != 0 or repeats == 0) return error.InvalidArguments;
	var sample: Sample = .{ .cpu_ns = @splat(0), .wall_ns = @splat(0) };
	for (0..8) |position| {
		const index = ((if (position < 4) position else 7-position) + round) % 4;
		const duration = try batch(state,methods[index],if (position < 4) 0 else count/2,count/2,repeats);
		sample.cpu_ns[index] += duration.cpu_ns;
		sample.wall_ns[index] += duration.wall_ns;
	}
	for (&sample.cpu_ns,&sample.wall_ns) |*cpu,*wall| {
		cpu.* /= @floatFromInt(count*repeats); wall.* /= @floatFromInt(count*repeats);
	}
	return sample;
}

test "selected competitor timing substitutes only the B-Z slot" {
	const Fake = struct {
		position: usize = 0,
		calls: [8]Method = undefined,
		visits: [5][8]usize = @splat(@splat(0)),
		fn batch(self: *@This(), method: Method, start: usize, count: usize, repeats: usize) !Timing {
			for (start..start+count) |i| self.visits[@intFromEnum(method)][i] += repeats;
			self.calls[self.position] = method; self.position += 1;
			return .{.cpu_ns=@floatFromInt(count*repeats),.wall_ns=@floatFromInt(2*count*repeats)};
		}
	};
	const orders = [_][8]Method{
		.{.public_blip,.knuth,.selected_bz,.gmp,.gmp,.selected_bz,.knuth,.public_blip},
		.{.knuth,.selected_bz,.gmp,.public_blip,.public_blip,.gmp,.selected_bz,.knuth},
		.{.selected_bz,.gmp,.public_blip,.knuth,.knuth,.public_blip,.gmp,.selected_bz},
		.{.gmp,.public_blip,.knuth,.selected_bz,.selected_bz,.knuth,.public_blip,.gmp},
	};
	for (0..8) |round| {
		var fake: Fake = .{};
		const got = try selectedSample(&fake,Fake.batch,8,3,round);
		try std.testing.expectEqualSlices(Method,&orders[round%4],&fake.calls);
		try std.testing.expectEqualSlices(f64,&.{1,1,1,1},&got.cpu_ns);
		try std.testing.expectEqualSlices(f64,&.{2,2,2,2},&got.wall_ns);
		for (selected_methods) |method| try std.testing.expectEqualSlices(usize,&@as([8]usize,@splat(3)),&fake.visits[@intFromEnum(method)]);
		try std.testing.expectEqualSlices(usize,&@as([8]usize,@splat(0)),&fake.visits[@intFromEnum(Method.bz128)]);
	}
}

fn setMagnitude(value: *Mp, bytes: []const u8, allocator: std.mem.Allocator) !void {
	const magnitude = std.mem.trimEnd(u8,bytes,&.{0});
	if (magnitude.len == 0) return value.setU64(0);
	if (magnitude.len == 1 and magnitude[0] < 128) return value.setU64(magnitude[0]);
	const pad: usize = @intFromBool(magnitude[magnitude.len-1] & 0x80 != 0);
	const encoded = try allocator.alloc(u8,magnitude.len+pad+16);
	defer allocator.free(encoded);
	const header = try blip.tier3.writeHeader(encoded,magnitude.len+pad);
	@memcpy(encoded[header..][0..magnitude.len],magnitude);
	if (pad != 0) encoded[header+magnitude.len] = 0;
	try value.setBytes(encoded[0..header+magnitude.len+pad]);
}

pub const Case = struct {
	dividend: []u8, divisor: []u8, expected_q: []u8, expected_r: []u8,
	a: Mp, b: Mp, mq: Mp, mr: Mp,
	ga: gmp.Z, gb: gmp.Z, gq: gmp.Z, gr: gmp.Z,
	pub fn initSized(allocator: std.mem.Allocator, values_allocator: std.mem.Allocator, width: usize, index: usize, dividend_len: usize) !Case {
		var result: Case = .{
			.dividend = try allocator.alloc(u8,dividend_len), .divisor = try allocator.alloc(u8,width),
			.expected_q = try allocator.alloc(u8,dividend_len), .expected_r = try allocator.alloc(u8,width),
			.a = Mp.init(values_allocator), .b = Mp.init(values_allocator), .mq = Mp.init(values_allocator), .mr = Mp.init(values_allocator),
			.ga = undefined, .gb = undefined, .gq = undefined, .gr = undefined,
		};
		inline for (.{&result.ga,&result.gb,&result.gq,&result.gr}) |z| gmp.__gmpz_init(z);
		errdefer result.deinit();
		var rng = std.Random.DefaultPrng.init(0xB2D1_51A5 + width*257 + index);
		rng.random().bytes(result.dividend); rng.random().bytes(result.divisor);
		if (index%16 == 0) { @memset(result.dividend,255); @memset(result.divisor,255); }
		result.dividend[dividend_len-1] |= 0x80;
		const top = @as(u8,1) << @as(u3,@intCast(index%8));
		result.divisor[width-1] = (result.divisor[width-1] & (top-1)) | top;
		try setMagnitude(&result.a,result.dividend,allocator);
		try setMagnitude(&result.b,result.divisor,allocator);
		gmp.__gmpz_import(&result.ga,result.dividend.len,-1,1,0,0,result.dividend.ptr);
		gmp.__gmpz_import(&result.gb,result.divisor.len,-1,1,0,0,result.divisor.ptr);
		gmp.__gmpz_tdiv_qr(&result.gq,&result.gr,&result.ga,&result.gb);
		var q_len: usize = 0; var r_len: usize = 0;
		_ = gmp.__gmpz_export(result.expected_q.ptr,&q_len,-1,1,0,0,&result.gq);
		_ = gmp.__gmpz_export(result.expected_r.ptr,&r_len,-1,1,0,0,&result.gr);
		result.expected_q = result.expected_q[0..q_len]; result.expected_r = result.expected_r[0..r_len];
		try setMagnitude(&result.mq,result.expected_q,allocator);
		try setMagnitude(&result.mr,result.expected_r,allocator);
		return result;
	}
	fn init(allocator: std.mem.Allocator, values_allocator: std.mem.Allocator, width: usize, index: usize) !Case {
		return initSized(allocator,values_allocator,width,index,2*width);
	}
	pub fn deinit(self: *@This()) void {
		inline for (.{&self.ga,&self.gb,&self.gq,&self.gr}) |z| gmp.__gmpz_clear(z);
		self.a.deinit(); self.b.deinit(); self.mq.deinit(); self.mr.deinit();
	}
};
pub const Fixture = struct {
	cases: []Case,
	arena: std.heap.ArenaAllocator, scratch: std.heap.ArenaAllocator,
	q: Mp, r: Mp, gq: gmp.Z, gr: gmp.Z,
	quotient: []u8, remainder: []u8,
	fn init(parent: std.mem.Allocator, width: usize, count: usize) !Fixture {
		return initSized(parent,width,count,2*width);
	}
	pub fn initSized(parent: std.mem.Allocator, width: usize, count: usize, dividend_len: usize) !Fixture {
		if (std.mem.indexOfScalar(usize,&widths,width) == null or count == 0 or count > 64) return error.InvalidArguments;
		var arena = std.heap.ArenaAllocator.init(parent);
		errdefer arena.deinit();
		const allocator = arena.allocator();
		const cases = try allocator.alloc(Case,count);
		var initialized: usize = 0;
		errdefer for (cases[0..initialized]) |*case| case.deinit();
		for (cases,0..) |*case,index| {
			case.* = try Case.initSized(allocator,parent,width,index,dividend_len);
			initialized += 1;
		}
		const quotient = try allocator.alloc(u8,2*width+2);
		const remainder = try allocator.alloc(u8,width+2);
		var gq: gmp.Z = undefined; gmp.__gmpz_init(&gq);
		var gr: gmp.Z = undefined; gmp.__gmpz_init(&gr);
		return .{ .cases = cases, .arena = arena, .scratch = std.heap.ArenaAllocator.init(parent),
			.q = Mp.init(parent), .r = Mp.init(parent), .gq = gq, .gr = gr, .quotient = quotient, .remainder = remainder };
	}
	pub fn run(self: *@This(), method: Method, index: usize) !void {
		const case = &self.cases[index];
		switch (method) {
			.public_blip => {
				try Mp.divMod(&self.q,&self.r,&case.a,&case.b);
				if (!std.mem.eql(u8,self.q.bytes(),case.mq.bytes()) or !std.mem.eql(u8,self.r.bytes(),case.mr.bytes())) return error.IncorrectWork;
			},
			.gmp => {
				gmp.__gmpz_tdiv_qr(&self.gq,&self.gr,&case.ga,&case.gb);
				if (gmp.__gmpz_cmp(&self.gq,&case.gq) != 0 or gmp.__gmpz_cmp(&self.gr,&case.gr) != 0) return error.IncorrectWork;
			},
			.knuth, .bz128, .selected_bz => {
				if (!self.scratch.reset(.retain_capacity)) return error.OutOfMemory;
				@memset(self.quotient,0xa5); @memset(self.remainder,0xa5);
				const q = self.quotient[1..self.quotient.len-1]; const r = self.remainder[1..self.remainder.len-1];
				const q_len, const r_len = if (method == .knuth) blk: {
					const got = try blip.tier3.divModKnuthU64Bytes(case.dividend,case.dividend.len,case.divisor,case.divisor.len,q,r,self.scratch.allocator());
					break :blk .{got.q_len,got.r_len};
				} else if (method == .selected_bz) blk: {
					const got = try blip.tier3.divModBurnikelZiegler(case.dividend,case.dividend.len,case.divisor,case.divisor.len,q,r,self.scratch.allocator());
					break :blk .{got.q_len,got.r_len};
				} else blk: {
					const got = try blip.tier3.divModBurnikelZieglerCutoff128(case.dividend,case.dividend.len,case.divisor,case.divisor.len,q,r,self.scratch.allocator());
					break :blk .{got.q_len,got.r_len};
				};
				if (!std.mem.eql(u8,q[0..q_len],case.expected_q) or !std.mem.eql(u8,r[0..r_len],case.expected_r)) return error.IncorrectWork;
				if (self.quotient[0] != 0xa5 or self.quotient[self.quotient.len-1] != 0xa5 or self.remainder[0] != 0xa5 or self.remainder[self.remainder.len-1] != 0xa5) return error.CanaryDamaged;
			},
		}
	}
	pub fn corruptQuotient(self: *@This(), index: usize) !void {
		const case = &self.cases[index];
		case.expected_q[0] ^= 1;
		try setMagnitude(&case.mq,case.expected_q,self.arena.allocator());
		gmp.__gmpz_import(&case.gq,case.expected_q.len,-1,1,0,0,case.expected_q.ptr);
	}
	pub fn deinit(self: *@This()) void {
		blip.tier3.releaseBzArena(); blip.tier3.releaseMulScratch(); blip.tier3.releaseDivScratch(); blip.tier3.releaseVnScratch();
		self.q.deinit(); self.r.deinit();
		gmp.__gmpz_clear(&self.gq); gmp.__gmpz_clear(&self.gr);
		for (self.cases) |*case| case.deinit();
		self.scratch.deinit(); self.arena.deinit();
	}
};

test "competitor widths classify the bounded set and ordered lists" {
	var accepted: [16400]bool = @splat(false);
	var expected: [16400]bool = @splat(false);
	for (widths) |width| expected[width] = true;
	for (0..accepted.len) |width| {
		var buffer: [24]u8 = undefined;
		const input = try std.fmt.bufPrint(&buffer, "{d}", .{width});
		accepted[width] = if (parse(&.{input})) |_| true else |_| false;
	}
	try std.testing.expectEqualSlices(bool, &expected, &accepted);
	const options = try parse(&.{"8,16,32,64,128,256,512,1024,2048,4096,8192,16384"});
	try std.testing.expectEqualSlices(usize, &widths, options.sizes[0..options.count]);
	for ([_][]const u8{ "", "0", "64,", "64,64", "128,64", "-1", "x", "18446744073709551616" }) |invalid| {
		try std.testing.expectError(error.InvalidArguments, parse(&.{invalid}));
	}
	try std.testing.expectError(error.InvalidArguments, parse(&.{}));
	try std.testing.expectError(error.InvalidArguments, parse(&.{"64","128"}));
}

test "four-way timing rotates mirrored batches and covers each input once" {
	const Fake = struct {
		position: usize = 0,
		calls: [8]Method = undefined,
		visits: [4][8]usize = @splat(@splat(0)),
		fn batch(self: *@This(), method: Method, start: usize, count: usize, repeats: usize) !Timing {
			const index: usize = @intFromEnum(method);
			for (start .. start + count) |i| self.visits[index][i] += repeats;
			self.calls[self.position] = method;
			const duration: f64 = @floatFromInt((100 - 20 * index + 10 * self.position) * count * repeats);
			self.position += 1;
			return .{ .cpu_ns = duration, .wall_ns = duration + @as(f64,@floatFromInt(5*count*repeats)) };
		}
	};
	const orders = [_][8]Method{
		.{.public_blip,.knuth,.bz128,.gmp,.gmp,.bz128,.knuth,.public_blip},
		.{.knuth,.bz128,.gmp,.public_blip,.public_blip,.gmp,.bz128,.knuth},
		.{.bz128,.gmp,.public_blip,.knuth,.knuth,.public_blip,.gmp,.bz128},
		.{.gmp,.public_blip,.knuth,.bz128,.bz128,.knuth,.public_blip,.gmp},
	};
	for (0..8) |round| {
		var fake: Fake = .{};
		const got = try balancedSample(&fake, Fake.batch, 8, 3, round);
		try std.testing.expectEqualSlices(f64, &.{135,115,95,75}, &got.cpu_ns);
		try std.testing.expectEqualSlices(f64, &.{140,120,100,80}, &got.wall_ns);
		try std.testing.expectEqualSlices(Method, &orders[round%4], &fake.calls);
		for (fake.visits) |visits| try std.testing.expectEqualSlices(usize, &@as([8]usize,@splat(3)), &visits);
	}
	var fake: Fake = .{};
	for ([_]usize{0,1,7}) |count| try std.testing.expectError(error.InvalidArguments, balancedSample(&fake, Fake.batch, count, 3, 0));
	try std.testing.expectError(error.InvalidArguments, balancedSample(&fake, Fake.batch, 8, 0, 0));
	const Failure = struct {
		fn batch(_: void, _: Method, _: usize, _: usize, _: usize) error{Injected}!Timing { return error.Injected; }
	};
	try std.testing.expectError(error.Injected, balancedSample({}, Failure.batch, 8, 3, 0));
}

pub fn nativeBatch(fixture: *Fixture, method: Method, start: usize, count: usize, repeats: usize) !Timing {
	const Clock = struct {
		pub fn read(_: *@This(), kind: std.c.CLOCK) !u64 { return @import("immediate_add.zig").now(kind); }
	};
	var clock: Clock = .{};
	const got = try @import("division_crossover.zig").timedBatch(fixture,&clock,method,start,count,repeats);
	return .{ .cpu_ns = got.cpu_ns, .wall_ns = got.wall_ns };
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
	return runWith(false,init,args);
}

pub fn runSelected(init: std.process.Init, args: []const []const u8) !void {
	return runWith(true,init,args);
}

fn runWith(comptime selected: bool, init: std.process.Init, args: []const []const u8) !void {
	const methods = if (selected) selected_methods else original_methods;
	const options = try parse(args);
	const count = 64;
	const Component = struct { method: []const u8, cpu_ns: [8]f64, wall_ns: [8]f64 };
	const Row = struct {
		size: usize, fixture_count: usize = count, iterations: usize, warmup_cases: usize = count*4,
		divisor_min_bits: usize, divisor_max_bits: usize,
		samples: struct { cpu_ns: [8]f64, wall_ns: [8]f64 }, components: [4]Component,
	};
	var rows: [widths.len]Row = undefined;
	for (options.sizes[0..options.count],0..) |width,row_index| {
		var fixture = try Fixture.init(std.heap.c_allocator,width,count);
		defer fixture.deinit();
		for (0..count) |index| for (methods) |method| try fixture.run(method,index);
		const repeats = @import("division_crossover.zig").nativeRepeats(width);
		var row: Row = .{ .size = width, .iterations = count*repeats, .divisor_min_bits = width*8-7,
			.divisor_max_bits = width*8, .samples = undefined, .components = undefined };
		for (&row.components,methods) |*component,method| {
			component.* = .{ .method = @tagName(method), .cpu_ns = undefined, .wall_ns = undefined };
		}
		for (0..8) |round| {
			const sample = try sampleWith(methods,&fixture,nativeBatch,count,repeats,round);
			var cpu: f64 = 0; var wall: f64 = 0;
			for (&row.components,0..) |*component,index| {
				component.cpu_ns[round] = sample.cpu_ns[index]; component.wall_ns[round] = sample.wall_ns[index];
				cpu += sample.cpu_ns[index]; wall += sample.wall_ns[index];
			}
			row.samples.cpu_ns[round] = cpu/4; row.samples.wall_ns[round] = wall/4;
		}
		rows[row_index] = row;
	}
	const report = .{
		.schema = "performance-measurement/v1", .correct = true, .build_mode = "ReleaseFast",
		.compiler = @import("builtin").zig_version_string, .gmp_version = std.mem.span(gmp.__gmp_version),
		.method = if (selected) "division-selected-competitors-v1" else "division-native-competitors-v1",
		.cpu_clock = "CLOCK_PROCESS_CPUTIME_ID", .wall_clock = "CLOCK_MONOTONIC",
		.seed_usage = "0xB2D151A5 + divisor_bytes*257 + case_index; eight normalization shifts; engine seed does not alter inputs",
		.normalization = "rotating ABCDDCBA half-pool batches; eight samples; primary averages four methods per operation; no subtraction",
		.operation = "positive 2:1 magnitude byte widths; size is divisor bytes; inputs preconverted outside timing; every result fully checked",
		.verification = "public BLIP compares canonical bytes; GMP uses mpz_cmp; byte kernels compare magnitudes and canaries; comparison costs included",
		.allocator_coverage = "public BLIP and GMP reuse native results after warmup; byte kernels reset an arena retaining capacity and poison outputs; cold allocation unmeasured",
		.rows = rows[0..options.count],
	};
	const json = try std.json.Stringify.valueAlloc(init.arena.allocator(),report,.{});
	try std.Io.File.stdout().writeStreamingAll(init.io,json);
	try std.Io.File.stdout().writeStreamingAll(init.io,"\n");
}

test "all competitors agree with complete references and reject corrupted quotients" {
	for (widths) |width| {
		var fixture = try Fixture.init(std.testing.allocator, width, 8);
		defer fixture.deinit();
		for (fixture.cases, 0..) |_, index| {
			for (std.enums.values(Method)) |method| try fixture.run(method,index);
			try fixture.corruptQuotient(index);
			for (std.enums.values(Method)) |method| try std.testing.expectError(error.IncorrectWork, fixture.run(method,index));
		}
	}
}

test "small competitor oracle agrees with independent native division" {
	var fixture = try Fixture.init(std.testing.allocator,8,8);
	defer fixture.deinit();
	for (fixture.cases) |case| {
		const a = std.mem.readInt(u128,case.dividend[0..16],.little);
		const b = std.mem.readInt(u64,case.divisor[0..8],.little);
		var q: [16]u8 = undefined; var r: [16]u8 = undefined;
		std.mem.writeInt(u128,&q,a/b,.little);
		std.mem.writeInt(u128,&r,a%b,.little);
		try std.testing.expectEqualSlices(u8,std.mem.trimEnd(u8,&q,&.{0}),case.expected_q);
		try std.testing.expectEqualSlices(u8,std.mem.trimEnd(u8,&r,&.{0}),case.expected_r);
	}
}

test "competitor fixtures and arithmetic release partial allocations" {
	const FailureCase = struct {
		fn run(allocator: std.mem.Allocator) !void {
			var fixture = try Fixture.init(allocator,16,2);
			defer fixture.deinit();
			for (std.enums.values(Method)) |method| try fixture.run(method,0);
		}
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator,FailureCase.run,.{});
}

test "explicit B-Z allocation failures release memory including optional cache recovery" {
	const Check = struct {
		fn run(comptime divide: anytype, allocator: std.mem.Allocator, width: usize, dividend_len: usize) !void {
			var fixture = try Fixture.initSized(allocator,width,1,dividend_len); defer fixture.deinit();
			try divide(&fixture.q,&fixture.r,&fixture.cases[0].a,&fixture.cases[0].b);
			try std.testing.expectEqualSlices(u8,fixture.cases[0].mq.bytes(),fixture.q.bytes());
			try std.testing.expectEqualSlices(u8,fixture.cases[0].mr.bytes(),fixture.r.bytes());
		}
	};
	inline for (.{Mp.divModBurnikelZiegler,Mp.divModBurnikelZieglerLeadingBlock,Mp.divModBurnikelZieglerShortQuotient,Mp.divModBurnikelZieglerShortCarry}) |divide| for ([_]usize{16,256}) |width| for ([_]usize{width+1,2*width}) |dividend_len| {
		var baseline = std.testing.FailingAllocator.init(std.testing.allocator,.{});
		try Check.run(divide,baseline.allocator(),width,dividend_len);
		try std.testing.expectEqual(baseline.allocated_bytes,baseline.freed_bytes);
		for (0..baseline.alloc_index) |index| {
			var failing = std.testing.FailingAllocator.init(std.testing.allocator,.{ .fail_index = index });
			Check.run(divide,failing.allocator(),width,dividend_len) catch |err| try std.testing.expectEqual(error.OutOfMemory,err);
			try std.testing.expect(failing.has_induced_failure);
			try std.testing.expectEqual(failing.allocated_bytes,failing.freed_bytes);
		}
	};
}

test "explicit public B-Z division preserves signed results and input aliases" {
	var zero = Mp.init(std.testing.allocator); defer zero.deinit();
	try zero.setI64(0);
	for ([_]usize{8,64,128,256}) |width| {
		var fixture = try Fixture.init(std.testing.allocator,width,32); defer fixture.deinit();
		for (fixture.cases,0..) |*case,index| {
			const negative_a = (index/8)%4 == 1 or (index/8)%4 == 3;
			const negative_b = (index/8)%4 >= 2;
			if (negative_a) {
				try case.a.sub(&zero,&case.a); try case.mr.sub(&zero,&case.mr);
			}
			if (negative_b) try case.b.sub(&zero,&case.b);
			if (negative_a != negative_b) try case.mq.sub(&zero,&case.mq);
			inline for (.{Mp.divModBurnikelZiegler,Mp.divModBurnikelZieglerLeadingBlock,Mp.divModBurnikelZieglerShortQuotient,Mp.divModBurnikelZieglerShortCarry}) |divide| for (0..3) |alias_mode| {
				var a = Mp.init(std.testing.allocator); defer a.deinit();
				var b = Mp.init(std.testing.allocator); defer b.deinit();
				try a.setBytes(case.a.bytes()); try b.setBytes(case.b.bytes());
				const q = switch (alias_mode) { 0 => &fixture.q, 1 => &a, else => &b };
				const r = switch (alias_mode) { 0 => &fixture.r, 1 => &b, else => &a };
				try divide(q,r,&a,&b);
				try std.testing.expectEqualSlices(u8,case.mq.bytes(),q.bytes());
				try std.testing.expectEqualSlices(u8,case.mr.bytes(),r.bytes());
			};
		}
	}
}
