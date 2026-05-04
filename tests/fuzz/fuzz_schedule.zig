// Fuzz harness for the schedule subcommand library entry point
// (src/schedule.zig: runSchedule + extractJobIds + checkFailedEntries) via a
// duck-typed mock HTTP client.
//
// ---------------------------------------------------------------------------
// STATUS: stub
// ---------------------------------------------------------------------------
//
// This is a minimal harness that compiles, links against the AFL++ runtime,
// and validates the runSchedule public API can be driven with the shared
// ProgrammableMockClient. The fuzz input is fed verbatim as the POST response
// body; all other knobs (status, retries, async/monitor) are fixed.
//
// Concretely, this stub exercises:
//   - JSON parse of the response (any malformed body returns 1 cleanly)
//   - The .object type-narrowing switch in runSchedule
//   - checkFailedEntries (when input contains a "failed" object)
//   - extractJobIds (when input contains a non-empty "ids" array)
//   - The known @intCast panic on negative integers in "ids"
//
// It does NOT yet exercise:
//   - Async path (scheduled_product_id) — needs a multi-response mock
//   - asyncPollAndMonitor's polling state machine
//   - runMonitor integration (monitor_jobs=true)
//   - HTTP status variations (always 200)
//   - Retry loop (always 0 retries)
//
// ---------------------------------------------------------------------------
// Planned next iteration
// ---------------------------------------------------------------------------
//
// Extend ProgrammableMockClient in mock_client.zig with a scripted-response
// array (next_bodies: []const []const u8), then split fuzz input into
// sections: <opt_byte> <ctrl_byte+status+post_body> <poll_body>. See
// ideas/HARNESS_AUDIT.md for the full corpus design and the six target seeds.

const std = @import("std");
const zoqa = @import("zoqa");
const mock_client = @import("mock_client.zig");

const ProgrammableMockClient = mock_client.ProgrammableMockClient;

// ---------------------------------------------------------------------------
// zig_fuzz_init — called once per AFL++ worker process
// ---------------------------------------------------------------------------

var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
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

pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const arena = arena_impl.allocator();
    _ = arena_impl.reset(.retain_capacity);

    const input = buf[0..@intCast(len)];

    // Use the entire input as the POST response body. Sync path only.
    var mock = ProgrammableMockClient{
        .response_body = input,
    };

    // Use a null writer to avoid non-deterministic I/O from real stdout.
    // Writing to AFL++'s pipe causes variable edge coverage depending on
    // kernel pipe buffer state — the root cause of the 83.91% stability.
    var null_buf: [4096]u8 = undefined;
    var null_writer: std.Io.Writer = .fixed(&null_buf);

    _ = zoqa.runSchedule(
        arena,
        &mock,
        "http://localhost",
        "DISTRI=opensuse&VERSION=Tumbleweed",
        .{
            .quiet = true,
            .retries = 0,
            .retry_sleep_s = 0,
            .monitor_jobs = false,
            .output_writer = &null_writer,
        },
    ) catch return;
}
