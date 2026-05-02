const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	// Optional: paths to system GMP for the gmp_bench comparison binary.
	// blip_mp itself has NO runtime dep on GMP — tier 3 is implemented in
	// pure Zig limb primitives. GMP is only needed for the apples-to-apples
	// benchmark exe.
	const gmp_include_path = b.option([]const u8, "gmp-include-path", "Path to GMP headers (gmp.h) — bench comparison only");
	const gmp_lib_path = b.option([]const u8, "gmp-lib-path", "Path to GMP library directory — bench comparison only");
	// Optional: path to GMP built with --disable-assembly (pure C). Used to
	// isolate the BLIP-vs-limb-storage question from Zig-vs-aarch64-asm.
	const gmp_noasm_include_path = b.option([]const u8, "gmp-noasm-include-path", "Path to GMP-noasm headers");
	const gmp_noasm_lib_path = b.option([]const u8, "gmp-noasm-lib-path", "Path to GMP-noasm library directory");

	// Core module: pure Zig, no external link deps.
	const core_module = b.createModule(.{
		.root_source_file = b.path("src/blip_mp.zig"),
		.target = target,
		.optimize = optimize,
	});

	const static_lib = b.addLibrary(.{
		.name = "blip_mp",
		.linkage = .static,
		.root_module = core_module,
	});
	b.installArtifact(static_lib);

	// C FFI library — exports the symbols declared in include/blip_mp.h.
	// Uses libc via std.heap.c_allocator; the Zig core itself doesn't link
	// libc, but the FFI consumer surface does.
	const c_api_module = b.createModule(.{
		.root_source_file = b.path("src/c_api.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	const c_api_lib = b.addLibrary(.{
		.name = "blip_mp_c",
		.linkage = .static,
		.root_module = c_api_module,
	});
	c_api_lib.installHeader(b.path("include/blip_mp.h"), "blip_mp.h");
	b.installArtifact(c_api_lib);

	// C smoke test — dogfoods the FFI exactly as a downstream binding would.
	// Pure-C source; links against the static C-API library.
	const c_smoke_module = b.createModule(.{
		.root_source_file = null,
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	c_smoke_module.addCSourceFile(.{
		.file = b.path("tests/cli/c_smoke.c"),
		.flags = &.{ "-O2", "-Wall", "-Wextra", "-Werror", "-std=c11" },
	});
	c_smoke_module.addIncludePath(b.path("include"));
	c_smoke_module.linkLibrary(c_api_lib);
	const c_smoke = b.addExecutable(.{
		.name = "c-smoke",
		.root_module = c_smoke_module,
	});
	const install_c_smoke = b.addInstallArtifact(c_smoke, .{});
	const c_smoke_step = b.step("c-smoke", "Build the C-FFI smoke test");
	c_smoke_step.dependOn(&install_c_smoke.step);

	// Wire the run step too so `zig build c-smoke-run` exercises the FFI.
	const run_c_smoke = b.addRunArtifact(c_smoke);
	run_c_smoke.step.dependOn(&install_c_smoke.step);
	const run_c_smoke_step = b.step("c-smoke-run", "Run the C-FFI smoke test");
	run_c_smoke_step.dependOn(&run_c_smoke.step);

	const unit_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/blip_mp.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	const run_unit_tests = b.addRunArtifact(unit_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);

	// blip_mp benchmark exe — links libc for c_allocator (apples-to-apples
	// allocator with GMP comparison). No GMP linkage on the blip_mp side.
	const blip_mp_bench_module = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/blip_mp_bench.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
		.imports = &.{
			.{ .name = "blip_mp", .module = core_module },
		},
	});
	const blip_mp_bench = b.addExecutable(.{
		.name = "blip_mp_bench",
		.root_module = blip_mp_bench_module,
	});
	const install_blip_mp_bench = b.addInstallArtifact(blip_mp_bench, .{});
	const bench_step = b.step("bench", "Build benchmark binaries");
	bench_step.dependOn(&install_blip_mp_bench.step);

	// fft_microbench — isolates per-call cost of mulModP/addModP/subModP and
	// their @Vector(2, u64) SIMD counterparts. No FFT setup, no allocation.
	// Used to measure M6-4-A SIMD speedups against the scalar baseline.
	const fft_microbench_module = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/fft_microbench.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
		.imports = &.{
			.{ .name = "blip_mp", .module = core_module },
		},
	});
	const fft_microbench = b.addExecutable(.{
		.name = "fft_microbench",
		.root_module = fft_microbench_module,
	});
	const install_fft_microbench = b.addInstallArtifact(fft_microbench, .{});
	bench_step.dependOn(&install_fft_microbench.step);

	// cross_check — Zig exe that links both blip_mp (Zig core) and GMP,
	// runs randomized add/sub/mul comparisons, asserts results match.
	// Run via `./test` (or `nix build .#packages.<sys>.cross_check`).
	if (gmp_include_path != null and gmp_lib_path != null) {
		const cc_module = b.createModule(.{
			.root_source_file = b.path("tests/integration/cross_check.zig"),
			.target = target,
			.optimize = optimize,
			.link_libc = true,
			.imports = &.{
				.{ .name = "blip_mp", .module = core_module },
			},
		});
		cc_module.addLibraryPath(.{ .cwd_relative = gmp_lib_path.? });
		cc_module.linkSystemLibrary("gmp", .{});
		const cross_check = b.addExecutable(.{
			.name = "cross_check",
			.root_module = cc_module,
		});
		const install_cc = b.addInstallArtifact(cross_check, .{});
		const cc_step = b.step("cross_check", "Build cross-validation against GMP");
		cc_step.dependOn(&install_cc.step);
		bench_step.dependOn(&install_cc.step);
	}

	// gmp_noasm_bench — same C source as gmp_bench but linking against GMP
	// built with --disable-assembly. Lets us measure pure-C GMP performance
	// to isolate the storage-paradigm question from the asm-tuning question.
	if (gmp_noasm_include_path != null and gmp_noasm_lib_path != null) {
		const gmp_noasm_module = b.createModule(.{
			.root_source_file = null,
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		});
		gmp_noasm_module.addCSourceFile(.{
			.file = b.path("tests/benchmark/gmp_bench.c"),
			.flags = &.{ "-O3", "-Wall", "-Wextra" },
		});
		gmp_noasm_module.addIncludePath(.{ .cwd_relative = gmp_noasm_include_path.? });
		gmp_noasm_module.addLibraryPath(.{ .cwd_relative = gmp_noasm_lib_path.? });
		gmp_noasm_module.linkSystemLibrary("gmp", .{});
		const gmp_noasm_bench = b.addExecutable(.{
			.name = "gmp_noasm_bench",
			.root_module = gmp_noasm_module,
		});
		const install_gmp_noasm = b.addInstallArtifact(gmp_noasm_bench, .{});
		bench_step.dependOn(&install_gmp_noasm.step);
	}

	// gmp_bench — pure C exe linking GMP (with hand-tuned asm by default).
	if (gmp_include_path != null and gmp_lib_path != null) {
		const gmp_module = b.createModule(.{
			.root_source_file = null,
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		});
		gmp_module.addCSourceFile(.{
			.file = b.path("tests/benchmark/gmp_bench.c"),
			.flags = &.{ "-O3", "-Wall", "-Wextra" },
		});
		gmp_module.addIncludePath(.{ .cwd_relative = gmp_include_path.? });
		gmp_module.addLibraryPath(.{ .cwd_relative = gmp_lib_path.? });
		gmp_module.linkSystemLibrary("gmp", .{});
		const gmp_bench = b.addExecutable(.{
			.name = "gmp_bench",
			.root_module = gmp_module,
		});
		const install_gmp_bench = b.addInstallArtifact(gmp_bench, .{});
		bench_step.dependOn(&install_gmp_bench.step);
	}
}
