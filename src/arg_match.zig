const std = @import("std");

// ---------------------------------------------------------------------------
// Low-level matching primitives
// ---------------------------------------------------------------------------

/// Returns `true` when `token` matches either `long` (e.g. `"--verbose"`) or,
/// if provided, `short` (e.g. `"-v"`). Pass `null` for `short` when no alias exists.
pub fn matchBool(token: []const u8, long: []const u8, short: ?[]const u8) bool {
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
pub fn matchValue(
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
// Common flag dispatch (comptime duck-typed)
// ---------------------------------------------------------------------------

/// Try to match `token` against the five common flags shared by all openQA CLI
/// tools: `--host`, `--apikey`, `--apisecret`, `--verbose/-v`, `--help/-h`.
///
/// The args struct `T` must expose fields named `host`, `apikey`, `apisecret`
/// (all `?[]const u8`), and `verbose`, `help` (both `bool`). A missing or
/// mistyped field produces a compile error.
///
/// Returns `true` when a common flag was consumed, `false` if unmatched.
/// The caller is responsible for any post-parse semantics (e.g. early return
/// on `--help`).
pub fn tryCommonFlag(
    comptime T: type,
    args: *T,
    token: []const u8,
    i: *usize,
    argv: []const []const u8,
) !bool {
    if (matchBool(token, "--help", "-h")) {
        args.help = true;
        return true;
    }
    if (matchBool(token, "--verbose", "-v")) {
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

test "matchBool: long form" {
    try std.testing.expect(matchBool("--verbose", "--verbose", "-v"));
}

test "matchBool: short form" {
    try std.testing.expect(matchBool("-v", "--verbose", "-v"));
}

test "matchBool: no match" {
    try std.testing.expect(!matchBool("--quiet", "--verbose", "-v"));
}

test "matchBool: null short — long matches" {
    try std.testing.expect(matchBool("--osd", "--osd", null));
}

test "matchBool: null short — no match" {
    try std.testing.expect(!matchBool("-o", "--osd", null));
}

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
