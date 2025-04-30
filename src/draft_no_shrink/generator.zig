const std = @import("std");
const FinitePrng = @import("../finite_prng.zig");
const FiniteRandom = FinitePrng.FiniteRandom;
const Ratio = FinitePrng.Ratio;
/// Core Generator type that produces random values of a specific type
pub fn Generator(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The type of values this generator produces
        pub const ValueType = T;

        /// Function that generates values
        generateFn: *const fn (random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!T,

        /// Generate a value
        pub fn generate(self: Self, random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!T {
            return self.generateFn(random, allocator);
        }

        /// Map a generator to a new type
        pub fn map(self: *const Self, comptime U: type, mapFn: *const fn (T) U) MappedGenerator(T, U) {
            return MappedGenerator(T, U){
                .parent = self,
                .map_fn = mapFn,
            };
        }

        /// Filter generated values
        pub fn filter(self: *const Self, filterFn: fn (T) bool) FilteredGenerator(T) {
            return FilteredGenerator(T){
                .parent = self,
                .filter_fn = filterFn,
            };
        }
    };
}

/// Core generator function that dispatches based on type
pub fn gen(comptime T: type, config: anytype) Generator(T) {
    if (@typeInfo(@TypeOf(config)) != .@"struct") {
        @compileError("Config must be a struct, got " ++ @typeName(@TypeOf(config)));
    }
    return switch (@typeInfo(T)) {
        .int => intGen(T, config),
        .float => floatGen(T, config),
        .bool => boolGen(config),
        .array => |info| arrayGen(info.child, info.len, gen(info.child, if (@hasField(@TypeOf(config), "child_config"))
            config.child_config
        else
            @compileError("Expected 'child_config' field for array type " ++ @typeName(T)))),
        .pointer => |info| switch (info.size) {
            .slice => sliceGen(info.child, gen(info.child, if (@hasField(@TypeOf(config), "child_config"))
                config.child_config
            else
                @compileError("Expected 'child_config' field for slice type " ++ @typeName(T))), config),
            .one => pointerGen(info.child, gen(info.child, if (@hasField(@TypeOf(config), "child_config"))
                config.child_config
            else
                .{})),
            else => @compileError("Cannot generate pointers except slices and single pointers"),
        },
        .@"struct" => structGen(T, config),
        .@"enum" => enumGen(T),
        .@"union" => |info| unionGen(T, info, config),
        .optional => |info| optionalGen(
            info.child,
            gen(info.child, if (@hasField(@TypeOf(config), "child_config"))
                config.child_config
            else
                .{}),
            config,
        ),
        .vector => |info| vectorGen(info.child, info.len, gen(info.child, if (@hasField(@TypeOf(config), "child_config"))
            config.child_config
        else
            @compileError("Expected 'child_config' field for vector type " ++ @typeName(T)))),
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

            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!T {
                _ = allocator;

                // Sometimes generate boundary values (20% of the time)
                if (try random.chance(.{ .numerator = 1, .denominator = 5 })) {
                    var boundaries: [7]T = undefined;
                    const count = getIntBoundaryValues(T, Min, Max, &boundaries);

                    const index = try random.intRangeLessThan(usize, 0, count);
                    return boundaries[index];
                }

                if (Max == std.math.maxInt(T)) {
                    // Special case for maximum value to avoid overflow
                    return try random.intRangeAtMost(T, Min, Max);
                } else {
                    return try random.intRangeLessThan(T, Min, Max + 1);
                }
            }
        }.generate,
    };
}

// Generate floats
fn floatGen(comptime T: type, config: anytype) Generator(T) {
    const min = if (@hasField(@TypeOf(config), "min")) config.min else -100.0;
    const max = if (@hasField(@TypeOf(config), "max")) config.max else 100.0;

    return Generator(T){
        .generateFn = struct {
            const Min = min;
            const Max = max;
            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!T {
                _ = allocator;

                // Sometimes generate special values (20% of the time)
                if (try random.chance(.{ .numerator = 1, .denominator = 5 })) {
                    var special_values: [8]T = undefined;
                    const count = getFloatSpecialValues(T, Min, Max, &special_values);

                    const index = try random.uintLessThan(usize, count);
                    return special_values[index];
                }

                // Otherwise generate a random value in the range
                return Min + (Max - Min) * (try random.floatNorm(T));
            }
        }.generate,
    };
}
//
// Generate booleans
fn boolGen(config: anytype) Generator(bool) {
    _ = config; // Unused for now, could add bias in the future

    return Generator(bool){
        .generateFn = struct {
            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!bool {
                _ = allocator;
                return try random.boolean();
            }
        }.generate,
    };
}

/// Generate arrays
fn arrayGen(comptime E: type, comptime len: usize, comptime child_gen: Generator(E)) Generator([len]E) {
    return Generator([len]E){
        .generateFn = struct {
            const ChildGen = child_gen;
            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }![len]E {
                var result: [len]E = undefined;
                for (&result) |*elem| {
                    elem.* = try ChildGen.generate(random, allocator);
                }
                return result;
            }
        }.generate,
    };
}

/// Generate slices
fn sliceGen(comptime E: type, comptime child_gen: Generator(E), config: anytype) Generator([]E) {
    const min_len = if (@hasField(@TypeOf(config), "min_len")) config.min_len else 0;
    const max_len = if (@hasField(@TypeOf(config), "max_len")) config.max_len else 100;

    return Generator([]E){
        .generateFn = struct {
            const ChildGen = child_gen;
            const MinLen = min_len;
            const MaxLen = max_len;

            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }![]E {
                const len = try random.intRangeLessThan(usize, MinLen, MaxLen + 1);
                const result = try allocator.alloc(E, len);

                for (result) |*elem| {
                    elem.* = try ChildGen.generate(random, allocator);
                }

                return result;
            }
        }.generate,
    };
}

/// Generate structs
fn structGen(comptime T: type, config: anytype) Generator(T) {
    const fields = std.meta.fields(T);

    return Generator(T){
        .generateFn = struct {
            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!T {
                var result: T = undefined;

                inline for (fields) |field| {
                    const FieldType = field.type;

                    // Get field-specific config if available
                    const field_config = if (@hasField(@TypeOf(config), field.name))
                        @field(config, field.name)
                    else
                        .{};

                    @field(result, field.name) = try gen(FieldType, field_config).generate(random, allocator);
                }

                return result;
            }
        }.generate,
    };
}

/// Generate enum values
fn enumGen(comptime T: type) Generator(T) {
    const enum_info = @typeInfo(T).@"enum";
    return Generator(T){
        .generateFn = struct {
            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!T {
                _ = allocator;
                const index = try random.intRangeLessThan(usize, 0, enum_info.fields.len);
                return std.enums.values(T)[index];
            }
        }.generate,
    };
}

fn optionalGen(comptime Child: type, comptime child_gen: Generator(Child), config: anytype) Generator(?Child) {
    // Default null probability if not specified
    const chance_ratio = if (@hasField(@TypeOf(config), "null_ratio")) blk: {
        const ratio_type = @TypeOf(config.null_ratio);

        // If it's already a Ratio, use it directly
        if (ratio_type == Ratio) {
            break :blk config.null_ratio;
        }

        // Otherwise, check if it has compatible fields with correct types
        if (!@hasField(ratio_type, "numerator") or !@hasField(ratio_type, "denominator")) {
            @compileError("null_ratio must have numerator and denominator fields");
        }

        // Create a new Ratio with the values from the provided struct
        break :blk Ratio{
            .numerator = config.null_ratio.numerator,
            .denominator = config.null_ratio.denominator,
        };
    } else Ratio{ .numerator = 1, .denominator = 2 }; // Default 1/2 ratio

    return Generator(?Child){
        .generateFn = struct {
            const ChildGen = child_gen;
            const chanceRatio = chance_ratio;

            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!?Child {
                // Generate null with probability from ratio
                if (try random.chance(chanceRatio)) {
                    return null;
                } else {
                    // Otherwise generate a value of the child type
                    return try ChildGen.generate(random, allocator);
                }
            }
        }.generate,
    };
}

/// Combine multiple generators with a tuple
pub fn tuple(comptime generators: anytype) blk: {
    const fields = std.meta.fields(@TypeOf(generators));
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| {
        const GenType = @TypeOf(@field(generators, field.name));
        types[i] = GenType.ValueType;
    }
    break :blk Generator(std.meta.Tuple(&types));
} {
    // Define the tuple type once
    const TupleType = comptime blk: {
        const fields = std.meta.fields(@TypeOf(generators));
        var types: [fields.len]type = undefined;
        for (fields, 0..) |field, i| {
            const GenType = @TypeOf(@field(generators, field.name));
            types[i] = GenType.ValueType;
        }
        break :blk std.meta.Tuple(&types);
    };

    return Generator(TupleType){
        .generateFn = struct {
            const Generators = generators;

            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!TupleType {
                var result: TupleType = undefined;

                inline for (std.meta.fields(@TypeOf(Generators)), 0..) |field, i| {
                    const genrt = @field(Generators, field.name);
                    result[i] = try genrt.generate(random, allocator);
                }

                return result;
            }
        }.generate,
    };
}

/// Choose between multiple generators
pub fn oneOf(comptime generators: anytype, comptime weights: ?[]const u64) blk: {
    // Get the type from the first generator
    const T = @TypeOf(generators[0]).ValueType;

    // Verify that all generators have the same output type
    for (generators) |genr| {
        if (@TypeOf(genr).ValueType != T) {
            @compileError("All generators must have the same output type");
        }
    }

    break :blk Generator(T);
} {
    // Get the type from the first generator
    const T = @TypeOf(generators[0]).ValueType;

    return Generator(T){
        .generateFn = struct {
            const Generators = generators;
            const Weights = weights;

            fn weightedChoice(rand: *FiniteRandom, weights_slice: []const u64) error{ OutOfMemory, OutOfEntropy }!usize {
                // Use integer weights directly
                var int_weights: [64]u64 = undefined; // Fixed size array to avoid allocation
                var total: u64 = 0;

                for (weights_slice, 0..) |w, i| {
                    if (i >= int_weights.len) break; // Safety check
                    int_weights[i] = w; // No conversion needed
                    total += int_weights[i];
                }

                // Pick a random number in the range [0, total)
                const pick = try rand.uintLessThan(u64, total);

                // Find the corresponding index
                var cumulative: u64 = 0;
                for (int_weights[0..@min(weights_slice.len, int_weights.len)], 0..) |w, i| {
                    cumulative += w;
                    if (pick < cumulative) return i;
                }

                return @min(weights_slice.len, int_weights.len) - 1;
            }

            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!T {
                const idx = if (Weights) |w|
                    try weightedChoice(random, w)
                else
                    try random.uintLessThan(usize, Generators.len);

                // Use inline for to handle each generator at compile time
                inline for (Generators, 0..) |genr, i| {
                    if (i == idx) {
                        return try genr.generate(random, allocator);
                    }
                }

                unreachable; // Should never reach here
            }
        }.generate,
    };
}

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

/// Generate single pointers
fn pointerGen(comptime Child: type, comptime child_gen: Generator(Child)) Generator(*Child) {
    return Generator(*Child){
        .generateFn = struct {
            const ChildGen = child_gen;

            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!*Child {
                const ptr = try allocator.create(Child);
                errdefer allocator.destroy(ptr);

                ptr.* = try ChildGen.generate(random, allocator);
                return ptr;
            }
        }.generate,
    };
}

/// Generate union values
fn unionGen(comptime T: type, info: std.builtin.Type.Union, config: anytype) Generator(T) {
    const field_names = comptime blk: {
        var names: [info.fields.len][]const u8 = undefined;
        for (info.fields, 0..) |field, i| {
            names[i] = field.name;
        }
        break :blk names;
    };

    return Generator(T){
        .generateFn = struct {
            const FieldNames = field_names;

            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!T {
                // Randomly select a field index
                const field_index = try random.intRangeLessThan(usize, 0, FieldNames.len);
                const field_name = FieldNames[field_index];

                // Use inline for to handle each field at compile time
                inline for (info.fields) |field| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        // Get field-specific config if available
                        const field_config = if (@hasField(@TypeOf(config), field.name))
                            @field(config, field.name)
                        else
                            .{};

                        // Generate a value for the selected field
                        const field_value = try gen(field.type, field_config).generate(random, allocator);

                        // Initialize the union with the generated value
                        return @unionInit(T, field.name, field_value);
                    }
                }

                unreachable; // Should never reach here
            }
        }.generate,
    };
}

/// Generate vectors
fn vectorGen(comptime E: type, comptime len: usize, comptime child_gen: Generator(E)) Generator(@Vector(len, E)) {
    return Generator(@Vector(len, E)){
        .generateFn = struct {
            const ChildGen = child_gen;
            fn generate(random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!@Vector(len, E) {
                var result: [len]E = undefined;
                for (&result) |*elem| {
                    elem.* = try ChildGen.generate(random, allocator);
                }
                return @as(@Vector(len, E), result);
            }
        }.generate,
    };
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

pub fn MappedGenerator(comptime T: type, comptime U: type) type {
    return struct {
        const MappedSelf = @This();

        /// The type of values this generator produces
        pub const ValueType = U;

        /// Parent generator
        parent: *const Generator(T),

        /// Mapping functions
        map_fn: *const fn (T) U,

        /// Context for mapped values
        const MapContext = struct {
            original_value: T,
            original_context: ?*anyopaque,
            context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,

            /// Free resources associated with this context
            fn deinit(ctx: ?*anyopaque, allocator: std.mem.Allocator) void {
                if (ctx) |ptr| {
                    const self_ctx: *@This() = @ptrCast(@alignCast(ptr));
                    if (self_ctx.original_context != null and self_ctx.context_deinit != null) {
                        self_ctx.context_deinit.?(self_ctx.original_context, allocator);
                    }
                    allocator.destroy(self_ctx);
                }
            }
        };

        /// Generate a mapped value
        pub fn generate(self: MappedSelf, random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!U {
            // Generate original value with context
            const original = try self.parent.generate(random, allocator);

            // Map the value
            const mapped_value = self.map_fn(original);

            return mapped_value;
        }
    };
}

pub fn FilteredGenerator(comptime T: type) type {
    return struct {
        const FilteredSelf = @This();

        /// The type of values this generator produces
        pub const ValueType = T;

        /// Parent generator
        parent: *const Generator(T),

        /// Filter function
        filter_fn: *const fn (T) bool,

        /// Generate a value that passes the filter
        pub fn generate(self: FilteredSelf, random: *FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!T {
            // Try a limited number of times to find a value that passes the filter
            var attempts: usize = 0;
            const max_attempts = 100;

            while (attempts < max_attempts) : (attempts += 1) {
                const value = try self.parent.generate(random, allocator);
                if (self.filter_fn(value)) return value;
            }

            // If we can't find a value after max attempts, return the last one anyway
            return self.parent.generate(random, allocator);
        }
    };
}
