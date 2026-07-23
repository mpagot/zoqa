const std = @import("std");
const config = @import("config.zig");
const http_client = @import("http_client.zig");

pub const ArchiveOptions = struct {
    with_thumbnails: bool = false,
    asset_size_limit: u64 = 209_715_200, // 200 MiB
    credentials: ?config.Credentials = null,
    quiet: bool = false,
    retries: u32 = 0,
    retry_sleep_s: f64 = 3.0,
    retry_factor: f64 = 1.0,
};

const ProgressWriter = struct {
    out: *std.Io.Writer,
    display_name: []const u8,
    content_length: *?u64,
    bytes_written: u64 = 0,
    last_pct: u64 = 101, // sentinel
    stdout_buf: [256]u8 = undefined,
    writer: std.Io.Writer,

    /// Create a new progress writer that displays download percentage on stdout.
    ///
    /// Parameters:
    /// - `out`: The underlying stdout writer for regular output.
    /// - `name`: Display name for the asset being downloaded.
    /// - `cl`: Pointer to the optional content-length (updated by the HTTP layer).
    /// - `buffer`: Scratch buffer for the writer interface.
    ///
    /// Returns: A configured `ProgressWriter` ready to receive streamed data.
    pub fn init(out: *std.Io.Writer, name: []const u8, cl: *?u64, buffer: []u8) ProgressWriter {
        return .{
            .out = out,
            .display_name = name,
            .content_length = cl,
            .writer = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain },
            },
        };
    }

    /// Flush buffered data to the underlying file writer and update byte progress.
    ///
    /// Parameters:
    /// - `w`: The writer interface whose buffer holds pending data.
    /// - `data`: Scatter-gather slice array to drain.
    /// - `splat`: Repeat count for the last data slice (splatted writes).
    ///
    /// Returns: Number of bytes consumed from `data` beyond the internal buffer.
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ProgressWriter = @alignCast(@fieldParentPtr("writer", w));
        const aux = w.buffered();

        const aux_n = try self.out.writeSplatHeader(aux, data, splat);

        if (aux_n < w.end) {
            self.bytes_written += aux_n;
            const remaining = w.buffer[aux_n..w.end];
            @memmove(w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
            self.updateProgress();
            return 0;
        }

        self.bytes_written += aux.len;
        const n = aux_n - w.end;
        w.end = 0;

        var remaining: usize = n;
        for (data[0 .. data.len - 1]) |slice| {
            if (remaining <= slice.len) {
                self.bytes_written += remaining;
                self.updateProgress();
                return n;
            }
            remaining -= slice.len;
            self.bytes_written += slice.len;
        }

        if (remaining > 0) {
            const pattern = data[data.len - 1];
            _ = pattern; // just counting the bytes towards progress
            self.bytes_written += remaining;
        }

        self.updateProgress();
        return n;
    }

    /// Print the current download percentage to stdout when it changes.
    fn updateProgress(self: *ProgressWriter) void {
        if (self.content_length.*) |total| {
            if (total > 0) {
                const pct = (self.bytes_written * 100) / total;
                if (pct != self.last_pct) {
                    self.last_pct = pct;
                    var stdout_writer = std.fs.File.stdout().writer(&self.stdout_buf);
                    stdout_writer.interface.print(
                        "\rDownloading {s}: {d}%",
                        .{ self.display_name, pct },
                    ) catch {};
                    stdout_writer.interface.flush() catch {};
                }
            }
        }
    }
};

/// Download a file with progress reporting, streaming it to disk.
///
/// Parameters:
/// - `allocator`: Used for HTTP buffers and temporary path construction.
/// - `client`: HTTP client instance (injected for testability).
/// - `host`: Base URL of the openQA instance.
/// - `url_path`: Absolute URL path to fetch (e.g. "/tests/42/asset/iso/foo.iso").
/// - `dest_path`: Local filesystem path to write the downloaded file.
/// - `display_name`: Human-readable name shown in progress output.
/// - `options`: Archive options (credentials, size limit, quiet mode).
///
/// Errors: Returns on any download failure (non-fatal); propagates file I/O errors.
fn downloadFile(
    allocator: std.mem.Allocator,
    client: anytype,
    host: []const u8,
    url_path: []const u8,
    dest_path: []const u8,
    display_name: []const u8,
    options: ArchiveOptions,
) !void {
    var file = try std.fs.cwd().createFile(dest_path, .{});
    var file_ok = false;
    defer {
        file.close();
        if (!file_ok) std.fs.cwd().deleteFile(dest_path) catch {};
    }

    var cl: ?u64 = null;
    var file_buf: [65536]u8 = undefined;
    var file_writer = file.writer(&file_buf);

    var pw_buf: [65536]u8 = undefined;
    var pw = ProgressWriter.init(&file_writer.interface, display_name, &cl, &pw_buf);
    var writer = &pw.writer;

    const result = http_client.openQARawGet(host, url_path, .{
        .allocator = allocator,
        .credentials = options.credentials,
        .size_limit = options.asset_size_limit,
        .quiet = options.quiet,
    }, client, writer, &cl) catch |err| {
        var stdout_buf: [256]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        if (err == error.FileTooLarge) {
            stdout_writer.interface.print("\nAsset {s} exceeds maximum size limit of {d} bytes.\n", .{ display_name, options.asset_size_limit }) catch {};
            stdout_writer.interface.flush() catch {};
        } else {
            stdout_writer.interface.print("\nError downloading {s}: {s}\n", .{ display_name, @errorName(err) }) catch {};
            stdout_writer.interface.flush() catch {};
        }
        return; // continue, not a fatal failure
    };

    try writer.flush();
    try file_writer.interface.flush();

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);

    const code = @intFromEnum(result.status);
    if (code == 404) {
        stdout_writer.interface.print("\nFile not found: {s}\n", .{display_name}) catch {};
        stdout_writer.interface.flush() catch {};
        return; // error.NotFound but continue
    }
    if (code < 200 or code >= 300) {
        stdout_writer.interface.print("\nDownload failed for {s}: HTTP {d}\n", .{ display_name, code }) catch {};
        stdout_writer.interface.flush() catch {};
        return; // error.DownloadFailed but continue
    }

    file_ok = true;
    stdout_writer.interface.print("\n", .{}) catch {};
    stdout_writer.interface.flush() catch {};
}

/// Download a file silently (no progress output), used for screenshots and thumbnails.
///
/// Parameters:
/// - `allocator`: Used for HTTP buffers.
/// - `client`: HTTP client instance.
/// - `host`: Base URL of the openQA instance.
/// - `url_path`: Absolute URL path to fetch.
/// - `dest_path`: Local filesystem path to write the downloaded file.
/// - `options`: Archive options (credentials, size limit, quiet mode).
///
/// Errors: Returns on any download failure (non-fatal); propagates file I/O errors.
fn downloadFileNoProgress(
    allocator: std.mem.Allocator,
    client: anytype,
    host: []const u8,
    url_path: []const u8,
    dest_path: []const u8,
    options: ArchiveOptions,
) !void {
    var file = try std.fs.cwd().createFile(dest_path, .{});
    var file_ok = false;
    defer {
        file.close();
        if (!file_ok) std.fs.cwd().deleteFile(dest_path) catch {};
    }

    var buf: [65536]u8 = undefined;
    var fw = file.writer(&buf);
    const result = http_client.openQARawGet(host, url_path, .{
        .allocator = allocator,
        .credentials = options.credentials,
        .size_limit = options.asset_size_limit,
        .quiet = options.quiet,
    }, client, &fw.interface, null) catch {
        return; // ignore failure for screenshots
    };

    try fw.interface.flush();
    const code = @intFromEnum(result.status);
    if (code < 200 or code >= 300) return;
    file_ok = true;
}

/// Process a single test result detail entry (screenshot or inline text).
///
/// Parameters:
/// - `allocator`: Used for path construction and HTTP buffers.
/// - `client`: HTTP client instance.
/// - `host`: Base URL of the openQA instance.
/// - `resultdir`: Local testresults directory path.
/// - `item`: JSON object map for one detail entry (has "screenshot" or "text" key).
/// - `options`: Archive options (credentials, thumbnails, quiet mode).
///
/// Errors: Propagates allocation and file I/O errors; HTTP failures are non-fatal.
fn downloadTestResultDetail(
    allocator: std.mem.Allocator,
    client: anytype,
    host: []const u8,
    resultdir: []const u8,
    item: std.json.ObjectMap,
    options: ArchiveOptions,
) !void {
    if (item.get("screenshot")) |sc_val| {
        const screenshot = switch (sc_val) {
            .string => |s| s,
            else => return,
        };

        const md5_dir: []const u8 = blk: {
            if (item.get("md5_dirname")) |v| {
                if (v == .string) break :blk v.string;
            }
            const md5_1 = switch (item.get("md5_1") orelse return) {
                .string => |s| s,
                else => return,
            };
            const md5_2 = switch (item.get("md5_2") orelse return) {
                .string => |s| s,
                else => return,
            };
            break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ md5_1, md5_2 });
        };
        defer if (item.get("md5_dirname") == null or item.get("md5_dirname").? != .string) {
            allocator.free(md5_dir);
        };

        const md5_basename = switch (item.get("md5_basename") orelse return) {
            .string => |s| s,
            else => return,
        };

        const url_path = try std.fmt.allocPrint(allocator, "/image/{s}/{s}", .{ md5_dir, md5_basename });
        defer allocator.free(url_path);
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resultdir, screenshot });
        defer allocator.free(dest);
        downloadFileNoProgress(allocator, client, host, url_path, dest, options) catch {};

        if (options.with_thumbnails) {
            const thumb_url = try std.fmt.allocPrint(allocator, "/image/{s}/.thumbs/{s}", .{ md5_dir, md5_basename });
            defer allocator.free(thumb_url);
            const thumb_dest = try std.fmt.allocPrint(allocator, "{s}/thumbnails/{s}", .{ resultdir, md5_basename });
            defer allocator.free(thumb_dest);
            downloadFileNoProgress(allocator, client, host, thumb_url, thumb_dest, options) catch {};
        }
    } else if (item.get("text")) |text_val| {
        const filename = switch (text_val) {
            .string => |s| s,
            else => return,
        };
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resultdir, filename });
        defer allocator.free(dest);
        const content: []const u8 = if (item.get("text_data")) |td| switch (td) {
            .string => |s| s,
            else => "No data\n",
        } else "No data\n";
        var file = try std.fs.cwd().createFile(dest, .{});
        defer file.close();
        var buf: [512]u8 = undefined;
        var fw = file.writer(&buf);
        try fw.interface.writeAll(content);
        try fw.interface.flush();
    }
}

/// Download job assets from an openQA instance and archive them locally.
///
/// Fetches the asset list for the given job, then downloads each asset
/// (respecting include/exclude filters) into the specified output directory.
///
/// Parameters:
/// - `allocator`: General-purpose allocator for HTTP buffers and path construction.
/// - `client`: HTTP client (injected; supports `anytype` for testability).
/// - `host`: Base URL of the openQA instance (e.g. "https://openqa.opensuse.org").
/// - `job_id`: Numeric job ID whose assets to download.
/// - `output_path`: Local directory to write archived assets into.
/// - `options`: Archive options (credentials, retry config, filters, verbosity).
///
/// Returns: void on success.
///
/// Errors: HTTP failures, file I/O errors, JSON parse errors, or allocation failures.
pub fn runArchive(
    allocator: std.mem.Allocator,
    client: anytype,
    host: []const u8,
    job_id: u64,
    output_path: []const u8,
    options: ArchiveOptions,
) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const detail_path = try std.fmt.allocPrint(allocator, "jobs/{d}/details", .{job_id});
    defer allocator.free(detail_path);

    const resp = http_client.openQAReq(host, detail_path, .{
        .allocator = allocator,
        .credentials = options.credentials,
        .retries = options.retries,
        .quiet = options.quiet,
        .retry_sleep_s = options.retry_sleep_s,
        .retry_factor = options.retry_factor,
    }, client) catch {
        return error.JobDetailsFailed;
    };
    defer resp.deinit();

    const status_code = @intFromEnum(resp.status);
    if (status_code != 200) {
        try stdout.print("Failed to fetch job details for {d} (HTTP {d})\n", .{ job_id, status_code });
        try stdout.flush();
        return error.JobDetailsFailed;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
    defer parsed.deinit();

    const job = switch (parsed.value) {
        .object => |o| o.get("job") orelse return error.MissingJob,
        else => return error.MissingJob,
    };
    const job_obj = switch (job) {
        .object => |o| o,
        else => return error.MissingJob,
    };

    try std.fs.cwd().makePath(output_path);

    if (job_obj.get("assets")) |assets| {
        if (assets == .object) {
            var asset_it = assets.object.iterator();
            while (asset_it.next()) |entry| {
                const type_name = entry.key_ptr.*;
                if (std.mem.eql(u8, type_name, "repo")) continue;

                try stdout.print("Attempt {s} download:\n", .{type_name});
                try stdout.flush();

                const type_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_path, type_name });
                defer allocator.free(type_dir);
                try std.fs.cwd().makePath(type_dir);

                if (entry.value_ptr.* == .array) {
                    for (entry.value_ptr.array.items) |fname_val| {
                        if (fname_val == .string) {
                            const fname = fname_val.string;
                            const url_path = try std.fmt.allocPrint(allocator, "/tests/{d}/asset/{s}/{s}", .{ job_id, type_name, fname });
                            defer allocator.free(url_path);
                            const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ type_dir, fname });
                            defer allocator.free(dest);
                            downloadFile(allocator, client, host, url_path, dest, fname, options) catch {};
                        }
                    }
                }
            }
        }
    }

    if (job_obj.get("testresults")) |testresults_val| {
        if (testresults_val == .array) {
            const resultdir = try std.fmt.allocPrint(allocator, "{s}/testresults", .{output_path});
            defer allocator.free(resultdir);

            try stdout.print("Downloading test details and screenshots to {s}\n", .{resultdir});
            try stdout.flush();

            const ulogs_dir = try std.fmt.allocPrint(allocator, "{s}/ulogs", .{resultdir});
            defer allocator.free(ulogs_dir);

            try std.fs.cwd().makePath(resultdir);
            try std.fs.cwd().makePath(ulogs_dir);
            if (options.with_thumbnails) {
                const thumbs_dir = try std.fmt.allocPrint(allocator, "{s}/thumbnails", .{resultdir});
                defer allocator.free(thumbs_dir);
                try std.fs.cwd().makePath(thumbs_dir);
            }

            for (testresults_val.array.items) |tr_val| {
                if (tr_val == .object) {
                    const tr = tr_val.object;
                    if (tr.get("name")) |name_val| {
                        if (name_val == .string) {
                            const name = name_val.string;
                            const json_path = try std.fmt.allocPrint(allocator, "{s}/details-{s}.json", .{ resultdir, name });
                            defer allocator.free(json_path);
                            // JSON formatting note: std.json.Stringify with default
                            // options produces minified JSON, preserves parse-order
                            // keys, and does NOT escape forward slashes.
                            // The Perl reference (Mojo::JSON::encode_json) uses
                            // Cpanel::JSON::XS with ->escape_slash and ->canonical,
                            // which writes '/' as '\/' and sorts keys alphabetically.
                            // Both are valid JSON per RFC 8259 §7 (solidus escaping
                            // is optional).  The outputs are semantically equivalent:
                            //   jq . perl_details.json == jq . zig_details.json
                            {
                                var file = try std.fs.cwd().createFile(json_path, .{});
                                defer file.close();
                                var buf: [4096]u8 = undefined;
                                var fw = file.writer(&buf);
                                try std.json.Stringify.value(tr_val, .{}, &fw.interface);
                                try fw.interface.flush();
                            }
                            try stdout.print("Saved details for {s}\n", .{json_path});
                            try stdout.flush();

                            if (tr.get("details")) |details_val| {
                                if (details_val == .array) {
                                    for (details_val.array.items) |item_val| {
                                        if (item_val == .object) {
                                            downloadTestResultDetail(allocator, client, host, resultdir, item_val.object, options) catch {};
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (job_obj.get("logs")) |logs_val| {
        if (logs_val == .array) {
            try stdout.print("Downloading logs\n", .{});
            try stdout.flush();

            const resultdir = try std.fmt.allocPrint(allocator, "{s}/testresults", .{output_path});
            defer allocator.free(resultdir);
            try std.fs.cwd().makePath(resultdir);

            for (logs_val.array.items) |fname_val| {
                if (fname_val == .string) {
                    const fname = fname_val.string;
                    const url_path = try std.fmt.allocPrint(allocator, "/tests/{d}/file/{s}", .{ job_id, fname });
                    defer allocator.free(url_path);
                    const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resultdir, fname });
                    defer allocator.free(dest);
                    downloadFile(allocator, client, host, url_path, dest, fname, options) catch {};
                }
            }
        }
    }

    if (job_obj.get("ulogs")) |ulogs_val| {
        if (ulogs_val == .array) {
            try stdout.print("Downloading ulogs\n", .{});
            try stdout.flush();

            const resultdir = try std.fmt.allocPrint(allocator, "{s}/testresults", .{output_path});
            defer allocator.free(resultdir);
            const ulogs_dir = try std.fmt.allocPrint(allocator, "{s}/ulogs", .{resultdir});
            defer allocator.free(ulogs_dir);
            try std.fs.cwd().makePath(resultdir);
            try std.fs.cwd().makePath(ulogs_dir);

            for (ulogs_val.array.items) |fname_val| {
                if (fname_val == .string) {
                    const fname = fname_val.string;
                    const url_path = try std.fmt.allocPrint(allocator, "/tests/{d}/file/{s}", .{ job_id, fname });
                    defer allocator.free(url_path);
                    const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ulogs_dir, fname });
                    defer allocator.free(dest);
                    downloadFile(allocator, client, host, url_path, dest, fname, options) catch {};
                }
            }
        }
    }
}
