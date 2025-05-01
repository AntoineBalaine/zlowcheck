//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

pub fn main() !void {
    _ = lib.gen(i32, .{ .min = 10, .max = 20 });
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("zlowcheck_lib");
