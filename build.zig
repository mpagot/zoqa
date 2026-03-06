const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module — exposed to consumers of this package.
    const lib_mod = b.addModule("openQAclient", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Executable
    const exe = b.addExecutable(.{
        .name = "openQAclient",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openQAclient", .module = lib_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    if (b.option(bool, "fuzz", "enable building tooling for fuzz testing") orelse false) {
        setupFuzzing(b, target, optimize);
    }
}

fn setupFuzzing(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const afl = b.lazyImport(@This(), "afl_kit") orelse return;

    const fuzz_obj = b.addObject(.{
        .name = "fuzz_obj",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/fuzz.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
            .fuzz = true,
            .imports = &.{
                .{ .name = "openQAclient", .module = b.modules.get("openQAclient").? },
            },
        }),
    });
    fuzz_obj.root_module.stack_check = false;
    fuzz_obj.root_module.link_libc = true;

    // use_system_afl = true: afl_kit will call whichever afl-cc is on PATH.
    // Add vendor/aflplusplus to PATH before invoking `zig build -Dfuzz`, e.g.:
    //   PATH=$PWD/vendor/aflplusplus:$PATH zig build -Dfuzz
    if (afl.addInstrumentedExe(b, target, optimize, null, true, fuzz_obj, &.{})) |afl_exe| {
        b.getInstallStep().dependOn(&b.addInstallFile(afl_exe, "openQAclient-afl").step);
    }
}
