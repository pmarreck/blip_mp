const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	// Optional: paths to system GMP (provided by Nix). When unset, the
	// gmp_bench target is skipped — the core library has no GMP dependency.
	const gmp_include_path = b.option([]const u8, "gmp-include-path", "Path to GMP headers (gmp.h)");
	const gmp_lib_path = b.option([]const u8, "gmp-lib-path", "Path to GMP library directory");

	// Core module: pure Zig, no I/O, no external deps.
	const core_module = b.createModule(.{
		.root_source_file = b.path("src/blip_mp.zig"),
		.target = target,
		.optimize = optimize,
	});

	// Static library — the public artifact, exposed via C FFI later.
	const static_lib = b.addLibrary(.{
		.name = "blip_mp",
		.linkage = .static,
		.root_module = core_module,
	});
	b.installArtifact(static_lib);

	// Unit tests — every src/*.zig that has tests is reachable from blip_mp.zig.
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

	// blip_mp benchmark exe — links the core module by name.
	// link_libc is on so we can use std.heap.c_allocator (apples-to-apples
	// with GMP, which uses libc malloc).
	const blip_mp_bench = b.addExecutable(.{
		.name = "blip_mp_bench",
		.root_module = b.createModule(.{
			.root_source_file = b.path("tests/benchmark/blip_mp_bench.zig"),
			.target = target,
			.optimize = optimize,
			.link_libc = true,
			.imports = &.{
				.{ .name = "blip_mp", .module = core_module },
			},
		}),
	});
	b.installArtifact(blip_mp_bench);

	// Bench step: depend on the install of each bench artifact so `zig build
	// bench --prefix $out` actually populates $out/bin/.
	const install_blip_mp_bench = b.addInstallArtifact(blip_mp_bench, .{});
	const bench_step = b.step("bench", "Build benchmark binaries");
	bench_step.dependOn(&install_blip_mp_bench.step);

	// gmp benchmark — only built if GMP paths are provided (typically by Nix).
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
