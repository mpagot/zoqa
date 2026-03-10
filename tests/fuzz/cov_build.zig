const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = .Debug;

    const lib_mod = b.addModule("zoqa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zoqa-cov-ini",
        .root_source_file = b.path("tests/fuzz/cov_harness_ini.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zoqa", lib_mod);

    // Pass LLVM coverage flags to the compile step
    // Note: LLVM coverage flags are passed to the compile step, not the link step
    // We can use `-fprofile-instr-generate -fcoverage-mapping` as part of the compile command.
    // In Zig 0.15.2, we can add these flags to the root module's LLVM step.

    // Actually, we can just run a raw `zig build-exe` with those flags.

    b.installArtifact(exe);
}
