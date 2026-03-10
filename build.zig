const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module — exposed to consumers of this package.
    const lib_mod = b.addModule("zoqa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Executable
    const exe = b.addExecutable(.{
        .name = "zoqa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zoqa", .module = lib_mod },
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
    if (afl.addInstrumentedExe(b, target, optimize, null, true, obj, &.{})) |afl_exe| {
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

    // Build a module for src/main.zig so fuzz_cli.zig can import it as "main".
    // It depends on the library module for config/http_client access.
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zoqa", .module = lib_mod },
        },
    });

    // zoqa-fuzz-ini: INI config file parser
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-ini", "tests/fuzz/fuzz_ini.zig", &.{
        .{ .name = "zoqa", .module = lib_mod },
    });

    // zoqa-fuzz-cli: CLI argument parser + jsonToFormEncoded
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-cli", "tests/fuzz/fuzz_cli.zig", &.{
        .{ .name = "main", .module = main_mod },
    });

    // zoqa-fuzz-http: parseLinkHeader + JSON pretty-print path
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-http", "tests/fuzz/fuzz_http.zig", &.{
        .{ .name = "zoqa", .module = lib_mod },
    });

    // zoqa-fuzz-auth: HMAC-SHA1 signing + URL normalization
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-auth", "tests/fuzz/fuzz_auth.zig", &.{
        .{ .name = "zoqa", .module = lib_mod },
    });

    // zoqa-fuzz-gzip: gzip decompression (Content-Encoding: gzip path)
    addFuzzBinary(b, afl, target, optimize, "zoqa-fuzz-gzip", "tests/fuzz/fuzz_gzip.zig", &.{});
}
