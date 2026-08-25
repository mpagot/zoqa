// Fuzz harness for the schedule subcommand library entry point
// (src/schedule.zig: runSchedule + extractJobIds + checkFailedEntries +
//  asyncPollAndMonitor; src/monitor.zig: runMonitor + checkJobStatus)
// via a duck-typed mock HTTP client with scripted response sequences.
//
// ---------------------------------------------------------------------------
// Corpus format
// ---------------------------------------------------------------------------
//
// Sections separated by "\x00" (null byte). Strictly requires at least 2 sections:
//
//   Byte 0: option byte (controls scenario mode and HTTP knobs)
//   Section 0..N-2: scripted POST/poll response bodies (at least 1, the POST response)
//   Section N-1: fallback response body (always returned after scripted bodies are exhausted)
//
// option byte bits:
//   bit 0 (0x01): enable_monitor — if set, monitor_jobs=true. Exercises
//                 the monitoring loop after sync job IDs are extracted.
//   bit 1 (0x02): non_200_status — if set, POST returns HTTP 500 instead
//                 of 200. Exercises the non-2xx error path.
//   bit 2 (0x04): enable_retries — if set, retries=2 and fail_attempts=1
//                 so the first request fails then succeeds on retry.
//   bit 3 (0x08): enable_credentials — if set, provides API key/secret
//                 to exercise HMAC-SHA1 auth header construction.
//
// When monitor_jobs=true and the POST response contains sync IDs, the
// harness uses scripted bodies: Section 0 is the initial POST response,
// Sections 1..N-2 become successive responses to the monitor's status-polling requests.
// Each poll response should be a JSON object like {"state":"done","result":"passed"}.
// The last section (Section N-1) is the fallback response body.
//
// When the POST response contains a scheduled_product_id (async path),
// the harness enters asyncPollAndMonitor. Sections 1..N-2 become poll
// responses. The last section (Section N-1) is the fallback response body.
//
// ---------------------------------------------------------------------------
// Safety
// ---------------------------------------------------------------------------
//
// The harness uses poll_interval=0 to eliminate sleep between poll
// iterations. To prevent infinite loops when the state machine receives non-terminal
// states indefinitely, the final section (Section N-1) must be a terminal fallback
// response body (e.g. {"status":"cancelled","state":"cancelled"}).
//
// All output goes to a fixed-buffer writer (not stdout) to avoid
// non-deterministic I/O that would reduce AFL++ stability.

const std = @import("std");
const zoqa = @import("zoqa");
const mock_client = @import("mock_client.zig");

const ProgrammableMockClient = mock_client.ProgrammableMockClient;

// ---------------------------------------------------------------------------
// zig_fuzz_init — called once per AFL++ worker process
// ---------------------------------------------------------------------------

var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
var arena_impl: std.heap.ArenaAllocator = .{
    .child_allocator = undefined,
    .state = .{},
};

pub export fn zig_fuzz_init() void {
    arena_impl.child_allocator = gpa_impl.allocator();
}

// ---------------------------------------------------------------------------
// zig_fuzz_test — called in a tight loop by AFL++ persistent mode
// ---------------------------------------------------------------------------

// Maximum number of scripted response bodies to prevent unbounded stack
// usage from very large fuzz inputs.
const MAX_SCRIPTED_BODIES = 8;

pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const arena = arena_impl.allocator();
    _ = arena_impl.reset(.retain_capacity);

    const input = buf[0..@intCast(len)];
    if (input.len < 2) return; // need at least option byte + 1 body byte

    // ------------------------------------------------------------------
    // Decode option byte
    // ------------------------------------------------------------------
    const opt: u8 = input[0];
    const enable_monitor: bool = (opt & 0x01) != 0;
    const non_200_status: bool = (opt & 0x02) != 0;
    const enable_retries: bool = (opt & 0x04) != 0;
    const enable_creds: bool = (opt & 0x08) != 0;

    // ------------------------------------------------------------------
    // Split remaining input on \x00 into sections
    // ------------------------------------------------------------------
    const payload = input[1..];
    var sections: [MAX_SCRIPTED_BODIES + 1][]const u8 = undefined;
    var section_count: usize = 0;
    var start: usize = 0;
    for (payload, 0..) |byte, i| {
        if (byte == 0 and section_count < MAX_SCRIPTED_BODIES) {
            sections[section_count] = payload[start..i];
            section_count += 1;
            start = i + 1;
        }
    }
    // Last section (or the only one if no null bytes)
    if (start <= payload.len and section_count <= MAX_SCRIPTED_BODIES) {
        sections[section_count] = payload[start..];
        section_count += 1;
    }
    // Must have at least 2 sections: 1 or more scripted response(s) + 1 fallback response body.
    if (section_count <= 1) return;

    // sections[0..N-1] are the scripted POST/poll response bodies; sections[N-1] is the fallback response body.
    const fallback_body = sections[section_count - 1];
    const bodies_count = section_count - 1;
    const next_bodies_slice = sections[0..bodies_count];

    // ------------------------------------------------------------------
    // Configure mock
    // ------------------------------------------------------------------
    const creds: ?zoqa.config.Credentials = if (enable_creds)
        .{ .allocator = arena, .key = "fuzzkey1234567890", .secret = "fuzzsecret0987654321" }
    else
        null;

    // Scripted statuses: first entry matches POST status, rest are 200 for polls.
    // If non_200_status, the POST returns 500 (exercises non-2xx path).
    var scripted_statuses: [MAX_SCRIPTED_BODIES + 1]std.http.Status = undefined;
    scripted_statuses[0] = if (non_200_status) .internal_server_error else .ok;
    for (1..bodies_count) |i| {
        scripted_statuses[i] = .ok;
    }

    var mock = ProgrammableMockClient{
        .fail_attempts = if (enable_retries) 1 else 0,
        .response_status = .ok,
        .response_body = fallback_body,
        .next_bodies = if (bodies_count > 0) next_bodies_slice else null,
        .next_statuses = if (bodies_count > 0) scripted_statuses[0..bodies_count] else null,
    };
    // Use a fixed-buffer writer to avoid non-deterministic I/O.
    var null_buf: [4096]u8 = undefined;
    var null_writer: std.Io.Writer = .fixed(&null_buf);

    _ = zoqa.runSchedule(
        arena,
        &mock,
        "http://localhost",
        "DISTRI=opensuse&VERSION=Tumbleweed",
        .{
            .credentials = creds,
            .quiet = true,
            .retries = if (enable_retries) @as(u32, 2) else @as(u32, 0),
            .retry_sleep_s = 0,
            .retry_factor = 1.0,
            .monitor_jobs = enable_monitor,
            .follow = false,
            .poll_interval = 0, // no sleep between polls
            .output_writer = &null_writer,
        },
    ) catch return;
}
