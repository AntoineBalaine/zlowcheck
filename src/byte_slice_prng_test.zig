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

test "FinitePrng boolean" {
    // Test with known values - use a slice instead of an array
    const bytes = &[_]u8{ 0x01, 0x00 }; // 00000001 00000000
    var prng = FinitePrng.init(bytes);

    // First bit is 1
    const first_bit = try prng.boolean();
    try testing.expectEqual(true, first_bit);

    // Next 7 bits are 0
    try testing.expectEqual(false, try prng.boolean());
    try testing.expectEqual(false, try prng.boolean());
    try testing.expectEqual(false, try prng.boolean());
    try testing.expectEqual(false, try prng.boolean());
    try testing.expectEqual(false, try prng.boolean());
    try testing.expectEqual(false, try prng.boolean());
    try testing.expectEqual(false, try prng.boolean());

    // All bits in second byte are 0
    try testing.expectEqual(false, try prng.boolean());

    // Test many booleans with a separate instance
    const many_bytes = &[_]u8{0xFF} ** 4; // All 1s
    var many_prng = FinitePrng.init(many_bytes);

    for (0..32) |_| {
        try testing.expectEqual(true, try many_prng.boolean());
    }
}

test "FinitePrng enumValue" {
    const TestEnum = enum {
        A,
        B,
        C,
    };

    // Use enough bytes to ensure we can get all enum values
    const bytes = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04 };
    var prng = FinitePrng.init(&bytes);

    // Test that we can get enum values
    _ = try prng.enumValue(TestEnum);
    _ = try prng.enumValue(TestEnum);
    _ = try prng.enumValue(TestEnum);

    // Test with custom index type
    _ = try prng.enumValueWithIndex(TestEnum, u8);
}

test "FinitePrng int" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    var prng = FinitePrng.init(&bytes);

    // Test u8
    try testing.expectEqual(@as(u8, 0x12), try prng.int(u8));

    // Test u16
    try testing.expectEqual(@as(u16, 0x3456), try prng.int(u16));

    // Test u32
    try testing.expectEqual(@as(u32, 0x789ABCDE), try prng.int(u32));

    // Test i8 (signed)
    prng = FinitePrng.init(&bytes);
    try testing.expectEqual(@as(i8, 0x12), try prng.int(i8));

    // Test out of entropy
    const small_bytes = [_]u8{ 0x12, 0x34 };
    var small_prng = FinitePrng.init(&small_bytes);

    _ = try small_prng.int(u16); // Should succeed
    try testing.expectError(error.OutOfEntropy, small_prng.int(u16)); // Should fail
}

test "FinitePrng uintLessThan and uintLessThanBiased" {
    const bytes = [_]u8{ 0x05, 0x0A, 0x0F, 0x14, 0x19 };
    var prng = FinitePrng.init(&bytes);

    // Test uintLessThan
    try testing.expectEqual(@as(u8, 5), try prng.uintLessThan(u8, 10));
    try testing.expectEqual(@as(u8, 10), try prng.uintLessThan(u8, 15));

    // Test uintLessThanBiased
    prng = FinitePrng.init(&bytes);
    try testing.expectEqual(@as(u8, 5), try prng.uintLessThanBiased(u8, 10));
    try testing.expectEqual(@as(u8, 10), try prng.uintLessThanBiased(u8, 15));

    // Test edge cases
    try testing.expectEqual(@as(u8, 0), try prng.uintLessThan(u8, 1));
    try testing.expectEqual(@as(u8, 0), try prng.uintLessThanBiased(u8, 1));
}

test "FinitePrng uintAtMost and uintAtMostBiased" {
    const bytes = [_]u8{ 0x05, 0x0A, 0x0F, 0x14, 0x19 };
    var prng = FinitePrng.init(&bytes);

    // Test uintAtMost
    try testing.expectEqual(@as(u8, 5), try prng.uintAtMost(u8, 9));
    try testing.expectEqual(@as(u8, 10), try prng.uintAtMost(u8, 14));

    // Test uintAtMostBiased
    prng = FinitePrng.init(&bytes);
    try testing.expectEqual(@as(u8, 5), try prng.uintAtMostBiased(u8, 9));
    try testing.expectEqual(@as(u8, 10), try prng.uintAtMostBiased(u8, 14));
}

test "FinitePrng intRangeLessThan and intRangeLessThanBiased" {
    const bytes = [_]u8{ 0x05, 0x0A, 0x0F, 0x14, 0x19 };
    var prng = FinitePrng.init(&bytes);

    // Test intRangeLessThan
    try testing.expectEqual(@as(i8, 15), try prng.intRangeLessThan(i8, 10, 20));
    try testing.expectEqual(@as(i8, 30), try prng.intRangeLessThan(i8, 20, 30));

    // Test intRangeLessThanBiased
    prng = FinitePrng.init(&bytes);
    try testing.expectEqual(@as(i8, 15), try prng.intRangeLessThanBiased(i8, 10, 20));
    try testing.expectEqual(@as(i8, 30), try prng.intRangeLessThanBiased(i8, 20, 30));

    // Test edge case where at_least >= less_than
    try testing.expectEqual(@as(i8, 10), try prng.intRangeLessThan(i8, 10, 10));
    try testing.expectEqual(@as(i8, 10), try prng.intRangeLessThanBiased(i8, 10, 10));
}

test "FinitePrng intRangeAtMost and intRangeAtMostBiased" {
    const bytes = [_]u8{ 0x05, 0x0A, 0x0F, 0x14, 0x19 };
    var prng = FinitePrng.init(&bytes);

    // Test intRangeAtMost
    try testing.expectEqual(@as(i8, 15), try prng.intRangeAtMost(i8, 10, 19));
    try testing.expectEqual(@as(i8, 30), try prng.intRangeAtMost(i8, 20, 30));

    // Test intRangeAtMostBiased
    prng = FinitePrng.init(&bytes);
    try testing.expectEqual(@as(i8, 15), try prng.intRangeAtMostBiased(i8, 10, 19));
    try testing.expectEqual(@as(i8, 30), try prng.intRangeAtMostBiased(i8, 20, 30));
}

test "FinitePrng float" {
    const bytes = [_]u8{0x00} ** 8;
    var prng = FinitePrng.init(&bytes);

    // Test f32
    const f32_val = try prng.float(f32);
    try testing.expect(std.math.isFinite(f32_val));

    // Test f64
    const f64_val = try prng.float(f64);
    try testing.expect(std.math.isFinite(f64_val));
}

test "FinitePrng floatNorm" {
    const bytes = [_]u8{0x00} ** 8;
    var prng = FinitePrng.init(&bytes);

    // Test f32 norm
    const f32_norm = try prng.floatNorm(f32);
    try testing.expect(f32_norm >= 0 and f32_norm < 1);

    // Test f64 norm
    const f64_norm = try prng.floatNorm(f64);
    try testing.expect(f64_norm >= 0 and f64_norm < 1);
}

test "FinitePrng floatExp" {
    const bytes = [_]u8{0x80} ** 8; // Non-zero bytes to get non-zero floats
    var prng = FinitePrng.init(&bytes);

    // Test f32 exp
    const f32_exp = try prng.floatExp(f32);
    try testing.expect(f32_exp > 0);

    // Test f64 exp
    const f64_exp = try prng.floatExp(f64);
    try testing.expect(f64_exp > 0);
}

test "FinitePrng shuffle" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var prng = FinitePrng.init(&bytes);

    var array = [_]u8{ 1, 2, 3, 4, 5 };
    const original = [_]u8{ 1, 2, 3, 4, 5 };

    try prng.shuffle(u8, &array);

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
    try prng.shuffleWithIndex(u8, &array2, u8);
}

test "FinitePrng weightedIndex" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var prng = FinitePrng.init(&bytes);

    const weights = [_]u8{ 10, 20, 30, 40 };
    const index = try prng.weightedIndex(u8, &weights);

    // Check that the index is valid
    try testing.expect(index < weights.len);

    // Test error case with empty array
    const empty_weights = [_]u8{};
    try testing.expectError(error.OutOfEntropy, prng.weightedIndex(u8, &empty_weights));
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

    try testing.expect(!prng.isEmpty());

    // Consume all bytes
    _ = try prng.int(u16);

    try testing.expect(prng.isEmpty());
}
