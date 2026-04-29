// Fuzz harness for the full openQA request execution pipeline
// (src/http_client.zig: execute, normalizePathQuery, sleepForRetry;
//  src/auth.zig: buildAuthHeaders, hmacSha1Hex)
// via zoqa.openQAReq with a ProgrammableMockClient.
//
// ---------------------------------------------------------------------------
// Corpus format
// ---------------------------------------------------------------------------
//
// Four sections separated by "\n---\n":
//
//   Section 1: credentials + path
//   <api_key>\n<api_secret>\n<path_query>
//
//   Section 2: method + params
//   <method_byte><params>
//
//   Section 3: response control
//   <ctrl_byte><status_hi><status_lo><response_body>
//
//   Section 4: optional raw gzip bytes
//   <raw_gzip_bytes>
//
// Field encoding:
//
//   method_byte:
//     0x00 → GET, 0x01 → POST, 0x02 → PUT, 0x03 → DELETE, 0x04 → PATCH
//     Any other value → GET (fallback)
//
//   ctrl_byte bits:
//     bits 0-1 (0x03): fail_attempts — number of times request() returns error
//                      before succeeding (0–3). Exercises the retry loop.
//     bit 2 (0x04):    use_gzip — if set, mock returns Content-Encoding: gzip
//                      header and the section 4 bytes as body.
//
//   status_hi, status_lo: u16 HTTP status code (big-endian). If both are 0,
//   defaults to 200. Values outside 100–599 are clamped to 200.
//
// If fewer than 4 sections are present, missing sections use safe defaults
// (empty strings, zero bytes).
//
// ---------------------------------------------------------------------------
// zig_fuzz_init
// ---------------------------------------------------------------------------
//
// No setup needed. The harness sets `retry_sleep_s = 0` directly on the
// CallOptions passed to openQAReq below — env vars (OPENQA_CLI_RETRY_*) are
// only read by main.zig's CLI parsing layer and never reach the library code.
//
// ---------------------------------------------------------------------------
// ProgrammableMockClient
// ---------------------------------------------------------------------------
//
// Drives openQAReq through a duck-typed MockClient with knobs for:
//   - fail_attempts: returns error.ConnectionRefused N times before succeeding
//   - response_status: configurable HTTP status code
//   - response_gzip: when true, includes Content-Encoding: gzip header
//   - response_body: configurable response body bytes
//
// This exercises:
//   - retry loop in execute() (via fail_attempts)
//   - normalizePathQuery + buildAuthHeaders (via HMAC signing path)
//   - gzip decompression path (via response_gzip)
//   - non-2xx status handling (via response_status)
//   - JSON parse/stringify path (via JSON-shaped body on success)
//
const std = @import("std");
const zoqa = @import("zoqa");
const mock_client = @import("mock_client.zig");

const ProgrammableMockClient = mock_client.ProgrammableMockClient;

// ---------------------------------------------------------------------------
// zig_fuzz_init — called once per AFL++ worker process
// ---------------------------------------------------------------------------

pub export fn zig_fuzz_init() void {}

// ---------------------------------------------------------------------------
// zig_fuzz_test — called in a tight loop by AFL++ persistent mode
// ---------------------------------------------------------------------------

pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const input = buf[0..@intCast(len)];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Split into up to 4 sections on "\n---\n".
    const sep = "\n---\n";

    // Section 1: credentials + path
    const s1_end = std.mem.indexOf(u8, input, sep) orelse input.len;
    const section1 = input[0..s1_end];
    const rest1 = if (s1_end + sep.len <= input.len) input[s1_end + sep.len ..] else "";

    // Section 2: method + params
    const s2_end = std.mem.indexOf(u8, rest1, sep) orelse rest1.len;
    const section2 = rest1[0..s2_end];
    const rest2 = if (s2_end + sep.len <= rest1.len) rest1[s2_end + sep.len ..] else "";

    // Section 3: response control
    const s3_end = std.mem.indexOf(u8, rest2, sep) orelse rest2.len;
    const section3 = rest2[0..s3_end];
    const section4 = if (s3_end + sep.len <= rest2.len) rest2[s3_end + sep.len ..] else "";

    // ------------------------------------------------------------------
    // Decode section 1: api_key / api_secret / path_query
    // ------------------------------------------------------------------
    const first_nl = std.mem.indexOfScalar(u8, section1, '\n');
    const api_key: []const u8 = if (first_nl) |p| section1[0..p] else section1;
    const after_key: []const u8 = if (first_nl) |p| section1[p + 1 ..] else "";

    const second_nl = std.mem.indexOfScalar(u8, after_key, '\n');
    const api_secret: []const u8 = if (second_nl) |p| after_key[0..p] else after_key;
    var raw_path_query: []const u8 = if (second_nl) |p| after_key[p + 1 ..] else "";

    // Sanitize null bytes in path (std.Uri.parse rejects them).
    var path_buf: [512]u8 = undefined;
    const path_len: usize = @min(raw_path_query.len, @as(usize, path_buf.len - 1));
    path_buf[0] = '/';
    @memcpy(path_buf[1 .. path_len + 1], raw_path_query[0..path_len]);
    for (path_buf[1 .. path_len + 1]) |*c| {
        if (c.* == 0) c.* = '_';
    }
    raw_path_query = path_buf[0 .. path_len + 1];

    // ------------------------------------------------------------------
    // Decode section 2: method_byte + params
    // ------------------------------------------------------------------
    const method: std.http.Method = if (section2.len > 0) switch (section2[0]) {
        0x01 => .POST,
        0x02 => .PUT,
        0x03 => .DELETE,
        0x04 => .PATCH,
        else => .GET,
    } else .GET;
    const params: []const u8 = if (section2.len > 1) section2[1..] else "";

    // ------------------------------------------------------------------
    // Decode section 3: ctrl_byte + status + response_body
    // ------------------------------------------------------------------
    const ctrl: u8 = if (section3.len > 0) section3[0] else 0;
    const fail_attempts: u8 = ctrl & 0x03;
    const use_gzip: bool = (ctrl & 0x04) != 0;

    var status_code: u16 = 200;
    if (section3.len >= 3) {
        const raw: u16 = (@as(u16, section3[1]) << 8) | @as(u16, section3[2]);
        if (raw >= 100 and raw <= 599) status_code = raw;
    }
    const http_status: std.http.Status = @enumFromInt(status_code);

    // Body: gzip path uses section 4 bytes; plain path uses bytes after ctrl+status.
    const plain_body: []const u8 = if (section3.len > 3) section3[3..] else "{}";
    const response_body: []const u8 = if (use_gzip) section4 else plain_body;

    // ------------------------------------------------------------------
    // Run openQAReq with the programmable mock
    // ------------------------------------------------------------------
    const creds = if (api_key.len > 0 and api_secret.len > 0)
        zoqa.config.Credentials{ .allocator = allocator, .key = api_key, .secret = api_secret }
    else
        null;

    var mock = ProgrammableMockClient{
        .fail_attempts = fail_attempts,
        .response_status = http_status,
        .response_gzip = use_gzip,
        .response_body = response_body,
    };

    const resp = zoqa.openQAReq(
        "http://localhost",
        raw_path_query,
        .{
            .allocator = allocator,
            .method = method,
            .params = params,
            .credentials = creds,
            // Up to 3 retries — matches fail_attempts range (0–3).
            .retries = 3,
            .quiet = true,
            // Skip the production 3-second backoff between retry attempts so
            // AFL persistent-mode iterations stay in the microsecond range.
            // Must be set on the struct directly: env vars are only read by
            // main.zig's CLI parser, never by the library code.
            .retry_sleep_s = 0,
        },
        &mock,
    ) catch return;
    resp.deinit();
}
