const std = @import("std");
const generator = @import("generator.zig");
const Generator = generator.Generator;
const gen = generator.gen;
const tuple = generator.tuple;
const oneOf = generator.oneOf;
const FinitePrng = @import("byte_slice_prng.zig");

fn load_bytes(buf: []u8) void {
    const current_time = std.time.milliTimestamp();
    var std_prng = std.Random.DefaultPrng.init(@intCast(current_time));
    var std_random = std_prng.random();
    std_random.bytes(buf);
}

test "int generator produces values within range" {
    // Create a generator for integers between 10 and 20
    const intGenerator = gen(i32, .{ .min = 10, .max = 20 });

    // Create random bytes using std lib's PRNG
    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate 100 values and check they're all within range
    for (0..100) |_| {
        const value = intGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
        try std.testing.expect(value >= 10 and value <= 20);
    }
}

test "int generator produces boundary values" {
    // Create a generator for integers
    const intGenerator = gen(i32, .{ .min = -100, .max = 100 });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

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
        const value = intGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate 100 values and check they're all within range
    for (0..100) |_| {
        const value = floatGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        // Skip NaN and infinity checks
        if (std.math.isNan(value) or std.math.isInf(value)) continue;

        try std.testing.expect(value >= -10.0 and value <= 10.0);
    }
}

test "float generator produces special values" {
    const floatGenerator = gen(f64, .{});

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Track special values we've seen
    var seen_zero = false;
    var seen_one = false;
    var seen_neg_one = false;
    var seen_min_pos = false;
    var seen_min_neg = false;

    // Generate many values to increase chance of hitting special values
    for (0..1000) |_| {
        const value = floatGenerator.generate(&random, std.testing.allocator) catch break;

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    var seen_true = false;
    var seen_false = false;

    // Generate values until we've seen both true and false
    for (0..100) |_| {
        const value = boolGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate values and check they're all doubled
    for (0..100) |_| {
        const value = doubledGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
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
    var bytes: [1024]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate values and check they're all positive
    for (0..100) |_| {
        const value = positiveGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue; // Skip this iteration and continue with the loop
        };
        try std.testing.expect(value > 0 and value <= 10);
    }
}

test "array generator produces arrays of the correct length" {
    // Generate [5]i32 arrays
    const arrayGenerator = gen([5]i32, .{
        .child_config = .{ .min = -10, .max = 10 },
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate a few arrays and check their length
    for (0..10) |_| {
        const array = arrayGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
        try std.testing.expectEqual(@as(usize, 5), array.len);
    }
}

test "array generator respects element bounds" {
    // Generate [10]i32 arrays with elements between 5 and 15
    const arrayGenerator = gen([10]i32, .{
        .child_config = .{ .min = 5, .max = 15 },
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate arrays and check all elements are within bounds
    for (0..10) |_| {
        const array = arrayGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate a nested array and check its structure and values
    const nested_array = nestedArrayGenerator.generate(&random, std.testing.allocator) catch {
        random = finite_prng.random();
        return;
    };

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate several arrays to ensure we get both true and false values
    var seen_true = false;
    var seen_false = false;

    for (0..10) |_| {
        const array = boolArrayGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate arrays and check elements are doubled
    for (0..10) |_| {
        const array = doubledArrayGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate slices and check their length is within range
    for (0..10) |_| {
        const slice = sliceGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate slices and check all elements are within bounds
    for (0..10) |_| {
        const slice = sliceGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate slices and check elements are doubled
    for (0..5) |_| {
        const slice = doubledSliceGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate a nested slice and check its structure and values
    const nested_slice = nestedSliceGenerator.generate(&random, std.testing.allocator) catch {
        random = finite_prng.random();
        return;
    };
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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate points and check field bounds
    for (0..10) |_| {
        const point = pointGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate rectangles and check field bounds
    for (0..10) |_| {
        const rect = rectGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Track which enum values we've seen
    var seen = [_]bool{false} ** 5;

    // Generate many values to ensure we get all enum variants
    for (0..100) |_| {
        const color = colorGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Track which enum values we've seen
    var seen = [_]bool{false} ** 4;

    // Generate many values to ensure we get all enum variants
    for (0..100) |_| {
        const status = statusGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

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

test "optional generator produces both null and values" {
    // Create a generator for optional integers
    const optIntGenerator = gen(?i32, .{
        .child_config = .{ .min = 1, .max = 100 },
        .null_probability = 0.5, // 50% chance of null
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    var seen_null = false;
    var seen_value = false;

    // Generate values until we've seen both null and non-null
    for (0..100) |_| {
        const value = optIntGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        if (value == null) {
            seen_null = true;
        } else {
            seen_value = true;
            // Check that non-null values respect the child generator's constraints
            try std.testing.expect(value.? >= 1 and value.? <= 100);
        }

        if (seen_null and seen_value) break;
    }

    // We should have seen both null and non-null values
    try std.testing.expect(seen_null and seen_value);
}

test "optional generator with custom null probability" {
    // Create generators with different null probabilities
    const rareNullGen = gen(?i32, .{
        .child_config = .{ .min = 1, .max = 100 },
        .null_probability = 0.1, // 10% chance of null
    });

    const frequentNullGen = gen(?i32, .{
        .child_config = .{ .min = 1, .max = 100 },
        .null_probability = 0.9, // 90% chance of null
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Count nulls for each generator
    var rare_null_count: usize = 0;
    var frequent_null_count: usize = 0;
    const iterations = 1000;

    for (0..iterations) |_| {
        const rare_value = rareNullGen.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
        const frequent_value = frequentNullGen.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        if (rare_value == null) rare_null_count += 1;
        if (frequent_value == null) frequent_null_count += 1;
    }

    // The generator with higher null probability should produce more nulls
    try std.testing.expect(frequent_null_count > rare_null_count);

    // Check that the null counts are roughly in line with the probabilities
    // (allowing for some statistical variation)
    const rare_null_ratio = @as(f32, @floatFromInt(rare_null_count)) / @as(f32, @floatFromInt(iterations));
    const frequent_null_ratio = @as(f32, @floatFromInt(frequent_null_count)) / @as(f32, @floatFromInt(iterations));

    try std.testing.expect(rare_null_ratio < 0.2); // Should be close to 0.1
    try std.testing.expect(frequent_null_ratio > 0.8); // Should be close to 0.9
}

test "single pointer generator works correctly" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    // Create a generator for pointers to Point structs
    const pointPtrGenerator = gen(*Point, .{
        .child_config = .{
            .x = .{ .min = 0, .max = 100 },
            .y = .{ .min = 0, .max = 100 },
        },
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate a pointer to a Point and check its values
    const point_ptr = pointPtrGenerator.generate(&random, std.testing.allocator) catch {
        random = finite_prng.random();
        return;
    };
    defer std.testing.allocator.destroy(point_ptr);

    try std.testing.expect(point_ptr.x >= 0 and point_ptr.x <= 100);
    try std.testing.expect(point_ptr.y >= 0 and point_ptr.y <= 100);
}

test "single pointer to primitive type" {
    // Create a generator for pointers to integers
    const intPtrGenerator = gen(*i32, .{
        .child_config = .{ .min = -50, .max = 50 },
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate several pointers and check their values
    for (0..10) |_| {
        const int_ptr = intPtrGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
        defer std.testing.allocator.destroy(int_ptr);

        try std.testing.expect(int_ptr.* >= -50 and int_ptr.* <= 50);
    }
}

test "pointer to array" {
    // Create a generator for pointers to arrays
    const arrayPtrGenerator = gen(*[3]bool, .{
        .child_config = .{
            .child_config = .{},
        },
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate a pointer to an array and check its values
    const array_ptr = try arrayPtrGenerator.generate(&random, std.testing.allocator);
    defer std.testing.allocator.destroy(array_ptr);

    try std.testing.expectEqual(@as(usize, 3), array_ptr.len);

    // Each element should be a valid boolean
    for (array_ptr) |value| {
        try std.testing.expect(value == true or value == false);
    }
}

test "untagged union generator produces valid values" {
    const Value = union(enum) {
        int: i32,
        float: f64,
        boolean: bool,
    };

    // Create a generator for the Value union
    const valueGenerator = gen(Value, .{
        .int = .{ .min = 1, .max = 100 },
        .float = .{ .min = -10.0, .max = 10.0 },
        .boolean = .{},
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);

    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Track which union variants we've seen
    var seen_int = false;
    var seen_float = false;
    var seen_boolean = false;

    // Generate many values to ensure we get all variants
    for (0..100) |_| {
        const value = valueGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        // Determine which variant we got and verify its constraints
        const active_tag = std.meta.activeTag(value);
        switch (active_tag) {
            .int => {
                seen_int = true;
                try std.testing.expect(value.int >= 1 and value.int <= 100);
            },
            .float => {
                seen_float = true;
                try std.testing.expect(value.float >= -10.0 and value.float <= 10.0);
            },
            .boolean => {
                seen_boolean = true;
                try std.testing.expect(value.boolean == true or value.boolean == false);
            },
        }

        if (seen_int and seen_float and seen_boolean) break;
    }

    // We should have seen all union variants
    try std.testing.expect(seen_int);
    try std.testing.expect(seen_float);
    try std.testing.expect(seen_boolean);
}

test "tagged union generator works correctly" {
    const Shape = union(enum) {
        circle: struct { radius: f32 },
        rectangle: struct { width: f32, height: f32 },
        triangle: struct { base: f32, height: f32 },
    };

    // Create a generator for the Shape union
    const shapeGenerator = gen(Shape, .{
        .circle = .{
            .radius = .{ .min = 1.0, .max = 10.0 },
        },
        .rectangle = .{
            .width = .{ .min = 1.0, .max = 20.0 },
            .height = .{ .min = 1.0, .max = 15.0 },
        },
        .triangle = .{
            .base = .{ .min = 1.0, .max = 10.0 },
            .height = .{ .min = 1.0, .max = 10.0 },
        },
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Track which union variants we've seen
    var seen_circle = false;
    var seen_rectangle = false;
    var seen_triangle = false;

    // Generate many values to ensure we get all variants
    for (0..100) |_| {
        const shape = shapeGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        // Verify the shape's constraints
        switch (shape) {
            .circle => |c| {
                seen_circle = true;
                try std.testing.expect(c.radius >= 1.0 and c.radius <= 10.0);
            },
            .rectangle => |r| {
                seen_rectangle = true;
                try std.testing.expect(r.width >= 1.0 and r.width <= 20.0);
                try std.testing.expect(r.height >= 1.0 and r.height <= 15.0);
            },
            .triangle => |t| {
                seen_triangle = true;
                try std.testing.expect(t.base >= 1.0 and t.base <= 10.0);
                try std.testing.expect(t.height >= 1.0 and t.height <= 10.0);
            },
        }

        if (seen_circle and seen_rectangle and seen_triangle) break;
    }

    // We should have seen all union variants
    try std.testing.expect(seen_circle);
    try std.testing.expect(seen_rectangle);
    try std.testing.expect(seen_triangle);
}

test "union with slice fields" {
    const Data = union(enum) {
        text: []u8,
        numbers: []i32,
    };

    // Create a generator for the Data union
    const dataGenerator = gen(Data, .{
        .text = .{
            .min_len = 5,
            .max_len = 10,
            .child_config = .{},
        },
        .numbers = .{
            .min_len = 3,
            .max_len = 6,
            .child_config = .{ .min = -10, .max = 10 },
        },
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate a few values and check their constraints
    for (0..10) |_| {
        const data = dataGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        // Use if/else instead of switch for the union
        if (data == .text) {
            const t = data.text;
            defer std.testing.allocator.free(t);
            try std.testing.expect(t.len >= 5 and t.len <= 10);
        } else if (data == .numbers) {
            const n = data.numbers;
            defer std.testing.allocator.free(n);
            try std.testing.expect(n.len >= 3 and n.len <= 6);

            for (n) |num| {
                try std.testing.expect(num >= -10 and num <= 10);
            }
        }
    }
}

test "vector generator produces vectors within range" {
    // Generate @Vector(4, i32) vectors
    const vectorGenerator = gen(@Vector(4, i32), .{
        .child_config = .{ .min = -10, .max = 10 },
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate a few vectors and check their values
    for (0..10) |_| {
        const vector = vectorGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        // Check each element is within bounds
        for (0..4) |i| {
            const value = vector[i];
            try std.testing.expect(value >= -10 and value <= 10);
        }
    }
}

test "vector generator with boolean elements" {
    // Generate @Vector(8, bool) vectors
    const boolVectorGenerator = gen(@Vector(8, bool), .{
        .child_config = .{},
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate several vectors to ensure we get both true and false values
    var seen_true = false;
    var seen_false = false;

    for (0..10) |_| {
        const vector = boolVectorGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        for (0..8) |i| {
            const value = vector[i];
            if (value) seen_true = true else seen_false = true;
        }

        if (seen_true and seen_false) break;
    }

    // We should have seen both true and false values
    try std.testing.expect(seen_true and seen_false);
}

test "vector generator with map function" {
    // Generate @Vector(4, f32) vectors with elements between 0.0 and 1.0
    const baseVectorGenerator = gen(@Vector(4, f32), .{
        .child_config = .{ .min = 0.0, .max = 1.0 },
    });

    // Map to scale all elements by 10
    const scaledVectorGenerator = baseVectorGenerator.map(@Vector(4, f32), struct {
        fn scaleElements(vector: @Vector(4, f32)) @Vector(4, f32) {
            const splt: @Vector(4, f32) = @splat(10.0);
            return vector * splt;
        }
    }.scaleElements);

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate vectors and check elements are scaled
    for (0..10) |_| {
        const vector = scaledVectorGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        for (0..4) |i| {
            const value = vector[i];
            // Skip NaN and infinity checks
            if (std.math.isNan(value) or std.math.isInf(value)) continue;
            try std.testing.expect(value >= 0.0 and value <= 10.0);
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

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate tuples and check their components
    for (0..10) |_| {
        const value = tupleGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        // Check that each component has the correct type and constraints
        const int_value: i32 = value[0];
        const bool_value: bool = value[1];
        const float_value: f64 = value[2];

        try std.testing.expect(int_value >= 1 and int_value <= 100);
        try std.testing.expect(bool_value == true or bool_value == false);

        // Skip NaN and infinity checks for float
        if (!std.math.isNan(float_value) and !std.math.isInf(float_value)) {
            try std.testing.expect(float_value >= -10.0 and float_value <= 10.0);
        }
    }
}

test "tuple generator with nested tuples" {
    // Create generators for different types
    const intGenerator = comptime gen(i32, .{ .min = 1, .max = 10 });
    const stringGenerator = comptime gen([]u8, .{
        .min_len = 3,
        .max_len = 5,
        .child_config = .{},
    });

    // Create a pair generator
    const pairGenerator = comptime tuple(.{ intGenerator, stringGenerator });

    // Create a generator that combines a bool with a pair
    const nestedTupleGenerator = tuple(.{ gen(bool, .{}), pairGenerator });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Generate nested tuples and check their components
    for (0..5) |_| {
        const value = nestedTupleGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        // First element is a boolean
        const bool_value: bool = value[0];
        try std.testing.expect(bool_value == true or bool_value == false);

        // Second element is a tuple of (i32, []u8)
        const pair = value[1];
        const int_value: i32 = pair[0];
        const string_value: []u8 = pair[1];
        defer std.testing.allocator.free(string_value);

        try std.testing.expect(int_value >= 1 and int_value <= 10);
        try std.testing.expect(string_value.len >= 3 and string_value.len <= 5);
    }
}

test "tuple generator for property testing" {
    // Generate pairs of integers
    const pairGenerator = tuple(.{
        gen(i32, .{ .min = -100, .max = 100 }),
        gen(i32, .{ .min = -100, .max = 100 }),
    });

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Test the commutative property of addition
    for (0..100) |_| {
        const pair = pairGenerator.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
        const a = pair[0];
        const b = pair[1];

        // Test that a + b == b + a
        try std.testing.expectEqual(a + b, b + a);
    }
}

test "oneOf selects from multiple generators" {
    // Create several integer generators with different ranges
    const smallIntGen = comptime gen(i32, .{ .min = 1, .max = 10 });
    const mediumIntGen = comptime gen(i32, .{ .min = 11, .max = 100 });
    const largeIntGen = comptime gen(i32, .{ .min = 101, .max = 1000 });

    // Combine them with oneOf
    const combinedGen = oneOf(.{ smallIntGen, mediumIntGen, largeIntGen }, null);

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Track which ranges we've seen
    var seen_small = false;
    var seen_medium = false;
    var seen_large = false;

    // Generate many values to ensure we get all ranges
    for (0..1000) |_| {
        const value = combinedGen.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        if (value >= 1 and value <= 10) seen_small = true;
        if (value >= 11 and value <= 100) seen_medium = true;
        if (value >= 101 and value <= 1000) seen_large = true;

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
    }.alwaysTrue);

    const falseGen = comptime gen(bool, .{}).map(bool, struct {
        fn alwaysFalse(_: bool) bool {
            return false;
        }
    }.alwaysFalse);

    // Create a heavily weighted generator that should mostly produce true
    const weights = [_]f32{ 0.9, 0.1 }; // 90% true, 10% false
    const weightedGen = oneOf(.{ trueGen, falseGen }, &weights);

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Count true/false values
    var true_count: usize = 0;
    var false_count: usize = 0;
    const iterations = 1000;

    for (0..iterations) |_| {
        const value = weightedGen.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };
        if (value) true_count += 1 else false_count += 1;
    }

    // We should get roughly 90% true values
    const true_ratio = @as(f32, @floatFromInt(true_count)) / @as(f32, @floatFromInt(iterations));
    try std.testing.expect(true_ratio > 0.8); // Allow some statistical variation
}

test "oneOf with union generators" {
    const Value = union(enum) {
        int: i32,
        float: f64,
    };

    // Create generators for each variant
    const intValueGen = comptime gen(i32, .{ .min = 1, .max = 100 }).map(Value, struct {
        fn toIntValue(i: i32) Value {
            return Value{ .int = i };
        }
    }.toIntValue);

    const floatValueGen = comptime gen(f64, .{ .min = 0.0, .max = 1.0 }).map(Value, struct {
        fn toFloatValue(f: f64) Value {
            return Value{ .float = f };
        }
    }.toFloatValue);

    // Combine them with oneOf
    const valueGen = oneOf(.{ intValueGen, floatValueGen }, null);

    var bytes: [4096]u8 = undefined;
    load_bytes(&bytes);
    var finite_prng = FinitePrng.init(&bytes);
    var random = finite_prng.random();

    // Track which variants we've seen
    var seen_int = false;
    var seen_float = false;

    // Generate values until we've seen both variants
    for (0..100) |_| {
        const value = valueGen.generate(&random, std.testing.allocator) catch {
            random = finite_prng.random();
            continue;
        };

        switch (value) {
            .int => |i| {
                seen_int = true;
                try std.testing.expect(i >= 1 and i <= 100);
            },
            .float => |f| {
                seen_float = true;
                try std.testing.expect(f >= 0.0 and f <= 1.0);
            },
        }

        if (seen_int and seen_float) break;
    }

    // We should have seen both variants
    try std.testing.expect(seen_int);
    try std.testing.expect(seen_float);
}
