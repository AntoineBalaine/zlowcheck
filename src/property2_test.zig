const std = @import("std");
const property_mod = @import("property2.zig");
const generator2 = @import("generator2.zig");
const FinitePrng = @import("byte_slice_prng.zig");
const load_bytes = @import("test_helpers.zig").load_bytes;

const property = property_mod.property;
const PropertyResult = property_mod.PropertyResult;
const Property = property_mod.Property;
const gen = generator2.gen;

test "basic property test (addition commutative)" {
    // Test the commutative property of addition: a + b == b + a
    const TestType = struct { a: i32, b: i32 };
    const commutativeProperty = property(TestType, gen(TestType, .{
        .a = .{ .min = -100, .max = 100 },
        .b = .{ .min = -100, .max = 100 },
    }), struct {
        fn test_(args: TestType) bool {
            return args.a + args.b == args.b + args.a;
        }
    }.test_);

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test (should always succeed)
    const result = try commutativeProperty.check(std.testing.allocator, &bytes);

    // Should be successful
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.num_passed);
}

test "failing property with shrinking (all integers are positive)" {
    // Test the (false) property that all integers are positive
    // Use a smaller range to increase the chance of getting negative values in the test
    const positiveProperty = property(i32, gen(i32, .{ .min = -10, .max = -1 }), struct {
        fn test_(n: i32) bool {
            return n > 0;
        }
    }.test_);

    // Use a hardcoded byte sequence that's known to produce a failing test case
    // These bytes were captured from a previous failing run
    var bytes = [_]u8{ 0xdf, 0x54, 0x30, 0xc0, 0xd9, 0x5c, 0x53, 0x01, 0x58, 0x14, 0xf3, 0x54 };

    // Run the property test (should fail)
    const result = try positiveProperty.check(std.testing.allocator, &bytes);

    // Should fail with a counterexample
    try std.testing.expect(!result.success);

    // The counterexample should be 0 or negative
    try std.testing.expect(result.counterexample != null); // Should have a counterexample
    if (result.counterexample) |counter_ptr| {
        const counterexample = @as(*const i32, @ptrCast(@alignCast(counter_ptr))).*;
        try std.testing.expect(counterexample <= 0);
    }
    try std.testing.expect(result.num_shrinks > 0);
}

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

    // Should succeed
    try std.testing.expect(result.success);

    // Hooks should have been called once per test case
    try std.testing.expectEqual(@as(usize, 1), setup_called);
    try std.testing.expectEqual(@as(usize, 1), teardown_called);
}

test "reproducing failures" {
    // Test a property that fails for values < 10
    const minimalFailingProperty = property(i32, gen(i32, .{ .min = 0, .max = 20 }), struct {
        fn test_(n: i32) bool {
            return n >= 10; // Fails for values < 10
        }
    }.test_);

    // Use the same hardcoded bytes from generator2_test.zig that reliably produce a value < 10
    var bytes = [_]u8{ 0x3e, 0x9c, 0xff, 0xd9, 0x72, 0x5b, 0x7e, 0x26, 0x3f, 0xeb, 0x66, 0xdf };

    // Run the property test (should fail)
    const result = try minimalFailingProperty.check(std.testing.allocator, &bytes);

    // Should fail with a counterexample
    try std.testing.expect(!result.success);
    try std.testing.expect(result.failure_bytes != null);
    try std.testing.expect(result.counterexample != null); // Should have a counterexample

    // The counterexample should be the minimal failing example: < 10
    if (result.counterexample) |counter_ptr| {
        const counterexample = @as(*const i32, @ptrCast(@alignCast(counter_ptr))).*;
        try std.testing.expect(counterexample < 10);

        // Now reproduce with the exact same failure bytes
        if (result.failure_bytes) |failure_bytes| {
            // Create a new FinitePrng with just the failure bytes
            var prng = FinitePrng.init(failure_bytes);
            var random = prng.random();

            // Generate the value directly - use the same range as the property
            const value = try gen(i32, .{ .min = 0, .max = 20 }).generate(&random, std.testing.allocator);
            defer value.deinit(std.testing.allocator);

            // Should produce the same failing value
            try std.testing.expectEqual(counterexample, value.value);
        }
    }
}
