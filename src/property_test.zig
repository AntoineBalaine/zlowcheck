const std = @import("std");
const property_mod = @import("property.zig");
const generator2 = @import("generator.zig");
const FinitePrng = @import("finite_prng");
const load_bytes = @import("test_helpers").load_bytes;

const property = property_mod.property;
const PropertyResult = property_mod.PropertyResult;
const Property = property_mod.Property;
const gen = generator2.gen;

test "property with hooks" {
    // Setup state for hooks
    var setup_called: usize = 0;
    var teardown_called: usize = 0;

    // Create a property with hooks
    var prop = property(i32, gen(i32, .{ .min = 1, .max = 10 }), struct {
        fn test_(n: i32) bool {
            return n > 0; // Always true for our range
        }
    }.test_)
        .beforeEach(&setup_called, struct {
            fn hook(counter: *usize) void {
                counter.* += 1;
            }
        }.hook)
        .afterEach(&teardown_called, struct {
        fn hook(counter: *usize) void {
            counter.* += 1;
        }
    }.hook);

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test
    const result = try prop.check(std.testing.allocator, &bytes);

    // Should succeed (null result means success)
    try std.testing.expectEqual(null, result);

    // Hooks should have been called once per test case
    try std.testing.expectEqual(@as(usize, 1), setup_called);
    try std.testing.expectEqual(@as(usize, 1), teardown_called);
}

// test "reproducing failures" {
//     // Test a property that fails for values < 10
//     const minimalFailingProperty = property(i32, gen(i32, .{ .min = 0, .max = 20 }), struct {
//         fn test_(n: i32) bool {
//             return n >= 10; // Fails for values < 10
//         }
//     }.test_);
//
//     // Use the same hardcoded bytes from generator2_test.zig that reliably produce a value < 10
//     var bytes = [_]u8{ 0x3e, 0x9c, 0xff, 0xd9, 0x72, 0x5b, 0x7e, 0x26, 0x3f, 0xeb, 0x66, 0xdf };
//
//     // Run the property test (should fail)
//     const result = try minimalFailingProperty.check(std.testing.allocator, &bytes);
//
//     // Should fail with a counterexample (non-null result means failure)
//     try std.testing.expect(result != null);
//     try std.testing.expect(result.?.failure_bytes != null);
//     try std.testing.expect(result.?.counterexample != null); // Should have a counterexample
//
//     // The counterexample should be the minimal failing example: < 10
//     if (result.?.counterexample) |counter_ptr| {
//         const counterexample = @as(*const i32, @ptrCast(@alignCast(counter_ptr))).*;
//         try std.testing.expect(counterexample < 10);
//
//         // Now reproduce with the exact same failure bytes
//         if (result.?.failure_bytes) |failure_bytes| {
//             // Create a new FinitePrng with just the failure bytes
//             var prng = FinitePrng.init(failure_bytes);
//             var random = prng.random();
//
//             // Generate the value directly - use the same range as the property
//             const value = try gen(i32, .{ .min = 0, .max = 20 }).generate(&random, std.testing.allocator);
//             defer value.deinit(std.testing.allocator);
//
//             // Should produce the same failing value
//             try std.testing.expectEqual(counterexample, value.value);
//         }
//     }
// }

test "mapped generator with property" {
    // Create a mapped generator that forces odd values
    const intGen = gen(i32, .{ .min = 0, .max = 10 });
    const oddOnlyGen = intGen.map(i32, struct {
        pub fn map(n: i32) i32 {
            // Make sure we always return odd numbers
            return if (@rem(n, 2) == 0) n + 1 else n;
        }
    }.map, null);

    // Property that requires even numbers (should always fail with our generator)
    const evenOnlyProperty = property(i32, oddOnlyGen, struct {
        fn test_(n: i32) bool {
            return @rem(n, 2) == 0; // Will fail since the generator always returns odd numbers
        }
    }.test_);

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test (should fail)
    const result = try evenOnlyProperty.check(std.testing.allocator, &bytes);

    // Should fail with a counterexample (non-null result means failure)
    try std.testing.expect(result != null);

    // The counterexample should be an odd number
    if (result.?.counterexample) |counter_ptr| {
        const counterexample = @as(*const i32, @ptrCast(@alignCast(counter_ptr))).*;
        try std.testing.expect(@rem(counterexample, 2) == 1); // Should be odd
    }
}

test "filtered generator with property" {
    // Create a filtered generator that only allows even values
    const intGen = gen(i32, .{ .min = 0, .max = 100 });
    const evenOnlyGen = intGen.filter(struct {
        pub fn filter(n: i32) bool {
            // Only accept even numbers
            return @rem(n, 2) == 0;
        }
    }.filter);

    // Property that requires odd numbers (should always fail with our generator)
    const oddOnlyProperty = property(i32, evenOnlyGen, struct {
        fn test_(n: i32) bool {
            return @rem(n, 2) == 1; // Will fail since the generator always returns even numbers
        }
    }.test_);

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test (should fail)
    const result = try oddOnlyProperty.check(std.testing.allocator, &bytes);

    // Should fail with a counterexample (non-null result means failure)
    try std.testing.expect(result != null);

    // The counterexample should be an even number
    if (result.?.counterexample) |counter_ptr| {
        const counterexample = @as(*const i32, @ptrCast(@alignCast(counter_ptr))).*;
        try std.testing.expect(@rem(counterexample, 2) == 0); // Should be even
        try std.testing.expect(counterexample >= 0 and counterexample <= 100); // Should be in range
    }
}
