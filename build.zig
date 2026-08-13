const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Deliberately not `standardOptimizeOption`, which defaults to Debug.
    // Debug parses ~12x slower, which stands the point of this library on its
    // head for anyone who just runs `zig build`. ReleaseSafe keeps the bounds
    // and overflow checks — worth having in code that reads outside input —
    // and `-Doptimize=ReleaseFast` is there for whoever wants the rest.
    const requested = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSafe, or Debug for tests)",
    );

    const lib_optimize: std.builtin.OptimizeMode = requested orelse switch (b.release_mode) {
        .off, .any, .safe => .ReleaseSafe,
        .fast => .ReleaseFast,
        .small => .ReleaseSmall,
    };

    // Tests keep the Debug default: optimising them costs ~45s of compile time
    // per run and buys nothing, since the safety checks that matter are on in
    // Debug too. `-Doptimize` still applies to both, for testing what ships.
    const test_optimize: std.builtin.OptimizeMode = requested orelse .Debug;

    const mod = b.addModule("euspinolia", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = lib_optimize,
    });

    // Loaded by Python through ctypes.
    // Output: zig-out/lib/libeuspinolia.{so,dylib,dll}
    const lib = b.addLibrary(.{
        .name = "euspinolia",
        .linkage = .dynamic,
        .root_module = mod,
    });
    b.installArtifact(lib);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const mod_tests = b.addTest(.{ .root_module = test_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
