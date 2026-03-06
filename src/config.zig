const std = @import("std");

pub const Credentials = struct {
    key: []const u8,
    secret: []const u8,
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
    if (flag_osd) return .{ .url = "http://openqa.suse.de", .allocated = false };
    if (flag_o3) return .{ .url = "https://openqa.opensuse.org", .allocated = false };
    if (flag_odn) return .{ .url = "https://openqa.debian.net", .allocated = false };

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
            .key = try allocator.dupe(u8, key.?),
            .secret = try allocator.dupe(u8, secret.?),
        };
    }

    return null;
}

/// Finds credentials in the filesystem based on priority.
pub fn findCredentials(allocator: std.mem.Allocator, hostname: []const u8) !?Credentials {
    const env_config = if (std.posix.getenv("OPENQA_CONFIG")) |p| try std.fs.path.join(allocator, &.{ p, "client.conf" }) else null;
    defer if (env_config) |p| allocator.free(p);

    const env_home = if (std.posix.getenv("HOME")) |h| try std.fs.path.join(allocator, &.{ h, ".config", "openqa", "client.conf" }) else null;
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
    allocator.free(creds1.?.key);
    allocator.free(creds1.?.secret);

    const creds2 = try parseIni(allocator, ini, "another.host");
    try testing.expect(creds2 != null);
    try testing.expectEqualStrings("OTHERKEY", creds2.?.key);
    try testing.expectEqualStrings("OTHERSECRET", creds2.?.secret);
    allocator.free(creds2.?.key);
    allocator.free(creds2.?.secret);

    const creds3 = try parseIni(allocator, ini, "not.found");
    try testing.expect(creds3 == null);
}
