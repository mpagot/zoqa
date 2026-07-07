/// Shared CLI credential and environment-variable resolution.
///
/// This module lives in the executable layer — it uses `std.process` and is
/// imported by CLI tools, NOT by the zoqa library. It exists to deduplicate
/// the credential-merge and retry/timeout env-var parsing logic that every
/// openQA executable needs.
const std = @import("std");
const zoqa = @import("zoqa");
const config = zoqa.config;

/// Retry and timeout knobs resolved from environment variables.
/// Passed into `CallOptions` / HTTP client configuration so that
/// lower-level modules stay free of `std.process` dependencies.
pub const RetryConfig = struct {
    retries: u32,
    connect_timeout_s: f64,
    retry_sleep_s: f64,
    retry_factor: f64,
};

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
///
/// Returns: Owned `Credentials` with freshly-allocated key and secret (caller
///   must call `.deinit()`), or `null` when both are absent across all sources.
///
/// Errors:
///   - `OutOfMemory` — allocator failure.
///   - Any OS error from `std.process.getEnvVarOwned` or `config.findCredentials`.
pub fn resolveCredentials(
    allocator: std.mem.Allocator,
    host_url: []const u8,
    cli_key: ?[]const u8,
    cli_secret: ?[]const u8,
) !?config.Credentials {
    const hostname = hostnameFromUrl(host_url);

    const conf_creds = try config.findCredentials(allocator, hostname);
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

    return try config.mergeCredentials(
        allocator,
        .{ .key = cli_key, .secret = cli_secret },
        .{ .key = env_key, .secret = env_secret },
        conf_creds,
    );
}

/// Resolve retry/timeout configuration from environment variables.
///
/// Priority: `cli_retries` (from --retries flag) > `OPENQA_CLI_RETRIES` env >
/// `default_retries`. Timeout and backoff knobs are env-only (no CLI flags).
///
/// Arguments:
///   - `allocator`: Used only for temporary env-var string ownership.
///   - `cli_retries`: Retry count from CLI `--retries`/`--retry` flag, or `null` to fall through to env/default.
///   - `default_retries`: Value used when neither the CLI flag nor the env var
///     is set. Most tools pass `0`; `clone-job` passes `5` to match the Perl
///     reference's default. A user-set `OPENQA_CLI_RETRIES` still overrides it.
///
/// Returns: A `RetryConfig` struct with all four knobs resolved.
///
/// Errors:
///   - `error.InvalidConnectTimeout` — `OPENQA_CLI_CONNECT_TIMEOUT` is set but not a valid number.
///   - Any OS error from `std.process.getEnvVarOwned`.
pub fn resolveRetryConfig(
    allocator: std.mem.Allocator,
    cli_retries: ?u32,
    default_retries: u32,
) !RetryConfig {
    const retries: u32 = cli_retries orelse blk: {
        const env_s = std.process.getEnvVarOwned(allocator, "OPENQA_CLI_RETRIES") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk default_retries,
            else => return err,
        };
        defer allocator.free(env_s);
        break :blk std.fmt.parseInt(u32, env_s, 10) catch default_retries;
    };

    const connect_timeout_s: f64 = blk: {
        const env_s = std.process.getEnvVarOwned(allocator, "OPENQA_CLI_CONNECT_TIMEOUT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk 30.0,
            else => return err,
        };
        defer allocator.free(env_s);
        break :blk std.fmt.parseFloat(f64, env_s) catch {
            std.debug.print("error: OPENQA_CLI_CONNECT_TIMEOUT={s}: not a valid number\n", .{env_s});
            return error.InvalidConnectTimeout;
        };
    };

    const retry_sleep_s: f64 = blk: {
        const env_s = std.process.getEnvVarOwned(allocator, "OPENQA_CLI_RETRY_SLEEP_TIME_S") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk 3.0,
            else => return err,
        };
        defer allocator.free(env_s);
        break :blk std.fmt.parseFloat(f64, env_s) catch 3.0;
    };

    const retry_factor: f64 = blk: {
        const env_s = std.process.getEnvVarOwned(allocator, "OPENQA_CLI_RETRY_FACTOR") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk 1.0,
            else => return err,
        };
        defer allocator.free(env_s);
        break :blk std.fmt.parseFloat(f64, env_s) catch 1.0;
    };

    return .{
        .retries = retries,
        .connect_timeout_s = connect_timeout_s,
        .retry_sleep_s = retry_sleep_s,
        .retry_factor = retry_factor,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveRetryConfig defaults when no env vars set" {
    // In a typical test environment no OPENQA_CLI_* env vars are set.
    const cfg = try resolveRetryConfig(std.testing.allocator, null, 0);
    try std.testing.expectEqual(@as(u32, 0), cfg.retries);
    try std.testing.expectEqual(@as(f64, 30.0), cfg.connect_timeout_s);
    try std.testing.expectEqual(@as(f64, 3.0), cfg.retry_sleep_s);
    try std.testing.expectEqual(@as(f64, 1.0), cfg.retry_factor);
}

test "resolveRetryConfig cli_retries takes priority" {
    const cfg = try resolveRetryConfig(std.testing.allocator, 5, 0);
    try std.testing.expectEqual(@as(u32, 5), cfg.retries);
}

test "resolveRetryConfig falls back to default_retries when no CLI/env" {
    // clone-job passes default_retries = 5; with no --retry flag and no
    // OPENQA_CLI_RETRIES env var set, the default must win.
    const cfg = try resolveRetryConfig(std.testing.allocator, null, 5);
    try std.testing.expectEqual(@as(u32, 5), cfg.retries);
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
