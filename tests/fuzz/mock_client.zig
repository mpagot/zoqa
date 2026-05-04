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
//   - link_header:      if non-null, emit a Link header (exercises Gap 9).
//   - use_structured_ct: if true, set head.content_type to null so the fallback
//                        path in http_client.zig is NOT triggered via the
//                        structured field; instead, Content-Type is emitted only
//                        via iterateHeaders. When false, head.content_type is set
//                        to null to trigger the structured fallback path (Gap 11).
//   - inject_read_failed: if true, streamRemaining returns error.ReadFailed
//                          on first call (exercises Gap 10).
//
// Future extension: a scripted-response array so harnesses like fuzz_schedule
// can return distinct bodies on successive calls (POST → poll → poll …).
// See ideas/HARNESS_AUDIT.md.

const std = @import("std");

pub const ProgrammableMockClient = struct {
    const Self = @This();

    const MockHead = struct {
        status: std.http.Status,
        use_gzip: bool,
        link_header: ?[]const u8 = null,
        // When non-null, this is the structured content_type field that
        // http_client.zig checks as a fallback after iterateHeaders().
        // Set to null to exercise the fallback-absent path.
        content_type: ?[]const u8 = "application/json",

        const HeaderIterator = struct {
            use_gzip: bool,
            link_header: ?[]const u8,
            emit_content_type: bool,
            count: u8 = 0,

            pub fn next(self: *HeaderIterator) ?std.http.Header {
                if (self.count == 0) {
                    self.count += 1;
                    if (self.emit_content_type) {
                        return .{ .name = "Content-Type", .value = "application/json" };
                    }
                    // Skip Content-Type in headers — let structured field handle it
                    return self.next();
                }
                if (self.count == 1 and self.use_gzip) {
                    self.count += 1;
                    return .{ .name = "Content-Encoding", .value = "gzip" };
                }
                if (self.count <= 2 and self.link_header != null) {
                    self.count = 3;
                    return .{ .name = "Link", .value = self.link_header.? };
                }
                return null;
            }
        };

        pub fn iterateHeaders(self: *const MockHead) HeaderIterator {
            return .{
                .use_gzip = self.use_gzip,
                .link_header = self.link_header,
                // Emit Content-Type in headers unless we want the structured fallback
                .emit_content_type = self.content_type != null,
            };
        }
    };

    const MockReader = struct {
        body: []const u8,
        done: bool = false,
        inject_read_failed: bool = false,

        pub fn streamRemaining(self: *MockReader, w: anytype) anyerror!usize {
            if (self.inject_read_failed) {
                self.inject_read_failed = false;
                return error.ReadFailed;
            }
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
    link_header: ?[]const u8 = null,
    use_structured_ct: bool = true,
    inject_read_failed: bool = false,

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
                .link_header = self.link_header,
                // When use_structured_ct is false, set content_type to null so
                // the fallback path in http_client.zig (lines 424-427) is
                // exercised only via the header iterator.
                .content_type = if (self.use_structured_ct) "application/json" else null,
            },
            .mock_reader = .{
                .body = self.response_body,
                .inject_read_failed = self.inject_read_failed,
            },
        };
        return &self.response;
    }
};
