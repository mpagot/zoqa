const std = @import("std");

/// Returns `true` when `token` matches `long` or `short`.
///
/// Both `long` and `short` are comptime-known and optional; use `null` to
/// indicate absence.  At least one must be non-null and non-empty — violations
/// are caught at compile time via `@compileError`.
///
/// `long` and `short` are intentionally `comptime`: this function is designed
/// exclusively for fixed CLI flag matching.  Dynamically-constructed flag names
/// are not supported and never will be.
///
/// Arguments:
///   - `token`: The argv token to test (runtime).
///   - `long`: Long-form flag name, e.g. `"--verbose"`, or `null` (comptime).
///   - `short`: Short-form alias, e.g. `"-v"`, or `null` (comptime).
///
/// Returns: `true` when `token` equals `long` or `short`, `false` otherwise.
///
/// Errors:
///   - `error.EmptyToken` — `token` is an empty slice.
pub fn matchBool(
    token: []const u8,
    comptime long: ?[]const u8,
    comptime short: ?[]const u8,
) error{EmptyToken}!bool {
    comptime {
        if (long == null and short == null)
            @compileError("matchBool: at least one of `long` or `short` must be non-null");
        if (long) |l| if (l.len == 0)
            @compileError("matchBool: `long` must not be an empty string");
        if (short) |s| if (s.len == 0)
            @compileError("matchBool: `short` must not be an empty string");
    }
    if (token.len == 0) return error.EmptyToken;
    if (long) |l| if (std.mem.eql(u8, token, l)) return true;
    if (short) |s| if (std.mem.eql(u8, token, s)) return true;
    return false;
}

test "matchBool: long form" {
    try std.testing.expect(try matchBool("--verbose", "--verbose", "-v"));
}

test "matchBool: short form" {
    try std.testing.expect(try matchBool("-v", "--verbose", "-v"));
}

test "matchBool: no match" {
    try std.testing.expect(!try matchBool("--quiet", "--verbose", "-v"));
}

test "matchBool: null short — long matches" {
    try std.testing.expect(try matchBool("--osd", "--osd", null));
}

test "matchBool: null short — no match" {
    try std.testing.expect(!try matchBool("-o", "--osd", null));
}

test "matchBool: null long — short matches" {
    try std.testing.expect(try matchBool("-v", null, "-v"));
}

test "matchBool: null long — no match" {
    try std.testing.expect(!try matchBool("--verbose", null, "-v"));
}

test "matchBool: null short — empty token returns EmptyToken" {
    try std.testing.expectError(error.EmptyToken, matchBool("", "--osd", null));
}

/// Returns the value for a flag that takes an argument, handling both the space
/// form (`--flag VALUE`) and the equals form (`--flag=VALUE`).
///
/// `long` and `short` are comptime-known; `long` must be non-empty, `short`
/// (when non-null) must be non-empty — violations produce a compile error.
///
/// These parameters are intentionally `comptime`: this function is designed
/// exclusively for fixed CLI flag matching.  Dynamically-constructed flag names
/// are not supported and never will be.
///
/// Arguments:
///   - `token`: The current argv token being tested (runtime).
///   - `i`: Current argv index cursor; advanced by 1 when the space form matches.
///   - `argv`: The full argv slice, used to fetch the next token for the space form.
///   - `long`: Long-form flag name, e.g. `"--method"` (comptime).
///   - `short`: Short-form alias, e.g. `"-X"`, or `null` (comptime).
///
/// Returns: The flag's value string on a match, or `null` when `token` does not
/// match the long form, short form, or equals form (`--flag=VALUE`).
///
/// Errors:
///   - `error.MissingValue` — space form was matched but no next token exists.
pub fn matchValue(
    token: []const u8,
    i: *usize,
    argv: []const []const u8,
    comptime long: []const u8,
    comptime short: ?[]const u8,
) error{MissingValue}!?[]const u8 {
    comptime {
        if (long.len == 0)
            @compileError("matchValue: `long` must not be an empty string");
        if (short) |s| if (s.len == 0)
            @compileError("matchValue: `short` must not be an empty string");
    }
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

/// Try to match `token` against the five common flags shared by all openQA CLI
/// tools: `--host`, `--apikey`, `--apisecret`, `--verbose/-v`, `--help/-h`.
///
/// The args struct `T` must expose fields named `host`, `apikey`, `apisecret`
/// (all `?[]const u8`), and `verbose`, `help` (both `bool`). A missing or
/// mistyped field produces a compile error.
///
/// Arguments:
///   - `T`: The args struct type; required fields are verified at compile time.
///   - `args`: Pointer to the args struct being populated.
///   - `token`: The current argv token being tested.
///   - `i`: Current argv index cursor; forwarded to `matchValue` for value flags.
///   - `argv`: The full argv slice; forwarded to `matchValue` for value flags.
///
/// Returns: `true` when a common flag was consumed, `false` if unmatched.
/// The caller is responsible for any post-parse semantics (e.g. early return
/// on `--help`).
///
/// Errors:
///   - `error.MissingValue` — a value-taking flag (`--host`, `--apikey`,
///     `--apisecret`) was matched but no following token exists.
pub fn tryCommonFlag(
    comptime T: type,
    args: *T,
    token: []const u8,
    i: *usize,
    argv: []const []const u8,
) !bool {
    if (try matchBool(token, "--help", "-h")) {
        args.help = true;
        return true;
    }
    if (try matchBool(token, "--verbose", "-v")) {
        args.verbose = true;
        return true;
    }
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
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "matchValue: space form (long)" {
    const argv: []const []const u8 = &.{ "--host", "example.com", "--other" };
    var i: usize = 0;
    const val = try matchValue(argv[i], &i, argv, "--host", null);
    try std.testing.expectEqualStrings("example.com", val.?);
    try std.testing.expectEqual(@as(usize, 1), i);
}

test "matchValue: space form (short)" {
    const argv: []const []const u8 = &.{ "-X", "POST", "--other" };
    var i: usize = 0;
    const val = try matchValue(argv[i], &i, argv, "--method", "-X");
    try std.testing.expectEqualStrings("POST", val.?);
    try std.testing.expectEqual(@as(usize, 1), i);
}

test "matchValue: equals form" {
    const argv: []const []const u8 = &.{"--host=example.com"};
    var i: usize = 0;
    const val = try matchValue(argv[i], &i, argv, "--host", null);
    try std.testing.expectEqualStrings("example.com", val.?);
    // i is NOT advanced for equals form
    try std.testing.expectEqual(@as(usize, 0), i);
}

test "matchValue: missing value error" {
    const argv: []const []const u8 = &.{"--host"};
    var i: usize = 0;
    const result = matchValue(argv[i], &i, argv, "--host", null);
    try std.testing.expectError(error.MissingValue, result);
}

test "matchValue: no match returns null" {
    const argv: []const []const u8 = &.{ "--other", "value" };
    var i: usize = 0;
    const val = try matchValue(argv[i], &i, argv, "--host", null);
    try std.testing.expect(val == null);
    try std.testing.expectEqual(@as(usize, 0), i);
}

test "matchValue: equals form requires value after =" {
    const argv: []const []const u8 = &.{"--host="};
    var i: usize = 0;
    // "--host=" is exactly long.len + 1 chars, so token.len > long.len + 1 is false
    const val = try matchValue(argv[i], &i, argv, "--host", null);
    try std.testing.expect(val == null);
}

test "tryCommonFlag: fixture struct — all five flags" {
    const TestArgs = struct {
        host: ?[]const u8 = null,
        apikey: ?[]const u8 = null,
        apisecret: ?[]const u8 = null,
        verbose: bool = false,
        help: bool = false,
        // Extra field to prove duck-typing doesn't require exact struct match
        extra: bool = false,
    };

    var args = TestArgs{};

    // --help
    {
        const argv: []const []const u8 = &.{"-h"};
        var i: usize = 0;
        const consumed = try tryCommonFlag(TestArgs, &args, argv[0], &i, argv);
        try std.testing.expect(consumed);
        try std.testing.expect(args.help);
    }

    // --verbose
    {
        const argv: []const []const u8 = &.{"--verbose"};
        var i: usize = 0;
        const consumed = try tryCommonFlag(TestArgs, &args, argv[0], &i, argv);
        try std.testing.expect(consumed);
        try std.testing.expect(args.verbose);
    }

    // --host (space form)
    {
        const argv: []const []const u8 = &.{ "--host", "myhost.com" };
        var i: usize = 0;
        const consumed = try tryCommonFlag(TestArgs, &args, argv[0], &i, argv);
        try std.testing.expect(consumed);
        try std.testing.expectEqualStrings("myhost.com", args.host.?);
    }

    // --apikey (equals form)
    {
        const argv: []const []const u8 = &.{"--apikey=SECRET123"};
        var i: usize = 0;
        const consumed = try tryCommonFlag(TestArgs, &args, argv[0], &i, argv);
        try std.testing.expect(consumed);
        try std.testing.expectEqualStrings("SECRET123", args.apikey.?);
    }

    // --apisecret
    {
        const argv: []const []const u8 = &.{ "--apisecret", "s3cr3t" };
        var i: usize = 0;
        const consumed = try tryCommonFlag(TestArgs, &args, argv[0], &i, argv);
        try std.testing.expect(consumed);
        try std.testing.expectEqualStrings("s3cr3t", args.apisecret.?);
    }
}

test "tryCommonFlag: unrecognised flag returns false" {
    const TestArgs = struct {
        host: ?[]const u8 = null,
        apikey: ?[]const u8 = null,
        apisecret: ?[]const u8 = null,
        verbose: bool = false,
        help: bool = false,
    };

    var args = TestArgs{};
    const argv: []const []const u8 = &.{ "--unknown", "value" };
    var i: usize = 0;
    const consumed = try tryCommonFlag(TestArgs, &args, argv[0], &i, argv);
    try std.testing.expect(!consumed);
    try std.testing.expectEqual(@as(usize, 0), i);
}
