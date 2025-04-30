const std = @import("std");
const generator2 = @import("generator2.zig");
const FinitePrng = @import("byte_slice_prng.zig");
const load_bytes = @import("test_helpers.zig").load_bytes;

const gen = generator2.gen;
const Value = generator2.Value;
const ValueList = generator2.ValueList;
const property = @import("property2.zig").property;
const tuple = generator2.tuple;
const oneOf = generator2.oneOf;

test "int generator produces values within range" {
    // Create a generator for integers between 10 and 20
    const intGenerator = gen(i32, .{ .min = 10, .max = 20 });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;

    // Generate 20 values with different random seeds and check they're within range
    for (0..20) |_| {
        // Load random bytes for each test
        load_bytes(&bytes);

        // Create a finite PRNG
        var prng = FinitePrng.init(&bytes);
        var random = prng.random();

        // Generate the value
        const value = try intGenerator.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        // Verify the value is within range
        try std.testing.expect(value.value >= 10 and value.value <= 20);

        // Verify byte range is properly recorded
        try std.testing.expect(value.byte_pos != null);
        if (value.byte_pos) |pos| {
            try std.testing.expect(pos.start < pos.end);
            try std.testing.expect(pos.end <= bytes.len);
        }
    }
}

test "integer shrinking produces smaller values" {
    // Create a generator for integers between -100 and 100
    const intGenerator = gen(i32, .{ .min = -100, .max = 100 });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a value then shrink it
    const value = try intGenerator.generate(&random, std.testing.allocator);
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

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a value then shrink it
    const value = try intGenerator.generate(&random, std.testing.allocator);
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

    // Define the mapping functions
    const double = @as(*const fn (i32) i32, &struct {
        fn double(n: i32) i32 {
            return n * 2;
        }
    }.double);

    const halve = @as(?*const fn (i32) ?i32, &struct {
        fn halve(n: i32) ?i32 {
            if (@rem(n, 2) == 0) {
                return @divTrunc(n, 2);
            }
            return null; // Can't unmapped odd numbers
        }
    }.halve);

    // Map to double the values
    const doubledGenerator = intGenerator.map(i32, double, halve);

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a value, verify it's doubled, then shrink it
    const value = try doubledGenerator.generate(&random, std.testing.allocator);
    defer value.deinit(std.testing.allocator);

    // Value should be even and between 2 and 200
    try std.testing.expect(value.value >= 2 and value.value <= 200);
    try std.testing.expect(@rem(value.value, 2) == 0);

    // Shrink the value
    const shrinks = try doubledGenerator.shrink(value.value, value.context, std.testing.allocator);
    defer shrinks.deinit();

    // Verify we have some shrink candidates
    if (value.value > 2) { // Only values > 2 can be further shrunk
        try std.testing.expect(shrinks.len() > 0);

        // Verify that all shrinks are even numbers (maintain the doubling property)
        for (shrinks.values) |shrink| {
            try std.testing.expect(@rem(shrink.value, 2) == 0);
        }
    }
}

test "filter with shrinking" {
    // Create a generator for integers between -100 and 100
    const intGenerator = gen(i32, .{ .min = -100, .max = 100 });

    // Define the filter function
    const isPositive = @as(*const fn (i32) bool, &struct {
        fn isPositive(n: i32) bool {
            return n > 0;
        }
    }.isPositive);

    // Filter to only positive values
    const positiveGenerator = intGenerator.filter(isPositive);

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a value, verify it's positive, then shrink it
    const value = try positiveGenerator.generate(&random, std.testing.allocator);
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
    const commutativeProperty = property(TestType, gen(TestType, .{
        .a = .{ .min = -100, .max = 100 },
        .b = .{ .min = -100, .max = 100 },
    }), struct {
        fn test_(args: TestType) bool {
            return args.a + args.b == args.b + args.a;
        }
    }.test_);

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test
    const result = try commutativeProperty.check(std.testing.allocator, &bytes);

    // Should always succeed
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.num_passed);
}

test "failing property with shrinking (all integers are positive)" {
    // Test the (false) property that all integers are positive
    const positiveProperty = property(i32, gen(i32, .{ .min = -100, .max = 100 }), struct {
        fn test_(n: i32) bool {
            return n > 0;
        }
    }.test_);

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test (should fail)
    const result = try positiveProperty.check(std.testing.allocator, &bytes);

    // Should fail with a counterexample
    try std.testing.expect(!result.success);

    // The counterexample should be 0 or negative
    if (result.counterexample) |counter_ptr| {
        const counterexample = @as(*const i32, @ptrCast(@alignCast(counter_ptr))).*;
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

    // Create a buffer for random bytes
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

test "property with context-less hooks" {
    // Setup state for hooks
    var setup_called: usize = 0;
    var teardown_called: usize = 0;

    // Create a property with context-less hooks that use pointers
    var prop = property(i32, gen(i32, .{ .min = 1, .max = 10 }), struct {
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

    // Create a buffer for random bytes
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

test "property test finds minimal failing example" {
    // Test a property that should fail for values < 10
    const minimalFailingProperty = property(i32, gen(i32, .{ .min = 0, .max = 1000 }), struct {
        fn test_(n: i32) bool {
            return n >= 10; // Fails for values < 10
        }
    }.test_);

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Run the property test
    const result = try minimalFailingProperty.check(std.testing.allocator, &bytes);

    // Should fail with a counterexample
    try std.testing.expect(!result.success);

    // The counterexample should be the minimal failing example: 9 or less
    if (result.counterexample) |counter_ptr| {
        const counterexample = @as(*const i32, @ptrCast(@alignCast(counter_ptr))).*;
        try std.testing.expect(counterexample < 10);

        // In the ideal case, shrinking should find exactly 0
        std.debug.print("Minimal counterexample: {}\n", .{counterexample});
    } else {
        try std.testing.expect(false); // Should have a counterexample
    }
}

test "float generator produces values within range" {
    // Create a generator for floats between -10.0 and 10.0
    const floatGenerator = gen(f64, .{ .min = -10.0, .max = 10.0 });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate 100 values and check they're all within range
    for (0..100) |_| {
        const value = try floatGenerator.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        // Skip NaN and infinity checks
        if (std.math.isNan(value.value) or std.math.isInf(value.value)) continue;

        try std.testing.expect(value.value >= -10.0 and value.value <= 10.0);
    }
}

test "float generator produces special values" {
    const floatGenerator = gen(f64, .{});

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Track special values we've seen
    var seen_zero = false;
    var seen_one = false;
    var seen_neg_one = false;
    var seen_min_pos = false;
    var seen_min_neg = false;

    // Generate many values to increase chance of hitting special values
    for (0..1000) |_| {
        const value = try floatGenerator.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        if (value.value == 0.0) seen_zero = true;
        if (value.value == 1.0) seen_one = true;
        if (value.value == -1.0) seen_neg_one = true;
        if (value.value == std.math.floatMin(f64)) seen_min_pos = true;
        if (value.value == -std.math.floatMin(f64)) seen_min_neg = true;

        // If we've seen all special values, we can stop
        if (seen_zero and seen_one and seen_neg_one and
            seen_min_pos and seen_min_neg) break;
    }

    // We should have found at least some special values
    var found_count: usize = 0;
    if (seen_zero) found_count += 1;
    if (seen_one) found_count += 1;
    if (seen_neg_one) found_count += 1;
    if (seen_min_pos) found_count += 1;
    if (seen_min_neg) found_count += 1;

    try std.testing.expect(found_count > 0);
    std.debug.print("Found {d} of 5 special float values\n", .{found_count});
}

test "float shrinking produces simpler values" {
    // Create a generator for floats
    const floatGenerator = gen(f64, .{ .min = -100.0, .max = 100.0 });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a value then shrink it
    const value = try floatGenerator.generate(&random, std.testing.allocator);
    defer value.deinit(std.testing.allocator);

    // Only test shrinking for non-zero, non-special values
    if (value.value != 0.0 and !std.math.isNan(value.value) and !std.math.isInf(value.value)) {
        const shrinks = try floatGenerator.shrink(value.value, value.context, std.testing.allocator);
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

test "array generator produces arrays of the correct length" {
    // Generate [5]i32 arrays
    const arrayGenerator = gen([5]i32, .{
        .child_config = .{ .min = -10, .max = 10 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a few arrays and check their length
    for (0..10) |_| {
        const array = try arrayGenerator.generate(&random, std.testing.allocator);
        defer array.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 5), array.value.len);
    }
}

test "array generator respects element bounds" {
    // Generate [10]i32 arrays with elements between 5 and 15
    const arrayGenerator = gen([10]i32, .{
        .child_config = .{ .min = 5, .max = 15 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate arrays and check all elements are within bounds
    for (0..10) |_| {
        const array = try arrayGenerator.generate(&random, std.testing.allocator);
        defer array.deinit(std.testing.allocator);

        for (array.value) |value| {
            try std.testing.expect(value >= 5 and value <= 15);
        }
    }
}

test "array shrinking preserves element bounds" {
    // Generate [5]i32 arrays with elements between 5 and 15
    const arrayGenerator = gen([5]i32, .{
        .child_config = .{ .min = 5, .max = 15 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a value then shrink it
    const array = try arrayGenerator.generate(&random, std.testing.allocator);
    defer array.deinit(std.testing.allocator);

    const shrinks = try arrayGenerator.shrink(array.value, array.context, std.testing.allocator);
    defer shrinks.deinit();

    // Verify that all shrink candidates respect the element bounds
    for (shrinks.values) |shrink| {
        for (shrink.value) |elem| {
            try std.testing.expect(elem >= 5 and elem <= 15);
        }
    }
}

test "slice generator produces slices of correct length range" {
    // Generate []i32 slices with lengths between 3 and 7
    const sliceGenerator = gen([]i32, .{
        .min_len = 3,
        .max_len = 7,
        .child_config = .{ .min = -10, .max = 10 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate slices and check their length is within range
    for (0..10) |_| {
        const slice = try sliceGenerator.generate(&random, std.testing.allocator);
        defer slice.deinit(std.testing.allocator);

        try std.testing.expect(slice.value.len >= 3 and slice.value.len <= 7);
    }
}

test "slice generator respects element bounds" {
    // Generate []i32 slices with elements between 5 and 15
    const sliceGenerator = gen([]i32, .{
        .min_len = 1,
        .max_len = 10,
        .child_config = .{ .min = 5, .max = 15 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate slices and check all elements are within bounds
    for (0..10) |_| {
        const slice = try sliceGenerator.generate(&random, std.testing.allocator);
        defer slice.deinit(std.testing.allocator);

        for (slice.value) |value| {
            try std.testing.expect(value >= 5 and value <= 15);
        }
    }
}

test "slice shrinking works correctly" {
    // Generate []i32 slices
    const sliceGenerator = gen([]i32, .{
        .min_len = 5,
        .max_len = 10,
        .child_config = .{ .min = -10, .max = 10 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a value then shrink it
    const slice = try sliceGenerator.generate(&random, std.testing.allocator);
    defer slice.deinit(std.testing.allocator);

    const shrinks = try sliceGenerator.shrink(slice.value, slice.context, std.testing.allocator);
    defer shrinks.deinit();

    // Verify we have some shrink candidates
    try std.testing.expect(shrinks.len() > 0);

    // Verify that shrinks are either shorter or have simpler elements
    for (shrinks.values) |shrink| {
        // Either the shrink is shorter, or its elements are simpler
        var is_valid_shrink = shrink.value.len < slice.value.len;

        if (!is_valid_shrink) {
            // Check if elements are simpler
            for (shrink.value, slice.value) |shrink_elem, orig_elem| {
                if (@abs(shrink_elem) < @abs(orig_elem) or
                    (@abs(shrink_elem) == @abs(orig_elem) and shrink_elem >= 0 and orig_elem < 0))
                {
                    is_valid_shrink = true;
                    break;
                }
            }
        }

        try std.testing.expect(is_valid_shrink);
    }
}

test "single pointer generator works correctly" {
    // Create a generator for pointers to integers
    const intPtrGenerator = gen(*i32, .{
        .child_config = .{ .min = -50, .max = 50 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a pointer and check its value
    const int_ptr = try intPtrGenerator.generate(&random, std.testing.allocator);
    defer int_ptr.deinit(std.testing.allocator);

    try std.testing.expect(int_ptr.value.* >= -50 and int_ptr.value.* <= 50);
}

test "pointer shrinking works correctly" {
    // Create a generator for pointers to integers
    const intPtrGenerator = gen(*i32, .{
        .child_config = .{ .min = -50, .max = 50 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a value then shrink it
    const ptr = try intPtrGenerator.generate(&random, std.testing.allocator);
    defer ptr.deinit(std.testing.allocator);

    // Only test shrinking for non-zero values
    if (ptr.value.* != 0) {
        const shrinks = try intPtrGenerator.shrink(ptr.value, ptr.context, std.testing.allocator);
        defer shrinks.deinit();

        // Verify we have some shrink candidates
        try std.testing.expect(shrinks.len() > 0);

        // Verify that shrinks have simpler pointed-to values
        for (shrinks.values) |shrink| {
            try std.testing.expect(@abs(shrink.value.*) <= @abs(ptr.value.*));
        }
    }
}

test "enum generator produces valid enum values" {
    const Color = enum {
        red,
        green,
        blue,
        yellow,
        purple,
    };

    // Create a generator for the Color enum
    const colorGenerator = gen(Color, .{});

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Track which enum values we've seen
    var seen = [_]bool{false} ** 5;

    // Generate many values to ensure we get all enum variants
    for (0..100) |_| {
        const color = try colorGenerator.generate(&random, std.testing.allocator);
        defer color.deinit(std.testing.allocator);

        // Verify it's a valid enum value
        switch (color.value) {
            .red => seen[0] = true,
            .green => seen[1] = true,
            .blue => seen[2] = true,
            .yellow => seen[3] = true,
            .purple => seen[4] = true,
        }
    }

    // We should have seen all enum values
    for (seen, 0..) |was_seen, i| {
        try std.testing.expect(was_seen);
        if (!was_seen) {
            std.debug.print("Didn't see enum value at index {d}\n", .{i});
        }
    }
}

test "union generator produces valid values" {
    const ValueUnion = union(enum) {
        int: i32,
        float: f64,
        boolean: bool,
    };

    // Create a generator for the Value union
    const valueGenerator = gen(ValueUnion, .{
        .int = .{ .min = 1, .max = 100 },
        .float = .{ .min = -10.0, .max = 10.0 },
        .boolean = .{},
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Track which union variants we've seen
    var seen_int = false;
    var seen_float = false;
    var seen_boolean = false;

    // Generate many values to ensure we get all variants
    for (0..100) |_| {
        const value = try valueGenerator.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        // Determine which variant we got and verify its constraints
        const active_tag = std.meta.activeTag(value.value);
        switch (active_tag) {
            .int => {
                seen_int = true;
                try std.testing.expect(value.value.int >= 1 and value.value.int <= 100);
            },
            .float => {
                seen_float = true;
                try std.testing.expect(value.value.float >= -10.0 and value.value.float <= 10.0);
            },
            .boolean => {
                seen_boolean = true;
                try std.testing.expect(value.value.boolean == true or value.value.boolean == false);
            },
        }

        if (seen_int and seen_float and seen_boolean) break;
    }

    // We should have seen all union variants
    try std.testing.expect(seen_int);
    try std.testing.expect(seen_float);
    try std.testing.expect(seen_boolean);
}

test "union shrinking works correctly" {
    const ValueUnion = union(enum) {
        int: i32,
        float: f64,
    };

    // Create a generator for the Value union
    const valueGenerator = gen(ValueUnion, .{
        .int = .{ .min = -100, .max = 100 },
        .float = .{ .min = -10.0, .max = 10.0 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a value then shrink it
    const value = try valueGenerator.generate(&random, std.testing.allocator);
    defer value.deinit(std.testing.allocator);

    const shrinks = try valueGenerator.shrink(value.value, value.context, std.testing.allocator);
    defer shrinks.deinit();

    // Verify that all shrinks have the same active tag as the original
    const original_tag = std.meta.activeTag(value.value);
    for (shrinks.values) |shrink| {
        try std.testing.expectEqual(original_tag, std.meta.activeTag(shrink.value));
    }
}

test "optional generator produces both null and values" {
    // Create a generator for optional integers
    const optIntGenerator = gen(?i32, .{
        .child_config = .{ .min = 1, .max = 100 },
        .null_probability = 0.5, // 50% chance of null
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    var seen_null = false;
    var seen_value = false;

    // Generate values until we've seen both null and non-null
    for (0..100) |_| {
        const value = try optIntGenerator.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        if (value.value == null) {
            seen_null = true;
        } else {
            seen_value = true;
            // Check that non-null values respect the child generator's constraints
            try std.testing.expect(value.value.? >= 1 and value.value.? <= 100);
        }

        if (seen_null and seen_value) break;
    }

    // We should have seen both null and non-null values
    try std.testing.expect(seen_null and seen_value);
}

test "optional shrinking works correctly" {
    // Create a generator for optional integers
    const optIntGenerator = gen(?i32, .{
        .child_config = .{ .min = 1, .max = 100 },
        .null_probability = 0.3,
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a non-null value
    var value: Value(?i32) = undefined;
    var found_non_null = false;

    // Try to get a non-null value
    for (0..100) |_| {
        value = try optIntGenerator.generate(&random, std.testing.allocator);
        if (value.value != null) {
            found_non_null = true;
            break;
        }
        value.deinit(std.testing.allocator);
    }

    if (found_non_null) {
        defer value.deinit(std.testing.allocator);

        const shrinks = try optIntGenerator.shrink(value.value, value.context, std.testing.allocator);
        defer shrinks.deinit();

        // Verify we have some shrink candidates
        try std.testing.expect(shrinks.len() > 0);

        // The first shrink should be null (simplest form)
        try std.testing.expectEqual(@as(?i32, null), shrinks.values[0].value);
    } else {
        // If we couldn't generate a non-null value after 100 tries, something is wrong
        try std.testing.expect(false);
    }
}

test "vector generator produces vectors within range" {
    // Generate @Vector(4, i32) vectors
    const vectorGenerator = gen(@Vector(4, i32), .{
        .child_config = .{ .min = -10, .max = 10 },
    });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a few vectors and check their values
    for (0..10) |_| {
        const vector = try vectorGenerator.generate(&random, std.testing.allocator);
        defer vector.deinit(std.testing.allocator);

        // Check each element is within bounds
        for (0..4) |i| {
            const value = vector.value[i];
            try std.testing.expect(value >= -10 and value <= 10);
        }
    }
}

test "tuple generator combines multiple generators" {
    // Create generators for different types
    const intGenerator = comptime gen(i32, .{ .min = 1, .max = 100 });
    const boolGenerator = comptime gen(bool, .{});
    const floatGenerator = comptime gen(f64, .{ .min = -10.0, .max = 10.0 });

    // Combine them into a tuple generator
    const tupleGenerator = tuple(.{ intGenerator, boolGenerator, floatGenerator });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate tuples and check their components
    for (0..10) |_| {
        const value = try tupleGenerator.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        // Check that each component has the correct type and constraints
        const int_value: i32 = value.value[0];
        const bool_value: bool = value.value[1];
        const float_value: f64 = value.value[2];

        try std.testing.expect(int_value >= 1 and int_value <= 100);
        try std.testing.expect(bool_value == true or bool_value == false);

        // Skip NaN and infinity checks for float
        if (!std.math.isNan(float_value) and !std.math.isInf(float_value)) {
            try std.testing.expect(float_value >= -10.0 and float_value <= 10.0);
        }
    }
}

test "oneOf selects from multiple generators" {
    // Create several integer generators with different ranges
    const smallIntGen = comptime gen(i32, .{ .min = 1, .max = 10 });
    const mediumIntGen = comptime gen(i32, .{ .min = 11, .max = 100 });
    const largeIntGen = comptime gen(i32, .{ .min = 101, .max = 1000 });

    // Combine them with oneOf
    const combinedGen = oneOf(.{ smallIntGen, mediumIntGen, largeIntGen }, null);

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Track which ranges we've seen
    var seen_small = false;
    var seen_medium = false;
    var seen_large = false;

    // Generate many values to ensure we get all ranges
    for (0..1000) |_| {
        const value = try combinedGen.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        if (value.value >= 1 and value.value <= 10) seen_small = true;
        if (value.value >= 11 and value.value <= 100) seen_medium = true;
        if (value.value >= 101 and value.value <= 1000) seen_large = true;

        if (seen_small and seen_medium and seen_large) break;
    }

    // We should have seen all three ranges
    try std.testing.expect(seen_small);
    try std.testing.expect(seen_medium);
    try std.testing.expect(seen_large);
}

test "oneOf respects weights" {
    // Create two boolean generators - one that always generates true, one that always generates false
    const trueGen = comptime gen(bool, .{}).map(bool, struct {
        fn alwaysTrue(_: bool) bool {
            return true;
        }
    }.alwaysTrue, null);

    const falseGen = comptime gen(bool, .{}).map(bool, struct {
        fn alwaysFalse(_: bool) bool {
            return false;
        }
    }.alwaysFalse, null);

    // Create a heavily weighted generator that should mostly produce true
    const weights = [_]f32{ 0.9, 0.1 }; // 90% true, 10% false
    const weightedGen = oneOf(.{ trueGen, falseGen }, &weights);

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Count true/false values
    var true_count: usize = 0;
    var false_count: usize = 0;
    const iterations = 1000;

    for (0..iterations) |_| {
        const value = try weightedGen.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        if (value.value) true_count += 1 else false_count += 1;
    }

    // We should get roughly 90% true values
    const true_ratio = @as(f32, @floatFromInt(true_count)) / @as(f32, @floatFromInt(iterations));
    try std.testing.expect(true_ratio > 0.8); // Allow some statistical variation
}

test "bool generator produces both true and false" {
    const boolGenerator = gen(bool, .{});

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    var seen_true = false;
    var seen_false = false;

    // Generate values until we've seen both true and false
    for (0..100) |_| {
        const value = try boolGenerator.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        if (value.value) seen_true = true else seen_false = true;

        if (seen_true and seen_false) break;
    }

    // We should have seen both true and false
    try std.testing.expect(seen_true and seen_false);
}

test "bool shrinking works correctly" {
    const boolGenerator = gen(bool, .{});

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Generate a true value (we know shrinking only works on true)
    var value: Value(bool) = undefined;
    var found_true = false;

    // Try to get a true value
    for (0..100) |_| {
        value = try boolGenerator.generate(&random, std.testing.allocator);
        if (value.value) {
            found_true = true;
            break;
        }
        value.deinit(std.testing.allocator);
    }

    if (found_true) {
        defer value.deinit(std.testing.allocator);

        // Shrink the true value
        const shrinks = try boolGenerator.shrink(value.value, value.context, std.testing.allocator);
        defer shrinks.deinit();

        // Should have exactly one shrink candidate: false
        try std.testing.expectEqual(@as(usize, 1), shrinks.len());
        try std.testing.expectEqual(false, shrinks.values[0].value);
    } else {
        // If we couldn't generate a true value after 100 tries, something is wrong
        try std.testing.expect(false);
    }
}
