//! Small filesystem helpers and the file-backend abstraction used by
//! `http_client.openQADownloadToFile`.
//!
//! The `FileBackend` interface isolates the four filesystem operations
//! that the download-to-file state machine needs (stat, create, delete,
//! touch) from the HTTP/streaming logic. Production code passes
//! `RealFileBackend`; unit tests pass an in-memory mock. The backend
//! is injected via `anytype` so the compiler monomorphizes per call site:
//! the production binary inlines the real backend's methods (zero
//! indirection, zero vtable, zero runtime penalty) and dead-code-eliminates
//! the mock instantiation.

const std = @import("std");

/// Update a file's access and modification times to the current system time.
///
/// Called after a successful download or a skip-if-complete to delay openQA's
/// asset-cleanup cron. On a fresh write the filesystem already stamps
/// mtime to now, so the touch is only *observable* on the skip path.
///
/// Parameters:
///   - path: filesystem path of the file to touch (relative to the cwd).
///
/// Errors: returns an error if the file cannot be opened for writing or its
/// timestamps cannot be updated.
pub fn touchFile(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const now_ns: i128 = std.time.nanoTimestamp();
    try file.updateTimes(now_ns, now_ns);
}

/// Filesystem backend for `openQADownloadToFile`.
///
/// Any struct that provides these four methods satisfies the interface
/// (duck typing via `anytype`). The backend is responsible for the file
/// *lifecycle* (does it exist? create/truncate it, delete it, touch it). The
/// *data path* (writing the streamed body, updating timestamps) is
/// handled by the `FileSink` returned from `create`.
///
/// Methods:
///   - `stat(path)`: return the file's size, or null if it does not exist.
///   - `create(path)`: create or truncate the file, returning a `FileSink`.
///   - `delete(path)`: remove the file. Errors are ignored (best-effort).
///   - `touch(path)`: update the file's mtime to now (skip-if-complete path).
pub const RealFileBackend = struct {
    /// Return the file size, or null if the path does not exist or cannot
    /// be stat'ed.
    ///
    /// Parameters:
    ///   - path: filesystem path to stat (relative to the cwd).
    ///
    /// Returns: the file size in bytes, or null if the path is missing.
    ///
    /// Errors: none (stat failures are swallowed and reported as null).
    pub fn stat(path: []const u8) !?u64 {
        const st = std.fs.cwd().statFile(path) catch return null;
        return st.size;
    }

    /// Create or truncate the file at `path` and return a `RealFileSink`.
    ///
    /// Parameters:
    ///   - path: filesystem path to create (relative to the cwd).
    ///
    /// Returns: a `RealFileSink` wrapping the newly created file.
    ///
    /// Errors: propagates `std.fs.File.createFile` errors.
    pub fn create(path: []const u8) !RealFileSink {
        const file = try std.fs.cwd().createFile(path, .{});
        return RealFileSink{ .file = file };
    }

    /// Delete the file at `path`. Errors are ignored (best-effort cleanup).
    ///
    /// Parameters:
    ///   - path: filesystem path to delete (relative to the cwd).
    pub fn delete(path: []const u8) void {
        std.fs.cwd().deleteFile(path) catch {};
    }

    /// Update the file's mtime to now (skip-if-complete path).
    ///
    /// Parameters:
    ///   - path: filesystem path to touch (relative to the cwd).
    ///
    /// Errors: propagates `touchFile` errors.
    pub fn touch(path: []const u8) !void {
        try touchFile(path);
    }
};

/// A writable file sink: the data-path half of the file backend.
///
/// The `openQADownloadToFile` state machine calls these methods on the
/// sink returned by `backend.create()`. Production uses `RealFileSink`
/// (wraps a real `std.fs.File`); unit tests use an in-memory sink.
///
/// The sink is a handle: the caller must not copy it after calling
/// `writer()`, because the returned `*std.Io.Writer` points into the
/// sink's own `fw` field.
///
/// Methods:
///   - `writer(buf)`: return a `*std.Io.Writer` over the sink.
///   - `writeError()`: the last disk write error, if any (checked after
///     a stream failure to distinguish disk-full from network errors).
///   - `updateTimes(atime, mtime)`: set file timestamps.
///   - `close()`: flush and close the underlying file.
pub const RealFileSink = struct {
    file: std.fs.File,
    fw: std.fs.File.Writer = undefined,

    /// Return a buffered writer over the underlying file.
    ///
    /// Parameters:
    ///   - buf: stack-allocated buffer used for write buffering.
    ///
    /// Returns: a pointer to the sink's internal `std.Io.Writer` interface.
    pub fn writer(self: *RealFileSink, buf: []u8) *std.Io.Writer {
        self.fw = self.file.writer(buf);
        return &self.fw.interface;
    }

    /// Return the last disk write error, if any.
    ///
    /// Returns: the error stashed by the file writer (e.g. `NoSpaceLeft`),
    /// or null if no write error has occurred.
    pub fn writeError(self: *RealFileSink) ?anyerror {
        return self.fw.err;
    }

    /// Set the file's access and modification times.
    ///
    /// Parameters:
    ///   - atime_ns: access time in nanoseconds since epoch.
    ///   - mtime_ns: modification time in nanoseconds since epoch.
    ///
    /// Errors: propagates `std.fs.File.updateTimes` errors.
    pub fn updateTimes(self: *RealFileSink, atime_ns: u64, mtime_ns: u64) !void {
        try self.file.updateTimes(@as(i128, @intCast(atime_ns)), @as(i128, @intCast(mtime_ns)));
    }

    /// Close the underlying file.
    pub fn close(self: *RealFileSink) void {
        self.file.close();
    }
};

// ---------------------------------------------------------------------------
// Unit tests
//
// These tests exercise the real filesystem via /tmp with unique paths
// (millisecond timestamp mod 1e6 + per-process counter) and clean up after
// themselves. They are the only tests in
// this file that touch the real FS; all other tests in the codebase use
// in-memory mocks.
// ---------------------------------------------------------------------------

const testing = std.testing;

const MockFileSink = struct {
    aw: std.Io.Writer.Allocating,
    updated: bool = false,
    write_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) MockFileSink {
        return .{ .aw = .init(allocator) };
    }

    pub fn writer(self: *MockFileSink, _: []u8) *std.Io.Writer {
        return &self.aw.writer;
    }

    pub fn writeError(self: *MockFileSink) ?anyerror {
        return self.write_error;
    }

    pub fn updateTimes(self: *MockFileSink, _: u64, _: u64) !void {
        self.updated = true;
    }

    pub fn close(_: *MockFileSink) void {}

    pub fn deinit(self: *MockFileSink) void {
        self.aw.deinit();
    }

    pub fn written(self: *MockFileSink) []const u8 {
        return self.aw.writer.buffered();
    }
};

const MockFileBackend = struct {
    stat_size: ?u64 = null,
    sink: MockFileSink,
    touch_count: usize = 0,
    deleted: bool = false,

    pub fn init(allocator: std.mem.Allocator) MockFileBackend {
        return .{ .sink = .init(allocator) };
    }

    pub fn stat(self: *MockFileBackend, _: []const u8) !?u64 {
        return self.stat_size;
    }

    pub fn create(self: *MockFileBackend, _: []const u8) !*MockFileSink {
        self.sink.aw.clearRetainingCapacity();
        self.sink.updated = false;
        return &self.sink;
    }

    pub fn delete(self: *MockFileBackend, _: []const u8) void {
        self.deleted = true;
    }

    pub fn touch(self: *MockFileBackend, _: []const u8) !void {
        self.touch_count += 1;
    }
};

var fs_test_counter: u32 = 0;

fn uniqueTmpPath() []const u8 {
    fs_test_counter += 1;
    return std.fmt.allocPrint(
        testing.allocator,
        "zoqa_fs_test_{d}_{d}",
        .{ @as(u32, @intCast(@mod(std.time.milliTimestamp(), 1_000_000))), fs_test_counter },
    ) catch unreachable;
}

// Fixed past timestamp (2001-09-09) used to backdate files, so a touch that
// does nothing leaves the mtime here and the test fails.
const old_ns: i128 = 1_000_000_000 * std.time.ns_per_s;

/// Assert that `mtime` was set to "now" by a touch that started at `start_ns`.
/// One second of slack covers filesystems with coarse timestamp granularity.
fn expectTouched(mtime: i128, start_ns: i128) !void {
    try testing.expect(mtime > old_ns);
    try testing.expect(mtime >= start_ns - std.time.ns_per_s);
}

test "touchFile: updates mtime on an existing file" {
    const allocator = testing.allocator;
    var backend = MockFileBackend.init(allocator);
    defer backend.sink.deinit();

    try backend.touch("test_path");
    try testing.expectEqual(@as(usize, 1), backend.touch_count);

    try backend.touch("test_path");
    try testing.expectEqual(@as(usize, 2), backend.touch_count);
}

test "RealFileBackend.stat: returns size for existing file, null for missing" {
    const path = uniqueTmpPath();
    defer testing.allocator.free(path);

    // Missing path → null.
    try testing.expect(try RealFileBackend.stat(path) == null);

    // Create a file with known content.
    var file = std.fs.cwd().createFile(path, .{}) catch unreachable;
    file.writeAll("12345678") catch unreachable;
    file.close();

    // Existing path → size.
    try testing.expectEqual(@as(?u64, 8), try RealFileBackend.stat(path));

    std.fs.cwd().deleteFile(path) catch {};
}

test "RealFileBackend.create: sink writer writes + flushes, close closes fd" {
    const path = uniqueTmpPath();
    defer testing.allocator.free(path);

    var sink = try RealFileBackend.create(path);
    defer sink.close();

    var buf: [64]u8 = undefined;
    const w = sink.writer(&buf);
    w.writeAll("hello world") catch unreachable;
    w.flush() catch unreachable;

    // Verify the file on disk has the expected content.
    const st = std.fs.cwd().statFile(path) catch unreachable;
    try testing.expectEqual(@as(u64, 11), st.size);

    var rf = std.fs.cwd().openFile(path, .{}) catch unreachable;
    defer rf.close();
    var content_buf: [64]u8 = undefined;
    const n = rf.readAll(&content_buf) catch unreachable;
    try testing.expectEqualStrings("hello world", content_buf[0..n]);
}

test "RealFileBackend.create: writes larger than the buffer drain mid-stream" {
    const path = uniqueTmpPath();
    defer testing.allocator.free(path);
    // Registered before the sink's close, so it runs after it.
    defer std.fs.cwd().deleteFile(path) catch {};

    var sink = try RealFileBackend.create(path);
    defer sink.close();

    // 200 bytes of a repeating pattern through a 64-byte buffer: the writer
    // must drain to the file several times before the final flush, and the
    // pattern catches lost or reordered chunks.
    var expected: [200]u8 = undefined;
    for (&expected, 0..) |*b, i| b.* = @as(u8, @intCast('a' + i % 26));

    var buf: [64]u8 = undefined;
    const w = sink.writer(&buf);
    var pos: usize = 0;
    while (pos < expected.len) : (pos += 10) {
        w.writeAll(expected[pos .. pos + 10]) catch unreachable;
    }

    // Bytes already on disk before any flush prove drain ran mid-stream.
    const st_before_flush = std.fs.cwd().statFile(path) catch unreachable;
    try testing.expect(st_before_flush.size > 0);
    try testing.expect(sink.writeError() == null);

    w.flush() catch unreachable;

    var rf = std.fs.cwd().openFile(path, .{}) catch unreachable;
    defer rf.close();
    var content_buf: [256]u8 = undefined;
    const n = rf.readAll(&content_buf) catch unreachable;
    try testing.expectEqualSlices(u8, &expected, content_buf[0..n]);
}

test "RealFileBackend.delete: removes the file" {
    const path = uniqueTmpPath();
    defer testing.allocator.free(path);

    // Create the file.
    var file = std.fs.cwd().createFile(path, .{}) catch unreachable;
    file.writeAll("data") catch unreachable;
    file.close();

    // Verify it exists.
    try testing.expect(try RealFileBackend.stat(path) != null);

    // Delete it.
    RealFileBackend.delete(path);

    // Verify it is gone.
    try testing.expect(try RealFileBackend.stat(path) == null);
}

test "RealFileBackend.touch: updates mtime" {
    const path = uniqueTmpPath();
    defer testing.allocator.free(path);

    // Create the file and backdate it.
    var file = std.fs.cwd().createFile(path, .{}) catch unreachable;
    file.writeAll("x") catch unreachable;
    file.updateTimes(old_ns, old_ns) catch unreachable;
    file.close();

    const start_ns = std.time.nanoTimestamp();
    try RealFileBackend.touch(path);

    const st_after = std.fs.cwd().statFile(path) catch unreachable;
    try expectTouched(st_after.mtime, start_ns);

    std.fs.cwd().deleteFile(path) catch {};
}
