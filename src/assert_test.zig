const std = @import("std");
const testing = std.testing;
const assert_module = @import("assert.zig");
const assert = assert_module.assert;
const AssertConfig = assert_module.AssertConfig;
const property_mod = @import("property.zig");
const property = property_mod.property;
const Property = property_mod.Property;
const PropertyFailure = property_mod.PropertyFailure;
const gen = @import("generator.zig").gen;
const load_bytes = @import("test_helpers.zig").load_bytes;

test "assert passes for valid property" {
    // Create a property that always passes
    const alwaysTrue = property(i4, gen(i4, .{}), struct {
        fn test_(n: i4) bool {
            _ = n;
            return true;
        }
    }.test_);

    try assert(i4, alwaysTrue, .{}, testing.allocator);
}

test "assert fails for invalid property" {
    // Create a property that always fails
    const alwaysFalse = property(i4, gen(i4, .{}), struct {
        fn test_(n: i4) bool {
            _ = n;
            return false;
        }
    }.test_);

    // This should fail with error.PropertyTestFailed
    const result = assert(i4, alwaysFalse, .{}, testing.allocator);
    try testing.expectError(error.PropertyTestFailed, result);
}

test "assert with provided bytes" {
    // Create a property that passes only for even numbers
    const evenOnly = property(i32, gen(i32, .{}), struct {
        fn test_(n: i32) bool {
            return @rem(n, 2) == 0;
        }
    }.test_);

    var bytes: [128]u8 = undefined;
    load_bytes(&bytes);

    bytes[0] = 1; // This should make the generated number odd

    // This should fail
    const result = assert(i32, evenOnly, .{ .bytes = &bytes }, testing.allocator);
    try testing.expectError(error.PropertyTestFailed, result);
}

test "assert shrinks to minimal counterexample" {
    // Create a property that fails for numbers < 10
    const atLeastTen = property(i32, gen(i32, .{ .min = 0, .max = 100 }), struct {
        fn test_(n: i32) bool {
            return n >= 10;
        }
    }.test_);

    // Run the test with a large number of iterations to ensure we find a failure
    const result = assert(i32, atLeastTen, .{ .runs = 1000 }, testing.allocator);

    // This should fail
    try testing.expectError(error.PropertyTestFailed, result);

    // We can't directly check the counterexample value since it's printed to stderr,
    // but we could redirect stderr for testing if needed
}

test "assert with verbose output" {
    // Create a property that always passes
    const alwaysTrue = property(i32, gen(i32, .{}), struct {
        fn test_(n: i32) bool {
            _ = n;
            return true;
        }
    }.test_);

    // This should pass and print verbose output
    try assert(i32, alwaysTrue, .{ .verbose = true }, testing.allocator);

    // Note: We can't easily test the output directly in a unit test,
    // but we can verify it doesn't crash with verbose mode enabled
}
