const std = @import("std");
const generator = @import("generator.zig");
const property_mod = @import("property.zig");
const property = property_mod.property;
const Property = property_mod.Property;
const PropertyFailure = property_mod.PropertyFailure;
const ByteRange = property_mod.ByteRange;
const ByteSlicePrng = @import("../finite_prng.zig");
const load_bytes = @import("../test_helpers.zig").load_bytes;
const gen = generator.gen;
const Generator = generator.Generator;

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

    // Should be null (no counterexample)
    try std.testing.expectEqual(@as(?PropertyFailure, null), result);
}

test "failing property with shrinking (all integers are positive)" {
    // Test the (false) property that all integers are positive
    const positiveProperty = property(i32, gen(i32, .{ .min = -100, .max = 0 }), struct {
        fn test_(n: i32) bool {
            return n > 0;
        }
    }.test_);

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test (should fail)
    const result = try positiveProperty.check(std.testing.allocator, &bytes);

    // Should fail with a counterexample
    try std.testing.expect(result != null);

    // Check that some shrinking occurred
    if (result) |failure| {
        try std.testing.expect(failure.shrink_count > 0);
    }
}

test "property finds minimal failing example" {
    // Test a property that should fail for values < 10
    const minimalFailingProperty = property(i32, gen(i32, .{ .min = 0, .max = 1000 }), struct {
        fn test_(n: i32) bool {
            return n >= 10; // Fails for values < 10
        }
    }.test_);

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test (should fail)
    const result = try minimalFailingProperty.check(std.testing.allocator, &bytes);

    // Should fail with a counterexample
    try std.testing.expect(result != null);

    // The counterexample should have been shrunk
    if (result) |failure| {
        std.debug.print("Minimal counterexample had {} shrinking steps\n", .{failure.shrink_count});
        try std.testing.expect(failure.shrink_count > 0);
    }
}

test "property with hooks" {
    // Create static variables to track hook calls
    var setup_called: usize = 0;
    var teardown_called: usize = 0;

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test
    const result = try prop.check(std.testing.allocator, &bytes);

    // Should be null (no counterexample)
    try std.testing.expectEqual(@as(?PropertyFailure, null), result);

    // Hooks should have been called
    try std.testing.expect(setup_called > 0);
    try std.testing.expect(teardown_called > 0);
}

test "property with context hooks" {
    // Create a context struct to track hook calls
    const HookContext = struct {
        setup_called: bool = false,
        teardown_called: bool = false,
    };

    var context = HookContext{};

    // Create a property
    var prop = property(i32, gen(i32, .{ .min = 1, .max = 10 }), struct {
        fn test_(n: i32) bool {
            return n > 0; // Always true for our range
        }
    }.test_);

    // Create a copy with hooks added

    // Add hooks directly to the struct
    prop.before_each_context = &context;
    prop.before_each_fn = struct {
        fn hook(ctx: *anyopaque) void {
            const c = @as(*HookContext, @ptrCast(@alignCast(ctx)));
            c.setup_called = true;
        }
    }.hook;

    prop.after_each_context = &context;
    prop.after_each_fn = struct {
        fn hook(ctx: *anyopaque) void {
            const c = @as(*HookContext, @ptrCast(@alignCast(ctx)));
            c.teardown_called = true;
        }
    }.hook;

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test
    const result = try prop.check(std.testing.allocator, &bytes);

    // Should be null (no counterexample)
    try std.testing.expectEqual(@as(?PropertyFailure, null), result);

    // Hooks should have been called
    try std.testing.expect(context.setup_called);
    try std.testing.expect(context.teardown_called);
}

test "array generator with property" {
    // Generate [5]i32 arrays with elements between 5 and 15
    const arrayProperty = property([5]i32, gen([5]i32, .{
        .child_config = .{ .min = 5, .max = 15 },
    }), struct {
        fn test_(array: [5]i32) bool {
            // Test that all elements are within the expected range
            for (array) |elem| {
                if (elem < 5 or elem > 15) return false;
            }
            return true;
        }
    }.test_);

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test (should always succeed)
    const result = try arrayProperty.check(std.testing.allocator, &bytes);

    // Should be null (no counterexample)
    try std.testing.expectEqual(@as(?PropertyFailure, null), result);
}

test "checkUnmanaged API" {
    const simpleProperty = property(i32, gen(i32, .{ .min = -100, .max = 100 }), struct {
        fn test_(n: i32) bool {
            return n >= 0; // Should fail for negative numbers
        }
    }.test_);

    // Create a byte slice that should trigger a failure
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a buffer for shrinking
    var stack = try std.ArrayListUnmanaged(ByteRange).initCapacity(std.testing.allocator, property_mod.maxShrinkRanges(bytes.len));
    defer stack.deinit(std.testing.allocator);

    // Run the property test
    const result = try simpleProperty.checkUnmanaged(std.testing.allocator, &bytes, &stack);

    // Should fail with a counterexample
    try std.testing.expect(result != null);

    // The counterexample should have been shrunk
    if (result) |failure| {
        std.debug.print("Unmanaged API counterexample had {} shrinking steps\n", .{failure.shrink_count});
        try std.testing.expect(failure.shrink_count > 0);
    }
}
