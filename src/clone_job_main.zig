const std = @import("std");
const arg_match = @import("arg_match");
const zoqa = @import("zoqa");

// ---------------------------------------------------------------------------
// URL / JOBREF helpers
// ---------------------------------------------------------------------------

/// Returns true when every byte of `s` is an ASCII digit and `s` is non-empty.
fn isNumericId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Returns true when `s` starts with "http://" or "https://".
fn hasHttpScheme(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or
        std.mem.startsWith(u8, s, "https://");
}

/// Extract a numeric job ID from an openQA URL path.
///
/// Recognised path patterns:
///   /t{digits}              — shortcut form (e.g. /t42)
///   /tests/{digits}[/...]   — canonical form (e.g. /tests/42)
///
/// Returns the ID or null if the path does not match either pattern.
fn extractJobIdFromPath(path: []const u8) ?u64 {
    // /t{id}
    if (std.mem.startsWith(u8, path, "/t")) {
        const after_t = path[2..];
        const end = std.mem.indexOfScalar(u8, after_t, '/') orelse after_t.len;
        const id_part = after_t[0..end];
        if (isNumericId(id_part)) {
            return std.fmt.parseInt(u64, id_part, 10) catch null;
        }
    }

    // /tests/{id}[/...]
    const tests_pfx = "/tests/";
    if (std.mem.startsWith(u8, path, tests_pfx)) {
        const after = path[tests_pfx.len..];
        const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const id_part = after[0..end];
        if (isNumericId(id_part)) {
            return std.fmt.parseInt(u64, id_part, 10) catch null;
        }
    }

    return null;
}

// ---------------------------------------------------------------------------
// JOBREF parsing — mirrors CloneJob.pm split_jobid()
// ---------------------------------------------------------------------------

pub const SplitJobRefResult = struct {
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
/// Errors:
///   error.InvalidUrl — the string is neither a numeric ID nor a parseable URL.
///   error.UrlTooLong — the URL (after prepending a scheme) exceeds an internal limit.
pub fn splitJobRef(allocator: std.mem.Allocator, input: []const u8) !SplitJobRefResult {
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
fn normalizeHostUrl(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    if (hasHttpScheme(host)) return try allocator.dupe(u8, host);
    const scheme: []const u8 = if (std.mem.indexOf(u8, host, "localhost") != null)
        "http"
    else
        "https";
    return try std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, host });
}

// ---------------------------------------------------------------------------
// Settings helpers
// ---------------------------------------------------------------------------

/// A single job setting key/value pair.
/// Both slices borrow from an arena allocator — no individual deinit needed.
const SettingPair = struct {
    key: []const u8,
    value: []const u8,
};

/// Returns true when `c` is an RFC 3986 unreserved character.
fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

/// Appends a percent-encoded version of `input` to `buf` following
/// `application/x-www-form-urlencoded` rules.
fn formEncodeAppend(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| {
        if (isUnreserved(c)) {
            try buf.append(allocator, c);
        } else if (c == ' ') {
            try buf.append(allocator, '+');
        } else {
            var tmp: [3]u8 = undefined;
            const enc = try std.fmt.bufPrint(&tmp, "%{X:0>2}", .{c});
            try buf.appendSlice(allocator, enc);
        }
    }
}

/// Extract the hostname from a URL string for credential lookup.
/// Returns a slice into `url` (no allocation).
fn hostnameFromUrl(url: []const u8) []const u8 {
    const uri = std.Uri.parse(url) catch return url;
    return if (uri.host) |h| h.percent_encoded else url;
}

/// Parse a `KEY=VALUE` positional override string.
/// Returns null when the string contains no `=`.
const Override = struct { key: []const u8, value: []const u8 };
fn parseOverride(input: []const u8) ?Override {
    const eq = std.mem.indexOfScalar(u8, input, '=') orelse return null;
    return Override{ .key = input[0..eq], .value = input[eq + 1 ..] };
}

// ---------------------------------------------------------------------------
// JOBREF resolution
// ---------------------------------------------------------------------------

pub const ResolvedJobRef = struct {
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
/// Errors:
///   error.ConflictingOptions — both --within-instance and --from were supplied.
///   error.MissingFromHost    — no source host could be determined.
///   error.MissingJobId       — no job ID could be determined.
///   error.InvalidUrl         — a URL argument could not be parsed.
///   error.UrlTooLong         — a URL exceeded an internal buffer limit.
pub fn resolveJobRef(allocator: std.mem.Allocator, args: *const CloneArgs) !ResolvedJobRef {
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

    // ── Step 1: --within-instance ──────────────────────────────────────────
    if (args.within_instance) |wi| {
        var result = try splitJobRef(allocator, wi);
        from_url = result.host orelse return error.MissingFromHost;
        result.host = null; // ownership transferred to from_url
        // host = same instance as from
        host_url = try allocator.dupe(u8, from_url.?);
        if (result.job_id) |id| job_id = id;
        skip_download = true;
    }

    // ── Step 2: --from ────────────────────────────────────────────────────
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

    // ── Step 3: first positional as JOBREF (only when job_id still unknown) ─
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

    // ── Step 4: resolve destination --host ────────────────────────────────
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

pub const CloneArgs = struct {
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
/// Errors:
///   - `error.MissingJobRef` — no positional JOBREF argument found.
///   - `error.MissingValue` — a value-taking flag has no following token.
///   - `error.UnknownFlag` — unrecognised flag.
///   - `error.InvalidNumber` — a numeric flag has a non-numeric value.
pub fn parseCloneArgs(allocator: std.mem.Allocator, argv: []const []const u8) !CloneArgs {
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

fn printStderr(comptime fmt: []const u8, args_fmt: anytype) void {
    var buf: [2048]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print(fmt, args_fmt) catch {};
    w.interface.flush() catch {};
}

// ---------------------------------------------------------------------------
// Credential helpers
// ---------------------------------------------------------------------------

/// Merge credentials from CLI args, environment variables, and config file.
/// Priority: CLI > env > config. Returns null when neither key nor secret is available.
fn mergeCredentials(
    allocator: std.mem.Allocator,
    cli: struct { key: ?[]const u8, secret: ?[]const u8 },
    env: struct { key: ?[]const u8, secret: ?[]const u8 },
    conf: ?zoqa.config.Credentials,
) !?zoqa.config.Credentials {
    const key = cli.key orelse env.key orelse if (conf) |c| c.key else null;
    const secret = cli.secret orelse env.secret orelse if (conf) |c| c.secret else null;

    if (key != null and secret != null) {
        return zoqa.config.Credentials{
            .allocator = allocator,
            .key = try allocator.dupe(u8, key.?),
            .secret = try allocator.dupe(u8, secret.?),
        };
    }
    return null;
}

/// Resolve credentials for a given host URL.
/// Follows priority: CLI flags → OPENQA_API_KEY/OPENQA_API_SECRET env → config file.
fn resolveCredentials(
    allocator: std.mem.Allocator,
    host_url: []const u8,
    cli_key: ?[]const u8,
    cli_secret: ?[]const u8,
) !?zoqa.config.Credentials {
    const hostname = hostnameFromUrl(host_url);

    const conf_creds = try zoqa.config.findCredentials(allocator, hostname);
    defer if (conf_creds) |c| c.deinit();

    const env_key = std.process.getEnvVarOwned(allocator, "OPENQA_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (env_key) |s| allocator.free(s);

    const env_secret = std.process.getEnvVarOwned(allocator, "OPENQA_API_SECRET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (env_secret) |s| allocator.free(s);

    return try mergeCredentials(
        allocator,
        .{ .key = cli_key, .secret = cli_secret },
        .{ .key = env_key, .secret = env_secret },
        conf_creds,
    );
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

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
    const from_creds = resolveCredentials(gpa, resolved.from_url, args.apikey, args.apisecret) catch |err| {
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
    } else try resolveCredentials(gpa, resolved.host_url, args.apikey, args.apisecret);
    defer if (host_creds) |c| c.deinit();

    // ── GET /api/v1/jobs/{job_id} from the source instance ───────────────────
    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const job_path = try std.fmt.allocPrint(gpa, "jobs/{d}", .{resolved.job_id});
    defer gpa.free(job_path);

    const get_resp = zoqa.openQAReq(resolved.from_url, job_path, .{
        .allocator = gpa,
        .method = .GET,
        .credentials = from_creds,
        .quiet = !args.verbose,
    }, &client) catch |err| {
        printStderr("Error: GET job failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer get_resp.deinit();

    if (get_resp.exitCode() != 0) {
        printStderr("Error: failed to get job '{d}': {d}\n", .{
            resolved.job_id, @intFromEnum(get_resp.status),
        });
        std.process.exit(1);
    }

    // ── Parse GET response ────────────────────────────────────────────────────
    const get_parsed = std.json.parseFromSlice(std.json.Value, gpa, get_resp.body, .{}) catch |err| {
        printStderr("Error: failed to parse job response: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer get_parsed.deinit();

    const job_val = get_parsed.value.object.get("job") orelse {
        printStderr("Error: response missing 'job' field\n", .{});
        std.process.exit(1);
    };

    // Extract job name for output
    const job_name: []const u8 = if (job_val.object.get("name")) |n|
        switch (n) {
            .string => |s| s,
            else => "unknown",
        }
    else
        "unknown";

    // Extract group_id if present (may be null in JSON)
    const group_id: ?i64 = if (job_val.object.get("group_id")) |g|
        switch (g) {
            .integer => |i| i,
            else => null,
        }
    else
        null;

    // Extract settings object
    const settings_val = job_val.object.get("settings") orelse {
        printStderr("Error: response missing 'settings' field\n", .{});
        std.process.exit(1);
    };

    // ── Build settings list ───────────────────────────────────────────────────
    // Use an arena for all string copies; freed as a unit at the end.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var settings: std.ArrayList(SettingPair) = .empty;
    // No deinit needed — arena owns all the memory.

    // Copy settings from API response, skipping "NAME" (server auto-generates it).
    {
        var it = settings_val.object.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (std.mem.eql(u8, k, "NAME")) continue;
            const v: []const u8 = switch (entry.value_ptr.*) {
                .string => |s| s,
                .integer => |i| try std.fmt.allocPrint(arena_alloc, "{d}", .{i}),
                .float => |f| try std.fmt.allocPrint(arena_alloc, "{d}", .{f}),
                .bool => |b| if (b) "1" else "0",
                else => continue,
            };
            try settings.append(arena_alloc, .{
                .key = try arena_alloc.dupe(u8, k),
                .value = v,
            });
        }
    }

    // Add CLONED_FROM = "{from_url}/tests/{job_id}"
    {
        const cloned_from = try std.fmt.allocPrint(arena_alloc, "{s}/tests/{d}", .{
            resolved.from_url, resolved.job_id,
        });
        try settings.append(arena_alloc, .{ .key = "CLONED_FROM", .value = cloned_from });
    }

    // Add _GROUP_ID if the source job had a group (preserves group membership).
    if (group_id) |gid| {
        const gid_str = try std.fmt.allocPrint(arena_alloc, "{d}", .{gid});
        // Remove any existing _GROUP_ID / _GROUP before adding ours.
        var wi: usize = 0;
        while (wi < settings.items.len) {
            const k = settings.items[wi].key;
            if (std.mem.eql(u8, k, "_GROUP_ID") or std.mem.eql(u8, k, "_GROUP")) {
                _ = settings.orderedRemove(wi);
            } else {
                wi += 1;
            }
        }
        try settings.append(arena_alloc, .{ .key = "_GROUP_ID", .value = gid_str });
    }

    // ── Apply user setting overrides (KEY=VALUE positionals) ─────────────────
    const override_start: usize = if (resolved.jobref_consumed_positional) 1 else 0;
    const overrides = args.positionals.items[override_start..];

    for (overrides) |ov| {
        const parsed_ov = parseOverride(ov) orelse continue;
        const ov_key = try arena_alloc.dupe(u8, parsed_ov.key);
        const ov_val = try arena_alloc.dupe(u8, parsed_ov.value);

        // If value is empty: delete the setting.
        if (ov_val.len == 0) {
            var wi: usize = 0;
            while (wi < settings.items.len) {
                if (std.mem.eql(u8, settings.items[wi].key, ov_key)) {
                    _ = settings.orderedRemove(wi);
                } else {
                    wi += 1;
                }
            }
            continue;
        }

        // Override: find and replace existing, or append.
        // Also delete _GROUP when _GROUP_ID is set and vice-versa (§7 JOB_SETTING_OVERRIDES).
        var found = false;
        for (settings.items) |*s| {
            if (std.mem.eql(u8, s.key, ov_key)) {
                s.value = ov_val;
                found = true;
                break;
            }
        }
        if (!found) {
            try settings.append(arena_alloc, .{ .key = ov_key, .value = ov_val });
        }
        // Delete counterpart (_GROUP ↔ _GROUP_ID)
        const counterpart: ?[]const u8 = if (std.mem.eql(u8, ov_key, "_GROUP"))
            "_GROUP_ID"
        else if (std.mem.eql(u8, ov_key, "_GROUP_ID"))
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

    // ── Build POST body (application/x-www-form-urlencoded) ──────────────────
    // Format: KEY:{job_id}=percent_encoded_VALUE&...&is_clone_job=1
    // The colon and job ID are literal (not encoded); only values are encoded.
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);

    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{resolved.job_id}) catch unreachable;

    for (settings.items) |s| {
        if (body_buf.items.len > 0) try body_buf.append(gpa, '&');
        try formEncodeAppend(gpa, &body_buf, s.key);
        try body_buf.append(gpa, ':');
        try body_buf.appendSlice(gpa, id_str);
        try body_buf.append(gpa, '=');
        try formEncodeAppend(gpa, &body_buf, s.value);
    }
    if (body_buf.items.len > 0) try body_buf.append(gpa, '&');
    try body_buf.appendSlice(gpa, "is_clone_job=1");

    // ── POST /api/v1/jobs to the destination instance ─────────────────────────
    const post_form_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };
    const post_resp = zoqa.openQAReq(resolved.host_url, "jobs", .{
        .allocator = gpa,
        .method = .POST,
        .headers = &post_form_headers,
        .params = body_buf.items,
        .credentials = host_creds,
        .quiet = !args.verbose,
    }, &client) catch |err| {
        printStderr("Error: POST jobs failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer post_resp.deinit();

    if (post_resp.exitCode() != 0) {
        printStderr("Error: failed to create job: {s}\n", .{post_resp.body});
        std.process.exit(1);
    }

    // ── Parse POST response, extract new job ID ───────────────────────────────
    const post_parsed = std.json.parseFromSlice(std.json.Value, gpa, post_resp.body, .{}) catch |err| {
        printStderr("Error: failed to parse POST response: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer post_parsed.deinit();

    const ids_val = post_parsed.value.object.get("ids") orelse {
        printStderr("Error: POST response missing 'ids' field\n", .{});
        std.process.exit(1);
    };

    var ids_it = ids_val.object.iterator();
    const first_id_entry = ids_it.next() orelse {
        printStderr("Error: POST response 'ids' is empty\n", .{});
        std.process.exit(1);
    };
    const new_job_id: i64 = switch (first_id_entry.value_ptr.*) {
        .integer => |i| i,
        else => {
            printStderr("Error: unexpected type in POST response 'ids'\n", .{});
            std.process.exit(1);
        },
    };

    // ── Print success output (matches Perl format) ────────────────────────────
    // "1 job has been created:\n - {name} -> {host_url}/tests/{id}\n"
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("1 job has been created:\n - {s} -> {s}/tests/{d}\n", .{
        job_name, resolved.host_url, new_job_id,
    });
    try stdout.flush();
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

// ---------------------------------------------------------------------------
// Tests: URL helpers
// ---------------------------------------------------------------------------

test "isNumericId: digits only" {
    try std.testing.expect(isNumericId("42"));
    try std.testing.expect(isNumericId("12345"));
    try std.testing.expect(!isNumericId(""));
    try std.testing.expect(!isNumericId("42a"));
    try std.testing.expect(!isNumericId("a42"));
    try std.testing.expect(!isNumericId("http://host/t42"));
}

test "hasHttpScheme: detection" {
    try std.testing.expect(hasHttpScheme("http://localhost"));
    try std.testing.expect(hasHttpScheme("https://openqa.opensuse.org"));
    try std.testing.expect(!hasHttpScheme("openqa.opensuse.org"));
    try std.testing.expect(!hasHttpScheme("ftp://example.com"));
    try std.testing.expect(!hasHttpScheme(""));
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
// Tests: splitJobRef
// ---------------------------------------------------------------------------

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
// Tests: normalizeHostUrl
// ---------------------------------------------------------------------------

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
