const std = @import("std");
const config = @import("openQAclient").config;
const http_client = @import("http_client.zig");

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

fn isAbsoluteUrl(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "//") or std.mem.startsWith(u8, path, "#")) return true;
    const colon_idx = std.mem.indexOfScalar(u8, path, ':') orelse return false;
    for (path[0..colon_idx]) |c| {
        if (c == '/' or c == '?' or c == '#') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const Args = struct {
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
    kv_params: std.ArrayList([]const u8),
    // help requested
    help: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Args {
    var args = Args{
        .headers = .{},
        .param_files = .{},
        .kv_params = .{},
    };

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
        if (std.mem.eql(u8, arg, "--links")) {
            args.links = true;
            continue;
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

        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.host = argv[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--host=")) {
            args.host = arg["--host=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "--apikey")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.apikey = argv[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--apikey=")) {
            args.apikey = arg["--apikey=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "--apisecret")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.apisecret = argv[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--apisecret=")) {
            args.apisecret = arg["--apisecret=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "-X") or std.mem.eql(u8, arg, "--method")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.method = argv[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--method=")) {
            args.method = arg["--method=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--data")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.data = argv[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--data=")) {
            args.data = arg["--data=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--data-file")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.data_file = argv[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--data-file=")) {
            args.data_file = arg["--data-file=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--header")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            try args.headers.append(allocator, argv[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--header=")) {
            try args.headers.append(allocator, arg["--header=".len..]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--param-file")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            try args.param_files.append(allocator, argv[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--param-file=")) {
            try args.param_files.append(allocator, arg["--param-file=".len..]);
            continue;
        }

        if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--retries")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.retries = std.fmt.parseInt(u32, argv[i], 10) catch return error.InvalidRetries;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--retries=")) {
            args.retries = std.fmt.parseInt(u32, arg["--retries=".len..], 10) catch return error.InvalidRetries;
            continue;
        }

        // ---- positionals ----
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

// ---------------------------------------------------------------------------
// Help text
// ---------------------------------------------------------------------------

fn printHelp() void {
    std.debug.print(
        \\Usage: openQAclient [GLOBAL OPTIONS] api [API OPTIONS] PATH [KEY=VALUE ...]
        \\
        \\Global Options:
        \\  --host HOST          Base URL of the OpenQA instance
        \\  --osd                Alias for --host http://openqa.suse.de
        \\  --o3                 Alias for --host https://openqa.opensuse.org
        \\  --odn                Alias for --host https://openqa.debian.net
        \\  --apikey KEY         Override API public key
        \\  --apisecret SECRET   Override API secret
        \\  -v, --verbose        Print HTTP response status line and headers to stdout
        \\  -q, --quiet          Suppress non-fatal error messages on stderr
        \\  --links              Parse Link response header and print rel: url pairs to stderr
        \\  -h, --help           Display this help and exit
        \\
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
    , .{});
}

// ---------------------------------------------------------------------------
// --form: JSON object → application/x-www-form-urlencoded
// ---------------------------------------------------------------------------

/// Parses `body` as a JSON object and encodes it as `key=value&...`.
/// Caller owns the returned slice.
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

/// Percent-encode a string for application/x-www-form-urlencoded.
/// Unreserved chars (RFC 3986) pass through; space → '+'; everything else → %XX.
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

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
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
        std.debug.print("Argument error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer args.headers.deinit(gpa);
    defer args.param_files.deinit(gpa);
    defer args.kv_params.deinit(gpa);

    if (args.help) {
        printHelp();
        return;
    }

    // args.path holds the subcommand token ("api").
    const subcmd = args.path orelse {
        std.debug.print("Error: Missing subcommand. Use 'api'.\n", .{});
        std.process.exit(1);
    };

    if (!std.mem.eql(u8, subcmd, "api")) {
        std.debug.print("Error: Unknown subcommand '{s}'. Only 'api' is supported.\n", .{subcmd});
        std.process.exit(1);
    }

    // kv_params[0] = PATH, kv_params[1..] = KEY=VALUE pairs.
    if (args.kv_params.items.len == 0) {
        std.debug.print("Error: Missing PATH for api subcommand.\n", .{});
        std.process.exit(1);
    }

    const api_path = args.kv_params.items[0];
    const kv_args = args.kv_params.items[1..];

    // Resolve host
    const host_res = try config.resolveHost(
        gpa,
        args.osd,
        args.o3,
        args.odn,
        args.host,
    );
    defer if (host_res.allocated) gpa.free(host_res.url);

    // Parse HTTP method (accept upper or lower case)
    const method = std.meta.stringToEnum(std.http.Method, args.method) orelse blk: {
        var upper_buf: [16]u8 = undefined;
        if (args.method.len <= upper_buf.len) {
            const upper = std.ascii.upperString(upper_buf[0..args.method.len], args.method);
            break :blk std.meta.stringToEnum(std.http.Method, upper) orelse .GET;
        }
        break :blk .GET;
    };

    // Build base URL (SPEC §4)
    const base_url: []const u8 = if (isAbsoluteUrl(api_path))
        try gpa.dupe(u8, api_path)
    else blk: {
        const clean = if (std.mem.startsWith(u8, api_path, "/")) api_path[1..] else api_path;
        break :blk try std.fmt.allocPrint(gpa, "{s}/api/v1/{s}", .{ host_res.url, clean });
    };
    defer gpa.free(base_url);

    // Collect KEY=VALUE params from positionals and --param-file
    var params: std.ArrayList(u8) = .{};
    defer params.deinit(gpa);

    for (kv_args) |p| {
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (params.items.len > 0) try params.append(gpa, '&');
        try params.appendSlice(gpa, p[0..eq]);
        try params.append(gpa, '=');
        try params.appendSlice(gpa, p[eq + 1 ..]);
    }

    // --param-file KEY=FILE: read file, trim trailing newline, append KEY=value
    for (args.param_files.items) |pf| {
        const eq = std.mem.indexOfScalar(u8, pf, '=') orelse {
            std.debug.print("Warning: --param-file '{s}' missing '=', skipping.\n", .{pf});
            continue;
        };
        const key = pf[0..eq];
        const file_path = pf[eq + 1 ..];
        const contents = try std.fs.cwd().readFileAlloc(gpa, file_path, 10 * 1024 * 1024);
        defer gpa.free(contents);
        const trimmed = std.mem.trimRight(u8, contents, "\n\r");
        if (params.items.len > 0) try params.append(gpa, '&');
        try params.appendSlice(gpa, key);
        try params.append(gpa, '=');
        try params.appendSlice(gpa, trimmed);
    }

    // Append query string for GET/DELETE (SPEC §3.1)
    const final_url: []const u8 = if ((method == .GET or method == .DELETE) and params.items.len > 0) blk: {
        const sep = if (std.mem.indexOfScalar(u8, base_url, '?') != null) "&" else "?";
        break :blk try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ base_url, sep, params.items });
    } else base_url;
    defer if (final_url.ptr != base_url.ptr) gpa.free(final_url);

    // Build request body (SPEC §7)
    var body_buf: ?[]u8 = null; // owns allocated body bytes, if any
    defer if (body_buf) |b| gpa.free(b);

    var req_body: ?[]const u8 = null;

    if (args.data_file) |df| {
        const raw = if (std.mem.eql(u8, df, "-"))
            try std.fs.File.stdin().readToEndAlloc(gpa, 10 * 1024 * 1024)
        else
            try std.fs.cwd().readFileAlloc(gpa, df, 10 * 1024 * 1024);
        body_buf = raw;
        req_body = raw;
    } else if (args.data) |d| {
        req_body = d; // borrowed from argv, no allocation
    } else if ((method == .POST or method == .PUT or method == .PATCH) and params.items.len > 0) {
        req_body = params.items; // borrowed from params ArrayList
    }

    // --form: JSON object body → application/x-www-form-urlencoded (SPEC §7)
    var form_body_buf: ?[]u8 = null;
    defer if (form_body_buf) |b| gpa.free(b);

    if (args.form) {
        if (req_body) |rb| {
            form_body_buf = jsonToFormEncoded(gpa, rb) catch |err| {
                std.debug.print("--form error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            req_body = form_body_buf.?;
        } else {
            std.debug.print("--form requires --data or --data-file\n", .{});
            std.process.exit(1);
        }
    }

    // Build extra request headers
    var custom_headers: std.ArrayList(std.http.Header) = .{};
    defer custom_headers.deinit(gpa);

    for (args.headers.items) |h| {
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse {
            std.debug.print("Warning: --header '{s}' missing ':', skipping.\n", .{h});
            continue;
        };
        const name = std.mem.trim(u8, h[0..colon], " \t");
        const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
        try custom_headers.append(gpa, .{ .name = name, .value = value });
    }

    if (args.json) {
        try custom_headers.append(gpa, .{ .name = "Content-Type", .value = "application/json" });
    }

    if (args.form or ((method == .POST or method == .PUT or method == .PATCH) and
        params.items.len > 0 and args.data == null and args.data_file == null))
    {
        try custom_headers.append(gpa, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" });
    }

    // Resolve credentials (SPEC §5.1)
    var creds: ?config.Credentials = null;
    if (args.apikey != null and args.apisecret != null) {
        creds = .{ .key = args.apikey.?, .secret = args.apisecret.? };
    } else if (std.posix.getenv("OPENQA_API_KEY") != null and
        std.posix.getenv("OPENQA_API_SECRET") != null)
    {
        creds = .{
            .key = std.posix.getenv("OPENQA_API_KEY").?,
            .secret = std.posix.getenv("OPENQA_API_SECRET").?,
        };
    } else {
        const uri = try std.Uri.parse(host_res.url);
        if (uri.host) |h| {
            if (try config.findCredentials(gpa, h.percent_encoded)) |c| {
                creds = c;
            }
        }
    }

    // Retry count: --retries > OPENQA_CLI_RETRIES env > 0 (SPEC §8)
    const retries: u32 = args.retries orelse blk: {
        if (std.posix.getenv("OPENQA_CLI_RETRIES")) |s| {
            break :blk std.fmt.parseInt(u32, s, 10) catch 0;
        }
        break :blk 0;
    };

    const req = http_client.Request{
        .allocator = gpa,
        .method = method,
        .url = final_url,
        .headers = custom_headers.items,
        .body = req_body,
        .credentials = creds,
        .retries = retries,
        .verbose = args.verbose,
        .quiet = args.quiet,
        .links = args.links,
        .pretty = args.pretty,
    };

    const exit_code = try http_client.execute(req);
    std.process.exit(exit_code);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isAbsoluteUrl: absolute schemes" {
    try std.testing.expect(isAbsoluteUrl("https://example.com/foo"));
    try std.testing.expect(isAbsoluteUrl("http://localhost"));
    try std.testing.expect(isAbsoluteUrl("//example.com/path"));
    try std.testing.expect(isAbsoluteUrl("#fragment"));
}

test "isAbsoluteUrl: relative paths" {
    try std.testing.expect(!isAbsoluteUrl("jobs/overview"));
    try std.testing.expect(!isAbsoluteUrl("/jobs/overview"));
    try std.testing.expect(!isAbsoluteUrl("jobs?state=running"));
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

test "parseArgs: basic flags" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--host",        "http://example.com", "-v", "-q",
        "api",          "jobs/overview", "state=running",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    try std.testing.expectEqualStrings("http://example.com", parsed.host.?);
    try std.testing.expect(parsed.verbose);
    try std.testing.expect(parsed.quiet);
    try std.testing.expectEqualStrings("api", parsed.path.?);
    try std.testing.expectEqualStrings("jobs/overview", parsed.kv_params.items[0]);
    try std.testing.expectEqualStrings("state=running", parsed.kv_params.items[1]);
}

test "parseArgs: --method long and short" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "openQAclient", "-X", "POST", "api", "jobs" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);
    try std.testing.expectEqualStrings("POST", parsed.method);
}

test "parseArgs: repeatable --header" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--header", "X-Foo: bar", "-a", "X-Baz: qux", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), parsed.headers.items.len);
    try std.testing.expectEqualStrings("X-Foo: bar", parsed.headers.items[0]);
    try std.testing.expectEqualStrings("X-Baz: qux", parsed.headers.items[1]);
}

test "parseArgs: --retries" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "openQAclient", "--retries", "3", "api", "jobs" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 3), parsed.retries.?);
}
