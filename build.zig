const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Exposed module. Named with ".zig" suffix per the Karl Seguin / pg.zig
    // convention so consumers write `@import("bao.zig")`.
    const bao_mod = b.addModule("bao.zig", .{
        .root_source_file = b.path("src/Bao.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests: run the `test` blocks inside Bao.zig and blake3_lo.zig.
    const bao_tests = b.addTest(.{
        .root_module = bao_mod,
    });
    const run_bao_tests = b.addRunArtifact(bao_tests);

    const test_step = b.step("test", "Run bao.zig tests");
    test_step.dependOn(&run_bao_tests.step);
}
