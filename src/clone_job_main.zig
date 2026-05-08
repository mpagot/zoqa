const std = @import("std");
const arg_match = @import("arg_match");

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
        if (arg_match.matchBool(token, "--skip-deps", null)) {
            args.skip_deps = true;
            continue;
        }
        if (arg_match.matchBool(token, "--skip-chained-deps", null)) {
            args.skip_chained_deps = true;
            continue;
        }
        if (arg_match.matchBool(token, "--skip-download", null)) {
            args.skip_download = true;
            continue;
        }
        if (arg_match.matchBool(token, "--ignore-missing-assets", null)) {
            args.ignore_missing_assets = true;
            continue;
        }
        if (arg_match.matchBool(token, "--clone-children", null)) {
            args.clone_children = true;
            continue;
        }
        if (arg_match.matchBool(token, "--parental-inheritance", null)) {
            args.parental_inheritance = true;
            continue;
        }
        if (arg_match.matchBool(token, "--export-command", null)) {
            args.export_command = true;
            continue;
        }
        if (arg_match.matchBool(token, "--badge", null)) {
            args.badge = true;
            continue;
        }
        if (arg_match.matchBool(token, "--reproduce", null)) {
            args.reproduce = true;
            continue;
        }
        if (arg_match.matchBool(token, "--check-repos", null)) {
            args.check_repos = true;
            continue;
        }
        if (arg_match.matchBool(token, "--show-progress", null)) {
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
            std.debug.print("Error: flag requires a value\n", .{});
        }
        printHelp(true);
        std.process.exit(255);
    };
    defer args.deinit(gpa);

    if (args.help) {
        printHelp(false);
        return;
    }

    // No positional JOBREF provided
    if (args.positionals.items.len == 0) {
        var buf: [256]u8 = undefined;
        var err_writer = std.fs.File.stderr().writer(&buf);
        const w = &err_writer.interface;
        w.writeAll("missing job reference, see --help for usage\n") catch {};
        w.flush() catch {};
        std.process.exit(255);
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
