// Fuzz harness for gzip decompression (std.compress.flate.Decompress with
// .gzip mode) — the exact code path used by http_client.zig when the server
// responds with Content-Encoding: gzip despite Accept-Encoding: identity.
//
// ---------------------------------------------------------------------------
// Corpus format
// ---------------------------------------------------------------------------
//
// Raw binary data — fed directly to the gzip decompressor. Seeds should be
// valid gzip streams (created with `gzip` or `printf '...' | gzip`), but the
// fuzzer will quickly mutate them into invalid/truncated/malicious streams
// which is exactly what we want to test.
//
// ---------------------------------------------------------------------------
// What this exercises
// ---------------------------------------------------------------------------
//
// - std.compress.flate.Decompress.init with .gzip mode
// - reader.streamRemaining — the full decompression loop
// - Error handling for truncated, corrupt, or adversarial gzip data
// - Memory allocation behavior under decompression (gzip bomb detection)
//
const std = @import("std");

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const input = buf[0..@intCast(len)];

    if (input.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Mirror the exact decompression path from http_client.zig lines 246-257.
    var in: std.Io.Reader = .fixed(input);
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    _ = decompress.reader.streamRemaining(&out.writer) catch {};

    // If decompression succeeded, also try parsing the result as JSON —
    // this mirrors the full http_client path: decompress → JSON parse → stringify.
    const decompressed = out.written();
    if (decompressed.len > 0 and decompressed.len < 1024 * 1024) {
        if (std.json.parseFromSlice(std.json.Value, allocator, decompressed, .{})) |*parsed| {
            defer parsed.deinit();
            var discard_buf: [4096]u8 = undefined;
            var discard: std.Io.Writer.Discarding = .init(&discard_buf);
            std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &discard.writer) catch {};
        } else |_| {}
    }
}
