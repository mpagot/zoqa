const std = @import("std");
const config = @import("zoqa").config;
const auth = @import("zoqa").auth;

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: []std.http.Header,
    body: ?[]const u8,
    credentials: ?config.Credentials,
    retries: u32,
    verbose: bool,
    quiet: bool,
    links: bool,
    pretty: bool,
};

pub fn execute(req: Request) !u8 {
    var client = std.http.Client{ .allocator = req.allocator };
    defer client.deinit();

    // A single stdout writer with a stack buffer, reused across the retry loop.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        // Build the header list for this attempt (unmanaged ArrayList)
        var headers: std.ArrayList(std.http.Header) = .{};
        defer headers.deinit(req.allocator);

        try headers.appendSlice(req.allocator, req.headers);

        // Add default Accept header if the caller didn't supply one
        var has_accept = false;
        for (req.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Accept")) {
                has_accept = true;
                break;
            }
        }
        if (!has_accept) {
            try headers.append(req.allocator, .{ .name = "Accept", .value = "application/json" });
        }

        // Disable compression: std.http.Client does not decompress; request
        // raw bytes so the response body is always human-readable text.
        try headers.append(req.allocator, .{ .name = "Accept-Encoding", .value = "identity" });

        // if (req.body) |b| {
        //     var cl_buf: [32]u8 = undefined;
        //     const cl_val = try std.fmt.bufPrint(&cl_buf, "{d}", .{b.len});
        //     try headers.append(req.allocator, .{ .name = "Content-Length", .value = try req.allocator.dupe(u8, cl_val) });
        // }

        const uri = try std.Uri.parse(req.url);

        var hash_buf: [40]u8 = undefined;
        var timestamp_buf: [32]u8 = undefined;
        const timestamp_str = try std.fmt.bufPrint(&timestamp_buf, "{d}", .{std.time.timestamp()});

        if (req.credentials) |creds| {
            // HMAC message: path + ("?" + query if query else "") + timestamp.
            // Body parameters are strictly EXCLUDED. (SPEC §5.3)
            var msg_buf: std.ArrayList(u8) = .{};
            defer msg_buf.deinit(req.allocator);

            const w = msg_buf.writer(req.allocator);

            // 1. Build the path + query string
            try w.print("{s}", .{uri.path.percent_encoded});
            if (uri.query) |q| {
                try w.print("?{s}", .{q.percent_encoded});
            }

            // 2. Normalize the string: %20 -> +, ~ -> %7E
            // Copy to temporary slice then rewrite into msg_buf
            const raw_path_query = try msg_buf.toOwnedSlice(req.allocator);
            defer req.allocator.free(raw_path_query);
            msg_buf.clearRetainingCapacity();

            var i: usize = 0;
            while (i < raw_path_query.len) {
                if (i + 2 < raw_path_query.len and std.mem.eql(u8, raw_path_query[i .. i + 3], "%20")) {
                    try w.writeByte('+');
                    i += 3;
                } else if (raw_path_query[i] == '~') {
                    try w.print("%7E", .{});
                    i += 1;
                } else {
                    try w.writeByte(raw_path_query[i]);
                    i += 1;
                }
            }

            // 3. Generate the hash. buildAuthHeaders will append the timestamp to its own HMAC update.
            const auth_headers = auth.buildAuthHeaders(
                creds.key,
                creds.secret,
                msg_buf.items, // Only normalized path+query
                timestamp_str,
                &hash_buf,
            );

            try headers.appendSlice(req.allocator, &auth_headers);
        }

        // ----------------------------------------------------------------
        // Use client.request() so we can inspect response headers.
        // ----------------------------------------------------------------
        var http_req = client.request(req.method, uri, .{
            .extra_headers = headers.items,
        }) catch |err| {
            if (attempt < req.retries) {
                try sleepForRetry(attempt);
                continue;
            }
            if (!req.quiet) {
                std.debug.print("Connection error: {s}\n", .{@errorName(err)});
            }
            return 1;
        };
        defer http_req.deinit();

        // Send request (with or without body)
        if (req.body) |body_bytes| {
            // sendBodyComplete requires []u8 (mutable); duplicate into mutable memory
            const body_mut = try req.allocator.dupe(u8, body_bytes);
            defer req.allocator.free(body_mut);
            http_req.sendBodyComplete(body_mut) catch |err| {
                if (attempt < req.retries) {
                    try sleepForRetry(attempt);
                    continue;
                }
                if (!req.quiet) std.debug.print("Send error: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else if (req.method.requestHasBody()) {
            http_req.sendBodyComplete(&.{}) catch |err| {
                if (attempt < req.retries) {
                    try sleepForRetry(attempt);
                    continue;
                }
                if (!req.quiet) std.debug.print("Send error: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else {
            http_req.sendBodiless() catch |err| {
                if (attempt < req.retries) {
                    try sleepForRetry(attempt);
                    continue;
                }
                if (!req.quiet) std.debug.print("Send error: {s}\n", .{@errorName(err)});
                return 1;
            };
        }

        // Receive response headers
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = http_req.receiveHead(&redirect_buf) catch |err| {
            if (attempt < req.retries) {
                try sleepForRetry(attempt);
                continue;
            }
            if (!req.quiet) std.debug.print("Response error: {s}\n", .{@errorName(err)});
            return 1;
        };

        const status_uint = @intFromEnum(response.head.status);

        // Retry on gateway errors
        if (status_uint == 502 or status_uint == 503) {
            if (attempt < req.retries) {
                try sleepForRetry(attempt);
                continue;
            }
        }

        // Single pass over response headers to collect all needed information
        // before the response head bytes (borrowed from redirect_buf) may
        // become inaccessible after the body read.
        var content_type_is_json = false;
        var is_gzip = false;

        if (req.verbose) {
            try stdout.print("HTTP/1.1 {d} {s}\n", .{
                status_uint,
                response.head.status.phrase() orelse "",
            });
        }

        var hit = response.head.iterateHeaders();
        while (hit.next()) |hdr| {
            if (req.verbose) {
                try stdout.print("{s}: {s}\n", .{ hdr.name, hdr.value });
            }
            if (req.links and std.ascii.eqlIgnoreCase(hdr.name, "Link")) {
                parseLinkHeader(hdr.value, stdout);
            }
            if (std.ascii.eqlIgnoreCase(hdr.name, "Content-Encoding") and
                std.ascii.eqlIgnoreCase(std.mem.trim(u8, hdr.value, " \t"), "gzip"))
            {
                is_gzip = true;
            }
            if (std.ascii.eqlIgnoreCase(hdr.name, "Content-Type") and
                std.mem.indexOf(u8, hdr.value, "application/json") != null)
            {
                content_type_is_json = true;
            }
        }

        if (req.verbose) {
            try stdout.print("\n", .{});
            try stdout.flush();
        }

        // Also check the structured content_type field as a fallback
        if (!content_type_is_json) {
            if (response.head.content_type) |ct| {
                content_type_is_json = std.mem.indexOf(u8, ct, "application/json") != null;
            }
        }

        if (status_uint < 200 or status_uint >= 300) {
            if (!req.quiet) {
                std.debug.print("{d} {s}\n", .{ status_uint, response.head.status.phrase() orelse "Unknown Error" });
            }
        }

        // Read response body into memory
        var body_aw = std.Io.Writer.Allocating.init(req.allocator);
        defer body_aw.deinit();

        var transfer_buf: [4096]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        _ = body_reader.streamRemaining(&body_aw.writer) catch |err| switch (err) {
            error.ReadFailed => {
                if (!req.quiet) std.debug.print("Read error\n", .{});
                return 1;
            },
            else => |e| return e,
        };

        const raw_body = body_aw.written();

        // Decompress gzip body if Content-Encoding: gzip (server may ignore
        // Accept-Encoding: identity and compress anyway).
        var decompressed_buf: ?[]u8 = null;
        defer if (decompressed_buf) |b| req.allocator.free(b);

        const body_bytes: []const u8 = if (is_gzip) blk: {
            var in: std.Io.Reader = .fixed(raw_body);
            var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
            var out: std.Io.Writer.Allocating = .init(req.allocator);
            defer out.deinit();
            _ = decompress.reader.streamRemaining(&out.writer) catch |err| {
                if (!req.quiet) std.debug.print("Decompression error: {s}\n", .{@errorName(err)});
                return 1;
            };
            decompressed_buf = try req.allocator.dupe(u8, out.written());
            break :blk decompressed_buf.?;
        } else raw_body;

        if (req.pretty and content_type_is_json) {
            var parsed = std.json.parseFromSlice(std.json.Value, req.allocator, body_bytes, .{}) catch null;
            if (parsed) |*p| {
                defer p.deinit();
                try std.json.Stringify.value(p.value, .{ .whitespace = .indent_2 }, stdout);
                try stdout.print("\n", .{});
            } else {
                try stdout.print("{s}\n", .{body_bytes});
            }
        } else {
            try stdout.print("{s}\n", .{body_bytes});
        }
        try stdout.flush();

        return if (status_uint >= 200 and status_uint < 300) 0 else 1;
    }
}

/// Parse a single RFC 5988 Link header value and write each link to `writer`.
/// Format: <url>; rel="name", <url2>; rel="name2"
/// Output: "name: url\n" per link.
pub fn parseLinkHeader(value: []const u8, writer: anytype) void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        // Extract URL between < and >
        const url_start = std.mem.indexOfScalar(u8, trimmed, '<') orelse continue;
        const url_end = std.mem.indexOfScalar(u8, trimmed, '>') orelse continue;
        if (url_end <= url_start) continue;
        const url = trimmed[url_start + 1 .. url_end];

        // Extract rel="..." value
        var rel: []const u8 = "";
        var params = std.mem.splitScalar(u8, trimmed[url_end + 1 ..], ';');
        while (params.next()) |param| {
            const p = std.mem.trim(u8, param, " \t");
            if (std.mem.startsWith(u8, p, "rel=")) {
                var r = p[4..];
                // Strip optional surrounding quotes
                if (r.len >= 2 and r[0] == '"' and r[r.len - 1] == '"') {
                    r = r[1 .. r.len - 1];
                }
                rel = r;
                break;
            }
        }

        if (rel.len > 0) {
            writer.print("{s}: {s}\n", .{ rel, url }) catch {};
        }
    }
}

fn sleepForRetry(attempt: u32) !void {
    const base_str = std.posix.getenv("OPENQA_CLI_RETRY_SLEEP_TIME_S") orelse "3";
    const base: f64 = std.fmt.parseFloat(f64, base_str) catch 3.0;

    const factor_str = std.posix.getenv("OPENQA_CLI_RETRY_FACTOR") orelse "1.0";
    const factor: f64 = std.fmt.parseFloat(f64, factor_str) catch 1.0;

    const delay_s = base * std.math.pow(f64, factor, @floatFromInt(attempt));
    const delay_ns: u64 = @intFromFloat(delay_s * 1_000_000_000.0);
    std.Thread.sleep(delay_ns);
}

test "parseLinkHeader: basic parsing" {
    const testing = std.testing;
    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const header = "<http://example.com/api/v1/jobs?offset=0>; rel=\"first\", <http://example.com/api/v1/jobs?offset=10>; rel=\"next\"";
    parseLinkHeader(header, list.writer());

    try testing.expectEqualStrings(
        "first: http://example.com/api/v1/jobs?offset=0\nnext: http://example.com/api/v1/jobs?offset=10\n",
        list.items,
    );
}

test "execute: bodiless POST/PUT/PATCH does not panic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Start a temporary listener to allow std.http.Client to connect.
    // This allows us to reach the sendBodyComplete/sendBodiless calls.
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    const port = listener.listen_address.getPosixPort();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/jobs", .{port});

    // Accept one connection in a thread to prevent hanging
    const handle = try std.Thread.spawn(.{}, struct {
        fn run(l: *std.net.Server) void {
            var conn = l.accept() catch return;
            defer conn.stream.close();
            // Just read a bit and close; std.http.Client will fail with EndOfStream or Reset,
            // which is fine as long as we don't panic.
            var buf: [1024]u8 = undefined;
            _ = conn.stream.read(&buf) catch {};
        }
    }.run, .{&listener});
    defer handle.join();

    const methods = [_]std.http.Method{ .POST, .PUT, .PATCH };
    for (methods) |m| {
        const req = Request{
            .allocator = allocator,
            .method = m,
            .url = url,
            .headers = &.{},
            .body = null,
            .credentials = null,
            .retries = 0,
            .verbose = false,
            .quiet = true,
            .links = false,
            .pretty = false,
        };

        // If it panics, the test runner will report it.
        // We don't care about the exit code/error (it will likely be 1/EndOfStream),
        // we just want to ensure it doesn't crash.
        _ = try execute(req);
    }
}
