//! Clone-job dependency graph algorithm (library layer).
//!
//! Recursive dependency walk, dependency encoding,
//! depth-based override application, multi-job POST body construction,
//! and sorted output formatting. This module is I/O-free: it operates
//! on in-memory job data and produces byte buffers. The executable layer
//! handles HTTP requests and passes fetched job JSON to this module.

const std = @import("std");
const url = @import("url.zig");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A single job setting key/value pair.
/// Both slices are owned by the arena allocator — no individual free needed.
pub const SettingPair = struct {
    key: []const u8,
    value: []const u8,
};

/// Accumulated data for a single job in the clone graph.
/// Stored in `post_params` (the ArrayList of collected jobs).
pub const JobEntry = struct {
    /// Original job ID on the source instance.
    job_id: u64,
    /// Shallow copy of the job's settings, plus CLONED_FROM / _GROUP_ID / dep keys.
    /// All slices arena-owned.
    settings: std.ArrayList(SettingPair),
    /// The job's display name (from the API response). Arena-owned.
    name: []const u8,
};

/// Options controlling the clone graph walk.
/// Mirrors CLI flags; passed by the executable layer.
pub const CloneOptions = struct {
    skip_deps: bool = false,
    skip_chained_deps: bool = false,
    clone_children: bool = false,
    max_depth: ?u32 = null,
    parental_inheritance: bool = false,
    from_url: []const u8,
};

/// Parsed dependency arrays for a single job (parent or child side).
pub const JobDeps = struct {
    chained: []const u64,
    directly_chained: []const u64,
    parallel: []const u64,
};

/// Relation to the user-specified job.
pub const Relation = enum {
    /// The initial user-specified job.
    origin,
    /// A parent (direct or transitive) of the user-specified job.
    parents,
    /// A child (direct or transitive) of the user-specified job.
    children,
};

/// A single override from the CLI positional arguments.
/// Supports KEY=VALUE, KEY+=VALUE (append), KEY:SCOPE=VALUE (scoped), KEY= (delete).
pub const Override = struct {
    key: []const u8,
    scope: ?[]const u8,
    plus: bool,
    value: []const u8,
};

// ---------------------------------------------------------------------------
// Override parsing
// ---------------------------------------------------------------------------

/// Parse a `KEY[+]=VALUE` or `KEY:SCOPE[+]=VALUE` override string.
///
/// Arguments:
/// - `input`: Raw positional string (e.g. "BUILD=123", "TEST+=:PR-1", "KEY:scope=V").
///
/// Returns: An `Override` struct with key, scope, plus flag, and value extracted;
///   or `null` when the string contains no `=`.
pub fn parseOverride(input: []const u8) ?Override {
    const eq = std.mem.indexOfScalar(u8, input, '=') orelse return null;
    var key_part = input[0..eq];
    const value = input[eq + 1 ..];

    // Check for += (append mode)
    var plus = false;
    if (key_part.len > 0 and key_part[key_part.len - 1] == '+') {
        plus = true;
        key_part = key_part[0 .. key_part.len - 1];
    }

    // Check for KEY:SCOPE
    var scope: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, key_part, ':')) |colon| {
        scope = key_part[colon + 1 ..];
        key_part = key_part[0..colon];
    }

    return .{
        .key = key_part,
        .scope = scope,
        .plus = plus,
        .value = value,
    };
}

// ---------------------------------------------------------------------------
// Global settings check
// ---------------------------------------------------------------------------

/// Returns true if a setting key is a "global" setting that bypasses the
/// depth-based inheritance check. Matches Perl `is_global_setting`.
///
/// Global settings (WORKER_CLASS, _GROUP, _GROUP_ID) are always applied
/// to parent jobs regardless of depth.
///
/// Arguments:
/// - `key`: The setting key name to check.
///
/// Returns: `true` when `key` is one of the recognised global setting names.
pub fn isGlobalSetting(key: []const u8) bool {
    return std.mem.eql(u8, key, "WORKER_CLASS") or
        std.mem.eql(u8, key, "_GROUP") or
        std.mem.eql(u8, key, "_GROUP_ID");
}

// ---------------------------------------------------------------------------
// Dependency encoding
// ---------------------------------------------------------------------------

/// Filter `deps` to only those job IDs present in `collected_jobs`,
/// join with commas, and assign to `settings[name]`.
///
/// Mirrors Perl `_assign_existing_dependencies`.
/// If no deps survive filtering, the key is NOT added (matching Perl semantics:
/// an empty @filtered causes early return without assignment).
///
/// Arguments:
/// - `arena`: Allocator for all produced strings (key/value copies, format buffer).
/// - `settings`: The target settings list to update (existing entry with `name` is replaced).
/// - `name`: Dependency key name (e.g. "_PARALLEL", "_START_AFTER").
/// - `deps`: Source job IDs from the dependency graph.
/// - `collected_jobs`: Full set of jobs in the clone; only IDs present here survive filtering.
///
/// Errors: `OutOfMemory` if the arena cannot allocate.
pub fn assignExistingDeps(
    arena: std.mem.Allocator,
    settings: *std.ArrayList(SettingPair),
    name: []const u8,
    deps: []const u64,
    collected_jobs: []const JobEntry,
) !void {
    if (deps.len == 0) return;

    // Filter: keep only IDs that exist in collected_jobs
    var count: usize = 0;
    for (deps) |dep_id| {
        for (collected_jobs) |entry| {
            if (entry.job_id == dep_id) {
                count += 1;
                break;
            }
        }
    }
    if (count == 0) return;

    // Build comma-separated string of surviving IDs
    var buf: std.ArrayList(u8) = .empty;
    var first = true;
    for (deps) |dep_id| {
        var found = false;
        for (collected_jobs) |entry| {
            if (entry.job_id == dep_id) {
                found = true;
                break;
            }
        }
        if (!found) continue;
        // there is no call to deinit, this buff.append allocation
        // does not leak, only as long as the arena is really an arena allocator
        if (!first) try buf.append(arena, ',');
        first = false;
        try std.fmt.format(buf.writer(arena), "{d}", .{dep_id});
    }

    // Remove any existing entry with this key
    var wi: usize = 0;
    while (wi < settings.items.len) {
        if (std.mem.eql(u8, settings.items[wi].key, name)) {
            _ = settings.orderedRemove(wi);
        } else {
            wi += 1;
        }
    }

    try settings.append(arena, .{
        .key = try arena.dupe(u8, name),
        .value = try arena.dupe(u8, buf.items),
    });
}

test "assignExistingDeps: filters to collected jobs only" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Simulate collected_jobs with IDs 10 and 30 (but not 20)
    var s1: std.ArrayList(SettingPair) = .empty;
    var s2: std.ArrayList(SettingPair) = .empty;
    const collected = [_]JobEntry{
        .{ .job_id = 10, .settings = s1, .name = "job10" },
        .{ .job_id = 30, .settings = s2, .name = "job30" },
    };
    _ = &s1;
    _ = &s2;

    var settings: std.ArrayList(SettingPair) = .empty;
    const deps = [_]u64{ 10, 20, 30 };
    try assignExistingDeps(a, &settings, "_START_AFTER", &deps, &collected);

    // Should contain "10,30" (20 was filtered out)
    try std.testing.expectEqual(@as(usize, 1), settings.items.len);
    try std.testing.expectEqualStrings("_START_AFTER", settings.items[0].key);
    try std.testing.expectEqualStrings("10,30", settings.items[0].value);
}

test "assignExistingDeps: empty deps does nothing" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    var s1: std.ArrayList(SettingPair) = .empty;
    const collected = [_]JobEntry{
        .{ .job_id = 10, .settings = s1, .name = "job10" },
    };
    _ = &s1;
    try assignExistingDeps(a, &settings, "_PARALLEL", &.{}, &collected);
    try std.testing.expectEqual(@as(usize, 0), settings.items.len);
}

test "assignExistingDeps: no matching deps does nothing" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    var s1: std.ArrayList(SettingPair) = .empty;
    const collected = [_]JobEntry{
        .{ .job_id = 10, .settings = s1, .name = "job10" },
    };
    _ = &s1;
    const deps = [_]u64{ 99, 100 };
    try assignExistingDeps(a, &settings, "_PARALLEL", &deps, &collected);
    try std.testing.expectEqual(@as(usize, 0), settings.items.len);
}

// ---------------------------------------------------------------------------
// Settings override application
// ---------------------------------------------------------------------------

/// Apply user-provided overrides to a job's settings list.
///
/// Mirrors Perl `clone_job_apply_settings`:
///   - Deletes `NAME` key (server auto-generates it).
///   - For each override:
///     - If scoped: skip unless the job's TEST == scope.
///     - If unscoped and depth > 1 and not global and not --parental-inheritance: skip.
///     - Empty value: delete the key.
///     - Plus mode (+=): append to existing value.
///     - Otherwise: replace or append.
///   - Delete counterpart (_GROUP ↔ _GROUP_ID) when either is set.
///
/// `depth`: 1 for user-specified job, 2+ for parents, 0 for children.
///
/// Arguments:
/// - `arena`: Allocator for any new string allocations (appended/duplicated values).
/// - `settings`: The job's mutable settings list.
/// - `overrides`: Parsed CLI overrides to apply.
/// - `depth`: Depth of this job in the dependency graph (1 = origin, 2+ = parents, 0 = children).
/// - `parental_inheritance`: When true, all overrides propagate to parents regardless of depth.
///
/// Errors: `OutOfMemory` if the arena cannot allocate.
pub fn applySettings(
    arena: std.mem.Allocator,
    settings: *std.ArrayList(SettingPair),
    overrides: []const Override,
    depth: u32,
    parental_inheritance: bool,
) !void {
    // Delete NAME (server auto-generates it) — matches Perl: `delete $settings->{NAME}`
    {
        var wi: usize = 0;
        while (wi < settings.items.len) {
            if (std.mem.eql(u8, settings.items[wi].key, "NAME")) {
                _ = settings.orderedRemove(wi);
            } else {
                wi += 1;
            }
        }
    }

    // Find the TEST setting for scope matching
    const test_val: []const u8 = blk: {
        for (settings.items) |s| {
            if (std.mem.eql(u8, s.key, "TEST")) break :blk s.value;
        }
        break :blk "";
    };

    for (overrides) |ov| {
        // Scoped: skip unless TEST matches
        if (ov.scope) |scope| {
            if (!std.mem.eql(u8, test_val, scope)) continue;
        } else {
            // Unscoped: depth > 1 check (parents only inherit globals or with flag)
            if (!isGlobalSetting(ov.key) and depth > 1 and !parental_inheritance) continue;
        }

        // Empty value = delete
        if (ov.value.len == 0 and !ov.plus) {
            var wi: usize = 0;
            while (wi < settings.items.len) {
                if (std.mem.eql(u8, settings.items[wi].key, ov.key)) {
                    _ = settings.orderedRemove(wi);
                } else {
                    wi += 1;
                }
            }
            continue;
        }

        // Plus mode: append to existing value
        if (ov.plus) {
            var found = false;
            for (settings.items) |*s| {
                if (std.mem.eql(u8, s.key, ov.key)) {
                    s.value = try std.fmt.allocPrint(arena, "{s}{s}", .{ s.value, ov.value });
                    found = true;
                    break;
                }
            }
            if (!found) {
                try settings.append(arena, .{
                    .key = try arena.dupe(u8, ov.key),
                    .value = try arena.dupe(u8, ov.value),
                });
            }
            continue;
        }

        // Replace or append
        var found = false;
        for (settings.items) |*s| {
            if (std.mem.eql(u8, s.key, ov.key)) {
                s.value = try arena.dupe(u8, ov.value);
                found = true;
                break;
            }
        }
        if (!found) {
            try settings.append(arena, .{
                .key = try arena.dupe(u8, ov.key),
                .value = try arena.dupe(u8, ov.value),
            });
        }

        // Delete counterpart (_GROUP ↔ _GROUP_ID)
        const counterpart: ?[]const u8 = if (std.mem.eql(u8, ov.key, "_GROUP"))
            "_GROUP_ID"
        else if (std.mem.eql(u8, ov.key, "_GROUP_ID"))
            "_GROUP"
        else
            null;
        if (counterpart) |cp| {
            var wi: usize = 0;
            while (wi < settings.items.len) {
                if (std.mem.eql(u8, settings.items[wi].key, cp)) {
                    _ = settings.orderedRemove(wi);
                } else {
                    wi += 1;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Multi-job POST body construction
// ---------------------------------------------------------------------------

/// Build the `application/x-www-form-urlencoded` POST body for a multi-job clone.
///
/// Format: `KEY:JOBID=percent_encoded_VALUE&...&is_clone_job=1`
///
/// Jobs are emitted in the order they appear in `collected_jobs`.
/// The colon and job ID are literal (not encoded); only values are percent-encoded.
///
/// Arguments:
/// - `allocator`: Used for internal buffer growth and the returned owned slice.
/// - `collected_jobs`: Ordered list of jobs with their settings to encode.
///
/// Returns: An owned `[]u8` containing the full form-encoded POST body.
///   The caller must free it with `allocator`.
///
/// Errors: `OutOfMemory` if allocation fails.
pub fn buildPostBody(
    allocator: std.mem.Allocator,
    collected_jobs: []const JobEntry,
) ![]u8 {
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);

    for (collected_jobs) |entry| {
        var id_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{entry.job_id}) catch unreachable;

        for (entry.settings.items) |s| {
            if (body_buf.items.len > 0) try body_buf.append(allocator, '&');
            try url.formEncodeAppend(allocator, &body_buf, s.key);
            try body_buf.append(allocator, ':');
            try body_buf.appendSlice(allocator, id_str);
            try body_buf.append(allocator, '=');
            try url.formEncodeAppend(allocator, &body_buf, s.value);
        }
    }

    if (body_buf.items.len > 0) try body_buf.append(allocator, '&');
    try body_buf.appendSlice(allocator, "is_clone_job=1");

    return try allocator.dupe(u8, body_buf.items);
}

// ---------------------------------------------------------------------------
// Output formatting
// ---------------------------------------------------------------------------

/// Format the clone success output.
///
/// Produces:
///   "N jobs have been created:\n"  (or "1 job has been created:\n")
///   " - {name} -> {host_url}/tests/{new_id}\n"  (sorted by original ID ascending)
///
/// `ids_map` maps original_job_id (string key) → new_job_id (integer value),
/// as returned by the openQA `POST /api/v1/jobs` response `ids` object.
///
/// The `collected_jobs` is used to look up the display name for each original ID.
///
/// Arguments:
/// - `allocator`: Used for internal buffers and the returned owned slice.
/// - `ids_map`: JSON object mapping original job ID strings to new job ID integers.
/// - `collected_jobs`: Job entries for name lookup by original ID.
/// - `host_url`: Destination instance URL used to construct test links.
///
/// Returns: An owned `[]u8` with the formatted output text.
///   The caller must free it with `allocator`.
///
/// Errors: `OutOfMemory` if allocation fails.
pub fn formatOutput(
    allocator: std.mem.Allocator,
    ids_map: std.json.ObjectMap,
    collected_jobs: []const JobEntry,
    host_url: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const job_count = ids_map.count();

    // Header line
    if (job_count == 1) {
        try out.appendSlice(allocator, "1 job has been created:\n");
    } else {
        try std.fmt.format(out.writer(allocator), "{d} jobs have been created:\n", .{job_count});
    }

    // Collect entries and sort by original ID (ascending)
    const Entry = struct {
        original_id: u64,
        new_id: i64,
        name: []const u8,
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    var it = ids_map.iterator();
    while (it.next()) |kv| {
        const orig_id = std.fmt.parseInt(u64, kv.key_ptr.*, 10) catch continue;
        const new_id: i64 = switch (kv.value_ptr.*) {
            .integer => |i| i,
            else => continue,
        };
        // Look up name
        const name: []const u8 = blk: {
            for (collected_jobs) |entry| {
                if (entry.job_id == orig_id) break :blk entry.name;
            }
            break :blk "unknown";
        };
        try entries.append(allocator, .{
            .original_id = orig_id,
            .new_id = new_id,
            .name = name,
        });
    }

    // Sort by original_id ascending
    std.mem.sortUnstable(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.original_id < b.original_id;
        }
    }.lessThan);

    // Format each line
    for (entries.items) |e| {
        try std.fmt.format(out.writer(allocator), " - {s} -> {s}/tests/{d}\n", .{
            e.name, host_url, e.new_id,
        });
    }

    return try allocator.dupe(u8, out.items);
}

// ---------------------------------------------------------------------------
// Job settings extraction from JSON
// ---------------------------------------------------------------------------

/// Extract settings from a parsed job JSON value into a SettingPair list.
///
/// Copies all keys except "NAME" (server auto-generates it).
/// Also adds CLONED_FROM and _GROUP_ID as appropriate.
///
/// Arguments:
/// - `arena`: Allocator for all produced key/value strings and the list itself.
/// - `job_val`: The parsed JSON object for a single job (the "job" field's content).
/// - `from_url`: Source instance URL, used to construct the CLONED_FROM value.
/// - `job_id`: Numeric job ID on the source instance.
///
/// Returns: An `ArrayList(SettingPair)` containing the extracted settings.
///   All slices within are arena-owned.
///
/// Errors: `OutOfMemory` if the arena cannot allocate.
pub fn extractJobSettings(
    arena: std.mem.Allocator,
    job_val: std.json.ObjectMap,
    from_url: []const u8,
    job_id: u64,
) !std.ArrayList(SettingPair) {
    var settings: std.ArrayList(SettingPair) = .empty;

    // Extract settings object
    const settings_obj = if (job_val.get("settings")) |sv|
        switch (sv) {
            .object => |o| o,
            else => return settings,
        }
    else
        return settings;

    // Copy all settings except NAME
    var sit = settings_obj.iterator();
    while (sit.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.eql(u8, k, "NAME")) continue;
        const v: []const u8 = switch (entry.value_ptr.*) {
            .string => |s| s,
            .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
            .bool => |b| if (b) "1" else "0",
            else => continue,
        };
        try settings.append(arena, .{
            .key = try arena.dupe(u8, k),
            .value = try arena.dupe(u8, v),
        });
    }

    // Add CLONED_FROM
    const cloned_from = try std.fmt.allocPrint(arena, "{s}/tests/{d}", .{ from_url, job_id });
    try settings.append(arena, .{ .key = "CLONED_FROM", .value = cloned_from });

    // Add _GROUP_ID if present
    if (job_val.get("group_id")) |g| {
        switch (g) {
            .integer => |gid| {
                const gid_str = try std.fmt.allocPrint(arena, "{d}", .{gid});
                // Remove any existing _GROUP_ID / _GROUP before adding ours
                var wi: usize = 0;
                while (wi < settings.items.len) {
                    const sk = settings.items[wi].key;
                    if (std.mem.eql(u8, sk, "_GROUP_ID") or std.mem.eql(u8, sk, "_GROUP")) {
                        _ = settings.orderedRemove(wi);
                    } else {
                        wi += 1;
                    }
                }
                try settings.append(arena, .{ .key = "_GROUP_ID", .value = gid_str });
            },
            else => {},
        }
    }

    return settings;
}

/// Extract parent or child dependency IDs from a job JSON.
///
/// Reads the "Chained", "Directly chained", and "Parallel" arrays from the
/// specified dependency object (either "parents" or "children").
///
/// Arguments:
/// - `arena`: Allocator for the returned ID slices.
/// - `job_obj`: The parsed JSON object for a single job.
/// - `job_type_key`: Either "parents" or "children".
///
/// Returns: A `JobDeps` struct with slices of dependency IDs (arena-owned).
///   Empty slices are returned for missing or non-object fields.
///
/// Errors: `OutOfMemory` if the arena cannot allocate.
pub fn extractDeps(
    arena: std.mem.Allocator,
    job_obj: std.json.ObjectMap,
    job_type_key: []const u8,
) !JobDeps {
    const empty: []const u64 = &.{};

    const deps_val = job_obj.get(job_type_key) orelse return .{
        .chained = empty,
        .directly_chained = empty,
        .parallel = empty,
    };

    const deps_obj = switch (deps_val) {
        .object => |o| o,
        else => return .{
            .chained = empty,
            .directly_chained = empty,
            .parallel = empty,
        },
    };

    return .{
        .chained = try extractIdArray(arena, deps_obj, "Chained"),
        .directly_chained = try extractIdArray(arena, deps_obj, "Directly chained"),
        .parallel = try extractIdArray(arena, deps_obj, "Parallel"),
    };
}

/// Extract an array of integer IDs from a JSON object field.
fn extractIdArray(
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) ![]const u64 {
    const arr_val = obj.get(key) orelse return &.{};
    const arr = switch (arr_val) {
        .array => |a| a,
        else => return &.{},
    };

    var ids: std.ArrayList(u64) = .empty;
    for (arr.items) |item| {
        switch (item) {
            .integer => |i| {
                if (i >= 0) try ids.append(arena, @intCast(i));
            },
            else => {},
        }
    }
    return try arena.dupe(u64, ids.items);
}

// ---------------------------------------------------------------------------
// Dependency Graph Walker
// ---------------------------------------------------------------------------

/// A pull-based BFS iterator for walking the openQA job dependency graph.
///
/// Separates traversal logic (cycle detection, depth tracking, dep filtering)
/// from I/O concerns. The caller drives the loop:
///
/// ```
/// var walker = try DependencyWalker.init(arena, origin_job_id, opts);
/// while (walker.next()) |item| {
///     const job_obj = fetchAndParseJob(item.job_id); // caller does I/O
///     try walker.feed(arena, item, job_obj);
/// }
/// // walker.collected.items now holds all traversed entries
/// ```
pub const DependencyWalker = struct {
    worklist: std.ArrayList(WorkItem),
    collected: std.ArrayList(CollectedEntry),
    opts: CloneOptions,
    work_idx: usize,

    /// A single BFS worklist item.
    pub const WorkItem = struct {
        job_id: u64,
        depth: u32,
        relation: Relation,
    };

    /// Accumulated data for a single job collected during the walk.
    pub const CollectedEntry = struct {
        job_id: u64,
        settings: std.ArrayList(SettingPair),
        name: []const u8,
        parent_chained: []const u64,
        parent_directly_chained: []const u64,
        parent_parallel: []const u64,
        depth: u32,
        relation: Relation,
    };

    /// Create a walker seeded with the origin job.
    ///
    /// Arguments:
    /// - `allocator`: Arena allocator for worklist/collected storage.
    /// - `origin_job_id`: The root job ID to start the BFS from.
    /// - `opts`: Clone options controlling dep traversal (skip flags, depth limits).
    ///
    /// Returns: An initialized `DependencyWalker` ready for iteration.
    ///
    /// Errors: `OutOfMemory` if the initial worklist append fails.
    pub fn init(allocator: std.mem.Allocator, origin_job_id: u64, opts: CloneOptions) !DependencyWalker {
        var self = DependencyWalker{
            .worklist = .empty,
            .collected = .empty,
            .opts = opts,
            .work_idx = 0,
        };
        try self.worklist.append(allocator, .{
            .job_id = origin_job_id,
            .depth = 1,
            .relation = .origin,
        });
        return self;
    }

    /// Return the next job to fetch, skipping already-collected IDs (cycle detection).
    ///
    /// Returns: The next `WorkItem` to process, or `null` when the BFS is complete.
    pub fn next(self: *DependencyWalker) ?WorkItem {
        while (self.work_idx < self.worklist.items.len) {
            const item = self.worklist.items[self.work_idx];
            self.work_idx += 1;

            // Cycle detection: skip if already collected
            var already_collected = false;
            for (self.collected.items) |entry| {
                if (entry.job_id == item.job_id) {
                    already_collected = true;
                    break;
                }
            }
            if (already_collected) continue;

            return item;
        }
        return null;
    }

    /// Feed a fetched job's raw JSON object back into the walker.
    ///
    /// Extracts settings and dependencies from the job object, applies
    /// skip/depth filtering, enqueues reachable deps, and records the
    /// job in `collected`.
    ///
    /// Arguments:
    /// - `allocator`: Arena allocator for extracted data and worklist growth.
    /// - `item`: The `WorkItem` returned by the preceding `next()` call.
    /// - `job_obj`: The parsed JSON ObjectMap for the `"job"` key in the API response.
    ///
    /// Returns: void on success.
    ///
    /// Errors: `OutOfMemory` if allocations fail during extraction or enqueue.
    pub fn feed(
        self: *DependencyWalker,
        allocator: std.mem.Allocator,
        item: WorkItem,
        job_obj: std.json.ObjectMap,
    ) !void {
        // Extract job name
        const job_name: []const u8 = if (job_obj.get("name")) |n|
            switch (n) {
                .string => |s| try allocator.dupe(u8, s),
                else => "unknown",
            }
        else
            "unknown";

        // Extract settings
        const settings = try extractJobSettings(
            allocator,
            job_obj,
            self.opts.from_url,
            item.job_id,
        );

        // Extract deps
        const parent_deps = try extractDeps(allocator, job_obj, "parents");
        const child_deps = try extractDeps(allocator, job_obj, "children");

        // Enqueue parents (with skip logic)
        if (!self.opts.skip_deps) {
            if (!self.opts.skip_chained_deps) {
                for (parent_deps.chained) |dep_id| {
                    try self.worklist.append(allocator, .{
                        .job_id = dep_id,
                        .depth = item.depth + 1,
                        .relation = .parents,
                    });
                }
                for (parent_deps.directly_chained) |dep_id| {
                    try self.worklist.append(allocator, .{
                        .job_id = dep_id,
                        .depth = item.depth + 1,
                        .relation = .parents,
                    });
                }
            }
            for (parent_deps.parallel) |dep_id| {
                try self.worklist.append(allocator, .{
                    .job_id = dep_id,
                    .depth = item.depth + 1,
                    .relation = .parents,
                });
            }
        }

        // Enqueue children (with skip/depth logic)
        {
            const skip_depth = if (self.opts.max_depth) |max_d|
                (max_d > 0 and item.depth > max_d)
            else
                false;

            if (!skip_depth) {
                // Parallel children are always cloned
                for (child_deps.parallel) |dep_id| {
                    try self.worklist.append(allocator, .{
                        .job_id = dep_id,
                        .depth = item.depth + 1,
                        .relation = .children,
                    });
                }
                // Chained/directly-chained children only if clone_children
                if (self.opts.clone_children) {
                    for (child_deps.chained) |dep_id| {
                        try self.worklist.append(allocator, .{
                            .job_id = dep_id,
                            .depth = item.depth + 1,
                            .relation = .children,
                        });
                    }
                    for (child_deps.directly_chained) |dep_id| {
                        try self.worklist.append(allocator, .{
                            .job_id = dep_id,
                            .depth = item.depth + 1,
                            .relation = .children,
                        });
                    }
                }
            }
        }

        // Record this job
        try self.collected.append(allocator, .{
            .job_id = item.job_id,
            .settings = settings,
            .name = job_name,
            .parent_chained = parent_deps.chained,
            .parent_directly_chained = parent_deps.directly_chained,
            .parent_parallel = parent_deps.parallel,
            .depth = item.depth,
            .relation = item.relation,
        });
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseOverride: basic KEY=VALUE" {
    const ov = parseOverride("BUILD=1234").?;
    try std.testing.expectEqualStrings("BUILD", ov.key);
    try std.testing.expectEqualStrings("1234", ov.value);
    try std.testing.expect(ov.scope == null);
    try std.testing.expect(!ov.plus);
}

test "parseOverride: KEY+=VALUE" {
    const ov = parseOverride("TEST+=:PR-123").?;
    try std.testing.expectEqualStrings("TEST", ov.key);
    try std.testing.expectEqualStrings(":PR-123", ov.value);
    try std.testing.expect(ov.scope == null);
    try std.testing.expect(ov.plus);
}

test "parseOverride: KEY:SCOPE=VALUE" {
    const ov = parseOverride("BUILD:server=9999").?;
    try std.testing.expectEqualStrings("BUILD", ov.key);
    try std.testing.expectEqualStrings("server", ov.scope.?);
    try std.testing.expectEqualStrings("9999", ov.value);
    try std.testing.expect(!ov.plus);
}

test "parseOverride: KEY= (delete)" {
    const ov = parseOverride("FOOBAR=").?;
    try std.testing.expectEqualStrings("FOOBAR", ov.key);
    try std.testing.expectEqualStrings("", ov.value);
    try std.testing.expect(ov.scope == null);
    try std.testing.expect(!ov.plus);
}

test "parseOverride: no equals returns null" {
    try std.testing.expect(parseOverride("noequals") == null);
}

test "isGlobalSetting" {
    try std.testing.expect(isGlobalSetting("WORKER_CLASS"));
    try std.testing.expect(isGlobalSetting("_GROUP"));
    try std.testing.expect(isGlobalSetting("_GROUP_ID"));
    try std.testing.expect(!isGlobalSetting("BUILD"));
    try std.testing.expect(!isGlobalSetting("TEST"));
}

test "applySettings: depth 1 applies all overrides" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    try settings.append(a, .{ .key = "BUILD", .value = "old" });
    try settings.append(a, .{ .key = "TEST", .value = "mytest" });
    try settings.append(a, .{ .key = "NAME", .value = "should-be-deleted" });

    const ovs = [_]Override{
        .{ .key = "BUILD", .scope = null, .plus = false, .value = "new" },
    };
    try applySettings(a, &settings, &ovs, 1, false);

    // NAME should be deleted
    for (settings.items) |s| {
        try std.testing.expect(!std.mem.eql(u8, s.key, "NAME"));
    }
    // BUILD should be "new"
    for (settings.items) |s| {
        if (std.mem.eql(u8, s.key, "BUILD")) {
            try std.testing.expectEqualStrings("new", s.value);
        }
    }
}

test "applySettings: depth 2 skips non-global unless parental-inheritance" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    try settings.append(a, .{ .key = "BUILD", .value = "old" });
    try settings.append(a, .{ .key = "WORKER_CLASS", .value = "qemu" });
    try settings.append(a, .{ .key = "TEST", .value = "parent" });

    const ovs = [_]Override{
        .{ .key = "BUILD", .scope = null, .plus = false, .value = "new" },
        .{ .key = "WORKER_CLASS", .scope = null, .plus = false, .value = "kvm" },
    };
    try applySettings(a, &settings, &ovs, 2, false);

    // BUILD should remain "old" (depth > 1, not global)
    for (settings.items) |s| {
        if (std.mem.eql(u8, s.key, "BUILD")) {
            try std.testing.expectEqualStrings("old", s.value);
        }
    }
    // WORKER_CLASS should be "kvm" (global setting)
    for (settings.items) |s| {
        if (std.mem.eql(u8, s.key, "WORKER_CLASS")) {
            try std.testing.expectEqualStrings("kvm", s.value);
        }
    }
}

test "applySettings: depth 2 with parental-inheritance applies all" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    try settings.append(a, .{ .key = "BUILD", .value = "old" });
    try settings.append(a, .{ .key = "TEST", .value = "parent" });

    const ovs = [_]Override{
        .{ .key = "BUILD", .scope = null, .plus = false, .value = "new" },
    };
    try applySettings(a, &settings, &ovs, 2, true);

    for (settings.items) |s| {
        if (std.mem.eql(u8, s.key, "BUILD")) {
            try std.testing.expectEqualStrings("new", s.value);
        }
    }
}

test "applySettings: depth 0 (children) applies all" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    try settings.append(a, .{ .key = "BUILD", .value = "old" });
    try settings.append(a, .{ .key = "TEST", .value = "child" });

    const ovs = [_]Override{
        .{ .key = "BUILD", .scope = null, .plus = false, .value = "child-val" },
    };
    try applySettings(a, &settings, &ovs, 0, false);

    for (settings.items) |s| {
        if (std.mem.eql(u8, s.key, "BUILD")) {
            try std.testing.expectEqualStrings("child-val", s.value);
        }
    }
}

test "applySettings: scoped override matches TEST" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    try settings.append(a, .{ .key = "BUILD", .value = "old" });
    try settings.append(a, .{ .key = "TEST", .value = "server" });

    const ovs = [_]Override{
        .{ .key = "BUILD", .scope = "server", .plus = false, .value = "scoped" },
        .{ .key = "BUILD", .scope = "client", .plus = false, .value = "wrong" },
    };
    try applySettings(a, &settings, &ovs, 5, false);

    // Scoped overrides bypass depth check — "server" scope matches
    for (settings.items) |s| {
        if (std.mem.eql(u8, s.key, "BUILD")) {
            try std.testing.expectEqualStrings("scoped", s.value);
        }
    }
}

test "applySettings: plus mode appends" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    try settings.append(a, .{ .key = "TEST", .value = "base" });

    const ovs = [_]Override{
        .{ .key = "TEST", .scope = null, .plus = true, .value = ":PR-99" },
    };
    try applySettings(a, &settings, &ovs, 1, false);

    for (settings.items) |s| {
        if (std.mem.eql(u8, s.key, "TEST")) {
            try std.testing.expectEqualStrings("base:PR-99", s.value);
        }
    }
}

test "applySettings: delete key with empty value" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    try settings.append(a, .{ .key = "FOOBAR", .value = "something" });
    try settings.append(a, .{ .key = "TEST", .value = "t" });

    const ovs = [_]Override{
        .{ .key = "FOOBAR", .scope = null, .plus = false, .value = "" },
    };
    try applySettings(a, &settings, &ovs, 1, false);

    for (settings.items) |s| {
        try std.testing.expect(!std.mem.eql(u8, s.key, "FOOBAR"));
    }
}

test "buildPostBody: single job" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    try settings.append(a, .{ .key = "BUILD", .value = "123" });
    try settings.append(a, .{ .key = "TEST", .value = "my test" });

    const collected = [_]JobEntry{
        .{ .job_id = 42, .settings = settings, .name = "testjob" },
    };

    const body = try buildPostBody(allocator, &collected);
    defer allocator.free(body);

    // Should contain KEY:42=VALUE format
    try std.testing.expect(std.mem.indexOf(u8, body, "BUILD:42=123") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "TEST:42=my+test") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "is_clone_job=1") != null);
}

test "buildPostBody: multiple jobs" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s1: std.ArrayList(SettingPair) = .empty;
    try s1.append(a, .{ .key = "BUILD", .value = "1" });
    var s2: std.ArrayList(SettingPair) = .empty;
    try s2.append(a, .{ .key = "BUILD", .value = "2" });

    const collected = [_]JobEntry{
        .{ .job_id = 41, .settings = s1, .name = "parent" },
        .{ .job_id = 42, .settings = s2, .name = "child" },
    };

    const body = try buildPostBody(allocator, &collected);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "BUILD:41=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "BUILD:42=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "is_clone_job=1") != null);
}

test "formatOutput: single job" {
    const allocator = std.testing.allocator;

    // Build a mock ids_map
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"42\": 5001}", .{});
    defer parsed.deinit();
    const ids_map = parsed.value.object;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s1: std.ArrayList(SettingPair) = .empty;
    try s1.append(a, .{ .key = "TEST", .value = "x" });
    const collected = [_]JobEntry{
        .{ .job_id = 42, .settings = s1, .name = "mytest" },
    };

    const output = try formatOutput(allocator, ids_map, &collected, "http://localhost");
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "1 job has been created:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mytest -> http://localhost/tests/5001") != null);
}

test "formatOutput: multiple jobs sorted by original ID" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"42\": 5002, \"41\": 5001}", .{});
    defer parsed.deinit();
    const ids_map = parsed.value.object;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s1: std.ArrayList(SettingPair) = .empty;
    try s1.append(a, .{ .key = "TEST", .value = "x" });
    var s2: std.ArrayList(SettingPair) = .empty;
    try s2.append(a, .{ .key = "TEST", .value = "y" });
    const collected = [_]JobEntry{
        .{ .job_id = 41, .settings = s1, .name = "parent" },
        .{ .job_id = 42, .settings = s2, .name = "child" },
    };

    const output = try formatOutput(allocator, ids_map, &collected, "http://localhost");
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "2 jobs have been created:") != null);
    // parent (41) should appear before child (42)
    const parent_pos = std.mem.indexOf(u8, output, "parent -> http://localhost/tests/5001").?;
    const child_pos = std.mem.indexOf(u8, output, "child -> http://localhost/tests/5002").?;
    try std.testing.expect(parent_pos < child_pos);
}

// ---------------------------------------------------------------------------
// DependencyWalker tests
// ---------------------------------------------------------------------------

/// Helper: build a minimal job JSON ObjectMap for walker tests.
fn makeTestJobObj(
    allocator: std.mem.Allocator,
    name: []const u8,
    parent_chained: []const i64,
    child_parallel: []const i64,
) !std.json.ObjectMap {
    var obj = std.json.ObjectMap.init(allocator);

    // "name" field
    try obj.put("name", .{ .string = name });

    // "settings" object (minimal)
    var settings_obj = std.json.ObjectMap.init(allocator);
    try settings_obj.put("TEST", .{ .string = name });
    try obj.put("settings", .{ .object = settings_obj });

    // "parents" object
    var parents_obj = std.json.ObjectMap.init(allocator);
    var chained_arr = std.json.Array.init(allocator);
    for (parent_chained) |id| {
        try chained_arr.append(.{ .integer = id });
    }
    try parents_obj.put("Chained", .{ .array = chained_arr });
    try parents_obj.put("Directly chained", .{ .array = std.json.Array.init(allocator) });
    try parents_obj.put("Parallel", .{ .array = std.json.Array.init(allocator) });
    try obj.put("parents", .{ .object = parents_obj });

    // "children" object
    var children_obj = std.json.ObjectMap.init(allocator);
    var child_par_arr = std.json.Array.init(allocator);
    for (child_parallel) |id| {
        try child_par_arr.append(.{ .integer = id });
    }
    try children_obj.put("Chained", .{ .array = std.json.Array.init(allocator) });
    try children_obj.put("Directly chained", .{ .array = std.json.Array.init(allocator) });
    try children_obj.put("Parallel", .{ .array = child_par_arr });
    try obj.put("children", .{ .object = children_obj });

    return obj;
}

test "DependencyWalker: single job, no deps" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var walker = try DependencyWalker.init(a, 100, .{ .from_url = "http://src" });

    // First call to next() returns the origin
    const item = walker.next().?;
    try std.testing.expectEqual(@as(u64, 100), item.job_id);
    try std.testing.expectEqual(@as(u32, 1), item.depth);
    try std.testing.expectEqual(Relation.origin, item.relation);

    // Feed a job with no deps
    const job_obj = try makeTestJobObj(a, "origin_job", &.{}, &.{});
    try walker.feed(a, item, job_obj);

    // BFS is complete
    try std.testing.expectEqual(@as(?DependencyWalker.WorkItem, null), walker.next());
    try std.testing.expectEqual(@as(usize, 1), walker.collected.items.len);
    try std.testing.expectEqualStrings("origin_job", walker.collected.items[0].name);
}

test "DependencyWalker: follows parent chained deps" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var walker = try DependencyWalker.init(a, 10, .{ .from_url = "http://src" });

    // Process origin (has parent dep 20)
    const item1 = walker.next().?;
    try std.testing.expectEqual(@as(u64, 10), item1.job_id);
    const obj1 = try makeTestJobObj(a, "job10", &.{20}, &.{});
    try walker.feed(a, item1, obj1);

    // Process parent 20 (no further deps)
    const item2 = walker.next().?;
    try std.testing.expectEqual(@as(u64, 20), item2.job_id);
    try std.testing.expectEqual(@as(u32, 2), item2.depth);
    try std.testing.expectEqual(Relation.parents, item2.relation);
    const obj2 = try makeTestJobObj(a, "job20", &.{}, &.{});
    try walker.feed(a, item2, obj2);

    // Done
    try std.testing.expectEqual(@as(?DependencyWalker.WorkItem, null), walker.next());
    try std.testing.expectEqual(@as(usize, 2), walker.collected.items.len);
}

test "DependencyWalker: cycle detection skips already-collected" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var walker = try DependencyWalker.init(a, 1, .{ .from_url = "http://src" });

    // Job 1 depends on job 2
    const item1 = walker.next().?;
    const obj1 = try makeTestJobObj(a, "job1", &.{2}, &.{});
    try walker.feed(a, item1, obj1);

    // Job 2 depends on job 1 (cycle!)
    const item2 = walker.next().?;
    try std.testing.expectEqual(@as(u64, 2), item2.job_id);
    const obj2 = try makeTestJobObj(a, "job2", &.{1}, &.{});
    try walker.feed(a, item2, obj2);

    // Job 1 is already collected — next() skips it and returns null
    try std.testing.expectEqual(@as(?DependencyWalker.WorkItem, null), walker.next());
    try std.testing.expectEqual(@as(usize, 2), walker.collected.items.len);
}

test "DependencyWalker: skip_deps prevents parent traversal" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var walker = try DependencyWalker.init(a, 10, .{
        .from_url = "http://src",
        .skip_deps = true,
    });

    const item = walker.next().?;
    // Job 10 has parent 20, but skip_deps is set
    const obj = try makeTestJobObj(a, "job10", &.{20}, &.{});
    try walker.feed(a, item, obj);

    // Parent 20 was NOT enqueued
    try std.testing.expectEqual(@as(?DependencyWalker.WorkItem, null), walker.next());
    try std.testing.expectEqual(@as(usize, 1), walker.collected.items.len);
}

test "DependencyWalker: skip_chained_deps skips chained but allows parallel parents" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var walker = try DependencyWalker.init(a, 10, .{
        .from_url = "http://src",
        .skip_chained_deps = true,
    });

    const item = walker.next().?;

    // Build a job with chained parent 20 and parallel parent 30
    var obj = std.json.ObjectMap.init(a);
    try obj.put("name", .{ .string = "job10" });
    var settings_obj = std.json.ObjectMap.init(a);
    try settings_obj.put("TEST", .{ .string = "job10" });
    try obj.put("settings", .{ .object = settings_obj });

    var parents_obj = std.json.ObjectMap.init(a);
    var chained_arr = std.json.Array.init(a);
    try chained_arr.append(.{ .integer = 20 });
    try parents_obj.put("Chained", .{ .array = chained_arr });
    try parents_obj.put("Directly chained", .{ .array = std.json.Array.init(a) });
    var parallel_arr = std.json.Array.init(a);
    try parallel_arr.append(.{ .integer = 30 });
    try parents_obj.put("Parallel", .{ .array = parallel_arr });
    try obj.put("parents", .{ .object = parents_obj });

    var children_obj = std.json.ObjectMap.init(a);
    try children_obj.put("Chained", .{ .array = std.json.Array.init(a) });
    try children_obj.put("Directly chained", .{ .array = std.json.Array.init(a) });
    try children_obj.put("Parallel", .{ .array = std.json.Array.init(a) });
    try obj.put("children", .{ .object = children_obj });

    try walker.feed(a, item, obj);

    // Only parallel parent 30 was enqueued (chained 20 skipped)
    const item2 = walker.next().?;
    try std.testing.expectEqual(@as(u64, 30), item2.job_id);
    const obj2 = try makeTestJobObj(a, "job30", &.{}, &.{});
    try walker.feed(a, item2, obj2);

    try std.testing.expectEqual(@as(?DependencyWalker.WorkItem, null), walker.next());
    try std.testing.expectEqual(@as(usize, 2), walker.collected.items.len);
}

test "DependencyWalker: max_depth limits child traversal" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // max_depth=1: only origin's immediate children
    var walker = try DependencyWalker.init(a, 1, .{
        .from_url = "http://src",
        .max_depth = 1,
    });

    // Origin (depth=1) has child 2 (parallel)
    const item1 = walker.next().?;
    const obj1 = try makeTestJobObj(a, "job1", &.{}, &.{2});
    try walker.feed(a, item1, obj1);

    // Child 2 (depth=2) has child 3 (parallel) — but depth > max_depth, so NOT enqueued
    const item2 = walker.next().?;
    try std.testing.expectEqual(@as(u64, 2), item2.job_id);
    try std.testing.expectEqual(@as(u32, 2), item2.depth);
    const obj2 = try makeTestJobObj(a, "job2", &.{}, &.{3});
    try walker.feed(a, item2, obj2);

    // Job 3 not enqueued due to depth limit
    try std.testing.expectEqual(@as(?DependencyWalker.WorkItem, null), walker.next());
    try std.testing.expectEqual(@as(usize, 2), walker.collected.items.len);
}

test "DependencyWalker: clone_children enables chained child traversal" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var walker = try DependencyWalker.init(a, 1, .{
        .from_url = "http://src",
        .clone_children = true,
    });

    // Origin has chained child 5 (via "Chained" in children)
    const item1 = walker.next().?;

    var obj = std.json.ObjectMap.init(a);
    try obj.put("name", .{ .string = "job1" });
    var settings_obj = std.json.ObjectMap.init(a);
    try settings_obj.put("TEST", .{ .string = "job1" });
    try obj.put("settings", .{ .object = settings_obj });
    var parents_obj = std.json.ObjectMap.init(a);
    try parents_obj.put("Chained", .{ .array = std.json.Array.init(a) });
    try parents_obj.put("Directly chained", .{ .array = std.json.Array.init(a) });
    try parents_obj.put("Parallel", .{ .array = std.json.Array.init(a) });
    try obj.put("parents", .{ .object = parents_obj });
    var children_obj = std.json.ObjectMap.init(a);
    var chained_arr = std.json.Array.init(a);
    try chained_arr.append(.{ .integer = 5 });
    try children_obj.put("Chained", .{ .array = chained_arr });
    try children_obj.put("Directly chained", .{ .array = std.json.Array.init(a) });
    try children_obj.put("Parallel", .{ .array = std.json.Array.init(a) });
    try obj.put("children", .{ .object = children_obj });

    try walker.feed(a, item1, obj);

    // Chained child 5 was enqueued because clone_children=true
    const item2 = walker.next().?;
    try std.testing.expectEqual(@as(u64, 5), item2.job_id);
    try std.testing.expectEqual(Relation.children, item2.relation);
}
