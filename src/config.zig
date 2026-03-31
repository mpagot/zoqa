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

/// Resolves the effective base URL string. Returned slice is either a
/// compile-time literal or a newly allocated string; caller owns it when
/// allocated is true in the result.
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

/// Parses the INI file content to find credentials for a specific hostname.
/// Returns allocated struct fields on success, null if not found.
pub fn parseIni(allocator: std.mem.Allocator, content: []const u8, hostname: []const u8) !?Credentials {
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

/// Finds credentials in the filesystem based on priority.
pub fn findCredentials(allocator: std.mem.Allocator, hostname: []const u8) !?Credentials {
    // OPENQA_CONFIG overrides the default config directory.
    const openqa_config_dir = std.process.getEnvVarOwned(allocator, "OPENQA_CONFIG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (openqa_config_dir) |p| allocator.free(p);
    const env_config = if (openqa_config_dir) |p| try std.fs.path.join(allocator, &.{ p, "client.conf" }) else null;
    defer if (env_config) |p| allocator.free(p);

    // Resolve the user's home directory: HOME on POSIX, USERPROFILE on Windows.
    const home_dir = blk: {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |h| {
            break :blk h;
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => return err,
        }
        if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |h| {
            break :blk h;
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk null,
            else => return err,
        }
    };
    defer if (home_dir) |h| allocator.free(h);
    const env_home = if (home_dir) |h| try std.fs.path.join(allocator, &.{ h, ".config", "openqa", "client.conf" }) else null;
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
