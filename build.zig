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

	// bp — RPN exact-arithmetic calculator. Pure-C CLI dogfooding the C
	// FFI (per CLAUDE.md: no Zig CLI bypassing the FFI).
	const bp_module = b.createModule(.{
		.root_source_file = null,
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	bp_module.addCSourceFile(.{
		.file = b.path("cli/bp.c"),
		.flags = &.{ if (optimize == .Debug) "-O0" else "-O2", "-Wall", "-Wextra", "-Werror", "-std=c11" },
	});
	if (optimize == .Debug) bp_module.addCMacro("BLIP_MP_DEBUG", "1");
	bp_module.addIncludePath(b.path("include"));
	bp_module.linkLibrary(c_api_lib);
	const bp_exe = b.addExecutable(.{
		.name = "bp",
		.root_module = bp_module,
	});
	const install_bp = b.addInstallArtifact(bp_exe, .{});
	const bp_step = b.step("bp", "Build the bp RPN calculator");
	bp_step.dependOn(&install_bp.step);
	// Always install bp with the default `zig build` so it lands in zig-out/bin.
	b.getInstallStep().dependOn(&install_bp.step);

	const gmp_test_support = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/gmp.zig"),
		.target = target, .optimize = optimize, .link_libc = true,
	});
	if (gmp_lib_path) |path| gmp_test_support.addLibraryPath(.{ .cwd_relative = path });
	gmp_test_support.linkSystemLibrary("gmp", .{});
	const unit_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/blip_mp.zig"),
			.target = target,
			.optimize = optimize,
			// Native test support may use libc; the production core stays independent.
			.link_libc = true,
			.imports = &.{.{ .name = "gmp_test_support", .module = gmp_test_support }},
		}),
	});
	const run_unit_tests = b.addRunArtifact(unit_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
	const oracle_tests = b.addTest(.{ .root_module = gmp_test_support });
	const run_oracle_tests = b.addRunArtifact(oracle_tests);
	b.step("gmp-oracle-test", "Check the independent GMP byte-product oracle").dependOn(&run_oracle_tests.step);
	test_step.dependOn(&run_oracle_tests.step);

	const add_probe_module = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/immediate_add.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
		.imports = &.{.{ .name = "blip_mp", .module = core_module }},
	});
	const add_probe_tests = b.addTest(.{ .root_module = add_probe_module });
	const run_add_probe_tests = b.addRunArtifact(add_probe_tests);
	const probe_test_step = b.step("probe-test", "Check the immediate-add measurement oracle");
	probe_test_step.dependOn(&run_add_probe_tests.step);
	test_step.dependOn(&run_add_probe_tests.step);
	const add_probe = b.addExecutable(.{ .name = "blip-mp-add-probe", .root_module = add_probe_module });
	const install_add_probe = b.addInstallArtifact(add_probe, .{});
	const probe_step = b.step("add-probe", "Build the verified immediate-add performance probe");
	probe_step.dependOn(&install_add_probe.step);

	const inverse_module = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/inverse.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
		.imports = &.{.{ .name = "blip_mp", .module = core_module }},
	});
	if (gmp_lib_path) |path| inverse_module.addLibraryPath(.{ .cwd_relative = path });
	inverse_module.linkSystemLibrary("gmp", .{});
	const inverse_tests = b.addTest(.{ .root_module = inverse_module });
	const run_inverse_tests = b.addRunArtifact(inverse_tests);
	const inverse_test_step = b.step("inverse-probe-test", "Check inverse-modulo probe oracles");
	inverse_test_step.dependOn(&run_inverse_tests.step);
	test_step.dependOn(&run_inverse_tests.step);
	const inverse_probe = b.addExecutable(.{ .name = "blip-mp-inverse-probe", .root_module = inverse_module });
	const install_inverse = b.addInstallArtifact(inverse_probe, .{});
	b.step("inverse-probe", "Build the GMP-verified inverse-modulo probe").dependOn(&install_inverse.step);

	const division_module = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/division.zig"),
		.target = target, .optimize = optimize, .link_libc = true,
		.imports = &.{.{ .name = "blip_mp", .module = core_module }},
	});
	if (gmp_lib_path) |path| division_module.addLibraryPath(.{ .cwd_relative = path });
	division_module.linkSystemLibrary("gmp", .{});
	const division_tests = b.addTest(.{ .root_module = division_module });
	const run_division_tests = b.addRunArtifact(division_tests);
	b.step("division-probe-test", "Check division probe oracles").dependOn(&run_division_tests.step);
	test_step.dependOn(&run_division_tests.step);
	const division_probe = b.addExecutable(.{ .name = "blip-mp-division-probe", .root_module = division_module });
	const install_division = b.addInstallArtifact(division_probe, .{});
	b.step("division-probe", "Build the GMP-verified division probe").dependOn(&install_division.step);

	const multiplication_module = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/multiplication.zig"),
		.target = target, .optimize = optimize, .link_libc = true,
		.imports = &.{.{ .name = "blip_mp", .module = core_module }},
	});
	if (gmp_lib_path) |path| multiplication_module.addLibraryPath(.{ .cwd_relative = path });
	multiplication_module.linkSystemLibrary("gmp", .{});
	const multiplication_tests = b.addTest(.{ .root_module = multiplication_module });
	const run_multiplication_tests = b.addRunArtifact(multiplication_tests);
	b.step("multiplication-probe-test", "Check multiplication workloads and allocation lifetimes").dependOn(&run_multiplication_tests.step);
	test_step.dependOn(&run_multiplication_tests.step);
	const multiplication_probe = b.addExecutable(.{ .name = "blip-mp-multiplication-probe", .root_module = multiplication_module });
	const install_multiplication = b.addInstallArtifact(multiplication_probe, .{});
	b.step("multiplication-probe", "Build the GMP-verified multiplication probe").dependOn(&install_multiplication.step);

	const gold_module = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/goldilocks.zig"),
		.target = target, .optimize = optimize, .link_libc = true,
		.imports = &.{.{ .name = "blip_mp", .module = core_module }},
	});
	if (gmp_lib_path) |path| gold_module.addLibraryPath(.{ .cwd_relative = path });
	gold_module.linkSystemLibrary("gmp", .{});
	const gold_tests = b.addTest(.{ .root_module = gold_module });
	const run_gold_tests = b.addRunArtifact(gold_tests);
	b.step("gold-probe-test", "Check Goldilocks layout measurements").dependOn(&run_gold_tests.step);
	test_step.dependOn(&run_gold_tests.step);
	const gold_probe = b.addExecutable(.{ .name = "blip-mp-gold-probe", .root_module = gold_module });
	const install_gold = b.addInstallArtifact(gold_probe, .{});
	b.step("gold-probe", "Build the verified Goldilocks layout probe").dependOn(&install_gold.step);

	const powm_module = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/powm.zig"),
		.target = target, .optimize = optimize, .link_libc = true,
		.imports = &.{.{ .name = "blip_mp", .module = core_module }},
	});
	if (gmp_lib_path) |path| powm_module.addLibraryPath(.{ .cwd_relative = path });
	powm_module.linkSystemLibrary("gmp", .{});
	const powm_tests = b.addTest(.{ .root_module = powm_module });
	const run_powm_tests = b.addRunArtifact(powm_tests);
	b.step("powm-probe-test", "Check verified modular exponentiation measurements").dependOn(&run_powm_tests.step);
	test_step.dependOn(&run_powm_tests.step);
	const powm_probe = b.addExecutable(.{ .name = "blip-mp-powm-probe", .root_module = powm_module });
	const install_powm = b.addInstallArtifact(powm_probe, .{});
	b.step("powm-probe", "Build the verified modular exponentiation probe").dependOn(&install_powm.step);

	// Shared monotonic-clock helper module for the benchmark + cross-check exes.
	const time_util_module = b.createModule(.{
		.root_source_file = b.path("tests/time_util.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});

	// blip_mp benchmark exe — links libc for c_allocator (apples-to-apples
	// allocator with GMP comparison). No GMP linkage on the blip_mp side.
	const blip_mp_bench_module = b.createModule(.{
		.root_source_file = b.path("tests/benchmark/blip_mp_bench.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
		.imports = &.{
			.{ .name = "blip_mp", .module = core_module },
			.{ .name = "time_util", .module = time_util_module },
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
			.{ .name = "time_util", .module = time_util_module },
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
				.{ .name = "time_util", .module = time_util_module },
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
