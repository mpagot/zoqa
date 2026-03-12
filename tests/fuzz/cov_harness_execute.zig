const std = @import("std");
const fuzz_execute = @import("fuzz_execute.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <fuzz_input_file>\n", .{args[0]});
        return;
    }

    fuzz_execute.zig_fuzz_init();

    const file_path = args[1];
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    fuzz_execute.zig_fuzz_test(buffer.ptr, @intCast(bytes_read));
}
