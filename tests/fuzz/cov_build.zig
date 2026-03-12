// cov_build.zig — coverage build for the three gen-2 fuzz harnesses.
//
// Builds non-instrumented (plain Debug) executables from the gen-2 coverage
// harnesses and wires kcov steps so a single `zig build -p . coverage-<name>`
// command runs all corpus seeds through the harness under kcov and writes an
// HTML+JSON report to zig-out/coverage/<name>/.
//
// ---------------------------------------------------------------------------
// Why use_llvm = true is required for kcov on x86_64-linux
// ---------------------------------------------------------------------------
//
// kcov v42 (and v43) instruments binaries by reading .debug_line to build an
// (address → source line) map and placing int3 breakpoints via ptrace. DWARF 4
// and DWARF 5 use different .debug_line header layouts; kcov v42's Linux ELF
// parser only understands DWARF 4. When it encounters a DWARF 5 header it
// builds an empty address table and reports 0% coverage.
//
// Zig backend DWARF version summary:
//   self-hosted backend (use_llvm = null, default for native Debug) → DWARF 5
//   LLVM backend        (use_llvm = true)                           → DWARF 4
//
// Setting use_llvm = true forces the LLVM backend, which emits DWARF 4 and
// allows kcov v42 to parse .debug_line correctly on x86_64-linux.
//
// This is a workaround for a kcov bug, not a fix. The upstream issue tracking
// Linux DWARF 5 support in kcov has been stalled since 2024:
//   https://github.com/SimonKagstrom/kcov/issues/423
// The Zig issue that documents the self-hosted/DWARF 5 behaviour:
//   https://github.com/ziglang/zig/issues/25368
//
// Once kcov ships proper Linux DWARF 5 support, use_llvm = true can be
// removed and the self-hosted backend (faster compile times) can be used.
//
// ---------------------------------------------------------------------------
// Why link_libc = true / preferred_link_mode = .dynamic
// ---------------------------------------------------------------------------
//
// kcov instruments binaries via LD_PRELOAD, which only works on dynamically
// linked executables. Zig produces statically linked binaries by default.
// Setting link_libc = true and preferred_link_mode = .dynamic forces dynamic
// linking against libc so kcov's LD_PRELOAD agent can be injected.
//
// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------
//
//   # Build coverage runners and run kcov over corpus_<name>/ (or _min/):
//   zig build -p . --build-file tests/fuzz/cov_build.zig coverage-config
//   zig build -p . --build-file tests/fuzz/cov_build.zig coverage-request
//   zig build -p . --build-file tests/fuzz/cov_build.zig coverage-execute
//
//   # Or build all three at once:
//   zig build -p . --build-file tests/fuzz/cov_build.zig coverage
//
//   Reports land in zig-out/coverage/{config,request,execute}/
//   Open zig-out/coverage/<name>/index.html in a browser.
//
// ---------------------------------------------------------------------------
// Requirements
// ---------------------------------------------------------------------------
//
//   kcov must be installed and on PATH.
//   On openSUSE: sudo zypper install kcov
//   On Debian/Ubuntu: sudo apt-get install kcov
//   On Fedora: sudo dnf install kcov

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // use_llvm is set per-executable in addCoverageTarget.
    // See module-level comment for rationale.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    // ---------------------------------------------------------------------------
    // Shared library module
    // ---------------------------------------------------------------------------
    const lib_mod = b.addModule("zoqa", .{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Module for src/main.zig — needed by fuzz_request (imports "main").
    const main_mod = b.createModule(.{
        .root_source_file = b.path("../../src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
    });

    // ---------------------------------------------------------------------------
    // Top-level "coverage" step — depends on all three targets
    // ---------------------------------------------------------------------------
    const coverage_step = b.step("coverage", "Run kcov coverage over all gen-2 corpora");

    // ---------------------------------------------------------------------------
    // Register the three gen-2 coverage targets
    // ---------------------------------------------------------------------------
    addCoverageTarget(b, target, optimize, coverage_step, .{
        .name = "config",
        .harness = "cov_harness_config.zig",
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
        .corpus = "corpus_config",
    });

    addCoverageTarget(b, target, optimize, coverage_step, .{
        .name = "request",
        .harness = "cov_harness_request.zig",
        .imports = &.{
            .{ .name = "main", .module = main_mod },
            .{ .name = "zoqa", .module = lib_mod },
        },
        .corpus = "corpus_request",
    });

    addCoverageTarget(b, target, optimize, coverage_step, .{
        .name = "execute",
        .harness = "cov_harness_execute.zig",
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
        .corpus = "corpus_execute",
    });
}

// ---------------------------------------------------------------------------
// addCoverageTarget
// ---------------------------------------------------------------------------
//
// For each target this creates:
//   1. An executable compiled with the LLVM backend (use_llvm = true) for
//      DWARF 4 compatibility with kcov v42 on x86_64-linux.
//   2. One Run step per seed file in the corpus directory, each invoking:
//        kcov --include-pattern=src/ <out_dir> <exe> <seed_file>
//      The first seed run also passes --clean to reset any stale report.
//      kcov auto-merges successive runs into the same output directory.
//      Steps are chained serially so kcov never runs concurrently.
//   3. An InstallDirectory step that copies the report to
//      zig-out/coverage/<name>/.
//   4. A named build step "coverage-<name>".

const CoverageTargetOptions = struct {
    name: []const u8,
    harness: []const u8,
    imports: []const std.Build.Module.Import,
    corpus: []const u8,
};

fn addCoverageTarget(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    coverage_step: *std.Build.Step,
    opts: CoverageTargetOptions,
) void {
    const exe_name = b.fmt("zoqa-cov-{s}", .{opts.name});

    // Build the coverage executable.
    // use_llvm = true forces the LLVM backend → DWARF 4 → kcov v42 can parse
    // .debug_line correctly on x86_64-linux. See module-level comment.
    // link_libc = true + .linkage = .dynamic forces a dynamically linked
    // binary so kcov's LD_PRELOAD agent can instrument it.
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

    // Enumerate seed files from the corpus directory at build-graph
    // construction time. The corpus is checked in and stable, so fixing the
    // set of seeds at graph-construction time is correct and keeps the
    // build graph simple.
    const corpus_path = b.path(opts.corpus).getPath(b);

    var seed_paths: std.ArrayList([]const u8) = .{};
    defer seed_paths.deinit(b.allocator);

    var corpus_dir = std.fs.cwd().openDir(corpus_path, .{ .iterate = true }) catch {
        std.debug.print(
            "cov_build: warning: corpus directory '{s}' not found — " ++
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
            "cov_build: warning: corpus directory '{s}' is empty — " ++
                "skipping coverage target '{s}'\n",
            .{ corpus_path, opts.name },
        );
        return;
    }

    // The kcov output directory is captured from the first Run step and
    // reused (as a plain LazyPath) by all subsequent steps so kcov merges
    // into the same directory.
    var prev_step: ?*std.Build.Step = null;
    var out_dir_lazy: ?std.Build.LazyPath = null;

    for (seed_paths.items, 0..) |seed_abs, i| {
        const kcov_run = b.addSystemCommand(&.{"kcov"});

        if (i == 0) {
            // First run: --clean resets any stale report from a prior build.
            kcov_run.addArg("--clean");
            // Capture the output directory as a tracked LazyPath.
            out_dir_lazy = kcov_run.addOutputDirectoryArg(
                b.fmt("coverage-{s}", .{opts.name}),
            );
        } else {
            // Subsequent runs: write into the same directory so kcov merges.
            kcov_run.addDirectoryArg(out_dir_lazy.?);
        }

        kcov_run.addArg("--include-pattern=src/");
        // NOT addRunArtifact — we pass the binary as a plain argument so kcov
        // wraps it. addArtifactArg declares the dependency without running exe.
        kcov_run.addArtifactArg(exe);
        kcov_run.addArg(seed_abs);

        // Chain steps serially: kcov cannot merge concurrent runs correctly.
        if (prev_step) |ps| kcov_run.step.dependOn(ps);
        prev_step = &kcov_run.step;
    }

    // Install the merged report to zig-out/coverage/<name>/.
    const install = b.addInstallDirectory(.{
        .source_dir = out_dir_lazy.?,
        .install_dir = .{ .custom = "coverage" },
        .install_subdir = opts.name,
    });
    if (prev_step) |ps| install.step.dependOn(ps);

    // Named step: `zig build coverage-<name>`
    const step_name = b.fmt("coverage-{s}", .{opts.name});
    const step_desc = b.fmt(
        "Run kcov over corpus_{s}/ and write report to zig-out/coverage/{s}/",
        .{ opts.name, opts.name },
    );
    const named_step = b.step(step_name, step_desc);
    named_step.dependOn(&install.step);

    // Hook into the aggregate "coverage" step.
    coverage_step.dependOn(&install.step);
}
