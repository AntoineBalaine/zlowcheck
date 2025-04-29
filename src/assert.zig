const std = @import("std");
const property_mod = @import("property.zig");
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
) !void {
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
    if (!using_provided_bytes) {
        defer allocator.free(bytes);
    }

    // Run the property check
    const failure_opt = try prop.check(allocator, bytes);

    // If the property passed, we're done
    if (failure_opt == null) {
        if (config.verbose) {
            std.debug.print("✅ Property passed\n", .{});
        }
        return;
    }

    // Property failed - extract the counterexample
    if (failure_opt) |failure| {
        // Regenerate the counterexample using the same bytes that caused the failure
        var finite_prng = @import("byte_slice_prng.zig").init(bytes[failure.start_offset..failure.end_offset]);
        var random_for_example = finite_prng.random();

        // Generate the counterexample value
        const example = try prop.generator.generate(&random_for_example, allocator);

        // Print failure information to stderr
        const stderr = std.io.getStdErr().writer();
        try stderr.print("\n❌ Property failed\n", .{});
        try stderr.print("Counterexample: {any}\n", .{example});
        try stderr.print("Found after {} shrinking steps\n", .{failure.shrink_count});

        return error.PropertyTestFailed;
    }
}
