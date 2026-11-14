// Fuzz harness for the clone-job dependency graph algorithm
// (src/clone_job.zig: parseOverride, isGlobalSetting, assignExistingDeps,
//  applySettings, buildPostBody, formatOutput, formatExportCommand,
//  formatBadgeOutput, formatJsonOutput, appendRepeatSuffix,
//  injectReproduceSettings, extractAssets, isAssetGeneratedByClonedJobs,
//  shouldSkipUefiVarsAsset, extractJobSettings, extractDeps,
//  findSettingValue, collectRepoUrls, DependencyWalker).
//
// In addition to graph traversal and payload formatting, the harness
// exercises the asset download pipeline (src/clone_job_main.zig: downloadAssets)
// via zoqa.openQADownloadToFile and an in-memory FileBackend (PR #42).
//
// ---------------------------------------------------------------------------
// Oracles
// ---------------------------------------------------------------------------
//
//   O1: Collected job IDs are unique and collected.len <= MAX_FEEDS.
//   O2: A non-null parseOverride result has no '=' in key or scope.
//   O3: Dependency graph closure: final_jobs.len == collected.len.
//   O4: buildPostBody output ends with is_clone_job=1.
//   O5: formatJsonOutput output parses as a valid JSON object.
//   O6: Terminal download error triggers backend.delete() (no partial file).
//   O7: 416 Range triggers skip-if-complete (mtime touch, 0 bytes streamed).
//   O8: 200 OK download streams exact payload with zero byte corruption.
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
//     bit 7: run asset download simulation (in-memory FileBackend)
//   Byte 1:
//     bits 0-3: max_depth - 0x0F = null, else value & 0x0F (0 = unlimited).
//               Default 1 (CLI default). If full byte is 0xFF, max_depth is null.
//     bits 4-5: asset download mock mode:
//               0 = 200 OK (stream verify)
//               1 = 416 Range Not Satisfiable (skip-if-complete probe)
//               2 = 404 Not Found (terminal error cleanup)
//               3 = HTML challenge (reject_html detection & cleanup)
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
// ends. No disk I/O: the asset download stage uses an in-memory mock backend.

const std = @import("std");
const zoqa = @import("zoqa");
const clone_job = zoqa.clone_job;
const mock_client = @import("mock_client.zig");
const ProgrammableMockClient = mock_client.ProgrammableMockClient;

const MAX_FEEDS = 64;
const MAX_OVERRIDES = 64;

const FROM_URL = "http://source.invalid";
const DEST_HOST = "https://dest.invalid";

// ---------------------------------------------------------------------------
// In-memory FileBackend (PR #42)
// ---------------------------------------------------------------------------

const FuzzFileSink = struct {
    aw: std.Io.Writer.Allocating,
    updated: bool = false,
    write_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) FuzzFileSink {
        return .{ .aw = .init(allocator) };
    }

    pub fn writer(self: *FuzzFileSink, _: []u8) *std.Io.Writer {
        return &self.aw.writer;
    }

    pub fn writeError(self: *FuzzFileSink) ?anyerror {
        return self.write_error;
    }

    pub fn updateTimes(self: *FuzzFileSink, _: u64, _: u64) !void {
        self.updated = true;
    }

    pub fn close(_: *FuzzFileSink) void {}

    pub fn deinit(self: *FuzzFileSink) void {
        self.aw.deinit();
    }

    pub fn written(self: *FuzzFileSink) []const u8 {
        return self.aw.writer.buffered();
    }
};

const FuzzFileBackend = struct {
    stat_size: ?u64 = null,
    sink: FuzzFileSink,
    touch_count: usize = 0,
    deleted: bool = false,

    pub fn init(allocator: std.mem.Allocator) FuzzFileBackend {
        return .{ .sink = .init(allocator) };
    }

    pub fn stat(self: *FuzzFileBackend, _: []const u8) !?u64 {
        return self.stat_size;
    }

    pub fn create(self: *FuzzFileBackend, _: []const u8) !*FuzzFileSink {
        self.sink.aw.clearRetainingCapacity();
        self.sink.updated = false;
        self.deleted = false;
        return &self.sink;
    }

    pub fn delete(self: *FuzzFileBackend, _: []const u8) void {
        self.deleted = true;
    }

    pub fn touch(self: *FuzzFileBackend, _: []const u8) !void {
        self.touch_count += 1;
    }

    pub fn deinit(self: *FuzzFileBackend) void {
        self.sink.deinit();
    }
};

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
// zig_fuzz_init - called once per AFL++ worker process
// ---------------------------------------------------------------------------

pub export fn zig_fuzz_init() void {}

// ---------------------------------------------------------------------------
// zig_fuzz_test - called in a tight loop by AFL++ persistent mode
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
    // ORACLE: O2 - a non-null parseOverride result has no '=' in key or scope.
    for (decoded.overrides) |ov| {
        std.debug.assert(std.mem.indexOfScalar(u8, ov.key, '=') == null);
        if (ov.scope) |sc| {
            std.debug.assert(std.mem.indexOfScalar(u8, sc, '=') == null);
        }
    }

    // ------------------------------------------------------------------
    // Phase 1: parse section 1 (jobs JSON) into the arena. On failure,
    // verify state hygiene and return (override parsing already ran).
    // ------------------------------------------------------------------
    const jobs_root = std.json.parseFromSliceLeaky(std.json.Value, allocator, decoded.jobs_json, .{}) catch {
        // State hygiene: overrides count strictly bounded
        std.debug.assert(decoded.overrides.len <= MAX_OVERRIDES);
        return;
    };

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

        // ORACLE: O1 - collected job IDs are unique and collected.len <= MAX_FEEDS.
        std.debug.assert(walker.collected.items.len <= MAX_FEEDS);
        for (walker.collected.items, 0..) |item_a, idx| {
            for (walker.collected.items[idx + 1 ..]) |item_b| {
                std.debug.assert(item_a.job_id != item_b.job_id);
            }
        }

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

    // ORACLE: O3 - graph closure: final_jobs length matches collected length.
    std.debug.assert(encode.final_jobs.items.len == walk.walker.collected.items.len);

    // ------------------------------------------------------------------
    // --check-repos (bit 6, origin job only)
    // ------------------------------------------------------------------
    if (checkReposFlag() and encode.final_jobs.items.len > 0) {
        const repo_result = clone_job.collectRepoUrls(allocator, encode.final_jobs.items[0].settings.items) catch return;
        _ = repo_result;
    }

    // ------------------------------------------------------------------
    // Phase 4: Asset filter & in-memory download simulation (PR #42)
    // ------------------------------------------------------------------
    const skipped_parents = decoded.opts.skip_deps or decoded.opts.skip_chained_deps;
    for (walk.assets.items) |asset| {
        const is_generated = clone_job.isAssetGeneratedByClonedJobs(asset.filename, encode.final_jobs.items);
        const should_skip = clone_job.shouldSkipUefiVarsAsset(asset.filename, encode.final_jobs.items, skipped_parents);

        if (downloadAssetsFlag() and !is_generated and !should_skip) {
            const type_str: []const u8 = switch (asset.asset_type) {
                .iso => "iso",
                .hdd => "hdd",
                .other => "other",
            };

            const dl_path = std.fmt.allocPrint(allocator, "/tests/{d}/asset/{s}/{s}", .{
                asset.job_id, type_str, asset.filename,
            }) catch return;

            const basename = if (std.mem.lastIndexOfScalar(u8, asset.filename, '/')) |idx|
                asset.filename[idx + 1 ..]
            else
                asset.filename;

            const dest_path = std.fmt.allocPrint(allocator, "assets/{s}/{s}", .{ type_str, basename }) catch return;

            var backend = FuzzFileBackend.init(allocator);
            defer backend.deinit();

            var client: ProgrammableMockClient = .{};
            const mode = assetMode();
            const dummy_body = "ZOQA_FUZZ_ASSET_PAYLOAD_1234567890";
            const html_body = "<!DOCTYPE html><html><body>Challenge</body></html>";

            switch (mode) {
                0 => { // 200 OK
                    client.response_status = .ok;
                    client.response_body = dummy_body;
                    client.response_content_length = dummy_body.len;
                    backend.stat_size = null;
                },
                1 => { // 416 Skip-if-complete
                    backend.stat_size = 1024;
                    client.response_status = .range_not_satisfiable;
                    client.response_body = "";
                    client.response_content_length = 0;
                },
                2 => { // 404 Not Found
                    backend.stat_size = null;
                    client.response_status = .not_found;
                    client.response_body = "Not Found";
                    client.response_content_length = 9;
                },
                3 => { // HTML challenge
                    backend.stat_size = null;
                    client.response_status = .ok;
                    client.custom_content_type = "text/html";
                    client.response_body = html_body;
                    client.response_content_length = html_body.len;
                },
            }

            const download_res = zoqa.openQADownloadToFile(FROM_URL, dl_path, dest_path, .{
                .allocator = allocator,
                .credentials = null,
                .quiet = true,
                .retries = 1,
                .retry_sleep_s = 0,
                .allow_lengthless = false,
            }, &client, &backend);

            switch (mode) {
                0 => {
                    // ORACLE: O8 - successful download streams exact payload.
                    if (download_res) |res| {
                        if (res.status == .ok) {
                            std.debug.assert(backend.sink.written().len == dummy_body.len);
                        }
                    } else |_| {}
                },
                1 => {
                    // ORACLE: O7 - 416 Range triggers skip-if-complete (touch, no re-download).
                    if (download_res) |res| {
                        if (res.status == .ok) {
                            std.debug.assert(backend.touch_count > 0);
                            std.debug.assert(backend.sink.written().len == 0);
                        }
                    } else |_| {}
                },
                2 => {
                    // ORACLE: O6 - non-2xx status triggers backend.delete().
                    if (download_res) |res| {
                        if (res.status == .not_found) {
                            std.debug.assert(backend.deleted);
                        }
                    } else |_| {
                        std.debug.assert(backend.deleted);
                    }
                },
                3 => {
                    // ORACLE: O6 - HTML challenge error triggers backend.delete().
                    if (download_res) |_| {
                        // If file ended with .html/.htm, UnexpectedHtmlResponse is suppressed
                    } else |err| {
                        if (err == error.UnexpectedHtmlResponse) {
                            std.debug.assert(backend.deleted);
                        }
                    }
                },
            }
        }
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
        // ORACLE: O5 - formatJsonOutput output parses as a JSON object.
        const is_valid_json = std.json.validate(allocator, json_out) catch return;
        std.debug.assert(is_valid_json);
    }

    // ------------------------------------------------------------------
    // --repeat loop (bit 5): appendRepeatSuffix + buildPostBody per iter
    // ------------------------------------------------------------------
    if (repeatFlag()) {
        const count = repeatCount();
        for (1..count + 1) |i| {
            clone_job.appendRepeatSuffix(allocator, encode.final_jobs.items, @intCast(i)) catch return;
            const iter_body = clone_job.buildPostBody(allocator, encode.final_jobs.items) catch return;
            // ORACLE: O4 - buildPostBody output ends with is_clone_job=1.
            std.debug.assert(std.mem.endsWith(u8, iter_body, "is_clone_job=1"));
        }
    }
}

// ---------------------------------------------------------------------------
// Control-byte helpers
// ---------------------------------------------------------------------------

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

fn downloadAssetsFlag() bool {
    return (g_control[0] & 0x80) != 0;
}

fn assetMode() u2 {
    return @intCast((g_control[1] >> 4) & 0x03);
}

fn repeatCount() u32 {
    return (g_control[2] & 0x03) + 2;
}

// ---------------------------------------------------------------------------
// decode - section splitting, override parsing, control bytes
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
// runEncode - assignExistingDeps + applySettings + buildPostBody
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
    // ORACLE: O4 - buildPostBody output ends with is_clone_job=1.
    std.debug.assert(std.mem.endsWith(u8, post_body, "is_clone_job=1"));

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
