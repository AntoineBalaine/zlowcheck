const std = @import("std");
const property_mod = @import("property2.zig");
const generator2 = @import("generator2.zig");

const property = property_mod.property;
const Property = property_mod.Property;
const PropertyFailure = property_mod.PropertyFailure;

/// Configuration for property assertions
pub const AssertConfig = struct {
    /// Number of bytes to use for testing (more bytes = more test cases)
    /// If null, random bytes will be generated
    bytes: ?[]const u8 = null,

    /// Number of runs to attempt (only used if bytes is null)
    runs: u32 = 100,

    /// Whether to print verbose output
    verbose: bool = false,
};

/// Assert that a property holds
/// Returns an error if the property fails
pub fn assert(
    comptime T: type,
    prop: Property(T),
    config: AssertConfig,
    allocator: std.mem.Allocator,
) !?property_mod.PropertyResult {
    // Determine if we're using provided bytes or generating random ones
    const using_provided_bytes = config.bytes != null;
    const bytes = if (using_provided_bytes)
        config.bytes.?
    else blk: {
        // Generate random bytes based on the number of runs
        const bytes_len = config.runs * 32; // Reasonable amount of entropy per run
        const random_bytes = try allocator.alloc(u8, bytes_len);
        std.crypto.random.bytes(random_bytes);
        break :blk random_bytes;
    };

    // Free the bytes if we generated them
    defer if (!using_provided_bytes) allocator.free(bytes);

    // Run the property check
    const res = try prop.check(allocator, bytes);
    const failure_opt = if (!res.success) res else null;

    // Property failed - extract the counterexample
    if (failure_opt) |failure| {
        // Regenerate the counterexample using the same bytes that caused the failure
        var finite_prng = @import("byte_slice_prng.zig").init(bytes[failure.start_offset.?..failure.end_offset.?]);
        var random_for_example = finite_prng.random();

        // Generate the counterexample value
        const example = try prop.generator.generate(&random_for_example, allocator);

        // Print failure information to stderr
        const stderr = std.io.getStdErr().writer();
        try stderr.print("\n❌ Property failed\n", .{});
        try stderr.print("Counterexample: {any}\n", .{example});
        try stderr.print("Found after {} shrinking steps\n", .{failure.num_shrinks});

        return failure;
    }
    return null;
}

test assert {
    // Create a property that passes only for even numbers
    const evenOnly = property(i32, @import("generator2.zig").gen(i32, .{}), struct {
        fn test_(n: i32) bool {
            return @rem(n, 2) == 0;
        }
    }.test_);

    var bytes: [4096]u8 = undefined;
    @import("test_helpers.zig").load_bytes(&bytes);

    const result = try assert(i32, evenOnly, .{ .runs = 1000, .bytes = &bytes }, std.testing.allocator);
    try std.testing.expect(result != null);
}
