//! zoqa — public library API
//!
//! This file is the single point of contact for any consumer of the zoqa
//! library: CLIs, GUIs, embedded test harnesses, etc. Every public symbol
//! is exposed here.
//!
//! Internal modules (http_client, monitor, schedule, archive, config, auth)
//! do NOT import this file — they depend only on each other and on stdlib.
//! The library tree is acyclic.
//!
//! Test discovery note: acyclicity is necessary but NOT sufficient.
//! Zig's lazy semantic analysis only registers `test` blocks from files
//! that get fully analyzed; a top-level `pub const X = file.X;` does
//! NOT force that analysis. The anonymous `test {}` aggregator at the
//! bottom of this file imports every library source file from inside a
//! test body so their tests get discovered. Same idiom as
//! `test/behavior.zig` in ziglang/zig. See
//! https://github.com/ziglang/zig/issues/10018.
//!
//! API tiers (in dependency order):
//!   1. Config & auth        — zoqa.config, zoqa.auth
//!   2. HTTP request layer   — zoqa.openQAReq, zoqa.CallOptions, ...
//!   3. Response parsers     — zoqa.parseLinkHeader, zoqa.LinkIterator
//!   4. High-level workflows — zoqa.runArchive, zoqa.runMonitor, zoqa.runSchedule

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Tier 1 — Configuration & auth
// ---------------------------------------------------------------------------

pub const config = @import("config.zig");
pub const auth = @import("auth.zig");

// ---------------------------------------------------------------------------
// Tier 2 — HTTP request layer (definitions live in http_client.zig)
// ---------------------------------------------------------------------------

const http_client = @import("http_client.zig");

pub const APIResponse = http_client.APIResponse;
pub const StreamResult = http_client.StreamResult;
pub const CallOptions = http_client.CallOptions;
pub const RawGetOptions = http_client.RawGetOptions;
pub const openQAReq = http_client.openQAReq;
pub const openQARawGet = http_client.openQARawGet;

// ---------------------------------------------------------------------------
// Tier 3 — Response parsers (defined here; pure stdlib, no zoqa-internal deps)
// ---------------------------------------------------------------------------

/// Zero-allocation iterator over `(rel, url)` pairs in an RFC 5988
/// `Link` response header.
///
/// Lazily parses comma-separated link entries, yielding one `Relation`
/// per valid entry. Malformed entries (missing `<>` delimiters, missing
/// `rel=` parameter, empty rel value) are silently skipped — never an
/// error.
///
/// All returned slices **borrow** from the original header string.
/// No allocation, no `deinit` needed. The iterator itself is a small
/// stack value (wraps a `std.mem.SplitIterator`).
///
/// Created by `parseLinkHeader`.
pub const LinkIterator = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    /// A single parsed link relation: a `rel` name and its associated URL.
    pub const Relation = struct { rel: []const u8, url: []const u8 };

    /// Return the next valid `(rel, url)` pair, or `null` when exhausted.
    pub fn next(self: *LinkIterator) ?Relation {
        while (self.inner.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t");
            const url_start = std.mem.indexOfScalar(u8, trimmed, '<') orelse continue;
            const url_end = std.mem.indexOfScalar(u8, trimmed, '>') orelse continue;
            if (url_end <= url_start) continue;
            const url = trimmed[url_start + 1 .. url_end];

            var params = std.mem.splitScalar(u8, trimmed[url_end + 1 ..], ';');
            while (params.next()) |param| {
                const p = std.mem.trim(u8, param, " \t");
                if (std.mem.startsWith(u8, p, "rel=")) {
                    var r = p[4..];
                    if (r.len >= 2 and r[0] == '"' and r[r.len - 1] == '"') {
                        r = r[1 .. r.len - 1];
                    }
                    if (r.len > 0) {
                        return .{ .rel = r, .url = url };
                    }
                }
            }
        }
        return null;
    }
};

/// Parse an RFC 5988 `Link` header value into an iterator of
/// `(rel, url)` pairs.
///
/// The returned `LinkIterator` yields one `Relation` per valid
/// comma-separated entry in the header. Zero allocation — all
/// returned slices borrow from `header`.
///
/// ```zig
/// var it = zoqa.parseLinkHeader(resp.link.?);
/// while (it.next()) |link| {
///     try stderr.print("{s}: {s}\n", .{ link.rel, link.url });
/// }
/// ```
pub fn parseLinkHeader(header: []const u8) LinkIterator {
    return .{ .inner = std.mem.splitScalar(u8, header, ',') };
}

// ---------------------------------------------------------------------------
// Tier 4 — High-level workflows
// ---------------------------------------------------------------------------

const archive = @import("archive.zig");
const monitor = @import("monitor.zig");
const schedule = @import("schedule.zig");

pub const ArchiveOptions = archive.ArchiveOptions;
pub const runArchive = archive.runArchive;

pub const JobState = monitor.JobState;
pub const JobResult = monitor.JobResult;
pub const JobStatus = monitor.JobStatus;
pub const MonitorOptions = monitor.MonitorOptions;
pub const checkJobStatus = monitor.checkJobStatus;
pub const exitCodeForStatuses = monitor.exitCodeForStatuses;
pub const runMonitor = monitor.runMonitor;

pub const ScheduleOptions = schedule.ScheduleOptions;
pub const runSchedule = schedule.runSchedule;

// ---------------------------------------------------------------------------
// Tests — parseLinkHeader (Tier 3, defined in this file)
// ---------------------------------------------------------------------------

test "parseLinkHeader: multiple relations in header order" {
    const header = "</api/v1/jobs?offset=0>; rel=\"first\", </api/v1/jobs?offset=10>; rel=\"next\"";
    var it = parseLinkHeader(header);

    const first = it.next().?;
    try testing.expectEqualStrings("first", first.rel);
    try testing.expectEqualStrings("/api/v1/jobs?offset=0", first.url);

    const second = it.next().?;
    try testing.expectEqualStrings("next", second.rel);
    try testing.expectEqualStrings("/api/v1/jobs?offset=10", second.url);

    try testing.expect(it.next() == null);
}

test "parseLinkHeader: empty header yields nothing" {
    var it = parseLinkHeader("");
    try testing.expect(it.next() == null);
}

test "parseLinkHeader: malformed entries are skipped" {
    const header = "no-angles, <valid-url>; rel=\"good\", ; rel=\"no-url\"";
    var it = parseLinkHeader(header);

    const good = it.next().?;
    try testing.expectEqualStrings("good", good.rel);
    try testing.expectEqualStrings("valid-url", good.url);

    try testing.expect(it.next() == null);
}

test "parseLinkHeader: entry without rel parameter is skipped" {
    const header = "<url1>; type=\"text/html\", <url2>; rel=\"found\"";
    var it = parseLinkHeader(header);

    const found = it.next().?;
    try testing.expectEqualStrings("found", found.rel);
    try testing.expectEqualStrings("url2", found.url);

    try testing.expect(it.next() == null);
}

test "parseLinkHeader: unquoted rel value" {
    const header = "<url>; rel=next";
    var it = parseLinkHeader(header);

    const rel = it.next().?;
    try testing.expectEqualStrings("next", rel.rel);
    try testing.expectEqualStrings("url", rel.url);

    try testing.expect(it.next() == null);
}

test "parseLinkHeader: quoted rel value" {
    const header = "<url>; rel=\"prev\"";
    var it = parseLinkHeader(header);

    const rel = it.next().?;
    try testing.expectEqualStrings("prev", rel.rel);
    try testing.expectEqualStrings("url", rel.url);

    try testing.expect(it.next() == null);
}

test "re-exports: APIResponse accessible via zoqa" {
    const T = APIResponse;
    _ = T;
}

// ---------------------------------------------------------------------------
// Test discovery aggregator
//
// Zig's lazy semantic analysis only registers `test` blocks from files that
// get fully analyzed. A top-level `const x = @import("foo.zig");` is NOT
// enough — without a reference from inside a `test` block, `foo.zig`'s
// tests are silently dropped from `zig build test`. This anonymous test
// forces analysis of every library source file so their tests run.
//
// IMPORTANT: when adding a new file under src/, add a corresponding
// `_ = @import("newfile.zig");` line below or its tests will silently
// disappear from `zig build test`. The `make zig-test-discovery` target
// (tools/check_test_count.sh) catches this drift in CI.
//
// Same idiom as test/behavior.zig in ziglang/zig.
// See https://github.com/ziglang/zig/issues/10018.
// ---------------------------------------------------------------------------
test {
    _ = @import("auth.zig");
    _ = @import("config.zig");
    _ = @import("http_client.zig");
    _ = @import("monitor.zig");
    _ = @import("schedule.zig");
    _ = @import("archive.zig");
}
