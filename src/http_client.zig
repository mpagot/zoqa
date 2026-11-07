//! HTTP client for the openQA API.
//!
//! Provides buffered (`execute`, `openQAReq`) and streaming
//! (`executeStream`, `openQARawGet`, `openQADownloadToFile`) request
//! functions with HMAC-SHA1 authentication, retry with exponential
//! backoff, and gzip decompression. The HTTP client is injected
//! (`client: anytype`) so tests and fuzz harnesses can substitute a mock.

const std = @import("std");
const config = @import("config.zig");
const auth = @import("auth.zig");
const fs_utils = @import("fs_utils.zig");

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
pub const APIResponse = struct {
    allocator: std.mem.Allocator,
    /// HTTP status code of the final (non-retried) response.
    status: std.http.Status,
    /// Decompressed response body. Always allocated; never null; may be empty (`""`). Owned by this struct.
    body: []u8,
    /// All response headers, in transmission order. Allocated slice of owned entries. Owned by this struct. Used for verbose output.
    response_headers: []ResponseHeader,
    /// Value of the Content-Type header, if present, `null` otherwise. Allocated.
    content_type: ?[]u8,
    /// Value of the Link header, if present. Allocated. Used for pagination.
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
    /// as a process exit code. The CLI decides the final exit code; this
    /// function only encodes the HTTP rule that 2xx means success.
    pub fn exitCode(self: APIResponse) u8 {
        const s = @intFromEnum(self.status);
        return if (s >= 200 and s < 300) 0 else 1;
    }
};

/// Parameters for a single HTTP request dispatched by `execute()` or `executeStream()`.
///
/// `execute()` does not own any of the slices stored here; all borrowed
/// memory must remain valid for the duration of the call.
const Request = struct {
    /// General-purpose allocator used for all internal allocations (header list,
    /// body buffer, HMAC scratch buffers). The returned `APIResponse` is also allocated
    /// with this allocator and must be freed by the caller via `APIResponse.deinit()`.
    allocator: std.mem.Allocator,

    /// HTTP method (GET, POST, PUT, DELETE, …).
    method: std.http.Method,

    /// Fully-qualified URL string, e.g. `"https://openqa.example.com/api/v1/jobs"`.
    /// Must be a valid absolute URL; parsing errors are returned as `error.InvalidUri`.
    url: []const u8,

    /// Caller-supplied HTTP headers appended verbatim before auto-injected `Accept`
    /// and `Accept-Encoding` headers. If no `Accept` header is present, `application/json`
    /// is added automatically.
    headers: []const std.http.Header,

    /// Optional request body bytes. For methods that require a body (`requestHasBody()`
    /// returns true) but where `body` is `null`, an empty body is sent.
    body: ?[]const u8,

    /// If non-null, HMAC-SHA1 `X-API-Key` / `X-API-Hash` / `X-API-Microtime` headers
    /// are computed from the path, query string, and current Unix timestamp, then appended.
    /// Body parameters are intentionally excluded from the HMAC message.
    credentials: ?config.Credentials,

    /// Maximum number of additional attempts after the first failure. Retries are triggered
    /// by connection errors, send errors, and 502/503 HTTP responses. Each retry sleeps for
    /// an exponentially increasing interval (see `sleepForRetry`).
    retries: u32,

    /// When `true`, suppresses all diagnostic output to stderr (connection errors,
    /// non-2xx status lines, read/decompress errors). Useful in tests and when the caller
    /// handles errors itself.
    quiet: bool,

    /// When `true`, prints detailed request and response HTTP headers to stdout. Defaults to `false`.
    verbose: bool = false,

    /// TCP connect timeout in seconds. Currently parsed and validated but not yet wired into
    /// `std.http.Client` (which does not expose per-connection timeout support). Reserved for future use.
    /// Defaults to 30.0.
    connect_timeout_s: f64 = 30.0,

    /// Base sleep duration in seconds between retry attempts.
    /// Actual sleep = `retry_sleep_s * retry_factor^attempt`. Defaults to 3.0.
    retry_sleep_s: f64 = 3.0,

    /// Exponential backoff multiplier applied per attempt. Defaults to 1.0 (constant sleep).
    retry_factor: f64 = 1.0,

    /// Maximum bytes to accept in a streaming response. Only used by `executeStream()`;
    /// ignored by `execute()`. If the `Content-Length` response header exceeds this value,
    /// `executeStream()` returns `error.FileTooLarge` without reading the body.
    size_limit: ?u64 = null,

    /// Optional expected byte size of the response payload. Used by `executeStream()`
    /// to detect incomplete transfers or to validate stream size when `Content-Length` header is absent.
    expected_size: ?u64 = null,

    /// When `true`, permits streaming responses without a `Content-Length` header or `expected_size`.
    /// Defaults to `false`.
    allow_lengthless: bool = false,

    /// When `true`, rejects HTTP 200 responses with `Content-Type: text/html` (`error.UnexpectedHtmlResponse`).
    /// Used for asset downloads to prevent saving HTML challenge/error pages as binary payload files.
    reject_html: bool = false,
};

/// Result returned by `executeStream()`.
pub const StreamResult = struct {
    /// HTTP status code of the response.
    status: std.http.Status,

    /// Value of the `Content-Length` response header, or `null` if absent or not parseable as u64.
    content_length: ?u64,

    /// Parsed `Retry-After` header value in seconds, or `null` when absent or unparsable.
    /// Only meaningful for non-retryable (terminal) results; callers use it to honour the
    /// server's delay on their own retry loop.
    retry_after_s: ?u64 = null,
};

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

/// Build the outbound header list for a single request attempt.
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

/// Maximum redirect hops followed per request. Matches the Perl client
/// (`max_redirects(3)` in `OpenQA::Script::CloneJob`).
const max_redirects: u8 = 3;

/// Return true for the redirect statuses that `execute()` and
/// `executeStream()` follow (301, 302, 303, 307, 308).
fn isFollowableRedirect(status: std.http.Status) bool {
    return switch (status) {
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => true,
        else => false,
    };
}

/// Return true for errors raised by `RedirectState.follow`. They are permanent:
/// retrying the same URL produces the same redirect chain.
fn isRedirectError(err: anyerror) bool {
    return err == error.TooManyHttpRedirects or
        err == error.HttpRedirectLocationMissing or
        err == error.HttpRedirectLocationInvalid;
}

/// Return the port used for `uri`, filling in the scheme default.
fn effectivePort(uri: std.Uri) ?u16 {
    if (uri.port) |p| return p;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return null;
}

/// Return true when `a` and `b` share scheme, host and port.
fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    var a_buf: [std.Uri.host_name_max]u8 = undefined;
    var b_buf: [std.Uri.host_name_max]u8 = undefined;
    const a_host = a.getHost(&a_buf) catch return false;
    const b_host = b.getHost(&b_buf) catch return false;
    return std.ascii.eqlIgnoreCase(a_host, b_host) and effectivePort(a) == effectivePort(b);
}

/// Redirect state for the request loops of `execute()` and `executeStream()`.
///
/// WHY manual redirects: `std.http.Client` follows a redirect by re-sending the
/// same `extra_headers`, so the `X-API-Hash` signed for `/tests/<id>/asset/...`
/// reaches `/assets/...`. openQA with `[auth] require_for_assets = 1` (e.g.
/// OSD) rejects that with 403. The loops therefore request with
/// `.redirect_behavior = .unhandled`, call `follow()` on a 3xx, and rebuild the
/// headers on the next iteration, so every hop is signed for its own path.
/// Perl does the same: it resolves the final URL first, then signs it.
const RedirectState = struct {
    allocator: std.mem.Allocator,
    /// Current target: `Request.url` until the first hop, then `owned_url`.
    url: []const u8,
    /// Heap copy of the last resolved target. Freed on the next hop or by `deinit`.
    owned_url: ?[]u8 = null,
    /// Credentials for the current target. Cleared for good once a hop leaves
    /// the origin (scheme, host, port), so the API key is never sent to
    /// another server.
    credentials: ?config.Credentials,
    /// Number of redirects followed so far.
    hops: u8 = 0,

    /// Start at `req.url` with `req.credentials`.
    fn init(req: Request) RedirectState {
        return .{ .allocator = req.allocator, .url = req.url, .credentials = req.credentials };
    }

    /// Free the resolved target URL, if any.
    fn deinit(self: *RedirectState) void {
        if (self.owned_url) |u| self.allocator.free(u);
    }

    /// Resolve `location` against the current target and make it the new target.
    ///
    /// `location` usually points into the connection buffer of the current
    /// request; it is copied here, so the caller can release the request after.
    fn follow(self: *RedirectState, location: ?[]const u8) !void {
        if (self.hops >= max_redirects) return error.TooManyHttpRedirects;
        const loc = location orelse return error.HttpRedirectLocationMissing;
        const base = std.Uri.parse(self.url) catch return error.HttpRedirectLocationInvalid;

        // resolveInPlace expects the location at the start of the buffer and
        // may write a merged path (base path + location) after it.
        const aux = try self.allocator.alloc(u8, 2 * loc.len + self.url.len);
        defer self.allocator.free(aux);
        @memcpy(aux[0..loc.len], loc);
        var aux_free: []u8 = aux;
        const target = std.Uri.resolveInPlace(base, loc.len, &aux_free) catch
            return error.HttpRedirectLocationInvalid;

        // `target` borrows from `aux` and `self.url`: serialise it before
        // either is released. The fragment is dropped (never sent on the wire).
        const new_url = try std.fmt.allocPrint(self.allocator, "{f}", .{target.fmt(.{
            .scheme = true,
            .authority = true,
            .path = true,
            .query = true,
        })});

        if (!sameOrigin(base, target)) self.credentials = null;
        if (self.owned_url) |old| self.allocator.free(old);
        self.owned_url = new_url;
        self.url = new_url;
        self.hops += 1;
    }
};

/// Perform an HTTP request using the provided client.
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
fn execute(req: Request, client: anytype) !APIResponse {
    // connect_timeout_s is passed in from the caller (resolved from env in main).
    // TODO: wire req.connect_timeout_s into the HTTP client once std.http.Client
    // exposes per-connection timeout support.
    _ = req.connect_timeout_s;

    // A request body is only valid for methods that permit one (POST/PUT/PATCH).
    // std.http.Client asserts this precondition inside sendBodyUnflushed, so a
    // body on e.g. a GET aborts the whole process with a panic in safe builds
    // (and is silent undefined behavior in ReleaseFast). Guard here and fail cleanly instead:
    // this is a permanent condition, so it is checked once before the retry loop
    // rather than retried.
    //
    // DELIBERATE DIVERGENCE FROM THE PERL CLIENT (openqa-cli):
    //   Perl silently sends the body on a bodiless method (e.g. a GET) and exits
    //   0. The server simply ignores it.
    //   zoqa instead rejects the request up front with error.BodyOnBodilessMethod (non-zero exit).
    //   Parity is broken on purpose: an explicit error is better than a body
    //   that the server ignores, and Zig's std client cannot send a body on a
    //   GET without failing the assertion.
    //   The most common trigger is `--data-file FILE` / `--data` on a GET route without
    //   an explicit `-X POST`. See the ROB-8 E2E test in tests/e2e/tests_robustness.sh.
    if (req.body != null and !req.method.requestHasBody()) {
        if (!req.quiet)
            std.debug.print(
                "Error: a request body was provided for {s}, which does not allow a body (use -X POST/PUT/PATCH)\n",
                .{@tagName(req.method)},
            );
        return error.BodyOnBodilessMethod;
    }

    var redirect = RedirectState.init(req);
    defer redirect.deinit();
    // A 303 (or a 301/302 answering a POST) turns the next hop into a bodiless GET.
    var method = req.method;
    var body = req.body;

    var attempt: u32 = 0;
    // Redirect hops are not retries: they must not consume the retry budget.
    var followed_redirect = false;
    while (true) : (attempt += @intFromBool(!followed_redirect)) {
        followed_redirect = false;

        // Build request headers fresh on each attempt and each redirect hop so
        // the HMAC covers the current path and timestamp. hash_buf and
        // timestamp_buf are declared here so they outlive the headers list
        // (auth headers borrow from them).
        const uri = try std.Uri.parse(redirect.url);
        var hash_buf: [40]u8 = undefined;
        var timestamp_buf: [32]u8 = undefined;
        var headers = try buildHeaders(req.allocator, req.headers, redirect.credentials, uri, &hash_buf, &timestamp_buf, true);
        defer headers.deinit(req.allocator);

        if (req.verbose) {
            std.debug.print("> {s} {s}\n", .{ @tagName(method), uri.path.percent_encoded });
            for (headers.items) |h| {
                std.debug.print("> {s}: {s}\n", .{ h.name, h.value });
            }
            std.debug.print(">\n", .{});
        }

        // Issue the request via the injected client. Redirects are handled
        // below (see `RedirectState`), never by the client.
        var http_req = client.request(method, uri, .{
            .extra_headers = headers.items,
            .redirect_behavior = .unhandled,
        }) catch |err| {
            if (!req.quiet) std.debug.print("Connection error: {s}\n", .{@errorName(err)});
            if (attempt >= req.retries) return err;
            try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, null);
            continue;
        };
        defer http_req.deinit();

        // Send request (with or without body)
        if (body) |body_bytes| {
            const body_mut = try req.allocator.dupe(u8, body_bytes);
            defer req.allocator.free(body_mut);
            http_req.sendBodyComplete(body_mut) catch |err| {
                if (!req.quiet) std.debug.print("sendBodyComplete with alloc error: {s}\n", .{@errorName(err)});
                if (attempt >= req.retries) return err;
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, null);
                continue;
            };
        } else if (method.requestHasBody()) {
            http_req.sendBodyComplete(&.{}) catch |err| {
                if (!req.quiet) std.debug.print("sendBodyComplete error: {s}\n", .{@errorName(err)});
                if (attempt >= req.retries) return err;
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, null);
                continue;
            };
        } else {
            http_req.sendBodiless() catch |err| {
                if (!req.quiet) std.debug.print("sendBodiless error: {s}\n", .{@errorName(err)});
                if (attempt >= req.retries) return err;
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, null);
                continue;
            };
        }

        // Receive response headers. With `.unhandled` redirects the client
        // needs no redirect buffer.
        var response = http_req.receiveHead(&.{}) catch |err| {
            if (!req.quiet) std.debug.print("Response error: {s}\n", .{@errorName(err)});
            if (attempt >= req.retries) return err;
            try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, null);
            continue;
        };

        const status = response.head.status;
        if (isFollowableRedirect(status)) {
            if (req.verbose) std.debug.print("< {d} Location: {s}\n", .{ @intFromEnum(status), response.head.location orelse "-" });
            try redirect.follow(response.head.location);
            // Same rule as std.http.Client (RFC 9110 §15.4).
            if (status == .see_other or (method == .POST and (status == .moved_permanently or status == .found))) {
                method = .GET;
                body = null;
            }
            followed_redirect = true;
            continue;
        }

        // Retry on transient statuses (408, 429, 500, 502, 503, 504).
        if (isRetryableStatus(response.head.status)) {
            if (attempt < req.retries) {
                const override = retryAfterSeconds(response.head);
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, override);
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
            // behavior of Mojolicious's Mojo::Headers, which strips them
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

/// Performs an HTTP request and streams the response body directly into `writer`.
///
/// Designed for large downloads (such as archive artifacts and clone-job assets)
/// where buffering the full payload in memory would be prohibitive.
///
/// ## The Sink Pollution Contract (Non-2xx Responses)
///
/// Streaming into `writer` is **unconditional** once pre-stream gates pass.
/// If the server returns a non-2xx status code that is not retried (such as
/// a 404, or an exhausted 500/502/503), `executeStream` **still streams the
/// response body into `writer`**. In these cases, the sink will contain an
/// error payload (such as an HTML/JSON error document) rather than the
/// expected asset.
///
/// The caller owns the sink and **must inspect `result.status`**:
/// - If `result.status` indicates failure, the caller is responsible for
///   truncating, unlinking, or discarding the polluted sink.
/// - Higher-level helpers like `openQADownloadToFile` handle this by
///   deleting the destination file on terminal non-2xx outcomes.
///
/// ## Retry Architecture & Pre-Stream Gates
///
/// Retries and validations are strictly partitioned by **sink ownership**:
///
/// 1. **Pre-stream retries (internal):**
///    Failures occurring before any bytes reach `writer` are retried up to
///    `req.retries`. These include:
///    - Connection and send errors (`client.request`, `sendBodiless`).
///    - Header receive/parse errors (`receiveHead`).
///    - Retryable HTTP statuses: 408, 429, 500, 502, 503, 504.
///    If the retry budget is exhausted on a retryable status, the request falls
///    through and its error body is streamed directly into `writer`.
///
/// 2. **Pre-stream validation gates:**
///    Before body transfer begins, the response must pass several checks:
///    - Redirects (301, 302, 303, 307, 308) are followed up to `max_redirects`
///      and re-signed per hop.
///    - If `req.reject_html` is set, HTML responses on 200 OK are rejected with
///      `error.UnexpectedHtmlResponse`.
///    - If `req.size_limit` is set and `Content-Length` exceeds it,
///      `error.FileTooLarge` is returned before writing to `writer`.
///    - `error.LengthRequired` is enforced on `.ok` and `.partial_content` when
///      neither `Content-Length` nor `req.expected_size` is present (unless
///      `req.allow_lengthless` is true).
///
/// 3. **Mid-stream failures & integrity check (caller responsibility):**
///    Once `streamRemaining` begins writing to `writer`, no retries are attempted.
///    Because a generic `*std.Io.Writer` cannot be rewound or truncated, retrying
///    mid-stream would corrupt output by appending duplicate chunks. Mid-stream
///    read/write errors are returned immediately.
///    After streaming finishes, if fewer bytes were transferred than advertised by
///    `Content-Length` (or `req.expected_size` on 200/206), `error.HttpTransferTruncated`
///    is returned.
///
/// 4. **Interaction with `openQADownloadToFile`:**
///    `openQADownloadToFile` owns its sink (a local file). It acts as the outer
///    retry authority, safely re-creating/truncating the file between attempts
///    and unlinking on terminal failure. It invokes `executeStream` with
///    `retries = 0` to prevent redundant nested retries.
///
/// Parameters:
///   - req: Request configuration (headers, retry budget, size limits).
///   - client: HTTP client compatible with `std.http.Client.request`.
///   - writer: Output sink receiving the streamed body (asset payload or error page).
///   - content_length_out: Optional out-parameter populated with the advertised
///     `Content-Length` (or `null` if absent) before streaming begins.
///
/// Returns:
///   A `StreamResult` containing `status`, `content_length`, and optional `retry_after_s`.
///   The caller **must** inspect `result.status` to determine whether the written bytes
///   represent valid data or an error document.
///
/// Errors:
///   - Transport errors surviving all retry attempts prior to streaming.
///   - Redirect errors: `error.TooManyHttpRedirects`, `error.HttpRedirectLocationMissing`,
///     or `error.HttpRedirectLocationInvalid`.
///   - `error.UnexpectedHtmlResponse` if `req.reject_html` rejects an HTML response on 200.
///   - `error.FileTooLarge` if advertised `Content-Length` exceeds `req.size_limit`.
///   - `error.LengthRequired` if required length headers are absent on 200/206.
///   - `error.HttpTransferTruncated` if fewer bytes were read than expected.
///   - Any read error from the response stream or write error from `writer`.
fn executeStream(
    req: Request,
    client: anytype,
    writer: *std.Io.Writer,
    content_length_out: ?*?u64,
) !StreamResult {
    _ = req.connect_timeout_s;

    var redirect = RedirectState.init(req);
    defer redirect.deinit();

    var attempt: u32 = 0;
    // Redirect hops are not retries: they must not consume the retry budget.
    var followed_redirect = false;
    while (true) : (attempt += @intFromBool(!followed_redirect)) {
        followed_redirect = false;

        // Rebuild headers on each attempt and each redirect hop so the HMAC
        // covers the current path and timestamp. hash_buf and timestamp_buf
        // must outlive the headers list (the auth headers borrow from them).
        const uri = try std.Uri.parse(redirect.url);
        var hash_buf: [40]u8 = undefined;
        var timestamp_buf: [32]u8 = undefined;
        var headers = try buildHeaders(req.allocator, req.headers, redirect.credentials, uri, &hash_buf, &timestamp_buf, false);
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
            .redirect_behavior = .unhandled,
        }) catch |err| {
            if (attempt < req.retries) {
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, null);
                continue;
            }
            if (!req.quiet) std.debug.print("Connection error: {s}\n", .{@errorName(err)});
            return err;
        };
        defer http_req.deinit();

        http_req.sendBodiless() catch |err| {
            if (attempt < req.retries) {
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, null);
                continue;
            }
            if (!req.quiet) std.debug.print("Send error: {s}\n", .{@errorName(err)});
            return err;
        };

        var response = http_req.receiveHead(&.{}) catch |err| {
            if (attempt < req.retries) {
                try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, null);
                continue;
            }
            if (!req.quiet) std.debug.print("Response error: {s}\n", .{@errorName(err)});
            return err;
        };

        // Follow redirects before anything reaches `writer`; the redirect
        // body is discarded by `http_req.deinit()`.
        if (isFollowableRedirect(response.head.status)) {
            if (req.verbose) std.debug.print("< {d} Location: {s}\n", .{ @intFromEnum(response.head.status), response.head.location orelse "-" });
            try redirect.follow(response.head.location);
            followed_redirect = true;
            continue;
        }

        // Retry transient statuses (408, 429, 500, 502, 503, 504). This
        // happens before the body is streamed, so `writer` is still
        // untouched: it is safe to retry.
        if (isRetryableStatus(response.head.status) and attempt < req.retries) {
            const override = retryAfterSeconds(response.head);
            try sleepForRetry(attempt, req.retry_sleep_s, req.retry_factor, override);
            continue;
        }

        if (req.reject_html and response.head.status == .ok) {
            if (@hasField(@TypeOf(response.head), "content_type")) {
                if (response.head.content_type) |ct| {
                    if (std.ascii.startsWithIgnoreCase(ct, "text/html")) {
                        return error.UnexpectedHtmlResponse;
                    }
                }
            }
        }

        const content_length = response.head.content_length;
        if (content_length_out) |out| out.* = content_length;

        if (req.size_limit) |limit| {
            if (content_length) |cl| {
                if (cl > limit) return error.FileTooLarge;
            }
        }

        if (response.head.status == .ok or response.head.status == .partial_content) {
            if (content_length == null and req.expected_size == null and !req.allow_lengthless) {
                return error.LengthRequired;
            }
        }

        // Past this point bytes may reach `writer`; a mid-stream failure is
        // returned rather than retried (see the doc comment above).
        var transfer_buf: [65536]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        const bytes_written = try body_reader.streamRemaining(writer);

        if (content_length) |cl| {
            if (bytes_written < cl) {
                return error.HttpTransferTruncated;
            }
        } else if (response.head.status == .ok or response.head.status == .partial_content) {
            // expected_size validation only applies when the response status indicates
            // a successful asset download. On non-2xx status codes (e.g. 404 Not Found),
            // the response body is an error page rather than the asset payload; comparing
            // the error page length against expected_size would misclassify the 404 as a
            // truncated asset download instead of returning the status to the caller.
            if (req.expected_size) |es| {
                if (bytes_written < es) {
                    return error.HttpTransferTruncated;
                }
            }
        }

        return StreamResult{
            .status = response.head.status,
            .content_length = content_length,
            .retry_after_s = if (isRetryableStatus(response.head.status)) retryAfterSeconds(response.head) else null,
        };
    }
}

/// Extract and parse `Retry-After` header from response head (if present and integer).
pub fn retryAfterSeconds(head: anytype) ?u64 {
    var hit = head.iterateHeaders();
    while (hit.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "Retry-After")) {
            return parseRetryAfter(hdr.value);
        }
    }
    return null;
}

/// Returns true when the API or asset-download response status is transient and worth retrying.
/// Covers request timeout (408), rate limiting (429), and server/gateway
/// errors (500, 502, 503, 504).
pub fn isRetryableStatus(status: std.http.Status) bool {
    return switch (status) {
        .request_timeout, .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => true,
        else => false,
    };
}

/// Parse a `Retry-After` header value in seconds into an integer delay.
/// Accepts whole non-negative integers (delay-seconds, RFC 9110 §10.2.3).
/// Non-integer values (including HTTP-dates) return `null` (caller falls back
/// to computed backoff).
pub fn parseRetryAfter(value: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    for (trimmed) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

/// Maximum allowed delay in seconds for a server-supplied `Retry-After` header.
pub const RETRY_AFTER_CAP_S: u64 = 60;

/// Compute retry delay in nanoseconds.
/// If `override_s` is provided (e.g. from `Retry-After`), it is capped at `RETRY_AFTER_CAP_S` (60 s).
/// Otherwise, computes exponential backoff `sleep_s * factor^attempt` in ns, saturating at `maxInt(u64)`.
pub fn retryDelayNs(attempt: u32, sleep_s: f64, factor: f64, override_s: ?u64) u64 {
    if (override_s) |ov| {
        const clamped: u64 = @min(ov, RETRY_AFTER_CAP_S);
        return clamped * std.time.ns_per_s;
    }
    if (sleep_s <= 0) return 0;
    const delay_s = sleep_s * std.math.pow(f64, factor, @floatFromInt(attempt));
    if (std.math.isNan(delay_s) or delay_s <= 0) return 0;
    if (std.math.isInf(delay_s)) return std.math.maxInt(u64);
    const ns_f = delay_s * @as(f64, @floatFromInt(std.time.ns_per_s));
    const max_u64_f: f64 = @floatFromInt(std.math.maxInt(u64));
    if (ns_f >= max_u64_f) return std.math.maxInt(u64);
    return @intFromFloat(ns_f);
}

fn sleepForRetry(attempt: u32, sleep_s: f64, factor: f64, override_s: ?u64) !void {
    std.Thread.sleep(retryDelayNs(attempt, sleep_s, factor, override_s));
}

/// Returns true if the path ends with `.htm` or `.html` (case-insensitive).
pub fn hasHtmlExtension(path: []const u8) bool {
    if (path.len >= 5 and std.ascii.eqlIgnoreCase(path[path.len - 5 ..], ".html")) return true;
    if (path.len >= 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".htm")) return true;
    return false;
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
            location: ?[]const u8 = null,
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
/// This struct bundles every tunable aspect of a request into a single value that
/// is passed to `openQAReq`: HTTP method, parameters, body, authentication credentials, retry policy, and diagnostics.
/// All fields except `allocator` have sensible defaults, so callers only
/// need to set the fields that differ from a simple unauthenticated GET.
///
/// **Ownership:** `CallOptions` does **not** own any of the slices or
/// pointers it holds (`headers`, `params`, `body`, `credentials`). The
/// caller must ensure these remain valid for the duration of the
/// `openQAReq` call. There is no `deinit`; nothing needs to be freed.
pub const CallOptions = struct {
    /// General-purpose allocator used by `openQAReq` for all internal
    /// allocations. Must remain valid until `APIResponse.deinit()` is called.
    allocator: std.mem.Allocator,

    /// HTTP method for the request. Defaults to `.GET`.
    /// Also controls how `params` is routed (query for GET/DELETE, body for
    /// POST/PUT/PATCH unless an explicit `body` is set).
    method: std.http.Method = .GET,

    /// Extra request headers. **Not owned**; the caller keeps the memory alive.
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

/// Configuration for download progress reporting.
///
/// Fields:
///   - label: Display label (e.g. filename) for the resource being transferred.
///   - out: Destination writer for progress lines (typically stderr).
pub const Progress = struct {
    label: []const u8,
    out: *std.Io.Writer,
};

/// Pure accounting engine for download progress: tracks byte counters and
/// decides when a progress event should fire. Completely decoupled from
/// terminal I/O and string formatting; unit-testable with simulated clocks.
const ProgressMeter = struct {
    /// Payload handed to the renderer when a progress event fires.
    pub const RenderPayload = struct {
        done: u64,
        total: ?u64,
        pct: ?u8,
    };

    fallback_total: ?u64,
    content_length: ?u64 = null,
    bytes_written: u64 = 0,
    last_render_ms: i64 = std.math.minInt(i64),
    last_pct: ?u8 = null,

    /// Create a meter with an optional fallback total (e.g. the expected
    /// asset size from the metadata API, used when Content-Length is absent).
    pub fn init(fallback_total: ?u64) ProgressMeter {
        return .{ .fallback_total = fallback_total };
    }

    /// Reset counters and timers for a fresh retry attempt.
    pub fn reset(self: *ProgressMeter) void {
        self.bytes_written = 0;
        self.last_render_ms = std.math.minInt(i64);
        self.last_pct = null;
    }

    /// Record the Content-Length header value when it arrives.
    pub fn setTotal(self: *ProgressMeter, cl: ?u64) void {
        self.content_length = cl;
    }

    /// The effective total: Content-Length if known, else the fallback.
    pub fn effectiveTotal(self: *const ProgressMeter) ?u64 {
        return self.content_length orelse self.fallback_total;
    }

    /// Overflow-safe integer percentage of `done` out of `total`.
    pub fn computePct(done: u64, total: u64) u8 {
        if (total == 0) return 100;
        if (done >= total) return 100;
        if (done < std.math.maxInt(u64) / 100) {
            return @intCast((done * 100) / total);
        }
        return @intCast(done / (total / 100));
    }

    /// Record `n` newly written bytes and return a render payload when the
    /// dual-throttling gates are satisfied:
    ///   - known total: integer percentage changed AND >= 50 ms elapsed
    ///   - unknown total: >= 250 ms elapsed
    /// The returned payload is rendered by the caller (the tap), which then
    /// calls `markRendered` so the throttle timer reflects the actual render.
    ///
    /// The time gate applies from the first render onward: `last_render_ms == 0`
    /// (initial state) means the first render fires immediately; once a render
    /// has occurred, the elapsed-time threshold must be met.
    pub fn update(self: *ProgressMeter, n: u64, now_ms: i64) ?RenderPayload {
        self.bytes_written += n;
        const total = self.effectiveTotal();
        if (total) |t| {
            if (t == 0) return null;
            const pct = computePct(self.bytes_written, t);
            // Time gate: >= 50 ms since last render (first render always passes).
            if (self.last_render_ms != std.math.minInt(i64) and now_ms - self.last_render_ms < 50) return null;
            // Pct-change gate: skip if the integer percentage is unchanged
            // since the last render (avoids redundant redraws at the same pct).
            if (self.last_pct != null and pct == self.last_pct.?) return null;
            return .{ .done = self.bytes_written, .total = t, .pct = pct };
        }
        if (self.last_render_ms != std.math.minInt(i64) and now_ms - self.last_render_ms < 250) return null;
        return .{ .done = self.bytes_written, .total = null, .pct = null };
    }

    /// Record that a progress event was rendered at `now_ms`.
    pub fn markRendered(self: *ProgressMeter, now_ms: i64, pct: ?u8) void {
        self.last_render_ms = now_ms;
        self.last_pct = pct;
    }

    /// Forced final 100% payload, returned regardless of the throttle gates.
    pub fn finalRender(self: *ProgressMeter) RenderPayload {
        const total = self.effectiveTotal();
        const pct: ?u8 = if (total) |t| computePct(self.bytes_written, t) else null;
        self.last_render_ms = std.math.minInt(i64);
        self.last_pct = pct;
        return .{ .done = self.bytes_written, .total = total, .pct = pct };
    }
};

/// Terminal UI renderer for the download progress meter. Owns line
/// formatting, ghost-character erasure via space padding, and the
/// transfer-boundary newlines. Zero ANSI escapes: pure ASCII on stderr,
/// so redirected stderr and CI logs stay clean.
const ProgressTerminalRenderer = struct {
    label: []const u8,
    out: *std.Io.Writer,
    last_line_len: usize = 0,
    has_rendered: bool = false,

    /// Create a renderer for the transfer labelled `label`, writing to `out`.
    pub fn init(label: []const u8, out: *std.Io.Writer) ProgressTerminalRenderer {
        return .{ .label = label, .out = out };
    }

    /// Format `bytes` as a binary-unit string (B, KiB, MiB, GiB, TiB) with
    /// one decimal place into `buf`.
    pub fn formatHumanSize(buf: []u8, bytes: u64) []const u8 {
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
        var value: f64 = @floatFromInt(bytes);
        var unit: usize = 0;
        while (unit + 1 < units.len and value >= 1024) {
            value /= 1024;
            unit += 1;
        }
        if (unit == 0) {
            return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[unit] }) catch return "B";
        }
        return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch return "B";
    }

    /// Render one progress line: `\rDownloading {label}: {pct}% ({done} / {total})`
    /// or `\rDownloading {label}: {done}` when the total is unknown. Shorter
    /// lines are space-padded to the previous line length so ghost characters
    /// are erased without ANSI codes.
    pub fn renderProgress(self: *ProgressTerminalRenderer, done: u64, total: ?u64, pct: ?u8) std.Io.Writer.Error!void {
        var line_buf: [128]u8 = undefined;
        var line: []const u8 = undefined;
        if (total) |t| {
            const p: u8 = pct orelse ProgressMeter.computePct(done, t);
            var done_buf: [16]u8 = undefined;
            var total_buf: [16]u8 = undefined;
            const done_s = formatHumanSize(&done_buf, done);
            const total_s = formatHumanSize(&total_buf, t);
            line = std.fmt.bufPrint(&line_buf, "\rDownloading {s}: {d}% ({s} / {s})", .{
                self.label, p, done_s, total_s,
            }) catch return error.WriteFailed;
        } else {
            var done_buf: [16]u8 = undefined;
            const done_s = formatHumanSize(&done_buf, done);
            line = std.fmt.bufPrint(&line_buf, "\rDownloading {s}: {s}", .{
                self.label, done_s,
            }) catch return error.WriteFailed;
        }
        if (line.len < self.last_line_len) {
            try self.out.alignBuffer(line, self.last_line_len, .left, ' ');
        } else {
            try self.out.writeAll(line);
        }
        self.last_line_len = line.len;
        self.has_rendered = true;
        try self.out.flush();
    }

    /// Render the skip-if-complete (HTTP 416) message.
    pub fn renderSkip(self: *ProgressTerminalRenderer) std.Io.Writer.Error!void {
        try self.out.print("{s}: already complete, skipped\n", .{self.label});
        try self.out.flush();
    }

    /// Render the final 100% line and terminate it with a newline.
    pub fn finish(self: *ProgressTerminalRenderer, done: u64, total: ?u64) std.Io.Writer.Error!void {
        const pct: ?u8 = if (total) |t| ProgressMeter.computePct(done, t) else null;
        try self.renderProgress(done, total, pct);
        try self.out.writeByte('\n');
        try self.out.flush();
        self.last_line_len = 0;
    }

    /// Terminate the in-progress line with a newline after a mid-stream
    /// failure. No-op when nothing was rendered (pre-stream errors must not
    /// emit a stray newline).
    pub fn abort(self: *ProgressTerminalRenderer) std.Io.Writer.Error!void {
        if (!self.has_rendered) return;
        try self.out.writeByte('\n');
        try self.out.flush();
        self.has_rendered = false;
        self.last_line_len = 0;
    }
};

/// Byte tap: a `std.Io.Writer` that forwards every byte to an inner writer
/// unchanged while reporting the count to a `ProgressMeter` and rendering
/// progress events through a `ProgressTerminalRenderer`.
///
/// Only `drain` is overridden; the default `sendFile` returns
/// `error.Unimplemented`, which makes `File.Reader.stream` fall back to the
/// read-into-buffer path so every byte flows through `drain` and gets
/// accounted.
const ProgressStreamTap = struct {
    inner: *std.Io.Writer,
    meter: *ProgressMeter,
    renderer: *ProgressTerminalRenderer,
    w: std.Io.Writer,

    /// Wrap `inner` with progress accounting. `buffer` is the tap's own
    /// write buffer (managed by the default `rebase`/`flush`).
    pub fn init(inner: *std.Io.Writer, meter: *ProgressMeter, renderer: *ProgressTerminalRenderer, buffer: []u8) ProgressStreamTap {
        return .{
            .inner = inner,
            .meter = meter,
            .renderer = renderer,
            .w = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain },
            },
        };
    }

    /// Return the writer interface to hand to `executeStream`.
    pub fn writer(self: *ProgressStreamTap) *std.Io.Writer {
        return &self.w;
    }

    /// Forward `buffer[0..end]` + `data` (last slice splatted) to `inner`,
    /// accounting every byte. Same memmove pattern as `Writer.Hashed.drain`.
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ProgressStreamTap = @alignCast(@fieldParentPtr("w", w));
        const aux = w.buffered();
        const aux_n = try self.inner.writeSplatHeader(aux, data, splat);
        if (aux_n < w.end) {
            self.account(aux_n);
            const remaining = w.buffer[aux_n..w.end];
            @memmove(w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
            return 0;
        }
        self.account(aux.len);
        const n = aux_n - w.end;
        w.end = 0;
        var remaining: usize = n;
        for (data[0 .. data.len - 1]) |slice| {
            if (remaining <= slice.len) {
                self.account(remaining);
                return n;
            }
            remaining -= slice.len;
            self.account(slice.len);
        }
        if (remaining > 0) {
            self.account(remaining);
        }
        return n;
    }

    /// Account `n` bytes and render a progress event when the meter's
    /// throttle gates are satisfied.
    fn account(self: *ProgressStreamTap, n: u64) void {
        const now_ms = std.time.milliTimestamp();
        if (self.meter.update(n, now_ms)) |payload| {
            self.renderer.renderProgress(payload.done, payload.total, payload.pct) catch {};
            self.meter.markRendered(now_ms, payload.pct);
        }
    }
};

/// Options for `openQARawGet`.
pub const RawGetOptions = struct {
    allocator: std.mem.Allocator,
    credentials: ?config.Credentials = null,
    size_limit: ?u64 = null,
    quiet: bool = false,
    verbose: bool = false,
    /// Optional expected byte size of the response payload.
    expected_size: ?u64 = null,
    /// When `true`, permits streaming responses without a `Content-Length` header or `expected_size`.
    allow_lengthless: bool = false,

    /// When non-null, `openQADownloadToFile` renders a progress meter for the
    /// body transfer into `progress.out`. Not owned.
    progress: ?Progress = null,

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
/// Streams the response body into `writer`. Before streaming starts, writes
/// the Content-Length header value into `content_length_out` (if non-null),
/// allowing callers to set up progress tracking. Retries transient pre-stream
/// failures up to `opts.retries` times; a mid-stream failure is not retried
/// (see `executeStream`).
///
/// Parameters:
///   - host: bare hostname or full base URL of the openQA instance.
///   - absolute_path: request path; must start with "/".
///   - opts: credentials, retry policy, size limit and verbosity (see
///     `RawGetOptions`).
///   - client: an HTTP client compatible with `std.http.Client.request`.
///   - writer: sink the response body is streamed into.
///   - content_length_out: optional out-param receiving the Content-Length
///     header value before streaming begins.
///
/// Returns: a `StreamResult` with the HTTP status and content length.
///
/// Errors: host-resolution/allocation failures and any error propagated by
/// `executeStream` (transport failure, `error.FileTooLarge`, writer errors).
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
        .allow_lengthless = true,
    };

    return executeStream(req, client, writer, content_length_out);
}

/// Probe whether an on-disk file is already the full asset.
///
/// Return `true` when the source already considers a `size`-byte local file to
/// be a complete copy, mirroring Perl's `curl --continue-at -`
/// (`mirror()`, CloneJob.pm:203). Issues a ranged GET (`Range: bytes={size}-`);
/// openQA serves factory assets via a Range-capable static route
/// (`Accept-Ranges: bytes`) and answers **416 Range Not Satisfiable** when
/// nothing remains to transfer (i.e. the file is already complete).
/// Any other status (200 full body, 206 partial, …) means the body must be (re)downloaded.
///
/// The probe body is streamed into a discarding sink, so the destination file is
/// never touched here. Returns an error only on a transport failure, letting the
/// caller fall back to a full download.
///
/// The probe is a ranged GET, not a HEAD, so it goes through the same
/// `executeStream` path as the real download: openQA 302-redirects
/// `/tests/{id}/asset/...` → `/assets/...`, and the redirect is followed and
/// re-signed exactly as for the download (see `RedirectState`).
fn isRemoteComplete(url: []const u8, size: u64, opts: RawGetOptions, client: anytype) !bool {
    var range_buf: [64]u8 = undefined;
    const range_val = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{size});
    const range_headers = [_]std.http.Header{.{ .name = "Range", .value = range_val }};
    const req = Request{
        .allocator = opts.allocator,
        .method = .GET,
        .url = url,
        .headers = &range_headers,
        .body = null,
        .credentials = opts.credentials,
        .retries = 0,
        .quiet = opts.quiet,
        .verbose = opts.verbose,
        .size_limit = null,
    };
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    const result = try executeStream(req, client, &discarding.writer, null);
    return result.status == .range_not_satisfiable;
}

/// Stream an authenticated GET to a local file, with retry.
///
/// Downloads `absolute_path` from `host` into `dest_path`, streaming
/// directly to disk. Three guarantees:
///   1. No partial file survives any failure (destination is deleted).
///   2. A complete local copy is skipped (ranged-GET probe, mtime touched).
///   3. Transient failures (connection, 5xx, mid-stream reset) are retried
///      with backoff; non-5xx statuses are terminal.
///
/// Retry architecture: see `executeStream`. This function is the file-owning
/// variant that adds mid-stream retry by re-creating the file between
/// attempts. It calls `executeStream` with `retries = 0` to avoid
/// double-retrying.
///
/// Parameters:
///   - host: bare hostname or full base URL of the source openQA instance.
///   - absolute_path: request path of the asset; must start with "/".
///   - dest_path: local filesystem path to stream the body into.
///   - opts: credentials, retry policy, size limit and verbosity (see
///     `RawGetOptions`).
///   - client: an HTTP client compatible with `std.http.Client.request`.
///
/// Returns: a `StreamResult` with the final HTTP status and content length. On a
/// skip-if-complete hit the status is `.ok` and no body is transferred.
///
/// Errors: host-resolution/allocation failures, filesystem errors creating or
/// touching the destination, and transport errors surviving all retries. On any
/// error no partial destination file is left behind.
///
/// Parameters:
///   - backend: a file backend providing `stat`, `create`, and `delete`
///     methods (see `fs_utils.RealFileBackend`). `create` returns a
///     `FileSink` (see `fs_utils.RealFileSink`) that the state machine
///     uses for the data path. Production code passes
///     `fs_utils.RealFileBackend`; unit tests pass a mock.
pub fn openQADownloadToFile(
    host: []const u8,
    absolute_path: []const u8, // must start with "/"
    dest_path: []const u8,
    opts: RawGetOptions,
    client: anytype,
    backend: anytype,
) !StreamResult {
    const host_res = try config.resolveHost(opts.allocator, false, false, false, host);
    defer if (host_res.allocated) opts.allocator.free(host_res.url);

    const url = try std.fmt.allocPrint(opts.allocator, "{s}{s}", .{ host_res.url, absolute_path });
    defer opts.allocator.free(url);

    // Skip-if-complete (mirrors Perl's `curl --continue-at -`). If the
    // destination file already exists and the source reports it as complete
    // (a ranged GET at the on-disk size returns 416), skip the body transfer entirely and
    // only refresh the mtime.
    // This avoids re-fetching large already-present assets (multi-GB HDD images)
    // on every re-clone. The check is gated on the file existing with size > 0,
    // so fresh downloads (empty destination) take the normal streaming path below.
    if (backend.stat(dest_path)) |maybe_size| {
        if (maybe_size) |size| {
            if (size > 0) {
                if (isRemoteComplete(url, size, opts, client)) |complete| {
                    if (complete) {
                        // Already complete on disk: skip the body transfer and touch
                        // mtime to delay openQA's asset-cleanup cron.
                        try backend.touch(dest_path);
                        if (opts.progress) |prog| {
                            var r = ProgressTerminalRenderer.init(prog.label, prog.out);
                            try r.renderSkip();
                        }
                        return StreamResult{ .status = .ok, .content_length = size };
                    }
                } else |_| {
                    // Probe failed (transport error): fall through to a full
                    // download, which is authoritative on its own.
                }
            }
        }
    } else |_| {
        // Destination missing or unstattable: take the normal download path.
    }

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
        .expected_size = opts.expected_size,
        .allow_lengthless = opts.allow_lengthless,
        .reject_html = !hasHtmlExtension(dest_path),
    };

    const Outcome = union(enum) {
        done: StreamResult, // success: keep the file
        terminal: StreamResult, // non-retryable status: delete + return status
        retry: ?u64, // retryable failure: delete + backoff (or Retry-After) + try again
        failed: anyerror, // retry-exhausted error: delete + return error
    };

    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const outcome: Outcome = blk: {
            var sink = backend.create(dest_path) catch |err| break :blk .{ .failed = err };
            defer sink.close();

            var file_buf: [65536]u8 = undefined;
            const w = sink.writer(&file_buf);

            var cl: ?u64 = null;
            const outcome_inner: Outcome = if (opts.progress) |prog| with_progress: {
                var meter = ProgressMeter.init(opts.expected_size);
                var renderer = ProgressTerminalRenderer.init(prog.label, prog.out);
                var tap_buf: [65536]u8 = undefined;
                var tap = ProgressStreamTap.init(w, &meter, &renderer, &tap_buf);

                const res = executeStream(req, client, &tap.w, &cl) catch |err| {
                    renderer.abort() catch {};
                    // LengthRequired is a policy violation (strict mode rejects
                    // responses without Content-Length or expected_size). Retrying
                    // would defeat the policy when the fault is transient.
                    // Redirect errors are permanent: the same chain comes back.
                    if (err == error.LengthRequired or err == error.UnexpectedHtmlResponse or isRedirectError(err)) break :blk .{ .failed = err };
                    // Local disk write failure (NoSpaceLeft, DiskQuota, ...): the
                    // real file writer stashes the specific error; the sink exposes
                    // it via writeError(). Retrying would re-download the whole
                    // asset against a filesystem that cannot store it.
                    if (sink.writeError()) |disk_err| break :blk .{ .failed = disk_err };
                    if (err == error.NoSpaceLeft or err == error.DiskQuota or err == error.ReadOnlyFilesystem or err == error.WriteFailed) {
                        break :blk .{ .failed = err };
                    }
                    // Connection error or mid-stream reset, retry if budget remains.
                    break :blk if (attempt < opts.retries) .{ .retry = null } else .{ .failed = err };
                };

                if (res.status == .ok) {
                    meter.setTotal(cl);
                    tap.w.flush() catch |err| {
                        renderer.abort() catch {};
                        break :blk .{ .failed = err };
                    };
                    w.flush() catch |err| {
                        renderer.abort() catch {};
                        break :blk .{ .failed = err };
                    };
                    // Update file timestamps to current system time to delay openQA's asset-cleanup cron.
                    const now_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
                    sink.updateTimes(now_ns, now_ns) catch |err| {
                        renderer.abort() catch {};
                        break :blk .{ .failed = err };
                    };
                    const payload = meter.finalRender();
                    renderer.finish(payload.done, payload.total) catch {};
                    break :with_progress .{ .done = res };
                }

                renderer.abort() catch {};
                // Non-2xx: the body just written is an error page, not the asset.
                if (isRetryableStatus(res.status) and attempt < opts.retries) {
                    break :with_progress .{ .retry = res.retry_after_s };
                }
                break :with_progress .{ .terminal = res };
            } else no_progress: {
                const res = executeStream(req, client, w, &cl) catch |err| {
                    // LengthRequired is a policy violation (strict mode rejects
                    // responses without Content-Length or expected_size). Retrying
                    // would defeat the policy when the fault is transient.
                    // Redirect errors are permanent: the same chain comes back.
                    if (err == error.LengthRequired or err == error.UnexpectedHtmlResponse or isRedirectError(err)) break :blk .{ .failed = err };
                    // Local disk write failure (NoSpaceLeft, DiskQuota, ...): the
                    // real file writer stashes the specific error; the sink exposes
                    // it via writeError(). Retrying would re-download the whole
                    // asset against a filesystem that cannot store it.
                    if (sink.writeError()) |disk_err| break :blk .{ .failed = disk_err };
                    if (err == error.NoSpaceLeft or err == error.DiskQuota or err == error.ReadOnlyFilesystem or err == error.WriteFailed) {
                        break :blk .{ .failed = err };
                    }
                    // Connection error or mid-stream reset, retry if budget remains.
                    break :blk if (attempt < opts.retries) .{ .retry = null } else .{ .failed = err };
                };

                if (res.status == .ok) {
                    // Flush before the deferred close so the file is complete on disk.
                    w.flush() catch |err| break :blk .{ .failed = err };
                    // Update file timestamps to current system time to delay openQA's asset-cleanup cron.
                    const now_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
                    sink.updateTimes(now_ns, now_ns) catch |err| break :blk .{ .failed = err };
                    break :no_progress .{ .done = res };
                }

                // Non-2xx: the body just written is an error page, not the asset.
                if (isRetryableStatus(res.status) and attempt < opts.retries) {
                    break :no_progress .{ .retry = res.retry_after_s };
                }
                break :no_progress .{ .terminal = res };
            };
            break :blk outcome_inner;
        };

        // The file is now closed (deferred inside the block). Act on the outcome.
        switch (outcome) {
            .done => |result| return result,
            .terminal => |result| {
                backend.delete(dest_path);
                return result;
            },
            .failed => |err| {
                backend.delete(dest_path);
                return err;
            },
            .retry => |ra| {
                backend.delete(dest_path);
                try sleepForRetry(attempt, opts.retry_sleep_s, opts.retry_factor, ra);
            },
        }
    }
}

/// Build the URL and perform an authenticated request against an openQA instance.
///
/// This is the **primary public entry point** of the library. It orchestrates:
///   1. Host resolution (bare hostname → full base URL via `config.resolveHost`).
///   2. URL construction (`host/api/v1/path`, with params routing).
///   3. HMAC-SHA1 signature generation (via resolved credentials).
///   4. HTTP execution and response decompression (via the injected `client`).
///
/// Parameter routing:
///   - GET / DELETE: `opts.params` is appended to the URL as a query string.
///   - POST / PUT / PATCH: `opts.params` is used as the request body, unless
///     `opts.body` is already set (explicit body takes precedence).
///
/// Parameters:
///   - host: bare hostname or full base URL of the openQA instance.
///   - path: API path relative to `/api/v1/` (leading "/" is tolerated).
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
/// test assertions can verify URL construction, parameter routing, and body
/// selection without making real HTTP calls.
const TestMockClient = struct {
    const Self = @This();

    const MockHead = struct {
        status: std.http.Status = .ok,
        content_type: ?[]const u8 = "application/json",
        location: ?[]const u8 = null,
        content_length: ?u64 = null,

        const HeaderIterator = struct {
            done: bool = false,
            /// Yield the single canned response header once, then null.
            fn next(self: *HeaderIterator) ?std.http.Header {
                if (self.done) return null;
                self.done = true;
                return .{ .name = "Content-Type", .value = "application/json" };
            }
        };

        /// Return an iterator over this mock head's response headers.
        fn iterateHeaders(_: *const MockHead) HeaderIterator {
            return .{};
        }
    };

    const MockReader = struct {
        done: bool = false,
        /// Stream the canned body ("{}") once, then report EOF (0 bytes).
        fn streamRemaining(self: *MockReader, w: anytype) anyerror!usize {
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
        /// Record that a bodiless request was sent.
        fn sendBodiless(self: *MockResponse) !void {
            self.parent.captured_bodiless = true;
        }
        /// Capture the request body bytes for later assertions.
        fn sendBodyComplete(self: *MockResponse, body: []u8) !void {
            const len = @min(body.len, self.parent.captured_body.len);
            @memcpy(self.parent.captured_body[0..len], body[0..len]);
            self.parent.captured_body_len = len;
        }
        /// Return the canned body reader for this response.
        fn reader(self: *MockResponse, _: []u8) *MockReader {
            return &self.mock_reader;
        }
        /// Return this response as its own head (no network round-trip).
        fn receiveHead(self: *MockResponse, _: []u8) !*MockResponse {
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

    /// Capture the method and reconstructed URL, then return a canned response.
    fn request(self: *Self, method: std.http.Method, uri: std.Uri, _: anytype) !*MockResponse {
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
    const testing = std.testing;
    // Regression test for the panic reproduced by tests_robustness.sh ROB-5:
    // `--data-file FILE` (or `--data`) attaches a body but leaves the method at
    // its GET default. std.http.Client asserts requestHasBody() in
    // sendBodyUnflushed, so a body on GET used to abort the process. execute()
    // now guards this and returns error.BodyOnBodilessMethod instead.
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
            location: ?[]const u8 = null,
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

// Fully in-memory, no-FS mock sink for openQADownloadToFile unit tests.
//
// Wraps std.Io.Writer.Allocating so the stdlib enforces the writer contract
// (drain, splat, buffered bytes). No hand-written vtable, no @fieldParentPtr.
const MockFileSink = struct {
    aw: std.Io.Writer.Allocating,
    updated: bool = false,
    write_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) MockFileSink {
        return .{ .aw = .init(allocator) };
    }

    /// Return the type-erased writer interface.
    pub fn writer(self: *MockFileSink, _: []u8) *std.Io.Writer {
        return &self.aw.writer;
    }

    /// Return the pre-set write error, if any.
    pub fn writeError(self: *MockFileSink) ?anyerror {
        return self.write_error;
    }

    /// Record that timestamps were updated.
    pub fn updateTimes(self: *MockFileSink, _: u64, _: u64) !void {
        self.updated = true;
    }

    /// No-op close (the state machine calls this after each attempt).
    pub fn close(_: *MockFileSink) void {}

    /// Free the allocating writer. Tests call this via `defer` right after
    /// `MockFileBackend.init`, so error paths do not leak.
    pub fn deinit(self: *MockFileSink) void {
        self.aw.deinit();
    }

    /// Bytes written so far.
    pub fn written(self: *MockFileSink) []const u8 {
        return self.aw.writer.buffered();
    }
};

// Fully in-memory, no-FS mock backend for openQADownloadToFile unit tests.
const MockFileBackend = struct {
    stat_size: ?u64 = null,
    sink: MockFileSink,
    touched: bool = false,
    deleted: bool = false,

    pub fn init(allocator: std.mem.Allocator) MockFileBackend {
        return .{ .sink = .init(allocator) };
    }

    pub fn stat(self: *MockFileBackend, _: []const u8) !?u64 {
        return self.stat_size;
    }

    // Truncate in place rather than re-init: re-init would leak the bytes of
    // a previous attempt and wipe a pre-set `write_error`.
    pub fn create(self: *MockFileBackend, _: []const u8) !*MockFileSink {
        self.sink.aw.clearRetainingCapacity();
        self.sink.updated = false;
        return &self.sink;
    }

    pub fn delete(self: *MockFileBackend, _: []const u8) void {
        self.deleted = true;
    }

    pub fn touch(self: *MockFileBackend, _: []const u8) !void {
        self.touched = true;
    }
};

test "openQADownloadToFile: successful download and mtime touch" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();

    const res = try openQADownloadToFile("http://localhost", "/tests/123/file.txt", "dest.txt", .{
        .allocator = allocator,
        .credentials = null,
        .quiet = true,
        .retries = 0,
        .allow_lengthless = true,
    }, &mock, &backend);

    try testing.expect(res.status == .ok);

    // Verify the sink received data (TestMockClient's MockReader returns "{}")
    try testing.expect(backend.sink.written().len > 0);
    // Verify timestamps were updated
    try testing.expect(backend.sink.updated);
}

// Shared reusable pieces for the skip-probe mocks below: a response whose
// status is chosen per request, with a no-op body reader.
const SkipProbeReader = struct {
    /// Report an empty body (the skip probe streams into a discarding sink).
    fn streamRemaining(_: *SkipProbeReader, _: anytype) anyerror!usize {
        return 0;
    }
};

const SkipProbeHead = struct {
    status: std.http.Status,
    content_length: ?u64 = null,
    content_type: ?[]const u8 = null,
    location: ?[]const u8 = null,
    const HeaderIterator = struct {
        /// The probe ignores response headers, so yield none.
        fn next(_: *HeaderIterator) ?std.http.Header {
            return null;
        }
    };
    /// Return an (empty) iterator over this mock head's response headers.
    fn iterateHeaders(_: *const SkipProbeHead) HeaderIterator {
        return .{};
    }
};

const SkipProbeResponse = struct {
    head: SkipProbeHead,
    rdr: SkipProbeReader = .{},
    pub fn deinit(_: *SkipProbeResponse) void {}
    /// Accept a bodiless request (no-op for the probe).
    fn sendBodiless(_: *SkipProbeResponse) !void {}
    /// Accept a request body (no-op; used by `execute` POST tests).
    fn sendBodyComplete(_: *SkipProbeResponse, _: []u8) !void {}
    /// Return the canned no-op body reader for this response.
    fn reader(self: *SkipProbeResponse, _: []u8) *SkipProbeReader {
        return &self.rdr;
    }
    /// Return this response as its own head (no network round-trip).
    fn receiveHead(self: *SkipProbeResponse, _: []u8) !*SkipProbeResponse {
        return self;
    }
};

/// Scripted mock for redirect tests. Call `i` is answered with `hops[i]` (the
/// last entry repeats) and what the client sent is recorded in `calls[i]`, so
/// tests can check that every hop is signed for its own path.
const RedirectTestMock = struct {
    const Self = @This();
    const max_calls = 16;

    const Hop = struct {
        status: std.http.Status,
        location: ?[]const u8 = null,
    };

    /// What the client sent on one call.
    const Call = struct {
        method: std.http.Method = .GET,
        /// `scheme://host[:port]/path[?query]` of the request.
        target_buf: [256]u8 = undefined,
        target_len: usize = 0,
        microtime_buf: [32]u8 = undefined,
        microtime_len: usize = 0,
        /// `X-API-Hash` value, or null when no auth headers were sent.
        hash: ?[40]u8 = null,
        /// True when the request disabled the client's own redirect handling.
        unhandled: bool = false,

        fn target(self: *const Call) []const u8 {
            return self.target_buf[0..self.target_len];
        }

        /// Fail unless this call carries an `X-API-Hash` signed for `path_and_query`.
        fn expectSignedFor(self: *const Call, creds: config.Credentials, path_and_query: []const u8) !void {
            const hash = self.hash orelse return error.TestExpectedAuthHeaders;
            var buf: [40]u8 = undefined;
            const expected = auth.buildAuthHeaders(creds.key, creds.secret, path_and_query, self.microtime_buf[0..self.microtime_len], &buf);
            try std.testing.expectEqualStrings(expected[2].value, &hash);
        }
    };

    hops: []const Hop,
    calls: [max_calls]Call = undefined,
    call_count: usize = 0,
    response: SkipProbeResponse = .{ .head = .{ .status = .ok } },

    /// Record the request, then answer with the next scripted hop.
    fn request(self: *Self, method: std.http.Method, uri: std.Uri, options: anytype) !*SkipProbeResponse {
        if (self.call_count >= max_calls) return error.TestUnexpectedResult;
        var c: Call = .{ .method = method, .unhandled = options.redirect_behavior == .unhandled };
        var w: std.Io.Writer = .fixed(&c.target_buf);
        w.print("{f}", .{uri.fmt(.{ .scheme = true, .authority = true, .path = true, .query = true })}) catch {};
        c.target_len = w.buffered().len;
        for (options.extra_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "X-API-Hash")) c.hash = h.value[0..40].*;
            if (std.ascii.eqlIgnoreCase(h.name, "X-API-Microtime")) {
                @memcpy(c.microtime_buf[0..h.value.len], h.value);
                c.microtime_len = h.value.len;
            }
        }
        self.calls[self.call_count] = c;
        const hop = self.hops[@min(self.call_count, self.hops.len - 1)];
        self.call_count += 1;
        self.response = .{ .head = .{ .status = hop.status, .location = hop.location } };
        return &self.response;
    }
};

/// Credentials shared by the redirect tests.
const redirect_test_creds = config.Credentials{
    .allocator = std.testing.allocator,
    .key = "FAKEKEY",
    .secret = "FAKESECRET",
};

/// Build a streaming GET for the redirect tests.
fn redirectTestRequest(url: []const u8) Request {
    return .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .url = url,
        .headers = &.{},
        .body = null,
        .credentials = redirect_test_creds,
        .retries = 0,
        .quiet = true,
        .retry_sleep_s = 0,
        .allow_lengthless = true,
    };
}

test "executeStream: 302 hop is re-signed for the redirect target" {
    const testing = std.testing;
    var mock: RedirectTestMock = .{ .hops = &.{
        .{ .status = .found, .location = "/assets/iso/x.iso" },
        .{ .status = .ok },
    } };
    var sink: std.Io.Writer.Discarding = .init(&.{});

    const res = try executeStream(redirectTestRequest("http://localhost/tests/1/asset/iso/x.iso"), &mock, &sink.writer, null);

    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqual(@as(usize, 2), mock.call_count);
    try testing.expect(mock.calls[0].unhandled and mock.calls[1].unhandled);
    try testing.expectEqualStrings("http://localhost/tests/1/asset/iso/x.iso", mock.calls[0].target());
    try mock.calls[0].expectSignedFor(redirect_test_creds, "/tests/1/asset/iso/x.iso");
    try testing.expectEqualStrings("http://localhost/assets/iso/x.iso", mock.calls[1].target());
    try mock.calls[1].expectSignedFor(redirect_test_creds, "/assets/iso/x.iso");
}

test "executeStream: cross-origin redirect drops credentials" {
    const testing = std.testing;
    const locations = [_][]const u8{
        "https://mirror.example.com/assets/iso/x.iso", // other host and scheme
        "http://localhost:8080/assets/iso/x.iso", // other port
    };
    for (locations) |loc| {
        var mock: RedirectTestMock = .{
            .hops = &.{
                .{ .status = .found, .location = loc },
                .{ .status = .found, .location = "http://localhost/assets/iso/x.iso" }, // back to the origin
                .{ .status = .ok },
            },
        };
        var sink: std.Io.Writer.Discarding = .init(&.{});

        _ = try executeStream(redirectTestRequest("http://localhost/tests/1/asset/iso/x.iso"), &mock, &sink.writer, null);

        try testing.expectEqual(@as(usize, 3), mock.call_count);
        try testing.expect(mock.calls[0].hash != null);
        try testing.expectEqualStrings(loc, mock.calls[1].target());
        try testing.expect(mock.calls[1].hash == null);
        // Once dropped, credentials stay dropped for the rest of the chain.
        try testing.expect(mock.calls[2].hash == null);
    }
}

test "executeStream: more than max_redirects hops returns TooManyHttpRedirects" {
    const testing = std.testing;
    var mock: RedirectTestMock = .{ .hops = &.{.{ .status = .found, .location = "/loop" }} };
    var sink: std.Io.Writer.Discarding = .init(&.{});

    try testing.expectError(error.TooManyHttpRedirects, executeStream(redirectTestRequest("http://localhost/start"), &mock, &sink.writer, null));
    try testing.expectEqual(@as(usize, max_redirects + 1), mock.call_count);
}

test "executeStream: redirect without Location returns HttpRedirectLocationMissing" {
    var mock: RedirectTestMock = .{ .hops = &.{.{ .status = .found }} };
    var sink: std.Io.Writer.Discarding = .init(&.{});

    try std.testing.expectError(error.HttpRedirectLocationMissing, executeStream(redirectTestRequest("http://localhost/start"), &mock, &sink.writer, null));
}

test "executeStream: redirect hops do not consume the retry budget" {
    const testing = std.testing;
    // One retry is allowed. The redirect must not use it up, so the 503 on
    // the target is still retried and the request succeeds.
    var mock: RedirectTestMock = .{ .hops = &.{
        .{ .status = .found, .location = "/assets/iso/x.iso" },
        .{ .status = .service_unavailable },
        .{ .status = .ok },
    } };
    var req = redirectTestRequest("http://localhost/tests/1/asset/iso/x.iso");
    req.retries = 1;
    var sink: std.Io.Writer.Discarding = .init(&.{});

    const res = try executeStream(req, &mock, &sink.writer, null);

    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqual(@as(usize, 3), mock.call_count);
    // The retry goes to the redirect target, freshly signed.
    try testing.expectEqualStrings("http://localhost/assets/iso/x.iso", mock.calls[2].target());
    try mock.calls[2].expectSignedFor(redirect_test_creds, "/assets/iso/x.iso");
}

test "execute: 302 hop is re-signed for the redirect target, query included" {
    const testing = std.testing;
    var mock: RedirectTestMock = .{ .hops = &.{
        .{ .status = .found, .location = "http://localhost/api/v1/jobs/overview?state=done" },
        .{ .status = .ok },
    } };
    var req = redirectTestRequest("http://localhost/api/v1/jobs?state=done");
    req.allow_lengthless = false;

    const resp = try execute(req, &mock);
    defer resp.deinit();

    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expectEqual(@as(usize, 2), mock.call_count);
    try testing.expect(mock.calls[0].unhandled and mock.calls[1].unhandled);
    try mock.calls[0].expectSignedFor(redirect_test_creds, "/api/v1/jobs?state=done");
    try mock.calls[1].expectSignedFor(redirect_test_creds, "/api/v1/jobs/overview?state=done");
}

test "execute: 303 turns a POST into a bodiless GET" {
    const testing = std.testing;
    var mock: RedirectTestMock = .{ .hops = &.{
        .{ .status = .see_other, .location = "/api/v1/jobs/1" },
        .{ .status = .ok },
    } };
    var req = redirectTestRequest("http://localhost/api/v1/jobs");
    req.method = .POST;
    req.body = "a=b";

    const resp = try execute(req, &mock);
    defer resp.deinit();

    try testing.expectEqual(std.http.Method.POST, mock.calls[0].method);
    try testing.expectEqual(std.http.Method.GET, mock.calls[1].method);
    try mock.calls[1].expectSignedFor(redirect_test_creds, "/api/v1/jobs/1");
}

test "RedirectState.follow: resolves relative, absolute-path and absolute locations" {
    const testing = std.testing;
    var state = RedirectState.init(redirectTestRequest("http://localhost/tests/1/asset/iso/a.iso?x=1"));
    defer state.deinit();

    try state.follow("b.iso"); // relative: merged with the base directory
    try testing.expectEqualStrings("http://localhost/tests/1/asset/iso/b.iso", state.url);
    try state.follow("/assets/iso/../hdd/c.qcow2#frag"); // dot segments removed, fragment dropped
    try testing.expectEqualStrings("http://localhost/assets/hdd/c.qcow2", state.url);
    try testing.expect(state.credentials != null);
    try state.follow("HTTP://LOCALHOST:80/assets/d.iso"); // same origin, spelled differently
    try testing.expectEqualStrings("HTTP://LOCALHOST:80/assets/d.iso", state.url);
    try testing.expect(state.credentials != null);
    try testing.expectError(error.TooManyHttpRedirects, state.follow("/e.iso"));
}

test "openQADownloadToFile: redirect errors are not retried" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var mock: RedirectTestMock = .{ .hops = &.{.{ .status = .found, .location = "/loop" }} };
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();

    try testing.expectError(error.TooManyHttpRedirects, openQADownloadToFile("http://localhost", "/tests/1/asset/iso/x.iso", "dest.iso", .{
        .allocator = allocator,
        .credentials = null,
        .quiet = true,
        .retries = 2,
        .retry_sleep_s = 0,
    }, &mock, &backend));
    // One chain only (not one per retry), and no partial file left behind.
    try testing.expectEqual(@as(usize, max_redirects + 1), mock.call_count);
    try testing.expect(backend.deleted);
}

test "openQADownloadToFile: skips re-download when source replies 416 directly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Non-redirecting source: the ranged probe GET is answered immediately with
    // 416 Range Not Satisfiable → the file is already complete.
    const CompleteMock = struct {
        const Self = @This();
        response: SkipProbeResponse = .{ .head = .{ .status = .range_not_satisfiable } },
        pub fn request(self: *Self, _: std.http.Method, _: std.Uri, _: anytype) !*SkipProbeResponse {
            self.response = .{ .head = .{ .status = .range_not_satisfiable } };
            return &self.response;
        }
    };

    // Pre-place a "complete" sentinel of a known size (16 bytes).
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();
    backend.stat_size = 16;

    var mock: CompleteMock = .{};
    const res = try openQADownloadToFile("http://localhost", "/tests/1/asset/iso/x.iso", "dest.iso", .{
        .allocator = allocator,
        .credentials = null,
        .quiet = true,
        .retries = 0,
    }, &mock, &backend);

    try testing.expect(res.status == .ok);
    // Skip path: no data written to the sink.
    try testing.expectEqual(@as(usize, 0), backend.sink.written().len);
}

test "openQADownloadToFile: skip probe follows the 302 redirect via a ranged GET" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // openQA's asset route: the ranged probe GET gets a 302 to /assets/...,
    // and only the redirect target answers 416. The probe must follow the
    // redirect (re-signed) to see the 416; otherwise the skip fails and the
    // sentinel is overwritten (which this test guards against).

    // Pre-place a "complete" sentinel of a known size (16 bytes).
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();
    backend.stat_size = 16;

    var mock: RedirectTestMock = .{ .hops = &.{
        .{ .status = .found, .location = "/assets/hdd/x.qcow2" },
        .{ .status = .range_not_satisfiable },
    } };
    const res = try openQADownloadToFile("http://localhost", "/tests/1/asset/hdd/x.qcow2", "dest.qcow2", .{
        .allocator = allocator,
        .credentials = redirect_test_creds,
        .quiet = true,
        .retries = 0,
    }, &mock, &backend);

    try testing.expect(res.status == .ok);
    // The probe is a GET that followed the redirect, signed for the target.
    try testing.expectEqual(@as(usize, 2), mock.call_count);
    try testing.expectEqual(std.http.Method.GET, mock.calls[0].method);
    try testing.expectEqual(std.http.Method.GET, mock.calls[1].method);
    try testing.expectEqualStrings("http://localhost/assets/hdd/x.qcow2", mock.calls[1].target());
    try mock.calls[1].expectSignedFor(redirect_test_creds, "/assets/hdd/x.qcow2");

    // Skip path: mtime touched and no data written to the sink.
    try testing.expect(backend.touched);
    try testing.expectEqual(@as(usize, 0), backend.sink.written().len);
}

test "openQADownloadToFile: re-downloads when source does not report complete" {
    const testing = std.testing;
    const allocator = testing.allocator;
    // TestMockClient answers the ranged probe with 200 (not 416), so the source
    // reports the file as NOT complete → a full download must overwrite it.
    var mock: TestMockClient = .{};

    // Pre-place a wrong-content file (18 bytes); the download must overwrite it.
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();
    backend.stat_size = 18;

    const res = try openQADownloadToFile("http://localhost", "/tests/1/asset/iso/x.iso", "dest.iso", .{
        .allocator = allocator,
        .credentials = null,
        .quiet = true,
        .retries = 0,
        .allow_lengthless = true,
    }, &mock, &backend);

    try testing.expect(res.status == .ok);
    // The sink should contain "{}" (the mock's body), not the stale content.
    try testing.expectEqualStrings("{}", backend.sink.written());
}

test "executeStream: returns error.HttpTransferTruncated on short read" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TruncatedMockClient = struct {
        const Self = @This();

        const MockHead = struct {
            status: std.http.Status = .ok,
            content_type: ?[]const u8 = "application/json",
            location: ?[]const u8 = null,
            content_length: ?u64 = 10, // Exceeds body length (2)

            const HeaderIterator = struct {
                done: bool = false,
                fn next(self: *HeaderIterator) ?std.http.Header {
                    if (self.done) return null;
                    self.done = true;
                    return .{ .name = "Content-Type", .value = "application/json" };
                }
            };

            fn iterateHeaders(_: *const MockHead) HeaderIterator {
                return .{};
            }
        };

        const MockReader = struct {
            done: bool = false,
            fn streamRemaining(self: *MockReader, w: anytype) anyerror!usize {
                if (self.done) return 0;
                self.done = true;
                const body = "{}"; // 2 bytes
                try w.writeAll(body);
                return body.len;
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},

            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
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

    var mock: TruncatedMockClient = .{};
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

    var discarding: std.Io.Writer.Discarding = .init(&.{});
    const result = executeStream(req, &mock, &discarding.writer, null);
    try testing.expectError(error.HttpTransferTruncated, result);
}

test "openQADownloadToFile: retries on error.HttpTransferTruncated and deletes partial file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TruncatedMockClient = struct {
        const Self = @This();

        const MockHead = struct {
            status: std.http.Status = .ok,
            content_type: ?[]const u8 = "application/json",
            location: ?[]const u8 = null,
            content_length: ?u64 = 10, // Exceeds body length (2)

            const HeaderIterator = struct {
                done: bool = false,
                fn next(self: *HeaderIterator) ?std.http.Header {
                    if (self.done) return null;
                    self.done = true;
                    return .{ .name = "Content-Type", .value = "application/json" };
                }
            };

            fn iterateHeaders(_: *const MockHead) HeaderIterator {
                return .{};
            }
        };

        const MockReader = struct {
            done: bool = false,
            fn streamRemaining(self: *MockReader, w: anytype) anyerror!usize {
                if (self.done) return 0;
                self.done = true;
                const body = "{}"; // 2 bytes
                try w.writeAll(body);
                return body.len;
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},

            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
            pub fn reader(self: *MockResponse, _: []u8) *MockReader {
                return &self.mock_reader;
            }
            pub fn receiveHead(self: *MockResponse, _: []u8) !*MockResponse {
                return self;
            }
        };

        attempts: u32 = 0,
        response: MockResponse = .{},

        pub fn request(self: *Self, _: std.http.Method, _: std.Uri, _: anytype) !*MockResponse {
            self.attempts += 1;
            return &self.response;
        }
    };

    var mock: TruncatedMockClient = .{};
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();

    const result = openQADownloadToFile("http://localhost", "/tests/123/file.txt", "dest.txt", .{
        .allocator = allocator,
        .credentials = null,
        .quiet = true,
        .retries = 2, // 2 retries = 3 total attempts
        .retry_sleep_s = 0.001, // extremely fast
        .retry_factor = 1.0,
    }, &mock, &backend);

    // Should exhaust retries and propagate the error.
    try testing.expectError(error.HttpTransferTruncated, result);

    // Verify that 3 attempts were made.
    try testing.expectEqual(@as(u32, 3), mock.attempts);
    // Verify the partial file was deleted.
    try testing.expect(backend.deleted);
}

test "openQADownloadToFile: NoSpaceLeft is terminal (no retry)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const DiskFullMockClient = struct {
        const Self = @This();

        const MockHead = struct {
            status: std.http.Status = .ok,
            content_length: ?u64 = 100,
            content_type: ?[]const u8 = "application/octet-stream",
            location: ?[]const u8 = null,

            const HeaderIterator = struct {
                done: bool = false,
                fn next(self: *HeaderIterator) ?std.http.Header {
                    if (self.done) return null;
                    self.done = true;
                    return .{ .name = "Content-Type", .value = "application/octet-stream" };
                }
            };

            fn iterateHeaders(_: *const MockHead) HeaderIterator {
                return .{};
            }
        };

        const MockReader = struct {
            fn streamRemaining(_: *MockReader, w: anytype) anyerror!usize {
                // Write a few bytes, then simulate ENOSPC.
                const partial = "partial-data";
                try w.writeAll(partial);
                return error.NoSpaceLeft;
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},

            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
            pub fn reader(self: *MockResponse, _: []u8) *MockReader {
                return &self.mock_reader;
            }
            pub fn receiveHead(self: *MockResponse, _: []u8) !*MockResponse {
                return self;
            }
        };

        attempts: u32 = 0,
        response: MockResponse = .{},

        pub fn request(self: *Self, _: std.http.Method, _: std.Uri, _: anytype) !*MockResponse {
            self.attempts += 1;
            return &self.response;
        }
    };

    var mock: DiskFullMockClient = .{};
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();
    // Pre-set the sink's write error to simulate a full disk.
    backend.sink.write_error = error.NoSpaceLeft;

    const result = openQADownloadToFile("http://localhost", "/tests/123/file.txt", "dest.txt", .{
        .allocator = allocator,
        .credentials = null,
        .quiet = true,
        .retries = 2, // 2 retries = 3 total attempts (if buggy)
        .retry_sleep_s = 0.001,
        .retry_factor = 1.0,
    }, &mock, &backend);

    // NoSpaceLeft is terminal: exactly 1 attempt, no retry.
    try testing.expectEqual(@as(u32, 1), mock.attempts);
    try testing.expectError(error.NoSpaceLeft, result);
    // The partial file must be deleted.
    try testing.expect(backend.deleted);
}

test "openQADownloadToFile: body larger than 64 KiB exercises the drain path" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BigBodyMockClient = struct {
        const Self = @This();
        const body_len: usize = 128 * 1024; // 128 KiB

        const MockHead = struct {
            status: std.http.Status = .ok,
            content_length: ?u64 = body_len,
            location: ?[]const u8 = null,

            const HeaderIterator = struct {
                done: bool = false,
                fn next(self: *HeaderIterator) ?std.http.Header {
                    if (self.done) return null;
                    self.done = true;
                    return .{ .name = "Content-Type", .value = "application/octet-stream" };
                }
            };

            fn iterateHeaders(_: *const MockHead) HeaderIterator {
                return .{};
            }
        };

        const MockReader = struct {
            // Like std.Io.Reader.streamRemaining, stream the whole body in
            // one call; executeStream calls this exactly once.
            fn streamRemaining(_: *MockReader, w: anytype) anyerror!usize {
                var buf: [65536]u8 = undefined;
                @memset(&buf, 0x42);
                var pos: usize = 0;
                while (pos < body_len) {
                    const chunk = @min(buf.len, body_len - pos);
                    try w.writeAll(buf[0..chunk]);
                    pos += chunk;
                }
                return pos;
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},

            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
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

    var mock: BigBodyMockClient = .{};
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();

    const res = try openQADownloadToFile("http://localhost", "/tests/123/big.bin", "dest.bin", .{
        .allocator = allocator,
        .credentials = null,
        .quiet = true,
        .retries = 0,
    }, &mock, &backend);

    try testing.expect(res.status == .ok);
    // All 128 KiB must be in the sink (no truncation, no reordering).
    try testing.expectEqual(@as(usize, 128 * 1024), backend.sink.written().len);
    // Spot-check: first and last bytes are 0x42.
    try testing.expectEqual(@as(u8, 0x42), backend.sink.written()[0]);
    try testing.expectEqual(@as(u8, 0x42), backend.sink.written()[backend.sink.written().len - 1]);
}

test "openQADownloadToFile: writeError NoSpaceLeft is terminal and deletes the file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const GenericErrorMockClient = struct {
        const Self = @This();

        const MockHead = struct {
            status: std.http.Status = .ok,
            content_length: ?u64 = 100,
            location: ?[]const u8 = null,

            const HeaderIterator = struct {
                done: bool = false,
                fn next(self: *HeaderIterator) ?std.http.Header {
                    if (self.done) return null;
                    self.done = true;
                    return .{ .name = "Content-Type", .value = "application/octet-stream" };
                }
            };

            fn iterateHeaders(_: *const MockHead) HeaderIterator {
                return .{};
            }
        };

        const MockReader = struct {
            fn streamRemaining(_: *MockReader, w: anytype) anyerror!usize {
                const partial = "partial-data";
                try w.writeAll(partial);
                return error.WriteFailed;
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},

            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
            pub fn reader(self: *MockResponse, _: []u8) *MockReader {
                return &self.mock_reader;
            }
            pub fn receiveHead(self: *MockResponse, _: []u8) !*MockResponse {
                return self;
            }
        };

        attempts: u32 = 0,
        response: MockResponse = .{},

        pub fn request(self: *Self, _: std.http.Method, _: std.Uri, _: anytype) !*MockResponse {
            self.attempts += 1;
            return &self.response;
        }
    };

    var mock: GenericErrorMockClient = .{};
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();
    // Pre-set the sink's write error to simulate a full disk.
    backend.sink.write_error = error.NoSpaceLeft;

    const result = openQADownloadToFile("http://localhost", "/tests/123/file.txt", "dest.txt", .{
        .allocator = allocator,
        .credentials = null,
        .quiet = true,
        .retries = 2,
        .retry_sleep_s = 0.001,
        .retry_factor = 1.0,
    }, &mock, &backend);

    // writeError() takes precedence: the result is NoSpaceLeft, not WriteFailed.
    try testing.expectError(error.NoSpaceLeft, result);
    // Terminal: exactly 1 attempt, no retry.
    try testing.expectEqual(@as(u32, 1), mock.attempts);
    // The partial file must be deleted.
    try testing.expect(backend.deleted);
}

test "executeStream: fails with LengthRequired if lengthless and not allowed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const LengthlessMockClient = struct {
        const Self = @This();
        const MockHead = struct {
            status: std.http.Status = .ok,
            content_type: ?[]const u8 = "application/json",
            location: ?[]const u8 = null,
            content_length: ?u64 = null, // Missing Content-Length

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
            pub fn streamRemaining(_: *MockReader, _: anytype) anyerror!usize {
                return 0;
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},
            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
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

    var mock: LengthlessMockClient = .{};
    const req = Request{
        .allocator = allocator,
        .method = .GET,
        .url = "http://localhost/api/v1/jobs",
        .headers = &.{},
        .body = null,
        .credentials = null,
        .retries = 0,
        .quiet = true,
        .expected_size = null,
        .allow_lengthless = false, // strict mode
    };

    var discarding: std.Io.Writer.Discarding = .init(&.{});
    const result = executeStream(req, &mock, &discarding.writer, null);
    try testing.expectError(error.LengthRequired, result);
}

test "executeStream: succeeds when lengthless and allowed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const LengthlessMockClient = struct {
        const Self = @This();
        const MockHead = struct {
            status: std.http.Status = .ok,
            content_type: ?[]const u8 = "application/json",
            location: ?[]const u8 = null,
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
            pub fn streamRemaining(_: *MockReader, _: anytype) anyerror!usize {
                return 10;
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},
            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
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

    var mock: LengthlessMockClient = .{};
    const req = Request{
        .allocator = allocator,
        .method = .GET,
        .url = "http://localhost/api/v1/jobs",
        .headers = &.{},
        .body = null,
        .credentials = null,
        .retries = 0,
        .quiet = true,
        .expected_size = null,
        .allow_lengthless = true,
    };

    var discarding: std.Io.Writer.Discarding = .init(&.{});
    const res = try executeStream(req, &mock, &discarding.writer, null);
    try testing.expectEqual(std.http.Status.ok, res.status);
}

test "executeStream: fails with HttpTransferTruncated when bytes written < expected_size" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TruncatedMockClient = struct {
        const Self = @This();
        const MockHead = struct {
            status: std.http.Status = .ok,
            content_length: ?u64 = null,
            content_type: ?[]const u8 = null,
            location: ?[]const u8 = null,

            const HeaderIterator = struct {
                pub fn next(_: *HeaderIterator) ?std.http.Header {
                    return null;
                }
            };

            pub fn iterateHeaders(_: *const MockHead) HeaderIterator {
                return .{};
            }
        };

        const MockReader = struct {
            pub fn streamRemaining(_: *MockReader, _: anytype) anyerror!usize {
                return 50; // Returns 50 bytes, but expected 100
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},
            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
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

    var mock: TruncatedMockClient = .{};
    const req = Request{
        .allocator = allocator,
        .method = .GET,
        .url = "http://localhost/tests/1/asset/iso/test.iso",
        .headers = &.{},
        .body = null,
        .credentials = null,
        .retries = 0,
        .quiet = true,
        .expected_size = 100, // Expected 100 bytes
        .allow_lengthless = false,
    };

    var discarding: std.Io.Writer.Discarding = .init(&.{});
    const result = executeStream(req, &mock, &discarding.writer, null);
    try testing.expectError(error.HttpTransferTruncated, result);
}

test "executeStream: lengthless 404 response with expected_size set returns not_found status" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const NotFoundMockClient = struct {
        const Self = @This();
        const MockHead = struct {
            status: std.http.Status = .not_found,
            content_length: ?u64 = null,
            content_type: ?[]const u8 = null,
            location: ?[]const u8 = null,

            const HeaderIterator = struct {
                pub fn next(_: *HeaderIterator) ?std.http.Header {
                    return null;
                }
            };

            pub fn iterateHeaders(_: *const MockHead) HeaderIterator {
                return .{};
            }
        };

        const MockReader = struct {
            pub fn streamRemaining(_: *MockReader, w: anytype) anyerror!usize {
                const body = "404 Not Found";
                try w.writeAll(body);
                return body.len;
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},
            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
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

    var mock: NotFoundMockClient = .{};
    const req = Request{
        .allocator = allocator,
        .method = .GET,
        .url = "http://localhost/tests/1/asset/iso/missing.iso",
        .headers = &.{},
        .body = null,
        .credentials = null,
        .retries = 0,
        .quiet = true,
        .expected_size = 1000,
        .allow_lengthless = false,
    };

    var discarding: std.Io.Writer.Discarding = .init(&.{});
    const res = try executeStream(req, &mock, &discarding.writer, null);
    try testing.expectEqual(std.http.Status.not_found, res.status);
}

// ---------------------------------------------------------------------------
// Progress meter unit tests
// ---------------------------------------------------------------------------

test "ProgressMeter: computePct basic arithmetic" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 0), ProgressMeter.computePct(0, 1000));
    try testing.expectEqual(@as(u8, 45), ProgressMeter.computePct(450, 1000));
    try testing.expectEqual(@as(u8, 99), ProgressMeter.computePct(999, 1000));
    try testing.expectEqual(@as(u8, 100), ProgressMeter.computePct(1000, 1000));
    try testing.expectEqual(@as(u8, 100), ProgressMeter.computePct(2000, 1000));
}

test "ProgressMeter: computePct overflow protection" {
    const testing = std.testing;
    const max = std.math.maxInt(u64);
    try testing.expectEqual(@as(u8, 100), ProgressMeter.computePct(max, max));
    try testing.expectEqual(@as(u8, 100), ProgressMeter.computePct(max, 1));
    // done near maxInt: (done * 100) would overflow, so the alternate
    // division path must be taken.
    const done = max - 100;
    const total = max;
    const pct = ProgressMeter.computePct(done, total);
    try testing.expect(pct >= 99 and pct <= 100);
}

test "ProgressMeter: computePct zero total guard" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 100), ProgressMeter.computePct(0, 0));
    try testing.expectEqual(@as(u8, 100), ProgressMeter.computePct(5, 0));
}

test "ProgressMeter: update fires on first byte and pct change" {
    const testing = std.testing;
    var meter = ProgressMeter.init(1000);
    meter.setTotal(1000);
    // First render: last_render_ms == minInt, so the time gate is bypassed.
    const p1 = meter.update(100, 0) orelse return testing.expect(false);
    try testing.expectEqual(@as(u64, 100), p1.done);
    try testing.expectEqual(@as(u8, 10), p1.pct.?);
    meter.markRendered(0, p1.pct);

    // bytes=150 (15%), within 50 ms: time gate blocks.
    try testing.expect(meter.update(50, 20) == null);
    // bytes=160 (16%), >= 50 ms, pct changed: event.
    const p2 = meter.update(10, 80) orelse return testing.expect(false);
    try testing.expectEqual(@as(u8, 16), p2.pct.?);
    meter.markRendered(80, p2.pct);
    // bytes=180 (18%), within 50 ms of t=80: time gate blocks.
    try testing.expect(meter.update(20, 100) == null);
    // bytes=200 (20%), >= 50 ms, pct changed: event.
    const p3 = meter.update(20, 140) orelse return testing.expect(false);
    try testing.expectEqual(@as(u8, 20), p3.pct.?);
}

test "ProgressMeter: update throttles within 50 ms of last render" {
    const testing = std.testing;
    var meter = ProgressMeter.init(1000);
    meter.setTotal(1000);
    // bytes=100 (10%), first render.
    const p1 = meter.update(100, 0) orelse return testing.expect(false);
    try testing.expectEqual(@as(u8, 10), p1.pct.?);
    meter.markRendered(0, p1.pct);
    // bytes=200 (20%), only 10 ms since t=0: time gate blocks.
    try testing.expect(meter.update(100, 10) == null);
    // bytes=300 (30%), 80 ms since t=0, pct changed: event.
    const p2 = meter.update(100, 80) orelse return testing.expect(false);
    try testing.expectEqual(@as(u8, 30), p2.pct.?);
    meter.markRendered(80, p2.pct);
    // bytes=400 (40%), only 10 ms since t=80: time gate blocks.
    try testing.expect(meter.update(100, 90) == null);
    // bytes=500 (50%), 60 ms since t=80, pct changed: event.
    const p3 = meter.update(100, 150) orelse return testing.expect(false);
    try testing.expectEqual(@as(u8, 50), p3.pct.?);
}

test "ProgressMeter: unknown total uses 250 ms gate" {
    const testing = std.testing;
    var meter = ProgressMeter.init(null);
    // First render: last_render_ms == 0, so the time gate is bypassed.
    const p1 = meter.update(100, 0) orelse return testing.expect(false);
    try testing.expectEqual(@as(u64, 100), p1.done);
    try testing.expect(p1.total == null);
    try testing.expect(p1.pct == null);
    meter.markRendered(0, null);
    // 100 ms elapsed (< 250 ms): throttled.
    try testing.expect(meter.update(100, 100) == null);
    // 350 ms elapsed (>= 250 ms): event.
    const p2 = meter.update(100, 350) orelse return testing.expect(false);
    try testing.expectEqual(@as(u64, 300), p2.done);
}

test "ProgressMeter: setTotal prefers content_length over fallback" {
    const testing = std.testing;
    var meter = ProgressMeter.init(500);
    try testing.expectEqual(@as(u64, 500), meter.effectiveTotal().?);
    meter.setTotal(1000);
    try testing.expectEqual(@as(u64, 1000), meter.effectiveTotal().?);
    meter.setTotal(null);
    try testing.expectEqual(@as(u64, 500), meter.effectiveTotal().?);
}

test "ProgressMeter: reset clears counters and timers" {
    const testing = std.testing;
    var meter = ProgressMeter.init(1000);
    meter.setTotal(1000);
    _ = meter.update(500, 1000);
    meter.markRendered(1000, 50);
    meter.reset();
    try testing.expectEqual(@as(u64, 0), meter.bytes_written);
    try testing.expect(meter.last_pct == null);
    try testing.expectEqual(std.math.minInt(i64), meter.last_render_ms);
    // First update after reset fires immediately (no throttle state).
    const p = meter.update(10, 5000) orelse return testing.expect(false);
    try testing.expectEqual(@as(u8, 1), p.pct.?);
}

test "ProgressMeter: finalRender forces completion payload" {
    const testing = std.testing;
    var meter = ProgressMeter.init(1000);
    meter.setTotal(1000);
    _ = meter.update(990, 0);
    meter.markRendered(0, 99);
    // Even though the 50 ms gate would block a 100% event at t=10 ms,
    // finalRender forces it.
    const p = meter.finalRender();
    try testing.expectEqual(@as(u64, 990), p.done);
    try testing.expectEqual(@as(u8, 99), p.pct.?);
    // Unknown total: finalRender reports done with no pct.
    var m2 = ProgressMeter.init(null);
    _ = m2.update(42, 0);
    const p2 = m2.finalRender();
    try testing.expectEqual(@as(u64, 42), p2.done);
    try testing.expect(p2.pct == null);
}

test "ProgressTerminalRenderer: formatHumanSize boundaries" {
    const testing = std.testing;
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0 B", ProgressTerminalRenderer.formatHumanSize(&buf, 0));
    try testing.expectEqualStrings("1023 B", ProgressTerminalRenderer.formatHumanSize(&buf, 1023));
    try testing.expectEqualStrings("1.0 KiB", ProgressTerminalRenderer.formatHumanSize(&buf, 1024));
    try testing.expectEqualStrings("1.5 MiB", ProgressTerminalRenderer.formatHumanSize(&buf, 1_572_864));
    try testing.expectEqualStrings("2.0 GiB", ProgressTerminalRenderer.formatHumanSize(&buf, 2_147_483_648));
    try testing.expectEqualStrings("3.0 TiB", ProgressTerminalRenderer.formatHumanSize(&buf, 3_298_534_883_328));
}

test "ProgressTerminalRenderer: progress line formatting" {
    const testing = std.testing;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var r = ProgressTerminalRenderer.init("test.iso", &aw.writer);

    try r.renderProgress(450, 1000, 45);
    var out = aw.writer.buffered();
    try testing.expectEqualStrings("\rDownloading test.iso: 45% (450 B / 1000 B)", out);

    // Unknown total: no percentage, no total.
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    var r2 = ProgressTerminalRenderer.init("test.iso", &aw2.writer);
    try r2.renderProgress(2048, null, null);
    out = aw2.writer.buffered();
    try testing.expectEqualStrings("\rDownloading test.iso: 2.0 KiB", out);
}

test "ProgressTerminalRenderer: space padding erases ghost characters" {
    const testing = std.testing;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var r = ProgressTerminalRenderer.init("test.iso", &aw.writer);

    // Long line first.
    try r.renderProgress(999_999, 1_000_000, 99);
    const long_line = aw.writer.buffered();
    try testing.expect(std.mem.startsWith(u8, long_line, "\rDownloading test.iso: 99% (976.6 KiB / 976.6 KiB)"));

    // Shorter line: padded with trailing spaces up to the previous length.
    try r.renderProgress(10, 1_000_000, 0);
    const all = aw.writer.buffered();
    const second = all[long_line.len..];
    try testing.expect(std.mem.startsWith(u8, second, "\rDownloading test.iso: 0% (10 B / 976.6 KiB)"));
    // The padded line must be at least as long as the first line.
    try testing.expect(second.len >= long_line.len);
    for (second[long_line.len - 1 ..]) |c| {
        try testing.expectEqual(@as(u8, ' '), c);
    }
}

test "ProgressTerminalRenderer: finish emits final line and newline" {
    const testing = std.testing;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var r = ProgressTerminalRenderer.init("test.iso", &aw.writer);

    try r.renderProgress(500, 1000, 50);
    try r.finish(1000, 1000);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "100%") != null);
}

test "ProgressTerminalRenderer: abort emits newline only after a render" {
    const testing = std.testing;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var r = ProgressTerminalRenderer.init("test.iso", &aw.writer);

    // Pre-stream silence: abort before any render emits nothing.
    try r.abort();
    try testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);

    // After a render, abort terminates the line with a newline.
    try r.renderProgress(100, 1000, 10);
    const before = aw.writer.buffered().len;
    try r.abort();
    const out = aw.writer.buffered();
    try testing.expectEqual(before + 1, out.len);
    try testing.expectEqual(@as(u8, '\n'), out[before]);
}

test "ProgressTerminalRenderer: skip message" {
    const testing = std.testing;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var r = ProgressTerminalRenderer.init("test.iso", &aw.writer);
    try r.renderSkip();
    try testing.expectEqualStrings("test.iso: already complete, skipped\n", aw.writer.buffered());
}

test "ProgressStreamTap: transparent byte passthrough" {
    const testing = std.testing;
    var inner: std.Io.Writer.Allocating = .init(testing.allocator);
    defer inner.deinit();
    var meter = ProgressMeter.init(100);
    var renderer = ProgressTerminalRenderer.init("t", &inner.writer);
    var tap_buf: [64]u8 = undefined;
    var tap = ProgressStreamTap.init(&inner.writer, &meter, &renderer, &tap_buf);

    const payload = "hello world, this is a tap test";
    try tap.writer().writeAll(payload);
    try tap.writer().flush();

    // The inner writer received the payload plus the progress lines.
    const out = inner.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, payload) != null);
    // The meter counted exactly the payload bytes.
    try testing.expectEqual(@as(u64, payload.len), meter.bytes_written);
}

test "ProgressStreamTap: splat passthrough and accounting" {
    const testing = std.testing;
    var inner: std.Io.Writer.Allocating = .init(testing.allocator);
    defer inner.deinit();
    var meter = ProgressMeter.init(10);
    var renderer = ProgressTerminalRenderer.init("t", &inner.writer);
    var tap_buf: [8]u8 = undefined;
    var tap = ProgressStreamTap.init(&inner.writer, &meter, &renderer, &tap_buf);

    // Splat write: 5 x "ab" = 10 bytes.
    var splat_data = [_][]const u8{"ab"};
    try tap.writer().writeSplatAll(&splat_data, 5);
    try tap.writer().flush();

    try testing.expectEqual(@as(u64, 10), meter.bytes_written);
    const out = inner.writer.buffered();
    // The payload bytes must appear exactly 5 times.
    var count: usize = 0;
    for (0..out.len - 1) |i| {
        if (std.mem.eql(u8, out[i .. i + 2], "ab")) count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);
}

test "ProgressStreamTap: large write across buffer boundary" {
    const testing = std.testing;
    var inner: std.Io.Writer.Allocating = .init(testing.allocator);
    defer inner.deinit();
    var meter = ProgressMeter.init(1024);
    var renderer = ProgressTerminalRenderer.init("t", &inner.writer);
    var tap_buf: [16]u8 = undefined;
    var tap = ProgressStreamTap.init(&inner.writer, &meter, &renderer, &tap_buf);

    var big: [1000]u8 = undefined;
    @memset(&big, 0x42);
    try tap.writer().writeAll(&big);
    try tap.writer().flush();

    try testing.expectEqual(@as(u64, 1000), meter.bytes_written);
    const out = inner.writer.buffered();
    // The payload (1000 x 0x42) must appear as a contiguous run; progress
    // lines are interleaved but never contain 0x42.
    try testing.expect(std.mem.indexOf(u8, out, &big) != null);
}

test "parseRetryAfter: integer seconds and invalid formats" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u64, 2), parseRetryAfter("2"));
    try testing.expectEqual(@as(?u64, 30), parseRetryAfter(" 30 "));
    try testing.expectEqual(@as(?u64, 0), parseRetryAfter("0"));
    try testing.expectEqual(@as(?u64, 999999), parseRetryAfter("999999"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("soon"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter(""));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("-5"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("1.5"));
}

test "retryDelayNs: override and exponential backoff" {
    const testing = std.testing;
    // Override capped at RETRY_AFTER_CAP_S (60 s)
    try testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), retryDelayNs(0, 3.0, 1.0, 2));
    try testing.expectEqual(@as(u64, 0), retryDelayNs(0, 3.0, 1.0, 0));
    try testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), retryDelayNs(0, 3.0, 1.0, 120));

    // Computed backoff (uncapped for server delay, saturates on overflow)
    try testing.expectEqual(@as(u64, 3 * std.time.ns_per_s), retryDelayNs(0, 3.0, 1.0, null));
    try testing.expectEqual(@as(u64, 3 * std.time.ns_per_s), retryDelayNs(0, 3.0, 2.0, null));
    try testing.expectEqual(@as(u64, 6 * std.time.ns_per_s), retryDelayNs(1, 3.0, 2.0, null));
    try testing.expectEqual(@as(u64, 12 * std.time.ns_per_s), retryDelayNs(2, 3.0, 2.0, null));
    try testing.expectEqual(@as(u64, 100 * std.time.ns_per_s), retryDelayNs(0, 100.0, 1.0, null));
    try testing.expectEqual(std.math.maxInt(u64), retryDelayNs(1000, 100.0, 10.0, null));
}

test "hasHtmlExtension: case-insensitive suffix matching" {
    const testing = std.testing;
    try testing.expect(hasHtmlExtension("a.html"));
    try testing.expect(hasHtmlExtension("A.HTM"));
    try testing.expect(hasHtmlExtension("x.Html"));
    try testing.expect(!hasHtmlExtension("a.qcow2"));
    try testing.expect(!hasHtmlExtension("html"));
    try testing.expect(!hasHtmlExtension("a.html.qcow2"));
    try testing.expect(!hasHtmlExtension("a.xhtml"));
}

test "executeStream: reject_html returns error.UnexpectedHtmlResponse on text/html" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const HtmlMockClient = struct {
        const Self = @This();
        const MockHead = struct {
            status: std.http.Status = .ok,
            content_length: ?u64 = 100,
            content_type: ?[]const u8 = "text/html; charset=utf-8",
            location: ?[]const u8 = null,

            const HeaderIterator = struct {
                pub fn next(_: *HeaderIterator) ?std.http.Header {
                    return null;
                }
            };

            pub fn iterateHeaders(_: *const MockHead) HeaderIterator {
                return .{};
            }
        };

        const MockReader = struct {
            pub fn streamRemaining(_: *MockReader, w: anytype) anyerror!usize {
                try w.writeAll("<html>Challenge</html>");
                return 22;
            }
        };

        const MockResponse = struct {
            head: MockHead = .{},
            mock_reader: MockReader = .{},
            pub fn deinit(_: *MockResponse) void {}
            pub fn sendBodiless(_: *MockResponse) !void {}
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

    var mock: HtmlMockClient = .{};
    const req = Request{
        .allocator = allocator,
        .method = .GET,
        .url = "http://localhost/tests/1/asset/hdd/disk.qcow2",
        .headers = &.{},
        .body = null,
        .credentials = null,
        .retries = 0,
        .quiet = true,
        .reject_html = true,
    };

    var discarding: std.Io.Writer.Discarding = .init(&.{});
    const result = executeStream(req, &mock, &discarding.writer, null);
    try testing.expectError(error.UnexpectedHtmlResponse, result);
}

test "buildHeaders: R1 regression — always exactly one Accept header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const uri = try std.Uri.parse("http://localhost/api/v1/jobs");
    var hash_buf: [40]u8 = undefined;
    var timestamp_buf: [32]u8 = undefined;

    // Default: Accept: application/json added automatically
    {
        var headers = try buildHeaders(allocator, &.{}, null, uri, &hash_buf, &timestamp_buf, false);
        defer headers.deinit(allocator);

        var accept_count: usize = 0;
        var accept_val: []const u8 = "";
        for (headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Accept")) {
                accept_count += 1;
                accept_val = h.value;
            }
        }
        try testing.expectEqual(@as(usize, 1), accept_count);
        try testing.expectEqualStrings("application/json", accept_val);
    }

    // Custom Accept header provided by caller: caller value wins, still exactly 1 Accept
    {
        const custom_headers = [_]std.http.Header{.{ .name = "Accept", .value = "text/plain" }};
        var headers = try buildHeaders(allocator, &custom_headers, null, uri, &hash_buf, &timestamp_buf, false);
        defer headers.deinit(allocator);

        var accept_count: usize = 0;
        var accept_val: []const u8 = "";
        for (headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Accept")) {
                accept_count += 1;
                accept_val = h.value;
            }
        }
        try testing.expectEqual(@as(usize, 1), accept_count);
        try testing.expectEqualStrings("text/plain", accept_val);
    }
}
