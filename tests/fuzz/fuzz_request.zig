// Fuzz harness for the CLI argument parser, full request-building pipeline,
// RFC 5988 Link header parser, and JSON parse/stringify path
// (src/main.zig: parseArgs, buildRequest; src/root.zig: parseLinkHeader).
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
//   zoqa
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
// Two additional optional content blocks extend the base fuzz_cli format:
//
//   ---LINKHEADER---
//   </api/v1/jobs?page=2>; rel="next"
//   ---LINKHEADEREND---
//
//   ---JSON---
//   {"id":1,"state":"running"}
//   ---JSONEND---
//
// The LINKHEADER block content is fed to parseLinkHeader + LinkIterator.
// The JSON block content is fed to std.json.parseFromSlice + stringify.
// Both blocks are optional — their absence is handled gracefully.
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
//   ---LINKHEADER---          start of Link header content block
//   ---LINKHEADEREND---       end of Link header content block
//   ---JSON---                start of JSON content block
//   ---JSONEND---             end of JSON content block
//
const std = @import("std");
const main_mod = @import("main");
const zoqa = @import("zoqa");

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

pub export fn zig_fuzz_init() void {
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

pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const input = buf[0..@intCast(len)];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // ------------------------------------------------------------------
    // Pass 1: scan for all content blocks.
    // ------------------------------------------------------------------
    const FILE_START = "---FILECONTENT---";
    const FILE_END = "---FILECONTENTEND---";
    const DATA_START = "---DATAFILECONTENT---";
    const DATA_END = "---DATAFILECONTENTEND---";
    const LINK_START = "---LINKHEADER---";
    const LINK_END = "---LINKHEADEREND---";
    const JSON_START = "---JSON---";
    const JSON_END = "---JSONEND---";

    var file_content: []const u8 = "";
    var has_file_block = false;
    var data_file_content: ?[]const u8 = null;
    var link_header_content: ?[]const u8 = null;
    var json_content: ?[]const u8 = null;

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

    // Extract ---LINKHEADER--- block
    if (std.mem.indexOf(u8, input, LINK_START)) |start_pos| {
        const after_start = start_pos + LINK_START.len;
        const content_begin = if (after_start < input.len and input[after_start] == '\n')
            after_start + 1
        else
            after_start;

        if (std.mem.indexOf(u8, input[content_begin..], LINK_END)) |end_rel| {
            const end_pos = content_begin + end_rel;
            const raw_content = input[content_begin..end_pos];
            link_header_content = std.mem.trimRight(u8, raw_content, "\n\r");
        }
    }

    // Extract ---JSON--- block
    if (std.mem.indexOf(u8, input, JSON_START)) |start_pos| {
        const after_start = start_pos + JSON_START.len;
        const content_begin = if (after_start < input.len and input[after_start] == '\n')
            after_start + 1
        else
            after_start;

        if (std.mem.indexOf(u8, input[content_begin..], JSON_END)) |end_rel| {
            const end_pos = content_begin + end_rel;
            const raw_content = input[content_begin..end_pos];
            json_content = std.mem.trimRight(u8, raw_content, "\n\r");
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
    // Skip all marker lines; track --param-file token for path rewriting.
    // ------------------------------------------------------------------
    var argv: std.ArrayList([]const u8) = .{};

    var prev_was_param_file = false;
    var in_file_block = false;
    var in_data_block = false;
    var in_link_block = false;
    var in_json_block = false;

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

        if (std.mem.eql(u8, line, LINK_START)) {
            in_link_block = true;
            continue;
        }
        if (std.mem.eql(u8, line, LINK_END)) {
            in_link_block = false;
            continue;
        }
        if (in_link_block) continue;

        if (std.mem.eql(u8, line, JSON_START)) {
            in_json_block = true;
            continue;
        }
        if (std.mem.eql(u8, line, JSON_END)) {
            in_json_block = false;
            continue;
        }
        if (in_json_block) continue;

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

    // ------------------------------------------------------------------
    // Target 1: parseArgs + buildRequest (core CLI pipeline)
    // ------------------------------------------------------------------
    if (argv.items.len > 0) {
        var parsed = main_mod.parseArgs(allocator, argv.items) catch null;
        if (parsed) |*p| {
            defer p.headers.deinit(allocator);
            defer p.param_files.deinit(allocator);
            defer p.kv_params.deinit(allocator);

            var req_cfg = main_mod.buildRequest(allocator, p, data_file_content) catch null;
            if (req_cfg) |*r| r.deinit(allocator);
        }
    }

    // ------------------------------------------------------------------
    // Target 2: RFC 5988 Link header parser (parseLinkHeader + iterator)
    // ------------------------------------------------------------------
    if (link_header_content) |lh| {
        var it = zoqa.parseLinkHeader(lh);
        while (it.next()) |_| {}
    }

    // ------------------------------------------------------------------
    // Target 3: JSON parse/stringify path (mirrors --pretty output path)
    // ------------------------------------------------------------------
    if (json_content) |jc| {
        if (jc.len > 0) {
            if (std.json.parseFromSlice(std.json.Value, allocator, jc, .{})) |*parsed| {
                defer parsed.deinit();
                var discard_buf: [4096]u8 = undefined;
                var discard: std.Io.Writer.Discarding = .init(&discard_buf);
                std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &discard.writer) catch {};
            } else |_| {}
        }
    }
}
