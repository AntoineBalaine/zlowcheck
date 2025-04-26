const std = @import("std");
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const BitReader = @import("bitreader_std.zig");

const FinitePrng = @This();
bytes_: []const u8,
fixed_buffer: std.io.FixedBufferStream([]const u8),
bit_reader: BitReader.BitReader(.big),

pub const FinitePrngErr = error{
    OutOfEntropy,
};

pub fn init(bytes_: []const u8) FinitePrng {
    return .{
        .bytes_ = bytes_,
        .fixed_buffer = std.io.fixedBufferStream(bytes_),
        .bit_reader = BitReader.bitReader(.big),
    };
}

pub fn isEmpty(self: *const FinitePrng) bool {
    return self.fixed_buffer.pos >= self.bytes_.len;
}

pub fn bytes(self: *@This(), buf: []u8) !void {
    const bytes_read = try self.fixed_buffer.read(buf);
    if (bytes_read < buf.len) {
        return error.OutOfEntropy;
    }
}
pub fn random(self: *FinitePrng) FiniteRandom {
    self.fixed_buffer.pos = 0;
    self.bit_reader = BitReader.bitReader(.big); // Reset the bit reader to its initial state
    return .{
        .prng = self,
        .reader = self.fixed_buffer.reader(),
    };
}

/// The random API, with modified signatures to return errors.
/// Will error once it runs out of data.
pub const FiniteRandom = struct {
    prng: *FinitePrng,
    reader: std.io.FixedBufferStream([]const u8).Reader,

    // Methods that use the stored reader
    pub fn boolean(self: *@This()) !bool {
        var bits_read: u16 = undefined;
        const result = try self.prng.bit_reader.readBits(u1, 1, &bits_read, self.reader);
        if (bits_read == 0) return error.OutOfEntropy;
        return result == 1;
    }

    pub fn enumValue(self: *@This(), comptime EnumType: type) !EnumType {
        // Get all enum values at comptime
        const values = comptime std.enums.values(EnumType);
        // Get a random index at runtime
        const random_index = try self.uintLessThan(usize, values.len);
        // Return the enum value at that index
        return values[random_index];
    }

    pub fn enumValueWithIndex(self: *@This(), comptime EnumType: type, comptime Index: type) !EnumType {
        // Get all enum values at comptime
        const values = comptime std.enums.values(EnumType);
        // Get a random index at runtime with the specified index type
        const random_index = try self.uintLessThan(Index, values.len);
        // Return the enum value at that index
        return values[@intCast(random_index)];
    }

    pub fn int(self: *@This(), comptime T: type) !T {
        const bits = @typeInfo(T).int.bits;
        const UnsignedT = std.meta.Int(.unsigned, bits);

        var bits_read: u16 = undefined;
        const result = try self.prng.bit_reader.readBits(UnsignedT, bits, &bits_read, self.reader);
        if (bits_read < bits) return error.OutOfEntropy;

        if (@typeInfo(T).int.signedness == .signed) {
            return @bitCast(result);
        } else {
            return result;
        }
    }

    pub fn uintLessThanBiased(self: *@This(), comptime T: type, less_than: T) !T {
        if (less_than <= 1) return 0;

        // Get a random number and take the remainder when divided by less_than
        const rnd = try self.int(T);
        return @rem(rnd, less_than);
    }

    pub fn uintLessThan(self: *@This(), comptime T: type, less_than: T) !T {
        if (less_than <= 1) return 0;
        // NOTE: leaving this previous version in as reference
        // I couldn’t get it to work. I traded of for a different algo
        // which consume a LOT of data from the strea
        // Ensure we're using an unsigned type for log2_int_ceil
        // const bits_needed = std.math.log2_int_ceil(T, less_than);
        // const mask = (@as(T, 1) << @intCast(bits_needed)) - 1;
        // while (true) {
        //     var bits_read: u16 = undefined;
        //     const result = try self.bit_reader.readBits(T, @intCast(bits_needed), &bits_read, reader);
        //     if (bits_read < bits_needed) return error.OutOfEntropy;
        //     const masked_result = result & mask;
        //     if (masked_result < less_than) return masked_result;
        // }

        const bits = @typeInfo(T).int.bits;
        const WT = std.meta.Int(.unsigned, bits * 2); // Wider type for multiplication

        // Get a random number of the full range
        const rnd = try self.int(T);

        // Apply fast range algorithm
        const product = @as(WT, rnd) * @as(WT, less_than);
        return @as(T, @truncate(product >> bits));
    }

    pub fn uintAtMostBiased(self: *@This(), comptime T: type, at_most: T) !T {
        return try self.uintLessThanBiased(T, at_most + 1);
    }

    pub fn uintAtMost(self: *@This(), comptime T: type, at_most: T) !T {
        return try self.uintLessThan(T, at_most + 1);
    }

    pub fn intRangeLessThanBiased(self: *@This(), comptime T: type, at_least: T, less_than: T) !T {
        if (at_least >= less_than) return at_least;
        const range = less_than - at_least;

        // Use unsigned version for the range calculation if T is signed
        if (@typeInfo(T).int.signedness == .signed) {
            const UT = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
            const unsigned_result = try self.uintLessThanBiased(UT, @intCast(range));
            return at_least + @as(T, @intCast(unsigned_result));
        } else {
            const result = try self.uintLessThanBiased(T, range);
            return at_least + result;
        }
    }

    pub fn intRangeLessThan(self: *@This(), comptime T: type, at_least: T, less_than: T) !T {
        if (at_least >= less_than) return at_least;
        const range = less_than - at_least;

        // Use unsigned version for the range calculation if T is signed
        if (@typeInfo(T).int.signedness == .signed) {
            const UT = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
            const unsigned_result = try self.uintLessThan(UT, @intCast(range));
            return at_least + @as(T, @intCast(unsigned_result));
        } else {
            const result = try self.uintLessThan(T, range);
            return at_least + result;
        }
    }

    pub fn intRangeAtMostBiased(self: *@This(), comptime T: type, at_least: T, at_most: T) !T {
        return try self.intRangeLessThanBiased(T, at_least, at_most + 1);
    }

    pub fn intRangeAtMost(self: *@This(), comptime T: type, at_least: T, at_most: T) !T {
        return try self.intRangeLessThan(T, at_least, at_most + 1);
    }

    pub fn float(self: *@This(), comptime T: type) !T {
        switch (T) {
            f16 => {
                const rnd = try self.int(u16);
                return @bitCast(rnd);
            },
            f32 => {
                const rnd = try self.int(u32);
                return @bitCast(rnd);
            },
            f64 => {
                const rnd = try self.int(u64);
                return @bitCast(rnd);
            },
            else => @compileError("Unsupported float type: " ++ @typeName(T)),
        }
    }

    pub fn floatNorm(self: *@This(), comptime T: type) !T {
        // Generate a float in the range [0, 1)
        switch (T) {
            f32 => {
                const rnd = try self.int(u32);
                // Use the first 23 bits for the mantissa, discard the rest
                const result = @as(f32, @floatFromInt(rnd & 0x7FFFFF)) / @as(f32, @floatFromInt(0x800000));
                return result;
            },
            f64 => {
                const rnd = try self.int(u64);
                // Use the first 52 bits for the mantissa, discard the rest
                const result = @as(f64, @floatFromInt(rnd & 0xFFFFFFFFFFFFF)) / @as(f64, @floatFromInt(0x10000000000000));
                return result;
            },
            else => @compileError("Unsupported float type: " ++ @typeName(T)),
        }
    }

    pub fn floatExp(self: *@This(), comptime T: type) !T {
        // Generate a float with an exponential distribution
        const norm = try self.floatNorm(T);
        return -@log(norm);
    }

    pub fn shuffle(self: *@This(), comptime T: type, buf: []T) !void {
        // Fisher-Yates shuffle
        var i: usize = buf.len;
        while (i > 1) {
            i -= 1;
            const j = try self.uintLessThanBiased(usize, i + 1);
            std.mem.swap(T, &buf[i], &buf[j]);
        }
    }

    pub fn shuffleWithIndex(self: *@This(), comptime T: type, buf: []T, comptime Index: type) !void {
        // Fisher-Yates shuffle with custom index type
        var i: Index = @intCast(buf.len);
        while (i > 1) {
            i -= 1;
            const j = try self.uintLessThan(Index, i + 1);
            std.mem.swap(T, &buf[@intCast(i)], &buf[@intCast(j)]);
        }
    }

    pub fn weightedIndex(self: *@This(), comptime T: type, proportions: []const T) !usize {
        if (proportions.len == 0) return error.OutOfEntropy;

        // Calculate the sum of all proportions
        var sum: T = 0;
        for (proportions) |p| {
            sum += p;
        }

        // Generate a random value between 0 and sum
        const rand_val = try self.intRangeLessThan(T, 0, sum);

        // Find the index corresponding to the random value
        var partial_sum: T = 0;
        for (proportions, 0..) |p, i| {
            partial_sum += p;
            if (rand_val < partial_sum) return i;
        }

        // Fallback (should never happen unless sum calculation had rounding errors)
        return proportions.len - 1;
    }
};
pub fn limitRangeBiased(comptime T: type, random_int: T, less_than: T) T {
    if (less_than <= 1) return 0;
    return random_int % less_than;
}
pub fn MinArrayIndex(comptime Index: type) type {
    return Index;
}
