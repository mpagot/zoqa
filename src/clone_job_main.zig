const std = @import("std");

pub fn main() !void {
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    try stdout.interface.writeAll("zoqa-clone-job: stub (not yet implemented)\n");
    try stdout.interface.flush();
}
