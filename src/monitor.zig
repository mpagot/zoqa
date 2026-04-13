const std = @import("std");
const zoqa = @import("root.zig");

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
pub fn checkJobStatus(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    host: []const u8,
    job_id: u64,
    follow: bool,
    call_options: zoqa.CallOptions,
) !JobStatus {
    const path_query = if (follow)
        try std.fmt.allocPrint(allocator, "experimental/jobs/{d}/status?follow=1", .{job_id})
    else
        try std.fmt.allocPrint(allocator, "experimental/jobs/{d}/status", .{job_id});
    defer allocator.free(path_query);

    // Ensure method is GET
    var options = call_options;
    options.method = .GET;

    const resp = try zoqa.openQAReq(host, path_query, options, client);
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

/// Compute the CLI exit code according to SPEC §14.5.
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
