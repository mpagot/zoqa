// Fuzz harness for HTTP response data parsers:
//   - parseLinkHeader      (src/http_client.zig): parses RFC 5988 Link headers
//   - std.json.parseFromSlice:                    parses JSON response body (--pretty path)
//
// Corpus format — two sections separated by a blank line:
//
//   <Link header value>
//
//   <JSON body>
//
// Example seed:
//
//   </api/v1/jobs?page=2>; rel="next", </api/v1/jobs?page=1>; rel="prev"
//
//   {"id":1,"state":"running","name":"foo"}
//
// The harness splits on the first blank line (\n\n). The first part is fed to
// parseLinkHeader; the second part is fed to std.json.parseFromSlice. Either
// section may be empty — the harness handles that gracefully.
const std = @import("std");
const http_client = @import("http_client");

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const input = buf[0..@intCast(len)];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Split on first blank line to separate link-header section from JSON section.
    const separator = "\n\n";
    const split_pos = std.mem.indexOf(u8, input, separator);

    const link_section: []const u8 = if (split_pos) |p| input[0..p] else input;
    const json_section: []const u8 = if (split_pos) |p| input[p + separator.len ..] else "";

    // Target 1: RFC 5988 Link header parser.
    // Use a null writer so the fuzzer doesn't spend time on write syscalls.
    if (link_section.len > 0) {
        http_client.parseLinkHeader(link_section, std.io.null_writer);
    }

    // Target 2: JSON response body pretty-printing path (--pretty flag path).
    // Parse, then serialize back through std.json.Stringify — this mirrors the
    // exact code path in http_client.execute() when --pretty is set.
    if (json_section.len > 0) {
        if (std.json.parseFromSlice(std.json.Value, allocator, json_section, .{})) |*parsed| {
            defer parsed.deinit();
            // Serialize back to a discard writer — exercises stringify without I/O.
            var discard_buf: [4096]u8 = undefined;
            var discard: std.Io.Writer.Discarding = .init(&discard_buf);
            std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &discard.writer) catch {};
        } else |_| {}
    }
}
