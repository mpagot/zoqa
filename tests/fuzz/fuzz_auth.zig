// Fuzz harness for HMAC-SHA1 authentication (src/auth.zig) and URL
// normalization (src/http_client.zig §5.3: %20→+, ~→%7E).
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
//   3. URL normalization + HMAC signing pipeline — via openQAReq with a mock
//      HTTP client so that normalizePathQuery and buildAuthHeaders are both
//      exercised end-to-end through the same code path used in production.
//
const std = @import("std");
const zoqa = @import("zoqa");
const auth = zoqa.auth;

// ---------------------------------------------------------------------------
// Minimal mock HTTP client — accepts any request, returns 200 OK with an
// empty JSON body. Never performs real I/O.
// ---------------------------------------------------------------------------

const MockClient = struct {
    const Self = @This();

    const MockHead = struct {
        status: std.http.Status = .ok,
        content_type: ?[]const u8 = "application/json",

        const HeaderIterator = struct {
            done: bool = false,
            pub fn next(self: *HeaderIterator) ?std.http.Header {
                if (self.done) return null;
                self.done = true;
                return .{ .name = "Content-Type", .value = "application/json" };
            }
        };

        pub fn iterateHeaders(_: *const MockHead) HeaderIterator {
            return .{};
        }
    };

    const MockReader = struct {
        done: bool = false,
        pub fn streamRemaining(self: *MockReader, w: anytype) anyerror!usize {
            if (self.done) return 0;
            self.done = true;
            const body = "{}";
            try w.writeAll(body);
            return body.len;
        }
    };

    const MockResponse = struct {
        head: MockHead = .{},
        mock_reader: MockReader = .{},

        pub fn deinit(_: *MockResponse) void {}
        pub fn sendBodiless(_: *MockResponse) !void {}
        pub fn sendBodyComplete(_: *MockResponse, _: []u8) !void {}

        pub fn reader(self: *MockResponse, _: []u8) *MockReader {
            return &self.mock_reader;
        }
        pub fn receiveHead(self: *MockResponse, _: []u8) !*MockResponse {
            return self;
        }
    };

    response: MockResponse = .{},

    pub fn request(self: *Self, _: std.http.Method, _: std.Uri, _: anytype) !*MockResponse {
        self.response = .{};
        return &self.response;
    }
};

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
    // Target 2: buildAuthHeaders with fuzzed inputs
    // -------------------------------------------------------------------
    const timestamp = "1234567890";
    var hash_buf: [40]u8 = undefined;
    _ = auth.buildAuthHeaders(
        api_key,
        api_secret,
        raw_path_query,
        timestamp,
        &hash_buf,
    );

    // -------------------------------------------------------------------
    // Target 3: full normalization + HMAC signing pipeline via openQAReq
    //
    // Exercises the same normalizePathQuery → buildAuthHeaders code path
    // that execute() uses in production. The mock client ensures no real
    // I/O occurs. The path is constructed from the fuzz input so that
    // AFL++ can drive the normalization logic (%20, ~, etc.).
    // -------------------------------------------------------------------
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a valid path from the fuzz input; prefix with "/" to make it
    // a plausible API path. Sanitize null bytes that would break URI parsing.
    var path_buf: [512]u8 = undefined;
    // Cast path_buf.len - 1 to usize explicitly: without this, @min infers a
    // comptime-sized integer type (u9 for 511) and path_len + 1 overflows when
    // path_len reaches the maximum value of 511.
    const path_len: usize = @min(raw_path_query.len, @as(usize, path_buf.len - 1));
    path_buf[0] = '/';
    @memcpy(path_buf[1 .. path_len + 1], raw_path_query[0..path_len]);
    // Replace null bytes — std.Uri.parse rejects them.
    for (path_buf[1 .. path_len + 1]) |*c| {
        if (c.* == 0) c.* = '_';
    }
    const fuzz_path = path_buf[0 .. path_len + 1];

    const creds = zoqa.config.Credentials{
        .allocator = allocator,
        .key = api_key,
        .secret = api_secret,
    };

    var mock: MockClient = .{};
    const resp = zoqa.openQAReq(
        "http://localhost",
        fuzz_path,
        .{
            .allocator = allocator,
            .credentials = creds,
            .quiet = true,
        },
        &mock,
    ) catch return;
    resp.deinit();
}
