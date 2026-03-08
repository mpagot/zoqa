const std = @import("std");
const config = @import("openQAclient").config;
const http_client = @import("http_client.zig");

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

pub fn isAbsoluteUrl(path: []const u8) bool {
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
    kv_params: std.ArrayList([]const u8),
    // help requested
    help: bool = false,
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Args {
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
pub fn jsonToFormEncoded(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
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
pub fn formEncodeAppend(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), input: []const u8) !void {
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
// buildRequest — extracted post-parseArgs processing (fuzzable)
// ---------------------------------------------------------------------------

/// Fully-built request configuration, ready to pass to http_client.execute().
/// All slices are owned by the caller's allocator.
pub const RequestConfig = struct {
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    headers: std.ArrayList(std.http.Header),
    params_encoded: []const u8,

    // Owned buffers that must be freed by the caller
    url_owned: bool,
    body_owned: bool,
    form_body_buf: ?[]u8,
    params_buf: std.ArrayList(u8),
    base_url_buf: ?[]u8,

    pub fn deinit(self: *RequestConfig, allocator: std.mem.Allocator) void {
        if (self.form_body_buf) |b| allocator.free(b);
        self.params_buf.deinit(allocator);
        if (self.base_url_buf) |b| allocator.free(b);
        if (self.url_owned and self.url.ptr != (self.base_url_buf orelse self.url).ptr) {
            allocator.free(self.url);
        }
        self.headers.deinit(allocator);
    }
};

/// Logic for merging credentials from multiple sources with field-level priority.
/// Priority: CLI > ENV > Config File.
/// Returns allocated Credentials on success (caller owns fields).
pub fn mergeCredentials(
    allocator: std.mem.Allocator,
    cli: struct { key: ?[]const u8, secret: ?[]const u8 },
    env: struct { key: ?[]const u8, secret: ?[]const u8 },
    conf: ?config.Credentials,
) !?config.Credentials {
    const key = cli.key orelse env.key orelse if (conf) |c| c.key else null;
    const secret = cli.secret orelse env.secret orelse if (conf) |c| c.secret else null;

    if (key != null and secret != null) {
        return config.Credentials{
            .key = try allocator.dupe(u8, key.?),
            .secret = try allocator.dupe(u8, secret.?),
        };
    }
    return null;
}

/// Build a RequestConfig from parsed arguments.
///
/// This function performs all the post-parseArgs processing that was previously
/// inlined in main(): positional KV encoding, param-file reading, host
/// resolution, method parsing, URL building, body assembly (--data, --data-file,
/// --form), and header construction.
///
/// `data_file_content` is the pre-read content of --data-file (or stdin).
/// Pass null when --data-file was not supplied. The caller is responsible for
/// reading the file/stdin before calling this function — buildRequest itself
/// does no filesystem I/O for body data. It DOES read --param-file files from
/// the filesystem (because the fuzz harness already writes a temp file that
/// the function can read).
pub fn buildRequest(
    allocator: std.mem.Allocator,
    args: *const Args,
    data_file_content: ?[]const u8,
) !RequestConfig {
    // kv_params[0] = PATH, kv_params[1..] = KEY=VALUE pairs.
    if (args.kv_params.items.len == 0) return error.MissingPath;

    const api_path = args.kv_params.items[0];
    const kv_args = args.kv_params.items[1..];

    // Collect all parameters (SPEC §3.1)
    var params: std.ArrayList(u8) = .{};
    errdefer params.deinit(allocator);

    // Positional KEY=VALUE pairs
    for (kv_args) |p| {
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (params.items.len > 0) try params.append(allocator, '&');
        try formEncodeAppend(allocator, &params, p[0..eq]);
        try params.append(allocator, '=');
        try formEncodeAppend(allocator, &params, p[eq + 1 ..]);
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
        if (params.items.len > 0) try params.append(allocator, '&');
        try formEncodeAppend(allocator, &params, key);
        try params.append(allocator, '=');
        try formEncodeAppend(allocator, &params, trimmed);
    }

    // Resolve host
    const host_res = try config.resolveHost(
        allocator,
        args.osd,
        args.o3,
        args.odn,
        args.host,
    );
    defer if (host_res.allocated) allocator.free(host_res.url);

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
    var base_url_buf: ?[]u8 = null;
    errdefer if (base_url_buf) |b| allocator.free(b);

    const base_url: []const u8 = if (isAbsoluteUrl(api_path))
        api_path
    else blk: {
        const clean = if (std.mem.startsWith(u8, api_path, "/")) api_path[1..] else api_path;
        base_url_buf = try std.fmt.allocPrint(allocator, "{s}/api/v1/{s}", .{ host_res.url, clean });
        break :blk base_url_buf.?;
    };

    // Append query string ONLY for GET/DELETE (SPEC §3.1)
    var url_owned = false;
    const final_url: []const u8 = if ((method == .GET or method == .DELETE) and params.items.len > 0) blk: {
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, base_url, '?') != null) "&" else "?";
        url_owned = true;
        break :blk try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base_url, sep, params.items });
    } else base_url;
    errdefer if (url_owned) allocator.free(final_url);

    // Build request body (SPEC §7)
    var req_body: ?[]const u8 = null;

    if (data_file_content) |dfc| {
        req_body = dfc;
    } else if (args.data) |d| {
        req_body = d;
    } else if ((method == .POST or method == .PUT or method == .PATCH) and params.items.len > 0) {
        req_body = params.items;
    }

    // --form: JSON object body → application/x-www-form-urlencoded (SPEC §7)
    var form_body_buf: ?[]u8 = null;
    errdefer if (form_body_buf) |b| allocator.free(b);

    if (args.form) {
        if (req_body) |rb| {
            form_body_buf = try jsonToFormEncoded(allocator, rb);
            req_body = form_body_buf.?;
        } else {
            return error.FormRequiresData;
        }
    }

    // Build extra request headers
    var custom_headers: std.ArrayList(std.http.Header) = .{};
    errdefer custom_headers.deinit(allocator);

    for (args.headers.items) |h| {
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        const name = std.mem.trim(u8, h[0..colon], " \t");
        const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
        try custom_headers.append(allocator, .{ .name = name, .value = value });
    }

    if (args.json) {
        try custom_headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    }

    if (args.form or ((method == .POST or method == .PUT or method == .PATCH) and
        params.items.len > 0 and args.data == null and args.data_file == null))
    {
        try custom_headers.append(allocator, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" });
    }

    return RequestConfig{
        .method = method,
        .url = final_url,
        .body = req_body,
        .headers = custom_headers,
        .params_encoded = params.items,
        .url_owned = url_owned,
        .body_owned = data_file_content != null,
        .form_body_buf = form_body_buf,
        .params_buf = params,
        .base_url_buf = base_url_buf,
    };
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

    var req_cfg = buildRequest(gpa, &args, data_file_content) catch |err| {
        std.debug.print("Request build error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer req_cfg.deinit(gpa);

    // Resolve credentials (SPEC §5.1)
    const host_url = req_cfg.url;
    const uri = try std.Uri.parse(host_url);
    const hostname = if (uri.host) |h| h.percent_encoded else "localhost";
    const conf_creds = try config.findCredentials(gpa, hostname);
    defer if (conf_creds) |c| {
        gpa.free(c.key);
        gpa.free(c.secret);
    };

    const creds = try mergeCredentials(
        gpa,
        .{ .key = args.apikey, .secret = args.apisecret },
        .{ .key = std.posix.getenv("OPENQA_API_KEY"), .secret = std.posix.getenv("OPENQA_API_SECRET") },
        conf_creds,
    );
    defer if (creds) |c| {
        gpa.free(c.key);
        gpa.free(c.secret);
    };

    // Retry count: --retries > OPENQA_CLI_RETRIES env > 0 (SPEC §8)
    const retries: u32 = args.retries orelse blk: {
        if (std.posix.getenv("OPENQA_CLI_RETRIES")) |s| {
            break :blk std.fmt.parseInt(u32, s, 10) catch 0;
        }
        break :blk 0;
    };

    const req = http_client.Request{
        .allocator = gpa,
        .method = req_cfg.method,
        .url = req_cfg.url,
        .headers = req_cfg.headers.items,
        .body = req_cfg.body,
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
            .{ .key = "CONF_KEY", .secret = "CONF_SECRET" },
        );
        try testing.expect(res != null);
        defer {
            allocator.free(res.?.key);
            allocator.free(res.?.secret);
        }
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
        defer {
            allocator.free(res.?.key);
            allocator.free(res.?.secret);
        }
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

test "buildRequest: GET with KV params appends query string" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--host", "http://example.com", "api", "jobs", "state=running",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expect(req_cfg.method == .GET);
    // URL should contain the query string
    try std.testing.expect(std.mem.indexOf(u8, req_cfg.url, "?state=running") != null);
}

test "buildRequest: POST with --data and --form" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--host", "http://example.com", "-X",  "POST",
        "--form",       "--data", "{\"foo\":\"bar\"}",  "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expect(req_cfg.method == .POST);
    try std.testing.expect(req_cfg.body != null);
    try std.testing.expectEqualStrings("foo=bar", req_cfg.body.?);
    // Should have Content-Type: application/x-www-form-urlencoded header
    var found_ct = false;
    for (req_cfg.headers.items) |h| {
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
        "openQAclient", "-X", "post", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expect(req_cfg.method == .POST);
}

test "buildRequest: absolute URL used as-is" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "api", "https://custom.host/api/v1/jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expectEqualStrings("https://custom.host/api/v1/jobs", req_cfg.url);
}

test "buildRequest: --header with colon splitting" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--header", "X-Custom: my-value", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), req_cfg.headers.items.len);
    try std.testing.expectEqualStrings("X-Custom", req_cfg.headers.items[0].name);
    try std.testing.expectEqualStrings("my-value", req_cfg.headers.items[0].value);
}

test "buildRequest: --json adds Content-Type header" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--json", "-X", "POST", "--data", "{}", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    var found_json_ct = false;
    for (req_cfg.headers.items) |h| {
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
        "openQAclient", "--form", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    try std.testing.expectError(error.FormRequiresData, buildRequest(allocator, &parsed, null));
}

test "buildRequest: data-file content used as body" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "-X", "POST", "--data-file", "dummy.txt", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    const file_data = "file body content";
    var req_cfg = try buildRequest(allocator, &parsed, file_data);
    defer req_cfg.deinit(allocator);

    try std.testing.expectEqualStrings("file body content", req_cfg.body.?);
}

test "buildRequest: --osd flag resolves to openqa.suse.de" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--osd", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, req_cfg.url, "openqa.suse.de") != null);
}

// ---------------------------------------------------------------------------
// Additional coverage for pub functions
// ---------------------------------------------------------------------------

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
    defer {
        allocator.free(res.?.key);
        allocator.free(res.?.secret);
    }
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
        .{ .key = "CONF_KEY", .secret = "CONF_SECRET" },
    );
    try testing.expect(res != null);
    defer {
        allocator.free(res.?.key);
        allocator.free(res.?.secret);
    }
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
        .{ .key = "CONF_KEY", .secret = "CONF_SECRET" },
    );
    try testing.expect(res != null);
    defer {
        allocator.free(res.?.key);
        allocator.free(res.?.secret);
    }
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

test "isAbsoluteUrl: empty string" {
    try std.testing.expect(!isAbsoluteUrl(""));
}

test "isAbsoluteUrl: colon after slash is relative" {
    // "foo/bar:baz" has a slash before the colon → not a scheme
    try std.testing.expect(!isAbsoluteUrl("foo/bar:baz"));
}

test "isAbsoluteUrl: colon after question mark is relative" {
    try std.testing.expect(!isAbsoluteUrl("foo?bar:baz"));
}

test "isAbsoluteUrl: protocol-relative" {
    try std.testing.expect(isAbsoluteUrl("//cdn.example.com/asset.js"));
}

test "isAbsoluteUrl: ftp scheme" {
    try std.testing.expect(isAbsoluteUrl("ftp://files.example.com/data"));
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

test "buildRequest: DELETE with KV params appends query string" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "-X",     "DELETE",  "--host", "http://example.com",
        "api",          "jobs/1", "force=1",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expect(req_cfg.method == .DELETE);
    try std.testing.expect(std.mem.indexOf(u8, req_cfg.url, "?force=1") != null);
}

test "buildRequest: POST with KV params uses body not query string" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "-X",   "POST",       "--host",     "http://example.com",
        "api",          "jobs", "DISTRI=sle", "VERSION=15",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expect(req_cfg.method == .POST);
    // URL should NOT contain query string for POST
    try std.testing.expect(std.mem.indexOf(u8, req_cfg.url, "?") == null);
    // Body should contain the params
    try std.testing.expect(req_cfg.body != null);
    try std.testing.expect(std.mem.indexOf(u8, req_cfg.body.?, "DISTRI=sle") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_cfg.body.?, "VERSION=15") != null);
    // Should have form Content-Type
    var found_ct = false;
    for (req_cfg.headers.items) |h| {
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
    const argv: []const []const u8 = &.{ "openQAclient", "api" };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    try std.testing.expectError(error.MissingPath, buildRequest(allocator, &parsed, null));
}

test "buildRequest: --o3 flag resolves to openqa.opensuse.org" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--o3", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, req_cfg.url, "openqa.opensuse.org") != null);
}

test "buildRequest: --header without colon is skipped" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--header", "MalformedHeader", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    // Malformed header without colon should be silently skipped
    try std.testing.expectEqual(@as(usize, 0), req_cfg.headers.items.len);
}

test "buildRequest: leading slash stripped from relative api path" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--host", "http://example.com", "api", "/jobs/overview",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    // Should build "http://example.com/api/v1/jobs/overview" (no double slash)
    try std.testing.expectEqualStrings("http://example.com/api/v1/jobs/overview", req_cfg.url);
}

test "buildRequest: bare hostname gets https:// prefix via resolveHost" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--host", "myhost.example.com", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    var req_cfg = try buildRequest(allocator, &parsed, null);
    defer req_cfg.deinit(allocator);

    try std.testing.expect(std.mem.startsWith(u8, req_cfg.url, "https://myhost.example.com"));
}

test "buildRequest: data-file content with --form encodes JSON body" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "-X", "POST", "--data-file", "dummy.json", "--form", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    const file_data = "{\"key\":\"value\"}";
    var req_cfg = try buildRequest(allocator, &parsed, file_data);
    defer req_cfg.deinit(allocator);

    try std.testing.expectEqualStrings("key=value", req_cfg.body.?);
}

test "parseArgs: equals-form flags" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient",
        "--host=http://ex.com",
        "--apikey=K1",
        "--apisecret=S1",
        "--method=PUT",
        "--data=body",
        "--data-file=f.txt",
        "--header=X-A: B",
        "--param-file=K=V",
        "--retries=5",
        "api",
        "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

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
    const argv: []const []const u8 = &.{ "openQAclient", "--nonexistent" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(allocator, argv));
}

test "parseArgs: missing value after flag returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "openQAclient", "--host" };
    try std.testing.expectError(error.MissingValue, parseArgs(allocator, argv));
}

test "parseArgs: invalid retries returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{ "openQAclient", "--retries", "abc" };
    try std.testing.expectError(error.InvalidRetries, parseArgs(allocator, argv));
}

test "buildRequest: path with null byte returns error" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--param-file", "key=path\x00with_null", "api", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    try std.testing.expectError(error.PathContainsNullByte, buildRequest(allocator, &parsed, null));
}

test "parseArgs: stop flag --" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = &.{
        "openQAclient", "--", "--osd", "jobs",
    };
    var parsed = try parseArgs(allocator, argv);
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    // --osd after -- is treated as subcmd, not flag
    try std.testing.expect(!parsed.osd);
    try std.testing.expectEqualStrings("--osd", parsed.path.?);
    try std.testing.expectEqualStrings("jobs", parsed.kv_params.items[0]);
}
