const std = @import("std");
const testing = std.testing;

pub const config = @import("config.zig");
pub const auth = @import("auth.zig");
const http_client = @import("http_client.zig");

// Re-export public types. Only types needed by external consumers are `pub`.
// `Request`, `execute`, and `normalizePathQuery` are internal implementation
// details — external callers must go through `openQAReq` instead.
pub const APIResponse = http_client.APIResponse;

// Internal aliases — NOT part of the public API.
const Request = http_client.Request;
const execute = http_client.execute;

// ---------------------------------------------------------------------------
// CallOptions — options for openQAReq / openQANextUrl
// ---------------------------------------------------------------------------

/// Configuration for a single openQA API call via `openQAReq`.
///
/// This struct bundles every tuneable aspect of a request — HTTP method,
/// parameters, body, authentication credentials, retry policy, and
/// diagnostics — into a single value that is passed to `openQAReq`.
/// All fields except `allocator` have sensible defaults, so callers only
/// need to set the fields that differ from a simple unauthenticated GET.
///
/// `CallOptions` is a parameter type of the public function
/// `openQAReq`, it allows external package consumers to name the type explicitly
/// (e.g. to store a partially-filled `CallOptions` in a variable, pass it across
/// function boundaries, or write generic helpers). Callers may also use an
/// anonymous struct literal `.{ .allocator = alloc, ... }` — Zig coerces it
/// automatically — but having the named type available is important for
/// documentation, tooling, and downstream library code.
///
/// **Ownership:** `CallOptions` does **not** own any of the slices or
/// pointers it holds (`headers`, `params`, `body`, `credentials`). The
/// caller must ensure these remain valid for the duration of the
/// `openQAReq` call. There is no `deinit` — nothing to free.
///
/// **Example** (external consumer):
/// ```zig
/// const zoqa = @import("zoqa");
///
/// var client = std.http.Client{ .allocator = allocator };
/// defer client.deinit();
///
/// const resp = try zoqa.openQAReq("openqa.opensuse.org", "jobs/12345", .{
///     .allocator = allocator,
///     .method = .GET,
///     .credentials = creds,
/// }, &client);
/// defer resp.deinit();
/// ```
pub const CallOptions = struct {
    /// General-purpose allocator used by `openQAReq` for all internal
    /// allocations (URL construction, HMAC signing buffers, response body
    /// decompression). The same allocator is threaded into the returned
    /// `APIResponse`, which uses it in its `deinit` to free the response
    /// body and header copies. Callers must ensure this allocator remains
    /// valid until `APIResponse.deinit()` is called.
    allocator: std.mem.Allocator,

    /// HTTP method for the request. Defaults to `.GET`.
    ///
    /// The method also controls how `params` is routed:
    ///   - `.GET`, `.DELETE` → `params` appended as a URL query string.
    ///   - `.POST`, `.PUT`, `.PATCH` → `params` used as the request body
    ///     (unless an explicit `body` is provided).
    method: std.http.Method = .GET,

    /// Extra request headers supplied by the caller (e.g. from `--header`
    /// or `--json` CLI flags). **Not owned** by `CallOptions` — the caller
    /// must keep the backing memory alive for the duration of the request.
    /// Defaults to an empty slice.
    headers: []const std.http.Header = &.{},

    /// Pre-encoded URL query / form-encoded parameter string
    /// (e.g. `"DISTRI=sle&VERSION=15"`).
    ///
    /// This string must already be percent-encoded. `openQAReq` routes it
    /// based on the HTTP method:
    ///   - **GET / DELETE**: appended to the URL as a query string
    ///     (`?params` or `&params` if the URL already has a query).
    ///   - **POST / PUT / PATCH**: used as the request body, **unless** an
    ///     explicit `body` is provided, in which case `params` is ignored.
    ///
    /// Pass an empty slice (`""`) when there are no parameters.
    /// **Not owned** — the caller retains ownership.
    params: []const u8 = "",

    /// Optional raw request body. When set, this takes precedence over
    /// `params` for POST/PUT/PATCH payloads. Typically populated from
    /// `--data` or `--data-file` content. Pass `null` (the default) to let
    /// `params` serve as the body for write methods.
    /// **Not owned** — the caller retains ownership.
    body: ?[]const u8 = null,

    /// Resolved API credentials for HMAC-SHA1 request signing (SPEC §5).
    /// When `null` (the default), the request is sent without authentication
    /// — suitable for read-only public endpoints. When set, `openQAReq`
    /// computes the HMAC signature and attaches the `X-API-Key` /
    /// `X-API-Hash` headers automatically.
    /// **Not owned** — the caller retains ownership and must free after the
    /// request completes (if the credentials were dynamically allocated).
    credentials: ?config.Credentials = null,

    /// Number of automatic retries on transient failures — connection
    /// errors and HTTP 502/503 responses (SPEC §8). Defaults to `0`
    /// (no retries). Each retry re-executes the full request including
    /// HMAC re-signing with a fresh timestamp.
    retries: u32 = 0,

    /// When `true`, suppresses non-fatal diagnostic messages that would
    /// normally be printed to stderr (e.g. retry warnings, connection
    /// error details). Fatal errors still cause a non-zero exit or an
    /// error return. Corresponds to the `--quiet` / `-q` CLI flag.
    quiet: bool = false,
};

// ---------------------------------------------------------------------------
// openQAReq — construct URL and execute a request
// ---------------------------------------------------------------------------

/// Perform an authenticated request against an openQA instance.
///
/// This is the **primary public entry point** of the library. It orchestrates:
///   1. Host resolution (bare hostname → full base URL via `config.resolveHost`).
///   2. URL construction (`host/api/v1/path`, with params routing).
///   3. HMAC-SHA1 signature generation (via resolved credentials).
///   4. HTTP execution and response decompression (via the injected `client`).
///
/// Parameters:
///   `host`  — bare hostname, shortcut alias, or full base URL
///             (e.g. "my.host.de", "http://my.host.de", "https://my.host.de").
///             Shortcut resolution (osd/o3/odn) must be done by the caller
///             before invoking this function — pass the resolved host string.
///   `path`  — relative API path, always **without** the "/api/v1/" prefix
///             (e.g. "jobs", "jobs/1234"). Must not start with a scheme.
///             A leading slash is tolerated and stripped automatically.
///   `opts`  — `CallOptions` struct controlling method, params, body, headers,
///             credentials, retries, and quiet mode. See `CallOptions` doc
///             comments for params routing rules.
///   `client` — the HTTP engine. Pass a pointer to a real `std.http.Client`
///              for production, or a mock implementing the same `.request()`
///              interface for testing.
///
/// Returns:
///   `APIResponse` on success — caller **must** call `response.deinit()`.
///   Error on network/connection failure (after exhausting retries).
///
/// Params routing (performed internally):
///   - GET / DELETE:  `opts.params` is appended to the URL as a query string.
///   - POST / PUT / PATCH: `opts.params` is used as the request body, unless
///     `opts.body` is already set (explicit body takes precedence).
pub fn openQAReq(
    host: []const u8,
    path: []const u8,
    opts: CallOptions,
    client: anytype,
) !APIResponse {
    // Resolve the host to a base URL (adds https:// if bare hostname).
    const host_res = try config.resolveHost(opts.allocator, false, false, false, host);
    defer if (host_res.allocated) opts.allocator.free(host_res.url);

    // Strip any leading slash from path to avoid double-slash.
    const clean_path = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;

    // Build the base URL: <host>/api/v1/<path>
    const base_url = try std.fmt.allocPrint(opts.allocator, "{s}/api/v1/{s}", .{ host_res.url, clean_path });
    defer opts.allocator.free(base_url);

    // --- Params routing ---
    // GET/DELETE: append params as query string.
    // POST/PUT/PATCH: use params as body (unless explicit body provided).
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
    };

    return execute(req, client);
}

// ---------------------------------------------------------------------------
// openQAReq tests — mock client captures the Request that execute() builds
// ---------------------------------------------------------------------------

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
        // Reconstruct URL from the parsed Uri for assertion.
        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();
        // scheme://host
        writer.writeAll(uri.scheme) catch {};
        writer.writeAll("://") catch {};
        if (uri.host) |h| {
            writer.writeAll(h.percent_encoded) catch {};
        }
        if (uri.port) |p| {
            writer.print(":{d}", .{p}) catch {};
        }
        // path
        writer.writeAll(uri.path.percent_encoded) catch {};
        // query
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
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "/jobs/1234", .{
        .allocator = allocator,
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("http://localhost/api/v1/jobs/1234", mock.getCapturedUrl());
}

test "openQAReq: GET params appended as query string" {
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
    // GET should be bodiless
    try testing.expect(mock.captured_bodiless);
}

test "openQAReq: DELETE params appended as query string" {
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
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "isos", .{
        .allocator = allocator,
        .method = .POST,
        .params = "DISTRI=test&VERSION=1",
    }, &mock);
    defer resp.deinit();

    // URL should NOT have query string for POST
    try testing.expectEqualStrings("http://localhost/api/v1/isos", mock.getCapturedUrl());
    // params should have been sent as body
    try testing.expectEqualStrings("DISTRI=test&VERSION=1", mock.getCapturedBody());
}

test "openQAReq: POST explicit body takes precedence over params" {
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "jobs", .{
        .allocator = allocator,
        .method = .POST,
        .params = "ignored=true",
        .body = "{\"key\":\"value\"}",
    }, &mock);
    defer resp.deinit();

    // URL should NOT have query string
    try testing.expectEqualStrings("http://localhost/api/v1/jobs", mock.getCapturedUrl());
    // Explicit body wins over params
    try testing.expectEqualStrings("{\"key\":\"value\"}", mock.getCapturedBody());
}

test "openQAReq: PUT params routed as body" {
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
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("http://localhost", "workers", .{
        .allocator = allocator,
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("http://localhost/api/v1/workers", mock.getCapturedUrl());
    // No body sent — should have called sendBodiless
    try testing.expect(mock.captured_bodiless);
    try testing.expect(mock.captured_body_len == 0);
}

test "openQAReq: bare hostname gets https:// prefix" {
    const allocator = testing.allocator;
    var mock: TestMockClient = .{};

    const resp = try openQAReq("openqa.opensuse.org", "jobs", .{
        .allocator = allocator,
    }, &mock);
    defer resp.deinit();

    try testing.expectEqualStrings("https://openqa.opensuse.org/api/v1/jobs", mock.getCapturedUrl());
}

test "openQAReq: response fields are propagated" {
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

// ---------------------------------------------------------------------------
// LinkIterator / parseLinkHeader — RFC 5988 Link header parser
// ---------------------------------------------------------------------------

/// Zero-allocation iterator over `(rel, url)` pairs in an RFC 5988
/// `Link` response header.
///
/// Lazily parses comma-separated link entries, yielding one `Relation`
/// per valid entry. Malformed entries (missing `<>` delimiters, missing
/// `rel=` parameter, empty rel value) are silently skipped — never an
/// error.
///
/// All returned slices **borrow** from the original header string.
/// No allocation, no `deinit` needed. The iterator itself is a small
/// stack value (wraps a `std.mem.SplitIterator`).
///
/// Created by `parseLinkHeader`.
pub const LinkIterator = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    /// A single parsed link relation: a `rel` name and its associated URL.
    pub const Relation = struct { rel: []const u8, url: []const u8 };

    /// Return the next valid `(rel, url)` pair, or `null` when exhausted.
    pub fn next(self: *LinkIterator) ?Relation {
        while (self.inner.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t");
            const url_start = std.mem.indexOfScalar(u8, trimmed, '<') orelse continue;
            const url_end = std.mem.indexOfScalar(u8, trimmed, '>') orelse continue;
            if (url_end <= url_start) continue;
            const url = trimmed[url_start + 1 .. url_end];

            var params = std.mem.splitScalar(u8, trimmed[url_end + 1 ..], ';');
            while (params.next()) |param| {
                const p = std.mem.trim(u8, param, " \t");
                if (std.mem.startsWith(u8, p, "rel=")) {
                    var r = p[4..];
                    if (r.len >= 2 and r[0] == '"' and r[r.len - 1] == '"') {
                        r = r[1 .. r.len - 1];
                    }
                    if (r.len > 0) {
                        return .{ .rel = r, .url = url };
                    }
                }
            }
        }
        return null;
    }
};

/// Parse an RFC 5988 `Link` header value into an iterator of
/// `(rel, url)` pairs.
///
/// The returned `LinkIterator` yields one `Relation` per valid
/// comma-separated entry in the header. Zero allocation — all
/// returned slices borrow from `header`.
///
/// ```zig
/// var it = zoqa.parseLinkHeader(resp.link.?);
/// while (it.next()) |link| {
///     try stderr.print("{s}: {s}\n", .{ link.rel, link.url });
/// }
/// ```
pub fn parseLinkHeader(header: []const u8) LinkIterator {
    return .{ .inner = std.mem.splitScalar(u8, header, ',') };
}

// ---------------------------------------------------------------------------
// parseLinkHeader tests
// ---------------------------------------------------------------------------

test "parseLinkHeader: multiple relations in header order" {
    const header = "</api/v1/jobs?offset=0>; rel=\"first\", </api/v1/jobs?offset=10>; rel=\"next\"";
    var it = parseLinkHeader(header);

    const first = it.next().?;
    try testing.expectEqualStrings("first", first.rel);
    try testing.expectEqualStrings("/api/v1/jobs?offset=0", first.url);

    const second = it.next().?;
    try testing.expectEqualStrings("next", second.rel);
    try testing.expectEqualStrings("/api/v1/jobs?offset=10", second.url);

    try testing.expect(it.next() == null);
}

test "parseLinkHeader: empty header yields nothing" {
    var it = parseLinkHeader("");
    try testing.expect(it.next() == null);
}

test "parseLinkHeader: malformed entries are skipped" {
    const header = "no-angles, <valid-url>; rel=\"good\", ; rel=\"no-url\"";
    var it = parseLinkHeader(header);

    const good = it.next().?;
    try testing.expectEqualStrings("good", good.rel);
    try testing.expectEqualStrings("valid-url", good.url);

    try testing.expect(it.next() == null);
}

test "parseLinkHeader: entry without rel parameter is skipped" {
    const header = "<url1>; type=\"text/html\", <url2>; rel=\"found\"";
    var it = parseLinkHeader(header);

    const found = it.next().?;
    try testing.expectEqualStrings("found", found.rel);
    try testing.expectEqualStrings("url2", found.url);

    try testing.expect(it.next() == null);
}

test "parseLinkHeader: unquoted rel value" {
    const header = "<url>; rel=next";
    var it = parseLinkHeader(header);

    const rel = it.next().?;
    try testing.expectEqualStrings("next", rel.rel);
    try testing.expectEqualStrings("url", rel.url);

    try testing.expect(it.next() == null);
}

test "parseLinkHeader: quoted rel value" {
    const header = "<url>; rel=\"prev\"";
    var it = parseLinkHeader(header);

    const rel = it.next().?;
    try testing.expectEqualStrings("prev", rel.rel);
    try testing.expectEqualStrings("url", rel.url);

    try testing.expect(it.next() == null);
}

test "re-exports: APIResponse accessible via zoqa" {
    // Verify the re-export compiles and is accessible.
    const T = APIResponse;
    _ = T;
}
