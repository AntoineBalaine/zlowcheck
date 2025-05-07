const std = @import("std");
const testing = std.testing;

const FinitePrng = @import("finite_prng.zig");

test "FinitePrng initialization" {
    var bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };

    var prng = FinitePrng.init(&bytes);
    try testing.expect(!prng.isEmpty());
}

test "FinitePrng bytes" {
    var bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    var prng = FinitePrng.init(&bytes);

    var buf = [_]u8{0} ** 4;
    try prng.bytes(&buf);

    try testing.expectEqual(buf[0], 0x01);
    try testing.expectEqual(buf[1], 0x02);
    try testing.expectEqual(buf[2], 0x03);
    try testing.expectEqual(buf[3], 0x04);

    // Test that we've advanced in the stream
    try testing.expect(!prng.isEmpty());

    // Test out of entropy
    var large_buf = [_]u8{0} ** 10;
    try testing.expectError(error.OutOfEntropy, prng.bytes(&large_buf));
}

test "FinitePrng boolean with random() method" {
    var bytes = [_]u8{ 0x01, 0x00 };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();
    try testing.expectEqual(true, try rand.boolean());
    try testing.expectEqual(false, try rand.boolean());
}

test "FinitePrng int with random() method" {
    var bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test u8
    try testing.expectEqual(@as(u8, 0x12), try rand.int(u8));

    // Test u16
    try testing.expectEqual(@as(u16, 0x3456), try rand.int(u16));

    // Test u32
    try testing.expectEqual(@as(u32, 0x789ABCDE), try rand.int(u32));

    // Test i8 (signed)
    prng = FinitePrng.init(&bytes);
    rand = prng.random();
    try testing.expectEqual(@as(i8, 0x12), try rand.int(i8));

    // Test out of entropy
    var small_bytes = [_]u8{ 0x12, 0x34 };
    var small_prng = FinitePrng.init(&small_bytes);
    var small_rand = small_prng.random();

    _ = try small_rand.int(u16); // Should succeed
    try testing.expectError(error.OutOfEntropy, small_rand.int(u16)); // Should fail
}

test "FinitePrng uintLessThan with random() method" {
    // Use values that are above our limits to test the capping behavior
    var bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x05 };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test uintLessThan with different limits
    const val1 = try rand.uintLessThan(u8, 10);
    try testing.expect(val1 < 10);

    const val2 = try rand.uintLessThan(u8, 5);
    try testing.expect(val2 < 5);

    // Test edge case
    try testing.expectEqual(@as(u8, 0), try rand.uintLessThan(u8, 1));
}

test "FinitePrng enumValue with random() method" {
    const TestEnum = enum {
        A,
        B,
        C,
    };

    // Use enough bytes to ensure we can get all enum values
    var bytes = [_]u8{ 0x00, 0x01 } ** 32; // Much more data

    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test that we can get enum values
    _ = try rand.enumValue(TestEnum);
    _ = try rand.enumValue(TestEnum);
    _ = try rand.enumValue(TestEnum);

    // Test with custom index type
    _ = try rand.enumValueWithIndex(TestEnum, u8);
}

test "FinitePrng uintLessThanBiased with random() method" {
    var bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test uintLessThanBiased with different limits
    const val1 = try rand.uintLessThanBiased(u8, 10);
    try testing.expect(val1 < 10);

    const val2 = try rand.uintLessThanBiased(u8, 5);
    try testing.expect(val2 < 5);

    // Test edge case
    try testing.expectEqual(@as(u8, 0), try rand.uintLessThanBiased(u8, 1));
}

test "FinitePrng uintAtMost with random() method" {
    var bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test uintAtMost with different limits
    const val1 = try rand.uintAtMost(u8, 9);
    try testing.expect(val1 <= 9);

    const val2 = try rand.uintAtMost(u8, 4);
    try testing.expect(val2 <= 4);
}

test "FinitePrng uintAtMostBiased with random() method" {
    var bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test uintAtMostBiased with different limits
    const val1 = try rand.uintAtMostBiased(u8, 9);
    try testing.expect(val1 <= 9);

    const val2 = try rand.uintAtMostBiased(u8, 4);
    try testing.expect(val2 <= 4);
}

test "FinitePrng intRangeLessThan and intRangeLessThanBiased with random() method" {
    var bytes = [_]u8{0xFF} ** 32;
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test intRangeLessThan
    const val1 = try rand.intRangeLessThan(i8, 10, 20);
    try testing.expect(val1 >= 10 and val1 < 20);

    const val2 = try rand.intRangeLessThan(i8, -5, 5);
    try testing.expect(val2 >= -5 and val2 < 5);

    // Test intRangeLessThanBiased
    var prng2 = FinitePrng.init(&bytes);
    var rand2 = prng2.random();
    const val3 = try rand2.intRangeLessThanBiased(i8, 10, 20);
    try testing.expect(val3 >= 10 and val3 < 20);

    const val4 = try rand2.intRangeLessThanBiased(i8, -5, 5);
    try testing.expect(val4 >= -5 and val4 < 5);

    // Test edge case where at_least >= less_than
    try testing.expectEqual(@as(i8, 10), try rand2.intRangeLessThan(i8, 10, 10));
    try testing.expectEqual(@as(i8, 10), try rand2.intRangeLessThanBiased(i8, 10, 10));
}

test "FinitePrng intRangeAtMost and intRangeAtMostBiased with random() method" {
    var bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test intRangeAtMost
    const val1 = try rand.intRangeAtMost(i8, 10, 19);
    try testing.expect(val1 >= 10 and val1 <= 19);

    const val2 = try rand.intRangeAtMost(i8, -5, 5);
    try testing.expect(val2 >= -5 and val2 <= 5);

    // Test intRangeAtMostBiased
    var prng2 = FinitePrng.init(&bytes);
    var rand2 = prng2.random();
    const val3 = try rand2.intRangeAtMostBiased(i8, 10, 19);
    try testing.expect(val3 >= 10 and val3 <= 19);

    const val4 = try rand2.intRangeAtMostBiased(i8, -5, 5);
    try testing.expect(val4 >= -5 and val4 <= 5);
}

test "FinitePrng float with random() method" {
    var bytes = [_]u8{ 0x3F, 0x80, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; // More data with non-zero values
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test f32
    const f32_val = try rand.float(f32);
    try testing.expect(std.math.isFinite(f32_val));

    // Test f64
    const f64_val = try rand.float(f64);
    try testing.expect(std.math.isFinite(f64_val));
}

test "FinitePrng floatNorm with random() method" {
    var bytes = [_]u8{ 0x3F, 0x80, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; // More data with non-zero values
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test f32 norm
    const f32_norm = try rand.floatNorm(f32);
    try testing.expect(f32_norm >= 0 and f32_norm < 1);

    // Test f64 norm
    const f64_norm = try rand.floatNorm(f64);
    try testing.expect(f64_norm >= 0 and f64_norm < 1);
}

test "FinitePrng floatExp with random() method" {
    var bytes = [_]u8{ 0x3F, 0x80, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; // More data with non-zero values
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test f32 exp
    const f32_exp = try rand.floatExp(f32);
    try testing.expect(f32_exp > 0);

    // Test f64 exp
    const f64_exp = try rand.floatExp(f64);
    try testing.expect(f64_exp > 0);
}

test "FinitePrng shuffle with random() method" {
    // Increase the size of the byte array significantly
    // For an array of length 5, you need at least 5 random values
    // Each random value for usize might need 8 bytes (on 64-bit systems)
    // So provide plenty of data to be safe
    var bytes = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
        0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
        0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    };

    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();
    var array = [_]u8{ 1, 2, 3, 4, 5 };
    const original = [_]u8{ 1, 2, 3, 4, 5 };

    try rand.shuffle(u8, &array);

    // Check that the array was actually shuffled
    var is_different = false;
    for (array, 0..) |value, i| {
        if (value != original[i]) {
            is_different = true;
            break;
        }
    }
    try testing.expect(is_different);

    // Test shuffleWithIndex
    var array2 = [_]u8{ 1, 2, 3, 4, 5 };
    try rand.shuffleWithIndex(u8, &array2, u8);
}

test "FinitePrng weightedIndex with random() method" {
    var bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();
    const weights = [_]u8{ 10, 20, 30, 40 };
    const index = try rand.weightedIndex(u8, &weights);

    // Check that the index is valid
    try testing.expect(index < weights.len);

    // Test error case with empty array
    const empty_weights = [_]u8{};
    try testing.expectError(error.OutOfEntropy, rand.weightedIndex(u8, &empty_weights));
}

test "FinitePrng limitRangeBiased" {
    // This is a static function, so we don't need a PRNG instance
    try testing.expectEqual(@as(u8, 3), FinitePrng.limitRangeBiased(u8, 13, 10));
    try testing.expectEqual(@as(u8, 0), FinitePrng.limitRangeBiased(u8, 13, 1));
}

test "FinitePrng MinArrayIndex" {
    // This is a type function, so we just check the type
    try testing.expectEqual(u8, FinitePrng.MinArrayIndex(u8));
    try testing.expectEqual(usize, FinitePrng.MinArrayIndex(usize));
}

test "FinitePrng isEmpty" {
    var bytes = [_]u8{ 0x01, 0x02 };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();
    try testing.expect(!prng.isEmpty());

    // Consume all bytes
    _ = try rand.int(u16);

    try testing.expect(prng.isEmpty());
}

test "FinitePrng intRangeLessThanBiased with negative values using random() method" {
    var bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test with negative range
    const val1 = try rand.intRangeLessThanBiased(i8, -10, -5);
    try testing.expect(val1 >= -10 and val1 < -5);

    // Test with range crossing zero
    const val2 = try rand.intRangeLessThanBiased(i8, -5, 5);
    try testing.expect(val2 >= -5 and val2 < 5);

    // Test with both positive values
    const val3 = try rand.intRangeLessThanBiased(i8, 5, 10);
    try testing.expect(val3 >= 5 and val3 < 10);

    // Test edge case
    try testing.expectEqual(@as(i8, -10), try rand.intRangeLessThanBiased(i8, -10, -10));
}

test "FinitePrng random() method creates a fresh reader" {
    var bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var prng = FinitePrng.init(&bytes);

    // Create two separate random instances
    var rand1 = prng.random();

    // Both should read the same first byte
    try testing.expectEqual(@as(u8, 0x12), try rand1.int(u8));
    try testing.expectEqual(@as(u8, 0x34), try rand1.int(u8));
    var rand2 = prng.random();
    try testing.expectEqual(@as(u8, 0x12), try rand2.int(u8));
    try testing.expectEqual(@as(u8, 0x34), try rand2.int(u8));
}

test "enumWeighted" {
    const E = enum(u8) { a, b, c = 8 }; // 8 tests that the discriminant is used properly.

    // Use a fixed set of bytes for deterministic testing

    var bytes_: [4096]u8 = undefined;
    @import("test_helpers.zig").load_bytes(&bytes_);
    var prng = FinitePrng.init(&bytes_);
    var rand = prng.random();

    var count: struct { a: u32 = 0, b: u32 = 0, c: u32 = 0 } = .{};
    for (0..100) |_| {
        switch (try rand.enumWeighted(E, .{ .a = 0, .b = 1, .c = 2 })) {
            inline else => |tag| @field(count, @tagName(tag)) += 1,
        }
    }

    try std.testing.expectEqual(@as(u32, 0), count.a);
    try std.testing.expect(count.b < count.c);
    try std.testing.expectEqual(@as(u32, 0) + count.b + count.c, 100);
}

test "chance" {
    var bytes: [4096]u8 = undefined;
    @import("test_helpers.zig").load_bytes(&bytes);
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    var balance: i32 = 0;
    for (0..100) |_| {
        if (try rand.chance(.ratio(2, 7))) balance += 1 else balance -= 1;
        if (try rand.chance(.ratio(5, 7))) balance += 1 else balance -= 1;
    }
    try std.testing.expect(balance != 0);
}
test "Compare uintLessThan and uintLessThanMut entropy usage" {
    // Test with different integer types and bounds
    const TestCase = struct {
        name: []const u8,
        bound: u64,
        iterations: usize,
    };

    const test_cases = [_]TestCase{
        .{ .name = "u8 small bound", .bound = 10, .iterations = 100 },
        .{ .name = "u8 medium bound", .bound = 100, .iterations = 100 },
        .{ .name = "u8 large bound", .bound = 200, .iterations = 100 },
        .{ .name = "u16 small bound", .bound = 100, .iterations = 50 },
        .{ .name = "u16 medium bound", .bound = 1000, .iterations = 50 },
        .{ .name = "u16 large bound", .bound = 10000, .iterations = 50 },
        .{ .name = "u32 small bound", .bound = 1000, .iterations = 25 },
        .{ .name = "u32 medium bound", .bound = 100000, .iterations = 25 },
        .{ .name = "u32 large bound", .bound = 1000000000, .iterations = 25 },
    };

    std.debug.print("\nComparing entropy usage between uintLessThan and uintLessThanMut:\n", .{});
    std.debug.print("Test Case | Original Bytes | Mutated Bytes | Bytes Saved | % Saved\n", .{});
    std.debug.print("---------+---------------+--------------+------------+--------+----------\n", .{});

    var total_original_bytes: usize = 0;
    var total_mutated_bytes: usize = 0;

    inline for (test_cases) |test_case| {
        // Run test for u8
        if (std.mem.startsWith(u8, test_case.name, "u8")) {
            try runComparisonTest(
                u8,
                test_case.bound,
                test_case.iterations,
                test_case.name,
                &total_original_bytes,
                &total_mutated_bytes,
            );
        }
        // Run test for u16
        else if (std.mem.startsWith(u8, test_case.name, "u16")) {
            try runComparisonTest(
                u16,
                test_case.bound,
                test_case.iterations,
                test_case.name,
                &total_original_bytes,
                &total_mutated_bytes,
            );
        }
        // Run test for u32
        else if (std.mem.startsWith(u8, test_case.name, "u32")) {
            try runComparisonTest(
                u32,
                test_case.bound,
                test_case.iterations,
                test_case.name,
                &total_original_bytes,
                &total_mutated_bytes,
            );
        }
    }

    // Print overall statistics
    const total_saved = total_original_bytes - total_mutated_bytes;
    const total_percent_saved = if (total_original_bytes > 0)
        @as(f64, @floatFromInt(total_saved)) / @as(f64, @floatFromInt(total_original_bytes)) * 100.0
    else
        0.0;

    std.debug.print("---------+---------------+--------------+------------+--------+----------\n", .{});
    std.debug.print("Total    | {d:13} | {d:12} | {d:10} | {d:6.2}% \n", .{ total_original_bytes, total_mutated_bytes, total_saved, total_percent_saved });
}

fn runComparisonTest(
    comptime T: type,
    bound: u64,
    iterations: usize,
    name: []const u8,
    total_original_bytes: *usize,
    total_mutated_bytes: *usize,
) !void {
    // Create byte streams for testing
    var original_bytes: [4096]u8 = undefined;
    @import("test_helpers.zig").load_bytes(&original_bytes);

    var mutated_bytes: [4096]u8 = undefined;
    @memcpy(&mutated_bytes, &original_bytes);

    // Test original method
    var original_start_pos: usize = 0;
    var original_end_pos: usize = 0;
    {
        var prng = FinitePrng.init(original_bytes[0..]);
        var rand = prng.random();
        original_start_pos = rand.prng.fixed_buffer.pos;

        for (0..iterations) |_| {
            const value = try rand.uintLessThan(T, @intCast(bound));
            try std.testing.expect(value < bound);
        }

        original_end_pos = rand.prng.fixed_buffer.pos;
    }

    // Test mutation method
    var mutated_start_pos: usize = 0;
    var mutated_end_pos: usize = 0;
    {
        var prng = FinitePrng.init(mutated_bytes[0..]);
        var rand = prng.random();
        mutated_start_pos = rand.prng.fixed_buffer.pos;

        for (0..iterations) |_| {
            const value = try rand.uintLessThanMut(T, @intCast(bound));
            try std.testing.expect(value < bound);
        }

        mutated_end_pos = rand.prng.fixed_buffer.pos;

        // Also count changed byte locations for comparison
        var changed_locations: usize = 0;
        for (0..original_bytes.len) |i| {
            if (original_bytes[i] != mutated_bytes[i]) {
                changed_locations += 1;
            }
        }
    }

    // Calculate statistics
    const original_bytes_used = original_end_pos - original_start_pos;
    const mutated_bytes_used = mutated_end_pos - mutated_start_pos;
    const bytes_saved = if (original_bytes_used > mutated_bytes_used)
        original_bytes_used - mutated_bytes_used
    else
        0;
    const percent_saved = if (original_bytes_used > 0)
        @as(f64, @floatFromInt(bytes_saved)) / @as(f64, @floatFromInt(original_bytes_used)) * 100.0
    else
        0.0;

    // Update totals
    total_original_bytes.* += original_bytes_used;
    total_mutated_bytes.* += mutated_bytes_used;

    // Print results
    std.debug.print("{s:9} | {d:13} | {d:12} | {d:10} | {d:6.2}% \n", .{ name, original_bytes_used, mutated_bytes_used, bytes_saved, percent_saved });
}
