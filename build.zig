const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("euspinolia", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Loaded by Python through ctypes.
    // Output: zig-out/lib/libeuspinolia.{so,dylib,dll}
    const lib = b.addLibrary(.{
        .name = "euspinolia",
        .linkage = .dynamic,
        .root_module = mod,
    });
    b.installArtifact(lib);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
