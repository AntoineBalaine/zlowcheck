const std = @import("std");
const Generator = @import("generator.zig").Generator;
const gen = @import("generator.zig").gen;

test "int generator produces values within range" {
    // Create a generator for integers between 10 and 20
    const intGenerator = gen(i32, .{ .min = 10, .max = 20 });

    var prng = std.Random.DefaultPrng.init(42); // Fixed seed for reproducibility
    const random = prng.random();

    // Generate 100 values and check they're all within range
    for (0..100) |_| {
        const value = try intGenerator.generate(random, 10, std.testing.allocator);
        try std.testing.expect(value >= 10 and value <= 20);
    }
}

test "int generator produces boundary values" {
    // Create a generator for integers
    const intGenerator = gen(i32, .{ .min = -100, .max = 100 });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Set to track boundary values we've seen
    var seen_boundaries = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer seen_boundaries.deinit();

    // Expected boundary values
    try seen_boundaries.put(-100, {}); // min
    try seen_boundaries.put(-99, {}); // min+1
    try seen_boundaries.put(-1, {});
    try seen_boundaries.put(0, {});
    try seen_boundaries.put(1, {});
    try seen_boundaries.put(99, {}); // max-1
    try seen_boundaries.put(100, {}); // max

    // Generate many values to increase chance of hitting boundaries
    var found_count: usize = 0;
    for (0..1000) |_| {
        const value = try intGenerator.generate(random, 10, std.testing.allocator);

        // If it's a boundary value, remove it from our map
        if (seen_boundaries.contains(value)) {
            _ = seen_boundaries.remove(value);
            found_count += 1;

            // If we've found all boundaries, we can stop
            if (seen_boundaries.count() == 0) break;
        }
    }

    // We should have found at least some boundary values
    try std.testing.expect(found_count > 0);
    std.debug.print("Found {d} of 7 boundary values\n", .{found_count});
}

test "float generator produces values within range" {
    // Create a generator for floats between -10.0 and 10.0
    const floatGenerator = gen(f64, .{ .min = -10.0, .max = 10.0 });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate 100 values and check they're all within range
    for (0..100) |_| {
        const value = try floatGenerator.generate(random, 10, std.testing.allocator);

        // Skip NaN and infinity checks
        if (std.math.isNan(value) or std.math.isInf(value)) continue;

        try std.testing.expect(value >= -10.0 and value <= 10.0);
    }
}

test "float generator produces special values" {
    const floatGenerator = gen(f64, .{});

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Track special values we've seen
    var seen_zero = false;
    var seen_one = false;
    var seen_neg_one = false;
    var seen_min_pos = false;
    var seen_min_neg = false;

    // Generate many values to increase chance of hitting special values
    for (0..1000) |_| {
        const value = try floatGenerator.generate(random, 10, std.testing.allocator);

        if (value == 0.0) seen_zero = true;
        if (value == 1.0) seen_one = true;
        if (value == -1.0) seen_neg_one = true;
        if (value == std.math.floatMin(f64)) seen_min_pos = true;
        if (value == -std.math.floatMin(f64)) seen_min_neg = true;

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

test "bool generator produces both true and false" {
    const boolGenerator = gen(bool, .{});

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var seen_true = false;
    var seen_false = false;

    // Generate values until we've seen both true and false
    for (0..100) |_| {
        const value = try boolGenerator.generate(random, 10, std.testing.allocator);

        if (value) seen_true = true else seen_false = true;

        if (seen_true and seen_false) break;
    }

    // We should have seen both true and false
    try std.testing.expect(seen_true and seen_false);
}

test "map transforms values correctly" {
    // Create a generator for integers
    const intGenerator = gen(i32, .{ .min = 1, .max = 10 });

    // Map to double the values
    const doubledGenerator = intGenerator.map(i32, struct {
        fn double(n: i32) i32 {
            return n * 2;
        }
    }.double);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate values and check they're all doubled
    for (0..100) |_| {
        const value = try doubledGenerator.generate(random, 10, std.testing.allocator);
        try std.testing.expect(value >= 2 and value <= 20 and @rem(value, 2) == 0);
    }
}

test "filter constrains values correctly" {
    // Create a generator for integers
    const intGenerator = gen(i32, .{ .min = -10, .max = 10 });

    // Filter to only positive values
    const positiveGenerator = intGenerator.filter(struct {
        fn isPositive(n: i32) bool {
            return n > 0;
        }
    }.isPositive);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate values and check they're all positive
    for (0..100) |_| {
        const value = try positiveGenerator.generate(random, 10, std.testing.allocator);
        try std.testing.expect(value > 0 and value <= 10);
    }
}

test "array generator produces arrays of the correct length" {
    // Generate [5]i32 arrays
    const arrayGenerator = gen([5]i32, .{
        .child_config = .{ .min = -10, .max = 10 },
    });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate a few arrays and check their length
    for (0..10) |_| {
        const array = try arrayGenerator.generate(random, 10, std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 5), array.len);
    }
}

test "array generator respects element bounds" {
    // Generate [10]i32 arrays with elements between 5 and 15
    const arrayGenerator = gen([10]i32, .{
        .child_config = .{ .min = 5, .max = 15 },
    });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate arrays and check all elements are within bounds
    for (0..10) |_| {
        const array = try arrayGenerator.generate(random, 10, std.testing.allocator);

        for (array) |value| {
            try std.testing.expect(value >= 5 and value <= 15);
        }
    }
}

test "nested array generator works correctly" {
    // Generate [3][4]i32 arrays with elements between 1 and 100
    const nestedArrayGenerator = gen([3][4]i32, .{
        .child_config = .{
            .child_config = .{ .min = 1, .max = 100 },
        },
    });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate a nested array and check its structure and values
    const nested_array = try nestedArrayGenerator.generate(random, 10, std.testing.allocator);

    // Check outer array length
    try std.testing.expectEqual(@as(usize, 3), nested_array.len);

    // Check inner array lengths and element bounds
    for (nested_array) |inner_array| {
        try std.testing.expectEqual(@as(usize, 4), inner_array.len);

        for (inner_array) |value| {
            try std.testing.expect(value >= 1 and value <= 100);
        }
    }
}

test "array of booleans generator works correctly" {
    // Generate [8]bool arrays
    const boolArrayGenerator = gen([8]bool, .{
        .child_config = .{},
    });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate several arrays to ensure we get both true and false values
    var seen_true = false;
    var seen_false = false;

    for (0..10) |_| {
        const array = try boolArrayGenerator.generate(random, 10, std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 8), array.len);

        for (array) |value| {
            if (value) seen_true = true else seen_false = true;
        }

        if (seen_true and seen_false) break;
    }

    // We should have seen both true and false values
    try std.testing.expect(seen_true and seen_false);
}

test "array generator with map function" {
    // Generate [5]i32 arrays with elements between 1 and 10
    const baseArrayGenerator = gen([5]i32, .{
        .child_config = .{ .min = 1, .max = 10 },
    });

    // Map to double all elements
    const doubledArrayGenerator = baseArrayGenerator.map([5]i32, struct {
        fn doubleElements(array: [5]i32) [5]i32 {
            var result: [5]i32 = undefined;
            for (array, 0..) |value, i| {
                result[i] = value * 2;
            }
            return result;
        }
    }.doubleElements);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate arrays and check elements are doubled
    for (0..10) |_| {
        const array = try doubledArrayGenerator.generate(random, 10, std.testing.allocator);

        for (array) |value| {
            try std.testing.expect(value >= 2 and value <= 20);
            try std.testing.expect(@rem(value, 2) == 0); // All values should be even
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

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate slices and check their length is within range
    for (0..10) |_| {
        const slice = try sliceGenerator.generate(random, 10, std.testing.allocator);
        defer std.testing.allocator.free(slice);

        try std.testing.expect(slice.len >= 3 and slice.len <= 7);
    }
}

test "slice generator respects element bounds" {
    // Generate []i32 slices with elements between 5 and 15
    const sliceGenerator = gen([]i32, .{
        .min_len = 1,
        .max_len = 10,
        .child_config = .{ .min = 5, .max = 15 },
    });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate slices and check all elements are within bounds
    for (0..10) |_| {
        const slice = try sliceGenerator.generate(random, 10, std.testing.allocator);
        defer std.testing.allocator.free(slice);

        for (slice) |value| {
            try std.testing.expect(value >= 5 and value <= 15);
        }
    }
}

test "slice generator with map function" {
    // Generate []i32 slices with elements between 1 and 10
    const baseSliceGenerator = gen([]i32, .{
        .min_len = 3,
        .max_len = 5,
        .child_config = .{ .min = 1, .max = 10 },
    });

    // Map to double all elements in place
    const doubledSliceGenerator = baseSliceGenerator.map([]i32, struct {
        fn doubleElements(slice: []i32) []i32 {
            // Modify values in place
            for (slice) |*value| {
                value.* *= 2;
            }
            return slice; // Return the same slice
        }
    }.doubleElements);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate slices and check elements are doubled
    for (0..5) |_| {
        const slice = try doubledSliceGenerator.generate(random, 10, std.testing.allocator);
        defer std.testing.allocator.free(slice);

        for (slice) |value| {
            try std.testing.expect(value >= 2 and value <= 20);
            try std.testing.expect(@rem(value, 2) == 0); // All values should be even
        }
    }
}

test "nested slice generator works correctly" {
    // Generate [][]i32 slices with elements between 1 and 100
    const nestedSliceGenerator = gen([][]i32, .{
        .min_len = 2,
        .max_len = 4,
        .child_config = .{
            .min_len = 3,
            .max_len = 5,
            .child_config = .{ .min = 1, .max = 100 },
        },
    });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate a nested slice and check its structure and values
    const nested_slice = try nestedSliceGenerator.generate(random, 10, std.testing.allocator);
    defer {
        for (nested_slice) |inner_slice| {
            std.testing.allocator.free(inner_slice);
        }
        std.testing.allocator.free(nested_slice);
    }

    // Check outer slice length
    try std.testing.expect(nested_slice.len >= 2 and nested_slice.len <= 4);

    // Check inner slice lengths and element bounds
    for (nested_slice) |inner_slice| {
        try std.testing.expect(inner_slice.len >= 3 and inner_slice.len <= 5);

        for (inner_slice) |value| {
            try std.testing.expect(value >= 1 and value <= 100);
        }
    }
}

test "struct generator works correctly" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    // Generate Point structs with x between 0-10 and y between -5-5
    const pointGenerator = gen(Point, .{
        .x = .{ .min = 0, .max = 10 },
        .y = .{ .min = -5, .max = 5 },
    });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate points and check field bounds
    for (0..10) |_| {
        const point = try pointGenerator.generate(random, 10, std.testing.allocator);

        try std.testing.expect(point.x >= 0 and point.x <= 10);
        try std.testing.expect(point.y >= -5 and point.y <= 5);
    }
}

test "nested struct generator works correctly" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    const Rectangle = struct {
        top_left: Point,
        bottom_right: Point,
    };

    // Generate Rectangle structs with specific constraints using direct configuration
    const rectGenerator = gen(Rectangle, .{
        .top_left = .{
            .x = .{ .min = 0, .max = 10 },
            .y = .{ .min = 0, .max = 10 },
        },
        .bottom_right = .{
            .x = .{ .min = 20, .max = 30 },
            .y = .{ .min = 20, .max = 30 },
        },
    });

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate rectangles and check field bounds
    for (0..10) |_| {
        const rect = try rectGenerator.generate(random, 10, std.testing.allocator);

        // Check top_left point
        try std.testing.expect(rect.top_left.x >= 0 and rect.top_left.x <= 10);
        try std.testing.expect(rect.top_left.y >= 0 and rect.top_left.y <= 10);

        // Check bottom_right point
        try std.testing.expect(rect.bottom_right.x >= 20 and rect.bottom_right.x <= 30);
        try std.testing.expect(rect.bottom_right.y >= 20 and rect.bottom_right.y <= 30);
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

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Track which enum values we've seen
    var seen = [_]bool{false} ** 5;

    // Generate many values to ensure we get all enum variants
    for (0..100) |_| {
        const color = try colorGenerator.generate(random, 10, std.testing.allocator);

        // Verify it's a valid enum value
        switch (color) {
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

test "enum generator with non-zero values" {
    const Status = enum(u8) {
        pending = 10,
        active = 20,
        completed = 30,
        cancelled = 40,
    };

    // Create a generator for the Status enum
    const statusGenerator = gen(Status, .{});

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Track which enum values we've seen
    var seen = [_]bool{false} ** 4;

    // Generate many values to ensure we get all enum variants
    for (0..100) |_| {
        const status = try statusGenerator.generate(random, 10, std.testing.allocator);

        // Verify it's a valid enum value
        switch (status) {
            .pending => seen[0] = true,
            .active => seen[1] = true,
            .completed => seen[2] = true,
            .cancelled => seen[3] = true,
        }

        // Also verify the integer value is correct
        const int_value = @intFromEnum(status);
        switch (status) {
            .pending => try std.testing.expectEqual(@as(u8, 10), int_value),
            .active => try std.testing.expectEqual(@as(u8, 20), int_value),
            .completed => try std.testing.expectEqual(@as(u8, 30), int_value),
            .cancelled => try std.testing.expectEqual(@as(u8, 40), int_value),
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
