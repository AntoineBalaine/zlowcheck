const std = @import("std");
const FinitePrng = @import("finite_prng");
const FiniteRandom = FinitePrng.FiniteRandom;
const Ratio = FinitePrng.Ratio;

/// Byte position information for value generation
pub const BytePosition = struct {
    /// Start offset in the finite-prng’s byte slice
    start: u32,

    /// End offset in the finite-prng’s byte slice (bytes used)
    end: u32,
};

/// Value wrapper that stores both a generated value and its associated context.
///
/// The context is crucial for effective shrinking:
/// it makes the data-generation reproducible, even after multiple transforms.
pub fn Value(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The actual generated value
        value: T,

        /// Context associated with the value, used for shrinking
        /// The type is opaque because different generators need different context types
        context: ?*anyopaque,

        /// Context destructor function (if any)
        /// This is called when the value is no longer needed
        context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,

        /// Byte position information (optional for shrunk values)
        byte_pos: ?BytePosition,

        /// Initialize a new Value with a given value and context
        pub fn init(
            value: T,
            context: ?*anyopaque,
            context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
            byte_pos_opt: ?BytePosition,
        ) Self {
            return .{
                .value = value,
                .context = context,
                .context_deinit = context_deinit,
                .byte_pos = byte_pos_opt,
            };
        }

        /// Initialize a value with no context and optional byte positions
        /// If byte_pos is null, this is a shrunk value with no connection to the original byte slice
        pub fn initNoContext(value: T, byte_pos_opt: ?BytePosition) Self {
            return .{
                .value = value,
                .context = null,
                .context_deinit = null,
                .byte_pos = byte_pos_opt,
            };
        }

        /// Initialize a value with no context and no byte positions (for shrunk values)
        pub fn initShrunk(value: T) Self {
            return .{
                .value = value,
                .context = null,
                .context_deinit = null,
                .byte_pos = null,
            };
        }

        /// Cleanup the value's context if needed
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            if (self.context != null and self.context_deinit != null) {
                self.context_deinit.?(self.context, allocator);
            }
        }

        /// Get the byte slice that generated this value, if available
        pub fn bytes(self: Self, original_bytes: []const u8) ?[]const u8 {
            return if (self.byte_pos) |pos|
                original_bytes[pos.start..pos.end]
            else
                null;
        }

        /// Returns the number of bytes used to generate this value, if available
        pub fn byteLength(self: Self) ?u32 {
            return if (self.byte_pos) |pos|
                pos.end - pos.start
            else
                null;
        }
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

            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(TupleType) {
                const start_pos = random.prng.fixed_buffer.pos;

                // Create a tuple context
                const TupleContext = struct {
                    // Dynamic array to hold element contexts
                    element_contexts: std.ArrayList(?*anyopaque),
                    element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),

                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                        if (ctx) |ptr| {
                            const self_ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));

                            // Call deinit on each element context
                            for (self_ctx.element_contexts.items, self_ctx.element_deinits.items) |elem_ctx, deinit_fn| {
                                if (deinit_fn) |deinit_fn_| {
                                    deinit_fn_(elem_ctx, alloc);
                                }
                            }

                            // Free the arrays
                            self_ctx.element_contexts.deinit();
                            self_ctx.element_deinits.deinit();

                            // Free the context itself
                            alloc.destroy(self_ctx);
                        }
                    }
                };

                // Create the context
                var context = try allocator.create(TupleContext);
                context.* = .{
                    .element_contexts = std.ArrayList(?*anyopaque).init(allocator),
                    .element_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                };

                // Generate each element
                var result: TupleType = undefined;

                inline for (std.meta.fields(@TypeOf(Generators)), 0..) |field, i| {
                    const genrt = @field(Generators, field.name);
                    const element_value = try genrt.generate(random, allocator);
                    result[i] = element_value.value;

                    // Store the context if any
                    if (element_value.context != null) {
                        try context.element_contexts.append(element_value.context.?);
                        try context.element_deinits.append(element_value.context_deinit.?);
                    } else {
                        try context.element_contexts.append(null);
                        try context.element_deinits.append(null);
                    }
                }

                const end_pos = random.prng.fixed_buffer.pos;

                return Value(TupleType).init(
                    result,
                    @as(*anyopaque, @ptrCast(context)),
                    TupleContext.deinit,
                    .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                );
            }
        }.generate,

        .shrinkFn = struct {
            const Generators = generators;
            fn shrink(value: TupleType, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(TupleType) {
                if (context == null) {
                    // Can't shrink without context
                    return ValueList(TupleType).init(&[_]Value(TupleType){}, allocator);
                }

                const tuple_ctx = @as(*struct {
                    element_contexts: std.ArrayList(?*anyopaque),
                    element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                }, @ptrCast(@alignCast(context)));

                // For tuples, we shrink one element at a time
                var all_shrinks = std.ArrayList(Value(TupleType)).init(allocator);
                defer all_shrinks.deinit();

                // Try shrinking each element
                inline for (std.meta.fields(@TypeOf(Generators)), 0..) |field, i| {
                    const genrt = @field(Generators, field.name);
                    const elem_ctx = tuple_ctx.element_contexts.items[i];
                    const elem_shrinks = try genrt.shrink(value[i], elem_ctx, allocator);
                    defer elem_shrinks.deinit();

                    // For each shrunk element, create a new tuple with just that element shrunk
                    for (elem_shrinks.values) |shrunk_elem| {
                        // Create a new tuple context
                        const new_ctx = try allocator.create(struct {
                            element_contexts: std.ArrayList(?*anyopaque),
                            element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                        });
                        new_ctx.* = .{
                            .element_contexts = std.ArrayList(?*anyopaque).init(allocator),
                            .element_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                        };

                        // Copy the original contexts except for the one we're shrinking
                        for (tuple_ctx.element_contexts.items, tuple_ctx.element_deinits.items, 0..) |ctx, deinit_fn, j| {
                            if (j == i) {
                                // Use the shrunk element's context
                                try new_ctx.element_contexts.append(shrunk_elem.context);
                                try new_ctx.element_deinits.append(shrunk_elem.context_deinit);
                            } else {
                                // Copy the original context
                                try new_ctx.element_contexts.append(ctx);
                                try new_ctx.element_deinits.append(deinit_fn);
                            }
                        }

                        // Create a new tuple with the shrunk element
                        var new_tuple = value;
                        new_tuple[i] = shrunk_elem.value;

                        // Add to our list of shrinks
                        try all_shrinks.append(Value(TupleType).init(
                            new_tuple,
                            @as(*anyopaque, @ptrCast(new_ctx)),
                            struct {
                                fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                    if (ctx) |ptr| {
                                        const self_ctx = @as(*struct {
                                            element_contexts: std.ArrayList(?*anyopaque),
                                            element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                                        }, @ptrCast(@alignCast(ptr)));

                                        // Call deinit on each element context
                                        for (self_ctx.element_contexts.items, self_ctx.element_deinits.items) |ctx_elem, deinit_fn| {
                                            if (deinit_fn) |deinit_fn_| {
                                                deinit_fn_(ctx_elem, alloc);
                                            }
                                        }

                                        // Free the arrays
                                        self_ctx.element_contexts.deinit();
                                        self_ctx.element_deinits.deinit();

                                        // Free the context itself
                                        alloc.destroy(self_ctx);
                                    }
                                }
                            }.deinit,
                            null, // These are shrunk values with no byte position
                        ));
                    }
                }

                return ValueList(TupleType).init(try all_shrinks.toOwnedSlice(), allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: TupleType) bool {
                // Tuples need context for proper shrinking
                _ = value;
                return false;
            }
        }.canShrinkWithoutContext,
    };
}

test tuple {
    // Create generators for different types
    const intGenerator = comptime gen(i32, .{ .min = 1, .max = 100 });
    const boolGenerator = comptime gen(bool, .{});
    const floatGenerator = comptime gen(f64, .{ .min = -10.0, .max = 10.0 });

    // Combine them into a tuple generator
    const tupleGenerator = tuple(.{ intGenerator, boolGenerator, floatGenerator });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    @import("test_helpers").load_bytes(&bytes);

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

/// Choose between multiple generators
pub fn oneOf(comptime generators: anytype, comptime weights: ?[]const u32) blk: {
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

            fn weightedChoice(rand: *FiniteRandom, weights_slice: []const u32) error{ OutOfMemory, OutOfEntropy }!usize {
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

            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(T) {
                const start_pos = random.prng.fixed_buffer.pos;

                const idx = if (Weights) |w|
                    try weightedChoice(random, w)
                else
                    try random.uintLessThan(usize, Generators.len);

                // Use inline for to handle each generator at compile time
                inline for (Generators, 0..) |genr, i| {
                    if (i == idx) {
                        // Create a oneOf context
                        const OneOfContext = struct {
                            generator_index: usize,
                            value_context: ?*anyopaque,
                            context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,

                            fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                if (ctx) |ptr| {
                                    const self_ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));

                                    // Call deinit on the value context if any
                                    if (self_ctx.value_context != null and self_ctx.context_deinit != null) {
                                        self_ctx.context_deinit.?(self_ctx.value_context, alloc);
                                    }

                                    // Free the context itself
                                    alloc.destroy(self_ctx);
                                }
                            }
                        };

                        // Generate the value
                        const value = try genr.generate(random, allocator);
                        const end_pos = random.prng.fixed_buffer.pos;

                        // Create the context
                        const context = try allocator.create(OneOfContext);
                        context.* = .{
                            .generator_index = i,
                            .value_context = value.context,
                            .context_deinit = value.context_deinit,
                        };

                        return Value(T).init(
                            value.value,
                            @as(*anyopaque, @ptrCast(context)),
                            OneOfContext.deinit,
                            .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                        );
                    }
                }

                unreachable; // Should never reach here
            }
        }.generate,

        .shrinkFn = struct {
            const Generators = generators;
            fn shrink(value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T) {
                if (context == null) {
                    // Can't shrink without context
                    return ValueList(T).init(&[_]Value(T){}, allocator);
                }

                const oneOf_ctx = @as(*struct {
                    generator_index: usize,
                    value_context: ?*anyopaque,
                    context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                }, @ptrCast(@alignCast(context)));

                // Use the original generator to shrink the value
                inline for (Generators, 0..) |genr, i| {
                    if (i == oneOf_ctx.generator_index) {
                        const shrinks = try genr.shrink(value, oneOf_ctx.value_context, allocator);
                        defer shrinks.deinit();

                        // Create a new oneOf context for each shrunk value
                        var result = try allocator.alloc(Value(T), shrinks.len());

                        for (shrinks.values, 0..) |shrunk_value, j| {
                            // Create a new context
                            const new_ctx = try allocator.create(struct {
                                generator_index: usize,
                                value_context: ?*anyopaque,
                                context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                            });
                            new_ctx.* = .{
                                .generator_index = i,
                                .value_context = shrunk_value.context,
                                .context_deinit = shrunk_value.context_deinit,
                            };

                            // Store the result
                            result[j] = Value(T).init(
                                shrunk_value.value,
                                @as(*anyopaque, @ptrCast(new_ctx)),
                                struct {
                                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                        if (ctx) |ptr| {
                                            const self_ctx = @as(*struct {
                                                generator_index: usize,
                                                value_context: ?*anyopaque,
                                                context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                                            }, @ptrCast(@alignCast(ptr)));

                                            // Call deinit on the value context if any
                                            if (self_ctx.value_context != null and self_ctx.context_deinit != null) {
                                                self_ctx.context_deinit.?(self_ctx.value_context, alloc);
                                            }

                                            // Free the context itself
                                            alloc.destroy(self_ctx);
                                        }
                                    }
                                }.deinit,
                                null, // These are shrunk values with no byte position
                            );
                        }

                        return ValueList(T).init(result, allocator);
                    }
                }

                // If we get here, something went wrong
                return ValueList(T).init(&[_]Value(T){}, allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: T) bool {
                // oneOf needs context for proper shrinking
                _ = value;
                return false;
            }
        }.canShrinkWithoutContext,
    };
}

test oneOf {
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
    const weights = [_]u32{ 90, 10 }; // 90% true, 10% false
    const weightedGen = oneOf(.{ trueGen, falseGen }, &weights);

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;
    @import("test_helpers").load_bytes(&bytes);

    // Create a finite PRNG
    var prng = FinitePrng.init(&bytes);
    var random = prng.random();

    // Count true/false values
    var true_count: usize = 0;
    var false_count: usize = 0;
    // Use fewer iterations to avoid running out of entropy
    const iterations = 50;

    for (0..iterations) |_| {
        const value = try weightedGen.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        if (value.value) true_count += 1 else false_count += 1;
    }

    // We should get roughly 90% true values
    const true_ratio = @as(f32, @floatFromInt(true_count)) / @as(f32, @floatFromInt(iterations));
    try std.testing.expect(true_ratio > 0.8); // Allow some statistical variation
}

/// A list of values with the same type.
///
/// These get output as lists of options
/// by the generators during shrinking.
pub fn ValueList(comptime T: type) type {
    return struct {
        const Self = @This();

        values: []Value(T),
        allocator: std.mem.Allocator,

        /// Initialize a new value list
        pub fn init(values: []Value(T), allocator: std.mem.Allocator) Self {
            return .{
                .values = values,
                .allocator = allocator,
            };
        }

        /// Free the list and all values' contexts
        pub fn deinit(self: Self) void {
            for (self.values) |value| {
                value.deinit(self.allocator);
            }
            self.allocator.free(self.values);
        }

        /// Get the number of values in the list
        pub fn len(self: Self) usize {
            return self.values.len;
        }
    };
}

/// Trait checker for generator types
pub fn isGenerator(comptime T: type) bool {
    return @hasDecl(T, "ValueType") and
        @hasField(T, "generateFn") and
        @hasField(T, "shrinkFn") and
        @hasField(T, "canShrinkWithoutContextFn");
}

/// Core Generator type that produces random values of a specific type and can shrink them
pub fn Generator(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The type of values this generator produces
        pub const ValueType = T;

        /// Function that generates values with context
        generateFn: *const fn (random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(T),

        /// Function that shrinks values using their context
        shrinkFn: *const fn (value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T),

        /// Function that checks if a value can be shrunk without context
        canShrinkWithoutContextFn: *const fn (value: T) bool,

        /// Generate a value with its context
        ///
        /// Errors:
        /// - OutOfMemory: If memory allocation fails
        /// - OutOfEntropy: If the PRNG runs out of random data
        pub fn generate(self: Self, random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(T) {
            return self.generateFn(random, allocator);
        }

        /// Shrink a value using its context
        pub fn shrink(self: Self, value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T) {
            return self.shrinkFn(value, context, allocator);
        }

        /// Check if a value can be shrunk without context
        pub fn canShrinkWithoutContext(self: Self, value: T) bool {
            return self.canShrinkWithoutContextFn(value);
        }

        /// Map a generator to a new type.
        ///
        /// The map function provides a mechanism that allows us to apply a transform to a generated datum. And in the case where we need to shrink that datum (upon a predicate failure), it also provides a mechanism to: revert the transform, shrink, and re-apply.
        ///
        /// This unmap/shrink/remap can be applied for values coming from a generator, and also for values that have been provided without a generator. This allows library consumers to run pbt with pre-defined values, instead of being prisonners of the generators.
        ///
        /// When it comes to un-map data coming from generators,it’s possible to confidently do so using the original generator’s context and the original value. For values not coming from a generator, we have to rely on a user-provided unmap function which can apply the reverse transform - though the confidence level with this approach is lower, since it’s not provided by the library.
        pub fn map(self: *const Self, comptime U: type, mapFn: *const fn (T) U, unmapFn: ?*const fn (U) ?T) MappedGenerator(T, U) {
            return MappedGenerator(T, U){
                .parent = self,
                .map_fn = mapFn,
                .unmap_fn = unmapFn,
            };
        }

        /// Filter generated values
        ///
        /// Similarly to the map function, the filter function applies a filter to a generator’s output list. For sanity’s sake, the filter is only allowed to run 100 unsuccessful tries. Any value that is filtered out is de-initialized. When it comes to shrinking, Filter’s shrink() will call the original generator’s shrink method and reapply the filtering.
        pub fn filter(self: *const Self, filterFn: *const fn (T) bool) FilteredGenerator(T) {
            return FilteredGenerator(T){
                .parent = self,
                .filter_fn = filterFn,
            };
        }
    };
}

/// Generate booleans
fn boolGen(config: anytype) Generator(bool) {
    _ = config; // Unused for now, could add bias in the future

    return Generator(bool){
        .generateFn = struct {
            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(bool) {
                _ = allocator;
                const start_pos = random.prng.fixed_buffer.pos;
                const value = random.boolean();
                const end_pos = random.prng.fixed_buffer.pos;
                const value_result = try value;
                return Value(bool).initNoContext(
                    value_result,
                    .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                );
            }
        }.generate,

        .shrinkFn = struct {
            fn shrink(value: bool, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(bool) {
                _ = context;

                // Only true can be shrunk (to false)
                if (value) {
                    var result = try allocator.alloc(Value(bool), 1);
                    result[0] = Value(bool).initNoContext(false, null);
                    return ValueList(bool).init(result, allocator);
                } else {
                    // Can't shrink false
                    return ValueList(bool).init(&[_]Value(bool){}, allocator);
                }
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: bool) bool {
                // Only true can be shrunk (to false)
                return value;
            }
        }.canShrinkWithoutContext,
    };
}

/// Implementation of integer shrinking
fn intShrink(comptime T: type, value: T, context: ?*anyopaque, allocator: std.mem.Allocator) !ValueList(T) {
    _ = context; // Integer shrinking doesn't need context

    if (value == 0) {
        // Can't shrink 0 any further
        return ValueList(T).init(&[_]Value(T){}, allocator);
    }

    // For non-zero integers, we have several shrinking strategies:

    // 1. Shrink towards 0 (divide by 2)
    // 2. Try boundaries near 0 (0, 1, -1)
    // 3. Try absolute value (for negative numbers)

    var shrink_candidates = std.ArrayList(Value(T)).init(allocator);
    defer shrink_candidates.deinit();

    // Strategy 1: Shrink towards 0 (divide by 2)
    if (value != 0) {
        // TODO: switch to using .initShrink decl literal
        try shrink_candidates.append(Value(T).initNoContext(@divTrunc(value, 2), null));
    }

    // Strategy 2: Try boundaries near 0
    if (value > 1) {
        try shrink_candidates.append(Value(T).initNoContext(1, null));
        try shrink_candidates.append(Value(T).initNoContext(0, null));
    } else if (value < -1) {
        try shrink_candidates.append(Value(T).initNoContext(-1, null));
        try shrink_candidates.append(Value(T).initNoContext(0, null));
    }

    // Strategy 3: For negative numbers, try absolute value
    if (value < 0) {
        try shrink_candidates.append(Value(T).initNoContext(-value, null));
    }

    return ValueList(T).init(try shrink_candidates.toOwnedSlice(), allocator);
}

/// Generate arrays
fn arrayGen(comptime E: type, comptime len: usize, comptime child_gen: Generator(E)) Generator([len]E) {
    return Generator([len]E){
        .generateFn = struct {
            const ChildGen = child_gen;
            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value([len]E) {
                const start_pos = random.prng.fixed_buffer.pos;

                // Create an array context to hold all element contexts
                const ArrayContext = struct {
                    // Dynamic array to hold element contexts
                    element_contexts: std.ArrayList(?*anyopaque),
                    element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),

                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                        if (ctx) |ptr| {
                            const self_ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));

                            // Call deinit on each element context
                            for (self_ctx.element_contexts.items, self_ctx.element_deinits.items) |elem_ctx, deinit_fn| {
                                if (deinit_fn) |deinit_fn_| {
                                    deinit_fn_(elem_ctx, alloc);
                                }
                            }

                            // Free the arrays
                            self_ctx.element_contexts.deinit();
                            self_ctx.element_deinits.deinit();

                            // Free the context itself
                            alloc.destroy(self_ctx);
                        }
                    }
                };

                // Create the context
                var context = try allocator.create(ArrayContext);
                context.* = .{
                    .element_contexts = std.ArrayList(?*anyopaque).init(allocator),
                    .element_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                };

                // Generate each element
                var result: [len]E = undefined;
                for (&result) |*elem| {
                    const element_value = try ChildGen.generate(random, allocator);
                    elem.* = element_value.value;

                    // Store the context if any
                    if (element_value.context != null) {
                        try context.element_contexts.append(element_value.context.?);
                        try context.element_deinits.append(element_value.context_deinit.?);
                    } else {
                        try context.element_contexts.append(null);
                        try context.element_deinits.append(null);
                    }
                }

                const end_pos = random.prng.fixed_buffer.pos;

                return Value([len]E).init(
                    result,
                    @as(*anyopaque, @ptrCast(context)),
                    ArrayContext.deinit,
                    .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                );
            }
        }.generate,

        .shrinkFn = struct {
            const ChildGen = child_gen;
            fn shrink(value: [len]E, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList([len]E) {
                if (context == null) {
                    // Can't shrink without context
                    return ValueList([len]E).init(&[_]Value([len]E){}, allocator);
                }

                const array_ctx = @as(*struct {
                    element_contexts: std.ArrayList(?*anyopaque),
                    element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                }, @ptrCast(@alignCast(context)));

                // For arrays, we shrink one element at a time
                var all_shrinks = std.ArrayList(Value([len]E)).init(allocator);
                defer all_shrinks.deinit();

                // Try shrinking each element
                for (value, 0..) |elem, i| {
                    const elem_ctx = array_ctx.element_contexts.items[i];
                    const elem_shrinks = try ChildGen.shrink(elem, elem_ctx, allocator);
                    defer elem_shrinks.deinit();

                    // For each shrunk element, create a new array with just that element shrunk
                    for (elem_shrinks.values) |shrunk_elem| {
                        // Create a new array context
                        const new_ctx = try allocator.create(struct {
                            element_contexts: std.ArrayList(?*anyopaque),
                            element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                        });
                        new_ctx.* = .{
                            .element_contexts = std.ArrayList(?*anyopaque).init(allocator),
                            .element_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                        };

                        // Copy the original contexts except for the one we're shrinking
                        for (array_ctx.element_contexts.items, array_ctx.element_deinits.items, 0..) |ctx, deinit_fn, j| {
                            if (j == i) {
                                // Use the shrunk element's context
                                try new_ctx.element_contexts.append(shrunk_elem.context);
                                try new_ctx.element_deinits.append(shrunk_elem.context_deinit);
                            } else {
                                // Copy the original context
                                try new_ctx.element_contexts.append(ctx);
                                try new_ctx.element_deinits.append(deinit_fn);
                            }
                        }

                        // Create a new array with the shrunk element
                        var new_array = value;
                        new_array[i] = shrunk_elem.value;

                        // Add to our list of shrinks
                        try all_shrinks.append(Value([len]E).init(
                            new_array,
                            @as(*anyopaque, @ptrCast(new_ctx)),
                            struct {
                                fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                    if (ctx) |ptr| {
                                        const self_ctx = @as(*struct {
                                            element_contexts: std.ArrayList(?*anyopaque),
                                            element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                                        }, @ptrCast(@alignCast(ptr)));

                                        // Call deinit on each element context
                                        for (self_ctx.element_contexts.items, self_ctx.element_deinits.items) |ctx_elem, deinit_fn| {
                                            if (deinit_fn) |deinit_fn_| {
                                                deinit_fn_(ctx_elem, alloc);
                                            }
                                        }

                                        // Free the arrays
                                        self_ctx.element_contexts.deinit();
                                        self_ctx.element_deinits.deinit();

                                        // Free the context itself
                                        alloc.destroy(self_ctx);
                                    }
                                }
                            }.deinit,
                            null,
                        ));
                    }
                }

                return ValueList([len]E).init(try all_shrinks.toOwnedSlice(), allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            const ChildGen = child_gen;
            fn canShrinkWithoutContext(value: [len]E) bool {
                // Arrays need context for proper shrinking
                _ = value;
                return false;
            }
        }.canShrinkWithoutContext,
    };
}

/// Enhanced integer generator with shrinking
fn intGen(comptime T: type, config: anytype) Generator(T) {
    // Default values if not specified
    const min = if (@hasField(@TypeOf(config), "min")) config.min else std.math.minInt(T);
    const max = if (@hasField(@TypeOf(config), "max")) config.max else std.math.maxInt(T);

    return Generator(T){
        .generateFn = struct {
            const Min = min;
            const Max = max;

            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(T) {
                _ = allocator;
                const start_pos = random.prng.fixed_buffer.pos;

                // Sometimes generate boundary values (20% of the time)
                if (try random.chance(.{ .numerator = 1, .denominator = 5 })) {
                    var boundaries: [7]T = undefined;
                    const count = getIntBoundaryValues(T, Min, Max, &boundaries);

                    const index = try random.uintLessThan(usize, count);
                    const end_pos = random.prng.fixed_buffer.pos;
                    return Value(T).initNoContext(boundaries[index], .{ .start = @intCast(start_pos), .end = @intCast(end_pos) });
                }

                var value: T = undefined;
                if (Max == std.math.maxInt(T)) {
                    // Special case for maximum value to avoid overflow
                    value = try random.intRangeAtMost(T, Min, Max);
                } else {
                    value = try random.intRangeLessThan(T, Min, Max + 1);
                }

                const end_pos = random.prng.fixed_buffer.pos;
                return Value(T).initNoContext(value, .{ .start = @intCast(start_pos), .end = @intCast(end_pos) });
            }
        }.generate,

        .shrinkFn = struct {
            const Min = min;
            const Max = max;

            fn shrink(value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T) {
                // Use the generic int shrinking logic
                const all_shrinks = try intShrink(T, value, context, allocator);
                var valid_count: usize = 0;

                // Count valid shrinks (within range)
                for (all_shrinks.values) |shrnk| {
                    if (shrnk.value >= Min and shrnk.value <= Max) {
                        valid_count += 1;
                    }
                }

                // Filter to only include values in range
                var filtered = try allocator.alloc(Value(T), valid_count);
                var index: usize = 0;

                for (all_shrinks.values) |shrnk| {
                    if (shrnk.value >= Min and shrnk.value <= Max) {
                        filtered[index] = shrnk;
                        index += 1;
                    } else {
                        // No need to call deinit since integers don't have context to clean up
                    }
                }

                // Deinit the original list without deiniting the values
                allocator.free(all_shrinks.values);

                return ValueList(T).init(filtered, allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: T) bool {
                // Integers can always be shrunk without context,
                // as long as they are within the valid range
                return value >= min and value <= max;
            }
        }.canShrinkWithoutContext,
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

            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value([]E) {
                const start_pos = random.prng.fixed_buffer.pos;
                const len = try random.uintLessThan(usize, MaxLen - MinLen + 1) + MinLen;

                // Create a slice context to hold all element contexts
                const SliceContext = struct {
                    // The slice itself (so we can free it)
                    slice: []E,
                    // Dynamic array to hold element contexts
                    element_contexts: std.ArrayList(?*anyopaque),
                    element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),

                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                        if (ctx) |ptr| {
                            const self_ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));

                            // Call deinit on each element context
                            for (self_ctx.element_contexts.items, self_ctx.element_deinits.items) |elem_ctx, deinit_fn| {
                                if (deinit_fn) |deinit_fn_| {
                                    deinit_fn_(elem_ctx, alloc);
                                }
                            }

                            // Free the slice
                            alloc.free(self_ctx.slice);

                            // Free the arrays
                            self_ctx.element_contexts.deinit();
                            self_ctx.element_deinits.deinit();

                            // Free the context itself
                            alloc.destroy(self_ctx);
                        }
                    }
                };

                // Allocate the slice
                const result = try allocator.alloc(E, len);
                errdefer allocator.free(result);

                // Create the context
                var context = try allocator.create(SliceContext);
                context.* = .{
                    .slice = result,
                    .element_contexts = std.ArrayList(?*anyopaque).init(allocator),
                    .element_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                };

                // Generate each element
                for (result) |*elem| {
                    const element_value = try ChildGen.generate(random, allocator);
                    elem.* = element_value.value;

                    // Store the context if any
                    if (element_value.context != null) {
                        try context.element_contexts.append(element_value.context.?);
                        try context.element_deinits.append(element_value.context_deinit.?);
                    } else {
                        try context.element_contexts.append(null);
                        try context.element_deinits.append(null);
                    }
                }

                const end_pos = random.prng.fixed_buffer.pos;

                return Value([]E).init(
                    result,
                    @as(*anyopaque, @ptrCast(context)),
                    SliceContext.deinit,
                    .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                );
            }
        }.generate,

        .shrinkFn = struct {
            const ChildGen = child_gen;
            const MinLen = min_len;
            fn shrink(value: []E, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList([]E) {
                if (context == null) {
                    // Can't shrink without context
                    return ValueList([]E).init(&[_]Value([]E){}, allocator);
                }

                const slice_ctx = @as(*struct {
                    slice: []E,
                    element_contexts: std.ArrayList(?*anyopaque),
                    element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                }, @ptrCast(@alignCast(context)));

                var all_shrinks = std.ArrayList(Value([]E)).init(allocator);
                defer all_shrinks.deinit();

                // Strategy 1: Shrink the length (if possible)
                if (value.len > MinLen) {
                    // Try removing elements from the end
                    const new_len = @max(MinLen, value.len / 2);

                    // Create a new slice context
                    const new_ctx = try allocator.create(struct {
                        slice: []E,
                        element_contexts: std.ArrayList(?*anyopaque),
                        element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                    });
                    new_ctx.* = .{
                        .slice = try allocator.alloc(E, new_len),
                        .element_contexts = std.ArrayList(?*anyopaque).init(allocator),
                        .element_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                    };

                    // Copy the elements and contexts
                    @memcpy(new_ctx.slice, value[0..new_len]);
                    for (slice_ctx.element_contexts.items[0..new_len], slice_ctx.element_deinits.items[0..new_len]) |ctx, deinit_fn| {
                        try new_ctx.element_contexts.append(ctx);
                        try new_ctx.element_deinits.append(deinit_fn);
                    }

                    // Add to our list of shrinks
                    try all_shrinks.append(Value([]E).init(
                        new_ctx.slice,
                        @as(*anyopaque, @ptrCast(new_ctx)),
                        struct {
                            fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                if (ctx) |ptr| {
                                    const self_ctx = @as(*struct {
                                        slice: []E,
                                        element_contexts: std.ArrayList(?*anyopaque),
                                        element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                                    }, @ptrCast(@alignCast(ptr)));

                                    // Call deinit on each element context
                                    for (self_ctx.element_contexts.items, self_ctx.element_deinits.items) |elem_ctx, deinit_fn| {
                                        if (deinit_fn) |deinit_fn_| {
                                            deinit_fn_(elem_ctx, alloc);
                                        }
                                    }

                                    // Free the slice
                                    alloc.free(self_ctx.slice);

                                    // Free the arrays
                                    self_ctx.element_contexts.deinit();
                                    self_ctx.element_deinits.deinit();

                                    // Free the context itself
                                    alloc.destroy(self_ctx);
                                }
                            }
                        }.deinit,
                        null,
                    ));
                }

                // Strategy 2: Shrink individual elements
                for (value, 0..) |elem, i| {
                    const elem_ctx = slice_ctx.element_contexts.items[i];
                    const elem_shrinks = try ChildGen.shrink(elem, elem_ctx, allocator);
                    defer elem_shrinks.deinit();

                    // For each shrunk element, create a new slice with just that element shrunk
                    for (elem_shrinks.values) |shrunk_elem| {
                        // Create a new slice context
                        const new_ctx = try allocator.create(struct {
                            slice: []E,
                            element_contexts: std.ArrayList(?*anyopaque),
                            element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                        });
                        new_ctx.* = .{
                            .slice = try allocator.alloc(E, value.len),
                            .element_contexts = std.ArrayList(?*anyopaque).init(allocator),
                            .element_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                        };

                        // Copy the original slice
                        @memcpy(new_ctx.slice, value);

                        // Replace the shrunk element
                        new_ctx.slice[i] = shrunk_elem.value;

                        // Copy the contexts except for the one we're shrinking
                        for (slice_ctx.element_contexts.items, slice_ctx.element_deinits.items, 0..) |ctx, deinit_fn, j| {
                            if (j == i) {
                                // Use the shrunk element's context
                                try new_ctx.element_contexts.append(shrunk_elem.context);
                                try new_ctx.element_deinits.append(shrunk_elem.context_deinit);
                            } else {
                                // Copy the original context
                                try new_ctx.element_contexts.append(ctx);
                                try new_ctx.element_deinits.append(deinit_fn);
                            }
                        }

                        // Add to our list of shrinks
                        try all_shrinks.append(Value([]E).init(
                            new_ctx.slice,
                            @as(*anyopaque, @ptrCast(new_ctx)),
                            struct {
                                fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                    if (ctx) |ptr| {
                                        const self_ctx = @as(*struct {
                                            slice: []E,
                                            element_contexts: std.ArrayList(?*anyopaque),
                                            element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                                        }, @ptrCast(@alignCast(ptr)));

                                        // Call deinit on each element context
                                        for (self_ctx.element_contexts.items, self_ctx.element_deinits.items) |ctx_elem, deinit_fn| {
                                            if (deinit_fn) |deinit_fn_| {
                                                deinit_fn_(ctx_elem, alloc);
                                            }
                                        }

                                        // Free the slice
                                        alloc.free(self_ctx.slice);

                                        // Free the arrays
                                        self_ctx.element_contexts.deinit();
                                        self_ctx.element_deinits.deinit();

                                        // Free the context itself
                                        alloc.destroy(self_ctx);
                                    }
                                }
                            }.deinit,
                            null,
                        ));
                    }
                }

                return ValueList([]E).init(try all_shrinks.toOwnedSlice(), allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: []E) bool {
                // Slices need context for proper shrinking
                _ = value;
                return false;
            }
        }.canShrinkWithoutContext,
    };
}

/// Generate single pointers
fn pointerGen(comptime Child: type, comptime child_gen: Generator(Child)) Generator(*Child) {
    return Generator(*Child){
        .generateFn = struct {
            const ChildGen = child_gen;

            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(*Child) {
                const start_pos = random.prng.fixed_buffer.pos;

                // Create a pointer context
                const PtrContext = struct {
                    ptr: *Child,
                    value_context: ?*anyopaque,
                    context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,

                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                        if (ctx) |ptr| {
                            const self_ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));

                            // Call deinit on the value context if any
                            if (self_ctx.value_context != null and self_ctx.context_deinit != null) {
                                self_ctx.context_deinit.?(self_ctx.value_context, alloc);
                            }

                            // Free the pointer
                            alloc.destroy(self_ctx.ptr);

                            // Free the context itself
                            alloc.destroy(self_ctx);
                        }
                    }
                };

                // Generate the child value
                const child_value = try ChildGen.generate(random, allocator);

                // Allocate memory for the pointer
                const ptr = try allocator.create(Child);
                ptr.* = child_value.value;

                // Create the context
                const context = try allocator.create(PtrContext);
                context.* = .{
                    .ptr = ptr,
                    .value_context = child_value.context,
                    .context_deinit = child_value.context_deinit,
                };

                const end_pos = random.prng.fixed_buffer.pos;

                return Value(*Child).init(
                    ptr,
                    @as(*anyopaque, @ptrCast(context)),
                    PtrContext.deinit,
                    .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                );
            }
        }.generate,

        .shrinkFn = struct {
            const ChildGen = child_gen;
            fn shrink(value: *Child, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(*Child) {
                if (context == null) {
                    // Can't shrink without context
                    return ValueList(*Child).init(&[_]Value(*Child){}, allocator);
                }

                const ptr_ctx = @as(*struct {
                    ptr: *Child,
                    value_context: ?*anyopaque,
                    context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                }, @ptrCast(@alignCast(context)));

                // Shrink the pointed-to value
                const value_shrinks = try ChildGen.shrink(value.*, ptr_ctx.value_context, allocator);
                defer value_shrinks.deinit();

                // Create a new pointer for each shrunk value
                var result = try allocator.alloc(Value(*Child), value_shrinks.len());

                for (value_shrinks.values, 0..) |shrunk_value, i| {
                    // Allocate a new pointer
                    const new_ptr = try allocator.create(Child);
                    new_ptr.* = shrunk_value.value;

                    // Create a new context
                    const new_ctx = try allocator.create(struct {
                        ptr: *Child,
                        value_context: ?*anyopaque,
                        context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                    });
                    new_ctx.* = .{
                        .ptr = new_ptr,
                        .value_context = shrunk_value.context,
                        .context_deinit = shrunk_value.context_deinit,
                    };

                    // Store the result
                    result[i] = Value(*Child).init(
                        new_ptr,
                        @as(*anyopaque, @ptrCast(new_ctx)),
                        struct {
                            fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                if (ctx) |ptr| {
                                    const self_ctx = @as(*struct {
                                        ptr: *Child,
                                        value_context: ?*anyopaque,
                                        context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                                    }, @ptrCast(@alignCast(ptr)));

                                    // Call deinit on the value context if any
                                    if (self_ctx.value_context != null and self_ctx.context_deinit != null) {
                                        self_ctx.context_deinit.?(self_ctx.value_context, alloc);
                                    }

                                    // Free the pointer
                                    alloc.destroy(self_ctx.ptr);

                                    // Free the context itself
                                    alloc.destroy(self_ctx);
                                }
                            }
                        }.deinit,
                        null,
                    );
                }

                return ValueList(*Child).init(result, allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: *Child) bool {
                // Pointers need context for proper shrinking
                _ = value;
                return false;
            }
        }.canShrinkWithoutContext,
    };
}

/// Helper functions (same as in the original generator.zig)
/// Generate floats
fn floatGen(comptime T: type, config: anytype) Generator(T) {
    const min = if (@hasField(@TypeOf(config), "min")) config.min else -100.0;
    const max = if (@hasField(@TypeOf(config), "max")) config.max else 100.0;

    return Generator(T){
        .generateFn = struct {
            const Min = min;
            const Max = max;
            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(T) {
                _ = allocator;
                const start_pos = random.prng.fixed_buffer.pos;

                // Sometimes generate special values (20% of the time)
                if (try random.chance(.{ .numerator = 1, .denominator = 5 })) {
                    var special_values: [8]T = undefined;
                    const count = getFloatSpecialValues(T, Min, Max, &special_values);

                    const index = try random.uintLessThan(usize, count);
                    const end_pos = random.prng.fixed_buffer.pos;
                    return Value(T).initNoContext(special_values[index], .{ .start = @intCast(start_pos), .end = @intCast(end_pos) });
                }

                // Otherwise generate a random value in the range
                const norm = try random.floatNorm(T);
                const value = Min + (Max - Min) * norm;
                const end_pos = random.prng.fixed_buffer.pos;
                return Value(T).initNoContext(value, .{ .start = @intCast(start_pos), .end = @intCast(end_pos) });
            }
        }.generate,

        .shrinkFn = struct {
            const Min = min;
            const Max = max;

            fn shrink(value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T) {
                _ = context; // Float shrinking doesn't need context

                // For floats, we have several shrinking strategies:
                // 1. Shrink towards 0 (divide by 2)
                // 2. Try boundaries near 0 (0, 1, -1)
                // 3. Try absolute value (for negative numbers)
                // 4. Try rounding to nearest integer

                var shrink_candidates = std.ArrayList(Value(T)).init(allocator);
                defer shrink_candidates.deinit();

                // Skip shrinking for special values
                if (std.math.isNan(value) or std.math.isInf(value)) {
                    return ValueList(T).init(&[_]Value(T){}, allocator);
                }

                // Strategy 1: Shrink towards 0 (divide by 2)
                if (value != 0) {
                    try shrink_candidates.append(Value(T).initNoContext(value / 2, null));
                }

                // Strategy 2: Try boundaries near 0
                if (value > 1) {
                    try shrink_candidates.append(Value(T).initNoContext(1, null));
                    try shrink_candidates.append(Value(T).initNoContext(0, null));
                } else if (value < -1) {
                    try shrink_candidates.append(Value(T).initNoContext(-1, null));
                    try shrink_candidates.append(Value(T).initNoContext(0, null));
                }

                // Strategy 3: For negative numbers, try absolute value
                if (value < 0) {
                    try shrink_candidates.append(Value(T).initNoContext(-value, null));
                }

                // Strategy 4: Try rounding to nearest integer if not already an integer
                const rounded = @round(value);
                if (value != rounded) {
                    try shrink_candidates.append(Value(T).initNoContext(rounded, null));
                }

                // Filter to only include values in range
                var valid_count: usize = 0;
                for (shrink_candidates.items) |shrnk| {
                    if (shrnk.value >= Min and shrnk.value <= Max) {
                        valid_count += 1;
                    }
                }

                var filtered = try allocator.alloc(Value(T), valid_count);
                var index: usize = 0;

                for (shrink_candidates.items) |shrnk| {
                    if (shrnk.value >= Min and shrnk.value <= Max) {
                        filtered[index] = shrnk;
                        index += 1;
                    }
                }

                return ValueList(T).init(filtered, allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: T) bool {
                // Floats can always be shrunk without context,
                // as long as they are within the valid range and not special values
                return value >= min and value <= max and
                    !std.math.isNan(value) and !std.math.isInf(value);
            }
        }.canShrinkWithoutContext,
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

/// Generator for struct types
fn structGen(comptime T: type, config: anytype) Generator(T) {
    // Validate that all fields in config match fields in T
    const struct_info = @typeInfo(T).@"struct";
    inline for (@typeInfo(@TypeOf(config)).@"struct".fields) |field| {
        const field_name = field.name;
        if (!@hasField(T, field_name)) {
            @compileError("Config has field '" ++ field_name ++ "' which doesn't exist in " ++ @typeName(T));
        }
    }

    return Generator(T){
        .generateFn = struct {
            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(T) {
                const start_pos = random.prng.fixed_buffer.pos;

                // Create a struct context to hold all field contexts
                const StructContext = struct {
                    // Dynamic array to hold field contexts
                    field_contexts: std.ArrayList(?*anyopaque),
                    field_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),

                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                        if (ctx) |ptr| {
                            const self_ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));

                            // Call deinit on each field context
                            for (self_ctx.field_contexts.items, self_ctx.field_deinits.items) |field_ctx, deinit_fn| {
                                if (deinit_fn) |deinit_fn_| {
                                    deinit_fn_(field_ctx, alloc);
                                }
                            }

                            // Free the arrays
                            self_ctx.field_contexts.deinit();
                            self_ctx.field_deinits.deinit();

                            // Free the context itself
                            alloc.destroy(self_ctx);
                        }
                    }
                };

                // Create the context
                var context = try allocator.create(StructContext);
                context.* = .{
                    .field_contexts = std.ArrayList(?*anyopaque).init(allocator),
                    .field_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                };

                // Initialize the result struct
                var result: T = undefined;

                // Generate each field
                inline for (struct_info.fields) |field| {
                    const field_name = field.name;
                    const FieldType = field.type;

                    // Check if we have a generator config for this field
                    if (@hasField(@TypeOf(config), field_name)) {
                        const field_config = @field(config, field_name);
                        const field_generator = gen(FieldType, field_config);

                        // Generate the field value
                        const field_value = try field_generator.generate(random, allocator);

                        // Store the value
                        @field(result, field_name) = field_value.value;

                        // Store the context if any
                        if (field_value.context != null) {
                            try context.field_contexts.append(field_value.context.?);
                            try context.field_deinits.append(field_value.context_deinit.?);
                        } else {
                            try context.field_contexts.append(null);
                            try context.field_deinits.append(null);
                        }
                    } else {
                        // No config for this field, use default if possible
                        if (@hasDecl(FieldType, "default")) {
                            @field(result, field_name) = FieldType.default;
                        } else {
                            @compileError("No generator config provided for field '" ++ field_name ++ "' in " ++ @typeName(T));
                        }
                    }
                }

                const end_pos = random.prng.fixed_buffer.pos;

                return Value(T).init(
                    result,
                    @as(*anyopaque, @ptrCast(context)),
                    StructContext.deinit,
                    .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                );
            }
        }.generate,

        .shrinkFn = struct {
            fn shrink(value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T) {
                _ = value;
                _ = context;
                // For now, we don't implement struct shrinking
                return ValueList(T).init(&[_]Value(T){}, allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: T) bool {
                _ = value;
                return false; // Structs need context for proper shrinking
            }
        }.canShrinkWithoutContext,
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

test gen {
    // Create a generator for integers between 10 and 20
    const intGenerator = gen(i32, .{ .min = 10, .max = 20 });

    // Create a buffer for random bytes
    var bytes: [4096]u8 = undefined;

    // Generate 20 values with different random seeds and check they're within range
    for (0..20) |_| {
        // Load random bytes for each test
        @import("test_helpers").load_bytes(&bytes);

        // Create a finite PRNG
        var prng = FinitePrng.init(&bytes);
        var random = prng.random();

        // Generate the value
        const value = try intGenerator.generate(&random, std.testing.allocator);
        defer value.deinit(std.testing.allocator);

        // Verify the value is within range
        try std.testing.expect(value.value >= 10 and value.value <= 20);
    }
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
        unmap_fn: ?*const fn (U) ?T,

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
        pub fn generate(self: MappedSelf, random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(U) {
            const start_pos = random.prng.fixed_buffer.pos;

            // Generate original value with context
            const original = try self.parent.generate(random, allocator);

            // Map the value
            const mapped_value = self.map_fn(original.value);

            // Create a new context that references the original
            const context = try allocator.create(MapContext);
            context.* = .{
                .original_value = original.value,
                .original_context = original.context,
                .context_deinit = original.context_deinit,
            };

            const end_pos = random.prng.fixed_buffer.pos;

            return Value(U).init(
                mapped_value,
                @as(*anyopaque, @ptrCast(context)),
                MapContext.deinit,
                .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
            );
        }

        /// Shrink a mapped value
        pub fn shrink(self: MappedSelf, value: U, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(U) {
            if (context) |ctx_ptr| {
                // We have context, use it for smart shrinking
                const map_ctx: *MapContext = @ptrCast(@alignCast(ctx_ptr));

                // Shrink the original value
                const shrunk_originals = try self.parent.shrink(
                    map_ctx.original_value,
                    map_ctx.original_context,
                    allocator,
                );
                defer shrunk_originals.deinit();

                // Map each shrunk value
                var shrunk_mapped = try allocator.alloc(Value(U), shrunk_originals.len());

                for (shrunk_originals.values, 0..) |shrunk_original, i| {
                    // Create a new context for each shrunk value
                    const new_ctx = try allocator.create(MapContext);
                    new_ctx.* = .{
                        .original_value = shrunk_original.value,
                        .original_context = shrunk_original.context,
                        .context_deinit = shrunk_original.context_deinit,
                    };

                    // Map the shrunk value
                    const mapped_value = self.map_fn(shrunk_original.value);

                    // Store the result
                    shrunk_mapped[i] = Value(U).init(
                        mapped_value,
                        @as(*anyopaque, @ptrCast(new_ctx)),
                        MapContext.deinit,
                        null,
                    );
                }

                return ValueList(U).init(shrunk_mapped, allocator);
            } else if (self.unmap_fn) |unmap| {
                // No context but we have an unmapping function
                if (unmap(value)) |original| {
                    if (self.parent.canShrinkWithoutContext(original)) {
                        // Shrink the unmapped value
                        const shrunk_originals = try self.parent.shrink(original, null, allocator);
                        defer shrunk_originals.deinit();

                        // Map each shrunk value
                        var shrunk_mapped = try allocator.alloc(Value(U), shrunk_originals.len());

                        for (shrunk_originals.values, 0..) |shrunk_original, i| {
                            shrunk_mapped[i] = Value(U).initNoContext(self.map_fn(shrunk_original.value), null);
                        }

                        return ValueList(U).init(shrunk_mapped, allocator);
                    }
                }
            }

            // Can't shrink without proper context
            return ValueList(U).init(&[_]Value(U){}, allocator);
        }

        /// Check if a value can be shrunk without context
        pub fn canShrinkWithoutContext(self: MappedSelf, value: U) bool {
            if (self.unmap_fn) |unmap| {
                if (unmap(value)) |original| {
                    return self.parent.canShrinkWithoutContext(original);
                }
            }
            return false;
        }
    };
}

test MappedGenerator {
    // Create a mapped generator that forces odd values
    const intGen_ = gen(i32, .{ .min = 0, .max = 10 });
    // here’s our mapped generator:
    const oddOnlyGen = intGen_.map(i32, struct {
        pub fn map(n: i32) i32 {
            // Make sure we always return odd numbers
            return if (@rem(n, 2) == 0) n + 1 else n;
        }
    }.map, null);

    // Property that requires even numbers (should always fail with our generator)
    const evenOnlyProperty = @import("property.zig").property(i32, oddOnlyGen, struct {
        fn test_(n: i32) bool {
            return @rem(n, 2) == 0; // Will fail since the generator always returns odd numbers
        }
    }.test_);

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    @import("test_helpers").load_bytes(&bytes);

    // Run the property test (should fail)
    const result = try evenOnlyProperty.check(std.testing.allocator, &bytes);

    // Should fail with a counterexample (non-null result means failure)
    try std.testing.expect(result != null);

    // The counterexample should be an odd number
    if (result.?.counterexample) |counter_ptr| {
        const counterexample = @as(*const i32, @ptrCast(@alignCast(counter_ptr))).*;
        try std.testing.expect(@rem(counterexample, 2) == 1); // Should be odd
    }
}

/// Generate enum values
fn enumGen(comptime T: type) Generator(T) {
    const enum_info = @typeInfo(T).@"enum";
    return Generator(T){
        .generateFn = struct {
            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(T) {
                _ = allocator;
                const start_pos = random.prng.fixed_buffer.pos;
                const index = try random.uintLessThan(usize, enum_info.fields.len);
                const end_pos = random.prng.fixed_buffer.pos;
                return Value(T).initNoContext(std.enums.values(T)[index], .{ .start = @intCast(start_pos), .end = @intCast(end_pos) });
            }
        }.generate,

        .shrinkFn = struct {
            fn shrink(value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T) {
                _ = value;
                _ = context;
                // For enums, we don't implement shrinking yet
                // A possible strategy would be to shrink towards the first enum value
                return ValueList(T).init(&[_]Value(T){}, allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: T) bool {
                _ = value;
                return false; // Enums don't need shrinking for now
            }
        }.canShrinkWithoutContext,
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

            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(T) {
                const start_pos = random.prng.fixed_buffer.pos;

                // Create a union context
                const UnionContext = struct {
                    tag: std.meta.Tag(T),
                    field_context: ?*anyopaque,
                    context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,

                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                        if (ctx) |ptr| {
                            const self_ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));

                            // Call deinit on the field context if any
                            if (self_ctx.field_context != null and self_ctx.context_deinit != null) {
                                self_ctx.context_deinit.?(self_ctx.field_context, alloc);
                            }

                            // Free the context itself
                            alloc.destroy(self_ctx);
                        }
                    }
                };

                // Randomly select a field index
                const field_index = try random.uintLessThan(usize, FieldNames.len);
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
                        const field_generator = gen(field.type, field_config);
                        const field_value = try field_generator.generate(random, allocator);

                        // Create the union value
                        const union_value = @unionInit(T, field.name, field_value.value);

                        // Create the context
                        const context = try allocator.create(UnionContext);
                        context.* = .{
                            .tag = @field(std.meta.Tag(T), field.name),
                            .field_context = field_value.context,
                            .context_deinit = field_value.context_deinit,
                        };

                        const end_pos = random.prng.fixed_buffer.pos;

                        return Value(T).init(
                            union_value,
                            @as(*anyopaque, @ptrCast(context)),
                            UnionContext.deinit,
                            .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                        );
                    }
                }

                unreachable; // Should never reach here
            }
        }.generate,

        .shrinkFn = struct {
            fn shrink(value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T) {
                if (context == null) {
                    // Can't shrink without context
                    return ValueList(T).init(&[_]Value(T){}, allocator);
                }

                const union_ctx = @as(*struct {
                    tag: std.meta.Tag(T),
                    field_context: ?*anyopaque,
                    context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                }, @ptrCast(@alignCast(context)));

                // Get the active tag
                const active_tag = std.meta.activeTag(value);

                // Use inline for to handle each field at compile time
                // TODO: find a way to fix this thing
                inline for (info.fields) |field| {
                    if (active_tag == @field(std.meta.Tag(T), field.name)) {
                        // Get field-specific config if available
                        const field_config = if (@hasField(@TypeOf(config), field.name))
                            @field(config, field.name)
                        else
                            .{};

                        // Get the field value
                        const field_value = @field(value, field.name);

                        // Create a generator for the field type
                        const field_generator = gen(field.type, field_config);

                        // Shrink the field value
                        const field_shrinks = try field_generator.shrink(field_value, union_ctx.field_context, allocator);
                        defer field_shrinks.deinit();

                        // Create a union value for each shrunk field value
                        var result = try allocator.alloc(Value(T), field_shrinks.len());

                        for (field_shrinks.values, 0..) |shrunk_field, i| {
                            // Create the union value
                            const union_value = @unionInit(T, field.name, shrunk_field.value);

                            // Create a new context
                            const new_ctx = try allocator.create(struct {
                                tag: std.meta.Tag(T),
                                field_context: ?*anyopaque,
                                context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                            });
                            new_ctx.* = .{
                                .tag = active_tag,
                                .field_context = shrunk_field.context,
                                .context_deinit = shrunk_field.context_deinit,
                            };

                            // Store the result
                            result[i] = Value(T).init(
                                union_value,
                                @as(*anyopaque, @ptrCast(new_ctx)),
                                struct {
                                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                        if (ctx) |ptr| {
                                            const self_ctx = @as(*struct {
                                                tag: std.meta.Tag(T),
                                                field_context: ?*anyopaque,
                                                context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                                            }, @ptrCast(@alignCast(ptr)));

                                            // Call deinit on the field context if any
                                            if (self_ctx.field_context != null and self_ctx.context_deinit != null) {
                                                self_ctx.context_deinit.?(self_ctx.field_context, alloc);
                                            }

                                            // Free the context itself
                                            alloc.destroy(self_ctx);
                                        }
                                    }
                                }.deinit,
                                null,
                            );
                        }

                        return ValueList(T).init(result, allocator);
                    }
                }

                // If we get here, something went wrong
                return ValueList(T).init(&[_]Value(T){}, allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: T) bool {
                // Unions need context for proper shrinking
                _ = value;
                return false;
            }
        }.canShrinkWithoutContext,
    };
}

/// Generate optional values
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

            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(?Child) {
                const start_pos = random.prng.fixed_buffer.pos;

                // Create an optional context
                const OptContext = struct {
                    is_null: bool,
                    value_context: ?*anyopaque,
                    context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,

                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                        if (ctx) |ptr| {
                            const self_ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));

                            // Call deinit on the value context if any
                            if (!self_ctx.is_null and self_ctx.value_context != null and self_ctx.context_deinit != null) {
                                self_ctx.context_deinit.?(self_ctx.value_context, alloc);
                            }

                            // Free the context itself
                            alloc.destroy(self_ctx);
                        }
                    }
                };

                // Generate null with probability NullProb
                if (try random.chance(chanceRatio)) {
                    // Create a context for null
                    const context = try allocator.create(OptContext);
                    context.* = .{
                        .is_null = true,
                        .value_context = null,
                        .context_deinit = null,
                    };

                    const end_pos = random.prng.fixed_buffer.pos;

                    return Value(?Child).init(
                        null,
                        @as(*anyopaque, @ptrCast(context)),
                        OptContext.deinit,
                        .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                    );
                } else {
                    // Generate a value
                    const child_value = try ChildGen.generate(random, allocator);

                    // Create a context for the value
                    const context = try allocator.create(OptContext);
                    context.* = .{
                        .is_null = false,
                        .value_context = child_value.context,
                        .context_deinit = child_value.context_deinit,
                    };

                    const end_pos = random.prng.fixed_buffer.pos;

                    return Value(?Child).init(
                        child_value.value,
                        @as(*anyopaque, @ptrCast(context)),
                        OptContext.deinit,
                        .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                    );
                }
            }
        }.generate,

        .shrinkFn = struct {
            const ChildGen = child_gen;
            fn shrink(value: ?Child, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(?Child) {
                if (context == null) {
                    // Can't shrink without context
                    return ValueList(?Child).init(&[_]Value(?Child){}, allocator);
                }

                const opt_ctx = @as(*struct {
                    is_null: bool,
                    value_context: ?*anyopaque,
                    context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                }, @ptrCast(@alignCast(context)));

                // For optionals, the simplest value is null
                if (value != null) {
                    // If we have a value, we can shrink to null
                    var result = try allocator.alloc(Value(?Child), 1);

                    // Create a context for null
                    const null_ctx = try allocator.create(struct {
                        is_null: bool,
                        value_context: ?*anyopaque,
                        context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                    });
                    null_ctx.* = .{
                        .is_null = true,
                        .value_context = null,
                        .context_deinit = null,
                    };

                    // Store the null value
                    result[0] = Value(?Child).init(
                        null,
                        @as(*anyopaque, @ptrCast(null_ctx)),
                        struct {
                            fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                if (ctx) |ptr| {
                                    const self_ctx = @as(*struct {
                                        is_null: bool,
                                        value_context: ?*anyopaque,
                                        context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                                    }, @ptrCast(@alignCast(ptr)));

                                    // No need to call deinit for null values
                                    // Free the context itself
                                    alloc.destroy(self_ctx);
                                }
                            }
                        }.deinit,
                        null,
                    );

                    // If the value itself can be shrunk, add those shrinks too
                    if (!opt_ctx.is_null) {
                        const child_shrinks = try ChildGen.shrink(value.?, opt_ctx.value_context, allocator);
                        defer child_shrinks.deinit();

                        // Add each shrunk child value
                        if (child_shrinks.len() > 0) {
                            // Resize the result array
                            const new_result = try allocator.realloc(result, 1 + child_shrinks.len());
                            result = new_result;

                            for (child_shrinks.values, 0..) |shrunk_child, i| {
                                // Create a context for the shrunk value
                                const shrunk_ctx = try allocator.create(struct {
                                    is_null: bool,
                                    value_context: ?*anyopaque,
                                    context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                                });
                                shrunk_ctx.* = .{
                                    .is_null = false,
                                    .value_context = shrunk_child.context,
                                    .context_deinit = shrunk_child.context_deinit,
                                };

                                // Store the shrunk value
                                result[1 + i] = Value(?Child).init(
                                    shrunk_child.value,
                                    @as(*anyopaque, @ptrCast(shrunk_ctx)),
                                    struct {
                                        fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                            if (ctx) |ptr| {
                                                const self_ctx = @as(*struct {
                                                    is_null: bool,
                                                    value_context: ?*anyopaque,
                                                    context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void,
                                                }, @ptrCast(@alignCast(ptr)));

                                                // Call deinit on the value context if any
                                                if (!self_ctx.is_null and self_ctx.value_context != null and self_ctx.context_deinit != null) {
                                                    self_ctx.context_deinit.?(self_ctx.value_context, alloc);
                                                }

                                                // Free the context itself
                                                alloc.destroy(self_ctx);
                                            }
                                        }
                                    }.deinit,
                                    null,
                                );
                            }
                        }
                    }

                    return ValueList(?Child).init(result, allocator);
                } else {
                    // Can't shrink null
                    return ValueList(?Child).init(&[_]Value(?Child){}, allocator);
                }
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: ?Child) bool {
                // Optionals need context for proper shrinking
                _ = value;
                return false;
            }
        }.canShrinkWithoutContext,
    };
}

/// Generate vectors
fn vectorGen(comptime E: type, comptime len: usize, comptime child_gen: Generator(E)) Generator(@Vector(len, E)) {
    return Generator(@Vector(len, E)){
        .generateFn = struct {
            const ChildGen = child_gen;
            fn generate(random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(@Vector(len, E)) {
                const start_pos = random.prng.fixed_buffer.pos;

                // Create a vector context (similar to array context)
                const VectorContext = struct {
                    // Dynamic array to hold element contexts
                    element_contexts: std.ArrayList(?*anyopaque),
                    element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),

                    fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                        if (ctx) |ptr| {
                            const self_ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));

                            // Call deinit on each element context
                            for (self_ctx.element_contexts.items, self_ctx.element_deinits.items) |elem_ctx, deinit_fn| {
                                if (deinit_fn) |deinit_fn_| {
                                    deinit_fn_(elem_ctx, alloc);
                                }
                            }

                            // Free the arrays
                            self_ctx.element_contexts.deinit();
                            self_ctx.element_deinits.deinit();

                            // Free the context itself
                            alloc.destroy(self_ctx);
                        }
                    }
                };

                // Create the context
                var context = try allocator.create(VectorContext);
                context.* = .{
                    .element_contexts = std.ArrayList(?*anyopaque).init(allocator),
                    .element_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                };

                // Generate each element
                var result_array: [len]E = undefined;
                for (&result_array) |*elem| {
                    const element_value = try ChildGen.generate(random, allocator);
                    elem.* = element_value.value;

                    // Store the context if any
                    if (element_value.context != null) {
                        try context.element_contexts.append(element_value.context.?);
                        try context.element_deinits.append(element_value.context_deinit.?);
                    } else {
                        try context.element_contexts.append(null);
                        try context.element_deinits.append(null);
                    }
                }

                const end_pos = random.prng.fixed_buffer.pos;

                return Value(@Vector(len, E)).init(
                    @as(@Vector(len, E), result_array),
                    @as(*anyopaque, @ptrCast(context)),
                    VectorContext.deinit,
                    .{ .start = @intCast(start_pos), .end = @intCast(end_pos) },
                );
            }
        }.generate,

        .shrinkFn = struct {
            const ChildGen = child_gen;
            fn shrink(value: @Vector(len, E), context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(@Vector(len, E)) {
                if (context == null) {
                    // Can't shrink without context
                    return ValueList(@Vector(len, E)).init(&[_]Value(@Vector(len, E)){}, allocator);
                }

                const vector_ctx = @as(*struct {
                    element_contexts: std.ArrayList(?*anyopaque),
                    element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                }, @ptrCast(@alignCast(context)));

                // For vectors, we shrink one element at a time (similar to arrays)
                var all_shrinks = std.ArrayList(Value(@Vector(len, E))).init(allocator);
                defer all_shrinks.deinit();

                // Convert vector to array for easier element access
                var value_array: [len]E = undefined;
                for (0..len) |i| {
                    value_array[i] = value[i];
                }

                // Try shrinking each element
                for (value_array, 0..) |elem, i| {
                    const elem_ctx = vector_ctx.element_contexts.items[i];
                    const elem_shrinks = try ChildGen.shrink(elem, elem_ctx, allocator);
                    defer elem_shrinks.deinit();

                    // For each shrunk element, create a new vector with just that element shrunk
                    for (elem_shrinks.values) |shrunk_elem| {
                        // Create a new vector context
                        const new_ctx = try allocator.create(struct {
                            element_contexts: std.ArrayList(?*anyopaque),
                            element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                        });
                        new_ctx.* = .{
                            .element_contexts = std.ArrayList(?*anyopaque).init(allocator),
                            .element_deinits = std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void).init(allocator),
                        };

                        // Copy the original contexts except for the one we're shrinking
                        for (vector_ctx.element_contexts.items, vector_ctx.element_deinits.items, 0..) |ctx, deinit_fn, j| {
                            if (j == i) {
                                // Use the shrunk element's context
                                try new_ctx.element_contexts.append(shrunk_elem.context);
                                try new_ctx.element_deinits.append(shrunk_elem.context_deinit);
                            } else {
                                // Copy the original context
                                try new_ctx.element_contexts.append(ctx);
                                try new_ctx.element_deinits.append(deinit_fn);
                            }
                        }

                        // Create a new array with the shrunk element
                        var new_array = value_array;
                        new_array[i] = shrunk_elem.value;

                        // Add to our list of shrinks
                        try all_shrinks.append(Value(@Vector(len, E)).init(
                            @as(@Vector(len, E), new_array),
                            @as(*anyopaque, @ptrCast(new_ctx)),
                            struct {
                                fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                                    if (ctx) |ptr| {
                                        const self_ctx = @as(*struct {
                                            element_contexts: std.ArrayList(?*anyopaque),
                                            element_deinits: std.ArrayList(?*const fn (?*anyopaque, std.mem.Allocator) void),
                                        }, @ptrCast(@alignCast(ptr)));

                                        // Call deinit on each element context
                                        for (self_ctx.element_contexts.items, self_ctx.element_deinits.items) |ctx_elem, deinit_fn| {
                                            if (deinit_fn) |deinit_fn_| {
                                                deinit_fn_(ctx_elem, alloc);
                                            }
                                        }

                                        // Free the arrays
                                        self_ctx.element_contexts.deinit();
                                        self_ctx.element_deinits.deinit();

                                        // Free the context itself
                                        alloc.destroy(self_ctx);
                                    }
                                }
                            }.deinit,
                            null,
                        ));
                    }
                }

                return ValueList(@Vector(len, E)).init(try all_shrinks.toOwnedSlice(), allocator);
            }
        }.shrink,

        .canShrinkWithoutContextFn = struct {
            fn canShrinkWithoutContext(value: @Vector(len, E)) bool {
                // Vectors need context for proper shrinking
                _ = value;
                return false;
            }
        }.canShrinkWithoutContext,
    };
}

/// Specialized generator for filtered values
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
        pub fn generate(self: FilteredSelf, random: *FinitePrng.FiniteRandom, allocator: std.mem.Allocator) error{ OutOfMemory, OutOfEntropy }!Value(T) {
            // Try a limited number of times to find a value that passes the filter
            var attempts: usize = 0;
            const max_attempts = 100;

            while (attempts < max_attempts) : (attempts += 1) {
                const value = try self.parent.generate(random, allocator);
                if (self.filter_fn(value.value)) return value;

                // Clean up the rejected value
                value.deinit(allocator);
            }

            // If we can't find a value after max attempts, return the last one anyway
            return try self.parent.generate(random, allocator);
        }

        /// Shrink a value, ensuring all shrunk values pass the filter
        pub fn shrink(self: FilteredSelf, value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T) {
            // Get all possible shrinks from the parent generator
            const all_shrinks = try self.parent.shrink(value, context, allocator);
            defer all_shrinks.deinit();

            // Count how many values pass the filter
            var passing_count: usize = 0;
            for (all_shrinks.values) |shrnk| {
                if (self.filter_fn(shrnk.value)) passing_count += 1;
            }

            // Allocate space for the filtered shrinks
            var filtered_shrinks = try allocator.alloc(Value(T), passing_count);

            // Copy only the values that pass the filter
            var index: usize = 0;
            for (all_shrinks.values) |shrnk| {
                if (self.filter_fn(shrnk.value)) {
                    filtered_shrinks[index] = shrnk;
                    index += 1;
                } else {
                    // Clean up the rejected value
                    shrnk.deinit(allocator);
                }
            }

            return ValueList(T).init(filtered_shrinks, allocator);
        }

        /// Check if a value can be shrunk without context
        pub fn canShrinkWithoutContext(self: FilteredSelf, value: T) bool {
            // We can only shrink if the parent can shrink and the value passes the filter
            return self.parent.canShrinkWithoutContext(value) and self.filter_fn(value);
        }
    };
}
