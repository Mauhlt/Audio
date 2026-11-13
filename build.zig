const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // SIMD tuning width in bytes; unset = std.simd.suggestVectorLength(u8) for the target.
    // Set it to run a wider (or narrower) build's vector code on this machine.
    const vector_bytes = b.option(usize, "vector-bytes", "SIMD tuning width in bytes (power of two, >= 16; default: suggested for the target CPU)");
    const options = b.addOptions();
    options.addOption(usize, "vector_bytes", vector_bytes orelse 0); // 0: suggested
    const options_mod = options.createModule();

    // Other projects: `b.dependency("Audio", .{}).module("Audio")`.
    // No optimize mode here: the module inherits the importing module's.
    const mod = b.addModule("Audio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("build_options", options_mod);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.setCwd(b.path(".")); // tests read src/Data/... relative to the project root
    run_mod_tests.has_side_effects = true; // reads/writes data files the cache doesn't track
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // ReleaseFast tests, e.g. for benchmarking
    const mod_release = b.addModule("AudioReleaseFast", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    mod_release.addImport("build_options", options_mod);
    const run_release_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod_release }));
    run_release_tests.setCwd(b.path("."));
    run_release_tests.has_side_effects = true;
    const test_release_step = b.step("test-release", "Run tests in ReleaseFast");
    test_release_step.dependOn(&run_release_tests.step);

    // Benchmarks (ReleaseFast)
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "Audio", .module = mod_release }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("."));
    run_bench.has_side_effects = true;
    const bench_step = b.step("bench", "Encode/decode benchmarks (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);
}
