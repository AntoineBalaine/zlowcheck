const std = @import("std");

/// Value wrapper that stores both a generated value and its associated context
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

        /// Initialize a new Value with a given value and context
        pub fn init(value: T, context: ?*anyopaque, context_deinit: ?*const fn (?*anyopaque, std.mem.Allocator) void) Self {
            return .{
                .value = value,
                .context = context,
                .context_deinit = context_deinit,
            };
        }

        /// Initialize a value with no context
        pub fn initNoContext(value: T) Self {
            return .{
                .value = value,
                .context = null,
                .context_deinit = null,
            };
        }

        /// Cleanup the value's context if needed
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            if (self.context != null and self.context_deinit != null) {
                self.context_deinit.?(self.context, allocator);
            }
        }
    };
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
        generateFn: *const fn (random: std.Random, size: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Value(T),

        /// Function that shrinks values using their context
        shrinkFn: *const fn (value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T),

        /// Function that checks if a value can be shrunk without context
        canShrinkWithoutContextFn: *const fn (value: T) bool,

        /// Generate a value with its context
        pub fn generate(self: Self, random: std.Random, size: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Value(T) {
            return self.generateFn(random, size, allocator);
        }

        /// Shrink a value using its context
        pub fn shrink(self: Self, value: T, context: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}!ValueList(T) {
            return self.shrinkFn(value, context, allocator);
        }

        /// Check if a value can be shrunk without context
        pub fn canShrinkWithoutContext(self: Self, value: T) bool {
            return self.canShrinkWithoutContextFn(value);
        }

        /// Map a generator to a new type
        /// The map function provides a mechanism that allows us to apply a transform to a generated datum. And in the case where we need to shrink that datum (upon a predicate failure), it also provides a mechanism to: revert the transform, shrink, and re-apply. This unmap/shrink/remap can be applied for values coming from a generator, and also for values that have been provided without a generator. This allows library consumers to run pbt with pre-defined values, instead of being prisonners of the generators.
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
        try shrink_candidates.append(Value(T).initNoContext(@divTrunc(value, 2)));
    }

    // Strategy 2: Try boundaries near 0
    if (value > 1) {
        try shrink_candidates.append(Value(T).initNoContext(1));
        try shrink_candidates.append(Value(T).initNoContext(0));
    } else if (value < -1) {
        try shrink_candidates.append(Value(T).initNoContext(-1));
        try shrink_candidates.append(Value(T).initNoContext(0));
    }

    // Strategy 3: For negative numbers, try absolute value
    if (value < 0) {
        try shrink_candidates.append(Value(T).initNoContext(-value));
    }

    return ValueList(T).init(try shrink_candidates.toOwnedSlice(), allocator);
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

            fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Value(T) {
                _ = size;
                _ = allocator;

                // Sometimes generate boundary values (20% of the time)
                if (random.float(f32) < 0.2) {
                    var boundaries: [7]T = undefined;
                    const count = getIntBoundaryValues(T, Min, Max, &boundaries);

                    const index = random.intRangeLessThan(usize, 0, count);
                    return Value(T).initNoContext(boundaries[index]);
                }

                if (Max == std.math.maxInt(T)) {
                    // Special case for maximum value to avoid overflow
                    return Value(T).initNoContext(random.intRangeAtMost(T, Min, Max));
                } else {
                    return Value(T).initNoContext(random.intRangeLessThan(T, Min, Max + 1));
                }
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

/// Helper functions (same as in the original generator.zig)
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
            fn generate(random: std.Random, size: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Value(T) {

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
                        const field_value = try field_generator.generate(random, size, allocator);

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

                return Value(T).init(
                    result,
                    @as(*anyopaque, @ptrCast(context)),
                    StructContext.deinit,
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
        .@"struct" => structGen(T, config),
        // Additional generator types could be added here
        else => @compileError("Cannot generate values of type " ++ @typeName(T)),
    };
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
        pub fn generate(self: MappedSelf, random: std.Random, size: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Value(U) {
            // Generate original value with context
            const original = try self.parent.generate(random, size, allocator);

            // Map the value
            const mapped_value = self.map_fn(original.value);

            // Create a new context that references the original
            const context = try allocator.create(MapContext);
            context.* = .{
                .original_value = original.value,
                .original_context = original.context,
                .context_deinit = original.context_deinit,
            };

            return Value(U).init(
                mapped_value,
                @as(*anyopaque, @ptrCast(context)),
                MapContext.deinit,
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
                            shrunk_mapped[i] = Value(U).initNoContext(self.map_fn(shrunk_original.value));
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
        pub fn generate(self: FilteredSelf, random: std.Random, size: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Value(T) {
            // Try a limited number of times to find a value that passes the filter
            var attempts: usize = 0;
            const max_attempts = 100;

            while (attempts < max_attempts) : (attempts += 1) {
                const value = try self.parent.generate(random, size, allocator);
                if (self.filter_fn(value.value)) return value;

                // Clean up the rejected value
                value.deinit(allocator);
            }

            // If we can't find a value after max attempts, return the last one anyway
            return self.parent.generate(random, size, allocator);
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
