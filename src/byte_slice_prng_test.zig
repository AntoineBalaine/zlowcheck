const std = @import("std");
const testing = std.testing;
const FinitePrng = @import("byte_slice_prng.zig");

test "FinitePrng initialization" {
    const bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var prng = FinitePrng.init(bytes);
    try testing.expect(!prng.isEmpty());
}

test "FinitePrng bytes" {
    const bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    var prng = FinitePrng.init(bytes);

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
    // Test with known values - use a slice instead of an array
    const bytes = &[_]u8{ 0x80, 0x00 }; // 10000000 00000000 in big endian
    var prng = FinitePrng.init(bytes);
    var rand = prng.random();

    // First bit is 1
    const first_bit = try rand.boolean();
    try testing.expectEqual(true, first_bit);

    // Next 7 bits are 0
    try testing.expectEqual(false, try rand.boolean());
    try testing.expectEqual(false, try rand.boolean());
    try testing.expectEqual(false, try rand.boolean());
    try testing.expectEqual(false, try rand.boolean());
    try testing.expectEqual(false, try rand.boolean());
    try testing.expectEqual(false, try rand.boolean());
    try testing.expectEqual(false, try rand.boolean());

    // All bits in second byte are 0
    try testing.expectEqual(false, try rand.boolean());

    // Test many booleans with a separate instance
    const many_bytes = &[_]u8{0xFF} ** 4; // All 1s
    var many_prng = FinitePrng.init(many_bytes);
    var many_rand = many_prng.random();

    for (0..32) |_| {
        try testing.expectEqual(true, try many_rand.boolean());
    }
}

test "FinitePrng enumValue with random() method" {
    const TestEnum = enum {
        A,
        B,
        C,
    };

    // Use enough bytes to ensure we can get all enum values
    const bytes = [_]u8{0x00} ** 32; // Much more data

    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test that we can get enum values
    _ = try rand.enumValue(TestEnum);
    _ = try rand.enumValue(TestEnum);
    _ = try rand.enumValue(TestEnum);

    // Test with custom index type
    _ = try rand.enumValueWithIndex(TestEnum, u8);
}

test "FinitePrng int with random() method" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
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
    const small_bytes = [_]u8{ 0x12, 0x34 };
    var small_prng = FinitePrng.init(&small_bytes);
    var small_rand = small_prng.random();

    _ = try small_rand.int(u16); // Should succeed
    try testing.expectError(error.OutOfEntropy, small_rand.int(u16)); // Should fail
}

test "FinitePrng uintLessThan with random() method" {
    // Use values that are above our limits to test the capping behavior
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
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

test "FinitePrng uintLessThanBiased with random() method" {
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
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
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test uintAtMost with different limits
    const val1 = try rand.uintAtMost(u8, 9);
    try testing.expect(val1 <= 9);

    const val2 = try rand.uintAtMost(u8, 4);
    try testing.expect(val2 <= 4);
}

test "FinitePrng uintAtMostBiased with random() method" {
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();

    // Test uintAtMostBiased with different limits
    const val1 = try rand.uintAtMostBiased(u8, 9);
    try testing.expect(val1 <= 9);

    const val2 = try rand.uintAtMostBiased(u8, 4);
    try testing.expect(val2 <= 4);
}

test "FinitePrng intRangeLessThan and intRangeLessThanBiased with random() method" {
    const bytes = [_]u8{0xFF} ** 32;
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
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
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
    const bytes = [_]u8{ 0x3F, 0x80, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; // More data with non-zero values
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
    const bytes = [_]u8{ 0x3F, 0x80, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; // More data with non-zero values
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
    const bytes = [_]u8{ 0x3F, 0x80, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; // More data with non-zero values
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
    const bytes = [_]u8{
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
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
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
    const bytes = [_]u8{ 0x01, 0x02 };
    var prng = FinitePrng.init(&bytes);
    var rand = prng.random();
    try testing.expect(!prng.isEmpty());

    // Consume all bytes
    _ = try rand.int(u16);

    try testing.expect(prng.isEmpty());
}

test "FinitePrng intRangeLessThanBiased with negative values using random() method" {
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
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

// ai? our current implementation doesn’t reset the fixed buffer stream position to 0,
// so any new ranodm() calls will not yield idem-potent results.
// What would be the most ergonomic for this? Maybe we’d need a reset() method??
test "FinitePrng random() method creates a fresh reader" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
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
