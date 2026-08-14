// mock_client.zig — duck-typed HTTP client for fuzz harnesses.
//
// Satisfies the protocol consumed by both `http_client.execute` and
// `http_client.executeStream` (`src/http_client.zig`), and by any function
// that forwards `client: anytype` into them (`openQAReq`, `openQARawGet`,
// `runSchedule`, `runMonitor`, `runArchive`). Originally lived inline in
// fuzz_execute.zig; extracted here so multiple harnesses can share it.
//
// Knobs (single-response mode — the default):
//   - fail_attempts:    return error.ConnectionRefused N times before succeeding
//                       (exercises the retry loop in http_client.execute).
//   - response_status:  HTTP status code returned on success.
//   - response_gzip:    if true, emit Content-Encoding: gzip and treat
//                       response_body as gzip-compressed bytes.
//   - response_body:    response payload (or compressed payload when use_gzip).
//   - response_content_length: value for head.content_length (used by
//                       executeStream for Content-Length validation).
//   - partial_body_len: if set, streamRemaining delivers only this many bytes
//                       instead of the full response_body. Simulates short reads
//                       that trigger HttpTransferTruncated in executeStream.
//   - link_header:      if non-null, emit a Link header.
//   - use_structured_ct: if true, set head.content_type to "application/json"
//                        so the fallback path in http_client.zig is NOT triggered
//                        via the structured field; when false, head.content_type is
//                        set to null to trigger the structured fallback path.
//   - inject_read_failed: if true, streamRemaining returns error.ReadFailed
//                          on first call.
//
// Multi-response mode (scripted sequence):
//   - next_bodies:      slice of response bodies. When non-null, each
//                       successive request() pops the next body from the list.
//                       Once exhausted, falls back to response_body.
//   - next_statuses:    optional parallel slice of HTTP statuses. When non-null
//                       and same length as next_bodies, each response uses the
//                       corresponding status. When null, all responses use
//                       response_status.
//
// Scripted mode enables harnesses like fuzz_schedule to drive multi-request
// patterns: POST → poll → poll → final response.

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
        // Content-Length value exposed to executeStream() for truncation
        // detection and LengthRequired checks. Null means no Content-Length
        // header was sent. Not used by execute() (which ignores it).
        content_length: ?u64 = null,

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
        // When non-null, deliver only this many bytes instead of the full
        // body. Simulates short reads that trigger HttpTransferTruncated
        // when content_length > partial_body_len.
        partial_body_len: ?usize = null,

        pub fn streamRemaining(self: *MockReader, w: anytype) anyerror!usize {
            if (self.inject_read_failed) {
                self.inject_read_failed = false;
                return error.ReadFailed;
            }
            if (self.done) return 0;
            self.done = true;
            const deliver_len = if (self.partial_body_len) |pbl|
                @min(pbl, self.body.len)
            else
                self.body.len;
            try w.writeAll(self.body[0..deliver_len]);
            return deliver_len;
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
    response_content_length: ?u64 = null,
    partial_body_len: ?usize = null,
    link_header: ?[]const u8 = null,
    use_structured_ct: bool = true,
    inject_read_failed: bool = false,

    // Multi-response mode: when non-null, each request() pops the next
    // body (and optionally status) from these slices. Once exhausted,
    // falls back to response_body / response_status.
    next_bodies: ?[]const []const u8 = null,
    next_statuses: ?[]const std.http.Status = null,

    // Internal state — reset by each call to request().
    attempt: u8 = 0,
    scripted_index: usize = 0,
    response: MockResponse = undefined,

    pub fn request(self: *Self, _: std.http.Method, _: std.Uri, _: anytype) !*MockResponse {
        if (self.attempt < self.fail_attempts) {
            self.attempt += 1;
            return error.ConnectionRefused;
        }
        self.attempt += 1;

        // Select body and status: scripted sequence takes precedence.
        const body = if (self.next_bodies) |nb| blk: {
            if (self.scripted_index < nb.len) {
                const b = nb[self.scripted_index];
                break :blk b;
            }
            break :blk self.response_body;
        } else self.response_body;

        const status = if (self.next_statuses) |ns| blk: {
            if (self.scripted_index < ns.len) {
                const s = ns[self.scripted_index];
                break :blk s;
            }
            break :blk self.response_status;
        } else self.response_status;

        // Advance scripted index after selecting.
        if (self.next_bodies != null) {
            self.scripted_index += 1;
        }

        self.response = .{
            .head = .{
                .status = status,
                .use_gzip = self.response_gzip,
                .link_header = self.link_header,
                // When use_structured_ct is false, set content_type to null so
                // the fallback path in http_client.zig is exercised only via
                // the header iterator.
                .content_type = if (self.use_structured_ct) "application/json" else null,
                .content_length = self.response_content_length,
            },
            .mock_reader = .{
                .body = body,
                .inject_read_failed = self.inject_read_failed,
                .partial_body_len = self.partial_body_len,
            },
        };
        return &self.response;
    }
};
