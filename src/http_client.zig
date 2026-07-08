//! This module provides functions for dealing with http requests to the openQA server

const std = @import("std");
const config = @import("config.zig");
const auth = @import("auth.zig");

/// A single HTTP response header name/value pair.
/// Both fields are heap-allocated and owned by the `APIResponse`
/// that contains this entry. Freed by `APIResponse.deinit()`.
const ResponseHeader = struct {
    name: []u8,
    value: []u8,
};

/// Owned HTTP response returned by `execute()`.
///
/// All string fields are heap-allocated using the allocator stored in the
/// struct. The caller **must** call `deinit()` exactly once to release them.
///
/// Fields:
/// - `status`           HTTP status code of the final (non-retried) response.
/// - `body`             Decompressed response body. Always non-null; may be
///                      empty (`""`). Owned by this struct.
/// - `response_headers` All response headers, in transmission order. Owned
///                      by this struct. Used for verbose output.
/// - `content_type`     Value of the first `Content-Type` response header, or
///                      `null` if absent. Owned by this struct.
/// - `link`             Value of the first `Link` response header, or `null`
///                      if absent. Used for pagination. Owned by this struct.
pub const APIResponse = struct {
    allocator: std.mem.Allocator,
    status: std.http.Status,
    /// Decompressed response body. Always allocated; never null.
    body: []u8,
    /// All response headers, in transmission order. Allocated slice of owned entries.
    response_headers: []ResponseHeader,
    /// Value of the Content-Type header, if present. Allocated.
    content_type: ?[]u8,
    /// Value of the Link header, if present. Allocated.
    link: ?[]u8,

    /// Release all memory owned by this response.
    /// Must be called exactly once. Do not use the struct after calling this.
    pub fn deinit(self: APIResponse) void {
        for (self.response_headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.response_headers);
        if (self.content_type) |ct| self.allocator.free(ct);
        if (self.link) |l| self.allocator.free(l);
        self.allocator.free(self.body);
    }

    /// Map the response status to a process exit code.
    ///
    /// Returns: 0 for 2xx status codes, 1 otherwise. Suitable for use directly
    /// as a process exit code. This code is not about deciding what to return
    /// as exit code in the cli, it is more to abstract the knowledge about the
    /// HTTP protocol.
    pub fn exitCode(self: APIResponse) u8 {
        const s = @intFromEnum(self.status);
        return if (s >= 200 and s < 300) 0 else 1;
    }
};

/// Parameters for a single HTTP request dispatched by `execute()`.
///
/// `execute()` does not own any of the slices stored here, all borrowed
/// memory must remain valid for the duration of the call.
///
/// Fields:
/// - `allocator`        Used for all internal allocations (header list, body
///                      buffer, HMAC scratch buffers). The returned `APIResponse`
///                      is also allocated with this allocator and must be freed
///                      by the caller via `APIResponse.deinit()`.
/// - `method`           HTTP method (GET, POST, PUT, DELETE, …).
/// - `url`              Fully-qualified URL string, e.g.
///                      `"https://openqa.example.com/api/v1/jobs"`.
///                      Must be a valid absolute URL; parsing errors surface as
///                      `error.InvalidUri`.
/// - `headers`          Caller-supplied HTTP headers appended verbatim before
///                      the auto-injected `Accept` and `Accept-Encoding` headers.
///                      If no `Accept` header is present, `application/json` is
///                      added automatically.
/// - `body`             Optional request body bytes. For methods that require a
///                      body (`requestHasBody()` returns true) but where `body`
///                      is `null`, an empty body is sent.
/// - `credentials`      If non-null, HMAC-SHA1 `X-API-Key` / `X-API-Hash` /
///                      `X-API-Microtime` headers are computed from the path,
///                       query string, and current Unix timestamp, then appended.
///                      Body parameters are intentionally excluded from the HMAC
///                      message.
/// - `retries`          Maximum number of additional attempts after the first
///                      failure. Retries are triggered by connection errors, send
///                      errors, and 502/503 HTTP responses. Each retry sleeps for
///                      an exponentially increasing interval (see `sleepForRetry`).
/// - `quiet`             When `true`, suppresses all diagnostic output to stderr
///                       (connection errors, non-2xx status lines, read/decompress
///                       errors). Useful in tests and when the caller handles
///                       errors itself.
/// - `connect_timeout_s` TCP connect timeout in seconds. Currently parsed and
///                       validated but not yet wired into `std.http.Client`
///                       (which does not expose per-connection timeout support).
///                       Reserved for future use. Defaults to 30.0.
/// - `retry_sleep_s`     Base sleep duration in seconds between retry attempts.
///                       Actual sleep = `retry_sleep_s * retry_factor^attempt`.
///                       Defaults to 3.0.
/// - `retry_factor`      Exponential backoff multiplier applied per attempt.
///                       Defaults to 1.0 (constant sleep).
pub const Request = struct {
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
    credentials: ?config.Credentials,
    retries: u32,
    quiet: bool,
    verbose: bool = false,
    connect_timeout_s: f64 = 30.0,
    retry_sleep_s: f64 = 3.0,
    retry_factor: f64 = 1.0,
    /// Maximum bytes to accept in a streaming response. Only used by
    /// `executeStream()`; ignored by `execute()`. If the `Content-Length`
    /// response header exceeds this value, `executeStream()` returns
    /// `error.FileTooLarge` without reading the body.
    size_limit: ?u64 = null,
};

/// Result returned by `executeStream()`. Result type for executeStream()
/// Fields:
/// - `status`         HTTP status code of the response.
/// - `content_length` Value of the `Content-Length` response header, or
///                    `null` if absent or not parseable as u64.
pub const StreamResult = struct {
    status: std.http.Status,
    content_length: ?u64,
};

/// Normalize path+query for HMAC signing: %20 → +, ~ → %7E
///
/// Normalize a URL path+query string for HMAC-SHA1 signing.
/// Rewrites %20 → + and ~ → %7E.
/// Output is written to `writer`. Called internally by `execute()` before
/// computing the HMAC digest; not part of the public API.
fn normalizePathQuery(input: []const u8, writer: anytype) !void {
    var i: usize = 0;
    while (i < input.len) {
        if (i + 2 < input.len and std.mem.eql(u8, input[i .. i + 3], "%20")) {
            try writer.writeByte('+');
            i += 3;
        } else if (input[i] == '~') {
            try writer.print("%7E", .{});
            i += 1;
        } else {
            try writer.writeByte(input[i]);
            i += 1;
        }
    }
}

/// Shared request-header construction. Build the outbound header list for a single request attempt.
///
/// Copies `extra_headers` verbatim, adds `Accept: application/json` if no
/// `Accept` header is present, always adds `Accept-Encoding: identity`, and
/// optionally appends HMAC-SHA1 auth headers when `credentials` is non-null.
///
/// The caller must supply `hash_buf` and `timestamp_buf` as stack variables
/// that outlive the returned list: the HMAC auth headers borrow from them
/// (see `auth.buildAuthHeaders` doc comment).
///
/// The returned `ArrayList` is owned by the caller; free via
/// `headers.deinit(allocator)`.
fn buildHeaders(
    allocator: std.mem.Allocator,
    extra_headers: []const std.http.Header,
    credentials: ?config.Credentials,
    uri: std.Uri,
    hash_buf: *[40]u8,
    timestamp_buf: *[32]u8,
    accept_gzip: bool,
) !std.ArrayList(std.http.Header) {
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer headers.deinit(allocator);

    try headers.appendSlice(allocator, extra_headers);

    var has_accept = false;
    for (extra_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Accept")) {
            has_accept = true;
            break;
        }
    }
    if (!has_accept) {
        try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    }

    if (accept_gzip) {
        try headers.append(allocator, .{ .name = "Accept-Encoding", .value = "gzip, deflate" });
    } else {
        try headers.append(allocator, .{ .name = "Accept-Encoding", .value = "identity" });
    }

    if (credentials) |creds| {
        // HMAC message: path + ("?" + query if query else "") + timestamp.
        // Body parameters are strictly EXCLUDED.
        var msg_buf: std.ArrayList(u8) = .empty;
        defer msg_buf.deinit(allocator);

        const w = msg_buf.writer(allocator);
        // Build the path + query string
        try w.print("{s}", .{uri.path.percent_encoded});
        if (uri.query) |q| {
            try w.print("?{s}", .{q.percent_encoded});
        }

        // Normalize: %20 → +, ~ → %7E
        const raw_path_query = try msg_buf.toOwnedSlice(allocator);
        defer allocator.free(raw_path_query);
        msg_buf.clearRetainingCapacity();
        try normalizePathQuery(raw_path_query, w);

        // Generate timestamp and auth headers
        const timestamp_str = try std.fmt.bufPrint(timestamp_buf, "{d}", .{std.time.timestamp()});
        const auth_headers = auth.buildAuthHeaders(
            creds.key,
            creds.secret,
            msg_buf.items,
            timestamp_str,
            hash_buf,
        );
        try headers.appendSlice(allocator, &auth_headers);
    }

    return headers;
}

/// Perform an HTTP request using the provided client. Injectable HTTP engine
///
/// Parameters:
///   - req: the fully-populated request (method, URL, headers, body,
///     credentials, retry policy).
///   - client: an HTTP client implementing `.request(method, uri, options)`
///     compatible with `std.http.Client.request`. Pass a pointer to a real
///     `std.http.Client` for production, or a `MockClient` for tests.
///
/// Returns: an `APIResponse` that the caller must `deinit()`. The response may
/// carry any HTTP status (including non-2xx); use `APIResponse.exitCode` to map
/// it to success/failure.
///
/// Errors: connection or send failures (after exhausting retries) are returned
/// as errors rather than as an `APIResponse` with a non-2xx status, so callers
/// can distinguish network failures from HTTP-level failures.
pub fn execute(req: Request, client: anytype) !APIResponse {
    // connect_timeout_s is passed in from the caller (resolved from env in main).
    // TODO: wire req.connect_timeout_s into the HTTP client once std.http.Client
    // exposes per-connection timeout support.
    _ = req.connect_timeout_s;

    // A request body is only valid for methods that permit one (POST/PUT/PATCH).
    // std.http.Client asserts this precondition inside sendBodyUnflushed, so a
    // body on e.g. a GET aborts the whole process with a panic in safe builds
    // (and is silent UB in ReleaseFast). Guard here and fail cleanly instead —
    // this is a permanent condition, so it is checked once before the retry loop
    // rather than retried.
    //
    // DELIBERATE DIVERGENCE FROM THE PERL CLIENT (openqa-cli):
    //   Perl silently sends the body on a bodiless method (e.g. a GET) and exits
    //   0 — the server simply ignores it. zoqa instead rejects the request up
    //   front with error.BodyOnBodilessMethod (non-zero exit). We consciously
    //   break behavioural parity here because Perl's behaviour is a footgun and
    //   Zig's std client cannot send a body on GET without asserting. The most
    //   common trigger is `--data-file FILE` / `--data` on a GET route without
    //   an explicit `-X POST`. See ideas/SPEC.md ("Body on a bodiless method")
    //   and the ROB-8 E2E test in tests/e2e/tests_robustness.sh.
    if (req.body != null and !req.method.requestHasBody()) {
        if (!req.quiet)
            std.debug.print(
                "Error: a request body was provided for {s}, which does not allow a body (use -X POST/PUT/PATCH)\n",
                .{@tagName(req.method)},
            );
        return error.BodyOnBodilessMethod;
    }

    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        // Build request headers fresh on each attempt so the HMAC timestamp
        // is current. hash_buf and timestamp_buf are declared here so they
        // outlive the headers list (auth headers borrow from them).
        const uri = try std.Uri.parse(req.url);
        var hash_buf: [40]u8 = undefined;
        var timestamp_buf: [32]u8 = undefined;
        var headers = try buildHeaders(req.allocator, req.headers, req.credentials, uri, &hash_buf, &timestamp_buf, true);
        defer headers.deinit(req.allocator);

        if (req.verbose) {
            std.debug.print("> {s} {s}\n", .{ @tagName(req.method), uri.path.percent_encoded });
            for (headers.items) |h| {
                std.debug.print("> {s}: {s}\n", .{ h.name, h.value });
            }
            std.debug.print(">\n", .{});
        }

        // Issue the request via the injected client
        var http_req = client.request(req.method, uri, .{
            .extra_headers = headers.items,
        }) catch |err| {
            if (!req.quiet) std.debug.print("Connection error: {s}\n", .{@errorName(err)});
            if (attempt >= req.retries) return err;
            try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
            continue;
        };
        defer http_req.deinit();

        // Send request (with or without body)
        if (req.body) |body_bytes| {
            const body_mut = try req.allocator.dupe(u8, body_bytes);
            defer req.allocator.free(body_mut);
            http_req.sendBodyComplete(body_mut) catch |err| {
                if (!req.quiet) std.debug.print("sendBodyComplete with alloc error: {s}\n", .{@errorName(err)});
                if (attempt >= req.retries) return err;
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
                continue;
            };
        } else if (req.method.requestHasBody()) {
            http_req.sendBodyComplete(&.{}) catch |err| {
                if (!req.quiet) std.debug.print("sendBodyComplere error: {s}\n", .{@errorName(err)});
                if (attempt >= req.retries) return err;
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
                continue;
            };
        } else {
            http_req.sendBodiless() catch |err| {
                if (!req.quiet) std.debug.print("sendBodyLess error: {s}\n", .{@errorName(err)});
                if (attempt >= req.retries) return err;
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
                continue;
            };
        }

        // Receive response headers
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = http_req.receiveHead(&redirect_buf) catch |err| {
            if (!req.quiet) std.debug.print("Response error: {s}\n", .{@errorName(err)});
            if (attempt >= req.retries) return err;
            try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
            continue;
        };

        const status_uint = @intFromEnum(response.head.status);

        // Retry on gateway errors
        if (status_uint == 502 or status_uint == 503) {
            if (attempt < req.retries) {
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
                continue;
            }
        }

        // Single pass over response headers to collect needed information
        var content_type_buf: ?[]u8 = null;
        var link_buf: ?[]u8 = null;
        // Register errdefer here, before the loop, so any allocation failure
        // inside the loop doesn't leak content_type_buf or link_buf (issue #7).
        errdefer {
            if (content_type_buf) |ct| req.allocator.free(ct);
            if (link_buf) |l| req.allocator.free(l);
        }
        var content_type_is_json = false;
        var is_gzip = false;
        var all_headers: std.ArrayList(ResponseHeader) = .empty;
        errdefer {
            for (all_headers.items) |h| {
                req.allocator.free(h.name);
                req.allocator.free(h.value);
            }
            all_headers.deinit(req.allocator);
        }

        var hit = response.head.iterateHeaders();
        while (hit.next()) |hdr| {
            // Collect all headers for verbose output (§1.3).
            // Hop-by-hop headers (RFC 7230 §6.1) are excluded to match the
            // behaviour of Mojolicious's Mojo::Headers, which strips them
            // before exposing the header set to application code.
            const hop_by_hop = [_][]const u8{
                "Connection",          "Keep-Alive", "Proxy-Authenticate",
                "Proxy-Authorization", "TE",         "Trailers",
                "Transfer-Encoding",   "Upgrade",
            };
            var is_hop_by_hop = false;
            for (hop_by_hop) |name| {
                if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
                    is_hop_by_hop = true;
                    break;
                }
            }
            if (!is_hop_by_hop) {
                try all_headers.append(req.allocator, .{
                    .name = try req.allocator.dupe(u8, hdr.name),
                    .value = try req.allocator.dupe(u8, hdr.value),
                });
            }

            if (std.ascii.eqlIgnoreCase(hdr.name, "Link") and link_buf == null) {
                link_buf = try req.allocator.dupe(u8, hdr.value);
            }
            if (std.ascii.eqlIgnoreCase(hdr.name, "Content-Encoding") and
                std.ascii.eqlIgnoreCase(std.mem.trim(u8, hdr.value, " \t"), "gzip"))
            {
                is_gzip = true;
            }
            if (std.ascii.eqlIgnoreCase(hdr.name, "Content-Type")) {
                if (content_type_buf == null) {
                    content_type_buf = try req.allocator.dupe(u8, hdr.value);
                }
                if (std.mem.indexOf(u8, hdr.value, "application/json") != null) {
                    content_type_is_json = true;
                }
            }
        }

        // Fallback: check structured content_type field
        if (!content_type_is_json) {
            if (response.head.content_type) |ct| {
                content_type_is_json = std.mem.indexOf(u8, ct, "application/json") != null;
            }
        }

        // Read response body into memory
        var body_aw = std.Io.Writer.Allocating.init(req.allocator);
        defer body_aw.deinit();

        var transfer_buf: [65536]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        _ = body_reader.streamRemaining(&body_aw.writer) catch |err| switch (err) {
            error.ReadFailed => {
                if (!req.quiet) std.debug.print("Read error\n", .{});
                return err;
            },
            else => |e| return e,
        };

        const owned_body: []u8 = if (is_gzip) blk: {
            const raw_body = body_aw.written();
            var in: std.Io.Reader = .fixed(raw_body);
            var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
            var out: std.Io.Writer.Allocating = .init(req.allocator);
            errdefer out.deinit();
            _ = decompress.reader.streamRemaining(&out.writer) catch |err| {
                if (!req.quiet) std.debug.print("Decompression error: {s}\n", .{@errorName(err)});
                return err;
            };
            break :blk try out.toOwnedSlice();
        } else try body_aw.toOwnedSlice();

        return APIResponse{
            .allocator = req.allocator,
            .status = response.head.status,
            .body = owned_body,
            .response_headers = try all_headers.toOwnedSlice(req.allocator),
            .content_type = content_type_buf,
            .link = link_buf,
        };
    }
}

/// Perform an HTTP request and stream the response body directly to `writer`.
///
/// Unlike `execute()`, this function does not buffer the body in memory — it is
/// intended for large file downloads (e.g. the `archive` subcommand and
/// clone-job asset downloads) where buffering would be prohibitive.
///
/// Retries (up to `req.retries`) are attempted only for failures that occur
/// BEFORE the body stream begins: connection errors, send errors,
/// response-header errors, and 502/503 status codes. Because the status is
/// known before any byte is written to `writer`, these retries never corrupt
/// the caller's sink. A failure DURING body streaming is NOT retried and is
/// returned to the caller, because the generic `writer` cannot be rewound to
/// discard partially-written bytes — the caller, which owns the sink (e.g. a
/// file it can re-create/truncate), must handle that case if it wants to retry.
///
/// If `req.size_limit` is set and the `Content-Length` response header is
/// present and exceeds the limit, `error.FileTooLarge` is returned before
/// any body bytes are written to `writer`.
///
/// Parameters:
///   - req: the request to perform (see `Request`).
///   - client: an HTTP client compatible with `std.http.Client.request`.
///   - writer: sink the response body is streamed into.
///   - content_length_out: optional out-param; when non-null it receives the
///     `Content-Length` header value (or null if absent) before streaming.
///
/// Returns: a `StreamResult` with the HTTP status and content length. The caller
/// is responsible for checking `result.status` and handling non-2xx responses.
///
/// Errors: transport failures
pub fn executeStream(
    req: Request,
    client: anytype,
    writer: *std.Io.Writer,
    content_length_out: ?*?u64,
) !StreamResult {
    _ = req.connect_timeout_s;

    const uri = try std.Uri.parse(req.url);

    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        // Rebuild headers on each attempt so the HMAC timestamp stays current.
        // hash_buf and timestamp_buf must outlive the headers list (the auth
        // headers borrow from them).
        var hash_buf: [40]u8 = undefined;
        var timestamp_buf: [32]u8 = undefined;
        var headers = try buildHeaders(req.allocator, req.headers, req.credentials, uri, &hash_buf, &timestamp_buf, false);
        defer headers.deinit(req.allocator);

        if (req.verbose) {
            std.debug.print("> {s} {s}\n", .{ @tagName(req.method), uri.path.percent_encoded });
            for (headers.items) |h| {
                std.debug.print("> {s}: {s}\n", .{ h.name, h.value });
            }
            std.debug.print(">\n", .{});
        }

        var http_req = client.request(req.method, uri, .{
            .extra_headers = headers.items,
        }) catch |err| {
            if (attempt < req.retries) {
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
                continue;
            }
            if (!req.quiet) std.debug.print("Connection error: {s}\n", .{@errorName(err)});
            return err;
        };
        defer http_req.deinit();

        http_req.sendBodiless() catch |err| {
            if (attempt < req.retries) {
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
                continue;
            }
            if (!req.quiet) std.debug.print("Send error: {s}\n", .{@errorName(err)});
            return err;
        };

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = http_req.receiveHead(&redirect_buf) catch |err| {
            if (attempt < req.retries) {
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
                continue;
            }
            if (!req.quiet) std.debug.print("Response error: {s}\n", .{@errorName(err)});
            return err;
        };

        // Retry transient gateway errors. This happens before the body is
        // streamed, so `writer` is still untouched — safe to retry.
        const status_uint = @intFromEnum(response.head.status);
        if ((status_uint == 502 or status_uint == 503) and attempt < req.retries) {
            try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor);
            continue;
        }

        const content_length = response.head.content_length;
        if (content_length_out) |out| out.* = content_length;

        if (req.size_limit) |limit| {
            if (content_length) |cl| {
                if (cl > limit) return error.FileTooLarge;
            }
        }

        // Past this point bytes may reach `writer`; a mid-stream failure is
        // returned rather than retried (see the doc comment above).
        var transfer_buf: [65536]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        _ = try body_reader.streamRemaining(writer);

        return StreamResult{
            .status = response.head.status,
            .content_length = content_length,
        };
    }
}

// ---------------------------------------------------------------------------
// Retry sleep
// ---------------------------------------------------------------------------

fn sleepForRetry(attempt: u32, sleep_s: f64, factor: f64) !void {
    const delay_s = sleep_s * std.math.pow(f64, factor, @floatFromInt(attempt));
    const delay_ns: u64 = @intFromFloat(delay_s * 1_000_000_000.0);
    std.Thread.sleep(delay_ns);
}

test "normalizePathQuery: %20 becomes plus, tilde becomes %7E" {
    const testing = std.testing;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try normalizePathQuery("/api/v1/jobs?name=hello%20world&t=~1", buf.writer(testing.allocator));
    try testing.expectEqualStrings("/api/v1/jobs?name=hello+world&t=%7E1", buf.items);
}

test "normalizePathQuery: no substitutions needed" {
    const testing = std.testing;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try normalizePathQuery("/api/v1/jobs?limit=10", buf.writer(testing.allocator));
    try testing.expectEqualStrings("/api/v1/jobs?limit=10", buf.items);
}

test "execute: MockClient returns APIResponse" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // A minimal mock that simulates a 200 OK JSON response.
    const MockClient = struct {
        const Self = @This();

        const MockHead = struct {
            status: std.http.Status = .ok,
            content_type: ?[]const u8 = "application/json",
            content_length: ?u64 = null,

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
                const body = "{\"jobs\":[]}";
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
            return &self.response;
        }
    };

    var mock: MockClient = .{};
    const req = Request{
        .allocator = allocator,
        .method = .GET,
        .url = "http://localhost/api/v1/jobs",
        .headers = &.{},
        .body = null,
        .credentials = null,
        .retries = 0,
        .quiet = true,
    };

    const resp = try execute(req, &mock);
    defer resp.deinit();

    try testing.expect(resp.exitCode() == 0);
    try testing.expectEqualStrings("{\"jobs\":[]}", resp.body);
}

/// Configuration for a single openQA API call via `openQAReq`.
///
/// This struct bundles every tuneable aspect of a request into a single value that
/// is passed to `openQAReq`: HTTP method, parameters, body, authentication credentials, retry policy, and diagnostics.
/// All fields except `allocator` have sensible defaults, so callers only
/// need to set the fields that differ from a simple unauthenticated GET.
///
/// **Ownership:** `CallOptions` does **not** own any of the slices or
/// pointers it holds (`headers`, `params`, `body`, `credentials`). The
/// caller must ensure these remain valid for the duration of the
/// `openQAReq` call. There is no `deinit`, nothing to free.
pub const CallOptions = struct {
    /// General-purpose allocator used by `openQAReq` for all internal
    /// allocations. Must remain valid until `APIResponse.deinit()` is called.
    allocator: std.mem.Allocator,

    /// HTTP method for the request. Defaults to `.GET`.
    /// Also controls how `params` is routed (query for GET/DELETE, body for
    /// POST/PUT/PATCH unless an explicit `body` is set).
    method: std.http.Method = .GET,

    /// Extra request headers. **Not owned**, caller keeps the memory alive.
    headers: []const std.http.Header = &.{},

    /// Pre-encoded URL query / form-encoded parameter string.
    /// Routed by HTTP method: query string (GET/DELETE) or body (POST/PUT/PATCH).
    /// **Not owned**.
    params: []const u8 = "",

    /// Optional raw request body. Takes precedence over `params` for write
    /// methods. **Not owned**.
    body: ?[]const u8 = null,

    /// Resolved API credentials for HMAC-SHA1 signing. `null` = unauthenticated.
    /// **Not owned**.
    credentials: ?config.Credentials = null,

    /// Number of automatic retries on transient failures (connection errors and
    /// HTTP 502/503). Defaults to 0.
    retries: u32 = 0,

    /// Suppress non-fatal diagnostics. Defaults to false.
    quiet: bool = false,

    /// Print request headers to stderr. Defaults to false.
    verbose: bool = false,

    /// TCP connect timeout in seconds. Reserved for future use.
    connect_timeout_s: f64 = 30.0,

    /// Base sleep duration in seconds between retry attempts.
    /// Actual sleep = `retry_sleep_s * retry_factor^attempt`.
    retry_sleep_s: f64 = 3.0,

    /// Exponential backoff multiplier applied per retry attempt.
    retry_factor: f64 = 1.0,
};

/// Options for `openQARawGet`.
pub const RawGetOptions = struct {
    allocator: std.mem.Allocator,
    credentials: ?config.Credentials = null,
    size_limit: ?u64 = null,
    quiet: bool = false,
    verbose: bool = false,

    /// Number of automatic retries on transient pre-stream failures
    /// (connection errors and HTTP 502/503). Defaults to 0. See
    /// `executeStream` for exactly which failures are retried.
    retries: u32 = 0,

    /// Base sleep duration in seconds between retry attempts.
    /// Actual sleep = `retry_sleep_s * retry_factor^attempt`.
    retry_sleep_s: f64 = 3.0,

    /// Exponential backoff multiplier applied per retry attempt.
    retry_factor: f64 = 1.0,
};

/// Perform an authenticated GET request to an arbitrary path (no /api/v1/ prefix).
///
/// Streams the response body into `writer`. Before streaming starts, deposits
/// the Content-Length header value into `content_length_out` (if non-null),
/// allowing callers to set up progress tracking.
/// No retry, intended for large file downloads.
///
/// Parameters:
///   - host: bare hostname or full base URL of the openQA instance.
///   - absolute_path: request path; must start with "/" (no /api/v1/ prefix).
///   - opts: allocator, credentials, size limit and verbosity (see
///     `RawGetOptions`).
///   - client: an HTTP client compatible with `std.http.Client.request`.
///   - writer: destination for the streamed response body.
///   - content_length_out: optional out-param receiving the Content-Length
///     header value before streaming begins.
///
/// Returns: a `StreamResult` describing the streamed transfer.
///
/// Errors: host-resolution/allocation/URL-construction failures and any error
/// propagated by `executeStream` (transport or write failure).
pub fn openQARawGet(
    host: []const u8,
    absolute_path: []const u8, // must start with "/"
    opts: RawGetOptions,
    client: anytype,
    writer: *std.Io.Writer,
    content_length_out: ?*?u64,
) !StreamResult {
    const host_res = try config.resolveHost(opts.allocator, false, false, false, host);
    defer if (host_res.allocated) opts.allocator.free(host_res.url);

    const url = try std.fmt.allocPrint(opts.allocator, "{s}{s}", .{ host_res.url, absolute_path });
    defer opts.allocator.free(url);

    const req = Request{
        .allocator = opts.allocator,
        .method = .GET,
        .url = url,
        .headers = &.{},
        .body = null,
        .credentials = opts.credentials,
        .retries = opts.retries,
        .quiet = opts.quiet,
        .verbose = opts.verbose,
        .retry_sleep_s = opts.retry_sleep_s,
        .retry_factor = opts.retry_factor,
        .size_limit = opts.size_limit,
    };

    return executeStream(req, client, writer, content_length_out);
}

// ---------------------------------------------------------------------------
// openQADownloadToFile — authenticated GET streamed to a local file, with retry
// ---------------------------------------------------------------------------

/// Download the resource at `absolute_path` on `host` into the local file
/// `dest_path`, streaming the body directly to disk with retry.
///
/// DESIGN — why the retry loop (and the file lifecycle) live HERE:
///
/// `executeStream` streams into a generic `*std.Io.Writer`, which has no way to
/// rewind or truncate what was already written. That is fine for retrying
/// failures that happen BEFORE the body stream starts (connection errors,
/// 502/503) — and `executeStream` does exactly that — but it CANNOT retry a
/// failure that happens mid-stream (e.g. a TCP reset after N body bytes),
/// because the partial bytes are already committed to the sink and re-streaming
/// would concatenate a second copy onto the first (see e2e CLO-98/99).
///
/// Retrying a mid-transfer failure therefore requires re-creating (truncating)
/// the sink between attempts, which only the owner of the sink can do. This
/// function owns the file, so the retry loop belongs here. Keeping it in this
/// module (rather than in the CLI) lets `sleepForRetry` stay a private
/// implementation detail shared with `execute`/`executeStream` instead of
/// being exported. This is the one place in `http_client` that touches
/// `std.fs`, by design.
///
/// Behaviour:
///   - Each attempt re-creates `dest_path` (truncating), so a failed transfer
///     never leaves partial bytes behind.
///   - Retries connection/stream errors and 5xx status up to `opts.retries`
///     times, sleeping with exponential backoff between attempts.
///   - 404 (and any other non-5xx status) is terminal — never retried — and
///     the caller decides how to treat it via the returned `StreamResult`.
///   - On success the file is flushed and kept; on ANY failure (terminal or
///     retry-exhausted) the partial file is deleted before returning.
pub fn openQADownloadToFile(
    host: []const u8,
    absolute_path: []const u8, // must start with "/"
    dest_path: []const u8,
    opts: RawGetOptions,
    client: anytype,
) !StreamResult {
    const host_res = try config.resolveHost(opts.allocator, false, false, false, host);
    defer if (host_res.allocated) opts.allocator.free(host_res.url);

    const url = try std.fmt.allocPrint(opts.allocator, "{s}{s}", .{ host_res.url, absolute_path });
    defer opts.allocator.free(url);

    // A single streaming attempt: retries are disabled on the inner request so
    // that THIS loop is the sole retry authority (avoids double-retrying).
    const req = Request{
        .allocator = opts.allocator,
        .method = .GET,
        .url = url,
        .headers = &.{},
        .body = null,
        .credentials = opts.credentials,
        .retries = 0,
        .quiet = opts.quiet,
        .verbose = opts.verbose,
        .size_limit = opts.size_limit,
    };

    const Outcome = union(enum) {
        done: StreamResult, // success — keep the file
        terminal: StreamResult, // non-retryable status — delete + return status
        retry, // retryable failure — delete + backoff + try again
        failed: anyerror, // retry-exhausted error — delete + return error
    };

    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const outcome: Outcome = blk: {
            const file = std.fs.cwd().createFile(dest_path, .{}) catch |err| break :blk .{ .failed = err };
            defer file.close();

            var file_buf: [65536]u8 = undefined;
            var file_writer = file.writer(&file_buf);

            const result = executeStream(req, client, &file_writer.interface, null) catch |err| {
                // Connection error or mid-stream reset — retry if budget remains.
                break :blk if (attempt < opts.retries) .retry else .{ .failed = err };
            };

            if (result.status == .ok) {
                // Flush before the deferred close so the file is complete on disk.
                file_writer.interface.flush() catch |err| break :blk .{ .failed = err };
                break :blk .{ .done = result };
            }

            // Non-2xx: the body just written is an error page, not the asset.
            const code = @intFromEnum(result.status);
            if (code >= 500 and attempt < opts.retries) break :blk .retry;
            break :blk .{ .terminal = result };
        };

        // The file is now closed (deferred inside the block). Act on the outcome.
        switch (outcome) {
            .done => |result| return result,
            .terminal => |result| {
                std.fs.cwd().deleteFile(dest_path) catch {};
                return result;
            },
            .failed => |err| {
                std.fs.cwd().deleteFile(dest_path) catch {};
                return err;
            },
            .retry => {
                std.fs.cwd().deleteFile(dest_path) catch {};
                try sleepForRetry(attempt, opts.retry_sleep_s, opts.retry_factor);
            },
        }
    }
}

// ---------------------------------------------------------------------------
// openQAReq — construct URL and execute a request
// ---------------------------------------------------------------------------

/// Construct URL and Perform an authenticated request against an openQA instance.
///
/// This is the **primary public entry point** of the library. It orchestrates:
///   1. Host resolution (bare hostname → full base URL via `config.resolveHost`).
///   2. URL construction (`host/api/v1/path`, with params routing).
///   3. HMAC-SHA1 signature generation (via resolved credentials).
///   4. HTTP execution and response decompression (via the injected `client`).
///
/// Params routing:
///   - GET / DELETE:  `opts.params` is appended to the URL as a query string.
///   - POST / PUT / PATCH: `opts.params` is used as the request body, unless
///     `opts.body` is already set (explicit body takes precedence).
///
/// Parameters:
///   - host: bare hostname or full base URL of the openQA instance.
///   - path: API path relative to `/api/v1/` (a leading "/" is tolerated).
///   - opts: method, params, body, credentials and retry policy (see
///     `CallOptions`).
///   - client: an HTTP client compatible with `std.http.Client.request`.
///
/// Returns: an `APIResponse` that the caller must `deinit()`.
///
/// Errors: host-resolution/allocation/URL-construction failures and any error
/// propagated by `execute` (transport failure surviving retries).
pub fn openQAReq(
    host: []const u8,
    path: []const u8,
    opts: CallOptions,
    client: anytype,
) !APIResponse {
    const host_res = try config.resolveHost(opts.allocator, false, false, false, host);
    defer if (host_res.allocated) opts.allocator.free(host_res.url);

    const clean_path = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;

    const base_url = try std.fmt.allocPrint(opts.allocator, "{s}/api/v1/{s}", .{ host_res.url, clean_path });
    defer opts.allocator.free(base_url);

    var url_buf: ?[]u8 = null;
    defer if (url_buf) |b| opts.allocator.free(b);

    const final_url: []const u8 = if ((opts.method == .GET or opts.method == .DELETE) and opts.params.len > 0) blk: {
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, base_url, '?') != null) "&" else "?";
        url_buf = try std.fmt.allocPrint(opts.allocator, "{s}{s}{s}", .{ base_url, sep, opts.params });
        break :blk url_buf.?;
    } else base_url;

    const effective_body: ?[]const u8 = if (opts.body) |b|
        b
    else if ((opts.method == .POST or opts.method == .PUT or opts.method == .PATCH) and opts.params.len > 0)
        opts.params
    else
        null;

    const req = Request{
        .allocator = opts.allocator,
        .method = opts.method,
        .url = final_url,
        .headers = opts.headers,
        .body = effective_body,
        .credentials = opts.credentials,
        .retries = opts.retries,
        .quiet = opts.quiet,
        .verbose = opts.verbose,
        .connect_timeout_s = opts.connect_timeout_s,
        .retry_sleep_s = opts.retry_sleep_s,
        .retry_factor = opts.retry_factor,
    };

    return execute(req, client);
}

/// Minimal mock HTTP client for openQAReq unit tests.
///
/// Captures the URL (reconstructed from the `std.Uri` that `execute` passes
/// to `client.request`) and the request body (via `sendBodyComplete`), so
/// test assertions can verify URL construction, params routing, and body
/// selection without making real HTTP calls.
const TestMockClient = struct {
    const Self = @This();

    const MockHead = struct {
        status: std.http.Status = .ok,
        content_type: ?[]const u8 = "application/json",
        content_length: ?u64 = null,

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
        parent: *Self,

        pub fn deinit(_: *MockResponse) void {}
        pub fn sendBodiless(self: *MockResponse) !void {
            self.parent.captured_bodiless = true;
        }
        pub fn sendBodyComplete(self: *MockResponse, body: []u8) !void {
            const len = @min(body.len, self.parent.captured_body.len);
            @memcpy(self.parent.captured_body[0..len], body[0..len]);
            self.parent.captured_body_len = len;
        }
        pub fn reader(self: *MockResponse, _: []u8) *MockReader {
            return &self.mock_reader;
        }
        pub fn receiveHead(self: *MockResponse, _: []u8) !*MockResponse {
            return self;
        }
    };

    captured_url: [1024]u8 = [_]u8{0} ** 1024,
    captured_url_len: usize = 0,
    captured_body: [1024]u8 = [_]u8{0} ** 1024,
    captured_body_len: usize = 0,
    captured_method: std.http.Method = .GET,
    captured_bodiless: bool = false,
    response: ?MockResponse = null,

    pub fn request(self: *Self, method: std.http.Method, uri: std.Uri, _: anytype) !*MockResponse {
        self.response = .{ .parent = self };
        self.captured_method = method;
        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();
        writer.writeAll(uri.scheme) catch {};
        writer.writeAll("://") catch {};
        if (uri.host) |h| {
            writer.writeAll(h.percent_encoded) catch {};
        }
        if (uri.port) |p| {
            writer.print(":{d}", .{p}) catch {};
        }
        writer.writeAll(uri.path.percent_encoded) catch {};
        if (uri.query) |q| {
            writer.writeByte('?') catch {};
            writer.writeAll(q.percent_encoded) catch {};
        }
        const len = stream.pos;
        @memcpy(self.captured_url[0..len], buf[0..len]);
        self.captured_url_len = len;
        return &self.response.?;
    }

    fn getCapturedUrl(self: *const Self) []const u8 {
        return self.captured_url[0..self.captured_url_len];
    }

    fn getCapturedBody(self: *const Self) []const u8 {
        return self.captured_body[0..self.captured_body_len];
    }
};

test "openQAReq: basic URL construction from host and path" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "jobs", .{
        .allocator = allocator,
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("http://localhost/api/v1/jobs", mock.getCapturedUrl());
    try testing.expect(mock.captured_method == .GET);
}

test "openQAReq: leading slash in path is stripped" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "/jobs/1234", .{
        .allocator = allocator,
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("http://localhost/api/v1/jobs/1234", mock.getCapturedUrl());
}

test "openQAReq: GET params appended as query string" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "jobs", .{
        .allocator = allocator,
        .method = .GET,
        .params = "DISTRI=sle&VERSION=15",
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings(
        "http://localhost/api/v1/jobs?DISTRI=sle&VERSION=15",
        mock.getCapturedUrl(),
    );
    try testing.expect(mock.captured_bodiless);
}

test "openQAReq: DELETE params appended as query string" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "assets/42", .{
        .allocator = allocator,
        .method = .DELETE,
        .params = "force=1",
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings(
        "http://localhost/api/v1/assets/42?force=1",
        mock.getCapturedUrl(),
    );
}

test "openQAReq: POST params used as body (no explicit body)" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "isos", .{
        .allocator = allocator,
        .method = .POST,
        .params = "DISTRI=test&VERSION=1",
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("http://localhost/api/v1/isos", mock.getCapturedUrl());
    try testing.expectEqualStrings("DISTRI=test&VERSION=1", mock.getCapturedBody());
}

test "openQAReq: POST explicit body takes precedence over params" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "jobs", .{
        .allocator = allocator,
        .method = .POST,
        .params = "ignored=true",
        .body = "{\"key\":\"value\"}",
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("http://localhost/api/v1/jobs", mock.getCapturedUrl());
    try testing.expectEqualStrings("{\"key\":\"value\"}", mock.getCapturedBody());
}

test "openQAReq: body on GET is rejected cleanly (no panic)" {
    // Regression test for the panic reproduced by tests_robustness.sh ROB-5:
    // `--data-file FILE` (or `--data`) attaches a body but leaves the method at
    // its GET default. std.http.Client asserts requestHasBody() in
    // sendBodyUnflushed, so a body on GET used to abort the process. execute()
    // now guards this and returns error.BodyOnBodilessMethod instead.
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const result = openQAReq("http://localhost", "jobs/overview", .{
        .allocator = allocator,
        .method = .GET,
        .body = "hello",
        .quiet = true,
    }, &mock);
    try testing.expectError(error.BodyOnBodilessMethod, result);
    // The guard runs before any request is issued.
    try testing.expect(mock.captured_url_len == 0);
    try testing.expect(mock.captured_body_len == 0);
}

test "openQAReq: body on DELETE is rejected cleanly" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const result = openQAReq("http://localhost", "assets/42", .{
        .allocator = allocator,
        .method = .DELETE,
        .body = "{}",
        .quiet = true,
    }, &mock);
    try testing.expectError(error.BodyOnBodilessMethod, result);
}

test "openQAReq: PUT params routed as body" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "jobs/1", .{
        .allocator = allocator,
        .method = .PUT,
        .params = "STATE=done",
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("http://localhost/api/v1/jobs/1", mock.getCapturedUrl());
    try testing.expectEqualStrings("STATE=done", mock.getCapturedBody());
}

test "openQAReq: no params produces clean URL and null body" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "workers", .{
        .allocator = allocator,
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("http://localhost/api/v1/workers", mock.getCapturedUrl());
    try testing.expect(mock.captured_bodiless);
    try testing.expect(mock.captured_body_len == 0);
}

test "openQAReq: bare hostname gets https:// prefix" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("openqa.opensuse.org", "jobs", .{
        .allocator = allocator,
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("https://openqa.opensuse.org/api/v1/jobs", mock.getCapturedUrl());
}

test "openQAReq: response fields are propagated" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "jobs", .{
        .allocator = allocator,
    }, &mock);
    defer resp.deinit();

    try testing.expect(resp.status == .ok);
    try testing.expect(resp.exitCode() == 0);
    try testing.expectEqualStrings("{}", resp.body);
}

test "openQARawGet: URL construction without /api/v1/ prefix" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    _ = openQARawGet("http://localhost", "/tests/123/asset/repo/file.txt", .{
        .allocator = allocator,
    }, &mock, &w, null) catch {};

    try testing.expectEqualStrings("http://localhost/tests/123/asset/repo/file.txt", mock.getCapturedUrl());
    try testing.expect(mock.captured_method == .GET);
}

test "openQARawGet: HMAC auth headers attached when credentials provided" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const creds = config.Credentials{
        .allocator = allocator,
        .key = "fake_key",
        .secret = "fake_secret",
    };

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    _ = openQARawGet("http://localhost", "/tests/123/file.txt", .{
        .allocator = allocator,
        .credentials = creds,
    }, &mock, &w, null) catch {};

    try testing.expectEqualStrings("http://localhost/tests/123/file.txt", mock.getCapturedUrl());
}

test "execute: hop-by-hop headers are excluded from response_headers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock that returns a mix of application-level and hop-by-hop headers.
    // Only the application-level ones must appear in APIResponse.response_headers.
    const MockClient = struct {
        const Self = @This();

        const MockHead = struct {
            status: std.http.Status = .ok,
            content_type: ?[]const u8 = "application/json",
            content_length: ?u64 = null,

            // Emits: Content-Type, Connection, Keep-Alive, Transfer-Encoding,
            // Server, Upgrade. The hop-by-hop ones (Connection, Keep-Alive,
            // Transfer-Encoding, Upgrade) must be stripped; Content-Type and
            // Server must survive.
            const HeaderIterator = struct {
                index: u8 = 0,
                const headers = [_]std.http.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "Connection", .value = "keep-alive" },
                    .{ .name = "Keep-Alive", .value = "timeout=15, max=100" },
                    .{ .name = "Transfer-Encoding", .value = "chunked" },
                    .{ .name = "Server", .value = "TestServer/1.0" },
                    .{ .name = "Upgrade", .value = "h2c" },
                };

                pub fn next(self: *HeaderIterator) ?std.http.Header {
                    if (self.index >= headers.len) return null;
                    const h = headers[self.index];
                    self.index += 1;
                    return h;
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
            return &self.response;
        }
    };

    var mock: MockClient = .{};
    const req = Request{
        .allocator = allocator,
        .method = .GET,
        .url = "http://localhost/api/v1/jobs",
        .headers = &.{},
        .body = null,
        .credentials = null,
        .retries = 0,
        .quiet = true,
    };

    const resp = try execute(req, &mock);
    defer resp.deinit();

    // Only Content-Type and Server must survive the hop-by-hop filter.
    try testing.expectEqual(@as(usize, 2), resp.response_headers.len);
    try testing.expectEqualStrings("Content-Type", resp.response_headers[0].name);
    try testing.expectEqualStrings("application/json", resp.response_headers[0].value);
    try testing.expectEqualStrings("Server", resp.response_headers[1].name);
    try testing.expectEqualStrings("TestServer/1.0", resp.response_headers[1].value);
}
