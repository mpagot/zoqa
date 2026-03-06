const std = @import("std");
pub fn main() void {
    const b = undefined;
    const m = std.Build.Module.create(b, .{});
    m.fuzz = true;
}
