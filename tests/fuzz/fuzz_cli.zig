// Fuzz harness for the CLI argument parser and full request-building pipeline
// (src/main.zig: parseArgs, buildRequest, mergeCredentials).
//
// ---------------------------------------------------------------------------
// Corpus format
// ---------------------------------------------------------------------------
//
// Plain text, one argument per line. Empty lines are ignored.
//
// The special --param-file code path requires a temp file on disk whose
// contents are provided inline in the corpus using a content block. The block
// MUST appear immediately after the KEY=IGNORED line that follows --param-file:
//
//   openQAclient
//   --param-file
//   BUILD=IGNORED
//   ---FILECONTENT---
//   LATEST_SLE15_7
//   ---FILECONTENTEND---
//   api
//   isos
//
// The harness extracts the content between the two markers, writes it to a
// per-process temp file, and rewrites the KEY=IGNORED token to
// KEY=/tmp/openqa_fuzz_param_<pid> before calling parseArgs.
//
// Similarly, --data-file content can be provided inline:
//
//   ---DATAFILECONTENT---
//   {"key":"value"}
//   ---DATAFILECONTENTEND---
//
// The harness extracts this content and passes it as the data_file_content
// parameter to buildRequest, exercising the --data-file body path without
// actual filesystem reads.
//
// ---------------------------------------------------------------------------
// Temp-file lifecycle
// ---------------------------------------------------------------------------
//
// The temp file is created once in zig_fuzz_init (called once per AFL++ worker
// process) and is never deleted — it persists for the process lifetime.
// Each zig_fuzz_test iteration truncate-overwrites it with the new content.
// This avoids per-iteration create/delete overhead on the tmpfs ramdisk.
//
// Path: /tmp/openqa_fuzz_param_<pid>
//
// ---------------------------------------------------------------------------
// Marker lines (excluded from argv)
// ---------------------------------------------------------------------------
//
//   ---FILECONTENT---         start of inline param-file content block
//   ---FILECONTENTEND---      end of inline param-file content block
//   ---DATAFILECONTENT---     start of inline data-file content block
//   ---DATAFILECONTENTEND---  end of inline data-file content block
//
const std = @import("std");
const main_mod = @import("main");

// ---------------------------------------------------------------------------
// Module-level state (written once by zig_fuzz_init, read every iteration)
// ---------------------------------------------------------------------------

/// Null-terminated path buffer: "/tmp/openqa_fuzz_param_<pid>\x00...".
/// Written once by zig_fuzz_init; never modified after that.
var tmp_param_path_buf: [64]u8 = undefined;

/// Slice into tmp_param_path_buf (excludes the null terminator).
var tmp_param_path: []const u8 = &.{};

// ---------------------------------------------------------------------------
// zig_fuzz_init — called once per AFL++ worker process
// ---------------------------------------------------------------------------

export fn zig_fuzz_init() void {
    const pid = std.os.linux.getpid();
    const written = std.fmt.bufPrint(&tmp_param_path_buf, "/tmp/openqa_fuzz_param_{d}", .{pid}) catch return;
    tmp_param_path = written;

    // Pre-create the file so each iteration can open-and-truncate cheaply.
    const file = std.fs.createFileAbsolute(tmp_param_path, .{ .truncate = true }) catch return;
    file.close();
}

// ---------------------------------------------------------------------------
// zig_fuzz_test — called in a tight loop by AFL++ persistent mode
// ---------------------------------------------------------------------------

export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const input = buf[0..@intCast(len)];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // ------------------------------------------------------------------
    // Pass 1: scan for content blocks.
    // ------------------------------------------------------------------
    const FILE_START = "---FILECONTENT---";
    const FILE_END = "---FILECONTENTEND---";
    const DATA_START = "---DATAFILECONTENT---";
    const DATA_END = "---DATAFILECONTENTEND---";

    var file_content: []const u8 = "";
    var has_file_block = false;
    var data_file_content: ?[]const u8 = null;

    // Extract ---FILECONTENT--- block
    if (std.mem.indexOf(u8, input, FILE_START)) |start_pos| {
        const after_start = start_pos + FILE_START.len;
        const content_begin = if (after_start < input.len and input[after_start] == '\n')
            after_start + 1
        else
            after_start;

        if (std.mem.indexOf(u8, input[content_begin..], FILE_END)) |end_rel| {
            const end_pos = content_begin + end_rel;
            const raw_content = input[content_begin..end_pos];
            file_content = std.mem.trimRight(u8, raw_content, "\n\r");
            has_file_block = true;
        }
    }

    // Extract ---DATAFILECONTENT--- block
    if (std.mem.indexOf(u8, input, DATA_START)) |start_pos| {
        const after_start = start_pos + DATA_START.len;
        const content_begin = if (after_start < input.len and input[after_start] == '\n')
            after_start + 1
        else
            after_start;

        if (std.mem.indexOf(u8, input[content_begin..], DATA_END)) |end_rel| {
            const end_pos = content_begin + end_rel;
            const raw_content = input[content_begin..end_pos];
            data_file_content = std.mem.trimRight(u8, raw_content, "\n\r");
        }
    }

    // Write param-file content to the temp file (truncate-overwrite).
    if (has_file_block and tmp_param_path.len > 0) {
        if (std.fs.openFileAbsolute(tmp_param_path, .{ .mode = .write_only })) |f| {
            defer f.close();
            _ = f.setEndPos(0) catch {};
            _ = f.writeAll(file_content) catch {};
        } else |_| {}
    }

    // ------------------------------------------------------------------
    // Pass 2: split on newlines → build raw token list.
    // Skip marker lines; track whether the previous argv token was
    // --param-file so we can rewrite the KEY=IGNORED token.
    // ------------------------------------------------------------------
    var argv: std.ArrayList([]const u8) = .{};

    var prev_was_param_file = false;
    var in_file_block = false;
    var in_data_block = false;

    var line_it = std.mem.splitScalar(u8, input, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;

        // Track entry/exit of content blocks — skip these lines from argv.
        if (std.mem.eql(u8, line, FILE_START)) {
            in_file_block = true;
            continue;
        }
        if (std.mem.eql(u8, line, FILE_END)) {
            in_file_block = false;
            continue;
        }
        if (in_file_block) continue;

        if (std.mem.eql(u8, line, DATA_START)) {
            in_data_block = true;
            continue;
        }
        if (std.mem.eql(u8, line, DATA_END)) {
            in_data_block = false;
            continue;
        }
        if (in_data_block) continue;

        // Rewrite the KEY=IGNORED token that follows --param-file into
        // KEY=/tmp/openqa_fuzz_param_<pid> so parseArgs sees a real path.
        if (prev_was_param_file and has_file_block and tmp_param_path.len > 0) {
            prev_was_param_file = false;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                argv.append(allocator, line) catch return;
                continue;
            };
            const key_part = line[0..eq];
            const rewritten = std.fmt.allocPrint(
                allocator,
                "{s}={s}",
                .{ key_part, tmp_param_path },
            ) catch return;
            argv.append(allocator, rewritten) catch return;
            continue;
        }

        prev_was_param_file = std.mem.eql(u8, line, "--param-file");
        argv.append(allocator, line) catch return;
    }

    if (argv.items.len == 0) return;

    // ------------------------------------------------------------------
    // Call parseArgs
    // ------------------------------------------------------------------
    var parsed = main_mod.parseArgs(allocator, argv.items) catch return;
    defer parsed.headers.deinit(allocator);
    defer parsed.param_files.deinit(allocator);
    defer parsed.kv_params.deinit(allocator);

    // ------------------------------------------------------------------
    // Exercise mergeCredentials (CLI-sourced key/secret only in harness)
    // ------------------------------------------------------------------
    const creds = main_mod.mergeCredentials(
        allocator,
        .{ .key = parsed.apikey, .secret = parsed.apisecret },
        .{ .key = null, .secret = null },
        null,
    ) catch return;
    if (creds) |c| {
        allocator.free(c.key);
        allocator.free(c.secret);
    }

    // ------------------------------------------------------------------
    // Exercise buildRequest — this is the main coverage target.
    // It exercises: isAbsoluteUrl, resolveHost, URL building, method
    // parsing, positional KV encoding, --param-file reading, body
    // assembly (--data, --data-file via data_file_content, params),
    // --form JSON-to-urlencoded, header ':' splitting, Content-Type
    // injection (--json, --form).
    // ------------------------------------------------------------------
    var req_cfg = main_mod.buildRequest(allocator, &parsed, data_file_content) catch return;
    req_cfg.deinit(allocator);
}
