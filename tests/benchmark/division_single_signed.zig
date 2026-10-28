//! Signed small-divisor comparison fixtures, including the reciprocal boundary.
const std = @import("std");
const blip = @import("blip_mp");
const Mp = blip.Mp;
const gmp = @import("gmp.zig");
const Base = @import("division_single.zig").Pool;
const Method = enum { current, reciprocal, gmp };

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
			.current => try Mp.divMod(&self.q,&self.r,&case.a,&case.b),
			.reciprocal => try Mp.divModSmallReciprocal(&self.q,&self.r,&case.a,&case.b),
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
