const std = @import("std");
const arg_match = @import("arg_match");
const cli_credentials = @import("cli_credentials");
const zoqa = @import("zoqa");

// ---------------------------------------------------------------------------
// URL / JOBREF helpers
// ---------------------------------------------------------------------------

/// Returns true when every byte of `s` is an ASCII digit and `s` is non-empty.
///
/// Arguments:
/// - `s`: The byte slice to check.
///
/// Returns: `true` if `s` is non-empty and consists entirely of ASCII digits,
///   `false` otherwise.
fn isNumericId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}
test "isNumericId: digits only" {
    try std.testing.expect(isNumericId("42"));
    try std.testing.expect(isNumericId("12345"));
    try std.testing.expect(!isNumericId(""));
    try std.testing.expect(!isNumericId("42a"));
    try std.testing.expect(!isNumericId("a42"));
    try std.testing.expect(!isNumericId("http://host/t42"));
}

/// Returns true when `s` starts with "http://" or "https://".
///
/// Arguments:
/// - `s`: The byte slice to inspect for an HTTP scheme prefix.
///
/// Returns: `true` if `s` begins with either "http://" or "https://".
fn hasHttpScheme(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or
        std.mem.startsWith(u8, s, "https://");
}

test "hasHttpScheme: detection" {
    try std.testing.expect(hasHttpScheme("http://localhost"));
    try std.testing.expect(hasHttpScheme("https://openqa.opensuse.org"));
    try std.testing.expect(!hasHttpScheme("openqa.opensuse.org"));
    try std.testing.expect(!hasHttpScheme("ftp://example.com"));
    try std.testing.expect(!hasHttpScheme(""));
}

/// Extract a numeric job ID from an openQA URL path.
///
/// Recognised path patterns:
///   /t{digits}              — shortcut form (e.g. /t42)
///   /tests/{digits}[/...]   — canonical form (e.g. /tests/42)
///
/// Arguments:
/// - `path`: The URL path component to parse (e.g. "/tests/42/details").
///
/// Returns: The extracted job ID, or `null` if the path does not match either pattern.
fn extractJobIdFromPath(path: []const u8) ?u64 {
    // /tests/{id}[/...] — check longer prefix first (avoids false match on /t)
    const tests_pfx = "/tests/";
    if (std.mem.startsWith(u8, path, tests_pfx)) {
        const after = path[tests_pfx.len..];
        const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const id_part = after[0..end];
        if (isNumericId(id_part)) {
            return std.fmt.parseInt(u64, id_part, 10) catch null;
        }
    }

    // /t{id}[/...] — short alias (only reached if /tests/ didn't match)
    if (std.mem.startsWith(u8, path, "/t")) {
        const after_t = path[2..];
        const end = std.mem.indexOfScalar(u8, after_t, '/') orelse after_t.len;
        const id_part = after_t[0..end];
        if (isNumericId(id_part)) {
            return std.fmt.parseInt(u64, id_part, 10) catch null;
        }
    }

    return null;
}

test "extractJobIdFromPath: /t{id}" {
    try std.testing.expectEqual(@as(?u64, 42), extractJobIdFromPath("/t42"));
    try std.testing.expectEqual(@as(?u64, 1234), extractJobIdFromPath("/t1234"));
    // trailing slash variant
    try std.testing.expectEqual(@as(?u64, 7), extractJobIdFromPath("/t7/"));
    // non-numeric after /t
    try std.testing.expectEqual(@as(?u64, null), extractJobIdFromPath("/tests"));
    try std.testing.expectEqual(@as(?u64, null), extractJobIdFromPath("/top"));
}

test "extractJobIdFromPath: /tests/{id}" {
    try std.testing.expectEqual(@as(?u64, 42), extractJobIdFromPath("/tests/42"));
    try std.testing.expectEqual(@as(?u64, 100), extractJobIdFromPath("/tests/100/details"));
    try std.testing.expectEqual(@as(?u64, null), extractJobIdFromPath("/tests/"));
    try std.testing.expectEqual(@as(?u64, null), extractJobIdFromPath("/tests/abc"));
}

test "extractJobIdFromPath: no match" {
    try std.testing.expectEqual(@as(?u64, null), extractJobIdFromPath("/"));
    try std.testing.expectEqual(@as(?u64, null), extractJobIdFromPath(""));
    try std.testing.expectEqual(@as(?u64, null), extractJobIdFromPath("/jobs/42"));
}

// ---------------------------------------------------------------------------
// JOBREF parsing — mirrors CloneJob.pm split_jobid()
// ---------------------------------------------------------------------------

const SplitJobRefResult = struct {
    /// Allocated host URL (scheme://authority). Null when the input was a bare integer.
    host: ?[]u8,
    /// Numeric job ID found in the URL path, or null.
    job_id: ?u64,

    pub fn deinit(self: SplitJobRefResult, allocator: std.mem.Allocator) void {
        if (self.host) |h| allocator.free(h);
    }
};

/// Parse a JOBREF string into its host-URL and job-ID components.
///
/// Mirrors the Perl `split_jobid()` function (CloneJob.pm:236–246).
///
/// Accepted inputs:
///   "https://openqa.opensuse.org/t42"      → host="https://openqa.opensuse.org", id=42
///   "https://openqa.opensuse.org/tests/42" → host="https://openqa.opensuse.org", id=42
///   "openqa.opensuse.org/t42"              → host="http://openqa.opensuse.org", id=42
///   "openqa.opensuse.org"                  → host="http://openqa.opensuse.org", id=null
///   "42"                                   → host=null, id=42
///
/// The returned `host` is always an owned allocation; call `deinit` to free it.
///
/// Arguments:
/// - `allocator`: Used to allocate the returned host URL string.
/// - `input`: The raw JOBREF string from the CLI (URL, hostname, or bare integer).
///
/// Returns: A `SplitJobRefResult` with an optional owned host URL and optional job ID.
///
/// Errors:
///   error.InvalidUrl — the string is neither a numeric ID nor a parseable URL.
///   error.UrlTooLong — the URL (after prepending a scheme) exceeds an internal limit.
fn splitJobRef(allocator: std.mem.Allocator, input: []const u8) !SplitJobRefResult {
    // Case 1: bare integer
    if (isNumericId(input)) {
        return .{
            .host = null,
            .job_id = std.fmt.parseInt(u64, input, 10) catch unreachable,
        };
    }

    // Case 2: URL — prepend "http://" when no scheme is present (matching Perl behaviour)
    var url_buf: [4096]u8 = undefined;
    const url_str: []const u8 = if (hasHttpScheme(input))
        input
    else blk: {
        const needed = "http://".len + input.len;
        if (needed > url_buf.len) return error.UrlTooLong;
        @memcpy(url_buf[0.."http://".len], "http://");
        @memcpy(url_buf["http://".len..needed], input);
        break :blk url_buf[0..needed];
    };

    const uri = std.Uri.parse(url_str) catch return error.InvalidUrl;

    // Extract job ID from path
    const path = uri.path.percent_encoded;
    const job_id = extractJobIdFromPath(path);

    // Build host URL: scheme + "://" + authority (host + optional port)
    const host_component = uri.host orelse return error.InvalidUrl;
    const host_str = host_component.percent_encoded;
    const host_url: []u8 = if (uri.port) |p|
        try std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ uri.scheme, host_str, p })
    else
        try std.fmt.allocPrint(allocator, "{s}://{s}", .{ uri.scheme, host_str });

    return .{
        .host = host_url,
        .job_id = job_id,
    };
}

test "splitJobRef: bare integer" {
    const allocator = std.testing.allocator;
    var r = try splitJobRef(allocator, "42");
    defer r.deinit(allocator);
    try std.testing.expect(r.host == null);
    try std.testing.expectEqual(@as(?u64, 42), r.job_id);
}

test "splitJobRef: https URL with /t42" {
    const allocator = std.testing.allocator;
    var r = try splitJobRef(allocator, "https://openqa.opensuse.org/t42");
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("https://openqa.opensuse.org", r.host.?);
    try std.testing.expectEqual(@as(?u64, 42), r.job_id);
}

test "splitJobRef: https URL with /tests/42" {
    const allocator = std.testing.allocator;
    var r = try splitJobRef(allocator, "https://openqa.opensuse.org/tests/42");
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("https://openqa.opensuse.org", r.host.?);
    try std.testing.expectEqual(@as(?u64, 42), r.job_id);
}

test "splitJobRef: bare hostname prepends http scheme" {
    const allocator = std.testing.allocator;
    var r = try splitJobRef(allocator, "openqa.opensuse.org");
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("http://openqa.opensuse.org", r.host.?);
    try std.testing.expect(r.job_id == null);
}

test "splitJobRef: bare hostname with /t42 path" {
    const allocator = std.testing.allocator;
    var r = try splitJobRef(allocator, "openqa.opensuse.org/t42");
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("http://openqa.opensuse.org", r.host.?);
    try std.testing.expectEqual(@as(?u64, 42), r.job_id);
}

test "splitJobRef: http URL no path returns no job_id" {
    const allocator = std.testing.allocator;
    var r = try splitJobRef(allocator, "http://openqa.example.com");
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("http://openqa.example.com", r.host.?);
    try std.testing.expect(r.job_id == null);
}

test "splitJobRef: URL with port" {
    const allocator = std.testing.allocator;
    var r = try splitJobRef(allocator, "http://localhost:9526/t99");
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("http://localhost:9526", r.host.?);
    try std.testing.expectEqual(@as(?u64, 99), r.job_id);
}

// ---------------------------------------------------------------------------
// Host URL normalisation for --host
// ---------------------------------------------------------------------------

/// Normalise a hostname string from --host into a full URL.
///
/// Mirrors `OpenQA::Client::url_from_host()` (Client.pm:22–28):
///   - If the string already has a scheme (http/https), return a copy unchanged.
///   - If the string contains "localhost", use "http://".
///   - Otherwise use "https://".
///
/// The returned slice is always a new allocation; the caller must free it.
///
/// Arguments:
/// - `allocator`: Used to allocate the returned URL string.
/// - `host`: The raw hostname or URL from the `--host` flag.
///
/// Returns: A newly allocated URL string with a guaranteed scheme prefix.
///
/// Errors:
///   error.OutOfMemory — allocation failed.
fn normalizeHostUrl(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    if (hasHttpScheme(host)) return try allocator.dupe(u8, host);
    const scheme: []const u8 = if (std.mem.indexOf(u8, host, "localhost") != null)
        "http"
    else
        "https";
    return try std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, host });
}

test "normalizeHostUrl: already has http scheme" {
    const allocator = std.testing.allocator;
    const r = try normalizeHostUrl(allocator, "http://localhost");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("http://localhost", r);
}

test "normalizeHostUrl: already has https scheme" {
    const allocator = std.testing.allocator;
    const r = try normalizeHostUrl(allocator, "https://openqa.opensuse.org");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("https://openqa.opensuse.org", r);
}

test "normalizeHostUrl: bare localhost uses http" {
    const allocator = std.testing.allocator;
    const r = try normalizeHostUrl(allocator, "localhost");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("http://localhost", r);
}

test "normalizeHostUrl: bare non-localhost uses https" {
    const allocator = std.testing.allocator;
    const r = try normalizeHostUrl(allocator, "openqa.opensuse.org");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("https://openqa.opensuse.org", r);
}

// ---------------------------------------------------------------------------
// Settings helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// JOBREF resolution
// ---------------------------------------------------------------------------

const ResolvedJobRef = struct {
    /// Source openQA instance URL (scheme://host). Owned.
    from_url: []u8,
    /// Destination openQA instance URL (scheme://host). Owned.
    host_url: []u8,
    /// Numeric job ID to clone.
    job_id: u64,
    /// Whether to skip asset downloads.
    skip_download: bool,
    /// True when positionals[0] was consumed as the JOBREF.
    /// Overrides then start at positionals[1..]; otherwise at positionals[0..].
    jobref_consumed_positional: bool,

    pub fn deinit(self: ResolvedJobRef, allocator: std.mem.Allocator) void {
        allocator.free(self.from_url);
        allocator.free(self.host_url);
    }
};

/// Resolve a complete (from_url, host_url, job_id, skip_download) tuple from
/// the parsed CLI arguments.
///
/// Resolution order (mirrors openqa-clone-job:250–269):
///   1. --within-instance HOST_OR_URL  → expands to --skip-download --from HOST --host HOST,
///      with optional job ID extracted from the URL path.
///   2. --from HOST_OR_URL             → sets the source host; a job ID in the URL is used
///      when no positional provides one.
///   3. First positional (JOBREF)      → if a job ID is still unknown, the first positional
///      is parsed as a JOBREF; if it is a URL its host overrides --from.
///   4. Remaining positionals          → treated as KEY=[VALUE] setting overrides (not
///      consumed here; callers access them via args.positionals[1..] or [0..] depending
///      on whether the first positional was used as the JOBREF).
///   5. --host HOST                    → overrides the destination; defaults to localhost.
///
/// Arguments:
/// - `allocator`: Used to allocate the returned URL strings.
/// - `args`: Parsed CLI arguments (read-only; positionals are not consumed).
///
/// Returns: A `ResolvedJobRef` with owned from/host URLs, job ID, and flags.
///
/// Errors:
///   error.ConflictingOptions — both --within-instance and --from were supplied.
///   error.MissingFromHost    — no source host could be determined.
///   error.MissingJobId       — no job ID could be determined.
///   error.InvalidUrl         — a URL argument could not be parsed.
///   error.UrlTooLong         — a URL exceeded an internal buffer limit.
fn resolveJobRef(allocator: std.mem.Allocator, args: *const CloneArgs) !ResolvedJobRef {
    // Conflicting options guard
    if (args.within_instance != null and args.from != null) {
        return error.ConflictingOptions;
    }

    var from_url: ?[]u8 = null;
    var host_url: ?[]u8 = null;
    var job_id: ?u64 = null;
    var skip_download = args.skip_download;

    // Free any partial allocations on error
    errdefer {
        if (from_url) |u| allocator.free(u);
        if (host_url) |u| allocator.free(u);
    }

    // Step 1: --within-instance
    if (args.within_instance) |wi| {
        var result = try splitJobRef(allocator, wi);
        from_url = result.host orelse return error.MissingFromHost;
        result.host = null; // ownership transferred to from_url
        // host = same instance as from
        host_url = try allocator.dupe(u8, from_url.?);
        if (result.job_id) |id| job_id = id;
        skip_download = true;
    }

    // Step 2: --from
    if (args.from) |from| {
        var result = try splitJobRef(allocator, from);
        defer result.deinit(allocator); // frees result.host only if still non-null

        if (result.host) |h| {
            if (from_url) |old| allocator.free(old);
            from_url = h;
            result.host = null; // transfer ownership
        } else {
            // --from with a bare integer makes no sense
            return error.MissingFromHost;
        }
        if (result.job_id) |id| {
            if (job_id == null) job_id = id;
        }
    }

    // Step 3: first positional as JOBREF (only when job_id still unknown)
    const jobref_in_positional = job_id == null;
    if (jobref_in_positional) {
        if (args.positionals.items.len == 0) return error.MissingJobId;

        var result = try splitJobRef(allocator, args.positionals.items[0]);
        defer result.deinit(allocator);

        if (result.host) |h| {
            // A URL positional overrides --from (Perl §9.3 behaviour)
            if (from_url) |old| allocator.free(old);
            from_url = h;
            result.host = null; // transfer ownership
        }
        if (result.job_id) |id| {
            job_id = id;
        }
        // result.deinit runs here; host is null at this point if transferred
    }

    // Validate required fields
    if (job_id == null) return error.MissingJobId;
    if (from_url == null) return error.MissingFromHost;

    // Step 4: resolve destination --host
    if (args.host) |h| {
        if (host_url) |old| allocator.free(old);
        host_url = try normalizeHostUrl(allocator, h);
    } else if (host_url == null) {
        host_url = try allocator.dupe(u8, "http://localhost");
    }

    return .{
        .from_url = from_url.?,
        .host_url = host_url.?,
        .job_id = job_id.?,
        .skip_download = skip_download,
        .jobref_consumed_positional = jobref_in_positional,
    };
}

// ---------------------------------------------------------------------------
// Help text
// ---------------------------------------------------------------------------

const help_text =
    \\Usage:
    \\    Clones a job from the local or a remote openQA instance. Downloads all
    \\    assets associated with the job (unless --skip-download is specified).
    \\    Optionally settings can be modified.
    \\
    \\      zoqa-clone-job [OPTIONS] JOBREF [KEY=[VALUE] ...]
    \\
    \\Options:
    \\    --host HOST           Target openQA instance (defaults to localhost)
    \\    --from HOST           Source openQA instance (deduced from JOBREF if URL)
    \\    --dir DIR             Asset storage directory (defaults to $OPENQA_SHAREDIR/factory)
    \\    --within-instance HOST
    \\                          Shortcut for --skip-download --from HOST --host HOST
    \\    --skip-deps           Do NOT clone parent jobs
    \\    --skip-chained-deps   Do NOT clone chained parent jobs (START_AFTER_TEST)
    \\    --skip-download       Do NOT download assets
    \\    --ignore-missing-assets
    \\                          Do not fail if an asset is missing
    \\    --clone-children      Clone all direct child jobs as well
    \\    --max-depth N         Max depth for cloning children (0 = infinity)
    \\    --repeat N            Clone the same job N times
    \\    --retry N             Retry up to N times on transient errors (default: 5)
    \\    --show-progress       Display progress bar when downloading assets
    \\    --parental-inheritance
    \\                          Apply settings overrides to parent jobs
    \\    --export-command      Print an openqa-cli command instead of cloning
    \\    --badge               Output markdown badge format
    \\    --json-output         Output JSON mapping of original to new job IDs
    \\    --reproduce           Use same test code and needles as original job
    \\    --check-repos         Check maintenance update repo availability
    \\    --apikey KEY          API key (overrides config file / env)
    \\    --apisecret SECRET    API secret (overrides config file / env)
    \\    --verbose, -v         Increase verbosity
    \\    --help, -h            Print this help
    \\
;

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const CloneArgs = struct {
    // Connection
    host: ?[]const u8 = null,
    from: ?[]const u8 = null,
    within_instance: ?[]const u8 = null,
    apikey: ?[]const u8 = null,
    apisecret: ?[]const u8 = null,

    // Behavior
    skip_deps: bool = false,
    skip_chained_deps: bool = false,
    skip_download: bool = false,
    ignore_missing_assets: bool = false,
    clone_children: bool = false,
    parental_inheritance: bool = false,
    export_command: bool = false,
    badge: bool = false,
    json_output: bool = false,
    reproduce: bool = false,
    check_repos: bool = false,
    show_progress: bool = false,
    verbose: bool = false,
    help: bool = false,

    // Value options
    dir: ?[]const u8 = null,
    max_depth: ?u32 = null,
    repeat: ?u32 = null,
    retry: ?u32 = null,

    // Positional: JOBREF and KEY=[VALUE] overrides
    // All slices borrow directly from argv — no copies are made during parsing.
    positionals: std.ArrayList([]const u8),

    pub fn deinit(self: *CloneArgs, allocator: std.mem.Allocator) void {
        self.positionals.deinit(allocator);
    }
};

/// Parse command-line arguments into a `CloneArgs` struct.
///
/// Arguments:
/// - `allocator`: Used to grow the positionals ArrayList.
/// - `argv`: Raw argument vector (argv[0] is the program name, skipped).
///
/// Returns: A populated `CloneArgs` struct. The caller must call `deinit` when done.
///
/// Errors:
///   - `error.MissingJobRef` — no positional JOBREF argument found.
///   - `error.MissingValue` — a value-taking flag has no following token.
///   - `error.UnknownFlag` — unrecognised flag.
///   - `error.InvalidNumber` — a numeric flag has a non-numeric value.
fn parseCloneArgs(allocator: std.mem.Allocator, argv: []const []const u8) !CloneArgs {
    var args = CloneArgs{
        .positionals = .empty,
    };

    var i: usize = 1; // skip argv[0] = program name
    while (i < argv.len) : (i += 1) {
        const token = argv[i];

        // Common flags shared with all openQA CLI executables
        if (try arg_match.tryCommonFlag(CloneArgs, &args, token, &i, argv)) {
            if (args.help) return args; // early return on --help/-h
            continue;
        }

        // Clone-job-specific boolean flags
        if (try arg_match.matchBool(token, "--skip-deps", null)) {
            args.skip_deps = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--skip-chained-deps", null)) {
            args.skip_chained_deps = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--skip-download", null)) {
            args.skip_download = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--ignore-missing-assets", null)) {
            args.ignore_missing_assets = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--clone-children", null)) {
            args.clone_children = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--parental-inheritance", null)) {
            args.parental_inheritance = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--export-command", null)) {
            args.export_command = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--badge", null)) {
            args.badge = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--json-output", null)) {
            args.json_output = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--reproduce", null)) {
            args.reproduce = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--check-repos", null)) {
            args.check_repos = true;
            continue;
        }
        if (try arg_match.matchBool(token, "--show-progress", null)) {
            args.show_progress = true;
            continue;
        }

        // Clone-job-specific value flags
        if (try arg_match.matchValue(token, &i, argv, "--from", null)) |v| {
            args.from = v;
            continue;
        }
        if (try arg_match.matchValue(token, &i, argv, "--within-instance", null)) |v| {
            args.within_instance = v;
            continue;
        }
        if (try arg_match.matchValue(token, &i, argv, "--dir", null)) |v| {
            args.dir = v;
            continue;
        }
        if (try arg_match.matchValue(token, &i, argv, "--max-depth", null)) |v| {
            args.max_depth = std.fmt.parseInt(u32, v, 10) catch return error.InvalidNumber;
            continue;
        }
        if (try arg_match.matchValue(token, &i, argv, "--repeat", null)) |v| {
            args.repeat = std.fmt.parseInt(u32, v, 10) catch return error.InvalidNumber;
            continue;
        }
        if (try arg_match.matchValue(token, &i, argv, "--retry", null)) |v| {
            args.retry = std.fmt.parseInt(u32, v, 10) catch return error.InvalidNumber;
            continue;
        }

        // Unknown flag
        if (std.mem.startsWith(u8, token, "-")) {
            std.debug.print("Unknown flag: {s}\n", .{token});
            return error.UnknownFlag;
        }

        // Positional argument (JOBREF or KEY=VALUE override)
        try args.positionals.append(allocator, token);
    }

    return args;
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

/// Write the help text to stdout (is_error=false) or stderr (is_error=true).
///
/// Arguments:
/// - `is_error`: When `true`, writes to stderr; when `false`, writes to stdout.
fn printHelp(is_error: bool) void {
    var buf: [4096]u8 = undefined;
    var out_writer = if (is_error)
        std.fs.File.stderr().writer(&buf)
    else
        std.fs.File.stdout().writer(&buf);
    const w = &out_writer.interface;
    w.writeAll(help_text) catch {};
    w.flush() catch {};
}

/// Print a formatted message to stderr using a stack-allocated buffer.
///
/// Arguments:
/// - `fmt`: Compile-time format string.
/// - `args_fmt`: Format arguments matching the placeholders in `fmt`.
fn printStderr(comptime fmt: []const u8, args_fmt: anytype) void {
    var buf: [2048]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print(fmt, args_fmt) catch {};
    w.interface.flush() catch {};
}

// ---------------------------------------------------------------------------
// Phase 1: BFS dependency graph walk
// ---------------------------------------------------------------------------

/// Walk the dependency graph starting from the origin job, fetching each
/// reachable job from the source instance and recording its settings and deps.
///
/// Returns the walker with collected entries (owned by `arena_alloc`).
/// Calls `std.process.exit(1)` on any fatal error (this is an exe-layer helper).
const WalkResult = struct {
    walker: zoqa.clone_job.DependencyWalker,
    assets: std.ArrayList(zoqa.clone_job.AssetEntry),
    missing_asset_filenames: std.ArrayList([]const u8),
};

/// Perform a BFS walk of the job dependency graph from the origin job.
///
/// Fetches each reachable job from the source instance, records settings and
/// dependency information, extracts asset references, and collects any
/// server-reported missing asset filenames (when `check_assets=1` is sent).
///
/// Arguments:
/// - `gpa`: General-purpose allocator for transient allocations (freed per-iteration).
/// - `arena_alloc`: Arena allocator for long-lived data (walker entries, assets).
/// - `resolved`: Resolved job reference containing `from_url` and `job_id`.
/// - `from_creds`: Optional API credentials for the source instance.
/// - `retry_cfg`: Retry/timeout configuration for HTTP requests.
/// - `clone_opts`: Clone behaviour flags (skip_deps, clone_children, etc.).
/// - `verbose`: When `true`, enables verbose HTTP request output.
/// - `ignore_missing_assets`: When `true`, suppresses the `?check_assets=1` query.
/// - `client`: HTTP client instance (shared across requests).
///
/// Returns: A `WalkResult` containing the walker state, collected assets, and
///   any missing asset filenames reported by the server.
fn walkDependencyGraph(
    gpa: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,
    resolved: anytype,
    from_creds: ?zoqa.config.Credentials,
    retry_cfg: cli_credentials.RetryConfig,
    clone_opts: zoqa.clone_job.CloneOptions,
    verbose: bool,
    ignore_missing_assets: bool,
    client: *std.http.Client,
) WalkResult {
    var walker = zoqa.clone_job.DependencyWalker.init(arena_alloc, resolved.job_id, clone_opts) catch |err| {
        printStderr("Error: walker init failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    var all_assets: std.ArrayList(zoqa.clone_job.AssetEntry) = .empty;
    var all_missing_assets: std.ArrayList([]const u8) = .empty;

    // Fetch job from source instance; add check_assets=1 unless suppressed
    const check_assets_qs: []const u8 = if (!ignore_missing_assets) "?check_assets=1" else "";

    while (walker.next()) |item| {
        const job_path = std.fmt.allocPrint(gpa, "jobs/{d}{s}", .{ item.job_id, check_assets_qs }) catch |err| {
            printStderr("Error: allocPrint failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer gpa.free(job_path);

        const get_resp = zoqa.openQAReq(resolved.from_url, job_path, .{
            .allocator = gpa,
            .method = .GET,
            .credentials = from_creds,
            .retries = retry_cfg.retries,
            .connect_timeout_s = retry_cfg.connect_timeout_s,
            .retry_sleep_s = retry_cfg.retry_sleep_s,
            .retry_factor = retry_cfg.retry_factor,
            .quiet = !verbose,
        }, client) catch |err| {
            printStderr("Error: GET job {d} failed: {s}\n", .{ item.job_id, @errorName(err) });
            std.process.exit(1);
        };
        defer get_resp.deinit();

        if (get_resp.exitCode() != 0) {
            printStderr("Error: failed to get job '{d}': {d}\n", .{
                item.job_id, @intFromEnum(get_resp.status),
            });
            std.process.exit(1);
        }

        // Parse job response
        const get_parsed = std.json.parseFromSlice(std.json.Value, gpa, get_resp.body, .{}) catch |err| {
            printStderr("Error: failed to parse job {d} response: {s}\n", .{ item.job_id, @errorName(err) });
            std.process.exit(1);
        };
        defer get_parsed.deinit();

        const job_val = get_parsed.value.object.get("job") orelse {
            printStderr("Error: response for job {d} missing 'job' field\n", .{item.job_id});
            std.process.exit(1);
        };
        const job_obj = switch (job_val) {
            .object => |o| o,
            else => {
                printStderr("Error: 'job' field is not an object for job {d}\n", .{item.job_id});
                std.process.exit(1);
            },
        };

        // Feed parsed job to walker (extracts settings, deps, enqueues children)
        walker.feed(arena_alloc, item, job_obj) catch |err| {
            printStderr("Error: walker feed failed for job {d}: {s}\n", .{ item.job_id, @errorName(err) });
            std.process.exit(1);
        };

        // Extract assets from this job
        const job_assets = zoqa.clone_job.extractAssets(arena_alloc, job_obj, item.job_id) catch |err| {
            printStderr("Error: extractAssets failed for job {d}: {s}\n", .{ item.job_id, @errorName(err) });
            std.process.exit(1);
        };
        for (job_assets) |asset| {
            all_assets.append(arena_alloc, asset) catch |err| {
                printStderr("Error: asset append failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        }

        // Collect server-reported missing_assets (populated when check_assets=1 was sent)
        if (job_obj.get("missing_assets")) |ma_val| {
            switch (ma_val) {
                .array => |arr| {
                    for (arr.items) |entry| {
                        switch (entry) {
                            .string => |s| {
                                const duped = arena_alloc.dupe(u8, s) catch |err| {
                                    printStderr("Error: dupe failed: {s}\n", .{@errorName(err)});
                                    std.process.exit(1);
                                };
                                all_missing_assets.append(arena_alloc, duped) catch |err| {
                                    printStderr("Error: missing_assets append failed: {s}\n", .{@errorName(err)});
                                    std.process.exit(1);
                                };
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
    }

    return .{ .walker = walker, .assets = all_assets, .missing_asset_filenames = all_missing_assets };
}

// ---------------------------------------------------------------------------
// Phase 2: Encode dependencies and apply overrides
// ---------------------------------------------------------------------------

/// Encode inter-job dependencies (filtering to only collected IDs) and apply
/// user overrides to each job's settings. Returns the final job list and the
/// encoded POST body.
///
/// Calls `std.process.exit(1)` on fatal errors (exe-layer helper).
///
/// Arguments:
/// - `gpa`: General-purpose allocator for building the POST body string.
/// - `arena_alloc`: Arena allocator for job entry storage.
/// - `collected`: Slice of collected BFS entries from the dependency walker.
/// - `overrides`: Parsed KEY=[VALUE] overrides from the command line.
/// - `clone_opts`: Clone behaviour flags (parental_inheritance, etc.).
///
/// Returns: An anonymous struct with `final_jobs` (the post-override job list)
///   and `post_body` (the encoded form body for the POST request).
fn encodeDepsAndApplyOverrides(
    gpa: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,
    collected: []zoqa.clone_job.DependencyWalker.CollectedEntry,
    overrides: []const zoqa.clone_job.Override,
    clone_opts: zoqa.clone_job.CloneOptions,
) struct { final_jobs: std.ArrayList(zoqa.clone_job.JobEntry), post_body: []const u8 } {
    // Build a lookup table of JobEntry for dependency filtering.
    var lookup_entries: std.ArrayList(zoqa.clone_job.JobEntry) = .empty;
    for (collected) |c| {
        lookup_entries.append(arena_alloc, .{
            .job_id = c.job_id,
            .settings = c.settings,
            .name = c.name,
        }) catch |err| {
            printStderr("Error: lookup_entries append failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    var final_jobs: std.ArrayList(zoqa.clone_job.JobEntry) = .empty;

    for (collected) |*entry| {
        // Encode parent dependencies into settings
        zoqa.clone_job.assignExistingDeps(
            arena_alloc,
            &entry.settings,
            "_PARALLEL",
            entry.parent_parallel,
            lookup_entries.items,
        ) catch |err| {
            printStderr("Error: dep encoding failed for job {d}: {s}\n", .{ entry.job_id, @errorName(err) });
            std.process.exit(1);
        };
        zoqa.clone_job.assignExistingDeps(
            arena_alloc,
            &entry.settings,
            "_START_AFTER",
            entry.parent_chained,
            lookup_entries.items,
        ) catch |err| {
            printStderr("Error: dep encoding failed for job {d}: {s}\n", .{ entry.job_id, @errorName(err) });
            std.process.exit(1);
        };
        zoqa.clone_job.assignExistingDeps(
            arena_alloc,
            &entry.settings,
            "_START_DIRECTLY_AFTER",
            entry.parent_directly_chained,
            lookup_entries.items,
        ) catch |err| {
            printStderr("Error: dep encoding failed for job {d}: {s}\n", .{ entry.job_id, @errorName(err) });
            std.process.exit(1);
        };

        // Apply settings overrides (depth-based)
        const override_depth: u32 = if (entry.relation == .children) 0 else entry.depth;
        zoqa.clone_job.applySettings(
            arena_alloc,
            &entry.settings,
            overrides,
            override_depth,
            clone_opts.parental_inheritance,
        ) catch |err| {
            printStderr("Error: failed to apply overrides for job {d}: {s}\n", .{ entry.job_id, @errorName(err) });
            std.process.exit(1);
        };

        // Add to final output
        final_jobs.append(arena_alloc, .{
            .job_id = entry.job_id,
            .settings = entry.settings,
            .name = entry.name,
        }) catch |err| {
            printStderr("Error: final_jobs append failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    // Build POST body
    const post_body = zoqa.clone_job.buildPostBody(gpa, final_jobs.items) catch |err| {
        printStderr("Error: failed to build POST body: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    return .{ .final_jobs = final_jobs, .post_body = post_body };
}

// ---------------------------------------------------------------------------
// Phase 3: POST to destination and format output
// ---------------------------------------------------------------------------

/// Output formatting mode for clone results.
const OutputMode = enum {
    default,
    badge,
    json,
};

/// POST the assembled clone request to the destination instance, parse the
/// response, and write formatted output to stdout.
///
/// Calls `std.process.exit(1)` on fatal errors (exe-layer helper).
///
/// Arguments:
/// - `gpa`: General-purpose allocator for request/response processing.
/// - `resolved`: Resolved job reference containing `host_url`.
/// - `host_creds`: Optional API credentials for the destination instance.
/// - `retry_cfg`: Retry/timeout configuration for the POST request.
/// - `verbose`: When `true`, enables verbose HTTP request output.
/// - `client`: HTTP client instance (shared across requests).
/// - `post_body`: The URL-encoded form body to send.
/// - `final_jobs`: The final job list for output formatting.
/// - `output_mode`: Selects between default, badge, or JSON output format.
///
/// Errors:
///   Returns `error` only for fatal I/O failures writing to stdout; all HTTP
///   and parsing errors are handled internally via `std.process.exit(1)`.
fn postAndFormatOutput(
    gpa: std.mem.Allocator,
    resolved: anytype,
    host_creds: ?zoqa.config.Credentials,
    retry_cfg: cli_credentials.RetryConfig,
    verbose: bool,
    client: *std.http.Client,
    post_body: []const u8,
    final_jobs: []const zoqa.clone_job.JobEntry,
    output_mode: OutputMode,
) !void {
    const post_form_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };
    const post_resp = zoqa.openQAReq(resolved.host_url, "jobs", .{
        .allocator = gpa,
        .method = .POST,
        .headers = &post_form_headers,
        .params = post_body,
        .credentials = host_creds,
        .retries = retry_cfg.retries,
        .connect_timeout_s = retry_cfg.connect_timeout_s,
        .retry_sleep_s = retry_cfg.retry_sleep_s,
        .retry_factor = retry_cfg.retry_factor,
        .quiet = !verbose,
    }, client) catch |err| {
        printStderr("Error: POST jobs failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer post_resp.deinit();

    if (post_resp.exitCode() != 0) {
        printStderr("Error: failed to create job: {s}\n", .{post_resp.body});
        std.process.exit(1);
    }

    // Parse POST response
    const post_parsed = std.json.parseFromSlice(std.json.Value, gpa, post_resp.body, .{}) catch |err| {
        printStderr("Error: failed to parse POST response: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer post_parsed.deinit();

    const ids_val = post_parsed.value.object.get("ids") orelse {
        printStderr("Error: POST response missing 'ids' field\n", .{});
        std.process.exit(1);
    };
    const ids_map = switch (ids_val) {
        .object => |o| o,
        else => {
            printStderr("Error: POST response 'ids' is not an object\n", .{});
            std.process.exit(1);
        },
    };

    const output = switch (output_mode) {
        .badge => zoqa.clone_job.formatBadgeOutput(gpa, ids_map, final_jobs, resolved.host_url),
        .json => zoqa.clone_job.formatJsonOutput(gpa, ids_map),
        .default => zoqa.clone_job.formatOutput(gpa, ids_map, final_jobs, resolved.host_url),
    } catch |err| {
        printStderr("Error: failed to format output: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer gpa.free(output);

    // Write to stdout
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(output);
    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Asset download
// ---------------------------------------------------------------------------

/// Download assets from the source instance to the local filesystem.
///
/// For each asset extracted during BFS, skips assets that are generated by
/// cloned jobs (PUBLISH_HDD_* / PUBLISH_PFLASH_VARS), then downloads the
/// remainder via GET /tests/{id}/asset/{type}/{filename}.
///
/// Arguments:
/// - `gpa`: General-purpose allocator for path construction and HTTP I/O.
/// - `client`: HTTP client instance (shared across requests).
/// - `assets`: Slice of asset entries collected during the dependency walk.
/// - `final_jobs`: Final job list used to identify self-generated assets.
/// - `from_url`: Source instance base URL.
/// - `from_creds`: Optional API credentials for the source instance.
/// - `asset_dir`: Local directory root for storing downloaded assets.
/// - `retry_cfg`: Retry/timeout configuration (currently unused/reserved).
/// - `verbose`: When `true`, logs skipped assets to stderr.
/// - `ignore_missing_assets`: When `true`, skips 404 responses instead of aborting.
fn downloadAssets(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    assets: []const zoqa.clone_job.AssetEntry,
    final_jobs: []const zoqa.clone_job.JobEntry,
    from_url: []const u8,
    from_creds: ?zoqa.config.Credentials,
    asset_dir: []const u8,
    retry_cfg: cli_credentials.RetryConfig,
    verbose: bool,
    ignore_missing_assets: bool,
) void {
    _ = retry_cfg;
    for (assets) |asset| {
        // Skip assets generated by cloned jobs
        if (zoqa.clone_job.isAssetGeneratedByClonedJobs(asset.filename, final_jobs)) {
            if (verbose) {
                std.debug.print("Skipping generated asset: {s}\n", .{asset.filename});
            }
            continue;
        }

        const type_str: []const u8 = switch (asset.asset_type) {
            .iso => "iso",
            .hdd => "hdd",
            .other => "other",
        };

        // Build download path: /tests/{id}/asset/{type}/{filename}
        const dl_path = std.fmt.allocPrint(gpa, "/tests/{d}/asset/{s}/{s}", .{
            asset.job_id, type_str, asset.filename,
        }) catch |err| {
            printStderr("Error: allocPrint failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer gpa.free(dl_path);

        // Destination: {asset_dir}/{type}/{basename}
        const basename = if (std.mem.lastIndexOfScalar(u8, asset.filename, '/')) |idx|
            asset.filename[idx + 1 ..]
        else
            asset.filename;

        const dest_dir = std.fmt.allocPrint(gpa, "{s}/{s}", .{ asset_dir, type_str }) catch |err| {
            printStderr("Error: allocPrint failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer gpa.free(dest_dir);

        const dest_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dest_dir, basename }) catch |err| {
            printStderr("Error: allocPrint failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer gpa.free(dest_path);

        // Create parent directories
        std.fs.cwd().makePath(dest_dir) catch |err| {
            printStderr("Error: failed to create directory '{s}': {s}\n", .{ dest_dir, @errorName(err) });
            std.process.exit(1);
        };

        // Open destination file and stream response into it
        const file = std.fs.cwd().createFile(dest_path, .{}) catch |err| {
            printStderr("Error: failed to create file '{s}': {s}\n", .{ dest_path, @errorName(err) });
            std.process.exit(1);
        };
        defer file.close();

        // Use openQARawGet for raw path (no /api/v1/ prefix), streaming to file
        var file_buf: [65536]u8 = undefined;
        var file_writer = file.writer(&file_buf);

        const stream_result = zoqa.openQARawGet(from_url, dl_path, .{
            .allocator = gpa,
            .credentials = from_creds,
            .quiet = !verbose,
        }, client, &file_writer.interface, null) catch |err| {
            printStderr("Error: asset download failed for '{s}': {s}\n", .{ asset.filename, @errorName(err) });
            std.process.exit(1);
        };

        if (stream_result.status != .ok) {
            if (ignore_missing_assets and stream_result.status == .not_found) {
                std.fs.cwd().deleteFile(dest_path) catch {};
                printStderr("Warning: skipping missing asset '{s}' (status 404)\n", .{asset.filename});
                continue;
            }
            printStderr("Error: asset download returned status {d} for '{s}'\n", .{
                @intFromEnum(stream_result.status), asset.filename,
            });
            std.process.exit(1);
        }

        // Flush the buffered writer
        file_writer.interface.flush() catch |err| {
            printStderr("Error: failed to flush asset '{s}': {s}\n", .{ dest_path, @errorName(err) });
            std.process.exit(1);
        };
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Clone-job CLI entry point: parses arguments, walks the dependency graph,
/// and POSTs the assembled multi-job clone request to the destination instance.
///
/// Errors: Returns an error union only for fatal I/O failures writing to
///   stdout; all other errors are handled internally and result in
///   `std.process.exit(1)` or `std.process.exit(255)`.
pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    var args = parseCloneArgs(gpa, argv) catch |err| {
        if (err == error.MissingValue) {
            printStderr("Error: flag requires a value\n", .{});
        } else if (err == error.UnknownFlag) {
            // message already printed in parseCloneArgs
        } else if (err == error.InvalidNumber) {
            printStderr("Error: flag value is not a valid number\n", .{});
        }
        printHelp(true);
        std.process.exit(255);
    };
    defer args.deinit(gpa);

    if (args.help) {
        printHelp(false);
        return;
    }

    // Resolve JOBREF → (from_url, host_url, job_id, skip_download)
    const resolved = resolveJobRef(gpa, &args) catch |err| {
        switch (err) {
            error.ConflictingOptions => printStderr(
                "Error: --within-instance and --from cannot be used together, see --help\n",
                .{},
            ),
            error.MissingJobId => printStderr(
                "Error: no job reference (JOBREF) provided, see --help\n",
                .{},
            ),
            error.MissingFromHost => printStderr(
                "Error: cannot determine source host; use --from HOST or pass a full URL, see --help\n",
                .{},
            ),
            error.InvalidUrl => printStderr(
                "Error: JOBREF does not look like a URL or a numeric job ID, see --help\n",
                .{},
            ),
            error.UrlTooLong => printStderr(
                "Error: URL is too long\n",
                .{},
            ),
            else => {
                printStderr("Error: unexpected failure while resolving job reference: {s}\n", .{@errorName(err)});
            },
        }
        std.process.exit(255);
    };
    defer resolved.deinit(gpa);

    if (args.verbose) {
        std.debug.print("from:          {s}\n", .{resolved.from_url});
        std.debug.print("host:          {s}\n", .{resolved.host_url});
        std.debug.print("job_id:        {d}\n", .{resolved.job_id});
        std.debug.print("skip_download: {}\n", .{resolved.skip_download});
    }

    // ── Credentials ──────────────────────────────────────────────────────────
    // Resolve credentials for source (from_url) and destination (host_url).
    const from_creds = cli_credentials.resolveCredentials(gpa, resolved.from_url, args.apikey, args.apisecret) catch |err| {
        printStderr("Error: credential lookup failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer if (from_creds) |c| c.deinit();

    // When cloning within the same instance, reuse the same credentials.
    const same_host = std.mem.eql(u8, resolved.from_url, resolved.host_url);
    const host_creds: ?zoqa.config.Credentials = if (same_host) blk: {
        // Duplicate so both can be independently deinit'd.
        if (from_creds) |c| {
            break :blk zoqa.config.Credentials{
                .allocator = gpa,
                .key = try gpa.dupe(u8, c.key),
                .secret = try gpa.dupe(u8, c.secret),
            };
        } else break :blk null;
    } else try cli_credentials.resolveCredentials(gpa, resolved.host_url, args.apikey, args.apisecret);
    defer if (host_creds) |c| c.deinit();

    // ── Retry/timeout knobs ──────────────────────────────────────────────────
    const retry_cfg = cli_credentials.resolveRetryConfig(gpa, args.retry) catch |err| {
        printStderr("Error: retry config resolution failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // ── Arena for all job settings (freed as a unit at the end) ──────────────
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // ── Parse user overrides ─────────────────────────────────────────────────
    const override_start: usize = if (resolved.jobref_consumed_positional) 1 else 0;
    const raw_overrides = args.positionals.items[override_start..];

    var overrides: std.ArrayList(zoqa.clone_job.Override) = .empty;
    for (raw_overrides) |ov_str| {
        if (zoqa.clone_job.parseOverride(ov_str)) |ov| {
            try overrides.append(arena_alloc, ov);
        }
    }

    // ── Recursive dependency graph walk ──────────────────────────────────────
    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const clone_opts = zoqa.clone_job.CloneOptions{
        .skip_deps = args.skip_deps,
        .skip_chained_deps = args.skip_chained_deps,
        .clone_children = args.clone_children,
        .max_depth = args.max_depth orelse 1,
        .parental_inheritance = args.parental_inheritance,
        .from_url = resolved.from_url,
    };

    // Phase 1: Walk dependency graph, fetch all reachable jobs.
    const walk_result = walkDependencyGraph(
        gpa,
        arena_alloc,
        &resolved,
        from_creds,
        retry_cfg,
        clone_opts,
        args.verbose,
        args.ignore_missing_assets,
        &client,
    );

    // Phase 1.5: --reproduce — fetch vars.json and inject versioning settings.
    if (args.reproduce) {
        for (walk_result.walker.collected.items) |*entry| {
            const vars_path = std.fmt.allocPrint(gpa, "/tests/{d}/file/vars.json", .{entry.job_id}) catch |err| {
                printStderr("Error: allocPrint failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer gpa.free(vars_path);

            // Stream vars.json into memory using an allocating writer
            var body_aw: std.Io.Writer.Allocating = .init(gpa);
            defer body_aw.deinit();

            const stream_result = zoqa.openQARawGet(resolved.from_url, vars_path, .{
                .allocator = gpa,
                .credentials = from_creds,
                .quiet = !args.verbose,
            }, &client, &body_aw.writer, null) catch {
                // vars.json fetch failed — warn and continue without injecting
                printStderr("Warning: could not fetch vars.json for job {d}, skipping reproduce injection\n", .{entry.job_id});
                continue;
            };

            if (stream_result.status != .ok) {
                printStderr("Warning: vars.json returned status {d} for job {d}, skipping\n", .{
                    @intFromEnum(stream_result.status), entry.job_id,
                });
                continue;
            }

            // Parse vars.json from the buffered body
            const vars_body = body_aw.toOwnedSlice() catch continue;
            defer gpa.free(vars_body);

            const vars_parsed = std.json.parseFromSlice(std.json.Value, gpa, vars_body, .{}) catch {
                printStderr("Warning: could not parse vars.json for job {d}\n", .{entry.job_id});
                continue;
            };
            defer vars_parsed.deinit();

            const vars_obj = switch (vars_parsed.value) {
                .object => |o| o,
                else => continue,
            };

            zoqa.clone_job.injectReproduceSettings(arena_alloc, &entry.settings, vars_obj) catch |err| {
                printStderr("Warning: reproduce settings injection failed for job {d}: {s}\n", .{ entry.job_id, @errorName(err) });
                continue;
            };
        }
    }

    // Phase 2: Encode dependencies and apply overrides.
    const phase2 = encodeDepsAndApplyOverrides(
        gpa,
        arena_alloc,
        walk_result.walker.collected.items,
        overrides.items,
        clone_opts,
    );
    defer gpa.free(phase2.post_body);

    // --export-command: print the equivalent zoqa api command and exit.
    if (args.export_command) {
        const cmd = zoqa.clone_job.formatExportCommand(gpa, phase2.final_jobs.items, resolved.host_url) catch |err| {
            printStderr("Error: failed to format export command: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer gpa.free(cmd);

        var stdout_buf: [8192]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(cmd);
        try stdout.flush();
        return;
    }

    // Asset download phase: download assets from source to --dir.
    if (!resolved.skip_download) {
        // Pre-check: abort on server-reported missing assets (unless suppressed).
        if (!args.ignore_missing_assets and walk_result.missing_asset_filenames.items.len > 0) {
            var truly_missing: std.ArrayList([]const u8) = .empty;
            for (walk_result.missing_asset_filenames.items) |path_str| {
                const basename = if (std.mem.lastIndexOfScalar(u8, path_str, '/')) |i|
                    path_str[i + 1 ..]
                else
                    path_str;
                if (!zoqa.clone_job.isAssetGeneratedByClonedJobs(basename, phase2.final_jobs.items)) {
                    truly_missing.append(arena_alloc, path_str) catch |err| {
                        printStderr("Error: truly_missing append failed: {s}\n", .{@errorName(err)});
                        std.process.exit(1);
                    };
                }
            }
            if (truly_missing.items.len > 0) {
                printStderr("The following assets are missing:\n", .{});
                for (truly_missing.items) |m| printStderr(" - {s}\n", .{m});
                printStderr("Use --ignore-missing-assets or --skip-download to proceed regardless.\n", .{});
                std.process.exit(1);
            }
        }
        const asset_dir = args.dir orelse "/var/lib/openqa/share/factory";
        downloadAssets(
            gpa,
            &client,
            walk_result.assets.items,
            phase2.final_jobs.items,
            resolved.from_url,
            from_creds,
            asset_dir,
            retry_cfg,
            args.verbose,
            args.ignore_missing_assets,
        );
    }

    // Phase 3: POST to destination and format output.
    const output_mode: OutputMode = if (args.json_output) .json else if (args.badge) .badge else .default;
    const repeat_count: u32 = args.repeat orelse 1;

    if (repeat_count <= 1) {
        // Single clone (default): no suffix mutation needed.
        try postAndFormatOutput(
            gpa,
            &resolved,
            host_creds,
            retry_cfg,
            args.verbose,
            &client,
            phase2.post_body,
            phase2.final_jobs.items,
            output_mode,
        );
    } else {
        // Repeat loop: mutate TEST per iteration, rebuild POST body, POST.
        for (1..repeat_count + 1) |i| {
            zoqa.clone_job.appendRepeatSuffix(
                arena_alloc,
                phase2.final_jobs.items,
                @intCast(i),
            ) catch |err| {
                printStderr("Error: failed to apply repeat suffix: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };

            const iter_post_body = zoqa.clone_job.buildPostBody(gpa, phase2.final_jobs.items) catch |err| {
                printStderr("Error: failed to build POST body for repeat iteration {d}: {s}\n", .{ i, @errorName(err) });
                std.process.exit(1);
            };
            defer gpa.free(iter_post_body);

            try postAndFormatOutput(
                gpa,
                &resolved,
                host_creds,
                retry_cfg,
                args.verbose,
                &client,
                iter_post_body,
                phase2.final_jobs.items,
                output_mode,
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseCloneArgs: --help returns help flag" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa-clone-job", "--help" };
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.help);
}

test "parseCloneArgs: -h returns help flag" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa-clone-job", "-h" };
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.help);
}

test "parseCloneArgs: boolean flags" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--skip-deps",                     "--skip-download", "--clone-children",
        "--verbose",      "https://openqa.opensuse.org/t42",
    };
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.skip_deps);
    try std.testing.expect(parsed.skip_download);
    try std.testing.expect(parsed.clone_children);
    try std.testing.expect(parsed.verbose);
    try std.testing.expect(!parsed.skip_chained_deps);
}

test "parseCloneArgs: value flags" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--host", "openqa.example.com", "--from", "openqa.opensuse.org",
        "--repeat",       "5",      "42",
    };
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("openqa.example.com", parsed.host.?);
    try std.testing.expectEqualStrings("openqa.opensuse.org", parsed.from.?);
    try std.testing.expectEqual(@as(u32, 5), parsed.repeat.?);
    try std.testing.expectEqualStrings("42", parsed.positionals.items[0]);
}

test "parseCloneArgs: equals-form value flags" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--host=openqa.example.com", "--retry=3", "42",
    };
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("openqa.example.com", parsed.host.?);
    try std.testing.expectEqual(@as(u32, 3), parsed.retry.?);
}

test "parseCloneArgs: positionals collected" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "https://openqa.opensuse.org/t42", "TEST+=:PR-123", "FOOBAR=",
    };
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), parsed.positionals.items.len);
    try std.testing.expectEqualStrings("https://openqa.opensuse.org/t42", parsed.positionals.items[0]);
    try std.testing.expectEqualStrings("TEST+=:PR-123", parsed.positionals.items[1]);
    try std.testing.expectEqualStrings("FOOBAR=", parsed.positionals.items[2]);
}

test "parseCloneArgs: unknown flag returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa-clone-job", "--nonexistent" };
    try std.testing.expectError(error.UnknownFlag, parseCloneArgs(allocator, argv));
}

test "parseCloneArgs: missing value returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa-clone-job", "--host" };
    try std.testing.expectError(error.MissingValue, parseCloneArgs(allocator, argv));
}

test "parseCloneArgs: invalid number returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa-clone-job", "--repeat", "abc", "42" };
    try std.testing.expectError(error.InvalidNumber, parseCloneArgs(allocator, argv));
}

test "parseCloneArgs: --within-instance sets value" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--within-instance", "https://openqa.opensuse.org", "42",
    };
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("https://openqa.opensuse.org", parsed.within_instance.?);
}

test "parseCloneArgs: no args produces empty positionals" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{"zoqa-clone-job"};
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), parsed.positionals.items.len);
    try std.testing.expect(!parsed.help);
}

test "parseCloneArgs: max_depth defaults to null when not specified" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--from", "openqa.example.com", "42",
    };
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.max_depth == null);
}

test "parseCloneArgs: --max-depth 0 parses as zero" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--from", "openqa.example.com", "--max-depth", "0", "42",
    };
    var parsed = try parseCloneArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, 0), parsed.max_depth);
}

// ---------------------------------------------------------------------------
// Tests: resolveJobRef
// ---------------------------------------------------------------------------

test "resolveJobRef: full URL positional, no flags" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "https://openqa.opensuse.org/t42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    const r = try resolveJobRef(allocator, &args);
    defer r.deinit(allocator);

    try std.testing.expectEqualStrings("https://openqa.opensuse.org", r.from_url);
    try std.testing.expectEqualStrings("http://localhost", r.host_url);
    try std.testing.expectEqual(@as(u64, 42), r.job_id);
    try std.testing.expect(!r.skip_download);
}

test "resolveJobRef: --from + bare integer positional" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--from", "openqa.opensuse.org", "42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    const r = try resolveJobRef(allocator, &args);
    defer r.deinit(allocator);

    try std.testing.expectEqualStrings("http://openqa.opensuse.org", r.from_url);
    try std.testing.expectEqualStrings("http://localhost", r.host_url);
    try std.testing.expectEqual(@as(u64, 42), r.job_id);
}

test "resolveJobRef: --host overrides default destination" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--from", "openqa.opensuse.org", "--host", "my.host.local", "42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    const r = try resolveJobRef(allocator, &args);
    defer r.deinit(allocator);

    try std.testing.expectEqualStrings("http://openqa.opensuse.org", r.from_url);
    // "my.host.local" contains no "localhost", so https://
    try std.testing.expectEqualStrings("https://my.host.local", r.host_url);
    try std.testing.expectEqual(@as(u64, 42), r.job_id);
}

test "resolveJobRef: --host localhost uses http" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--from", "openqa.opensuse.org", "--host", "localhost", "42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    const r = try resolveJobRef(allocator, &args);
    defer r.deinit(allocator);

    try std.testing.expectEqualStrings("http://localhost", r.host_url);
}

test "resolveJobRef: positional URL overrides --from" {
    // Perl §9.3: positional URL wins over --from
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--from", "https://host1.com", "https://host2.com/t42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    const r = try resolveJobRef(allocator, &args);
    defer r.deinit(allocator);

    try std.testing.expectEqualStrings("https://host2.com", r.from_url);
    try std.testing.expectEqual(@as(u64, 42), r.job_id);
}

test "resolveJobRef: --within-instance sets from, host, skip_download" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--within-instance", "https://openqa.opensuse.org", "42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    const r = try resolveJobRef(allocator, &args);
    defer r.deinit(allocator);

    try std.testing.expectEqualStrings("https://openqa.opensuse.org", r.from_url);
    try std.testing.expectEqualStrings("https://openqa.opensuse.org", r.host_url);
    try std.testing.expectEqual(@as(u64, 42), r.job_id);
    try std.testing.expect(r.skip_download);
}

test "resolveJobRef: --within-instance with job_id in URL" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--within-instance", "https://openqa.opensuse.org/t42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    const r = try resolveJobRef(allocator, &args);
    defer r.deinit(allocator);

    try std.testing.expectEqualStrings("https://openqa.opensuse.org", r.from_url);
    try std.testing.expectEqualStrings("https://openqa.opensuse.org", r.host_url);
    try std.testing.expectEqual(@as(u64, 42), r.job_id);
    try std.testing.expect(r.skip_download);
}

test "resolveJobRef: --within-instance + --from returns ConflictingOptions" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job",
        "--within-instance",
        "https://openqa.opensuse.org",
        "--from",
        "https://other.host.com",
        "42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    try std.testing.expectError(error.ConflictingOptions, resolveJobRef(allocator, &args));
}

test "resolveJobRef: bare integer without --from returns MissingFromHost" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    try std.testing.expectError(error.MissingFromHost, resolveJobRef(allocator, &args));
}

test "resolveJobRef: no positional and no within-instance returns MissingJobId" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--from", "openqa.opensuse.org",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    try std.testing.expectError(error.MissingJobId, resolveJobRef(allocator, &args));
}

test "resolveJobRef: --skip-download propagated" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--from", "openqa.opensuse.org", "--skip-download", "42",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    const r = try resolveJobRef(allocator, &args);
    defer r.deinit(allocator);

    try std.testing.expect(r.skip_download);
}

test "resolveJobRef: job_id from --from URL, no positional needed" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa-clone-job", "--from", "openqa.opensuse.org/t99",
    };
    var args = try parseCloneArgs(allocator, argv);
    defer args.deinit(allocator);

    const r = try resolveJobRef(allocator, &args);
    defer r.deinit(allocator);

    try std.testing.expectEqualStrings("http://openqa.opensuse.org", r.from_url);
    try std.testing.expectEqual(@as(u64, 99), r.job_id);
}
