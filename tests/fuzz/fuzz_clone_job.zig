// Fuzz harness for the clone-job dependency graph algorithm
// (src/clone_job.zig: parseOverride, isGlobalSetting, assignExistingDeps,
//  applySettings, buildPostBody, formatOutput, formatExportCommand,
//  formatBadgeOutput, formatJsonOutput, appendRepeatSuffix,
//  injectReproduceSettings, extractAssets, isAssetGeneratedByClonedJobs,
//  shouldSkipUefiVarsAsset, extractJobSettings, extractDeps,
//  findSettingValue, collectRepoUrls, DependencyWalker).
//
// The module is I/O-free: the harness drives the caller-driven BFS walker
// with synthetic job objects decoded from the fuzz input, then runs the
// encode/override/format pipeline in the same order as
// src/clone_job_main.zig (phase 1 walk, --reproduce, phase 2 encode,
// --check-repos, asset filter, --export-command, output, --repeat).
//
// ---------------------------------------------------------------------------
// Corpus format
// ---------------------------------------------------------------------------
//
// Up to four sections separated by the literal "\n---\n":
//
//   <jobs JSON>
//   ---
//   <override lines>
//   ---
//   <control bytes>
//   ---
//   <server JSON>
//
// Missing trailing sections take defaults. An input with no separator is
// all section 1.
//
// Section 1: jobs (JSON array)
//   A JSON array of job objects shaped like the "job" field of
//   GET /api/v1/jobs/{id}. The harness answers walker item job_id with the
//   first element whose "id" equals it; an unknown ID gets an empty object,
//   so the walk always ends. Origin = the "id" of element 0 (default 1 when
//   the array is empty, not an array, or element 0 has no non-negative
//   integer id). Invalid JSON: phases 1-4 are skipped but section 2 is
//   still parsed, so override parsing is fuzzed even when the JSON breaks.
//
// Section 2: overrides (lines)
//   One override per "\n"-separated line, passed to parseOverride exactly
//   like the CLI positionals. Lines without "=" are dropped. Cap: first 64.
//
// Section 3: control bytes
//   Byte 0 bits:
//     bit 0: skip_deps
//     bit 1: skip_chained_deps
//     bit 2: clone_children
//     bit 3: parental_inheritance
//     bit 4: run injectReproduceSettings (needs "vars" in section 4)
//     bit 5: run the --repeat loop
//     bit 6: run collectRepoUrls on the origin job
//     bit 7: reserved
//   Byte 1: max_depth — 0xFF = null, else value & 0x0F (0 = unlimited in the
//           walker). Default 1 (CLI default).
//   Byte 2: repeat count = (value & 0x03) + 2 (only with bit 5). Default 2.
//
// Section 4: server JSON (optional object)
//   {"ids":{...},"vars":{...}}
//   "ids": the POST /api/v1/jobs reply for the three format*Output
//          functions. When missing or not an object, the harness builds one:
//          "<job_id>": job_id + 1000 for every final job.
//   "vars": the vars.json object for injectReproduceSettings, applied to
//           every collected job when control bit 4 is set.
//
// ---------------------------------------------------------------------------
// Safety
// ---------------------------------------------------------------------------
//
// The walk is capped at MAX_FEEDS feeds per iteration (the worklist can
// grow on adversarial graphs; next() skips collected IDs but not queued
// duplicates). Unknown job IDs map to an empty object, so the walk always
// ends. No I/O: the harness is crash-only (v1), consistent with the other
// four harnesses.

const std = @import("std");
const zoqa = @import("zoqa");
const clone_job = zoqa.clone_job;

const MAX_FEEDS = 64;
const MAX_OVERRIDES = 64;

const FROM_URL = "http://source.invalid";
const DEST_HOST = "https://dest.invalid";

// ---------------------------------------------------------------------------
// Decoded input
// ---------------------------------------------------------------------------

const Decoded = struct {
    jobs_json: []const u8,
    overrides: []const clone_job.Override,
    opts: clone_job.CloneOptions,
    server_json: []const u8,
};

// ---------------------------------------------------------------------------
// Walk result
// ---------------------------------------------------------------------------

const WalkResult = struct {
    walker: clone_job.DependencyWalker,
    assets: std.ArrayList(clone_job.AssetEntry),
};

// ---------------------------------------------------------------------------
// Encode result
// ---------------------------------------------------------------------------

const EncodeResult = struct {
    final_jobs: std.ArrayList(clone_job.JobEntry),
    post_body: []const u8,
};

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

    // ------------------------------------------------------------------
    // Decode: section splitting, override parsing, control bytes
    // ------------------------------------------------------------------
    const decoded = decode(input, allocator);

    // parseOverride is exercised even when the jobs JSON is broken.
    // ORACLE: O2 — a non-null parseOverride result has no '=' in key or scope.
    _ = decoded.overrides;

    // ------------------------------------------------------------------
    // Parse section 1 (jobs JSON) into the arena. On failure, skip the
    // walk/encode/format/repeat phases (override parsing already ran).
    // ------------------------------------------------------------------
    const jobs_root = std.json.parseFromSliceLeaky(std.json.Value, allocator, decoded.jobs_json, .{}) catch return;

    // Build the job lookup table: id -> job ObjectMap.
    var jobs: std.ArrayList(struct { id: u64, obj: std.json.ObjectMap }) = .empty;
    defer jobs.deinit(allocator);

    var origin: u64 = 1;
    if (jobs_root == .array) {
        for (jobs_root.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const id_val = obj.get("id") orelse continue;
            const id: u64 = switch (id_val) {
                .integer => |i| std.math.cast(u64, i) orelse continue,
                else => continue,
            };
            jobs.append(allocator, .{ .id = id, .obj = obj }) catch return;
        }
        if (jobs.items.len > 0) origin = jobs.items[0].id;
    }

    // ------------------------------------------------------------------
    // Phase 1: walk (BFS with feed cap)
    // ------------------------------------------------------------------
    var walk: WalkResult = undefined;
    {
        var walker = clone_job.DependencyWalker.init(allocator, origin, decoded.opts) catch return;
        var all_assets: std.ArrayList(clone_job.AssetEntry) = .empty;

        var feeds: u32 = 0;
        while (walker.next()) |item| {
            if (feeds >= MAX_FEEDS) break;
            feeds += 1;

            // Look up the job object by id; unknown IDs get an empty object.
            var job_obj: std.json.ObjectMap = undefined;
            var found = false;
            for (jobs.items) |entry| {
                if (entry.id == item.job_id) {
                    job_obj = entry.obj;
                    found = true;
                    break;
                }
            }
            if (!found) {
                job_obj = std.json.ObjectMap.init(allocator);
            }

            walker.feed(allocator, item, job_obj) catch return;

            const job_assets = clone_job.extractAssets(allocator, job_obj, item.job_id) catch return;
            for (job_assets) |asset| {
                all_assets.append(allocator, asset) catch return;
            }
        }

        // ORACLE: O1 — collected job IDs are unique and collected.len <= MAX_FEEDS.
        walk = .{ .walker = walker, .assets = all_assets };
    }

    // ------------------------------------------------------------------
    // --reproduce: inject vars.json settings (bit 4, vars present)
    // ------------------------------------------------------------------
    if (reproduceFlag()) {
        const vars_obj = getVarsObject(decoded.server_json, allocator) orelse return;
        for (walk.walker.collected.items) |*entry| {
            clone_job.injectReproduceSettings(allocator, &entry.settings, vars_obj) catch return;
        }
    }

    // ------------------------------------------------------------------
    // Phase 2: encode deps + apply overrides + build POST body
    // ------------------------------------------------------------------
    const encode = runEncode(allocator, walk.walker.collected.items, decoded.overrides, decoded.opts) catch return;

    // ------------------------------------------------------------------
    // --check-repos (bit 6, origin job only)
    // ------------------------------------------------------------------
    if (checkReposFlag() and encode.final_jobs.items.len > 0) {
        const repo_result = clone_job.collectRepoUrls(allocator, encode.final_jobs.items[0].settings.items) catch return;
        _ = repo_result;
    }

    // ------------------------------------------------------------------
    // Asset filter: isAssetGeneratedByClonedJobs + shouldSkipUefiVarsAsset
    // ------------------------------------------------------------------
    const skipped_parents = decoded.opts.skip_deps or decoded.opts.skip_chained_deps;
    for (walk.assets.items) |asset| {
        _ = clone_job.isAssetGeneratedByClonedJobs(asset.filename, encode.final_jobs.items);
        _ = clone_job.shouldSkipUefiVarsAsset(asset.filename, encode.final_jobs.items, skipped_parents);
    }

    // ------------------------------------------------------------------
    // Output: formatExportCommand + the three format*Output functions
    // ------------------------------------------------------------------
    {
        const ids_map = getIdsMap(allocator, decoded.server_json, encode.final_jobs.items) catch return orelse return;

        const export_cmd = clone_job.formatExportCommand(allocator, encode.final_jobs.items, DEST_HOST) catch return;
        _ = export_cmd;

        const out = clone_job.formatOutput(allocator, ids_map, encode.final_jobs.items, DEST_HOST) catch return;
        _ = out;

        const badge = clone_job.formatBadgeOutput(allocator, ids_map, encode.final_jobs.items, DEST_HOST) catch return;
        _ = badge;

        const json_out = clone_job.formatJsonOutput(allocator, ids_map) catch return;
        // ORACLE: O5 — formatJsonOutput output parses as a JSON object.
        _ = json_out;
    }

    // ------------------------------------------------------------------
    // --repeat loop (bit 5): appendRepeatSuffix + buildPostBody per iter
    // ------------------------------------------------------------------
    if (repeatFlag()) {
        const count = repeatCount();
        for (1..count + 1) |i| {
            clone_job.appendRepeatSuffix(allocator, encode.final_jobs.items, @intCast(i)) catch return;
            const iter_body = clone_job.buildPostBody(allocator, encode.final_jobs.items) catch return;
            // ORACLE: O4 — buildPostBody output ends with is_clone_job=1.
            _ = iter_body;
        }
    }
}

// ---------------------------------------------------------------------------
// Control-byte helpers
// ---------------------------------------------------------------------------
//
// The control bytes are decoded in `decode` into CloneOptions booleans, but
// the harness also needs the raw bits for reproduce/repeat/check-repos.
// They are stored in a global set per iteration (AFL++ persistent mode is
// single-threaded, so a global is safe and avoids threading the bytes
// through every function).

var g_control: [3]u8 = .{ 0, 1, 0 };

fn reproduceFlag() bool {
    return (g_control[0] & 0x10) != 0;
}

fn repeatFlag() bool {
    return (g_control[0] & 0x20) != 0;
}

fn checkReposFlag() bool {
    return (g_control[0] & 0x40) != 0;
}

fn repeatCount() u32 {
    return (g_control[2] & 0x03) + 2;
}

// ---------------------------------------------------------------------------
// decode — section splitting, override parsing, control bytes
// ---------------------------------------------------------------------------

fn decode(input: []const u8, allocator: std.mem.Allocator) Decoded {
    const sep = "\n---\n";

    var jobs_json: []const u8 = input;
    var overrides_raw: []const u8 = "";
    var control: [3]u8 = .{ 0, 1, 0 };
    var server_json: []const u8 = "";

    // Split up to 3 separators.
    var rest = input;
    var found: usize = 0;
    while (found < 3) {
        const pos = std.mem.indexOf(u8, rest, sep) orelse break;
        switch (found) {
            0 => jobs_json = rest[0..pos],
            1 => overrides_raw = rest[0..pos],
            else => {
                const ctrl = rest[0..pos];
                if (ctrl.len > 0) control[0] = ctrl[0];
                if (ctrl.len > 1) control[1] = ctrl[1];
                if (ctrl.len > 2) control[2] = ctrl[2];
            },
        }
        rest = rest[pos + sep.len ..];
        found += 1;
    }
    // If exactly 2 separators were found, `rest` holds the control bytes
    // (section 3). Decode them here.
    if (found == 2) {
        if (rest.len > 0) control[0] = rest[0];
        if (rest.len > 1) control[1] = rest[1];
        if (rest.len > 2) control[2] = rest[2];
    }
    if (found == 3) server_json = rest;

    g_control = control;

    // Control byte 1: max_depth (0xFF = null, else value & 0x0F).
    const max_depth: ?u32 = if (control[1] == 0xFF) null else @as(u32, control[1] & 0x0F);

    const opts = clone_job.CloneOptions{
        .skip_deps = (control[0] & 0x01) != 0,
        .skip_chained_deps = (control[0] & 0x02) != 0,
        .clone_children = (control[0] & 0x04) != 0,
        .parental_inheritance = (control[0] & 0x08) != 0,
        .max_depth = max_depth,
        .from_url = FROM_URL,
    };

    // Parse overrides: one per line, first MAX_OVERRIDES lines.
    var overrides: std.ArrayList(clone_job.Override) = .empty;
    defer overrides.deinit(allocator);
    var line_it = std.mem.splitScalar(u8, overrides_raw, '\n');
    var count: usize = 0;
    while (line_it.next()) |line| {
        if (count >= MAX_OVERRIDES) break;
        if (line.len == 0) continue;
        if (clone_job.parseOverride(line)) |ov| {
            overrides.append(allocator, ov) catch return Decoded{
                .jobs_json = jobs_json,
                .overrides = &[_]clone_job.Override{},
                .opts = opts,
                .server_json = server_json,
            };
        }
        count += 1;
    }

    const overrides_owned = overrides.toOwnedSlice(allocator) catch &[_]clone_job.Override{};

    return Decoded{
        .jobs_json = jobs_json,
        .overrides = overrides_owned,
        .opts = opts,
        .server_json = server_json,
    };
}

// ---------------------------------------------------------------------------
// runEncode — assignExistingDeps + applySettings + buildPostBody
// ---------------------------------------------------------------------------

fn runEncode(
    allocator: std.mem.Allocator,
    collected: []clone_job.DependencyWalker.CollectedEntry,
    overrides: []const clone_job.Override,
    opts: clone_job.CloneOptions,
) !EncodeResult {
    // Build a lookup table of JobEntry for dependency filtering.
    // NOTE: lookup_entries copies each settings ArrayList by value;
    // assignExistingDeps later appends to the original, so the copy can
    // point at reallocated memory. Harmless with an arena (nothing is
    // freed, and the lookup only reads job_id).
    var lookup_entries: std.ArrayList(clone_job.JobEntry) = .empty;
    defer lookup_entries.deinit(allocator);
    for (collected) |c| {
        try lookup_entries.append(allocator, .{
            .job_id = c.job_id,
            .settings = c.settings,
            .name = c.name,
            .has_parents = c.parent_chained.len > 0 or c.parent_directly_chained.len > 0 or c.parent_parallel.len > 0,
        });
    }

    var final_jobs: std.ArrayList(clone_job.JobEntry) = .empty;
    defer final_jobs.deinit(allocator);

    for (collected) |*entry| {
        try clone_job.assignExistingDeps(allocator, &entry.settings, "_PARALLEL", entry.parent_parallel, lookup_entries.items);
        try clone_job.assignExistingDeps(allocator, &entry.settings, "_START_AFTER", entry.parent_chained, lookup_entries.items);
        try clone_job.assignExistingDeps(allocator, &entry.settings, "_START_DIRECTLY_AFTER", entry.parent_directly_chained, lookup_entries.items);

        const override_depth: u32 = if (entry.relation == .children) 0 else entry.depth;
        try clone_job.applySettings(allocator, &entry.settings, overrides, override_depth, opts.parental_inheritance);

        try final_jobs.append(allocator, .{
            .job_id = entry.job_id,
            .settings = entry.settings,
            .name = entry.name,
            .has_parents = entry.parent_chained.len > 0 or entry.parent_directly_chained.len > 0 or entry.parent_parallel.len > 0,
        });
    }

    const post_body = try clone_job.buildPostBody(allocator, final_jobs.items);
    // ORACLE: O4 — buildPostBody output ends with is_clone_job=1.

    const final_jobs_owned = try final_jobs.toOwnedSlice(allocator);
    return EncodeResult{
        .final_jobs = std.ArrayList(clone_job.JobEntry).fromOwnedSlice(final_jobs_owned),
        .post_body = post_body,
    };
}

// ---------------------------------------------------------------------------
// Section 4 helpers
// ---------------------------------------------------------------------------

fn getIdsMap(
    allocator: std.mem.Allocator,
    server_json: []const u8,
    final_jobs: []const clone_job.JobEntry,
) !?std.json.ObjectMap {
    if (server_json.len > 0) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, server_json, .{}) catch return null;
        if (parsed == .object) {
            if (parsed.object.get("ids")) |ids_val| {
                if (ids_val == .object) return ids_val.object;
            }
        }
    }
    // Synthetic: "<job_id>": job_id + 1000 for every final job.
    var map = std.json.ObjectMap.init(allocator);
    for (final_jobs) |job| {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{job.job_id}) catch return null;
        try map.put(key, .{ .integer = @as(i64, @intCast(job.job_id + 1000)) });
    }
    return map;
}

fn getVarsObject(server_json: []const u8, allocator: std.mem.Allocator) ?std.json.ObjectMap {
    if (server_json.len == 0) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, server_json, .{}) catch return null;
    if (parsed != .object) return null;
    const vars_val = parsed.object.get("vars") orelse return null;
    return switch (vars_val) {
        .object => |o| o,
        else => null,
    };
}
