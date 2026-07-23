const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols from the binary");

    // Library module exposed to consumers of this package.
    // Note: Zig uses a root source file approach. Only files that are explicitly
    // @import'ed from src/root.zig (or its imported files) will be part of the library.
    const lib_mod = b.addModule("zoqa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Shared argument-parsing module: CLI-only utilities shared between
    // executables (matchBool, matchValue, tryCommonFlag). Intentionally kept
    // out of root.zig to maintain library UX-agnosticism.
    const arg_match_mod = b.createModule(.{
        .root_source_file = b.path("src/arg_match.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared CLI runtime-input resolution module: orchestrates the
    // credential priority chain (CLI > env > config) and env-var parsing for
    // retry/timeout knobs. Uses std.process; NOT part of the library.
    const cli_env_mod = b.createModule(.{
        .root_source_file = b.path("src/cli_env.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
    });

    // Executable
    // Similarly, only files @import'ed from src/main.zig will be part of the executable.
    // The executable also imports the library module below so it can use its public API.
    const exe = b.addExecutable(.{
        .name = "zoqa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "zoqa", .module = lib_mod },
                .{ .name = "arg_match", .module = arg_match_mod },
                .{ .name = "cli_env", .module = cli_env_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Second executable: zoqa-clone-job
    const clone_exe = b.addExecutable(.{
        .name = "zoqa-clone-job",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clone_job_main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "zoqa", .module = lib_mod },
                .{ .name = "arg_match", .module = arg_match_mod },
                .{ .name = "cli_env", .module = cli_env_mod },
            },
        }),
    });
    b.installArtifact(clone_exe);

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

    const clone_exe_tests = b.addTest(.{
        .root_module = clone_exe.root_module,
    });
    const run_clone_exe_tests = b.addRunArtifact(clone_exe_tests);

    const arg_match_tests = b.addTest(.{
        .root_module = arg_match_mod,
    });
    const run_arg_match_tests = b.addRunArtifact(arg_match_tests);

    const cli_env_tests = b.addTest(.{
        .root_module = cli_env_mod,
    });
    const run_cli_env_tests = b.addRunArtifact(cli_env_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_clone_exe_tests.step);
    test_step.dependOn(&run_arg_match_tests.step);
    test_step.dependOn(&run_cli_env_tests.step);

    // Documentation generation step (on-demand: `zig build docs`)
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const docs_lib = b.addLibrary(.{
        .name = "zoqa",
        .root_module = docs_mod,
        .linkage = .static,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation (output: zig-out/docs/)");
    docs_step.dependOn(&install_docs.step);

    if (b.option(bool, "fuzz", "enable building tooling for fuzz testing") orelse false) {
        setupFuzzing(b, target, optimize);
    }
}

fn addFuzzBinary(
    b: *std.Build,
    afl: anytype,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    src: []const u8,
    imports: []const std.Build.Module.Import,
) void {
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
            .fuzz = true,
            .imports = imports,
        }),
    });
    obj.root_module.stack_check = false;
    obj.root_module.link_libc = true;

    // use_system_afl = true: afl_kit will call whichever afl-cc is on PATH.
    // Add vendor/aflplusplus to PATH before invoking `zig build -Dfuzz`, e.g.:
    //   PATH=$PWD/vendor/aflplusplus:$PATH zig build -Dfuzz
    // Pass -lm explicitly: afl-cc links with clang against system libs, and
    // std.math.pow(f64, ...) pulls in log/exp from libm at link time.
    if (afl.addInstrumentedExe(b, target, optimize, null, true, obj, &.{"-lm"})) |afl_exe| {
        b.getInstallStep().dependOn(&b.addInstallFile(afl_exe, name).step);
    }
}

fn setupFuzzing(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const afl = b.lazyImport(@This(), "afl_kit") orelse return;

    const lib_mod = b.modules.get("zoqa").?;

    // Build a module for src/main.zig so fuzz_request can import it as "main".
    // It depends on the library module for config/http_client access.
    const arg_match_mod = b.createModule(.{
        .root_source_file = b.path("src/arg_match.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    });
    const cli_env_mod = b.createModule(.{
        .root_source_file = b.path("src/cli_env.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
    });
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
            .{ .name = "arg_match", .module = arg_match_mod },
            .{ .name = "cli_env", .module = cli_env_mod },
        },
    });

    // zoqa-fuzz-config: INI parser + resolveHost (all 7 branches)
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-config", "tests/fuzz/fuzz_config.zig", &.{
        .{ .name = "zoqa", .module = lib_mod },
    });

    // zoqa-fuzz-request: CLI arg parser + buildRequest + parseLinkHeader + JSON
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-request", "tests/fuzz/fuzz_request.zig", &.{
        .{ .name = "main", .module = main_mod },
        .{ .name = "zoqa", .module = lib_mod },
    });

    // zoqa-fuzz-execute: full execute pipeline: auth + retry + gzip + openQAReq
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-execute", "tests/fuzz/fuzz_execute.zig", &.{
        .{ .name = "zoqa", .module = lib_mod },
    });

    // zoqa-fuzz-schedule: schedule subcommand: runSchedule + extractJobIds
    // (stub: sync path only, see tests/fuzz/fuzz_schedule.zig STATUS section).
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-schedule", "tests/fuzz/fuzz_schedule.zig", &.{
        .{ .name = "zoqa", .module = lib_mod },
    });
}
