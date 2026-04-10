const std = @import("std");
const zoqa = @import("zoqa");
const config = zoqa.config;

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

/// Check if the given API path is an absolute URL.
///
/// According to the specification, a path is absolute if:
/// - It starts with "//" or "#"
/// - It contains a colon ":" where all characters before it are NOT '/', '?', or '#'
///   (i.e., it matches the pattern ^[^:/?#]+:)
///
/// Arguments:
/// - `path`: The API path or URL to check.
///
/// Returns: `true` if it's an absolute URL, `false` otherwise.
fn isAbsoluteUrl(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "//") or std.mem.startsWith(u8, path, "#")) return true;
    const colon_idx = std.mem.indexOfScalar(u8, path, ':') orelse return false;
    for (path[0..colon_idx]) |c| {
        if (c == '/' or c == '?' or c == '#') return false;
    }
    return true;
}

test "isAbsoluteUrl: absolute schemes" {
    try std.testing.expect(isAbsoluteUrl("https://example.com/foo"));
    try std.testing.expect(isAbsoluteUrl("http://localhost"));
    try std.testing.expect(isAbsoluteUrl("ftp://files.example.com/data"));
    try std.testing.expect(isAbsoluteUrl("//example.com/path"));
    try std.testing.expect(isAbsoluteUrl("//cdn.example.com/asset.js"));
    try std.testing.expect(isAbsoluteUrl("#fragment"));
}

test "isAbsoluteUrl: relative paths" {
    try std.testing.expect(!isAbsoluteUrl("jobs/overview"));
    try std.testing.expect(!isAbsoluteUrl("/jobs/overview"));
    try std.testing.expect(!isAbsoluteUrl("jobs?state=running"));
    try std.testing.expect(!isAbsoluteUrl(""));
    // "foo/bar:baz" has a slash before the colon → not a scheme
    try std.testing.expect(!isAbsoluteUrl("foo/bar:baz"));
    try std.testing.expect(!isAbsoluteUrl("foo?bar:baz"));
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

pub const Args = struct {
    // global
    host: ?[]const u8 = null,
    osd: bool = false,
    o3: bool = false,
    odn: bool = false,
    apikey: ?[]const u8 = null,
    apisecret: ?[]const u8 = null,
    verbose: bool = false,
    quiet: bool = false,
    links: bool = false,
    // api subcommand
    method: []const u8 = "GET",
    data: ?[]const u8 = null,
    data_file: ?[]const u8 = null,
    form: bool = false,
    json: bool = false,
    pretty: bool = false,
    headers: std.ArrayList([]const u8),
    param_files: std.ArrayList([]const u8),
    retries: ?u32 = null,
    // positionals: args.path holds the subcommand token; kv_params holds PATH + KV pairs
    path: ?[]const u8 = null,
    // Positional arguments collected after the subcommand token, stored in order
    // of appearance on the command line. The layout is fixed by convention:
    //   [0]   — the API path (relative, e.g. "jobs/1234", or an absolute URL).
    //           Mandatory; buildRequest returns error.MissingPath when absent.
    //   [1..] — zero or more KEY=VALUE request-parameter strings
    //           (e.g. "DISTRI=sle", "state=running"). buildRequest
    //           percent-encodes these and places the result in
    //           RequestConfig.params_encoded, which openQAReq then routes
    //           as a URL query string (GET/DELETE) or request body
    //           (POST/PUT/PATCH) depending on the HTTP method.
    // All slices borrow directly from argv — no copies are made during parsing.
    kv_params: std.ArrayList([]const u8),
    // help requested
    help: bool = false,
    // User-Agent name (--name)
    name: []const u8 = "openQAclient",

    // archive subcommand options
    with_thumbnails: bool = false,
    asset_size_limit: ?u64 = null,

    /// Release the three owned ArrayLists.  Call this (via `defer`) immediately
    /// after a successful `parseArgs` return.
    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        self.headers.deinit(allocator);
        self.param_files.deinit(allocator);
        self.kv_params.deinit(allocator);
    }
};

/// Return the value for a flag that takes a single argument, handling both
/// the space form (`--flag VALUE`, which advances `i`) and the equals form
/// (`--flag=VALUE`, which slices the current token).  Returns `null` when
/// `arg` does not match `flag` at all.
///
/// `flag` must be the long-form name including the leading dashes, e.g.
/// `"--host"`.  Short aliases (e.g. `-X`) are handled by the caller as a
/// plain `eql` check before this function is called.
///
/// Errors:
///   - `error.MissingValue` — space form was matched but no next token exists.
fn flagValue(
    arg: []const u8,
    i: *usize,
    argv: []const []const u8,
    flag: []const u8,
) !?[]const u8 {
    if (std.mem.eql(u8, arg, flag)) {
        i.* += 1;
        if (i.* >= argv.len) return error.MissingValue;
        return argv[i.*];
    }
    // Equals form: arg must start with "flag=" and have at least one more byte.
    if (arg.len > flag.len + 1 and
        std.mem.startsWith(u8, arg, flag) and
        arg[flag.len] == '=')
    {
        return arg[flag.len + 1 ..];
    }
    return null;
}

/// Parse command-line arguments into an `Args` struct.
///
/// This function implements a CLI parser that handles:
/// - Global options (host, osd, o3, etc.)
/// - Subcommand identification (currently only "api")
/// - API-specific options (method, data, data-file, etc.)
/// - Positional arguments (API path and KEY=VALUE parameters)
/// - Argument terminator "--"
/// - Both space-separated (`--host openqa.org`) and equals-separated (`--host=openqa.org`) flag formats
///
/// Arguments:
/// - `allocator`: Used to allocate `std.ArrayList` buffers within the `Args` struct.
/// - `argv`: The raw command-line argument slices (including argv[0]).
///
/// Returns: `Args` struct on success, or an error if a flag is unknown or a value is missing.
/// The caller owns the `ArrayList` buffers in the returned `Args` and must call `deinit()` on them.
pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Args {
    var args = Args{
        .headers = .{},
        .param_files = .{},
        .kv_params = .{},
    };

    // The first argument (after argv[0]) must be the subcommand token.
    // If it starts with '-' (other than -h/--help or the stop-flag '--'),
    // reject with InvalidCommand to match Perl's Mojolicious dispatcher.
    if (argv.len > 1) {
        const first = argv[1];
        const is_help = std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help");
        const is_stop = std.mem.eql(u8, first, "--");
        if (!is_help and !is_stop and std.mem.startsWith(u8, first, "-")) {
            std.debug.print("Invalid command \"{s}\".\n", .{first});
            return error.InvalidCommand;
        }
    }

    var i: usize = 1; // skip argv[0]
    var past_subcmd = false;
    var stop_flags = false;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (stop_flags) {
            if (!past_subcmd) {
                past_subcmd = true;
                args.path = arg;
            } else if (args.path == null) {
                args.path = arg;
            } else {
                try args.kv_params.append(allocator, arg);
            }
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            stop_flags = true;
            continue;
        }

        // ---- boolean flags ----
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            args.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--osd")) {
            args.osd = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--o3")) {
            args.o3 = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--odn")) {
            args.odn = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            args.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            args.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--links")) {
            args.links = true;
            continue;
        }

        // ---- reject api-only flags when subcommand is archive ----
        if (args.path != null and std.mem.eql(u8, args.path.?, "archive")) {
            const is_api_only =
                std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--form") or
                std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json") or
                std.mem.eql(u8, arg, "-X") or
                std.mem.eql(u8, arg, "-d") or
                std.mem.eql(u8, arg, "-D") or
                std.mem.eql(u8, arg, "-a") or
                std.mem.eql(u8, arg, "--method") or std.mem.startsWith(u8, arg, "--method=") or
                std.mem.eql(u8, arg, "--data") or std.mem.startsWith(u8, arg, "--data=") or
                std.mem.eql(u8, arg, "--data-file") or std.mem.startsWith(u8, arg, "--data-file=") or
                std.mem.eql(u8, arg, "--header") or std.mem.startsWith(u8, arg, "--header=") or
                std.mem.eql(u8, arg, "--param-file") or std.mem.startsWith(u8, arg, "--param-file=");
            if (is_api_only) {
                std.debug.print("Unknown flag: {s}\n", .{arg});
                return error.UnknownFlag;
            }
        }

        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--form")) {
            args.form = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            args.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pretty")) {
            args.pretty = true;
            continue;
        }

        // ---- flags that take a value (space or = form) ----
        if (try flagValue(arg, &i, argv, "--host")) |v| {
            args.host = v;
            continue;
        }
        if (try flagValue(arg, &i, argv, "--apikey")) |v| {
            args.apikey = v;
            continue;
        }
        if (try flagValue(arg, &i, argv, "--apisecret")) |v| {
            args.apisecret = v;
            continue;
        }

        if (std.mem.eql(u8, arg, "-X")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.method = argv[i];
            continue;
        }
        if (try flagValue(arg, &i, argv, "--method")) |v| {
            args.method = v;
            continue;
        }

        if (std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.data = argv[i];
            continue;
        }
        if (try flagValue(arg, &i, argv, "--data")) |v| {
            args.data = v;
            continue;
        }

        if (std.mem.eql(u8, arg, "-D")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.data_file = argv[i];
            continue;
        }
        if (try flagValue(arg, &i, argv, "--data-file")) |v| {
            args.data_file = v;
            continue;
        }

        if (std.mem.eql(u8, arg, "-a")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            try args.headers.append(allocator, argv[i]);
            continue;
        }
        if (try flagValue(arg, &i, argv, "--header")) |v| {
            try args.headers.append(allocator, v);
            continue;
        }

        if (try flagValue(arg, &i, argv, "--param-file")) |v| {
            try args.param_files.append(allocator, v);
            continue;
        }

        if (std.mem.eql(u8, arg, "-r")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.retries = std.fmt.parseInt(u32, argv[i], 10) catch return error.InvalidRetries;
            continue;
        }
        if (try flagValue(arg, &i, argv, "--retries")) |v| {
            args.retries = std.fmt.parseInt(u32, v, 10) catch return error.InvalidRetries;
            continue;
        }

        if (try flagValue(arg, &i, argv, "--name")) |v| {
            args.name = v;
            continue;
        }

        // ---- archive-specific flags ----
        if (args.path != null and std.mem.eql(u8, args.path.?, "archive")) {
            if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--with-thumbnails")) {
                args.with_thumbnails = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-l")) {
                i += 1;
                if (i >= argv.len) return error.MissingValue;
                args.asset_size_limit = std.fmt.parseInt(u64, argv[i], 10) catch
                    return error.InvalidAssetSizeLimit;
                continue;
            }
            if (try flagValue(arg, &i, argv, "--asset-size-limit")) |v| {
                args.asset_size_limit = std.fmt.parseInt(u64, v, 10) catch
                    return error.InvalidAssetSizeLimit;
                continue;
            }
        }

        // ---- positionals / unrecognized flags ----

        // Any unrecognized flag after the subcommand is an error.
        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }

        // First positional = subcommand name (stored in path slot).
        // Second positional = api PATH (stored in kv_params[0]).
        // Remaining = KEY=VALUE params (stored in kv_params[1..]).
        if (!past_subcmd) {
            past_subcmd = true;
            args.path = arg; // subcommand token
            continue;
        }

        try args.kv_params.append(allocator, arg);
    }

    return args;
}

test "parseArgs: basic flags" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--host", "http://example.com", "-v", "-q", "jobs/overview", "state=running",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("http://example.com", parsed.host.?);
    try std.testing.expect(parsed.verbose);
    try std.testing.expect(parsed.quiet);
    try std.testing.expectEqualStrings("api", parsed.path.?);
    try std.testing.expectEqualStrings("jobs/overview", parsed.kv_params.items[0]);
    try std.testing.expectEqualStrings("state=running", parsed.kv_params.items[1]);
}

test "parseArgs: --method long and short" {
    const allocator = std.testing.allocator;

    // Test short form: -X
    {
        const argv: []const []const u8 = &.{ "zoqa", "api", "-X", "POST", "jobs" };
        var parsed = try parseArgs(allocator, argv);
        defer parsed.deinit(allocator);
        try std.testing.expectEqualStrings("POST", parsed.method);
    }

    // Test long form: --method
    {
        const argv: []const []const u8 = &.{ "zoqa", "api", "--method", "PUT", "jobs" };
        var parsed = try parseArgs(allocator, argv);
        defer parsed.deinit(allocator);
        try std.testing.expectEqualStrings("PUT", parsed.method);
    }
}

test "parseArgs: repeatable --header" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--header", "X-Foo: bar", "-a", "X-Baz: qux", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), parsed.headers.items.len);
    try std.testing.expectEqualStrings("X-Foo: bar", parsed.headers.items[0]);
    try std.testing.expectEqualStrings("X-Baz: qux", parsed.headers.items[1]);
}

test "parseArgs: --retries" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "--retries", "3", "jobs" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 3), parsed.retries.?);
}

test "parseArgs: equals-form flags" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa",
        "api",
        "--host=http://ex.com",
        "--apikey=K1",
        "--apisecret=S1",
        "--method=PUT",
        "--data=body",
        "--data-file=f.txt",
        "--header=X-A: B",
        "--param-file=K=V",
        "--retries=5",
        "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("http://ex.com", parsed.host.?);
    try std.testing.expectEqualStrings("K1", parsed.apikey.?);
    try std.testing.expectEqualStrings("S1", parsed.apisecret.?);
    try std.testing.expectEqualStrings("PUT", parsed.method);
    try std.testing.expectEqualStrings("body", parsed.data.?);
    try std.testing.expectEqualStrings("f.txt", parsed.data_file.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.headers.items.len);
    try std.testing.expectEqualStrings("X-A: B", parsed.headers.items[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.param_files.items.len);
    try std.testing.expectEqualStrings("K=V", parsed.param_files.items[0]);
    try std.testing.expectEqual(@as(u32, 5), parsed.retries.?);
}

test "parseArgs: unknown flag returns error" {
    const allocator = std.testing.allocator;
    // Flag before subcommand → InvalidCommand (§1.8)
    const argv: []const []const u8 = &.{ "zoqa", "--nonexistent" };
    try std.testing.expectError(error.InvalidCommand, parseArgs(allocator, argv));
}

test "parseArgs: unknown flag after subcommand returns UnknownFlag" {
    const allocator = std.testing.allocator;
    // Unknown flag after subcommand → UnknownFlag
    const argv: []const []const u8 = &.{ "zoqa", "api", "--nonexistent" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
}

test "parseArgs: missing value after flag returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "--host" };
    try std.testing.expectError(error.MissingValue, parseArgs(allocator, argv));
}

test "parseArgs: invalid retries returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "--retries", "abc" };
    try std.testing.expectError(error.InvalidRetries, parseArgs(allocator, argv));
}

test "parseArgs: flag before subcommand returns InvalidCommand" {
    const allocator = std.testing.allocator;
    // --host before the subcommand token → InvalidCommand (§1.8)
    const argv: []const []const u8 = &.{ "zoqa", "--host", "http://example.com", "api", "jobs" };
    try std.testing.expectError(error.InvalidCommand, parseArgs(allocator, argv));
}

test "parseArgs: -h before subcommand is allowed" {
    const allocator = std.testing.allocator;
    // -h/--help are exempt from the pre-subcommand restriction
    const argv: []const []const u8 = &.{ "zoqa", "-h" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.help);
}

test "parseArgs: stop flag --" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "--", "--osd", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    // --osd after -- is treated as subcmd, not flag
    try std.testing.expect(!parsed.osd);
    try std.testing.expectEqualStrings("--osd", parsed.path.?);
    try std.testing.expectEqualStrings("jobs", parsed.kv_params.items[0]);
}

test "parseArgs: short flags and aliases" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--osd", "-f", "-j", "-p", "-d", "raw_data", "-D", "file.txt", "path",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.osd);
    try std.testing.expect(parsed.form);
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.pretty);
    try std.testing.expectEqualStrings("raw_data", parsed.data.?);
    try std.testing.expectEqualStrings("file.txt", parsed.data_file.?);
}

// ---------------------------------------------------------------------------
// Cross-subcommand flag rejection: api-specific flags must be rejected
// when used with the archive subcommand.  Currently these flags are parsed
// unconditionally, so every sub-case below is expected to FAIL until the
// api-specific gate is added (symmetric with the archive gate at line 319).
// ---------------------------------------------------------------------------

test "parseArgs: api-specific flags rejected for archive" {
    const allocator = std.testing.allocator;

    // -f (short for --form)
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "-f", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // --form
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "--form", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // -j (short for --json)
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "-j", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // --json
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "--json", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // -X (short for --method)
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "-X", "POST", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // --method
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "--method", "POST", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // -d (short for --data)
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "-d", "body", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // --data
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "--data", "body", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // -D (short for --data-file)
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "-D", "f.json", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // --data-file
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "--data-file", "f.json", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // -a (short for --header)
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "-a", "X:Y", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // --header
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "--header", "X:Y", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
    // --param-file (no short form)
    {
        const argv: []const []const u8 = &.{ "zoqa", "archive", "--param-file", "p.txt", "12345", "/tmp/out" };
        try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
    }
}

// ---------------------------------------------------------------------------
// Missing -L alias: upstream openqa-cli.yaml defines "links|L" but our
// parseArgs only handles --links, not -L.  This test will FAIL until the
// alias is added.
// ---------------------------------------------------------------------------

test "parseArgs: -L alias for --links" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "-L", "jobs" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.links);
}

// ---------------------------------------------------------------------------
// Regression guards: confirm that combined short flags and archive-specific
// flags used with the api subcommand are correctly rejected.  These tests
// should PASS with the current code — they lock in existing correct behaviour.
// ---------------------------------------------------------------------------

test "parseArgs: combined short flags -vp rejected" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "-vp", "jobs" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
}

test "parseArgs: combined short flags -pv rejected" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "-pv", "jobs" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
}

test "parseArgs: archive flag -t rejected for api" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "-t", "jobs" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
}

test "parseArgs: archive flag --with-thumbnails rejected for api" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "--with-thumbnails", "jobs" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
}

test "parseArgs: archive flag -l rejected for api" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "-l", "1024", "jobs" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
}

test "parseArgs: archive flag --asset-size-limit rejected for api" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api", "--asset-size-limit", "1024", "jobs" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
}

// ---------------------------------------------------------------------------
// SPEC §13.1 compliance: --pretty and --links are "accepted but have no
// observable effect" for the archive subcommand.  These tests should PASS
// with the current code — they confirm the spec-mandated behaviour.
// ---------------------------------------------------------------------------

test "parseArgs: --pretty accepted for archive per SPEC 13.1" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "archive", "--pretty", "12345", "/tmp/out" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.pretty);
}

test "parseArgs: --links accepted for archive per SPEC 13.1" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "archive", "--links", "12345", "/tmp/out" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.links);
}

// ---------------------------------------------------------------------------
// --form: JSON object → application/x-www-form-urlencoded
// ---------------------------------------------------------------------------

/// Converts a JSON-formatted string into an application/x-www-form-urlencoded string.
///
/// This function is used to implement the `--form` flag logic. It expects the input
/// to be a flat JSON object. Nested objects or arrays are not supported and will
/// return `error.FormUnsupportedValueType`.
///
/// Supported JSON types:
/// - Strings: Passed through `formEncodeAppend`.
/// - Integers/Floats: Stringified and then encoded.
/// - Booleans: Converted to "true" or "false".
/// - Null: Result in an empty value (e.g., "key=").
///
/// Arguments:
/// - `allocator`: Used for JSON parsing and output buffer allocation.
/// - `body`: The raw JSON string to convert.
///
/// Returns: A newly-allocated, form-encoded string (e.g., "foo=bar&baz=123").
/// The caller owns the returned slice and must free it.
fn jsonToFormEncoded(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.FormRequiresJsonObject,
    };

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    var first = true;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.append(allocator, '&');
        first = false;
        try formEncodeAppend(allocator, &buf, entry.key_ptr.*);
        try buf.append(allocator, '=');
        switch (entry.value_ptr.*) {
            .string => |s| try formEncodeAppend(allocator, &buf, s),
            .integer => |n| {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{n});
                defer allocator.free(s);
                try formEncodeAppend(allocator, &buf, s);
            },
            .float => |f| {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
                defer allocator.free(s);
                try formEncodeAppend(allocator, &buf, s);
            },
            .bool => |b| try formEncodeAppend(allocator, &buf, if (b) "true" else "false"),
            .null => {}, // empty value
            else => return error.FormUnsupportedValueType,
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "jsonToFormEncoded: simple object" {
    const allocator = std.testing.allocator;
    const result = try jsonToFormEncoded(allocator, "{\"foo\":\"bar\",\"n\":42}");
    defer allocator.free(result);
    // std.json.ObjectMap preserves insertion order.
    try std.testing.expectEqualStrings("foo=bar&n=42", result);
}

test "jsonToFormEncoded: non-object returns error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.FormRequiresJsonObject,
        jsonToFormEncoded(allocator, "[1,2,3]"),
    );
}

test "jsonToFormEncoded: float and bool values" {
    const allocator = std.testing.allocator;
    const result = try jsonToFormEncoded(allocator, "{\"f\":3.14,\"b\":true}");
    defer allocator.free(result);
    // Float formatting may vary; just check it contains the key names
    try std.testing.expect(std.mem.indexOf(u8, result, "f=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "b=true") != null);
}

test "jsonToFormEncoded: null value produces empty value" {
    const allocator = std.testing.allocator;
    const result = try jsonToFormEncoded(allocator, "{\"x\":null}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("x=", result);
}

test "jsonToFormEncoded: nested array value returns error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.FormUnsupportedValueType,
        jsonToFormEncoded(allocator, "{\"arr\":[1,2]}"),
    );
}

test "jsonToFormEncoded: nested object value returns error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.FormUnsupportedValueType,
        jsonToFormEncoded(allocator, "{\"obj\":{\"a\":1}}"),
    );
}

test "jsonToFormEncoded: empty object" {
    const allocator = std.testing.allocator;
    const result = try jsonToFormEncoded(allocator, "{}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

/// Helper to check if a character is "unreserved" per RFC 3986.
fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

/// Appends a percent-encoded version of `input` to `buf` following `application/x-www-form-urlencoded` rules.
///
/// Behavior:
/// - Unreserved characters (A-Z, a-z, 0-9, '-', '_', '.', '~') are appended as-is.
/// - Space characters (' ') are converted to '+'.
/// - All other characters are percent-encoded as uppercase hex (e.g., '%0A').
///
/// Arguments:
/// - `allocator`: Used to grow the `buf` ArrayList if needed.
/// - `buf`: The destination buffer to append the encoded string to.
/// - `input`: The raw string to be encoded.
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

test "formEncodeAppend: unreserved chars pass through" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "hello_world-1.0~");
    try std.testing.expectEqualStrings("hello_world-1.0~", buf.items);
}

test "formEncodeAppend: spaces become plus, specials percent-encoded" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "a b=c&d");
    try std.testing.expectEqualStrings("a+b%3Dc%26d", buf.items);
}

test "formEncodeAppend: empty input produces empty output" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "formEncodeAppend: all special bytes percent-encoded" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "\x00\x01\xff");
    try std.testing.expectEqualStrings("%00%01%FF", buf.items);
}

/// Post-parseArgs processing result, ready to pass to `zoqa.openQAReq()`.
/// RequestConfig is purely a transitional container: it exists to bridge
/// the gap between raw CLI argument parsing (parseArgs → Args) and
/// the library's public API (openQAReq / CallOptions).
///
/// `buildRequest` extracts and validates CLI arguments into the fields needed
/// by the library's public API. URL construction is **not** performed here —
/// that responsibility belongs to `openQAReq`.
///
/// All slices are either borrowed from `Args` / `data_file_content` or owned
/// by internal buffers. Call `deinit()` to release owned memory.
const RequestConfig = struct {
    /// HTTP method parsed from `--method` / `-X` (default GET).
    method: std.http.Method,
    /// Resolved base URL of the target openQA instance
    /// (e.g. "http://openqa.suse.de", "https://myhost.example.com").
    /// Comes from `config.resolveHost` or from splitting an absolute URL.
    host: []const u8,
    /// Relative API path without the "/api/v1/" prefix
    /// (e.g. "jobs", "jobs/1234"). For absolute URLs this is extracted
    /// by stripping the scheme+authority and the "/api/v1/" prefix.
    path: []const u8,
    /// Pre-encoded `application/x-www-form-urlencoded` parameter string
    /// built from positional KEY=VALUE args and --param-file values
    /// (e.g. "DISTRI=sle&VERSION=15"). Empty slice when no params.
    params_encoded: []const u8,
    /// Optional request body from --data, --data-file, or --form.
    /// `null` when no explicit body was provided. Note: when params
    /// are present and no explicit body is set, `openQAReq` will use
    /// `params_encoded` as the body for POST/PUT/PATCH methods.
    body: ?[]const u8,
    /// Extra request headers from --header, --json, --form flags.
    headers: []const std.http.Header,

    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *RequestConfig) void {
        self.arena.deinit();
    }
};

/// Transform parsed CLI arguments into a `RequestConfig` ready for `zoqa.openQAReq()`.
///
/// This is the main post-`parseArgs` processing step. It performs everything
/// **except** final URL assembly and HTTP execution (both owned by `openQAReq`):
///   - Positional KEY=VALUE encoding into a percent-encoded params string.
///   - `--param-file` file reading, trimming, and encoding.
///   - Host resolution (`--host` / `--osd` / `--o3` / `--odn` → base URL).
///   - HTTP method string → `std.http.Method` parsing (case-insensitive).
///   - Body assembly from `--data`, `--data-file`, or `--form`.
///   - Header construction from `--header`, `--json`, and `--form` content-type.
///
/// For **absolute URLs** passed as the API path (e.g.
/// `zoqa api https://host/api/v1/jobs`), the function splits the URL into
/// `host` (scheme + authority) and `path` (relative, after `/api/v1/`).
///
/// **Side effects:** Reads `--param-file` targets from the filesystem via
/// `std.fs.cwd().readFileAlloc`. All other processing is pure.
///
/// Arguments:
///   - `allocator`: Used for all internal allocations (param encoding buffer,
///     form body conversion, host/path buffers, header list). Owned buffers are
///     tracked inside the returned `RequestConfig` and freed by its `deinit`.
///   - `args`: Parsed CLI arguments from `parseArgs`. Borrowed — the caller
///     must keep it alive (and its backing slices valid) for the lifetime of
///     the returned `RequestConfig`, since string fields may alias into it.
///   - `data_file_content`: Pre-read content of `--data-file` (or stdin).
///     Pass `null` when `--data-file` was not supplied. The caller reads
///     the file/stdin before calling this function because `--data-file`
///     supports `-` for stdin — a blocking, consume-once, process-global
///     operation that cannot be repeated inside a fuzz harness or unit test.
///     By contrast, `--param-file` is always a named path (no stdin), so it
///     is read internally via `readFileAlloc`; the fuzz harness compensates
///     with a temp-file rewrite.
///
/// Returns: A `RequestConfig` whose fields are ready to pass to
/// `zoqa.openQAReq()`. The caller owns the result and must call
/// `deinit(allocator)` to release internally-allocated buffers.
///
/// Errors:
///   - `error.MissingPath` — `args.kv_params` is empty (no API path provided).
///   - `error.FormRequiresData` — `--form` was set but no body source
///     (`--data` or `--data-file`) was provided.
///   - `error.FormRequiresJsonObject` — `--form` body is not a JSON object.
///   - `error.FormUnsupportedValueType` — `--form` JSON contains nested
///     arrays or objects.
///   - `error.PathContainsNullByte` — a `--param-file` path contains `\x00`.
///   - Any error from `std.fs.cwd().readFileAlloc` (param-file I/O),
///     `std.Uri.parse` (absolute URL), `config.resolveHost`, or allocator OOM.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    args: *const Args,
    data_file_content: ?[]const u8,
) !RequestConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // kv_params[0] = PATH, kv_params[1..] = KEY=VALUE pairs.
    if (args.kv_params.items.len == 0) return error.MissingPath;

    const api_path = args.kv_params.items[0];
    const kv_args = args.kv_params.items[1..];

    // Collect all parameters
    var params: std.ArrayList(u8) = .{};

    // Positional KEY=VALUE pairs
    for (kv_args) |p| {
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (params.items.len > 0) try params.append(arena_alloc, '&');
        try formEncodeAppend(arena_alloc, &params, p[0..eq]);
        try params.append(arena_alloc, '=');
        try formEncodeAppend(arena_alloc, &params, p[eq + 1 ..]);
    }

    // --param-file KEY=FILE
    for (args.param_files.items) |pf| {
        const eq = std.mem.indexOfScalar(u8, pf, '=') orelse continue;
        const key = pf[0..eq];
        const file_path = pf[eq + 1 ..];

        // Security check: Zig's path functions assert no null bytes.
        if (std.mem.indexOfScalar(u8, file_path, 0) != null) return error.PathContainsNullByte;

        const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);
        defer allocator.free(contents);
        const trimmed = std.mem.trimRight(u8, contents, "\n\r");
        if (params.items.len > 0) try params.append(arena_alloc, '&');
        try formEncodeAppend(arena_alloc, &params, key);
        try params.append(arena_alloc, '=');
        try formEncodeAppend(arena_alloc, &params, trimmed);
    }

    // Parse HTTP method (accept upper or lower case)
    const method = std.meta.stringToEnum(std.http.Method, args.method) orelse blk: {
        var upper_buf: [16]u8 = undefined;
        if (args.method.len <= upper_buf.len) {
            const upper = std.ascii.upperString(upper_buf[0..args.method.len], args.method);
            break :blk std.meta.stringToEnum(std.http.Method, upper) orelse .GET;
        }
        break :blk .GET;
    };

    // --- Host + path resolution ---
    // Two cases:
    //   1. Relative path (e.g. "jobs") → resolve host from flags, path = api_path.
    //   2. Absolute URL (e.g. "https://host/api/v1/jobs") → split into host + path.

    // SAFETY: both variables are unconditionally assigned in every branch of the
    // if/else below before any subsequent read. The `if (isAbsoluteUrl(...))` /
    // `else` pair is exhaustive, so no branch can reach the code after the block
    // without having written a valid slice into each variable.
    var resolved_host: []const u8 = undefined;
    // SAFETY: Unconditionally assigned alongside resolved_host in all branches.
    var relative_path: []const u8 = undefined;

    if (isAbsoluteUrl(api_path)) {
        // Absolute URL: split into host (scheme+authority) and relative path.
        // e.g. "https://custom.host/api/v1/jobs/123" → host="https://custom.host", path="jobs/123"
        const uri = try std.Uri.parse(api_path);
        const host_part = if (uri.host) |h| h.percent_encoded else "localhost";

        // Reconstruct scheme + authority as the host, preserving the port if present.
        // uri.scheme is []const u8 in Zig 0.15.2 (e.g. "https"), not an enum.
        resolved_host = if (uri.port) |port|
            try std.fmt.allocPrint(arena_alloc, "{s}://{s}:{d}", .{
                uri.scheme,
                host_part,
                port,
            })
        else
            try std.fmt.allocPrint(arena_alloc, "{s}://{s}", .{
                uri.scheme,
                host_part,
            });

        // Extract relative path by stripping the /api/v1/ prefix if present.
        const raw_path = uri.path.percent_encoded;
        const api_prefix = "/api/v1/";
        if (std.mem.startsWith(u8, raw_path, api_prefix)) {
            relative_path = raw_path[api_prefix.len..];
        } else if (std.mem.startsWith(u8, raw_path, "/api/v1")) {
            // Exact "/api/v1" without trailing slash
            relative_path = "";
        } else {
            // No /api/v1/ prefix — pass entire path (strip leading slash).
            // openQAReq will still prepend /api/v1/, so this means the
            // absolute URL didn't follow the openQA convention. We
            // preserve the path as-is for maximum flexibility.
            relative_path = if (std.mem.startsWith(u8, raw_path, "/")) raw_path[1..] else raw_path;
        }

        // If the original URL had a query string, append it to relative_path
        if (uri.query) |q| {
            relative_path = try std.fmt.allocPrint(arena_alloc, "{s}?{s}", .{ relative_path, q.percent_encoded });
        }
    } else {
        // Relative path: resolve host from CLI flags / --host / default.
        const host_res = try config.resolveHost(
            arena_alloc,
            args.osd,
            args.o3,
            args.odn,
            args.host,
        );
        resolved_host = host_res.url;

        // Strip leading slash from relative path to avoid double-slash in URL.
        relative_path = if (std.mem.startsWith(u8, api_path, "/")) api_path[1..] else api_path;
    }

    // Build request body
    // Note: KV params are NOT placed in the body here — that routing is
    // done by openQAReq based on the HTTP method. Only explicit --data,
    // --data-file, and --form bodies are set here.
    var req_body: ?[]const u8 = null;

    if (data_file_content) |dfc| {
        req_body = dfc;
    } else if (args.data) |d| {
        req_body = d;
    }

    // --form: JSON object body → application/x-www-form-urlencoded
    if (args.form) {
        if (req_body) |rb| {
            req_body = try jsonToFormEncoded(arena_alloc, rb);
        } else {
            return error.FormRequiresData;
        }
    }

    // Build extra request headers
    var custom_headers: std.ArrayList(std.http.Header) = .{};

    for (args.headers.items) |h| {
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        const name = std.mem.trim(u8, h[0..colon], " \t");
        const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
        try custom_headers.append(arena_alloc, .{ .name = name, .value = value });
    }

    if (args.json) {
        try custom_headers.append(arena_alloc, .{ .name = "Content-Type", .value = "application/json" });
    }

    // Add form content-type when:
    //   - --form flag is set, OR
    //   - POST/PUT/PATCH with KV params and no explicit --data/--data-file
    //     (params will become the body via openQAReq routing)
    if (args.form or ((method == .POST or method == .PUT or method == .PATCH) and
        params.items.len > 0 and args.data == null and args.data_file == null))
    {
        try custom_headers.append(arena_alloc, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" });
    }

    // User-Agent header from --name (default: "openQAclient")
    try custom_headers.append(arena_alloc, .{ .name = "User-Agent", .value = args.name });

    return .{
        .method = method,
        .host = resolved_host,
        .path = relative_path,
        .params_encoded = params.items[0..params.items.len],
        .body = req_body,
        .headers = try custom_headers.toOwnedSlice(arena_alloc),
        .arena = arena,
    };
}

test "buildRequest: GET with KV params appends query string" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--host", "http://example.com", "jobs", "state=running",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    try std.testing.expect(req_cfg.method == .GET);
    // params_encoded should contain the encoded KV pair (query string routing is done by openQAReq)
    try std.testing.expectEqualStrings("state=running", req_cfg.params_encoded);
    try std.testing.expectEqualStrings("http://example.com", req_cfg.host);
    try std.testing.expectEqualStrings("jobs", req_cfg.path);
}

test "buildRequest: POST with --data and --form" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa",   "api",    "--host",            "http://example.com", "-X", "POST",
        "--form", "--data", "{\"foo\":\"bar\"}", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    try std.testing.expect(req_cfg.method == .POST);
    try std.testing.expect(req_cfg.body != null);
    try std.testing.expectEqualStrings("foo=bar", req_cfg.body.?);
    // Should have Content-Type: application/x-www-form-urlencoded header
    var found_ct = false;
    for (req_cfg.headers) |h| {
        if (std.mem.eql(u8, h.name, "Content-Type") and
            std.mem.eql(u8, h.value, "application/x-www-form-urlencoded"))
        {
            found_ct = true;
            break;
        }
    }
    try std.testing.expect(found_ct);
}

test "buildRequest: lowercase method is upper-cased" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "-X", "post", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    try std.testing.expect(req_cfg.method == .POST);
}

test "buildRequest: absolute URL used as-is" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "https://custom.host/api/v1/jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    // Absolute URL should be split into host + path
    try std.testing.expectEqualStrings("https://custom.host", req_cfg.host);
    try std.testing.expectEqualStrings("jobs", req_cfg.path);
}

test "buildRequest: absolute URL with port preserves port in host" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "http://172.19.203.185:8080/api/v1/jobs/1",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    // Port must be preserved — without the fix this returns "http://172.19.203.185"
    try std.testing.expectEqualStrings("http://172.19.203.185:8080", req_cfg.host);
    try std.testing.expectEqualStrings("jobs/1", req_cfg.path);
}

test "buildRequest: --header with colon splitting" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--header", "X-Custom: my-value", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    // X-Custom + User-Agent = 2 headers
    try std.testing.expectEqual(@as(usize, 2), req_cfg.headers.len);
    try std.testing.expectEqualStrings("X-Custom", req_cfg.headers[0].name);
    try std.testing.expectEqualStrings("my-value", req_cfg.headers[0].value);
}

test "buildRequest: --json adds Content-Type header" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--json", "-X", "POST", "--data", "{}", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    var found_json_ct = false;
    for (req_cfg.headers) |h| {
        if (std.mem.eql(u8, h.name, "Content-Type") and
            std.mem.eql(u8, h.value, "application/json"))
        {
            found_json_ct = true;
            break;
        }
    }
    try std.testing.expect(found_json_ct);
}

test "buildRequest: --form without --data returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--form", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expectError(error.FormRequiresData, buildRequest(allocator, &parsed, null));
}

test "buildRequest: data-file content used as body" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "-X", "POST", "--data-file", "dummy.txt", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    const file_data = "file body content";
    var req_cfg = try buildRequest(allocator, &parsed, file_data);
    defer req_cfg.deinit();

    try std.testing.expectEqualStrings("file body content", req_cfg.body.?);
}

test "buildRequest: --osd flag resolves to openqa.suse.de" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--osd", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    try std.testing.expect(std.mem.indexOf(u8, req_cfg.host, "openqa.suse.de") != null);
}

test "buildRequest: DELETE with KV params appends query string" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa",   "api",     "-X", "DELETE", "--host", "http://example.com",
        "jobs/1", "force=1",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    try std.testing.expect(req_cfg.method == .DELETE);
    // params_encoded should contain the encoded KV pair (query string routing is done by openQAReq)
    try std.testing.expectEqualStrings("force=1", req_cfg.params_encoded);
}

test "buildRequest: POST with KV params uses body not query string" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api",        "-X",         "POST", "--host", "http://example.com",
        "jobs", "DISTRI=sle", "VERSION=15",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    try std.testing.expect(req_cfg.method == .POST);
    // buildRequest no longer puts KV params in body — that routing is
    // owned by openQAReq. Instead, params_encoded holds the encoded pairs.
    try std.testing.expect(req_cfg.body == null);
    try std.testing.expect(std.mem.indexOf(u8, req_cfg.params_encoded, "DISTRI=sle") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_cfg.params_encoded, "VERSION=15") != null);
    // Should have form Content-Type (added by buildRequest for POST with KV params)
    var found_ct = false;
    for (req_cfg.headers) |h| {
        if (std.mem.eql(u8, h.name, "Content-Type") and
            std.mem.eql(u8, h.value, "application/x-www-form-urlencoded"))
        {
            found_ct = true;
            break;
        }
    }
    try std.testing.expect(found_ct);
}

test "buildRequest: missing path returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "api" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expectError(error.MissingPath, buildRequest(allocator, &parsed, null));
}

test "buildRequest: --o3 flag resolves to openqa.opensuse.org" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--o3", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    try std.testing.expect(std.mem.indexOf(u8, req_cfg.host, "openqa.opensuse.org") != null);
}

test "buildRequest: --header without colon is skipped" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--header", "MalformedHeader", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    // Malformed header without colon should be silently skipped.
    // Only User-Agent should remain (always injected by buildRequest).
    try std.testing.expectEqual(@as(usize, 1), req_cfg.headers.len);
    try std.testing.expectEqualStrings("User-Agent", req_cfg.headers[0].name);
}

test "buildRequest: leading slash stripped from relative api path" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--host", "http://example.com", "/jobs/overview",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    // Should split into host + path with no double slash
    try std.testing.expectEqualStrings("http://example.com", req_cfg.host);
    try std.testing.expectEqualStrings("jobs/overview", req_cfg.path);
}

test "buildRequest: bare hostname gets https:// prefix via resolveHost" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--host", "myhost.example.com", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    try std.testing.expect(std.mem.startsWith(u8, req_cfg.host, "https://myhost.example.com"));
}

test "buildRequest: data-file content with --form encodes JSON body" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "-X", "POST", "--data-file", "dummy.json", "--form", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    const file_data = "{\"key\":\"value\"}";
    var req_cfg = try buildRequest(allocator, &parsed, file_data);
    defer req_cfg.deinit();

    try std.testing.expectEqualStrings("key=value", req_cfg.body.?);
}

test "buildRequest: path with null byte returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--param-file", "key=path\x00with_null", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expectError(error.PathContainsNullByte, buildRequest(allocator, &parsed, null));
}

test "buildRequest: --name sets User-Agent header" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--host", "http://example.com", "--name", "mybot", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    // Find User-Agent header
    var found = false;
    for (req_cfg.headers) |h| {
        if (std.mem.eql(u8, h.name, "User-Agent")) {
            try std.testing.expectEqualStrings("mybot", h.value);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "buildRequest: default User-Agent is openQAclient" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--host", "http://example.com", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit();

    var found = false;
    for (req_cfg.headers) |h| {
        if (std.mem.eql(u8, h.name, "User-Agent")) {
            try std.testing.expectEqualStrings("openQAclient", h.value);
            found = true;
        }
    }
    try std.testing.expect(found);
}

/// Resolve and merge API credentials from all possible sources according to priority.
///
/// Authentication to the openQA API requires two parts: a key and a secret.
/// These can be provided through three mechanisms, evaluated independently
/// for each field in the following priority order (highest to lowest):
///
/// 1. **CLI flags**: `--apikey` and `--apisecret`
/// 2. **Environment variables**: `OPENQA_API_KEY` and `OPENQA_API_SECRET`
/// 3. **Configuration file**: the `[<host>]` section in `client.conf`
///
/// Because priority is evaluated per-field, a user could theoretically provide
/// the key via CLI flag and the secret via environment variable, though usually
/// both come from the same source.
///
/// This function does **not** fetch the configuration file itself; it expects
/// the already-parsed `conf` struct matching the target host, and simply applies
/// the override logic.
///
/// Arguments:
/// - `allocator`: Used to duplicate the final resolved key and secret strings.
///   The caller will own these allocations.
/// - `cli`: The key/secret optionally provided via command-line flags.
/// - `env`: The key/secret optionally provided via environment variables.
/// - `conf`: The key/secret optionally found in the parsed configuration file
///   for the chosen host.
///
/// Returns:
/// - `?config.Credentials`: A struct containing the fully resolved `key` and
///   `secret`. The slices are newly allocated and **owned by the caller**, who
///   must call `deinit()` or manually free both fields.
/// - `null`: Returned if either the key or the secret (or both) are completely
///   missing across all three sources. In this case, the request will proceed
///   unauthenticated.
///
/// Errors:
/// - `error.OutOfMemory`: If duplication of the resolved strings fails.
fn mergeCredentials(
    allocator: std.mem.Allocator,
    cli: struct { key: ?[]const u8, secret: ?[]const u8 },
    env: struct { key: ?[]const u8, secret: ?[]const u8 },
    conf: ?config.Credentials,
) !?config.Credentials {
    const key = cli.key orelse env.key orelse if (conf) |c| c.key else null;
    const secret = cli.secret orelse env.secret orelse if (conf) |c| c.secret else null;

    if (key != null and secret != null) {
        return config.Credentials{
            .allocator = allocator,
            .key = try allocator.dupe(u8, key.?),
            .secret = try allocator.dupe(u8, secret.?),
        };
    }
    return null;
}

test "mergeCredentials: field-level priority behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Scenario 1: Partial CLI override (Secret only)
    // Should combine CLI secret with Config key
    {
        const res = try mergeCredentials(
            allocator,
            .{ .key = null, .secret = "CLI_SECRET" },
            .{ .key = null, .secret = null },
            .{ .allocator = allocator, .key = "CONF_KEY", .secret = "CONF_SECRET" },
        );
        try testing.expect(res != null);
        defer res.?.deinit();
        try testing.expectEqualStrings("CONF_KEY", res.?.key);
        try testing.expectEqualStrings("CLI_SECRET", res.?.secret);
    }

    // Scenario 2: CLI overrides ENV
    {
        const res = try mergeCredentials(
            allocator,
            .{ .key = "CLI_KEY", .secret = null },
            .{ .key = "ENV_KEY", .secret = "ENV_SECRET" },
            null,
        );
        try testing.expect(res != null);
        defer res.?.deinit();
        try testing.expectEqualStrings("CLI_KEY", res.?.key);
        try testing.expectEqualStrings("ENV_SECRET", res.?.secret);
    }

    // Scenario 3: All null returns null
    {
        const res = try mergeCredentials(
            allocator,
            .{ .key = null, .secret = null },
            .{ .key = null, .secret = null },
            null,
        );
        try testing.expect(res == null);
    }
}

test "mergeCredentials: env-only fallback (no CLI, no conf)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = null, .secret = null },
        .{ .key = "ENV_KEY", .secret = "ENV_SECRET" },
        null,
    );
    try testing.expect(res != null);
    defer res.?.deinit();
    try testing.expectEqualStrings("ENV_KEY", res.?.key);
    try testing.expectEqualStrings("ENV_SECRET", res.?.secret);
}

test "mergeCredentials: conf-only fallback (no CLI, no env)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = null, .secret = null },
        .{ .key = null, .secret = null },
        .{ .allocator = allocator, .key = "CONF_KEY", .secret = "CONF_SECRET" },
    );
    try testing.expect(res != null);
    defer res.?.deinit();
    try testing.expectEqualStrings("CONF_KEY", res.?.key);
    try testing.expectEqualStrings("CONF_SECRET", res.?.secret);
}

test "mergeCredentials: key from env, secret from conf" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = null, .secret = null },
        .{ .key = "ENV_KEY", .secret = null },
        .{ .allocator = allocator, .key = "CONF_KEY", .secret = "CONF_SECRET" },
    );
    try testing.expect(res != null);
    defer res.?.deinit();
    try testing.expectEqualStrings("ENV_KEY", res.?.key);
    try testing.expectEqualStrings("CONF_SECRET", res.?.secret);
}

test "mergeCredentials: partial key only returns null (no secret anywhere)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = "CLI_KEY", .secret = null },
        .{ .key = null, .secret = null },
        null,
    );
    try testing.expect(res == null);
}

test "mergeCredentials: partial secret only returns null (no key anywhere)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = null, .secret = "CLI_SECRET" },
        .{ .key = null, .secret = null },
        null,
    );
    try testing.expect(res == null);
}

// ---------------------------------------------------------------------------
// printResponse — format and write HTTP response to stdout/stderr
// ---------------------------------------------------------------------------

/// Write the HTTP response to stdout (and optionally stderr), implementing
/// verbose headers, link header parsing and body
/// output with optional JSON pretty-printing.
///
/// This is a pure output helper with no control-flow side effects — it never
/// calls `std.process.exit`. The caller (`main()`) is responsible for the exit
/// code.
///
/// Every `stdout.print` / `stdout.writeAll` call uses `catch {}` to silently
/// swallow write errors. This is intentional: when the output is piped into a
/// process that closes early (e.g. `zoqa ... | head`), the OS delivers SIGPIPE
/// or returns EPIPE on the next write. Propagating that error would cause the
/// CLI to exit with a confusing diagnostic; swallowing it produces the same
/// silent exit behaviour as coreutils.
///
/// Arguments:
///   - `allocator`: Scratch allocator for JSON pretty-print parsing. Only used
///     when `pretty` is true and the response body is `application/json`.
///   - `resp`: The HTTP response returned by `zoqa.openQAReq()`. Borrowed —
///     the caller retains ownership and is responsible for calling `resp.deinit()`.
///   - `verbose`: When true, print the HTTP status line and all response headers
///     to stdout before the body.
///   - `quiet`: When true, suppresses the non-2xx status line written to stderr.
///     Has no effect on stdout output.
///   - `links`: When true and the response contains a Link header, parse it and
///     print `rel: url` pairs to stderr.
///   - `pretty`: When true and Content-Type contains `application/json`, parse
///     the body and re-serialize with 2-space indentation.
fn printResponse(
    allocator: std.mem.Allocator,
    resp: zoqa.APIResponse,
    verbose: bool,
    quiet: bool,
    links: bool,
    pretty: bool,
) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // non-2xx status to stderr (suppressed by --quiet)
    const status_uint = @intFromEnum(resp.status);
    if ((status_uint < 200 or status_uint >= 300) and !quiet) {
        std.debug.print("{d} {s}\n", .{ status_uint, resp.status.phrase() orelse "Unknown Error" });
    }

    // verbose response headers
    if (verbose) {
        _ = stdout.print("HTTP/1.1 {d} {s}\n", .{
            @intFromEnum(resp.status),
            resp.status.phrase() orelse "Unknown",
        }) catch {}; // broken-pipe safe
        for (resp.response_headers) |h| {
            _ = stdout.print("{s}: {s}\n", .{ h.name, h.value }) catch {}; // broken-pipe safe
        }
        _ = stdout.print("\n", .{}) catch {}; // broken-pipe safe
        _ = stdout.flush() catch {}; // broken-pipe safe
    }

    // Link header parsing to stderr
    if (links) {
        if (resp.link) |lh| {
            var stderr_buf: [4096]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
            var it = zoqa.parseLinkHeader(lh);
            while (it.next()) |link| {
                _ = stderr_writer.interface.print("{s}: {s}\n", .{ link.rel, link.url }) catch {}; // broken-pipe safe
            }
            _ = stderr_writer.interface.flush() catch {}; // broken-pipe safe
        }
    }

    // body output (pretty JSON or raw)
    if (pretty) {
        const is_json = if (resp.content_type) |ct|
            std.mem.indexOf(u8, ct, "application/json") != null
        else
            false;
        if (is_json) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch null;
            if (parsed) |*p| {
                defer p.deinit();
                _ = std.json.Stringify.value(p.value, .{ .whitespace = .indent_2 }, stdout) catch {}; // broken-pipe safe
                _ = stdout.writeByte('\n') catch {}; // broken-pipe safe
            } else {
                _ = stdout.writeAll(resp.body) catch {}; // broken-pipe safe
                _ = stdout.writeByte('\n') catch {}; // broken-pipe safe
            }
        } else {
            _ = stdout.writeAll(resp.body) catch {}; // broken-pipe safe
            _ = stdout.writeByte('\n') catch {}; // broken-pipe safe
        }
    } else {
        _ = stdout.writeAll(resp.body) catch {}; // broken-pipe safe
        _ = stdout.writeByte('\n') catch {}; // broken-pipe safe
    }
    _ = stdout.flush() catch {}; // broken-pipe safe
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    var args = parseArgs(gpa, argv) catch |err| {
        if (err == error.InvalidCommand) std.process.exit(255);
        std.debug.print("Argument error: {s}\n", .{@errorName(err)});
        printHelp();
        std.process.exit(255);
    };
    defer args.deinit(gpa);

    if (args.help) {
        printHelp();
        return;
    }

    // args.path holds the subcommand token ("api").
    const subcmd = args.path orelse {
        std.debug.print("Error: Missing subcommand. Use 'api'.\n", .{});
        std.process.exit(1);
    };

    if (!std.mem.eql(u8, subcmd, "api") and !std.mem.eql(u8, subcmd, "archive")) {
        std.debug.print("Error: Unknown subcommand '{s}'. Only 'api' and 'archive' are supported.\n", .{subcmd});
        std.process.exit(1);
    }

    // Read --data-file content before buildRequest (filesystem I/O)
    var data_file_buf: ?[]u8 = null;
    defer if (data_file_buf) |b| gpa.free(b);

    if (args.data_file) |df| {
        if (std.mem.indexOfScalar(u8, df, 0) != null) return error.PathContainsNullByte;
        data_file_buf = if (std.mem.eql(u8, df, "-"))
            try std.fs.File.stdin().readToEndAlloc(gpa, 10 * 1024 * 1024)
        else
            try std.fs.cwd().readFileAlloc(gpa, df, 10 * 1024 * 1024);
    }

    const data_file_content: ?[]const u8 = if (data_file_buf) |b| b else null;

    var req_cfg: ?RequestConfig = null;
    defer if (req_cfg) |*cfg| cfg.deinit();

    if (std.mem.eql(u8, subcmd, "api")) {
        req_cfg = buildRequest(gpa, &args, data_file_content) catch |err| {
            if (err == error.MissingPath) {
                printApiHelp();
                std.process.exit(255);
            }
            std.debug.print("Request build error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, subcmd, "archive")) {
        if (args.kv_params.items.len < 2) {
            printArchiveHelp();
            std.process.exit(255);
        }
    }

    // Resolve credentials
    // Extract hostname from the resolved host URL for config file lookup.
    const host_for_uri = if (req_cfg) |cfg| cfg.host else args.host orelse "localhost";
    const hostname = blk: {
        const uri = std.Uri.parse(host_for_uri) catch {
            break :blk host_for_uri;
        };
        break :blk if (uri.host) |h| h.percent_encoded else "localhost";
    };

    const conf_creds = try config.findCredentials(gpa, hostname);
    defer if (conf_creds) |c| c.deinit();

    const env_apikey = std.process.getEnvVarOwned(gpa, "OPENQA_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (env_apikey) |s| gpa.free(s);

    const env_apisecret = std.process.getEnvVarOwned(gpa, "OPENQA_API_SECRET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (env_apisecret) |s| gpa.free(s);

    const creds = try mergeCredentials(
        gpa,
        .{ .key = args.apikey, .secret = args.apisecret },
        .{ .key = env_apikey, .secret = env_apisecret },
        conf_creds,
    );
    defer if (creds) |c| c.deinit();

    // Retry count: --retries > OPENQA_CLI_RETRIES env > 0
    const retries: u32 = args.retries orelse blk: {
        const env_s = std.process.getEnvVarOwned(gpa, "OPENQA_CLI_RETRIES") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk 0,
            else => return err,
        };
        defer gpa.free(env_s);
        break :blk std.fmt.parseInt(u32, env_s, 10) catch 0;
    };

    // Execution knobs: resolved from env here and passed into CallOptions so
    // that http_client.zig stays free of std.posix / env-var dependencies.
    const connect_timeout_s: f64 = blk: {
        const env_s = std.process.getEnvVarOwned(gpa, "OPENQA_CLI_CONNECT_TIMEOUT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk 30.0,
            else => return err,
        };
        defer gpa.free(env_s);
        break :blk std.fmt.parseFloat(f64, env_s) catch {
            std.debug.print("error: OPENQA_CLI_CONNECT_TIMEOUT={s}: not a valid number\n", .{env_s});
            return error.InvalidConnectTimeout;
        };
    };

    const retry_sleep_s: f64 = blk: {
        const env_s = std.process.getEnvVarOwned(gpa, "OPENQA_CLI_RETRY_SLEEP_TIME_S") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk 3.0,
            else => return err,
        };
        defer gpa.free(env_s);
        break :blk std.fmt.parseFloat(f64, env_s) catch 3.0;
    };

    const retry_factor: f64 = blk: {
        const env_s = std.process.getEnvVarOwned(gpa, "OPENQA_CLI_RETRY_FACTOR") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk 1.0,
            else => return err,
        };
        defer gpa.free(env_s);
        break :blk std.fmt.parseFloat(f64, env_s) catch 1.0;
    };

    if (std.mem.eql(u8, subcmd, "api")) {
        // Execute the request via the library's public API entry point.
        var client = std.http.Client{ .allocator = gpa };
        defer client.deinit();

        const cfg = req_cfg.?;
        const resp = zoqa.openQAReq(cfg.host, cfg.path, .{
            .allocator = gpa,
            .method = cfg.method,
            .headers = cfg.headers,
            .params = cfg.params_encoded,
            .body = cfg.body,
            .credentials = creds,
            .retries = retries,
            .quiet = args.quiet,
            .connect_timeout_s = connect_timeout_s,
            .retry_sleep_s = retry_sleep_s,
            .retry_factor = retry_factor,
        }, &client) catch |err| {
            if (!args.quiet) std.debug.print("Fatal: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer resp.deinit();

        printResponse(gpa, resp, args.verbose, args.quiet, args.links, args.pretty);

        std.process.exit(resp.exitCode());
    } else if (std.mem.eql(u8, subcmd, "archive")) {
        if (args.kv_params.items.len < 2) {
            printArchiveHelp();
            std.process.exit(255);
        }
        const job_id = std.fmt.parseInt(u64, args.kv_params.items[0], 10) catch {
            std.debug.print("Invalid JOB_ID: {s}\n", .{args.kv_params.items[0]});
            std.process.exit(1);
        };
        const output_path = args.kv_params.items[1];

        const archive_opts = zoqa.ArchiveOptions{
            .with_thumbnails = args.with_thumbnails,
            .asset_size_limit = args.asset_size_limit orelse 209_715_200,
            .credentials = creds,
            .quiet = args.quiet,
            .retries = retries,
            .retry_sleep_s = retry_sleep_s,
            .retry_factor = retry_factor,
        };

        const host_res = config.resolveHost(
            gpa,
            args.osd,
            args.o3,
            args.odn,
            args.host,
        ) catch |err| {
            std.debug.print("Host resolution error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer if (host_res.allocated) gpa.free(host_res.url);

        var client = std.http.Client{ .allocator = gpa };
        defer client.deinit();

        zoqa.runArchive(gpa, &client, host_res.url, job_id, output_path, archive_opts) catch |err| {
            std.debug.print("archive: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.process.exit(0);
    }
}

// ---------------------------------------------------------------------------
// Help text
// ---------------------------------------------------------------------------

const help_global_options =
    \\Global Options:
    \\  --host HOST          Base URL of the OpenQA instance
    \\  --osd                Alias for --host http://openqa.suse.de
    \\  --o3                 Alias for --host https://openqa.opensuse.org
    \\  --odn                Alias for --host https://openqa.debian.net
    \\  --apikey KEY         Override API public key
    \\  --apisecret SECRET   Override API secret
    \\  --name STRING        User-Agent name (default: openQAclient)
    \\  -v, --verbose        Print HTTP response status line and headers to stdout
    \\  -q, --quiet          Suppress non-fatal error messages on stderr
    \\  --links              Parse Link response header and print rel: url pairs to stderr
    \\  -h, --help           Display this help and exit
    \\
;

const help_api_options =
    \\API Options:
    \\  -X, --method METHOD        HTTP method (default: GET)
    \\  -d, --data BODY            Raw request body
    \\  -D, --data-file FILE       Read body from file (- = stdin)
    \\  -f, --form                 Treat data as JSON object, re-encode as form urlencoded
    \\  -j, --json                 Set Content-Type: application/json
    \\  -a, --header NAME:VALUE    Extra request header (repeatable)
    \\  --param-file KEY=FILE      Append file contents as param (repeatable)
    \\  -r, --retries N            Retry count on 502/503/connection error (default: 0)
    \\  -p, --pretty               Pretty-print JSON response body
    \\
;

const help_archive_options =
    \\Archive Options:
    \\  -t, --with-thumbnails   Download thumbnails for screenshots
    \\  -l, --asset-size-limit  Skip downloading assets larger than this limit (default 200MiB)
    \\
;

fn printHelp() void {
    std.debug.print(
        "Usage: zoqa [GLOBAL OPTIONS] SUBCOMMAND [OPTIONS] ...\n\n" ++
            "Subcommands:\n" ++
            "  api       Make an openQA API request\n" ++
            "  archive   Download assets and test results from a job\n\n" ++
            help_global_options ++
            help_api_options ++
            help_archive_options,
        .{},
    );
}

/// Print the `api` subcommand usage block to stderr.
/// Called when PATH is missing (exit 255, per Perl reference behavior).
fn printApiHelp() void {
    std.debug.print(
        "Usage: zoqa api [OPTIONS] PATH [KEY=VALUE ...]\n\n" ++
            "Make an openQA API request. PATH is the API endpoint (e.g. \"jobs\") or an absolute URL.\n\n" ++
            help_api_options ++
            help_global_options,
        .{},
    );
}

/// Print the `archive` subcommand usage block to stderr.
fn printArchiveHelp() void {
    std.debug.print(
        "Usage: zoqa archive [OPTIONS] JOB_ID OUTPUT_PATH\n\n" ++
            "Download assets and test results from a job into a local directory.\n\n" ++
            help_archive_options ++
            help_global_options,
        .{},
    );
}
