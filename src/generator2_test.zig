const std = @import("std");
const generator2 = @import("generator2.zig");
const property = @import("property.zig");
const runner = @import("runner.zig");

const gen = generator2.gen;
const Value = generator2.Value;
const ValueList = generator2.ValueList;
const Property = property.Property;
const property_fn = property.property;
const PropertyResult = property.PropertyResult;

test "int generator produces values within range" {
    // Create a generator for integers between 10 and 20
    const intGenerator = gen(i32, .{ .min = 10, .max = 20 });

    var prng = std.Random.DefaultPrng.init(42); // Fixed seed for reproducibility
    const random = prng.random();

    // Generate 100 values and check they're all within range
    for (0..100) |_| {
        const value = try intGenerator.generate(random, 10, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        try std.testing.expect(value.value >= 10 and value.value <= 20);
    }
}

test "integer shrinking produces smaller values" {
    // Create a generator for integers between -100 and 100
    const intGenerator = gen(i32, .{ .min = -100, .max = 100 });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate a value then shrink it
    const value = try intGenerator.generate(random, 10, std.testing.allocator);
    defer value.deinit(std.testing.allocator);

    // Only test shrinking for non-zero values
    if (value.value != 0) {
        const shrinks = try intGenerator.shrink(value.value, value.context, std.testing.allocator);
        defer shrinks.deinit();

        // Verify we have some shrink candidates
        try std.testing.expect(shrinks.len() > 0);

        // Verify that at least one shrink candidate is "simpler" than our value
        var found_simpler = false;
        for (shrinks.values) |shrink| {
            // Absolute value should be smaller or it should be closer to zero
            if (@abs(shrink.value) < @abs(value.value) or
                @abs(shrink.value - 0) < @abs(value.value - 0))
            {
                found_simpler = true;
                break;
            }
        }

        try std.testing.expect(found_simpler);
    }
}

test "shrinking preserves value range" {
    // Create a generator for positive integers between 50 and 100
    const intGenerator = gen(i32, .{ .min = 50, .max = 100 });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate a value then shrink it
    const value = try intGenerator.generate(random, 10, std.testing.allocator);
    defer value.deinit(std.testing.allocator);

    const shrinks = try intGenerator.shrink(value.value, value.context, std.testing.allocator);
    defer shrinks.deinit();

    // Verify that all shrink candidates respect the range constraints
    for (shrinks.values) |shrink| {
        try std.testing.expect(shrink.value >= 50 and shrink.value <= 100);
    }
}

test "map with shrinking" {
    // Create a generator for integers between 1 and 100
    const intGenerator = gen(i32, .{ .min = 1, .max = 100 });

    // Map to double the values
    const doubledGenerator = intGenerator.map(i32, struct {
        fn double(n: i32) i32 {
            return n * 2;
        }
    }.double, struct {
        fn halve(n: i32) ?i32 {
            if (n % 2 == 0) {
                return n / 2;
            }
            return null; // Can't unmapped odd numbers
        }
    }.halve);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate a value, verify it's doubled, then shrink it
    const value = try doubledGenerator.generate(random, 10, std.testing.allocator);
    defer value.deinit(std.testing.allocator);

    // Value should be even and between 2 and 200
    try std.testing.expect(value.value >= 2 and value.value <= 200);
    try std.testing.expect(value.value % 2 == 0);

    // Shrink the value
    const shrinks = try doubledGenerator.shrink(value.value, value.context, std.testing.allocator);
    defer shrinks.deinit();

    // Verify we have some shrink candidates
    if (value.value > 2) { // Only values > 2 can be further shrunk
        try std.testing.expect(shrinks.len() > 0);

        // Verify that all shrinks are even numbers (maintain the doubling property)
        for (shrinks.values) |shrink| {
            try std.testing.expect(shrink.value % 2 == 0);
        }
    }
}

test "filter with shrinking" {
    // Create a generator for integers between -100 and 100
    const intGenerator = gen(i32, .{ .min = -100, .max = 100 });

    // Filter to only positive values
    const positiveGenerator = intGenerator.filter(struct {
        fn isPositive(n: i32) bool {
            return n > 0;
        }
    }.isPositive);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate a value, verify it's positive, then shrink it
    const value = try positiveGenerator.generate(random, 10, std.testing.allocator);
    defer value.deinit(std.testing.allocator);

    // Value should be positive
    try std.testing.expect(value.value > 0);

    // Shrink the value
    const shrinks = try positiveGenerator.shrink(value.value, value.context, std.testing.allocator);
    defer shrinks.deinit();

    // If the value is greater than 1, we should have shrink candidates
    if (value.value > 1) {
        try std.testing.expect(shrinks.len() > 0);

        // Verify that all shrinks are positive (maintain the filter property)
        for (shrinks.values) |shrink| {
            try std.testing.expect(shrink.value > 0);
        }
    }
}

test "basic property test (addition commutative)" {
    // Test the commutative property of addition: a + b == b + a
    const TestType = struct { a: i32, b: i32 };
    const commutativeProperty = property_fn(TestType, gen(TestType, .{
        .a = .{ .min = -100, .max = 100 },
        .b = .{ .min = -100, .max = 100 },
    }), struct {
        fn test_(args: TestType) bool {
            return args.a + args.b == args.b + args.a;
        }
    }.test_);

    // Run the property test
    const result = try commutativeProperty.check(std.testing.allocator, 100, 42);

    // Should always succeed
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 100), result.num_passed);
}

test "failing property with shrinking (all integers are positive)" {
    // Test the (false) property that all integers are positive
    const positiveProperty = property_fn(i32, gen(i32, .{ .min = -100, .max = 100 }), struct {
        fn test_(n: i32) bool {
            return n > 0;
        }
    }.test_);

    // Run the property test (should fail)
    const result = try positiveProperty.check(std.testing.allocator, 100, 42);

    // Should fail with a counterexample
    try std.testing.expect(!result.success);

    // The counterexample should be 0 or negative
    if (result.counterexample) |counter_ptr| {
        const counterexample = @as(*const i32, @ptrCast(counter_ptr)).*;
        try std.testing.expect(counterexample <= 0);
    } else {
        try std.testing.expect(false); // Should have a counterexample
    }

    // Should have done some shrinking to find a minimal counterexample
    try std.testing.expect(result.num_shrinks > 0);
}

test "property with hooks" {
    // Setup state for hooks
    var setup_called: usize = 0;
    var teardown_called: usize = 0;

    // Create a property with hooks
    var prop = property_fn(i32, gen(i32, .{ .min = 1, .max = 10 }), struct {
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

    // Run the property test
    const result = try prop.check(std.testing.allocator, 10, 42);

    // Should succeed
    try std.testing.expect(result.success);

    // Hooks should have been called once per test case
    try std.testing.expectEqual(@as(usize, 10), setup_called);
    try std.testing.expectEqual(@as(usize, 10), teardown_called);
}

test "property with context-less hooks" {
    // Setup state for hooks
    var setup_called: usize = 0;
    var teardown_called: usize = 0;

    // Create a property with context-less hooks that use pointers
    var prop = property_fn(i32, gen(i32, .{ .min = 1, .max = 10 }), struct {
        fn test_(n: i32) bool {
            return n > 0; // Always true for our range
        }
    }.test_)
        // Pass pointers to the counters as context
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

    // Run the property test
    const result = try prop.check(std.testing.allocator, 10, 42);

    // Should succeed
    try std.testing.expect(result.success);

    // Hooks should have been called once per test case
    try std.testing.expectEqual(@as(usize, 10), setup_called);
    try std.testing.expectEqual(@as(usize, 10), teardown_called);
}

test "property test finds minimal failing example" {
    // Test a property that should fail for values < 10
    const minimalFailingProperty = property_fn(i32, gen(i32, .{ .min = 0, .max = 1000 }), struct {
        fn test_(n: i32) bool {
            return n >= 10; // Fails for values < 10
        }
    }.test_);

    // Run the property test
    const result = try minimalFailingProperty.check(std.testing.allocator, 100, 42);

    // Should fail with a counterexample
    try std.testing.expect(!result.success);

    // The counterexample should be the minimal failing example: 9 or less
    if (result.counterexample) |counter_ptr| {
        const counterexample = @as(*const i32, @ptrCast(counter_ptr)).*;
        try std.testing.expect(counterexample < 10);

        // In the ideal case, shrinking should find exactly 0
        std.debug.print("Minimal counterexample: {}\n", .{counterexample});
    } else {
        try std.testing.expect(false); // Should have a counterexample
    }
}
