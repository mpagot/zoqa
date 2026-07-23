const std = @import("std");
const config = @import("config.zig");
const http_client = @import("http_client.zig");
const monitor = @import("monitor.zig");

/// Configuration for `runSchedule`. Covers the POST to `/api/v1/isos`,
/// response handling (sync and async paths), and optional monitoring.
pub const ScheduleOptions = struct {
    credentials: ?config.Credentials = null,
    quiet: bool = false,
    retries: u32 = 0,
    connect_timeout_s: f64 = 30.0,
    retry_sleep_s: f64 = 3.0,
    retry_factor: f64 = 1.0,
    /// When true, after scheduling, wait for all resulting jobs to finish.
    monitor_jobs: bool = false,
    /// Follow newest clone of each job (modifier for monitoring).
    follow: bool = false,
    /// Polling interval in seconds when monitoring is active.
    /// Default is 1s for schedule (vs 10s for standalone monitor per §14.2).
    poll_interval: u64 = 1,
    /// User-Agent header value.
    name: []const u8 = "openQAclient",
    /// Optional output writer. When null (default), runSchedule writes to
    /// real stdout. Fuzz harnesses pass a no-op writer to eliminate I/O
    /// non-determinism (AFL++ pipe buffer state varies between runs).
    output_writer: ?*std.Io.Writer = null,
};

// runSchedule — library entry point for the schedule subcommand

/// Execute the full `schedule` flow:
///   1. POST `/api/v1/isos` with form-encoded params.
///   2. Handle synchronous response (extract `ids`) or async response
///      (`scheduled_product_id` without `ids`).
///   3. Print job URLs to stdout
///   4. If `--monitor` is active and job IDs are available (sync or after
///      async polling), enter the monitoring loop.
///
/// Parameters:
///   - allocator: used for JSON parsing and string formatting.
///   - client: duck-typed HTTP client compatible with `http_client.openQAReq`.
///   - host: the resolved base URL of the target openQA instance.
///   - params_encoded: form-encoded parameter string for the POST body.
///   - options: credentials, retries, output, and monitoring settings
///     (see `ScheduleOptions`).
///
/// Returns: The exit code per:
///   - `0` — jobs scheduled successfully (without monitoring), or all passed/softfailed.
///   - `1` — scheduling error, network error, server error.
///   - `2` — any monitored job failed/cancelled.
///
/// Errors:
///   - Any allocator or I/O error from nested monitor execution or extraction routines.
pub fn runSchedule(
    /// Used for JSON parsing and string formatting.
    allocator: std.mem.Allocator,
    /// Duck-typed HTTP client. Production callers pass `*std.http.Client`;
    /// fuzz harnesses pass a `*ProgrammableMockClient` (see
    /// `tests/fuzz/mock_client.zig`). Forwarded to `http_client.openQAReq`,
    /// which already accepts `anytype`.
    client: anytype,
    /// The resolved base URL of the target openQA instance.
    host: []const u8,
    /// Form-encoded parameter string for the POST request body.
    params_encoded: []const u8,
    /// Execution options governing credentials, retries, output, and monitoring.
    options: ScheduleOptions,
) !u8 {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = options.output_writer orelse &stdout_writer.interface;

    // POST /api/v1/isos
    const resp = http_client.openQAReq(host, "isos", .{
        .allocator = allocator,
        .method = .POST,
        .params = params_encoded,
        .credentials = options.credentials,
        .retries = options.retries,
        .quiet = options.quiet,
        .connect_timeout_s = options.connect_timeout_s,
        .retry_sleep_s = options.retry_sleep_s,
        .retry_factor = options.retry_factor,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "User-Agent", .value = options.name },
        },
    }, client) catch |err| {
        if (!options.quiet) std.debug.print("schedule: POST /api/v1/isos failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer resp.deinit();

    // Check HTTP status
    const status_code = @intFromEnum(resp.status);
    if (status_code < 200 or status_code >= 300) {
        if (!options.quiet) {
            std.debug.print("schedule: server returned HTTP {d}\n", .{status_code});
            if (resp.body.len > 0) std.debug.print("{s}\n", .{resp.body});
        }
        return 1;
    }

    // Parse JSON response
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch {
        if (!options.quiet) std.debug.print("schedule: invalid JSON in response\n", .{});
        return 1;
    };
    defer parsed.deinit();

    // The JSON parser returns a `std.json.Value`, which is a tagged union —
    // it can hold one of several types (.object, .array, .string, .integer, etc.).
    //
    // This switch expression does three things in one line:
    //
    //   .object => |o| o,
    //   ^^^^^^^    ^^^  ^
    //     │         │   └─ (3) Return expression: pass the captured ObjectMap
    //     │         │       through as the value of the whole switch expression,
    //     │         │       which gets assigned to `root`.
    //     │         │
    //     │         └─ (2) Payload capture: the .object variant carries an inner
    //     │              value of type std.json.ObjectMap (a hashmap of string
    //     │              keys → JSON values). The |o| syntax extracts that inner
    //     │              data and binds it to the local name `o`.
    //     │
    //     └─ (1) Switch prong: matches the .object variant of the tagged union.
    //          "Prong" is Zig's term for one arm/branch of a switch (like "case"
    //          in C).
    //
    //   else => { ... return 1; }
    //     If the JSON is anything other than an object (array, string, number,
    //     null), print an error to stderr (unless --quiet) and return exit code 1.
    //
    // Why use a switch instead of `parsed.value.object` directly? Because
    // accessing the wrong variant of a tagged union is safety-checked undefined
    // behavior in Zig — it would panic at runtime. The switch forces every
    // variant to be handled explicitly at compile time.
    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            if (!options.quiet) std.debug.print("schedule: expected JSON object in response\n", .{});
            return 1;
        },
    };

    // Check for `failed` entries (partial job creation failures).
    if (checkFailedEntries(root)) {
        return 1;
    }

    // Check for top-level `error` string (server-side scheduling error).
    // NOTE: In practice, `error` and non-empty `failed` are mutually exclusive
    // in the openQA server (Iso.pm returns `failed => {}` when `error` is set,
    // and omits `error` entirely on partial success). Both are checked here for
    // robustness against non-standard or future server versions.
    if (root.get("error")) |error_val| {
        if (error_val == .string and error_val.string.len > 0) {
            if (!options.quiet) std.debug.print("{s}\n", .{error_val.string});
            return 1;
        }
    }

    // Extract `ids` array (sync response) or `scheduled_product_id` (async).
    // Distinguish sync-empty-ids (key present, array empty → exit 0 per
    // Perl parity) from async (key absent → scheduled_product_id only).
    const ids_val = root.get("ids");
    const ids_present = ids_val != null;
    const has_ids = if (ids_val) |iv| iv == .array and iv.array.items.len > 0 else false;

    const scheduled_product_id: ?u64 = if (root.get("scheduled_product_id")) |sp| blk: {
        break :blk switch (sp) {
            // std.math.cast returns null on overflow (incl. negative → unsigned),
            // matching the existing `else => null` shape for non-integer values.
            .integer => std.math.cast(u64, sp.integer),
            else => null,
        };
    } else null;

    if (has_ids) {
        // Synchronous response: extract job IDs and print job URLs
        const job_ids = extractJobIds(allocator, options, host, stdout, ids_val.?.array) catch return 1;
        defer allocator.free(job_ids);

        if (!options.monitor_jobs) return 0;

        // Enter monitoring loop
        return monitor.runMonitor(allocator, client, host, job_ids, .{
            .credentials = options.credentials,
            .quiet = options.quiet,
            .retries = options.retries,
            .connect_timeout_s = options.connect_timeout_s,
            .retry_sleep_s = options.retry_sleep_s,
            .retry_factor = options.retry_factor,
            .follow = options.follow,
            .poll_interval = options.poll_interval,
        });
    } else if (ids_present) {
        // Sync response with empty ids array — zero products matched.
        // Matches Perl's _create_jobs which returns 0 when there is neither
        // a top-level `error` nor a non-empty `failed` array (see §15.4
        // step 6). Print the empty-set note for visibility but do NOT
        // override the exit code.
        if (!options.quiet) std.debug.print("schedule: no jobs scheduled\n", .{});
        return 0;
    } else if (scheduled_product_id != null and options.monitor_jobs) {
        // Async response with --monitor: poll for completion
        stdout.flush() catch {};
        return asyncPollAndMonitor(allocator, client, host, scheduled_product_id.?, stdout, options);
    } else if (scheduled_product_id != null) {
        // Async without --monitor: just exit 0 (no output per Perl reference behavior)
        stdout.flush() catch {};
        return 0;
    } else {
        // No ids and no scheduled_product_id — error
        if (!options.quiet) std.debug.print("schedule: no jobs scheduled and no scheduled_product_id in response\n", .{});
        return 1;
    }
}

// Async polling

/// Poll `GET /api/v1/isos/{scheduled_product_id}` until the scheduled product
/// leaves its pending state, then extract job IDs and enter the monitor loop.
///
/// Implements async+monitor path. Called from `runSchedule` when
/// the POST response contains a `scheduled_product_id` and `--monitor` is active.
///
/// Flow:
///   1. Build poll path: `isos/{scheduled_product_id}`.
///   2. Loop forever: GET the path, parse JSON, read the `status` field.
///   3. `"added"` / `"scheduling"` → sleep `options.poll_interval` seconds and repeat.
///   4. `"cancelled"` → print error (always, regardless of `quiet`), return 1.
///   5. `"scheduled"` → check `results.failed`; extract `results.successful_job_ids`
///      via `extractJobIds`; delegate to `monitor.runMonitor`.
///   6. Any other status → print error (unless quiet), return 1.
///
/// No timeout is applied; the loop runs until the product settles. This is
/// intentional and matches the Perl reference (`_wait_for_jobs` also loops
/// indefinitely).
///
/// Parameters:
///   - `allocator`: Used for building the URL path, parsing JSON responses, and allocating job ID arrays.
///   - `client`: Duck-typed HTTP client (same contract as `runSchedule`'s `client`).
///   - `host`: The resolved base URL of the target openQA instance.
///   - `scheduled_product_id`: The product ID returned from the initial scheduling POST.
///   - `stdout`: Writer for outputting job creation summaries and URLs.
///   - `options`: Execution options governing credentials, retries, and the polling interval.
///
/// Returns: The exit code:
///   - `0` — all monitored jobs passed or soft-failed (from `runMonitor`).
///   - `1` — network/parse error, or cancelled/unexpected status.
///   - `2` — one or more monitored jobs failed (from `runMonitor`).
///
/// Errors:
///   - Allocator out-of-memory errors or I/O errors from underlying operations.
fn asyncPollAndMonitor(
    allocator: std.mem.Allocator,
    client: anytype,
    host: []const u8,
    scheduled_product_id: u64,
    stdout: *std.Io.Writer,
    options: ScheduleOptions,
) !u8 {
    const poll_path = try std.fmt.allocPrint(allocator, "isos/{d}", .{scheduled_product_id});
    defer allocator.free(poll_path);

    while (true) {
        const poll_resp = http_client.openQAReq(host, poll_path, .{
            .allocator = allocator,
            .method = .GET,
            .credentials = options.credentials,
            .retries = options.retries,
            .quiet = options.quiet,
            .connect_timeout_s = options.connect_timeout_s,
            .retry_sleep_s = options.retry_sleep_s,
            .retry_factor = options.retry_factor,
        }, client) catch |err| {
            if (!options.quiet) std.debug.print("schedule: polling error: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer poll_resp.deinit();

        var poll_parsed = std.json.parseFromSlice(std.json.Value, allocator, poll_resp.body, .{}) catch {
            if (!options.quiet) std.debug.print("schedule: invalid JSON in poll response\n", .{});
            return 1;
        };
        defer poll_parsed.deinit();

        const poll_obj = switch (poll_parsed.value) {
            .object => |o| o,
            else => {
                if (!options.quiet) std.debug.print("schedule: expected JSON object in poll response\n", .{});
                return 1;
            },
        };

        const status_str = if (poll_obj.get("status")) |s| switch (s) {
            .string => |v| v,
            else => "unknown",
        } else "unknown";

        if (std.mem.eql(u8, status_str, "added") or std.mem.eql(u8, status_str, "scheduling")) {
            // Not ready yet — sleep and repeat
            std.Thread.sleep(options.poll_interval * std.time.ns_per_s);
            continue;
        }

        if (std.mem.eql(u8, status_str, "cancelled")) {
            std.debug.print("Scheduled product {d} ended up cancelled\n", .{scheduled_product_id});
            return 1;
        }

        if (std.mem.eql(u8, status_str, "scheduled")) {
            // Extract results.successful_job_ids
            const results = switch (poll_obj.get("results") orelse {
                if (!options.quiet) std.debug.print("schedule: missing 'results' in poll response\n", .{});
                return 1;
            }) {
                .object => |o| o,
                else => {
                    if (!options.quiet) std.debug.print("schedule: 'results' is not an object\n", .{});
                    return 1;
                },
            };

            // Check for failed entries in results
            if (checkFailedEntries(results)) {
                return 1;
            }

            const job_ids_val = switch (results.get("successful_job_ids") orelse {
                if (!options.quiet) std.debug.print("schedule: missing 'successful_job_ids' in results\n", .{});
                return 1;
            }) {
                .array => |a| a,
                else => {
                    if (!options.quiet) std.debug.print("schedule: 'successful_job_ids' is not an array\n", .{});
                    return 1;
                },
            };

            const job_ids = extractJobIds(allocator, options, host, stdout, job_ids_val) catch return 1;
            defer allocator.free(job_ids);

            // Enter monitoring loop (§15.7)
            return monitor.runMonitor(allocator, client, host, job_ids, .{
                .credentials = options.credentials,
                .quiet = options.quiet,
                .retries = options.retries,
                .connect_timeout_s = options.connect_timeout_s,
                .retry_sleep_s = options.retry_sleep_s,
                .retry_factor = options.retry_factor,
                .follow = options.follow,
                .poll_interval = options.poll_interval,
            });
        }

        // Unknown status — treat as error
        if (!options.quiet) std.debug.print("schedule: unexpected poll status: {s}\n", .{status_str});
        return 1;
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Inspect the `failed` key of a JSON response object and print any error messages.
///
/// Called from both `runSchedule` (on the POST response root) and
/// `asyncPollAndMonitor` (on the `results` sub-object) to surface per-product
/// failures reported by the server.
///
/// If `obj` contains a non-empty `"failed"` object, iterates its entries and
/// prints `"{product_name}: {error_message}\n"` to stderr for each entry that
/// carries an `"error_message"` string field. Output is unconditional —
/// `options.quiet` does not suppress it.
///
/// Parameters:
///   - `obj`: The JSON object map to inspect for a "failed" key.
///
/// Returns: `true` if any failed entries were found (caller should return 1), `false` otherwise.
fn checkFailedEntries(obj: std.json.ObjectMap) bool {
    if (obj.get("failed")) |failed_val| {
        if (failed_val == .object and failed_val.object.count() > 0) {
            var it = failed_val.object.iterator();
            while (it.next()) |entry| {
                const product_name = entry.key_ptr.*;
                if (entry.value_ptr.* == .object) {
                    if (entry.value_ptr.object.get("error_message")) |em| {
                        if (em == .string) {
                            std.debug.print("{s}: {s}\n", .{ product_name, em.string });
                        }
                    }
                }
            }
            return true;
        }
    }
    return false;
}

/// Validate and decode a JSON job-ID array, print the creation summary and
/// per-job URLs to stdout, and return an owned `[]u64` slice.
///
/// Called from two sites:
///   - `runSchedule` (sync path): the `ids` array from the POST response.
///   - `asyncPollAndMonitor` (async path): `results.successful_job_ids` from
///     the poll response.
///
/// Steps:
///   1. If the array is empty, print (unless quiet) and return `error.NoJobsCreated`.
///   2. Print `"1 job has been created:\n"` or `"{N} jobs have been created:\n"`.
///   3. Allocate `[]u64` of length `count`; freed via `errdefer` on any error.
///   4. Iterate: cast each `.integer` element to `u64` via `std.math.cast`,
///      returning `error.InvalidJobId` for negative or non-integer elements.
///   5. Print ` - {host}/tests/{id}` per job.
///   6. Flush stdout.
///   7. Return the slice — **the caller is responsible for freeing it**.
///
/// Parameters:
///   - `allocator`: Used to allocate the returned slice; must outlive the slice.
///   - `options`: Execution options (only `options.quiet` is read).
///   - `host`: Base URL printed in job links (e.g. `"https://openqa.suse.de"`).
///   - `stdout`: Writer for job-creation output.
///   - `job_ids_array`: JSON array of integer job IDs from the server response.
///
/// Returns: An allocated `[]u64` containing the job IDs. The caller owns the slice and must free it.
///
/// Errors:
///   - `error.NoJobsCreated` — if the array is empty.
///   - `error.InvalidJobId` — if an element is not an integer.
///   - Allocator OOM or I/O writer errors.
fn extractJobIds(
    allocator: std.mem.Allocator,
    options: ScheduleOptions,
    host: []const u8,
    stdout: *std.Io.Writer,
    job_ids_array: std.json.Array,
) ![]u64 {
    const count = job_ids_array.items.len;
    if (count == 0) {
        if (!options.quiet) std.debug.print("schedule: no jobs created\n", .{});
        return error.NoJobsCreated;
    }

    if (count == 1) {
        stdout.print("1 job has been created:\n", .{}) catch {};
    } else {
        stdout.print("{d} jobs have been created:\n", .{count}) catch {};
    }

    var job_ids = try allocator.alloc(u64, count);
    errdefer allocator.free(job_ids);

    for (job_ids_array.items, 0..) |id_val, i| {
        const id_int: u64 = switch (id_val) {
            .integer => std.math.cast(u64, id_val.integer) orelse {
                if (!options.quiet) std.debug.print("schedule: negative job ID in response\n", .{});
                return error.InvalidJobId;
            },
            else => {
                if (!options.quiet) std.debug.print("schedule: non-integer job ID in response\n", .{});
                return error.InvalidJobId;
            },
        };
        job_ids[i] = id_int;
        stdout.print(" - {s}/tests/{d}\n", .{ host, id_int }) catch {};
    }
    stdout.flush() catch {};

    return job_ids;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "checkFailedEntries: empty failed object returns false" {
    const allocator = testing.allocator;
    const json_str =
        \\{
        \\  "failed": {}
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(!checkFailedEntries(obj));
}

test "checkFailedEntries: non-empty failed object returns true" {
    const allocator = testing.allocator;
    const json_str =
        \\{
        \\  "failed": {
        \\    "product1": { "error_message": "failed to schedule" }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(checkFailedEntries(obj));
}

test "checkFailedEntries: missing failed key returns false" {
    const allocator = testing.allocator;
    const json_str =
        \\{
        \\  "success": true
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(!checkFailedEntries(obj));
}

test "extractJobIds: valid positive integers" {
    const allocator = testing.allocator;
    const json_str =
        \\[101, 102, 103]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const ids = try extractJobIds(allocator, .{}, "http://localhost", &w, arr);
    defer allocator.free(ids);

    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqual(@as(u64, 101), ids[0]);
    try testing.expectEqual(@as(u64, 102), ids[1]);
    try testing.expectEqual(@as(u64, 103), ids[2]);

    const output = w.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "3 jobs have been created") != null);
    try testing.expect(std.mem.indexOf(u8, output, "http://localhost/tests/101") != null);
}

test "extractJobIds: non-integer value returns error" {
    const allocator = testing.allocator;
    const json_str =
        \\[101, "102"]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try testing.expectError(error.InvalidJobId, extractJobIds(allocator, .{ .quiet = true }, "http://localhost", &w, arr));
}

test "extractJobIds: empty array returns error" {
    const allocator = testing.allocator;
    const json_str =
        \\[]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try testing.expectError(error.NoJobsCreated, extractJobIds(allocator, .{ .quiet = true }, "http://localhost", &w, arr));
}

// Regression test for negative job IDs — see ideas/HARNESS_AUDIT.md.
// AFL discovered this crash via the schedule fuzzer on 2026-04-29.
// Before the fix at schedule.zig:435, this test PANICS with
// "integer does not fit in destination type" because @intCast aborts on
// negative inputs. After the fix (using std.math.cast), it should return
// error.InvalidJobId cleanly.
test "extractJobIds: negative integer is rejected" {
    const allocator = testing.allocator;
    const json_str =
        \\[-1]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try testing.expectError(error.InvalidJobId, extractJobIds(allocator, .{ .quiet = true }, "http://localhost", &w, arr));
}
