const std = @import("std");
const property_mod = @import("property.zig");
const generator2 = @import("generator.zig");

const property = property_mod.property;
const Property = property_mod.Property;
const PropertyFailure = property_mod.PropertyFailure;

/// Configuration for property assertions
pub const AssertConfig = struct {
    /// Number of bytes to use for testing (more bytes = more test cases)
    /// If null, random bytes will be generated
    bytes: ?[]u8 = null,

    /// Number of runs to attempt (only used if bytes is null)
    runs: u32 = 100,

    /// Whether to print verbose output
    verbose: bool = false,
};

/// Assert that a property holds
/// Returns an error if the property fails
pub fn assert(
    prop: anytype,
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
    const failure_opt = try prop.check(allocator, bytes);

    // Property failed - extract the counterexample
    if (failure_opt) |failure| {
        // Regenerate the counterexample using the same bytes that caused the failure
        var finite_prng = @import("finite_prng").init(failure.failure_bytes.?);
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
    // Create a simple property that always fails with a direct generator
    const intGen = @import("generator.zig").gen(i32, .{ .min = -10, .max = -1 });

    // Property that requires positive values (will always fail with our generator)
    const positiveProperty = property(i32, intGen, struct {
        fn test_(n: i32) bool {
            return n > 0;
        }
    }.test_);

    var bytes: [4096]u8 = undefined;
    @import("test_helpers").load_bytes(&bytes);

    // This should fail since we're generating negative numbers but requiring positive ones
    const result = try assert(positiveProperty, .{ .bytes = &bytes }, std.testing.allocator);
    try std.testing.expect(result != null);
}
