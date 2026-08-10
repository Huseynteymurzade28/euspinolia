const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Çekirdek modül. İleride hem shared library hem de olası bir CLI
    // aynı modülü paylaşacak.
    const mod = b.addModule("euspinolia", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Python'un ctypes ile yükleyeceği paylaşımlı kütüphane.
    // Çıktı: zig-out/lib/libeuspinolia.so (linux) / .dylib (macos) / .dll (windows)
    const lib = b.addLibrary(.{
        .name = "euspinolia",
        .linkage = .dynamic,
        .root_module = mod,
    });
    b.installArtifact(lib);

    // zig build test
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Zig birim testlerini çalıştır");
    test_step.dependOn(&run_mod_tests.step);
}
