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

    if (b.option(bool, "coverage", "enable kcov coverage targets") orelse false) {
        setupCoverage(b, target, optimize);
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
            .target = target,
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
    //
    // Expected, harmless build noise: afl_kit compiles in two stages (Zig
    // emits LLVM bitcode, then afl-cc/clang compiles it). The bitcode carries
    // a generic x86_64-linux module triple while SUSE's clang defaults to
    // x86_64-suse-linux, so clang overrides the triple and prints
    // "overriding the module target triple ... [-Woverride-module]". The
    // override is a no-op (only the vendor field differs) and the resulting
    // machine code is identical, so the warning is safe to ignore.
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

    // zoqa-fuzz-schedule: runSchedule sync + async paths and runMonitor
    // (see the corpus format in tests/fuzz/fuzz_schedule.zig).
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-schedule", "tests/fuzz/fuzz_schedule.zig", &.{
        .{ .name = "zoqa", .module = lib_mod },
    });
}

// ---------------------------------------------------------------------------
// kcov coverage targets
// ---------------------------------------------------------------------------
//
// Builds non-instrumented (plain Debug) executables from the coverage
// harnesses and wires kcov steps so `zig build -Dcoverage coverage-<name>`
// runs all corpus seeds through the harness under kcov and writes an
// HTML+JSON report to zig-out/coverage/<name>/.
//
// use_llvm = true is required: kcov v42/43 reads .debug_line to build an
// (address → source line) map. The self-hosted backend emits DWARF 5 which
// kcov cannot parse on x86_64-linux (empty address table → 0% coverage).
// The LLVM backend emits DWARF 4, which kcov handles correctly.
// See: https://github.com/SimonKagstrom/kcov/issues/423
//
// link_libc = true + .linkage = .dynamic: kcov instruments via LD_PRELOAD,
// which only works on dynamically linked executables.

const CoverageTargetOptions = struct {
    name: []const u8,
    harness: []const u8,
    imports: []const std.Build.Module.Import,
    corpus: []const u8,
};

fn setupCoverage(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const lib_mod = b.modules.get("zoqa").?;

    // Modules for src/main.zig — needed by the request coverage harness.
    const arg_match_mod = b.createModule(.{
        .root_source_file = b.path("src/arg_match.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const cli_env_mod = b.createModule(.{
        .root_source_file = b.path("src/cli_env.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
    });
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
            .{ .name = "arg_match", .module = arg_match_mod },
            .{ .name = "cli_env", .module = cli_env_mod },
        },
    });

    const coverage_step = b.step("coverage", "Run kcov coverage over all corpora");

    addCoverageTarget(b, target, optimize, coverage_step, .{
        .name = "config",
        .harness = "tests/fuzz/cov_harness_config.zig",
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
        .corpus = "tests/fuzz/corpus_config",
    });

    addCoverageTarget(b, target, optimize, coverage_step, .{
        .name = "request",
        .harness = "tests/fuzz/cov_harness_request.zig",
        .imports = &.{
            .{ .name = "main", .module = main_mod },
            .{ .name = "zoqa", .module = lib_mod },
        },
        .corpus = "tests/fuzz/corpus_request",
    });

    addCoverageTarget(b, target, optimize, coverage_step, .{
        .name = "execute",
        .harness = "tests/fuzz/cov_harness_execute.zig",
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
        .corpus = "tests/fuzz/corpus_execute",
    });

    // schedule: runSchedule sync + async paths and runMonitor.
    addCoverageTarget(b, target, optimize, coverage_step, .{
        .name = "schedule",
        .harness = "tests/fuzz/cov_harness_schedule.zig",
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
        .corpus = "tests/fuzz/corpus_schedule",
    });
}

fn addCoverageTarget(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    coverage_step: *std.Build.Step,
    opts: CoverageTargetOptions,
) void {
    const exe_name = b.fmt("zoqa-cov-{s}", .{opts.name});

    const exe = b.addExecutable(.{
        .name = exe_name,
        .linkage = .dynamic,
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path(opts.harness),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = opts.imports,
        }),
    });

    // Compile-only step: builds the coverage executable without running kcov.
    // Useful for CI syntax checks and for debugging the harness in isolation.
    // Registered before the corpus checks so it exists even without seeds.
    const build_only_name = b.fmt("coverage-{s}-build", .{opts.name});
    const build_only = b.step(build_only_name, b.fmt("Build zoqa-cov-{s} without running kcov", .{opts.name}));
    build_only.dependOn(&exe.step);

    const corpus_path = b.path(opts.corpus).getPath(b);

    var seed_paths: std.ArrayList([]const u8) = .{};
    defer seed_paths.deinit(b.allocator);

    var corpus_dir = std.fs.cwd().openDir(corpus_path, .{ .iterate = true }) catch {
        std.debug.print(
            "coverage: warning: corpus directory '{s}' not found — " ++
                "skipping coverage target '{s}'\n",
            .{ corpus_path, opts.name },
        );
        return;
    };
    defer corpus_dir.close();

    var dir_it = corpus_dir.iterate();
    while (dir_it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const abs = std.fs.path.join(b.allocator, &.{ corpus_path, entry.name }) catch continue;
        seed_paths.append(b.allocator, abs) catch continue;
    }

    if (seed_paths.items.len == 0) {
        std.debug.print(
            "coverage: warning: corpus directory '{s}' is empty — " ++
                "skipping coverage target '{s}'\n",
            .{ corpus_path, opts.name },
        );
        return;
    }

    var prev_step: ?*std.Build.Step = null;
    var out_dir_lazy: ?std.Build.LazyPath = null;

    // kcov 43 stops option parsing at the first positional argument
    // (getopt_long in POSIX mode, PR #415), so every kcov option must come
    // before the output directory. --include-path takes a directory and
    // filters the report to src/ only.
    // The path is resolved from the build root, not the cwd: `zig build` run
    // from a subdirectory keeps that subdirectory as cwd.
    const include_arg = b.fmt("--include-path={s}/", .{b.pathFromRoot("src")});

    for (seed_paths.items, 0..) |seed_abs, i| {
        const kcov_run = b.addSystemCommand(&.{"kcov"});

        kcov_run.addArg(include_arg);

        if (i == 0) {
            kcov_run.addArg("--clean");
            out_dir_lazy = kcov_run.addOutputDirectoryArg(
                b.fmt("coverage-{s}", .{opts.name}),
            );
        } else {
            kcov_run.addDirectoryArg(out_dir_lazy.?);
        }

        kcov_run.addArtifactArg(exe);
        kcov_run.addArg(seed_abs);

        if (prev_step) |ps| kcov_run.step.dependOn(ps);
        prev_step = &kcov_run.step;
    }

    const install = b.addInstallDirectory(.{
        .source_dir = out_dir_lazy.?,
        .install_dir = .{ .custom = "coverage" },
        .install_subdir = opts.name,
    });
    if (prev_step) |ps| install.step.dependOn(ps);

    const step_name = b.fmt("coverage-{s}", .{opts.name});
    const step_desc = b.fmt(
        "Run kcov over corpus_{s}/ and write report to zig-out/coverage/{s}/",
        .{ opts.name, opts.name },
    );
    const named_step = b.step(step_name, step_desc);
    named_step.dependOn(&install.step);

    coverage_step.dependOn(&install.step);
}
