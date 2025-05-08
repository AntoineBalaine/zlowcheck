//! Adapted from Random.std,
//! with modified implementation to
//! allow function signatures which return
//! OutOfEntropy errors.
//!
//! This PRNG operates on byte boundaries for simplicity and performance.
//! All operations consume whole bytes of entropy, with smaller types
//! still consuming at least one byte.
//!
//! The implementation includes mutation strategies to reduce entropy
//! consumption when generating values within specific ranges.

const std = @import("std");
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;
const maxInt = std.math.maxInt;

const FinitePrng = @This();

bytes_: []u8,
fixed_buffer: std.io.FixedBufferStream([]u8),

pub const FinitePrngErr = error{
    OutOfEntropy,
};

/// doesn’t accept byte sequences longer than 2³² bytes-long.
pub fn init(bytes_: []u8) FinitePrng {
    // Assert that the byte buffer isn't too large for our position tracking
    std.debug.assert(bytes_.len <= std.math.maxInt(u32));
    return .{
        .bytes_ = bytes_,
        .fixed_buffer = std.io.fixedBufferStream(bytes_),
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
    return .{
        .prng = self,
        .reader = self.fixed_buffer.reader(),
    };
}

/// Lifted from Tigerbeetle’s PRNG
/// A less than one rational number, used to specify probabilities.
pub const Ratio = struct {
    // Invariant: numerator ≤ denominator.
    numerator: u64,
    // Invariant: denominator ≠ 0.
    denominator: u64,

    pub fn format(
        r: Ratio,
        comptime fmt: []const u8,
        writer: anytype,
    ) !void {
        _ = fmt;
        return writer.print("{d}/{d}", .{ r.numerator, r.denominator });
    }

    pub fn parse_flag_value(value: []const u8) union(enum) { ok: Ratio, err: []const u8 } {
        const numerator_string, const denominator_string = std.mem.split(value, "/") orelse
            return .{ .err = "expected 'a/b' ratio, but found:" };

        const numerator = std.fmt.parseInt(u64, numerator_string, 16) catch
            return .{ .err = "invalid numerator:" };
        const denominator = std.fmt.parseInt(u64, denominator_string, 16) catch
            return .{ .err = "invalid denominator:" };
        if (numerator > denominator) {
            return .{ .err = "ratio greater than 1:" };
        }
        return .{ .ok = ratio(numerator, denominator) };
    }

    pub fn ratio(numerator: u64, denominator: u64) Ratio {
        assert(denominator > 0);
        assert(numerator <= denominator);
        return .{ .numerator = numerator, .denominator = denominator };
    }
};

/// The random API, with modified signatures to return errors.
/// Will error once it runs out of data.
pub const FiniteRandom = struct {
    prng: *FinitePrng,
    reader: std.io.FixedBufferStream([]u8).Reader,

    // Methods that use the stored reader
    pub fn boolean(self: *@This()) !bool {
        const byte = self.reader.readByte() catch return error.OutOfEntropy;
        return byte & 1 == 1;
    }

    pub fn enumValue(self: *@This(), comptime EnumType: type) !EnumType {
        return self.enumValueWithIndex(EnumType, usize);
    }

    pub fn enumValueWithIndex(self: *@This(), comptime EnumType: type, comptime Index: type) !EnumType {
        comptime assert(@typeInfo(EnumType) == .@"enum");
        // Get all enum values at comptime
        const values = comptime std.enums.values(EnumType);
        // Get a random index at runtime with the specified index type

        comptime assert(values.len > 0); // can't return anything
        comptime assert(maxInt(Index) >= values.len - 1); // can't access all values

        const index = if (comptime values.len - 1 == maxInt(Index))
            try self.int(Index)
        else
            try self.uintLessThan(Index, values.len);

        const MinInt = MinArrayIndex(Index);
        return values[@as(MinInt, @intCast(index))];
    }

    /// Returns the type used for enum weights.
    pub fn EnumWeightsType(E: type) type {
        return std.enums.EnumFieldStruct(E, u64, null);
    }

    /// Returns a random value of an enum, where probability is proportional to weight.
    pub fn enumWeighted(self: *@This(), comptime Enum: type, weights: EnumWeightsType(Enum)) !Enum {
        const fields = @typeInfo(Enum).@"enum".fields;
        var total: u64 = 0;
        inline for (fields) |field| {
            total += @field(weights, field.name);
        }
        assert(total > 0);
        var pick = try self.uintLessThan(u64, total);
        inline for (fields) |field| {
            const weight = @field(weights, field.name);
            if (pick < weight) return @as(Enum, @enumFromInt(field.value));
            pick -= weight;
        }
        unreachable;
    }

    /// Reads bytes in big-endian order (most significant first)
    pub fn int(self: *@This(), comptime T: type) !T {
        const bits = @typeInfo(T).int.bits;
        const bytes_needed = std.math.divCeil(usize, bits, 8) catch unreachable;

        const UT = std.meta.Int(.unsigned, bits);
        const U = if (bits < 8) u8 else UT; // Use u8 as minimum size for small types

        var rv: U = 0;

        for (0..bytes_needed) |_| {
            const byte = self.reader.readByte() catch |err| switch (err) {
                error.EndOfStream => return error.OutOfEntropy,
                else => |e| return e,
            };

            if (U == u8) rv = 0 else rv <<= 8;
            rv |= byte;
        }

        if (bits < 8) {
            if (@typeInfo(T).int.signedness == .signed) {
                return @bitCast(@as(UT, @truncate(rv)));
            } else {
                return @as(T, @truncate(rv));
            }
        }

        // For signed types, handle sign extension if needed
        if (@typeInfo(T).int.signedness == .signed) {
            return @bitCast(@as(UT, rv));
        } else {
            return @intCast(rv);
        }
    }

    pub fn uintLessThanBiased(self: *@This(), comptime T: type, less_than: T) !T {
        comptime assert(@typeInfo(T).int.signedness == .unsigned);
        assert(0 < less_than);
        if (less_than <= 1) return 0;

        // Get a random number and take the remainder when divided by less_than
        const rnd = try self.int(T);
        return @rem(rnd, less_than);
    }

    /// Find a value in range by doing rejection sampling.
    /// Since entropy is a finite resource here, this version of the API
    /// mutates the bytestream until it finds a valid value,
    /// instead of endlessly consuming entropy.
    pub fn uintLessThanMut(self: *@This(), comptime T: type, less_than: T) !T {
        comptime assert(@typeInfo(T).int.signedness == .unsigned);
        assert(0 < less_than);
        if (less_than <= 1) return 0;

        // Calculate threshold using wrapping negation
        const bias_thresh = (0 -% less_than) % less_than;

        const bits = @typeInfo(T).int.bits;
        const bytes_needed = comptime std.math.divCeil(usize, bits, 8) catch unreachable;

        var x: T = undefined;
        var mult: @TypeOf(math.mulWide(T, 0, 0)) = undefined;

        const pos = self.prng.fixed_buffer.pos;

        { // Try to generate a value
            x = try self.int(T);
            mult = math.mulWide(T, x, less_than);

            if (@as(T, @truncate(mult)) >= bias_thresh) {
                return @intCast(mult >> bits);
            }
        }

        var prng = std.Random.DefaultPrng.init(try self.int(u64));
        var rand = prng.random();
        var buf: [bytes_needed]u8 = undefined;

        while (true) {
            self.prng.fixed_buffer.pos = pos;
            rand.bytes(&buf);
            @memcpy(self.prng.fixed_buffer.buffer[pos .. pos + bytes_needed], buf[0..]);
            x = try self.int(T);
            mult = math.mulWide(T, x, less_than);
            if (@as(T, @truncate(mult)) >= bias_thresh) {
                return @intCast(mult >> bits);
            }
        }
    }

    pub fn uintLessThan(self: *@This(), comptime T: type, less_than: T) !T {
        comptime assert(@typeInfo(T).int.signedness == .unsigned);
        const bits = @typeInfo(T).int.bits;
        assert(0 < less_than);

        // adapted from:
        //   http://www.pcg-random.org/posts/bounded-rands.html
        // Calculate threshold using wrapping negation
        const t = (0 -% less_than) % less_than;

        // Generate random values until we find one that passes the threshold test
        var x: T = undefined;
        var m: @TypeOf(math.mulWide(T, 0, 0)) = undefined;
        var l: T = undefined;

        while (true) {
            x = try self.int(T);
            m = math.mulWide(T, x, less_than);
            l = @truncate(m);
            if (l >= t) break;
        }

        return @intCast(m >> bits);
    }

    pub fn uintAtMostBiased(self: *@This(), comptime T: type, at_most: T) !T {
        assert(@typeInfo(T).int.signedness == .unsigned);
        if (at_most == maxInt(T)) {
            // have the full range
            return self.int(T);
        }
        return try self.uintLessThanBiased(T, at_most + 1);
    }

    pub fn uintAtMost(self: *@This(), comptime T: type, at_most: T) !T {
        assert(@typeInfo(T).int.signedness == .unsigned);
        if (at_most == maxInt(T)) {
            // have the full range
            return self.int(T);
        }
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
        assert(at_least <= at_most);
        const info = @typeInfo(T).int;
        if (info.signedness == .signed) {
            // Two's complement makes this math pretty easy.
            const UnsignedT = std.meta.Int(.unsigned, info.bits);
            const lo: UnsignedT = @bitCast(at_least);
            const hi: UnsignedT = @bitCast(at_most);
            const result = lo +% try self.uintAtMost(UnsignedT, hi -% lo);
            return @bitCast(result);
        } else {
            if (at_most == std.math.maxInt(T)) {
                return self.int(T);
            }
            return try self.intRangeLessThan(T, at_least, at_most + 1);
        }
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

    /// lifted from Tigerbeetle’s PRNG
    pub fn chance(self: *@This(), probability: Ratio) !bool {
        assert(probability.denominator > 0);
        assert(probability.numerator <= probability.denominator);
        return try self.uintLessThan(u64, probability.denominator) < probability.numerator;
    }
};

pub fn limitRangeBiased(comptime T: type, random_int: T, less_than: T) T {
    if (less_than <= 1) return 0;
    return random_int % less_than;
}

pub fn MinArrayIndex(comptime Index: type) type {
    const index_info = @typeInfo(Index).int;
    assert(index_info.signedness == .unsigned);
    return if (index_info.bits >= @typeInfo(usize).int.bits) usize else Index;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("finite_prng_test.zig");
}
