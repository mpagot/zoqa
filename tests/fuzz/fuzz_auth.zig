// Fuzz harness for HMAC-SHA1 authentication (src/auth.zig) and the URL
// normalization logic from http_client.zig (§5.3: %20→+, ~→%7E).
//
// ---------------------------------------------------------------------------
// Corpus format
// ---------------------------------------------------------------------------
//
// Three sections separated by newlines:
//
//   <api_key>
//   <api_secret>
//   <path_and_query>
//
// Example seed:
//
//   1234ABCD1234ABCD
//   ABCD1234ABCD1234
//   /api/v1/jobs?limit=100&offset=0
//
// The first line is the API key, the second is the API secret, and
// everything from the third line onward (including further newlines) is the
// path+query string.
//
// The harness exercises:
//   1. hmacSha1Hex      — raw HMAC-SHA1 with fuzzed key+message
//   2. buildAuthHeaders — full header construction with fuzzed inputs
//   3. URL normalization — %20→+, ~→%7E rewriting (same logic as http_client.zig)
//
const std = @import("std");
const auth = @import("zoqa").auth;

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const input = buf[0..@intCast(len)];

    // Split into three sections: key, secret, path_and_query.
    const first_nl = std.mem.indexOfScalar(u8, input, '\n') orelse {
        // No newline — use entire input as both key and message for hmacSha1Hex.
        var out: [40]u8 = undefined;
        auth.hmacSha1Hex(input, input, &out);
        return;
    };

    const api_key = input[0..first_nl];
    const rest = input[first_nl + 1 ..];

    const second_nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
        // Only two fields — use rest as secret, key as message.
        var out: [40]u8 = undefined;
        auth.hmacSha1Hex(rest, api_key, &out);
        return;
    };

    const api_secret = rest[0..second_nl];
    const raw_path_query = rest[second_nl + 1 ..];

    // -------------------------------------------------------------------
    // Target 1: hmacSha1Hex with fuzzed key and message
    // -------------------------------------------------------------------
    var out: [40]u8 = undefined;
    auth.hmacSha1Hex(api_secret, raw_path_query, &out);

    // -------------------------------------------------------------------
    // Target 2: URL normalization (%20 → +, ~ → %7E)
    // This mirrors the exact logic in http_client.zig lines 84-96.
    // -------------------------------------------------------------------
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var normalized: std.ArrayList(u8) = .{};
    const w = normalized.writer(allocator);

    var i: usize = 0;
    while (i < raw_path_query.len) {
        if (i + 2 < raw_path_query.len and std.mem.eql(u8, raw_path_query[i .. i + 3], "%20")) {
            w.writeByte('+') catch return;
            i += 3;
        } else if (raw_path_query[i] == '~') {
            w.print("%7E", .{}) catch return;
            i += 1;
        } else {
            w.writeByte(raw_path_query[i]) catch return;
            i += 1;
        }
    }

    // -------------------------------------------------------------------
    // Target 3: buildAuthHeaders with normalized path+query
    // -------------------------------------------------------------------
    // Use a fixed timestamp so the harness is deterministic.
    const timestamp = "1234567890";
    var hash_buf: [40]u8 = undefined;
    _ = auth.buildAuthHeaders(
        api_key,
        api_secret,
        normalized.items,
        timestamp,
        &hash_buf,
    );

    normalized.deinit(allocator);
}
