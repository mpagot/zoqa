const std = @import("std");

pub const Credentials = struct {
    allocator: std.mem.Allocator,
    key: []const u8,
    secret: []const u8,

    /// Release the key and secret strings allocated by `parseIni` /
    /// `mergeCredentials`. Must be called exactly once.
    pub fn deinit(self: Credentials) void {
        self.allocator.free(self.key);
        self.allocator.free(self.secret);
    }
};

pub const HostResult = struct {
    url: []const u8,
    allocated: bool,
};

/// Resolves the effective base URL string from alias flags and host argument.
///
/// Parameters:
///   - `allocator`: Used to allocate the `https://` prefix when a bare hostname is given.
///   - `flag_osd`: `true` if `--osd` was passed (maps to `http://openqa.suse.de`).
///   - `flag_o3`: `true` if `--o3` was passed (maps to `https://openqa.opensuse.org`).
///   - `flag_odn`: `true` if `--odn` was passed (maps to `https://openqa.debian.net`).
///   - `host_arg`: Explicit `--host` value, or `null`.
///
/// Returns: A `HostResult` whose `.url` is either a compile-time literal
///   (`.allocated = false`) or a newly allocated string (`.allocated = true`).
///   Caller must free `.url` when `.allocated` is true.
///
/// Errors:
///   - `OutOfMemory` — allocator failure when prefixing bare hostname with `https://`.
pub fn resolveHost(
    allocator: std.mem.Allocator,
    flag_osd: bool,
    flag_o3: bool,
    flag_odn: bool,
    host_arg: ?[]const u8,
) !HostResult {
    // Last-wins: if multiple alias flags are given, the last one on the command
    // line wins because parseArgs sets each bool independently, so we must
    // evaluate them in priority order and let later assignments overwrite.
    var alias_url: ?[]const u8 = null;
    if (flag_o3) alias_url = "https://openqa.opensuse.org";
    if (flag_osd) alias_url = "http://openqa.suse.de";
    if (flag_odn) alias_url = "https://openqa.debian.net";
    if (alias_url) |u| return .{ .url = u, .allocated = false };

    if (host_arg) |h| {
        if (std.mem.indexOf(u8, h, "://") != null or std.mem.startsWith(u8, h, "/")) {
            return .{ .url = h, .allocated = false };
        }
        return .{
            .url = try std.fmt.allocPrint(allocator, "https://{s}", .{h}),
            .allocated = true,
        };
    }

    return .{ .url = "http://localhost", .allocated = false };
}

test "resolveHost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    {
        const r = try resolveHost(allocator, true, false, false, null);
        try testing.expectEqualStrings("http://openqa.suse.de", r.url);
        try testing.expect(!r.allocated);
    }
    {
        const r = try resolveHost(allocator, false, true, false, null);
        try testing.expectEqualStrings("https://openqa.opensuse.org", r.url);
        try testing.expect(!r.allocated);
    }
    {
        const r = try resolveHost(allocator, false, false, true, null);
        try testing.expectEqualStrings("https://openqa.debian.net", r.url);
        try testing.expect(!r.allocated);
    }
    {
        const r = try resolveHost(allocator, false, false, false, "openqa.example.com");
        try testing.expectEqualStrings("https://openqa.example.com", r.url);
        try testing.expect(r.allocated);
        allocator.free(r.url);
    }
    {
        const r = try resolveHost(allocator, false, false, false, "http://openqa.example.com");
        try testing.expectEqualStrings("http://openqa.example.com", r.url);
        try testing.expect(!r.allocated);
    }
    {
        const r = try resolveHost(allocator, false, false, false, null);
        try testing.expectEqualStrings("http://localhost", r.url);
        try testing.expect(!r.allocated);
    }
    // Last-wins: --o3 then --osd → osd wins (osd is evaluated after o3)
    {
        const r = try resolveHost(allocator, true, true, false, null);
        try testing.expectEqualStrings("http://openqa.suse.de", r.url);
        try testing.expect(!r.allocated);
    }
    // Last-wins: --osd then --odn → odn wins (odn is evaluated after osd)
    {
        const r = try resolveHost(allocator, true, false, true, null);
        try testing.expectEqualStrings("https://openqa.debian.net", r.url);
        try testing.expect(!r.allocated);
    }
}

/// Parses INI file content to find credentials for a specific hostname.
///
/// Parameters:
///   - `allocator`: Used to allocate owned copies of the key and secret strings.
///   - `content`: The raw INI file content to parse.
///   - `hostname`: The section name to search for (e.g. `"openqa.suse.de"`).
///
/// Returns: A `Credentials` struct with owned key/secret on success (caller
///   must call `.deinit()`), or `null` if no matching section with both
///   `key` and `secret` is found.
///
/// Errors:
///   - `OutOfMemory` — allocator failure when duplicating the key/secret strings.
fn parseIni(allocator: std.mem.Allocator, content: []const u8, hostname: []const u8) !?Credentials {
    var it = std.mem.splitScalar(u8, content, '\n');
    var in_target_section = false;

    var key: ?[]const u8 = null;
    var secret: ?[]const u8 = null;

    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') {
            continue;
        }

        if (line[0] == '[' and line[line.len - 1] == ']') {
            const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (std.mem.eql(u8, section, hostname)) {
                in_target_section = true;
            } else {
                in_target_section = false;
            }
            continue;
        }

        if (in_target_section) {
            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = std.mem.trim(u8, line[0..eq_idx], " \t");
            const v = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

            if (std.mem.eql(u8, k, "key")) {
                key = v;
            } else if (std.mem.eql(u8, k, "secret")) {
                secret = v;
            }
        }
    }

    if (key != null and secret != null) {
        return Credentials{
            .allocator = allocator,
            .key = try allocator.dupe(u8, key.?),
            .secret = try allocator.dupe(u8, secret.?),
        };
    }

    return null;
}

test "parseIni" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ini =
        \\# A comment
        \\[openqa.example.com]
        \\key = MYPUBLICKEY
        \\secret = MYPRIVATESECRET
        \\
        \\[another.host]
        \\key = OTHERKEY
        \\secret = OTHERSECRET
    ;

    const creds1 = try parseIni(allocator, ini, "openqa.example.com");
    try testing.expect(creds1 != null);
    try testing.expectEqualStrings("MYPUBLICKEY", creds1.?.key);
    try testing.expectEqualStrings("MYPRIVATESECRET", creds1.?.secret);
    creds1.?.deinit();

    const creds2 = try parseIni(allocator, ini, "another.host");
    try testing.expect(creds2 != null);
    try testing.expectEqualStrings("OTHERKEY", creds2.?.key);
    try testing.expectEqualStrings("OTHERSECRET", creds2.?.secret);
    creds2.?.deinit();

    const creds3 = try parseIni(allocator, ini, "not.found");
    try testing.expect(creds3 == null);
}

/// Finds credentials by searching config files in priority order.
///
/// Search order: `$OPENQA_CONFIG/client.conf` > `~/.config/openqa/client.conf`
/// > `/etc/openqa/client.conf` > `/usr/etc/openqa/client.conf`.
///
/// Environment variables are NOT read here. The caller is responsible for
/// resolving `$OPENQA_CONFIG` and `$HOME`/`$USERPROFILE` from the OS
/// (e.g. via `cli_env.OsEnv`) and passing them in.
///
/// Parameters:
///   - `allocator`: Used for path construction, file I/O, and result allocation.
///   - `hostname`: The INI section name to look up (e.g. `"openqa.opensuse.org"`).
///   - `openqa_config_dir`: Value of `$OPENQA_CONFIG`, or `null` if unset.
///   - `home_dir`: Value of `$HOME`/`$USERPROFILE`, or `null` if unset.
///
/// Returns: A `Credentials` struct with owned key/secret (caller must call
///   `.deinit()`), or `null` if no config file contains a matching section.
///
/// Errors:
///   - `OutOfMemory` — allocator failure.
pub fn findCredentials(
    allocator: std.mem.Allocator,
    hostname: []const u8,
    openqa_config_dir: ?[]const u8,
    home_dir: ?[]const u8,
) !?Credentials {
    const env_config = if (openqa_config_dir) |p|
        try std.fs.path.join(allocator, &.{ p, "client.conf" })
    else
        null;
    defer if (env_config) |p| allocator.free(p);

    const env_home = if (home_dir) |h|
        try std.fs.path.join(allocator, &.{ h, ".config", "openqa", "client.conf" })
    else
        null;
    defer if (env_home) |p| allocator.free(p);

    const search_paths = [_]?[]const u8{
        env_config,
        env_home,
        "/etc/openqa/client.conf",
        "/usr/etc/openqa/client.conf",
    };

    for (search_paths) |path_opt| {
        if (path_opt) |path| {
            const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch continue;
            defer allocator.free(content);

            if (try parseIni(allocator, content, hostname)) |creds| {
                return creds;
            }
        }
    }

    return null;
}

test "findCredentials: both null, no static files present → null" {
    // Use a hostname that won't match anything in /etc/openqa/client.conf
    // or /usr/etc/openqa/client.conf (if those files even exist).
    const creds = try findCredentials(
        std.testing.allocator,
        "no.such.host.for.testing.invalid",
        null,
        null,
    );
    try std.testing.expect(creds == null);
}

test "findCredentials: openqa_config_dir finds credentials" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("client.conf", .{});
    defer f.close();
    try f.writeAll("[cfghost.example.com]\nkey = CFGKEY\nsecret = CFGSECRET\n");

    var path_buf: [4096]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const creds = try findCredentials(allocator, "cfghost.example.com", tmp_path, null);
    defer if (creds) |c| c.deinit();

    try std.testing.expect(creds != null);
    try std.testing.expectEqualStrings("CFGKEY", creds.?.key);
    try std.testing.expectEqualStrings("CFGSECRET", creds.?.secret);
}

test "findCredentials: home_dir finds credentials via .config/openqa/client.conf" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".config/openqa");
    const f = try tmp.dir.createFile(".config/openqa/client.conf", .{});
    defer f.close();
    try f.writeAll("[homehost.example.com]\nkey = HOMEKEY\nsecret = HOMESECRET\n");

    var path_buf: [4096]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const creds = try findCredentials(allocator, "homehost.example.com", null, tmp_path);
    defer if (creds) |c| c.deinit();

    try std.testing.expect(creds != null);
    try std.testing.expectEqualStrings("HOMEKEY", creds.?.key);
    try std.testing.expectEqualStrings("HOMESECRET", creds.?.secret);
}

test "findCredentials: openqa_config_dir takes priority over home_dir" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Both dirs use the same hostname — config_dir is searched first, so its
    // value is returned even though home_dir also has a matching section.
    const f1 = try tmp.dir.createFile("client.conf", .{});
    defer f1.close();
    try f1.writeAll("[priority.example.com]\nkey = CFGKEY\nsecret = CFGSECRET\n");

    try tmp.dir.makePath(".config/openqa");
    const f2 = try tmp.dir.createFile(".config/openqa/client.conf", .{});
    defer f2.close();
    try f2.writeAll("[priority.example.com]\nkey = HOMEKEY\nsecret = HOMESECRET\n");

    var path_buf: [4096]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const creds = try findCredentials(allocator, "priority.example.com", tmp_path, tmp_path);
    defer if (creds) |c| c.deinit();

    try std.testing.expect(creds != null);
    try std.testing.expectEqualStrings("CFGKEY", creds.?.key);
    try std.testing.expectEqualStrings("CFGSECRET", creds.?.secret);
}

test "findCredentials: hostname mismatch returns null" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("client.conf", .{});
    defer f.close();
    try f.writeAll("[other.host.example.com]\nkey = KEY\nsecret = SECRET\n");

    var path_buf: [4096]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const creds = try findCredentials(allocator, "different.host.example.com", tmp_path, null);
    try std.testing.expect(creds == null);
}

/// Merge credentials from three priority layers: CLI args, environment
/// variables, and config file. Priority per field: CLI > env > config.
///
/// Each field (key, secret) is resolved independently — it is valid to
/// have the key come from one source and the secret from another.
///
/// Arguments:
///   - `allocator`: Used to allocate owned copies of the merged key/secret.
///   - `cli`: Key/secret from CLI flags (`--apikey`, `--apisecret`), or `null` per field.
///   - `env`: Key/secret from environment variables, or `null` per field.
///   - `conf`: Credentials from config file (output of `findCredentials`), or `null`.
///
/// Returns: Owned `Credentials` (caller must call `.deinit()`), or `null`
///   when either key or secret is missing across all sources.
///
/// Errors:
///   - `OutOfMemory` — allocator failure when duplicating strings.
pub fn mergeCredentials(
    allocator: std.mem.Allocator,
    cli: struct { key: ?[]const u8, secret: ?[]const u8 },
    env: struct { key: ?[]const u8, secret: ?[]const u8 },
    conf: ?Credentials,
) !?Credentials {
    const key = cli.key orelse env.key orelse if (conf) |c| c.key else null;
    const secret = cli.secret orelse env.secret orelse if (conf) |c| c.secret else null;

    if (key != null and secret != null) {
        return Credentials{
            .allocator = allocator,
            .key = try allocator.dupe(u8, key.?),
            .secret = try allocator.dupe(u8, secret.?),
        };
    }
    return null;
}

test "mergeCredentials: field-level priority behavior" {
    const testing_alloc = std.testing.allocator;

    // Scenario 1: Partial CLI override (Secret only)
    // Should combine CLI secret with Config key
    {
        const res = try mergeCredentials(
            testing_alloc,
            .{ .key = null, .secret = "CLI_SECRET" },
            .{ .key = null, .secret = null },
            .{ .allocator = testing_alloc, .key = "CONF_KEY", .secret = "CONF_SECRET" },
        );
        try std.testing.expect(res != null);
        defer res.?.deinit();
        try std.testing.expectEqualStrings("CONF_KEY", res.?.key);
        try std.testing.expectEqualStrings("CLI_SECRET", res.?.secret);
    }

    // Scenario 2: CLI overrides ENV
    {
        const res = try mergeCredentials(
            testing_alloc,
            .{ .key = "CLI_KEY", .secret = null },
            .{ .key = "ENV_KEY", .secret = "ENV_SECRET" },
            null,
        );
        try std.testing.expect(res != null);
        defer res.?.deinit();
        try std.testing.expectEqualStrings("CLI_KEY", res.?.key);
        try std.testing.expectEqualStrings("ENV_SECRET", res.?.secret);
    }

    // Scenario 3: All null returns null
    {
        const res = try mergeCredentials(
            testing_alloc,
            .{ .key = null, .secret = null },
            .{ .key = null, .secret = null },
            null,
        );
        try std.testing.expect(res == null);
    }
}

test "mergeCredentials: env-only fallback (no CLI, no conf)" {
    const allocator = std.testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = null, .secret = null },
        .{ .key = "ENV_KEY", .secret = "ENV_SECRET" },
        null,
    );
    try std.testing.expect(res != null);
    defer res.?.deinit();
    try std.testing.expectEqualStrings("ENV_KEY", res.?.key);
    try std.testing.expectEqualStrings("ENV_SECRET", res.?.secret);
}

test "mergeCredentials: conf-only fallback (no CLI, no env)" {
    const allocator = std.testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = null, .secret = null },
        .{ .key = null, .secret = null },
        .{ .allocator = allocator, .key = "CONF_KEY", .secret = "CONF_SECRET" },
    );
    try std.testing.expect(res != null);
    defer res.?.deinit();
    try std.testing.expectEqualStrings("CONF_KEY", res.?.key);
    try std.testing.expectEqualStrings("CONF_SECRET", res.?.secret);
}

test "mergeCredentials: key from env, secret from conf" {
    const allocator = std.testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = null, .secret = null },
        .{ .key = "ENV_KEY", .secret = null },
        .{ .allocator = allocator, .key = "CONF_KEY", .secret = "CONF_SECRET" },
    );
    try std.testing.expect(res != null);
    defer res.?.deinit();
    try std.testing.expectEqualStrings("ENV_KEY", res.?.key);
    try std.testing.expectEqualStrings("CONF_SECRET", res.?.secret);
}

test "mergeCredentials: partial key only returns null (no secret anywhere)" {
    const allocator = std.testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = "CLI_KEY", .secret = null },
        .{ .key = null, .secret = null },
        null,
    );
    try std.testing.expect(res == null);
}

test "mergeCredentials: partial secret only returns null (no key anywhere)" {
    const allocator = std.testing.allocator;

    const res = try mergeCredentials(
        allocator,
        .{ .key = null, .secret = "CLI_SECRET" },
        .{ .key = null, .secret = null },
        null,
    );
    try std.testing.expect(res == null);
}
