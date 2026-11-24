//! Clone-job Pass 1: BFS dependency-graph walk with injected HTTP client.
//!
//! This module owns the part of `zoqa-clone-job` that fetches each reachable job
//! from the source instance and feeds it to the I/O-free
//! `clone_job.DependencyWalker`. It mirrors the other library workflow
//! orchestrators (`runArchive`, `runMonitor`, `runSchedule`): all HTTP I/O goes
//! through an injected `client: anytype`, so the same code runs in production, in
//! unit tests, and in the fuzz harness.
//!
//! Pass 2 (dependency encoding, overrides, POST body, output formatting) and all
//! CLI concerns (argument parsing, credentials resolution, exit codes) stay in
//! `src/clone_job_main.zig`.

const std = @import("std");
const clone_job = @import("clone_job.zig");
const config = @import("config.zig");
const http_client = @import("http_client.zig");

/// Errors returned by `walkDependencyGraph`.
///
/// Every transport, parse, shape, or extraction failure collapses to
/// `error.WalkFailed`, preserving `zoqa-clone-job`'s exit-code contract
/// (exit `1` on any BFS failure).
pub const WalkError = error{WalkFailed};

/// Retry/timeout knobs passed into each BFS `GET`.
///
/// Mirrors the relevant `http_client.CallOptions` fields without depending on
/// the CLI layer (`cli_env`), keeping the library free of `std.process`.
pub const RetryPolicy = struct {
    retries: u32 = 0,
    connect_timeout_s: f64 = 30.0,
    retry_sleep_s: f64 = 3.0,
    retry_factor: f64 = 1.0,
};

/// Result of a dependency-graph walk.
///
/// All collected data is owned by the arena allocator passed to
/// `walkDependencyGraph`; nothing here needs to be freed individually.
pub const WalkResult = struct {
    walker: clone_job.DependencyWalker,
    assets: std.ArrayList(clone_job.AssetEntry),
    missing_asset_filenames: std.ArrayList([]const u8),
};

/// Print a diagnostic to stderr unless `quiet` is set.
///
/// Mirrors the library's existing diagnostic convention (`http_client`,
/// `monitor`, `schedule`): output is gated by a quiet flag and written via
/// `std.debug.print`.
fn diag(quiet: bool, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    std.debug.print(fmt, args);
}

/// Perform a BFS walk of the job dependency graph from the origin job.
///
/// Fetches each reachable job from the source instance (`clone_opts.from_url`),
/// records settings and dependency information, extracts asset references, and
/// collects any server-reported missing asset filenames.
///
/// Parameters:
/// - `gpa`: General-purpose allocator for transient allocations (freed per-iteration).
/// - `arena`: Arena allocator for long-lived data (walker entries, assets).
/// - `origin_job_id`: Job ID to start the walk from.
/// - `credentials`: Optional API credentials for the source instance.
/// - `retry`: Retry/timeout policy for each `GET`.
/// - `clone_opts`: Clone behavior flags; `.from_url` is the source instance.
/// - `verbose`: When `true`, enables verbose HTTP request output.
/// - `quiet`: When `true`, suppresses walk diagnostics on stderr.
/// - `ignore_missing_assets`: When `true`, suppresses the `?check_assets=1` query.
/// - `client`: HTTP client compatible with `std.http.Client.request` (production:
///   `*std.http.Client`; tests/fuzz: a duck-typed mock).
///
/// Returns: A `WalkResult` with the walker state, collected assets, and
///   server-reported missing asset filenames.
///
/// Errors: `error.WalkFailed` on any transport, parse, shape, or extraction error.
pub fn walkDependencyGraph(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    origin_job_id: u64,
    credentials: ?config.Credentials,
    retry: RetryPolicy,
    clone_opts: clone_job.CloneOptions,
    verbose: bool,
    quiet: bool,
    ignore_missing_assets: bool,
    client: anytype,
) WalkError!WalkResult {
    var walker = clone_job.DependencyWalker.init(arena, origin_job_id, clone_opts) catch |err| {
        diag(quiet, "Error: walker init failed: {s}\n", .{@errorName(err)});
        return error.WalkFailed;
    };
    var all_assets: std.ArrayList(clone_job.AssetEntry) = .empty;
    var all_missing_assets: std.ArrayList([]const u8) = .empty;

    // Populate `missing_assets` on the server side unless suppressed.
    const check_assets_qs: []const u8 = if (!ignore_missing_assets) "?check_assets=1" else "";

    while (walker.next()) |item| {
        const job_path = std.fmt.allocPrint(gpa, "jobs/{d}{s}", .{ item.job_id, check_assets_qs }) catch |err| {
            diag(quiet, "Error: allocPrint failed: {s}\n", .{@errorName(err)});
            return error.WalkFailed;
        };
        defer gpa.free(job_path);

        const get_resp = http_client.openQAReq(clone_opts.from_url, job_path, .{
            .allocator = gpa,
            .method = .GET,
            .credentials = credentials,
            .retries = retry.retries,
            .connect_timeout_s = retry.connect_timeout_s,
            .retry_sleep_s = retry.retry_sleep_s,
            .retry_factor = retry.retry_factor,
            .quiet = !verbose,
        }, client) catch |err| {
            diag(quiet, "Error: GET job {d} failed: {s}\n", .{ item.job_id, @errorName(err) });
            return error.WalkFailed;
        };
        defer get_resp.deinit();

        if (get_resp.exitCode() != 0) {
            diag(quiet, "Error: failed to get job '{d}': {d}\n", .{
                item.job_id, @intFromEnum(get_resp.status),
            });
            return error.WalkFailed;
        }

        const get_parsed = std.json.parseFromSlice(std.json.Value, gpa, get_resp.body, .{}) catch |err| {
            diag(quiet, "Error: failed to parse job {d} response: {s}\n", .{ item.job_id, @errorName(err) });
            return error.WalkFailed;
        };
        defer get_parsed.deinit();

        const job_obj = clone_job.extractJobObject(get_parsed.value) catch |err| {
            switch (err) {
                error.NotAnObject => diag(quiet, "Error: response for job {d} is not a JSON object\n", .{item.job_id}),
                error.MissingJobField => diag(quiet, "Error: response for job {d} missing 'job' field\n", .{item.job_id}),
                error.JobFieldNotObject => diag(quiet, "Error: 'job' field is not an object for job {d}\n", .{item.job_id}),
            }
            return error.WalkFailed;
        };

        // Feed parsed job to walker (extracts settings, deps, enqueues children).
        walker.feed(arena, item, job_obj) catch |err| {
            diag(quiet, "Error: walker feed failed for job {d}: {s}\n", .{ item.job_id, @errorName(err) });
            return error.WalkFailed;
        };

        const job_assets = clone_job.extractAssets(arena, job_obj, item.job_id) catch |err| {
            diag(quiet, "Error: extractAssets failed for job {d}: {s}\n", .{ item.job_id, @errorName(err) });
            return error.WalkFailed;
        };
        all_assets.appendSlice(arena, job_assets) catch |err| {
            diag(quiet, "Error: asset append failed: {s}\n", .{@errorName(err)});
            return error.WalkFailed;
        };

        clone_job.collectMissingAssets(arena, job_obj, &all_missing_assets) catch |err| {
            diag(quiet, "Error: missing_assets append failed: {s}\n", .{@errorName(err)});
            return error.WalkFailed;
        };
    }

    return .{
        .walker = walker,
        .assets = all_assets,
        .missing_asset_filenames = all_missing_assets,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Duck-typed `std.http.Client` mock for `walkDependencyGraph` tests.
//
// `walkDependencyGraph` calls `http_client.openQAReq`, which forwards to
// `http_client.execute(q.?, client)`. That function drives the low-level
// `std.http.Client` surface directly (`request`/`sendBodiless`/`receiveHead`/
// `reader`), so the mock must reproduce that contract rather than returning an
// `APIResponse` itself. Responses are selected by substring match on the
// request path, with a default 404 for unmatched jobs.
const MockGraphClient = struct {
    const Self = @This();

    pub const MockResponseEntry = struct {
        status: std.http.Status = .ok,
        body: []const u8 = "{}",
    };

    const MockHeaderIterator = struct {
        done: bool = false,

        /// Yield the single canned Content-Type header once, then null.
        pub fn next(self: *MockHeaderIterator) ?std.http.Header {
            if (self.done) return null;
            self.done = true;
            return .{ .name = "Content-Type", .value = "application/json" };
        }
    };

    const MockHead = struct {
        status: std.http.Status = .ok,
        location: ?[]const u8 = null,
        content_type: ?[]const u8 = "application/json",
        content_length: ?u64 = null,

        /// Return an iterator over this mock head's response headers.
        pub fn iterateHeaders(_: *const MockHead) MockHeaderIterator {
            return .{};
        }
    };

    const MockReader = struct {
        done: bool = false,
        body: []const u8 = "",

        /// Stream this response's body once, then report EOF (0 bytes).
        pub fn streamRemaining(self: *MockReader, w: anytype) anyerror!usize {
            if (self.done) return 0;
            self.done = true;
            try w.writeAll(self.body);
            return self.body.len;
        }
    };

    const MockResponse = struct {
        head: MockHead = .{},
        reader_state: MockReader = .{},

        pub fn deinit(_: *MockResponse) void {}
        pub fn sendBodiless(_: *MockResponse) !void {}
        pub fn sendBodyComplete(_: *MockResponse, _: []u8) !void {}

        /// Return the canned body reader for this response.
        pub fn reader(self: *MockResponse, _: []u8) *MockReader {
            return &self.reader_state;
        }

        /// Return this response as its own head (no network round-trip).
        pub fn receiveHead(self: *MockResponse, _: []u8) !*MockResponse {
            return self;
        }
    };

    responses: std.StringHashMapUnmanaged(MockResponseEntry) = .empty,
    default_response: MockResponseEntry = .{
        .status = .not_found,
        .body = "{\"error\":\"not found\"}",
    },
    response: MockResponse = .{},

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.responses.deinit(allocator);
    }

    pub fn setResponse(self: *Self, allocator: std.mem.Allocator, path_pattern: []const u8, resp: MockResponseEntry) !void {
        try self.responses.put(allocator, path_pattern, resp);
    }

    /// Capture the request path, select the matching canned response, and
    /// return it as a low-level `std.http.Client` response.
    pub fn request(self: *Self, _: std.http.Method, uri: std.Uri, _: anytype) !*MockResponse {
        const path = uri.path.percent_encoded;

        var resp = self.default_response;
        var it = self.responses.iterator();
        while (it.next()) |entry| {
            if (std.mem.indexOf(u8, path, entry.key_ptr.*) != null) {
                resp = entry.value_ptr.*;
                break;
            }
        }

        self.response = .{
            .head = .{ .status = resp.status },
            .reader_state = .{ .body = resp.body },
        };
        return &self.response;
    }
};

fn testCloneOpts() clone_job.CloneOptions {
    return .{ .from_url = "http://localhost" };
}

test "walkDependencyGraph: single job success" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mock: MockGraphClient = .{};
    defer mock.deinit(allocator);
    try mock.setResponse(allocator, "jobs/42", .{
        .status = .ok,
        .body =
        \\{
        \\  "job": {
        \\    "id": 42,
        \\    "name": "single_test_job",
        \\    "settings": {
        \\      "DISTRI": "opensuse",
        \\      "VERSION": "15.5"
        \\    },
        \\    "assets": {
        \\      "iso": ["openSUSE-DVD.iso"]
        \\    }
        \\  }
        \\}
        ,
    });

    const res = try walkDependencyGraph(
        allocator,
        arena.allocator(),
        42,
        null,
        .{ .retries = 0 },
        testCloneOpts(),
        false,
        true,
        false,
        &mock,
    );

    try std.testing.expectEqual(@as(usize, 1), res.walker.collected.items.len);
    try std.testing.expectEqual(@as(u64, 42), res.walker.collected.items[0].job_id);
    try std.testing.expectEqualStrings("single_test_job", res.walker.collected.items[0].name);

    try std.testing.expectEqual(@as(usize, 1), res.assets.items.len);
    try std.testing.expectEqualStrings("openSUSE-DVD.iso", res.assets.items[0].filename);
    try std.testing.expectEqual(clone_job.AssetType.iso, res.assets.items[0].asset_type);

    try std.testing.expectEqual(@as(usize, 0), res.missing_asset_filenames.items.len);
}

test "walkDependencyGraph: bfs traversal follows parent chained dependencies" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mock: MockGraphClient = .{};
    defer mock.deinit(allocator);
    try mock.setResponse(allocator, "jobs/10", .{
        .status = .ok,
        .body =
        \\{
        \\  "job": {
        \\    "id": 10,
        \\    "name": "child_job",
        \\    "parents": {
        \\      "Chained": [20]
        \\    }
        \\  }
        \\}
        ,
    });
    try mock.setResponse(allocator, "jobs/20", .{
        .status = .ok,
        .body =
        \\{
        \\  "job": {
        \\    "id": 20,
        \\    "name": "parent_job"
        \\  }
        \\}
        ,
    });

    const res = try walkDependencyGraph(
        allocator,
        arena.allocator(),
        10,
        null,
        .{ .retries = 0 },
        testCloneOpts(),
        false,
        true,
        false,
        &mock,
    );

    try std.testing.expectEqual(@as(usize, 2), res.walker.collected.items.len);
    try std.testing.expectEqual(@as(u64, 10), res.walker.collected.items[0].job_id);
    try std.testing.expectEqualStrings("child_job", res.walker.collected.items[0].name);
    try std.testing.expectEqual(@as(u64, 20), res.walker.collected.items[1].job_id);
    try std.testing.expectEqualStrings("parent_job", res.walker.collected.items[1].name);
}

test "walkDependencyGraph: collects missing_assets array from job" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mock: MockGraphClient = .{};
    defer mock.deinit(allocator);
    try mock.setResponse(allocator, "jobs/42", .{
        .status = .ok,
        .body =
        \\{
        \\  "job": {
        \\    "id": 42,
        \\    "name": "job_with_missing",
        \\    "missing_assets": ["iso/missing.iso", "hdd/missing.qcow2"]
        \\  }
        \\}
        ,
    });

    const res = try walkDependencyGraph(
        allocator,
        arena.allocator(),
        42,
        null,
        .{ .retries = 0 },
        testCloneOpts(),
        false,
        true,
        false,
        &mock,
    );

    try std.testing.expectEqual(@as(usize, 2), res.missing_asset_filenames.items.len);
    try std.testing.expectEqualStrings("iso/missing.iso", res.missing_asset_filenames.items[0]);
    try std.testing.expectEqualStrings("hdd/missing.qcow2", res.missing_asset_filenames.items[1]);
}

test "walkDependencyGraph: returns error.WalkFailed on HTTP 404" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mock: MockGraphClient = .{};
    defer mock.deinit(allocator);
    // default_response is 404

    try std.testing.expectError(error.WalkFailed, walkDependencyGraph(
        allocator,
        arena.allocator(),
        404,
        null,
        .{ .retries = 0 },
        testCloneOpts(),
        false,
        true,
        false,
        &mock,
    ));
}

test "walkDependencyGraph: returns error.WalkFailed on malformed JSON" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mock: MockGraphClient = .{};
    defer mock.deinit(allocator);
    try mock.setResponse(allocator, "jobs/42", .{
        .status = .ok,
        .body = "this is not valid json {",
    });

    try std.testing.expectError(error.WalkFailed, walkDependencyGraph(
        allocator,
        arena.allocator(),
        42,
        null,
        .{ .retries = 0 },
        testCloneOpts(),
        false,
        true,
        false,
        &mock,
    ));
}

test "walkDependencyGraph: returns error.WalkFailed on non-object JSON root" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mock: MockGraphClient = .{};
    defer mock.deinit(allocator);
    try mock.setResponse(allocator, "jobs/42", .{
        .status = .ok,
        .body = "[\"an\", \"array\", \"not\", \"object\"]",
    });

    try std.testing.expectError(error.WalkFailed, walkDependencyGraph(
        allocator,
        arena.allocator(),
        42,
        null,
        .{ .retries = 0 },
        testCloneOpts(),
        false,
        true,
        false,
        &mock,
    ));
}

test "walkDependencyGraph: returns error.WalkFailed when 'job' key is missing" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mock: MockGraphClient = .{};
    defer mock.deinit(allocator);
    try mock.setResponse(allocator, "jobs/42", .{
        .status = .ok,
        .body = "{\"error\": \"job missing\"}",
    });

    try std.testing.expectError(error.WalkFailed, walkDependencyGraph(
        allocator,
        arena.allocator(),
        42,
        null,
        .{ .retries = 0 },
        testCloneOpts(),
        false,
        true,
        false,
        &mock,
    ));
}

test "walkDependencyGraph: returns error.WalkFailed when 'job' is not an object" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mock: MockGraphClient = .{};
    defer mock.deinit(allocator);
    try mock.setResponse(allocator, "jobs/42", .{
        .status = .ok,
        .body = "{\"job\": 42}",
    });

    try std.testing.expectError(error.WalkFailed, walkDependencyGraph(
        allocator,
        arena.allocator(),
        42,
        null,
        .{ .retries = 0 },
        testCloneOpts(),
        false,
        true,
        false,
        &mock,
    ));
}
