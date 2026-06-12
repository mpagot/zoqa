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

pub const Subcommand = enum { api, archive, monitor, schedule };

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
    // Identified subcommand. Set by parseArgs; null only when args.help is true.
    subcmd: ?Subcommand = null,
    // Positional arguments collected after the subcommand token, stored in order
    // of appearance on the command line. The layout is fixed by convention:
    //   [0]   : the API path (relative, e.g. "jobs/1234", or an absolute URL).
    //           Mandatory; buildRequest returns error.MissingPath when absent.
    //   [1..] : zero or more KEY=VALUE request-parameter strings
    //           (e.g. "DISTRI=sle", "state=running"). buildRequest
    //           percent-encodes these and places the result in
    //           RequestConfig.params_encoded, which openQAReq then routes
    //           as a URL query string (GET/DELETE) or request body
    //           (POST/PUT/PATCH) depending on the HTTP method.
    // All slices borrow directly from argv, no copies are made during parsing.
    kv_params: std.ArrayList([]const u8),
    // help requested
    help: bool = false,
    // User-Agent name (--name)
    name: []const u8 = "openQAclient",

    // archive subcommand options
    with_thumbnails: bool = false,
    asset_size_limit: ?u64 = null,

    // monitor subcommand options
    follow: bool = false,
    poll_interval: ?u64 = null,

    // schedule subcommand options
    schedule_monitor: bool = false,

    /// Release the three owned ArrayLists.  Call this (via `defer`) immediately
    /// after a successful `parseArgs` return.
    ///
    /// Arguments:
    /// - `allocator`: The same allocator that was passed to `parseArgs`; used to
    ///   release the backing storage of `headers`, `param_files`, and `kv_params`.
    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        self.headers.deinit(allocator);
        self.param_files.deinit(allocator);
        self.kv_params.deinit(allocator);
    }
};

/// Returns true when `token` — a single item from the command line —
/// matches either `long` (e.g. `"--verbose"`) or, if provided, `short`
/// (e.g. `"-v"`).  Pass `null` for `short` when no alias exists.
fn matchBool(token: []const u8, long: []const u8, short: ?[]const u8) bool {
    if (std.mem.eql(u8, token, long)) return true;
    if (short) |s| return std.mem.eql(u8, token, s);
    return false;
}

/// Returns the value for a flag that takes an argument, handling both the space
/// form (`--flag VALUE`) and the equals form (`--flag=VALUE`).
/// Returns `null` when `token` does not match either form.
///
/// `token`  — the current argv token being tested.
/// `i`      — current argv index (advanced by 1 when the space form matches).
/// `argv`   — the full argv slice (used to fetch the next token for space form).
/// `long`   — long-form flag name, e.g. `"--method"`.
/// `short`  — short-form alias, e.g. `"-X"`, or `null` when none exists.
///
/// Errors:
///   - `error.MissingValue` — space form was matched but no next token exists.
fn matchValue(
    token: []const u8,
    i: *usize,
    argv: []const []const u8,
    long: []const u8,
    short: ?[]const u8,
) !?[]const u8 {
    if (short) |s| {
        if (std.mem.eql(u8, token, s)) {
            i.* += 1;
            if (i.* >= argv.len) return error.MissingValue;
            return argv[i.*];
        }
    }
    if (std.mem.eql(u8, token, long)) {
        i.* += 1;
        if (i.* >= argv.len) return error.MissingValue;
        return argv[i.*];
    }
    // Equals form: token must start with "long=" and have at least one more byte.
    if (token.len > long.len + 1 and
        std.mem.startsWith(u8, token, long) and
        token[long.len] == '=')
    {
        return token[long.len + 1 ..];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Scoped flag dispatchers: one function per scope
// ---------------------------------------------------------------------------

/// Try to match `token` against a global flag (accepted by all subcommands).
/// Returns `true` when the flag was consumed, `false` if unmatched.
///
/// `args`  — mutable Args struct being populated.
/// `token` — the current argv token being tested.
/// `i`     — current argv index cursor (passed through to matchValue).
/// `argv`  — full argv slice (passed through to matchValue).
fn tryGlobalFlag(
    args: *Args,
    token: []const u8,
    i: *usize,
    argv: []const []const u8,
) !bool {
    // Boolean global flags
    if (matchBool(token, "--help", "-h")) {
        args.help = true;
        return true;
    }
    if (matchBool(token, "--osd", null)) {
        args.osd = true;
        return true;
    }
    if (matchBool(token, "--o3", null)) {
        args.o3 = true;
        return true;
    }
    if (matchBool(token, "--odn", null)) {
        args.odn = true;
        return true;
    }
    if (matchBool(token, "--verbose", "-v")) {
        args.verbose = true;
        return true;
    }
    if (matchBool(token, "--quiet", "-q")) {
        args.quiet = true;
        return true;
    }
    if (matchBool(token, "--links", "-L")) {
        args.links = true;
        return true;
    }
    if (matchBool(token, "--pretty", "-p")) {
        args.pretty = true;
        return true;
    }

    // Value global flags
    if (try matchValue(token, i, argv, "--host", null)) |v| {
        args.host = v;
        return true;
    }
    if (try matchValue(token, i, argv, "--apikey", null)) |v| {
        args.apikey = v;
        return true;
    }
    if (try matchValue(token, i, argv, "--apisecret", null)) |v| {
        args.apisecret = v;
        return true;
    }
    if (try matchValue(token, i, argv, "--name", null)) |v| {
        args.name = v;
        return true;
    }
    if (try matchValue(token, i, argv, "--retries", "-r")) |v| {
        args.retries = std.fmt.parseInt(u32, v, 10) catch return error.InvalidRetries;
        return true;
    }

    return false;
}

/// Try to match `token` against a flag specific to the `api` subcommand
/// (`zoqa api ...`).
/// Returns `true` when the flag was consumed, `false` if unmatched.
///
/// `args`      — mutable Args struct being populated.
/// `allocator` — used to allocate space in `args.headers` and `args.param_files`.
/// `token`     — the current argv token being tested.
/// `i`         — current argv index cursor (passed through to matchValue).
/// `argv`      — full argv slice (passed through to matchValue).
fn tryApiFlag(
    args: *Args,
    allocator: std.mem.Allocator,
    token: []const u8,
    i: *usize,
    argv: []const []const u8,
) !bool {
    // Boolean api flags
    if (matchBool(token, "--form", "-f")) {
        args.form = true;
        return true;
    }
    if (matchBool(token, "--json", "-j")) {
        args.json = true;
        return true;
    }

    // Value api flags
    if (try matchValue(token, i, argv, "--method", "-X")) |v| {
        args.method = v;
        return true;
    }
    if (try matchValue(token, i, argv, "--data", "-d")) |v| {
        args.data = v;
        return true;
    }
    if (try matchValue(token, i, argv, "--data-file", "-D")) |v| {
        args.data_file = v;
        return true;
    }
    if (try matchValue(token, i, argv, "--header", "-a")) |v| {
        try args.headers.append(allocator, v);
        return true;
    }
    if (try matchValue(token, i, argv, "--param-file", null)) |v| {
        try args.param_files.append(allocator, v);
        return true;
    }

    return false;
}

/// Try to match `token` against a flag specific to the `archive` subcommand
/// (`zoqa archive ...`).
/// Returns `true` when the flag was consumed, `false` if unmatched.
///
/// `args`  — mutable Args struct being populated.
/// `token` — the current argv token being tested.
/// `i`     — current argv index cursor (passed through to matchValue).
/// `argv`  — full argv slice (passed through to matchValue).
fn tryArchiveFlag(
    args: *Args,
    token: []const u8,
    i: *usize,
    argv: []const []const u8,
) !bool {
    if (matchBool(token, "--with-thumbnails", "-t")) {
        args.with_thumbnails = true;
        return true;
    }
    if (try matchValue(token, i, argv, "--asset-size-limit", "-l")) |v| {
        args.asset_size_limit = std.fmt.parseInt(u64, v, 10) catch
            return error.InvalidAssetSizeLimit;
        return true;
    }
    return false;
}

/// Try to match `token` against a flag specific to the `monitor` subcommand
/// (`zoqa monitor ...`).
/// Returns `true` when the flag was consumed, `false` if unmatched.
///
/// Recognised flags:
///   - `--follow` / `-f` — track the newest clone of each job during
///     polling; sets `args.follow`.
///   - `--poll-interval` / `-i` — polling interval in seconds;
///     sets `args.poll_interval`. Defaults to `10` in `buildMonitorRequest`
///     when absent.
///
/// `args`  — mutable Args struct being populated.
/// `token` — the current argv token being tested.
/// `i`     — current argv index cursor (passed through to matchValue).
/// `argv`  — full argv slice (passed through to matchValue).
fn tryMonitorFlag(
    args: *Args,
    token: []const u8,
    i: *usize,
    argv: []const []const u8,
) !bool {
    if (matchBool(token, "--follow", "-f")) {
        args.follow = true;
        return true;
    }
    if (try matchValue(token, i, argv, "--poll-interval", "-i")) |v| {
        args.poll_interval = std.fmt.parseInt(u64, v, 10) catch
            return error.InvalidPollInterval;
        return true;
    }
    return false;
}

/// Try to match `token` against a flag specific to the `schedule` subcommand
/// (`zoqa schedule ...`).
/// Returns `true` when the flag was consumed, `false` if unmatched.
///
/// Recognised flags:
///   - `--monitor` / `-m` — after scheduling, enter the blocking job monitor
///     loop; sets `args.schedule_monitor`.
///   - `--follow` / `-f` — track the newest clone of each job during
///     monitoring; sets `args.follow`. Meaningful only with `--monitor`.
///   - `--poll-interval` / `-i` — monitoring poll interval in seconds;
///     sets `args.poll_interval`. Defaults to `1` in `buildScheduleRequest`
///     when absent (shorter than the monitor subcommand's default of `10`).
///   - `--param-file KEY=FILE` — read KEY's value from a file and append it
///     to the POST body; appends to `args.param_files` (repeatable, no short
///     form). Unlike the `api` subcommand, `schedule` has no PATH positional
///     — every positional is a KEY=VALUE POST parameter for `/api/v1/isos`.
///
/// `args`      — mutable Args struct being populated.
/// `allocator` — used to grow `args.param_files` for `--param-file` entries.
/// `token`     — the current argv token being tested.
/// `i`         — current argv index cursor (passed through to matchValue).
/// `argv`      — full argv slice (passed through to matchValue).
fn tryScheduleFlag(
    args: *Args,
    allocator: std.mem.Allocator,
    token: []const u8,
    i: *usize,
    argv: []const []const u8,
) !bool {
    if (matchBool(token, "--monitor", "-m")) {
        args.schedule_monitor = true;
        return true;
    }
    if (matchBool(token, "--follow", "-f")) {
        args.follow = true;
        return true;
    }
    if (try matchValue(token, i, argv, "--poll-interval", "-i")) |v| {
        args.poll_interval = std.fmt.parseInt(u64, v, 10) catch
            return error.InvalidPollInterval;
        return true;
    }
    if (try matchValue(token, i, argv, "--param-file", null)) |v| {
        try args.param_files.append(allocator, v);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// parseArgs — subcommand-dispatched CLI parser
// ---------------------------------------------------------------------------

/// Parse command-line arguments into an `Args` struct.
///
/// The parser works in two phases:
///   1. Extract and validate the subcommand token at argv[1].
///   2. Loop over the remaining arguments, dispatching to scoped flag
///      handlers based on the identified subcommand.
///
/// A successful return guarantees `args.subcmd` is non-null unless
/// `args.help` is true (the bare `zoqa -h` case).
///
/// Errors:
///   - `error.MissingSubcommand` — no arguments after the program name.
///   - `error.InvalidCommand` — a flag (starting with `-`) at position 1.
///   - `error.UnknownSubcommand` — argv[1] is not a known subcommand.
///   - `error.UnknownFlag` — unrecognised flag after the subcommand.
///   - `error.MissingValue` — a value-taking flag has no following token.
pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Args {
    var args = Args{
        .headers = .empty,
        .param_files = .empty,
        .kv_params = .empty,
    };

    // Phase 1: subcommand extraction and validation.
    if (argv.len < 2) return error.MissingSubcommand;

    const first = argv[1];

    // -h / --help at position 1: return immediately with help flag set.
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        args.help = true;
        return args;
    }

    // Any other flag at position 1 is an error (matches Perl's Mojolicious
    // dispatcher which rejects flags before the subcommand).
    if (std.mem.startsWith(u8, first, "-")) {
        std.debug.print("Invalid command \"{s}\".\n", .{first});
        return error.InvalidCommand;
    }

    // Validate the subcommand token.
    args.subcmd = std.meta.stringToEnum(Subcommand, first) orelse {
        std.debug.print("Error: Unknown subcommand '{s}'.\n", .{first});
        return error.UnknownSubcommand;
    };

    // Phase 2: parse flags and positionals after the subcommand.
    var i: usize = 2;
    var stop_flags = false;

    while (i < argv.len) : (i += 1) {
        const token = argv[i];

        // After `--`, everything is a positional.
        if (stop_flags) {
            try args.kv_params.append(allocator, token);
            continue;
        }

        // "--" is the POSIX argument terminator: every token after it is
        // a positional, even if it starts with "-".
        if (std.mem.eql(u8, token, "--")) {
            stop_flags = true;
            continue;
        }

        // Global flags (accepted by all subcommands)
        if (try tryGlobalFlag(&args, token, &i, argv)) continue;

        // Subcommand-specific flags
        // Safe: phase 1 ensures args.subcmd is non-null before parsing flags
        switch (args.subcmd.?) {
            .api => if (try tryApiFlag(&args, allocator, token, &i, argv)) continue,
            .archive => if (try tryArchiveFlag(&args, token, &i, argv)) continue,
            .monitor => if (try tryMonitorFlag(&args, token, &i, argv)) continue,
            .schedule => if (try tryScheduleFlag(&args, allocator, token, &i, argv)) continue,
        }

        // Unknown flag
        if (std.mem.startsWith(u8, token, "-")) {
            std.debug.print("Unknown flag: {s}\n", .{token});
            return error.UnknownFlag;
        }

        // Positional argument
        try args.kv_params.append(allocator, token);
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
    try std.testing.expect(parsed.subcmd.? == .api);
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

test "parseArgs: bare zoqa returns MissingSubcommand" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{"zoqa"};
    try std.testing.expectError(error.MissingSubcommand, parseArgs(allocator, argv));
}

test "parseArgs: unknown subcommand returns UnknownSubcommand" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "banana" };
    try std.testing.expectError(error.UnknownSubcommand, parseArgs(allocator, argv));
}

test "parseArgs: stop flag -- at position 1 is rejected" {
    const allocator = std.testing.allocator;
    // -- at argv[1] is now treated as any other flag-like token → InvalidCommand.
    // (The old behaviour accepted it and treated everything after as positionals,
    // but the resulting "subcommand" was never valid anyway.)
    const argv: []const []const u8 = &.{
        "zoqa", "--", "--osd", "jobs",
    };
    try std.testing.expectError(error.InvalidCommand, parseArgs(allocator, argv));
}

test "parseArgs: stop flag -- after subcommand" {
    const allocator = std.testing.allocator;
    // -- after the subcommand stops flag parsing; remaining tokens are positionals.
    const argv: []const []const u8 = &.{
        "zoqa", "api", "--", "--osd", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expect(!parsed.osd);
    try std.testing.expect(parsed.subcmd.? == .api);
    try std.testing.expectEqualStrings("--osd", parsed.kv_params.items[0]);
    try std.testing.expectEqualStrings("jobs", parsed.kv_params.items[1]);
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
// when used with the archive subcommand.  The subcommand-dispatched parser
// handles this structurally : tryApiFlag is only called for .api.
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
// Missing -L alias: upstream openqa-cli.yaml defines "links|L".  The
// subcommand-dispatched parser includes -L in tryGlobalFlag via matchBool.
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
// should PASS with the current code : they lock in existing correct behaviour.
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
// --pretty and --links are "accepted but have no
// observable effect" for the archive subcommand.  These tests should PASS
// with the current code : they confirm the spec-mandated behaviour.
// ---------------------------------------------------------------------------

test "parseArgs: --pretty accepted for archive no effects" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "zoqa", "archive", "--pretty", "12345", "/tmp/out" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.pretty);
}

test "parseArgs: --links accepted for archive no effects" {
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
///
/// Errors:
///   - `error.FormRequiresJsonObject` : input is not a JSON object.
///   - `error.FormUnsupportedValueType` : a value is an array or nested object.
///   - JSON parse errors or `OutOfMemory` from the allocator.
fn jsonToFormEncoded(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.FormRequiresJsonObject,
    };

    var buf: std.ArrayList(u8) = .empty;
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
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "hello_world-1.0~");
    try std.testing.expectEqualStrings("hello_world-1.0~", buf.items);
}

test "formEncodeAppend: spaces become plus, specials percent-encoded" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "a b=c&d");
    try std.testing.expectEqualStrings("a+b%3Dc%26d", buf.items);
}

test "formEncodeAppend: empty input produces empty output" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "formEncodeAppend: all special bytes percent-encoded" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
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
/// by the library's public API. URL construction is **not** performed here:
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

    /// Release all memory owned by this configuration via the internal arena allocator.
    /// After this call, all string slices inside the struct become invalid.
    pub fn deinit(self: *RequestConfig) void {
        self.arena.deinit();
    }
};

/// ArchiveConfig is a transitional container: it exists to bridge
/// the gap between raw CLI argument parsing (parseArgs → Args) and
/// the library's public API (runArchive / ArchiveOptions).
///
/// It encapsulates the resolved arguments necessary to perform an archive download.
/// All slices are either borrowed from `Args` or owned by the internal `arena`.
/// Call `deinit()` to release owned memory.
const ArchiveConfig = struct {
    /// Resolved base URL of the target openQA instance (e.g. "https://openqa.suse.de").
    /// Comes from `config.resolveHost` processing aliases and `--host`.
    host: []const u8,
    /// The numeric openQA job identifier (base-10).
    job_id: u64,
    /// Local filesystem path where the downloaded archive assets will be stored.
    output_path: []const u8,
    /// Archive-specific options (e.g. thumbnails, asset limits) derived from CLI flags.
    options: zoqa.ArchiveOptions,
    /// Arena allocator owning dynamically allocated fields like `host`.
    arena: std.heap.ArenaAllocator,

    /// Releases all dynamically allocated memory owned by this configuration.
    fn deinit(self: *ArchiveConfig) void {
        self.arena.deinit();
    }
};

/// Build a form-encoded parameter string from positional KEY=VALUE arguments
/// and `--param-file KEY=FILE` entries. Used by both the `api` and `schedule`
/// subcommands.
///
/// Arguments:
///   - `allocator`: Used for file reads (`--param-file`). Temp allocations
///     are freed before return.
///   - `arena_alloc`: Arena allocator owning the returned string buffer.
///   - `kv_args`: Positional KEY=VALUE slices (borrowed from argv).
///   - `param_file_entries`: `--param-file KEY=FILE` slices (borrowed from argv).
///
/// Returns: The encoded string (owned by `arena_alloc`). Empty slice when
/// there are no parameters.
///
/// Errors:
///   - `error.PathContainsNullByte` : a file path contains `\x00`.
///   - Any error from `std.fs.cwd().readFileAlloc` or allocator OOM.
fn buildFormParams(
    allocator: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,
    kv_args: []const []const u8,
    param_file_entries: []const []const u8,
) ![]const u8 {
    var params: std.ArrayList(u8) = .empty;

    // Positional KEY=VALUE pairs
    for (kv_args) |p| {
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (params.items.len > 0) try params.append(arena_alloc, '&');
        try formEncodeAppend(arena_alloc, &params, p[0..eq]);
        try params.append(arena_alloc, '=');
        try formEncodeAppend(arena_alloc, &params, p[eq + 1 ..]);
    }

    // --param-file KEY=FILE
    for (param_file_entries) |pf| {
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

    return params.items[0..params.items.len];
}

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
///   - `error.MissingPath` : `args.kv_params` is empty (no API path provided).
///   - `error.FormRequiresData` : `--form` was set but no body source
///     (`--data` or `--data-file`) was provided.
///   - `error.FormRequiresJsonObject` : `--form` body is not a JSON object.
///   - `error.FormUnsupportedValueType` : `--form` JSON contains nested
///     arrays or objects.
///   - `error.PathContainsNullByte` : a `--param-file` path contains `\x00`.
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

    // Collect all parameters (shared helper handles KV pairs + --param-file)
    const params_encoded = try buildFormParams(allocator, arena_alloc, kv_args, args.param_files.items);

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

    // These two variables use `= undefined` (uninitialized memory) intentionally.
    //
    // WHY NOT a safe default like `= ""`?
    //   Using `undefined` makes any missed-assignment bug crash immediately in
    //   Debug builds (Zig fills undefined memory with 0xAA, so dereferencing it
    //   segfaults).  A dummy default like "" would silently produce wrong URLs.
    //
    // WHY NOT `?[]const u8 = null` (optional)?
    //   Both values are unconditionally needed after this block.  Wrapping them
    //   in optionals would force pointless `.?` unwraps at every use site for a
    //   null state that can never actually occur.
    //
    // PROOF OF SOUNDNESS:
    //   Assigned in the `if (isAbsoluteUrl(api_path)) { ... } else { ... }` block
    //   immediately below (~50 lines).  That if/else is exhaustive: exactly one
    //   branch always executes.  Within each branch, every path that doesn't
    //   propagate an error assigns BOTH variables before the branch ends.
    //
    // MAINTAINER NOTE: if you add an early `return` or new branch inside the
    // if/else below, you MUST assign both variables on that path, or convert
    // them to optionals.
    var resolved_host: []const u8 = undefined;
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
            // No /api/v1/ prefix : pass entire path (strip leading slash).
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
    } // ← end of exhaustive if/else: resolved_host and relative_path are
    //   now both guaranteed to hold valid slices.

    // Build request body
    // Note: KV params are NOT placed in the body here : that routing is
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
    var custom_headers: std.ArrayList(std.http.Header) = .empty;

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
        params_encoded.len > 0 and args.data == null and args.data_file == null))
    {
        try custom_headers.append(arena_alloc, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" });
    }

    // User-Agent header from --name (default: "openQAclient")
    try custom_headers.append(arena_alloc, .{ .name = "User-Agent", .value = args.name });

    return .{
        .method = method,
        .host = resolved_host,
        .path = relative_path,
        .params_encoded = params_encoded,
        .body = req_body,
        .headers = try custom_headers.toOwnedSlice(arena_alloc),
        .arena = arena,
    };
}

/// Transform parsed CLI arguments into an `ArchiveConfig` ready for `zoqa.runArchive()`.
///
/// Validates the presence of required positional arguments (`JOB_ID` and `OUTPUT_PATH`),
/// parses the `JOB_ID` as a base-10 integer, and resolves the target host/alias.
///
/// It intentionally does NOT populate connection-related options like `.credentials`,
/// `.retries`, or `.quiet`—these are supplied by the caller in `main()` from shared
/// environment and configuration file resolution.
///
/// Arguments:
///   - `allocator`: Used for internal allocations (like host resolution buffers).
///     Owned buffers are tracked inside the returned `ArchiveConfig` and freed by its `deinit`.
///   - `args`: Parsed CLI arguments from `parseArgs`. Borrowed — the caller must keep
///     it alive for the lifetime of the returned `ArchiveConfig`.
///
/// Returns:
///   - `ArchiveConfig` containing the resolved arguments.
///
/// Errors:
///   - `error.MissingArchiveArgs`: If fewer than 2 positional arguments were provided.
///   - `error.InvalidJobId`: If the `JOB_ID` positional argument is not a valid integer.
fn buildArchiveRequest(
    allocator: std.mem.Allocator,
    args: *const Args,
) !ArchiveConfig {
    if (args.kv_params.items.len < 2) return error.MissingArchiveArgs;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const job_id = std.fmt.parseInt(u64, args.kv_params.items[0], 10) catch
        return error.InvalidJobId;
    const output_path = args.kv_params.items[1];

    const host_res = try config.resolveHost(
        arena_alloc,
        args.osd,
        args.o3,
        args.odn,
        args.host,
    );

    return .{
        .host = host_res.url,
        .job_id = job_id,
        .output_path = output_path,
        .options = .{
            .with_thumbnails = args.with_thumbnails,
            .asset_size_limit = args.asset_size_limit orelse 209_715_200,
        },
        .arena = arena,
    };
}

const MonitorConfig = struct {
    host: []const u8,
    job_ids: []const u64,
    follow: bool,
    poll_interval: u64,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *MonitorConfig) void {
        self.arena.deinit();
    }
};

fn buildMonitorRequest(
    allocator: std.mem.Allocator,
    args: *const Args,
) !MonitorConfig {
    if (args.kv_params.items.len < 1) return error.MissingMonitorArgs;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var job_ids = try arena_alloc.alloc(u64, args.kv_params.items.len);
    for (args.kv_params.items, 0..) |param, i| {
        job_ids[i] = std.fmt.parseInt(u64, param, 10) catch
            return error.InvalidJobId;
    }

    const host_res = try config.resolveHost(
        arena_alloc,
        args.osd,
        args.o3,
        args.odn,
        args.host,
    );

    return .{
        .host = host_res.url,
        .job_ids = job_ids,
        .follow = args.follow,
        .poll_interval = args.poll_interval orelse 10,
        .arena = arena,
    };
}

/// ScheduleConfig is a transitional container: it bridges the gap between
/// raw CLI argument parsing (parseArgs → Args) and the library's public API
/// (runSchedule / ScheduleOptions).
const ScheduleConfig = struct {
    /// Resolved base URL of the target openQA instance.
    host: []const u8,
    /// Pre-encoded form body string for POST /api/v1/isos.
    params_encoded: []const u8,
    /// Whether --monitor was specified.
    monitor_jobs: bool,
    /// Whether --follow was specified.
    follow: bool,
    /// Polling interval in seconds (default 1 for schedule).
    poll_interval: u64,
    /// User-Agent header value.
    name: []const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *ScheduleConfig) void {
        self.arena.deinit();
    }
};

/// Transform parsed CLI arguments into a `ScheduleConfig` ready for `zoqa.runSchedule()`.
///
/// Validates that at least one KEY=VALUE positional argument is present,
/// form-encodes all parameters (positional + `--param-file`), and resolves
/// the target host.
///
/// Arguments:
///   - `allocator`: Used for internal allocations.
///   - `args`: Parsed CLI arguments from `parseArgs`.
///
/// Errors:
///   - `error.MissingScheduleArgs` — no KEY=VALUE positional arguments.
///   - `error.PathContainsNullByte` — a `--param-file` path contains `\x00`.
///   - Any error from file I/O, host resolution, or allocator OOM.
fn buildScheduleRequest(
    allocator: std.mem.Allocator,
    args: *const Args,
) !ScheduleConfig {
    if (args.kv_params.items.len < 1) return error.MissingScheduleArgs;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // All kv_params are KEY=VALUE pairs (no PATH for schedule).
    const params_encoded = try buildFormParams(allocator, arena_alloc, args.kv_params.items, args.param_files.items);

    const host_res = try config.resolveHost(
        arena_alloc,
        args.osd,
        args.o3,
        args.odn,
        args.host,
    );

    return .{
        .host = host_res.url,
        .params_encoded = params_encoded,
        .monitor_jobs = args.schedule_monitor,
        .follow = args.follow,
        .poll_interval = args.poll_interval orelse 1,
        .name = args.name,
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

    // Port must be preserved. Without the fix this returns "http://172.19.203.185"
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

test "buildArchiveRequest: valid positional arguments" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "archive", "12345", "/tmp/out",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var cfg = try buildArchiveRequest(allocator, &parsed);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u64, 12345), cfg.job_id);
    try std.testing.expectEqualStrings("/tmp/out", cfg.output_path);
    try std.testing.expectEqualStrings("http://localhost", cfg.host);
}

test "buildArchiveRequest: invalid job id returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "archive", "notanumber", "/tmp/out",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expectError(error.InvalidJobId, buildArchiveRequest(allocator, &parsed));
}

test "buildArchiveRequest: missing positional arguments returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "archive", "12345",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expectError(error.MissingArchiveArgs, buildArchiveRequest(allocator, &parsed));
}

test "buildArchiveRequest: --osd flag resolves to openqa.suse.de" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "archive", "--osd", "12345", "/tmp/out",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var cfg = try buildArchiveRequest(allocator, &parsed);
    defer cfg.deinit();

    try std.testing.expect(std.mem.indexOf(u8, cfg.host, "openqa.suse.de") != null);
}

test "buildArchiveRequest: --o3 flag resolves to openqa.opensuse.org" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "archive", "--o3", "12345", "/tmp/out",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var cfg = try buildArchiveRequest(allocator, &parsed);
    defer cfg.deinit();

    try std.testing.expect(std.mem.indexOf(u8, cfg.host, "openqa.opensuse.org") != null);
}

test "buildArchiveRequest: archive specific flags" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "archive", "--with-thumbnails", "--asset-size-limit", "1024", "12345", "/tmp/out",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var cfg = try buildArchiveRequest(allocator, &parsed);
    defer cfg.deinit();

    try std.testing.expect(cfg.options.with_thumbnails);
    try std.testing.expectEqual(@as(u64, 1024), cfg.options.asset_size_limit);
}

test "buildArchiveRequest: absolute url in host adds https via resolveHost" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "archive", "--host", "myhost.example.com", "12345", "/tmp/out",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var cfg = try buildArchiveRequest(allocator, &parsed);
    defer cfg.deinit();

    try std.testing.expect(std.mem.startsWith(u8, cfg.host, "https://myhost.example.com"));
}

test "buildMonitorRequest: valid positional arguments" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "monitor", "12345", "67890",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var cfg = try buildMonitorRequest(allocator, &parsed);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.job_ids.len);
    try std.testing.expectEqual(@as(u64, 12345), cfg.job_ids[0]);
    try std.testing.expectEqual(@as(u64, 67890), cfg.job_ids[1]);
    try std.testing.expectEqualStrings("http://localhost", cfg.host);
}

test "buildMonitorRequest: invalid job id returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "monitor", "12345", "abc",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expectError(error.InvalidJobId, buildMonitorRequest(allocator, &parsed));
}

test "buildMonitorRequest: missing positional arguments returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "zoqa", "monitor",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    try std.testing.expectError(error.MissingMonitorArgs, buildMonitorRequest(allocator, &parsed));
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
// printResponse : format and write HTTP response to stdout/stderr
// ---------------------------------------------------------------------------

/// Write the HTTP response to stdout (and optionally stderr), implementing
/// verbose headers, link header parsing and body
/// output with optional JSON pretty-printing.
///
/// This is a pure output helper with no control-flow side effects: it never
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

/// Entry point for the `zoqa` CLI: parse arguments, resolve credentials, and
/// dispatch to the appropriate subcommand handler (`api`, `archive`, `monitor`,
/// or `schedule`).
///
/// Most argument and runtime errors are handled internally: invalid subcommands
/// and missing required positionals print help to stderr and call
/// `std.process.exit(255)`; request/network failures call `std.process.exit(1)`.
/// Only a small set of errors propagate to the OS as a non-zero exit from the
/// error-union return:
///
/// Errors:
///   - `error.PathContainsNullByte` : `--data-file` path contains `\x00`.
///   - `error.InvalidConnectTimeout` : `OPENQA_CLI_CONNECT_TIMEOUT` env var
///     is present but cannot be parsed as a floating-point number.
///   - Any I/O error from reading `--data-file` / stdin or from loading
///     `~/.config/openqa/client.conf` via `config.findCredentials`.
///   - `error.OutOfMemory` from any internal allocation.
pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    var args = parseArgs(gpa, argv) catch |err| {
        if (err == error.InvalidCommand) std.process.exit(255);
        if (err == error.MissingSubcommand) {
            printHelp(false);
            return;
        }
        if (err == error.UnknownSubcommand) {
            printHelp(true);
            std.process.exit(255);
        }
        std.debug.print("Argument error: {s}\n", .{@errorName(err)});
        printHelp(true);
        std.process.exit(255);
    };
    defer args.deinit(gpa);

    if (args.help) {
        if (args.subcmd) |sc| {
            switch (sc) {
                .api => printApiHelp(false),
                .archive => printArchiveHelp(false),
                .monitor => printMonitorHelp(false),
                .schedule => printScheduleHelp(false),
            }
        } else {
            printHelp(false);
        }
        return;
    }

    // parseArgs guarantees subcmd is non-null when help is false.
    const subcmd = args.subcmd.?;

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

    var archive_cfg: ?ArchiveConfig = null;
    defer if (archive_cfg) |*cfg| cfg.deinit();

    var monitor_cfg: ?MonitorConfig = null;
    defer if (monitor_cfg) |*cfg| cfg.deinit();

    var schedule_cfg: ?ScheduleConfig = null;
    defer if (schedule_cfg) |*cfg| cfg.deinit();

    switch (subcmd) {
        .api => {
            req_cfg = buildRequest(gpa, &args, data_file_content) catch |err| {
                if (err == error.MissingPath) {
                    printApiHelp(true);
                    std.process.exit(255);
                }
                std.debug.print("Request build error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
        .archive => {
            archive_cfg = buildArchiveRequest(gpa, &args) catch |err| {
                if (err == error.MissingArchiveArgs) {
                    printArchiveHelp(true);
                    std.process.exit(255);
                }
                std.debug.print("Archive request build error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
        .monitor => {
            monitor_cfg = buildMonitorRequest(gpa, &args) catch |err| {
                if (err == error.MissingMonitorArgs or err == error.InvalidJobId) {
                    printMonitorHelp(true);
                    std.process.exit(255);
                }
                std.debug.print("Monitor request build error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
        .schedule => {
            schedule_cfg = buildScheduleRequest(gpa, &args) catch |err| {
                if (err == error.MissingScheduleArgs) {
                    printScheduleHelp(true);
                    std.process.exit(255);
                }
                std.debug.print("Schedule request build error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
    }

    // Resolve credentials
    // Extract hostname from the resolved host URL for config file lookup.
    // Note: a `switch (subcmd)` with `.?` unwraps would also work here since
    // each config is guaranteed non-null by the dispatch above, but the orelse
    // fallback below provides an extra safety net for future subcommands.
    const host_for_uri = blk: {
        if (req_cfg) |cfg| break :blk cfg.host;
        if (archive_cfg) |cfg| break :blk cfg.host;
        if (monitor_cfg) |cfg| break :blk cfg.host;
        if (schedule_cfg) |cfg| break :blk cfg.host;
        break :blk args.host orelse "localhost";
    };
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

    switch (subcmd) {
        .api => {
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
                .verbose = args.verbose,
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
        },
        .archive => {
            var cfg = &archive_cfg.?;
            cfg.options.credentials = creds;
            cfg.options.quiet = args.quiet;
            cfg.options.retries = retries;
            cfg.options.retry_sleep_s = retry_sleep_s;
            cfg.options.retry_factor = retry_factor;

            var client = std.http.Client{ .allocator = gpa };
            defer client.deinit();

            zoqa.runArchive(gpa, &client, cfg.host, cfg.job_id, cfg.output_path, cfg.options) catch |err| {
                std.debug.print("archive: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            std.process.exit(0);
        },
        .monitor => {
            const cfg = &monitor_cfg.?;
            var client = std.http.Client{ .allocator = gpa };
            defer client.deinit();

            const exit_code = zoqa.runMonitor(gpa, &client, cfg.host, cfg.job_ids, .{
                .credentials = creds,
                .quiet = args.quiet,
                .retries = retries,
                .connect_timeout_s = connect_timeout_s,
                .retry_sleep_s = retry_sleep_s,
                .retry_factor = retry_factor,
                .follow = cfg.follow,
                .poll_interval = cfg.poll_interval,
            }) catch |err| {
                if (!args.quiet) std.debug.print("Monitor error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            std.process.exit(exit_code);
        },
        .schedule => {
            const cfg = &schedule_cfg.?;
            var client = std.http.Client{ .allocator = gpa };
            defer client.deinit();

            const exit_code = zoqa.runSchedule(gpa, &client, cfg.host, cfg.params_encoded, .{
                .credentials = creds,
                .quiet = args.quiet,
                .retries = retries,
                .connect_timeout_s = connect_timeout_s,
                .retry_sleep_s = retry_sleep_s,
                .retry_factor = retry_factor,
                .monitor_jobs = cfg.monitor_jobs,
                .follow = cfg.follow,
                .poll_interval = cfg.poll_interval,
                .name = cfg.name,
            }) catch |err| {
                if (!args.quiet) std.debug.print("Schedule error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            std.process.exit(exit_code);
        },
    }
}

// ---------------------------------------------------------------------------
// Help text
// ---------------------------------------------------------------------------

const help_global_options =
    \\Options (for all commands):
    \\    --host STR         Base URL of the OpenQA instance
    \\    --osd              Alias for --host http://openqa.suse.de
    \\    --o3               Alias for --host https://openqa.opensuse.org
    \\    --odn              Alias for --host https://openqa.debian.net
    \\    --apikey STR       Override API public key
    \\    --apisecret STR    Override API secret
    \\    --name STR         User-Agent name (default: openQAclient)
    \\    --verbose (or -v)  Print HTTP response status line and headers to stdout
    \\    --quiet (or -q)    Suppress non-fatal error messages on stderr
    \\    --links (or -L)    Parse Link response header and print rel: url pairs to stderr
    \\    --pretty (or -p)   Pretty-print JSON response body
    \\    --help (or -h)     Display this help and exit
    \\
;

const help_api_options =
    \\Options for api:
    \\    --method STR (or -X)     HTTP method (default: GET)
    \\    --data STR (or -d)       Raw request body
    \\    --data-file STR (or -D)  Read body from file (- = stdin)
    \\    --form (or -f)           Treat data as JSON object, re-encode as form urlencoded
    \\    --json (or -j)           Set Content-Type: application/json
    \\    --header STR... (or -a)  Extra request header (repeatable)
    \\    --param-file STR...      Append file contents as param (repeatable)
    \\    --retries INT (or -r)    Retry count on 502/503/connection error (default: 0)
    \\
;

const help_archive_options =
    \\Options for archive:
    \\    --with-thumbnails (or -t)       Download thumbnails for screenshots
    \\    --asset-size-limit INT (or -l)  Skip downloading assets larger than this limit (default 200MiB)
    \\
;

const help_monitor_options =
    \\Options for monitor:
    \\    --follow (or -f)         Track the newest clone of each job
    \\    --poll-interval INT (or -i) Polling interval in seconds (default: 10)
    \\
;

const help_schedule_options =
    \\Options for schedule:
    \\    --monitor (or -m)        After scheduling, wait for all resulting jobs to finish
    \\    --follow (or -f)         Track the newest clone of each job (modifier for --monitor)
    \\    --poll-interval INT (or -i) Polling interval in seconds (default: 1)
    \\    --param-file STR...      Read parameter value from file contents (repeatable)
    \\
;

/// Print the top-level zoqa usage block.
///
/// Arguments:
///   - `is_error`: When true, write to stderr; otherwise stdout.
fn printHelp(is_error: bool) void {
    var buf: [4096]u8 = undefined;
    var out_writer = if (is_error) std.fs.File.stderr().writer(&buf) else std.fs.File.stdout().writer(&buf);
    const w = &out_writer.interface;
    w.print(
        "{s}\n" ++
            " api       Make an openQA API request\n" ++
            " archive   Download assets and test results from a job\n" ++
            " monitor   Wait until all specified jobs reach a final state\n" ++
            " schedule  Schedule openQA test jobs via POST /api/v1/isos\n\n" ++
            "See 'zoqa COMMAND --help' for more information on a specific command.\n",
        .{help_global_options},
    ) catch {};
    w.flush() catch {};
}

/// Print the `api` subcommand usage block.
/// Called when PATH is missing (exit 255, per Perl reference behavior).
///
/// Arguments:
///   - `is_error`: When true, write to stderr; otherwise stdout.
fn printApiHelp(is_error: bool) void {
    var buf: [4096]u8 = undefined;
    var out_writer = if (is_error) std.fs.File.stderr().writer(&buf) else std.fs.File.stdout().writer(&buf);
    const w = &out_writer.interface;
    w.print(
        "Usage: zoqa api [OPTIONS] PATH [PARAMS]\n\n" ++
            "{s}" ++
            "{s}",
        .{ help_global_options, help_api_options },
    ) catch {};
    w.flush() catch {};
}

/// Print the `archive` subcommand usage block.
///
/// Arguments:
///   - `is_error`: When true, write to stderr; otherwise stdout.
fn printArchiveHelp(is_error: bool) void {
    var buf: [4096]u8 = undefined;
    var out_writer = if (is_error) std.fs.File.stderr().writer(&buf) else std.fs.File.stdout().writer(&buf);
    const w = &out_writer.interface;
    w.print(
        "Usage: zoqa archive [OPTIONS] JOB PATH\n\n" ++
            "{s}" ++
            "{s}",
        .{ help_global_options, help_archive_options },
    ) catch {};
    w.flush() catch {};
}

/// Print the `monitor` subcommand usage block.
///
/// Arguments:
///   - `is_error`: When true, write to stderr; otherwise stdout.
fn printMonitorHelp(is_error: bool) void {
    var buf: [4096]u8 = undefined;
    var out_writer = if (is_error) std.fs.File.stderr().writer(&buf) else std.fs.File.stdout().writer(&buf);
    const w = &out_writer.interface;
    w.print(
        "Usage: zoqa monitor [OPTIONS] JOB_ID [JOB_ID ...]\n\n" ++
            "{s}" ++
            "{s}",
        .{ help_global_options, help_monitor_options },
    ) catch {};
    w.flush() catch {};
}

/// Print the `schedule` subcommand usage block.
///
/// Arguments:
///   - `is_error`: When true, write to stderr; otherwise stdout.
fn printScheduleHelp(is_error: bool) void {
    var buf: [4096]u8 = undefined;
    var out_writer = if (is_error) std.fs.File.stderr().writer(&buf) else std.fs.File.stdout().writer(&buf);
    const w = &out_writer.interface;
    w.print(
        "Usage: zoqa schedule [OPTIONS] KEY=VALUE [KEY=VALUE ...]\n\n" ++
            "{s}" ++
            "{s}",
        .{ help_global_options, help_schedule_options },
    ) catch {};
    w.flush() catch {};
}
