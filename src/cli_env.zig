/// Shared CLI runtime-input resolution (credentials + retry/timeout knobs).
///
/// This module lives in the executable layer — it uses `std.process` and is
/// imported by CLI tools, NOT by the zoqa library. It centralises all OS
/// environment variable access into the `OsEnv` struct, which executables
/// populate once at startup and then dispatch value-by-value to library
/// functions. Keeping this here is what lets the zoqa library stay free of
/// `std.process`.
const std = @import("std");
const zoqa = @import("zoqa");
const config = zoqa.config;

// ---------------------------------------------------------------------------
// OsEnv — all process-level environment variables consumed by openQA tools
// ---------------------------------------------------------------------------

/// All process-level environment variables consumed by openQA CLI tools.
///
/// Created by executables, filled by `resolve()`, then dispatched
/// value-by-value to library functions. The library layer never sees this type.
///
/// All non-null string fields are owned allocations; call `deinit()` to free.
pub const OsEnv = struct {
    // Config / credential resolution
    openqa_config: ?[]const u8 = null, // $OPENQA_CONFIG
    home: ?[]const u8 = null, // $HOME (POSIX) or $USERPROFILE (Windows)
    openqa_api_key: ?[]const u8 = null, // $OPENQA_API_KEY
    openqa_api_secret: ?[]const u8 = null, // $OPENQA_API_SECRET

    // Retry / timeout knobs (raw strings — parsed by resolveRetryConfig)
    openqa_cli_retries: ?[]const u8 = null, // $OPENQA_CLI_RETRIES
    openqa_cli_connect_timeout: ?[]const u8 = null, // $OPENQA_CLI_CONNECT_TIMEOUT
    openqa_cli_retry_sleep_time_s: ?[]const u8 = null, // $OPENQA_CLI_RETRY_SLEEP_TIME_S
    openqa_cli_retry_factor: ?[]const u8 = null, // $OPENQA_CLI_RETRY_FACTOR

    // Clone-job specific
    openqa_sharedir: ?[]const u8 = null, // $OPENQA_SHAREDIR

    /// Free all owned allocations. Safe to call on a default-initialised instance.
    pub fn deinit(self: *OsEnv, allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(OsEnv)) |f| {
            if (@field(self, f.name)) |s| allocator.free(s);
        }
        self.* = .{};
    }
};

/// Read all openQA-relevant environment variables from the OS process environment.
///
/// Populates `env` with owned string copies for each variable that is set,
/// and `null` for each that is absent. Any existing values in `env` are
/// replaced unconditionally.
///
/// Arguments:
///   - `allocator`: Used to allocate owned copies of each env var value.
///   - `env`: Output struct to populate. Call `env.deinit(allocator)` when done.
///
/// Errors:
///   - `OutOfMemory` — allocator failure.
///   - Any OS error from `std.process.getEnvVarOwned` other than
///     `EnvironmentVariableNotFound`.
pub fn resolve(allocator: std.mem.Allocator, env: *OsEnv) !void {
    env.* = .{};
    errdefer env.deinit(allocator);

    env.openqa_config = try readEnv(allocator, "OPENQA_CONFIG");
    // HOME (POSIX) with USERPROFILE (Windows) as fallback — single merged field.
    env.home = (try readEnv(allocator, "HOME")) orelse
        (try readEnv(allocator, "USERPROFILE"));
    env.openqa_api_key = try readEnv(allocator, "OPENQA_API_KEY");
    env.openqa_api_secret = try readEnv(allocator, "OPENQA_API_SECRET");
    env.openqa_cli_retries = try readEnv(allocator, "OPENQA_CLI_RETRIES");
    env.openqa_cli_connect_timeout = try readEnv(allocator, "OPENQA_CLI_CONNECT_TIMEOUT");
    env.openqa_cli_retry_sleep_time_s = try readEnv(allocator, "OPENQA_CLI_RETRY_SLEEP_TIME_S");
    env.openqa_cli_retry_factor = try readEnv(allocator, "OPENQA_CLI_RETRY_FACTOR");
    env.openqa_sharedir = try readEnv(allocator, "OPENQA_SHAREDIR");
}

/// Read a single environment variable by name.
///
/// Returns an owned copy of the value, or `null` if the variable is not set.
/// Propagates any OS error other than `EnvironmentVariableNotFound`.
fn readEnv(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// RetryConfig
// ---------------------------------------------------------------------------

/// Retry and timeout knobs resolved from environment variables.
/// Passed into `CallOptions` / HTTP client configuration so that
/// lower-level modules stay free of `std.process` dependencies.
pub const RetryConfig = struct {
    retries: u32,
    connect_timeout_s: f64,
    retry_sleep_s: f64,
    retry_factor: f64,
};

// ---------------------------------------------------------------------------
// resolveCredentials
// ---------------------------------------------------------------------------

/// Resolve credentials for a given host URL.
///
/// Follows the priority chain: CLI flags > `OPENQA_API_KEY`/`OPENQA_API_SECRET`
/// environment variables > `~/.config/openqa/client.conf` config file.
///
/// Arguments:
///   - `allocator`: General-purpose allocator for config file I/O and result duplication.
///   - `host_url`: The resolved base URL of the target host (used to extract hostname for config lookup).
///   - `cli_key`: API key from CLI `--apikey` flag, or `null`.
///   - `cli_secret`: API secret from CLI `--apisecret` flag, or `null`.
///   - `env_key`: API key from `$OPENQA_API_KEY` (`OsEnv.openqa_api_key`), or `null`.
///   - `env_secret`: API secret from `$OPENQA_API_SECRET` (`OsEnv.openqa_api_secret`), or `null`.
///   - `openqa_config_dir`: Value of `$OPENQA_CONFIG` (`OsEnv.openqa_config`), or `null`.
///   - `home_dir`: Value of `$HOME`/`$USERPROFILE` (`OsEnv.home`), or `null`.
///
/// Returns: Owned `Credentials` with freshly-allocated key and secret (caller
///   must call `.deinit()`), or `null` when both are absent across all sources.
///
/// Errors:
///   - `OutOfMemory` — allocator failure.
///   - Any OS error from `config.findCredentials`.
pub fn resolveCredentials(
    allocator: std.mem.Allocator,
    host_url: []const u8,
    cli_key: ?[]const u8,
    cli_secret: ?[]const u8,
    env_key: ?[]const u8,
    env_secret: ?[]const u8,
    openqa_config_dir: ?[]const u8,
    home_dir: ?[]const u8,
) !?config.Credentials {
    const hostname = hostnameFromUrl(host_url);

    const conf_creds = try config.findCredentials(allocator, hostname, openqa_config_dir, home_dir);
    defer if (conf_creds) |c| c.deinit();

    return try config.mergeCredentials(
        allocator,
        .{ .key = cli_key, .secret = cli_secret },
        .{ .key = env_key, .secret = env_secret },
        conf_creds,
    );
}

// ---------------------------------------------------------------------------
// resolveRetryConfig
// ---------------------------------------------------------------------------

/// Resolve retry/timeout configuration from pre-read environment variable strings.
///
/// Priority: `cli_retries` (from --retries flag) > `env_retries` string >
/// `default_retries`. Timeout and backoff knobs are env-only (no CLI flags).
///
/// Arguments:
///   - `cli_retries`: Retry count from CLI `--retries`/`--retry` flag, or `null`.
///   - `default_retries`: Value used when neither CLI flag nor env var is set.
///     Most tools pass `0`; `clone-job` passes `5` to match the Perl reference's
///     default. A user-set env var still overrides it.
///   - `env_retries`: Raw `$OPENQA_CLI_RETRIES` value (`OsEnv.openqa_cli_retries`), or `null`.
///   - `env_connect_timeout`: Raw `$OPENQA_CLI_CONNECT_TIMEOUT` value, or `null`.
///   - `env_retry_sleep`: Raw `$OPENQA_CLI_RETRY_SLEEP_TIME_S` value, or `null`.
///   - `env_retry_factor`: Raw `$OPENQA_CLI_RETRY_FACTOR` value, or `null`.
///
/// Returns: A `RetryConfig` struct with all four knobs resolved.
///
/// Errors:
///   - `error.InvalidConnectTimeout` — `env_connect_timeout` is set but not a valid number.
pub fn resolveRetryConfig(
    cli_retries: ?u32,
    default_retries: u32,
    env_retries: ?[]const u8,
    env_connect_timeout: ?[]const u8,
    env_retry_sleep: ?[]const u8,
    env_retry_factor: ?[]const u8,
) !RetryConfig {
    const retries: u32 = cli_retries orelse blk: {
        if (env_retries) |s| break :blk std.fmt.parseInt(u32, s, 10) catch default_retries;
        break :blk default_retries;
    };

    const connect_timeout_s: f64 = blk: {
        if (env_connect_timeout) |s| {
            break :blk std.fmt.parseFloat(f64, s) catch {
                std.debug.print("error: OPENQA_CLI_CONNECT_TIMEOUT={s}: not a valid number\n", .{s});
                return error.InvalidConnectTimeout;
            };
        }
        break :blk 30.0;
    };

    const retry_sleep_s: f64 = if (env_retry_sleep) |s|
        std.fmt.parseFloat(f64, s) catch 3.0
    else
        3.0;

    const retry_factor: f64 = if (env_retry_factor) |s|
        std.fmt.parseFloat(f64, s) catch 1.0
    else
        1.0;

    return .{
        .retries = retries,
        .connect_timeout_s = connect_timeout_s,
        .retry_sleep_s = retry_sleep_s,
        .retry_factor = retry_factor,
    };
}

// ---------------------------------------------------------------------------
// Tests — OsEnv
// ---------------------------------------------------------------------------

test "OsEnv: zero-init deinit does not crash" {
    var env: OsEnv = .{};
    env.deinit(std.testing.allocator);
}

test "OsEnv: deinit frees all populated fields without leaking" {
    const allocator = std.testing.allocator;
    var env: OsEnv = .{};
    // Populate every field so the testing allocator can verify each is freed.
    env.openqa_config = try allocator.dupe(u8, "/etc/openqa");
    env.home = try allocator.dupe(u8, "/home/user");
    env.openqa_api_key = try allocator.dupe(u8, "key123");
    env.openqa_api_secret = try allocator.dupe(u8, "secret456");
    env.openqa_cli_retries = try allocator.dupe(u8, "3");
    env.openqa_cli_connect_timeout = try allocator.dupe(u8, "60");
    env.openqa_cli_retry_sleep_time_s = try allocator.dupe(u8, "1.5");
    env.openqa_cli_retry_factor = try allocator.dupe(u8, "2.0");
    env.openqa_sharedir = try allocator.dupe(u8, "/var/lib/openqa/share");
    env.deinit(allocator);
    // std.testing.allocator detects any leak at test teardown.
}

test "OsEnv: deinit resets all fields to null" {
    const allocator = std.testing.allocator;
    var env: OsEnv = .{};
    env.openqa_sharedir = try allocator.dupe(u8, "/share");
    env.deinit(allocator);
    try std.testing.expect(env.openqa_sharedir == null);
    try std.testing.expect(env.openqa_config == null);
    try std.testing.expect(env.home == null);
}

// ---------------------------------------------------------------------------
// Tests — resolveCredentials
// ---------------------------------------------------------------------------

test "resolveCredentials: all null returns null" {
    // Hostname won't match any real config file — ensures config-file lookup
    // also returns null so the overall result is null.
    const creds = try resolveCredentials(
        std.testing.allocator,
        "http://no.such.host.for.testing.invalid",
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expect(creds == null);
}

test "resolveCredentials: env key+secret returned when cli absent" {
    const creds = try resolveCredentials(
        std.testing.allocator,
        "http://no.such.host.for.testing.invalid",
        null,
        null,
        "envkey",
        "envsecret",
        null,
        null,
    );
    defer if (creds) |c| c.deinit();
    try std.testing.expect(creds != null);
    try std.testing.expectEqualStrings("envkey", creds.?.key);
    try std.testing.expectEqualStrings("envsecret", creds.?.secret);
}

test "resolveCredentials: cli key+secret takes priority over env" {
    const creds = try resolveCredentials(
        std.testing.allocator,
        "http://no.such.host.for.testing.invalid",
        "clikey",
        "clisecret",
        "envkey",
        "envsecret",
        null,
        null,
    );
    defer if (creds) |c| c.deinit();
    try std.testing.expect(creds != null);
    try std.testing.expectEqualStrings("clikey", creds.?.key);
    try std.testing.expectEqualStrings("clisecret", creds.?.secret);
}

test "resolveCredentials: cli key mixed with env secret" {
    // Each field resolved independently: key from CLI, secret from env.
    const creds = try resolveCredentials(
        std.testing.allocator,
        "http://no.such.host.for.testing.invalid",
        "clikey",
        null,
        null,
        "envsecret",
        null,
        null,
    );
    defer if (creds) |c| c.deinit();
    try std.testing.expect(creds != null);
    try std.testing.expectEqualStrings("clikey", creds.?.key);
    try std.testing.expectEqualStrings("envsecret", creds.?.secret);
}

test "resolveCredentials: key without secret returns null" {
    const creds = try resolveCredentials(
        std.testing.allocator,
        "http://no.such.host.for.testing.invalid",
        null,
        null,
        "envkey",
        null,
        null,
        null,
    );
    try std.testing.expect(creds == null);
}

test "resolveCredentials: secret without key returns null" {
    const creds = try resolveCredentials(
        std.testing.allocator,
        "http://no.such.host.for.testing.invalid",
        null,
        null,
        null,
        "envsecret",
        null,
        null,
    );
    try std.testing.expect(creds == null);
}

// ---------------------------------------------------------------------------
// Tests — resolveRetryConfig
// ---------------------------------------------------------------------------

test "resolveRetryConfig defaults when no env vars set" {
    const cfg = try resolveRetryConfig(null, 0, null, null, null, null);
    try std.testing.expectEqual(@as(u32, 0), cfg.retries);
    try std.testing.expectEqual(@as(f64, 30.0), cfg.connect_timeout_s);
    try std.testing.expectEqual(@as(f64, 3.0), cfg.retry_sleep_s);
    try std.testing.expectEqual(@as(f64, 1.0), cfg.retry_factor);
}

test "resolveRetryConfig cli_retries takes priority" {
    const cfg = try resolveRetryConfig(5, 0, null, null, null, null);
    try std.testing.expectEqual(@as(u32, 5), cfg.retries);
}

test "resolveRetryConfig falls back to default_retries when no CLI/env" {
    // clone-job passes default_retries = 5; with no --retry flag and no
    // OPENQA_CLI_RETRIES env var set, the default must win.
    const cfg = try resolveRetryConfig(null, 5, null, null, null, null);
    try std.testing.expectEqual(@as(u32, 5), cfg.retries);
}

test "resolveRetryConfig env_retries parsed correctly" {
    const cfg = try resolveRetryConfig(null, 0, "3", null, null, null);
    try std.testing.expectEqual(@as(u32, 3), cfg.retries);
}

test "resolveRetryConfig cli_retries beats env_retries" {
    const cfg = try resolveRetryConfig(7, 0, "3", null, null, null);
    try std.testing.expectEqual(@as(u32, 7), cfg.retries);
}

test "resolveRetryConfig invalid env_retries falls back to default" {
    const cfg = try resolveRetryConfig(null, 2, "bad", null, null, null);
    try std.testing.expectEqual(@as(u32, 2), cfg.retries);
}

test "resolveRetryConfig invalid env_connect_timeout returns error" {
    try std.testing.expectError(
        error.InvalidConnectTimeout,
        resolveRetryConfig(null, 0, null, "bad", null, null),
    );
}

test "resolveRetryConfig env_retry_sleep parsed correctly" {
    const cfg = try resolveRetryConfig(null, 0, null, null, "5.0", null);
    try std.testing.expectEqual(@as(f64, 5.0), cfg.retry_sleep_s);
}

test "resolveRetryConfig invalid env_retry_sleep falls back to default" {
    const cfg = try resolveRetryConfig(null, 0, null, null, "bad", null);
    try std.testing.expectEqual(@as(f64, 3.0), cfg.retry_sleep_s);
}

test "resolveRetryConfig env_retry_factor parsed correctly" {
    const cfg = try resolveRetryConfig(null, 0, null, null, null, "2.0");
    try std.testing.expectEqual(@as(f64, 2.0), cfg.retry_factor);
}

test "resolveRetryConfig invalid env_retry_factor falls back to default" {
    const cfg = try resolveRetryConfig(null, 0, null, null, null, "bad");
    try std.testing.expectEqual(@as(f64, 1.0), cfg.retry_factor);
}

// ---------------------------------------------------------------------------
// Hostname extraction (private helper)
// ---------------------------------------------------------------------------

/// Extract the hostname from a URL string for credential lookup.
///
/// Uses `std.Uri.parse` to extract the host component. Returns a slice
/// into `url` (no allocation). Falls back to returning the full `url`
/// string when parsing fails or no host is present.
fn hostnameFromUrl(url: []const u8) []const u8 {
    const uri = std.Uri.parse(url) catch return url;
    return if (uri.host) |h| h.percent_encoded else url;
}

test "hostnameFromUrl: extracts host from full URL" {
    try std.testing.expectEqualStrings(
        "openqa.opensuse.org",
        hostnameFromUrl("https://openqa.opensuse.org/api/v1/jobs"),
    );
}

test "hostnameFromUrl: extracts host from URL with port" {
    try std.testing.expectEqualStrings(
        "localhost",
        hostnameFromUrl("http://localhost:9526/tests/42"),
    );
}

test "hostnameFromUrl: returns full string on parse failure" {
    try std.testing.expectEqualStrings(
        "not a url at all",
        hostnameFromUrl("not a url at all"),
    );
}

test "hostnameFromUrl: scheme-only URL with no host returns input" {
    // Edge case: "file:///" has no host authority
    const result = hostnameFromUrl("file:///etc/passwd");
    // std.Uri may or may not parse host as empty — verify no crash
    _ = result;
}
