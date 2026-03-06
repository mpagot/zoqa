const std = @import("std");
const config = @import("openQAclient").config;

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const input = buf[0..@intCast(len)];

    // Pass the fuzzed bytes to our INI parser
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    _ = config.parseIni(arena.allocator(), input, "openqa.suse.de") catch {};
}
