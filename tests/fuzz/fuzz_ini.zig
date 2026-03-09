// Fuzz harness for the INI config parser (src/config.zig: parseIni).
//
// ---------------------------------------------------------------------------
// Corpus format
// ---------------------------------------------------------------------------
//
// The first line is the hostname used for credential lookup. The rest is the
// INI file content fed to parseIni.
//
//   openqa.suse.de
//   [openqa.suse.de]
//   key = 1234ABCD1234ABCD
//   secret = ABCD1234ABCD1234
//
// This lets the fuzzer mutate both the hostname AND the INI body, so it can
// explore section-matching logic that was previously unreachable with the
// hardcoded hostname.
//
// If the input contains no newline, the entire input is used as the hostname
// with an empty INI body — this still exercises the empty-input path.
//
const std = @import("std");
const config = @import("zoqa").config;

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const input = buf[0..@intCast(len)];

    // Split on first newline: hostname | INI content
    const split_pos = std.mem.indexOfScalar(u8, input, '\n');
    const hostname: []const u8 = if (split_pos) |p| input[0..p] else input;
    const ini_content: []const u8 = if (split_pos) |p| input[p + 1 ..] else "";

    if (hostname.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    _ = config.parseIni(arena.allocator(), ini_content, hostname) catch {};
}
