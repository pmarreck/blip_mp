//! Fixed-input kernel and public-API comparisons; setup is outside the timer.
const std = @import("std");
const lib = @import("blip_mp");
const fft = lib.fft;
const clock = @import("time_util");
const allocator = std.heap.c_allocator;

fn cpuNs() u64 {
	var ts: clock.TimeSpec = undefined;
	const rc = clock.clock_gettime(@intFromEnum(std.posix.CLOCK.PROCESS_CPUTIME_ID), &ts);
	if (rc != 0) @panic("process CPU clock failed");
	return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

pub fn run() !void {
	for ([_]usize{ 512, 4096, 8192, 32768 }) |size| {
		const a = try allocator.alloc(u8, size);
		defer allocator.free(a);
		const b = try allocator.alloc(u8, size);
		defer allocator.free(b);
		const out = try allocator.alloc(u8, 2 * size);
		defer allocator.free(out);
		var rng = std.Random.DefaultPrng.init(0x579_B11F);
		rng.random().bytes(a);
		rng.random().bytes(b);
		a[size - 1] = 0x51;
		b[size - 1] = 0x61;
		const work = try allocator.alloc(u8, lib.tier3.toom3ScratchNeed(size));
		defer allocator.free(work);
		var n: usize = 1;
		while (n < 2 * size) n *= 2;
		const small_bytes = n * fft.residue.slot_bytes;
		const small = try allocator.alloc(u8, 4 * small_bytes);
		defer allocator.free(small);
		const gold_bytes = n / 2 * fft.gold_residue.slot_bytes;
		const gold = try allocator.alloc(u8, 4 * gold_bytes);
		defer allocator.free(gold);
		var ma = lib.Mp.init(allocator);
		defer ma.deinit();
		var mb = lib.Mp.init(allocator);
		defer mb.deinit();
		var mr = lib.Mp.init(allocator);
		defer mr.deinit();
		defer lib.tier3.releaseMulScratch();
		const enc = try allocator.alloc(u8, size + 16);
		defer allocator.free(enc);
		const h = try lib.tier3.writeHeader(enc, size);
		@memcpy(enc[h..][0..size], a);
		try ma.setBytes(enc[0..h + size]);
		const bh = try lib.tier3.writeHeader(enc, size / 2);
		@memcpy(enc[bh..][0..size / 2], b[0..size / 2]);
		enc[bh + size / 2 - 1] = 0x61;
		try mb.setBytes(enc[0..bh + size / 2]);
		for ([_][]const u8{ "toom3", "small_fft", "gold_fft", "asymmetric_mp" }, 0..) |name, method| {
			if (method == 1 and 2 * size > fft.MAX_FFT_COMBINED_LEN) continue;
			const iters: usize = if (size <= 4096) 100 else 10;
			var wall: u64 = 0;
			var cpu: u64 = 0;
			for (0..iters + 3) |i| {
				const c = cpuNs();
				const t = clock.nowNs();
				switch (method) {
					0 => lib.tier3.mulToom3(a, b, out, work),
					1 => { _ = fft.mulMagnitudesWithScratch(a, b, out, small[0..small_bytes], small[small_bytes..2 * small_bytes], small[2 * small_bytes..5 * small_bytes / 2], small[5 * small_bytes / 2..3 * small_bytes], small[3 * small_bytes..]); },
					2 => { _ = fft.goldMulMagnitudesWithScratch(a, b, out, gold[0..gold_bytes], gold[gold_bytes..2 * gold_bytes], gold[2 * gold_bytes..5 * gold_bytes / 2], gold[5 * gold_bytes / 2..3 * gold_bytes], gold[3 * gold_bytes..]); },
					3 => try mr.mul(&ma, &mb),
					else => unreachable,
				}
				const dt = clock.nowNs() - t;
				const dc = cpuNs() - c;
				if (i >= 3) { wall += dt; cpu += dc; }
				std.mem.doNotOptimizeAway(out);
				std.mem.doNotOptimizeAway(mr.bytes());
			}
			std.debug.print("STORAGE impl={s} bytes={d} iterations={d} wall_ns={d} cpu_ns={d}\n", .{name, size, iters, wall / iters, cpu / iters});
		}
	}
}
