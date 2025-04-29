const std = @import("std");

pub fn load_bytes(buf: []u8) void {
    const current_time = std.time.milliTimestamp();
    var std_prng = std.Random.DefaultPrng.init(@intCast(current_time));
    var std_random = std_prng.random();
    std_random.bytes(buf);
}
