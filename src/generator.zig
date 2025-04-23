const std = @import("std");

/// Core Generator type that produces random values of a specific type
pub fn Generator(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Function that generates values
        generateFn: fn (random: std.Random, size: usize, allocator: std.mem.Allocator) error{OutOfMemory}!T,

        /// Generate a value
        pub fn generate(self: Self, random: std.Random, size: usize, allocator: std.mem.Allocator) !T {
            return self.generateFn(random, size, allocator);
        }

        /// Map a generator to a new type
        pub fn map(self: Self, comptime U: type, mapFn: fn (T) U) Generator(U) {
            return Generator(U){
                .generateFn = struct {
                    fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) !U {
                        const value = try self.generate(random, size, allocator);
                        return mapFn(value);
                    }
                }.generate,
            };
        }

        /// Filter generated values
        pub fn filter(self: Self, filterFn: fn (T) bool) Generator(T) {
            return Generator(T){
                .generateFn = struct {
                    fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) !T {
                        // Try a limited number of times to find a value that passes the filter
                        var attempts: usize = 0;
                        const max_attempts = 100;

                        while (attempts < max_attempts) : (attempts += 1) {
                            const value = try self.generate(random, size, allocator);
                            if (filterFn(value)) return value;
                        }

                        // If we can't find a value after max attempts, return the last one
                        return self.generate(random, size, allocator);
                    }
                }.generate,
            };
        }
    };
}

/// Core generator function that dispatches based on type
pub fn gen(comptime T: type, config: anytype) Generator(T) {
    return switch (@typeInfo(T)) {
        .int => intGen(T, config),
        .float => floatGen(T, config),
        .bool => boolGen(config),
        .array => |info| arrayGen(info.child, info.len, gen(info.child, if (@hasField(@TypeOf(config), "child_config"))
            config.child_config
        else
            @compileError("Expected 'child_config' field for array type " ++ @typeName(T)))),
        .pointer => |info| if (info.size == .slice)
            sliceGen(info.child, gen(info.child, if (@hasField(@TypeOf(config), "child_config"))
                config.child_config
            else
                @compileError("Expected 'child_config' field for slice type " ++ @typeName(T))), config)
        else
            @compileError("Cannot generate pointers except slices"),
        // .Struct => structGen(T, config),
        // .Enum => enumGen(T, config),
        else => @compileError("Cannot generate values of type " ++ @typeName(T)),
    };
}
/// Generate integers
fn intGen(comptime T: type, config: anytype) Generator(T) {
    // Default values if not specified
    const min = if (@hasField(@TypeOf(config), "min")) config.min else std.math.minInt(T);
    const max = if (@hasField(@TypeOf(config), "max")) config.max else std.math.maxInt(T);

    return Generator(T){
        .generateFn = struct {
            const Min = min;
            const Max = max;

            fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) !T {
                _ = size;
                _ = allocator;

                // Sometimes generate boundary values (20% of the time)
                if (random.float(f32) < 0.2) {
                    var boundaries: [7]T = undefined;
                    const count = getIntBoundaryValues(T, Min, Max, &boundaries);

                    const index = random.intRangeLessThan(usize, 0, count);
                    return boundaries[index];
                }

                // Otherwise generate a random value in the range
                return random.intRangeLessThan(T, Min, Max + 1);
            }
        }.generate,
    };
}

// /// Generate floats
fn floatGen(comptime T: type, config: anytype) Generator(T) {
    const min = if (@hasField(@TypeOf(config), "min")) config.min else -100.0;
    const max = if (@hasField(@TypeOf(config), "max")) config.max else 100.0;

    return Generator(T){
        .generateFn = struct {
            const Min = min;
            const Max = max;
            fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) !T {
                _ = size;
                _ = allocator;

                // Sometimes generate special values (20% of the time)
                if (random.float(f32) < 0.2) {
                    var special_values: [8]T = undefined;
                    const count = getFloatSpecialValues(T, Min, Max, &special_values);

                    const index = random.intRangeLessThan(usize, 0, count);
                    return special_values[index];
                }

                // Otherwise generate a random value in the range
                return Min + (Max - Min) * random.float(T);
            }
        }.generate,
    };
}
//
// /// Generate booleans
fn boolGen(config: anytype) Generator(bool) {
    _ = config; // Unused for now, could add bias in the future

    return Generator(bool){
        .generateFn = struct {
            fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) !bool {
                _ = size;
                _ = allocator;
                return random.boolean();
            }
        }.generate,
    };
}

/// Generate arrays
fn arrayGen(comptime E: type, comptime len: usize, child_gen: Generator(E)) Generator([len]E) {
    return Generator([len]E){
        .generateFn = struct {
            const ChildGen = child_gen;
            fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) ![len]E {
                var result: [len]E = undefined;
                for (&result) |*elem| {
                    elem.* = try ChildGen.generate(random, size, allocator);
                }
                return result;
            }
        }.generate,
    };
}

/// Generate slices
fn sliceGen(comptime E: type, child_gen: Generator(E), config: anytype) Generator([]E) {
    const min_len = if (@hasField(@TypeOf(config), "min_len")) config.min_len else 0;
    const max_len = if (@hasField(@TypeOf(config), "max_len")) config.max_len else 100;

    return Generator([]E){
        .generateFn = struct {
            const ChildGen = child_gen;
            const MinLen = min_len;
            const MaxLen = max_len;

            fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) ![]E {
                const len = random.intRangeLessThan(usize, MinLen, MaxLen + 1);
                const result = try allocator.alloc(E, len);

                for (result) |*elem| {
                    elem.* = try ChildGen.generate(random, size, allocator);
                }

                return result;
            }
        }.generate,
    };
}
//
// /// Generate structs
// fn structGen(comptime T: type, config: anytype) Generator(T) {
//     const fields = std.meta.fields(T);
//
//     return Generator(T){
//         .generateFn = struct {
//             fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) !T {
//                 var result: T = undefined;
//
//                 inline for (fields) |field| {
//                     const FieldType = field.type;
//                     const field_config = if (@hasField(@TypeOf(config), field.name))
//                         @field(config, field.name)
//                     else {};
//
//                     @field(result, field.name) = try gen(FieldType, field_config).generate(random, size, allocator);
//                 }
//
//                 return result;
//             }
//         }.generate,
//     };
// }
//
// /// Generate enum values
// fn enumGen(comptime T: type, config: anytype) Generator(T) {
//     _ = config; // Unused for now
//     const fields = std.meta.fields(T);
//
//     return Generator(T){
//         .generateFn = struct {
//             fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) !T {
//                 _ = size;
//                 _ = allocator;
//                 const index = random.intRangeLessThan(usize, 0, fields.len);
//                 return @field(T, fields[index].name);
//             }
//         }.generate,
//     };
// }
//
// /// Combine multiple generators with a tuple
// pub fn tuple(comptime generators: anytype) Generator(std.meta.Tuple(&generators)) {
//     const Tuple = std.meta.Tuple(&generators);
//
//     return Generator(Tuple){
//         .generateFn = struct {
//             fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) !Tuple {
//                 var result: Tuple = undefined;
//                 inline for (generators, 0..) |genr, i| {
//                     result[i] = try genr.generate(random, size, allocator);
//                 }
//                 return result;
//             }
//         }.generate,
//     };
// }
//
// /// Choose between multiple generators
// pub fn oneOf(comptime T: type, generators: []const Generator(T), weights: ?[]const f32) Generator(T) {
//     return Generator(T){
//         .generateFn = struct {
//             const Gens = generators;
//             const Weights = weights;
//
//             fn weightedChoice(rand: std.Random, weights_slice: []const f32) usize {
//                 var total: f32 = 0;
//                 for (weights_slice) |w| total += w;
//
//                 const r = rand.float(f32) * total;
//                 var cumulative: f32 = 0;
//
//                 for (weights_slice, 0..) |w, i| {
//                     cumulative += w;
//                     if (r < cumulative) return i;
//                 }
//
//                 return weights_slice.len - 1;
//             }
//
//             fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) !T {
//                 const idx = if (Weights) |w|
//                     weightedChoice(random, w)
//                 else
//                     random.uintLessThan(usize, Gens.len);
//
//                 return Gens[idx].generate(random, size, allocator);
//             }
//         }.generate,
//     };
// }
//
// /// Configuration for property testing
// pub const TestConfig = struct {
//     allocator: std.mem.Allocator,
//     cases: usize = 100,
//     seed: u64,
//     size: usize = 100,
//     maxFailures: usize = 10,
//     verbose: bool = false,
// };
//
// /// Run a property test
// pub fn forAll(comptime T: type, generator: Generator(T), property: fn (T) bool, config: TestConfig) !bool {
//     var prng = std.Random.DefaultPrng.init(config.seed);
//     var random = prng.random();
//
//     var success = true;
//     var failures: usize = 0;
//
//     for (0..config.cases) |i| {
//         var arena = std.heap.ArenaAllocator.init(config.allocator);
//         defer arena.deinit();
//
//         const value = try generator.generate(random, config.size, arena.allocator());
//         const result = property(value);
//
//         if (!result) {
//             success = false;
//             failures += 1;
//             std.debug.print("Test failed for input: {any}\n", .{value});
//
//             if (failures >= config.maxFailures) {
//                 std.debug.print("Too many failures, stopping test\n", .{});
//                 break;
//             }
//         } else if (config.verbose) {
//             std.debug.print("Test {}/{} passed with input: {any}\n", .{ i + 1, config.cases, value });
//         }
//     }
//
//     if (success) {
//         std.debug.print("All {} tests passed!\n", .{config.cases});
//     } else {
//         std.debug.print("{} of {} tests failed\n", .{ failures, config.cases });
//     }
//
//     return success;
// }
//
// /// Check a property (for use in tests)
// pub fn check(generator: anytype, property: anytype) !void {
//     const T = @TypeOf(generator).T;
//
//     const config = TestConfig{
//         .allocator = std.testing.allocator,
//         .cases = 100,
//         .seed = @intCast(@as(i64, std.time.milliTimestamp())),
//         .size = 100,
//         .maxFailures = 10,
//     };
//
//     const success = try forAll(T, generator, property, config);
//     try std.testing.expect(success);
// }
//
// test "addition is commutative" {
//     // Generate pairs of integers between -100 and 100
//     const pairGen = tuple(.{
//         gen(i32, .{ .min = -100, .max = 100 }),
//         gen(i32, .{ .min = -100, .max = 100 }),
//     });
//
//     // Define the property
//     const property = struct {
//         fn prop(pair: std.meta.Tuple(&.{ i32, i32 })) bool {
//             return pair[0] + pair[1] == pair[1] + pair[0];
//         }
//     }.prop;
//
//     // Check the property
//     try check(pairGen, property);
// }
//
// test "sorted array remains sorted after sorting" {
//     // Generate arrays of integers
//     const arrayGen = gen([10]i32, .{
//         .element_config = .{ .min = -50, .max = 50 },
//     });
//
//     // Define the property
//     const property = struct {
//         fn prop(arr: [10]i32) bool {
//             var copy = arr;
//             std.sort.sort(i32, &copy, {}, std.sort.asc(i32));
//
//             // Check if sorted
//             for (1..copy.len) |i| {
//                 if (copy[i - 1] > copy[i]) return false;
//             }
//             return true;
//         }
//     }.prop;
//
//     // Check the property
//     try check(arrayGen, property);
// }

/// Get boundary values for integer types
fn getIntBoundaryValues(comptime T: type, min_val: T, max_val: T, out_boundaries: []T) usize {
    var list = std.ArrayListUnmanaged(T).initBuffer(out_boundaries);
    var max_included = false;

    // Always include min boundary
    list.appendAssumeCapacity(min_val);
    if (min_val == max_val) max_included = true;

    if (min_val + 1 <= max_val) {
        list.appendAssumeCapacity(min_val + 1);
        if (min_val + 1 == max_val) max_included = true;
    }

    // Include -1, 0, 1 if within range
    if (@typeInfo(T).int.signedness == .signed and min_val <= -1 and max_val >= -1) {
        list.appendAssumeCapacity(-1);
        if (-1 == max_val) max_included = true;
    }

    if (min_val <= 0 and max_val >= 0) {
        list.appendAssumeCapacity(0);
        if (0 == max_val) max_included = true;
    }

    if (min_val <= 1 and max_val >= 1) {
        list.appendAssumeCapacity(1);
        if (1 == max_val) max_included = true;
    }

    if (max_val - 1 >= min_val) {
        list.appendAssumeCapacity(max_val - 1);
        if (max_val - 1 == max_val) max_included = true; // This is always false, but kept for consistency
    }

    // Always include max boundary if not already included
    if (!max_included) {
        list.appendAssumeCapacity(max_val);
    }

    return list.items.len;
}

/// Get special values for float types
fn getFloatSpecialValues(comptime T: type, min_val: T, max_val: T, out_values: []T) usize {
    var list = std.ArrayListUnmanaged(T).initBuffer(out_values);
    var max_included = false;

    // Always include min boundary
    list.appendAssumeCapacity(min_val);
    if (min_val == max_val) max_included = true;

    // Include 0 if it's within range
    if (min_val <= 0 and max_val >= 0) {
        list.appendAssumeCapacity(0);
        if (0 == max_val) max_included = true;
    }

    // Include -1 and 1 if within range
    if (min_val <= -1 and max_val >= -1) {
        list.appendAssumeCapacity(-1);
        if (-1 == max_val) max_included = true;
    }
    if (min_val <= 1 and max_val >= 1) {
        list.appendAssumeCapacity(1);
        if (1 == max_val) max_included = true;
    }

    // Include smallest normalized values if within range
    const smallest_pos = std.math.floatMin(T);
    if (min_val <= smallest_pos and max_val >= smallest_pos) {
        list.appendAssumeCapacity(smallest_pos);
        if (smallest_pos == max_val) max_included = true;
    }
    const smallest_neg = -std.math.floatMin(T);
    if (min_val <= smallest_neg and max_val >= smallest_neg) {
        list.appendAssumeCapacity(smallest_neg);
        if (smallest_neg == max_val) max_included = true;
    }

    // Include infinity if within range (only possible if max_val is infinity)
    if (max_val == std.math.inf(T)) {
        list.appendAssumeCapacity(std.math.inf(T));
        max_included = true;
    }
    if (min_val == -std.math.inf(T)) {
        list.appendAssumeCapacity(-std.math.inf(T));
        if (-std.math.inf(T) == max_val) max_included = true;
    }

    // Always include max boundary if not already included
    if (!max_included) {
        list.appendAssumeCapacity(max_val);
    }

    return list.items.len;
}
