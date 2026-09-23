const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_kernel = b.option(bool, "native-kernel", "Use the vendored BLAKE3 AVX2 hash_many kernel (requires x86_64 Linux with AVX2)") orelse false;
    if (native_kernel and (target.result.cpu.arch != .x86_64 or
        target.result.os.tag != .linux or
        !target.result.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))))
    {
        @panic("-Dnative-kernel=true requires an x86_64 Linux target with AVX2 enabled (use -Dcpu=haswell or -Dtarget=native on AVX2 hosts)");
    }

    const options = b.addOptions();
    options.addOption(bool, "native_kernel", native_kernel);

    // Exposed module. Named with ".zig" suffix per the Karl Seguin / pg.zig
    // convention so consumers write `@import("bough.zig")`.
    const bough_mod = b.addModule("bough.zig", .{
        .root_source_file = b.path("src/Bough.zig"),
        .target = target,
        .optimize = optimize,
    });

    bough_mod.addOptions("bough_options", options);
    if (native_kernel) {
        // Keep this on the exported module so b.dependency("bough", ...).module("bough.zig")
        // automatically brings the assembly into consumer executables too.
        bough_mod.addAssemblyFile(b.path("vendor/blake3/blake3_avx2_x86-64_unix.S"));
    }

    const bench = b.addExecutable(.{
        .name = "bough-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bough", .module = bough_mod }},
        }),
    });
    const install_bench = b.addInstallArtifact(bench, .{});
    b.getInstallStep().dependOn(&install_bench.step);
    const bench_step = b.step("bench", "Build and install the benchmark driver (does not run it)");
    bench_step.dependOn(&install_bench.step);

    // Tests: run the `test` blocks inside Bough.zig and blake3_lo.zig.
    const bough_tests = b.addTest(.{
        .root_module = bough_mod,
    });
    const run_bough_tests = b.addRunArtifact(bough_tests);

    const test_step = b.step("test", "Run bough.zig tests");
    test_step.dependOn(&run_bough_tests.step);
}
