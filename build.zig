const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

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
}
