// Fuzz harness for the full openQA request execution pipeline
// (src/http_client.zig: execute, executeStream, normalizePathQuery,
//  sleepForRetry; src/auth.zig: buildAuthHeaders, hmacSha1Hex)
// via zoqa.openQAReq and zoqa.openQARawGet with a ProgrammableMockClient.
//
// ---------------------------------------------------------------------------
// Corpus format
// ---------------------------------------------------------------------------
//
// Five sections separated by "\n---\n":
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
//   Section 5: optional Link header value / streaming control
//   <stream_ctrl_byte><content_length_hi><content_length_lo><partial_body_byte><link_header_value>
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
//     bit 3 (0x08):    emit_link_header — if set, mock emits a Link header
//                      whose value is section 5 content after stream_ctrl bytes.
//     bit 4 (0x10):    use_structured_ct — if CLEAR, the mock's head.content_type
//                      is set to null, exercising the structured-field fallback
//                      path in http_client.zig.
//     bit 5 (0x20):    inject_read_failed — if set, streamRemaining returns
//                      error.ReadFailed on first call.
//     bit 6 (0x40):    include_accept_header — if set, an Accept header is
//                      added to extra_headers, exercising the "Accept already
//                      present" check in buildHeaders.
//     bit 7 (0x80):    use_streaming — if set, also exercise the streaming
//                      path (openQARawGet → executeStream). Section 5 bytes
//                      control content_length and partial delivery.
//
//   status_hi, status_lo: u16 HTTP status code (big-endian). If both are 0,
//   defaults to 200. Values outside 100–599 are clamped to 200.
//
//   stream_ctrl_byte (section 5, byte 0 — only when ctrl bit 7 set):
//     bits 0-1 (0x03): content_length mode:
//                      0 = null (no Content-Length)
//                      1 = exact match (body.len)
//                      2 = larger than body (triggers HttpTransferTruncated)
//                      3 = from section 5 bytes 1-2 (big-endian u16)
//     bit 2 (0x04):    enable partial delivery (partial_body_len = half of body)
//     bit 3 (0x08):    set size_limit to 100 (exercises FileTooLarge path)
//
//   content_length_hi, content_length_lo (section 5, bytes 1-2):
//     Raw u16 content_length value, only used when stream_ctrl mode == 3.
//
//   partial_body_byte (section 5, byte 3):
//     When stream_ctrl bit 2 is set, this byte controls partial_body_len:
//     0 = half of body length, non-zero = use this byte value directly.
//
// If fewer than 5 sections are present, missing sections use safe defaults
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
    const rest3 = if (s3_end + sep.len <= rest2.len) rest2[s3_end + sep.len ..] else "";

    // Section 4: optional gzip bytes
    const s4_end = std.mem.indexOf(u8, rest3, sep) orelse rest3.len;
    const section4 = rest3[0..s4_end];

    // Section 5: streaming control + optional Link header value
    const section5 = if (s4_end + sep.len <= rest3.len) rest3[s4_end + sep.len ..] else "";

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
    const emit_link: bool = (ctrl & 0x08) != 0;
    const use_structured_ct: bool = (ctrl & 0x10) == 0; // bit CLEAR = use structured
    const inject_read_failed: bool = (ctrl & 0x20) != 0;
    const include_accept: bool = (ctrl & 0x40) != 0;
    const use_streaming: bool = (ctrl & 0x80) != 0;

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
    // Decode section 5: streaming control + Link header value
    // ------------------------------------------------------------------
    // When streaming is enabled (ctrl bit 7), the first 4 bytes of section 5
    // encode streaming parameters; the remainder is the Link header value.
    // When streaming is disabled, all of section 5 is the Link header value.
    const stream_ctrl: u8 = if (use_streaming and section5.len > 0) section5[0] else 0;
    const link_header_start: usize = if (use_streaming) @min(@as(usize, 4), section5.len) else 0;
    const link_value: []const u8 = if (section5.len > link_header_start) section5[link_header_start..] else "";

    // Streaming: content_length mode
    const content_length_mode: u8 = stream_ctrl & 0x03;
    const response_content_length: ?u64 = if (!use_streaming) null else switch (content_length_mode) {
        0 => null, // no Content-Length
        1 => response_body.len, // exact match
        2 => response_body.len + 100, // larger → triggers HttpTransferTruncated
        3 => if (section5.len >= 3) // raw u16 from section 5 bytes 1-2
            (@as(u64, section5[1]) << 8) | @as(u64, section5[2])
        else
            null,
        else => unreachable,
    };

    // Streaming: partial delivery
    const enable_partial: bool = use_streaming and (stream_ctrl & 0x04) != 0;
    const partial_body_len: ?usize = if (!enable_partial) null else blk: {
        const explicit: u8 = if (section5.len >= 4) section5[3] else 0;
        break :blk if (explicit > 0)
            @as(usize, explicit)
        else
            response_body.len / 2;
    };

    // Streaming: size_limit
    const size_limit: ?u64 = if (use_streaming and (stream_ctrl & 0x08) != 0) 100 else null;

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
        .response_content_length = response_content_length,
        .partial_body_len = partial_body_len,
        .link_header = if (emit_link and link_value.len > 0) link_value else null,
        .use_structured_ct = use_structured_ct,
        .inject_read_failed = inject_read_failed,
    };

    // Build extra_headers: optionally include Accept to exercise Gap 7.
    const accept_hdr: [1]std.http.Header = .{.{ .name = "Accept", .value = "text/plain" }};
    const extra_headers: []const std.http.Header = if (include_accept) &accept_hdr else &.{};

    const resp = zoqa.openQAReq(
        "http://localhost",
        raw_path_query,
        .{
            .allocator = allocator,
            .method = method,
            .params = params,
            .credentials = creds,
            .headers = extra_headers,
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

    // ------------------------------------------------------------------
    // Streaming path: openQARawGet → executeStream
    // ------------------------------------------------------------------
    // When ctrl bit 7 is set, also exercise the streaming execution path.
    // This covers: Content-Length validation, HttpTransferTruncated,
    // LengthRequired, FileTooLarge, and the pre-stream retry loop in
    // executeStream — none of which are reachable via openQAReq/execute.
    if (use_streaming) {
        // Reset mock state for the second call (attempt counter, scripted index).
        mock.attempt = 0;
        mock.response = undefined;
        // Disable gzip for streaming (executeStream sets accept_gzip=false).
        mock.response_gzip = false;
        // Keep inject_read_failed for the streaming path too.

        var discard_buf: [4096]u8 = undefined;
        var stream_writer: std.Io.Writer = .fixed(&discard_buf);
        var cl_out: ?u64 = null;

        _ = zoqa.openQARawGet(
            "http://localhost",
            raw_path_query,
            .{
                .allocator = allocator,
                .credentials = creds,
                .size_limit = size_limit,
                .quiet = true,
                .retries = 3,
                .retry_sleep_s = 0,
            },
            &mock,
            &stream_writer,
            &cl_out,
        ) catch return;
    }
}
