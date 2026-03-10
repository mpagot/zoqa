const std = @import("std");
const testing = std.testing;

pub const config = @import("config.zig");
pub const auth = @import("auth.zig");
const http_client = @import("http_client.zig");

// Re-export public types. Only types needed by external consumers are `pub`.
// `Request` and `execute` are internal implementation details — external
// callers must go through `openQAReq` instead.
pub const APIResponse = http_client.APIResponse;
pub const normalizePathQuery = http_client.normalizePathQuery;
pub const parseLinkHeader = http_client.parseLinkHeader;

// Internal aliases — NOT part of the public API.
const Request = http_client.Request;
const execute = http_client.execute;

// ---------------------------------------------------------------------------
// CallOptions — options for openQAReq / openQANextUrl
// ---------------------------------------------------------------------------

pub const CallOptions = struct {
    allocator: std.mem.Allocator,
    method: std.http.Method = .GET,
    /// Extra request headers supplied by the caller (not owned by CallOptions).
    headers: []const std.http.Header = &.{},
    /// Pre-encoded URL query / form-encoded parameter string (e.g. "DISTRI=sle&VERSION=15").
    ///
    /// Routing rules (owned by `openQAReq`):
    ///   - GET / DELETE  → appended to the URL as a query string (`?params` or `&params`).
    ///   - POST / PUT / PATCH → used as the request body **unless** an explicit `body`
    ///     is provided, in which case `params` is ignored.
    ///
    /// Pass an empty slice (`""`) when there are no parameters.
    params: []const u8 = "",
    /// Optional raw request body. Takes precedence over `params` for
    /// POST/PUT/PATCH payloads.
    body: ?[]const u8 = null,
    /// Resolved credentials for HMAC signing. Null → unauthenticated request.
    credentials: ?config.Credentials = null,
    /// Number of retries on connection error or 502/503 (default 0).
    retries: u32 = 0,
    /// Suppress non-fatal error messages on stderr.
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
// openQANextUrl — extract the "next" URL from a Link header
// ---------------------------------------------------------------------------

/// Parse a RFC 5988 `Link` response header and return the URL with
/// `rel="next"`, or `null` if there is no such relation.
///
/// The returned slice is allocated with `allocator` and must be freed by
/// the caller.
pub fn openQANextUrl(allocator: std.mem.Allocator, link_header: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, link_header, ',');
    while (it.next()) |entry| {
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
                if (std.mem.eql(u8, r, "next")) {
                    return try allocator.dupe(u8, url);
                }
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "openQANextUrl: returns next URL" {
    const allocator = testing.allocator;
    const header = "</api/v1/jobs?offset=10>; rel=\"next\", </api/v1/jobs?offset=0>; rel=\"first\"";
    const next = try openQANextUrl(allocator, header);
    defer if (next) |n| allocator.free(n);
    try testing.expect(next != null);
    try testing.expectEqualStrings("/api/v1/jobs?offset=10", next.?);
}

test "openQANextUrl: returns null when no next relation" {
    const allocator = testing.allocator;
    const header = "</api/v1/jobs?offset=0>; rel=\"first\"";
    const next = try openQANextUrl(allocator, header);
    try testing.expect(next == null);
}

test "openQANextUrl: empty header returns null" {
    const allocator = testing.allocator;
    const next = try openQANextUrl(allocator, "");
    try testing.expect(next == null);
}

test "re-exports: APIResponse and normalizePathQuery accessible via zoqa" {
    // Verify the re-exports compile and are accessible.
    const T = APIResponse;
    _ = T;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    try normalizePathQuery("/api/v1/jobs?name=hello%20world", buf.writer(testing.allocator));
    try testing.expectEqualStrings("/api/v1/jobs?name=hello+world", buf.items);
}
