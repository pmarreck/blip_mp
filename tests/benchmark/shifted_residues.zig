//! Identical-input ablation of canonical and shifted-residue FFT products.
const std = @import("std");
const fft = @import("blip_mp").fft;
const clock = @import("time_util");
const cpuNs = @import("storage_aware.zig").cpuNs;

pub fn run() !void {
	const allocator = std.heap.c_allocator;
	for ([_]usize{ 128, 512, 2048, 4096, 7000 }) |size| {
		const a = try allocator.alloc(u8, size);
		defer allocator.free(a);
		const b = try allocator.alloc(u8, size);
		defer allocator.free(b);
		const out = try allocator.alloc(u8, 2 * size);
		defer allocator.free(out);
		var n: usize = 1;
		while (n < out.len) n *= 2;
		const len = n * fft.residue.slot_bytes;
		const work = try allocator.alloc(u8, 4 * len);
		defer allocator.free(work);
		for ([_][]const u8{ "random", "all255", "zero", "sparse" }, 0..) |pattern, pattern_index| {
			var rng = std.Random.DefaultPrng.init(0x5157 + size);
			rng.random().bytes(a);
			rng.random().bytes(b);
			if (pattern_index == 1) { @memset(a, 255); @memset(b, 255); }
			if (pattern_index == 2) @memset(a, 0);
			if (pattern_index == 3) {
				@memset(a, 0); @memset(b, 0);
				a[0] = 1; a[size - 1] = 255;
				b[0] = 255; b[size / 2] = 1;
			}
			const iterations: usize = if (size <= 512) 100 else 32;
			const modes = .{ fft.SmallResidueMode.canonical, fft.SmallResidueMode.shifted_boundary, fft.SmallResidueMode.shifted_arithmetic };
			var wall: [3]u64 = @splat(0);
			var cpu: [3]u64 = @splat(0);
			@memset(work, 0xa5);
			for (0..iterations + 3) |trial| {
				for (0..3) |position| {
					inline for (modes, 0..) |mode, mode_index| {
						if ((trial + position) % 3 == mode_index) {
							const c = cpuNs();
							const t = clock.nowNs();
							const written = fft.mulMagnitudesScoped(mode, a, b, out, work[0..len], work[len .. 2 * len], work[2 * len .. 5 * len / 2], work[5 * len / 2 .. 3 * len], work[3 * len ..]);
							const dt = clock.nowNs() - t;
							const dc = cpuNs() - c;
							if (trial >= 3) { wall[mode_index] += dt; cpu[mode_index] += dc; }
							std.mem.doNotOptimizeAway(out[0..written]);
						}
					}
				}
			}
			inline for (modes, 0..) |mode, index| {
				std.debug.print("SHIFT impl={s} bytes={d} pattern={s} iterations={d} wall_ns={d} cpu_ns={d}\n", .{ @tagName(mode), size, pattern, iterations, wall[index] / iterations, cpu[index] / iterations });
			}
		}
	}
}
