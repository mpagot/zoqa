const std = @import("std");
const config = @import("config.zig");
const http_client = @import("http_client.zig");

pub const JobState = enum {
    scheduled,
    running,
    uploading,
    done,
    cancelled,
    unknown,
};

pub const JobResult = enum {
    none,
    passed,
    softfailed,
    failed,
    incomplete,
    user_cancelled,
    parallel_failed,
    unknown,
};

pub const JobStatus = struct {
    state: JobState,
    result: JobResult,
    /// Raw state string returned by the API (useful for printing)
    raw_state: []const u8,

    pub fn isTerminal(self: JobStatus) bool {
        return self.state == .done or self.state == .cancelled;
    }

    pub fn isSuccess(self: JobStatus) bool {
        return self.result == .passed or self.result == .softfailed;
    }
};

fn parseState(s: []const u8) JobState {
    return std.meta.stringToEnum(JobState, s) orelse .unknown;
}

fn parseResult(s: []const u8) JobResult {
    return std.meta.stringToEnum(JobResult, s) orelse .unknown;
}

/// Single HTTP call to check the status of a job.
/// Returns a parsed JobStatus. The caller is responsible for polling.
///
/// `client` is duck-typed: production callers pass `*std.http.Client`; fuzz
/// harnesses pass a `*ProgrammableMockClient` (see `tests/fuzz/mock_client.zig`).
/// Forwarded to `http_client.openQAReq`, which already accepts `anytype`.
pub fn checkJobStatus(
    allocator: std.mem.Allocator,
    client: anytype,
    host: []const u8,
    job_id: u64,
    follow: bool,
    call_options: http_client.CallOptions,
) !JobStatus {
    const path_query = if (follow)
        try std.fmt.allocPrint(allocator, "experimental/jobs/{d}/status?follow=1", .{job_id})
    else
        try std.fmt.allocPrint(allocator, "experimental/jobs/{d}/status", .{job_id});
    defer allocator.free(path_query);

    // Ensure method is GET
    var options = call_options;
    options.method = .GET;

    const resp = try http_client.openQAReq(host, path_query, options, client);
    defer resp.deinit();

    if (resp.status != .ok) {
        return error.HttpError;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        return error.InvalidJson;
    }

    const obj = parsed.value.object;

    const state_str = if (obj.get("state")) |s| switch (s) {
        .string => |v| v,
        else => "unknown",
    } else "unknown";

    const result_str = if (obj.get("result")) |r| switch (r) {
        .string => |v| v,
        else => "none",
    } else "none";

    // Allocate raw_state so the caller can print it even after we return
    // (since it might be "unknown" or some new state the enum doesn't have)
    const raw_state = try allocator.dupe(u8, state_str);

    return JobStatus{
        .state = parseState(state_str),
        .result = parseResult(result_str),
        .raw_state = raw_state,
    };
}

/// Compute the CLI exit code
/// 0: all passed/softfailed
/// 2: at least one job failed/incomplete/cancelled
/// (Exit code 1 for network/API errors should be handled by the caller before this)
pub fn exitCodeForStatuses(statuses: []const JobStatus) u8 {
    for (statuses) |s| {
        if (s.state == .cancelled or !s.isSuccess()) {
            return 2;
        }
    }
    return 0;
}

test "exitCodeForStatuses - all passed" {
    const statuses = [_]JobStatus{
        .{ .state = .done, .result = .passed, .raw_state = "done" },
        .{ .state = .done, .result = .softfailed, .raw_state = "done" },
    };
    try std.testing.expectEqual(@as(u8, 0), exitCodeForStatuses(&statuses));
}

test "exitCodeForStatuses - one failed" {
    const statuses = [_]JobStatus{
        .{ .state = .done, .result = .passed, .raw_state = "done" },
        .{ .state = .done, .result = .failed, .raw_state = "done" },
    };
    try std.testing.expectEqual(@as(u8, 2), exitCodeForStatuses(&statuses));
}

test "exitCodeForStatuses - cancelled state returns 2 regardless of result" {
    const statuses = [_]JobStatus{
        .{ .state = .done, .result = .passed, .raw_state = "done" },
        // Cancelled jobs should exit 2 even if result is somehow "passed" or "none"
        .{ .state = .cancelled, .result = .passed, .raw_state = "cancelled" },
    };
    try std.testing.expectEqual(@as(u8, 2), exitCodeForStatuses(&statuses));
}

// ---------------------------------------------------------------------------
// MonitorOptions & runMonitor — library entry point for the monitoring loop
// ---------------------------------------------------------------------------

/// Configuration for the monitoring loop. Mirrors the CLI flags of the
/// `monitor` subcommand (§14) and is reused by `schedule --monitor` (§15.7).
pub const MonitorOptions = struct {
    credentials: ?config.Credentials = null,
    quiet: bool = false,
    retries: u32 = 0,
    connect_timeout_s: f64 = 30.0,
    retry_sleep_s: f64 = 3.0,
    retry_factor: f64 = 1.0,
    follow: bool = false,
    poll_interval: u64 = 10,
};

/// Blocking monitoring loop: polls each job until all reach a terminal state.
///
/// `client` is duck-typed: see `checkJobStatus` for the contract.
///
/// Returns the exit code:
///   0 — all jobs passed or softfailed
///   1 — API/network error during polling
///   2 — at least one job failed/cancelled
pub fn runMonitor(
    allocator: std.mem.Allocator,
    client: anytype,
    host: []const u8,
    job_ids: []const u64,
    options: MonitorOptions,
) !u8 {
    var completed = try allocator.alloc(bool, job_ids.len);
    defer allocator.free(completed);
    @memset(completed, false);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var final_statuses: std.ArrayList(JobStatus) = .empty;
    defer {
        for (final_statuses.items) |s| allocator.free(s.raw_state);
        final_statuses.deinit(allocator);
    }

    while (true) {
        var any_pending = false;

        for (job_ids, 0..) |job_id, i| {
            if (completed[i]) continue;

            const status = checkJobStatus(
                allocator,
                client,
                host,
                job_id,
                options.follow,
                .{
                    .allocator = allocator,
                    .credentials = options.credentials,
                    .retries = options.retries,
                    .quiet = options.quiet,
                    .connect_timeout_s = options.connect_timeout_s,
                    .retry_sleep_s = options.retry_sleep_s,
                    .retry_factor = options.retry_factor,
                },
            ) catch |err| {
                if (!options.quiet) {
                    std.debug.print("API error checking job {d}: {s}\n", .{ job_id, @errorName(err) });
                }
                return 1;
            };

            if (status.isTerminal()) {
                completed[i] = true;
                try final_statuses.append(allocator, status);
            } else {
                any_pending = true;
                stdout.print("Job state of job ID {d}: {s}, waiting {d} seconds (poll interval: {d})\n", .{
                    job_id, status.raw_state, options.poll_interval, options.poll_interval,
                }) catch {};
                stdout.flush() catch {};
                allocator.free(status.raw_state);
            }
        }

        if (!any_pending) break;

        std.Thread.sleep(options.poll_interval * std.time.ns_per_s);
    }

    return exitCodeForStatuses(final_statuses.items);
}
