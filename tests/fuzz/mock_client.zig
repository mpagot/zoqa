// mock_client.zig — duck-typed HTTP client for fuzz harnesses.
//
// Satisfies the protocol consumed by `zoqa.openQAReq` (`src/root.zig`) and by
// any function that forwards `client: anytype` into it (`runSchedule`,
// `runMonitor`, `runArchive`). Originally lived inline in fuzz_execute.zig;
// extracted here so multiple harnesses can share it.
//
// Knobs:
//   - fail_attempts:    return error.ConnectionRefused N times before succeeding
//                       (exercises the retry loop in http_client.execute).
//   - response_status:  HTTP status code returned on success.
//   - response_gzip:    if true, emit Content-Encoding: gzip and treat
//                       response_body as gzip-compressed bytes.
//   - response_body:    response payload (or compressed payload when use_gzip).
//
// Future extension (not yet wired): a scripted-response array so harnesses
// like fuzz_schedule can return distinct bodies on successive calls (POST →
// poll → poll …). See ideas/HARNESS_AUDIT.md.

const std = @import("std");

pub const ProgrammableMockClient = struct {
    const Self = @This();

    const MockHead = struct {
        status: std.http.Status,
        use_gzip: bool,
        // Fallback field checked by http_client.zig after iterateHeaders().
        content_type: ?[]const u8 = "application/json",

        const HeaderIterator = struct {
            use_gzip: bool,
            count: u8 = 0,

            pub fn next(self: *HeaderIterator) ?std.http.Header {
                if (self.count == 0) {
                    self.count += 1;
                    return .{ .name = "Content-Type", .value = "application/json" };
                }
                if (self.count == 1 and self.use_gzip) {
                    self.count += 1;
                    return .{ .name = "Content-Encoding", .value = "gzip" };
                }
                return null;
            }
        };

        pub fn iterateHeaders(self: *const MockHead) HeaderIterator {
            return .{ .use_gzip = self.use_gzip };
        }
    };

    const MockReader = struct {
        body: []const u8,
        done: bool = false,

        pub fn streamRemaining(self: *MockReader, w: anytype) anyerror!usize {
            if (self.done) return 0;
            self.done = true;
            try w.writeAll(self.body);
            return self.body.len;
        }
    };

    const MockResponse = struct {
        head: MockHead,
        mock_reader: MockReader,

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

    // Configuration — set before each call to openQAReq.
    fail_attempts: u8 = 0,
    response_status: std.http.Status = .ok,
    response_gzip: bool = false,
    response_body: []const u8 = "{}",

    // Internal state — reset by each call to request().
    attempt: u8 = 0,
    response: MockResponse = undefined,

    pub fn request(self: *Self, _: std.http.Method, _: std.Uri, _: anytype) !*MockResponse {
        if (self.attempt < self.fail_attempts) {
            self.attempt += 1;
            return error.ConnectionRefused;
        }
        self.attempt += 1;
        self.response = .{
            .head = .{
                .status = self.response_status,
                .use_gzip = self.response_gzip,
            },
            .mock_reader = .{ .body = self.response_body },
        };
        return &self.response;
    }
};
