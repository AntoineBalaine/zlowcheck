const std = @import("std");
const generator2 = @import("generator.zig");
const Generator = generator2.Generator;
const Value = generator2.Value;
const ValueList = generator2.ValueList;
const FinitePrng = @import("finite_prng");

/// Result of a property check
pub const PropertyResult = struct {
    /// Whether the property check passed
    success: bool,

    /// Counterexample if the property check failed
    counterexample: ?*anyopaque,

    /// Number of test cases that passed
    num_passed: usize,

    /// Number of test cases that were skipped (e.g., due to preconditions)
    num_skipped: usize,

    /// Number of shrinking steps performed (if any)
    num_shrinks: usize,

    /// Creation timestamp, useful for timing test duration
    timestamp: i64,

    /// The byte sequence that produced the failure
    failure_bytes: ?[]u8,

    /// Format the failure bytes as a hex string for easy copy/paste into test cases
    /// Returns a string that needs to be freed by the caller
    pub fn formatFailureBytes(self: PropertyResult, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.failure_bytes == null) return null;

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        try buffer.appendSlice("// Failure bytes as hex:\n// var bytes = [_]u8{ ");

        for (self.failure_bytes.?, 0..) |b, i| {
            // Format each byte as 0xXX
            try std.fmt.format(buffer.writer(), "0x{x:0>2}", .{b});

            // Add comma separator except for the last element
            if (i < self.failure_bytes.?.len - 1) {
                try buffer.appendSlice(", ");
            }

            // Add line break for readability every 8 bytes
            if ((i + 1) % 8 == 0 and i < self.failure_bytes.?.len - 1) {
                try buffer.appendSlice("\n//     ");
            }
        }

        try buffer.appendSlice(" };");

        return try buffer.toOwnedSlice();
    }
};

/// A property is a testable statement about inputs.
///
/// It combines a generator with a predicate function
pub fn Property(comptime T: type, comptime GeneratorType: type) type {
    return struct {
        const Self = @This();

        /// The generator used to create test values
        generator: GeneratorType,

        /// The predicate function that tests each value
        predicate: *const fn (T) bool,

        /// Setup function context and callback
        before_each_context: ?*anyopaque = null,
        before_each_fn: ?*const fn (*anyopaque) void = null,

        /// Teardown function context and callback
        after_each_context: ?*anyopaque = null,
        after_each_fn: ?*const fn (*anyopaque) void = null,

        /// Create a new property from a generator and predicate
        pub fn init(generator: GeneratorType, predicate: fn (T) bool) Self {
            return .{
                .generator = generator,
                .predicate = predicate,
                .before_each_context = null,
                .before_each_fn = null,
                .after_each_context = null,
                .after_each_fn = null,
            };
        }

        /// Add a setup function to be called before each test case
        /// The context is optional - pass null for hooks that don't need context
        pub fn beforeEach(
            self: Self,
            context: anytype,
            comptime hookFn: anytype,
        ) Self {
            const HookType = @TypeOf(hookFn);
            const hookInfo = @typeInfo(HookType).@"fn";

            // Validate hook function signature at compile time
            comptime {
                if (hookInfo.params.len == 0) {
                    // No-context hook - this is fine
                } else if (hookInfo.params.len == 1) {
                    // Context-based hook - make sure context type matches
                    const ContextType = @TypeOf(context);
                    const ParamType = hookInfo.params[0].type.?;

                    if (ParamType != ContextType) {
                        @compileError("Hook parameter type doesn't match context type");
                    }
                } else {
                    @compileError("Hook function must take either 0 or 1 parameters");
                }
            }

            var result = self;

            if (hookInfo.params.len == 0) {
                // No-context hook
                result.before_each_context = null;
                result.before_each_fn = struct {
                    fn wrapper(_: *anyopaque) void {
                        hookFn();
                    }
                }.wrapper;
            } else {
                // Context-based hook
                const ContextType = @TypeOf(context);
                result.before_each_context = context;
                result.before_each_fn = struct {
                    fn wrapper(ctx: *anyopaque) void {
                        hookFn(@as(ContextType, @ptrCast(@alignCast(ctx))));
                    }
                }.wrapper;
            }

            return result;
        }

        /// Add a teardown function to be called after each test case
        /// The context is optional - pass null for hooks that don't need context
        pub fn afterEach(
            self: Self,
            context: anytype,
            comptime hookFn: anytype,
        ) Self {
            const HookType = @TypeOf(hookFn);
            const hookInfo = @typeInfo(HookType).@"fn";

            // Validate hook function signature at compile time
            comptime {
                if (hookInfo.params.len == 0) {
                    // No-context hook - this is fine
                } else if (hookInfo.params.len == 1) {
                    // Context-based hook - make sure context type matches
                    const ContextType = @TypeOf(context);
                    const ParamType = hookInfo.params[0].type.?;

                    if (ParamType != ContextType) {
                        @compileError("Hook parameter type doesn't match context type");
                    }
                } else {
                    @compileError("Hook function must take either 0 or 1 parameters");
                }
            }

            var result = self;

            if (hookInfo.params.len == 0) {
                // No-context hook
                result.after_each_context = null;
                result.after_each_fn = struct {
                    fn wrapper(_: *anyopaque) void {
                        hookFn();
                    }
                }.wrapper;
            } else {
                // Context-based hook
                const ContextType = @TypeOf(context);
                result.after_each_context = context;
                result.after_each_fn = struct {
                    fn wrapper(ctx: *anyopaque) void {
                        hookFn(@as(ContextType, @ptrCast(@alignCast(ctx))));
                    }
                }.wrapper;
            }

            return result;
        }

        /// Run the property check using a byte slice as the randomness source
        ///
        /// Returns:
        /// - null if the test passes
        /// - PropertyResult if the test fails
        /// - error.OutOfMemory if memory allocation fails
        /// - error.OutOfEntropy if the input byte slice doesn't contain enough randomness
        pub fn check(self: Self, allocator: std.mem.Allocator, bytes: []u8) error{ OutOfMemory, OutOfEntropy }!?PropertyResult {
            // Create a finite PRNG from the byte slice
            var prng = FinitePrng.init(bytes);
            var random = prng.random();

            // Generate a test value
            const test_value = try self.generator.generate(&random, allocator);

            // Call the before hook if any
            if (self.before_each_fn) |hookFn| {
                if (self.before_each_context) |ctx| {
                    hookFn(ctx);
                } else {
                    // For context-less hooks, we pass a dummy value
                    var dummy: u8 = 0;
                    hookFn(&dummy);
                }
            }

            // Run the predicate on the generated value
            const predicate_result = self.predicate(test_value.value);

            // Call the after hook if any
            if (self.after_each_fn) |hookFn| {
                if (self.after_each_context) |ctx| {
                    hookFn(ctx);
                } else {
                    // For context-less hooks, we pass a dummy value
                    var dummy: u8 = 0;
                    hookFn(&dummy);
                }
            }

            if (!predicate_result) {
                // The predicate failed, we have a counterexample
                var result = PropertyResult{
                    .success = false,
                    .counterexample = null,
                    .num_passed = 0,
                    .num_skipped = 0,
                    .num_shrinks = 0,
                    .timestamp = std.time.milliTimestamp(),
                    .failure_bytes = null,
                };

                // Save the original byte position that produced the failure
                // This is critical for reproducing the test failure
                if (test_value.byte_pos) |pos| {
                    result.failure_bytes = bytes[pos.start..pos.end];
                }
                // If the byte position is null (which shouldn't happen for original generated values)
                // we leave the result.byte_start, result.byte_end, and result.failure_bytes as null

                // Try to shrink the counterexample
                var simplified_value = test_value;
                var shrink_iterations: usize = 0;

                // Main shrinking loop
                var found_simpler = true;
                while (found_simpler) {
                    found_simpler = false;

                    // Get possible simplifications
                    var shrinks = try self.generator.shrink(simplified_value.value, simplified_value.context, allocator);
                    defer shrinks.deinit();

                    // Find the first shrink that still fails the test
                    for (shrinks.values) |*shrink| {
                        // Run the before hook if any
                        if (self.before_each_fn) |hookFn| {
                            if (self.before_each_context) |ctx| {
                                hookFn(ctx);
                            } else {
                                // For context-less hooks, we pass a dummy value
                                var dummy: u8 = 0;
                                hookFn(&dummy);
                            }
                        }

                        const shrink_result = self.predicate(shrink.value);

                        // Run the after hook if any
                        if (self.after_each_fn) |hookFn| {
                            if (self.after_each_context) |ctx| {
                                hookFn(ctx);
                            } else {
                                // For context-less hooks, we pass a dummy value
                                var dummy: u8 = 0;
                                hookFn(&dummy);
                            }
                        }

                        if (!shrink_result) {
                            // Found a simpler failing case
                            simplified_value.deinit(allocator);

                            // Create a copy of the shrunk value
                            simplified_value = shrink.*;
                            shrink_iterations += 1;
                            found_simpler = true;

                            shrink.context = null;
                            shrink.context_deinit = null;

                            // Note: shrunk values don't always have meaningful byte positions
                            // but we keep the original byte range that led to the failure
                            break;
                        }
                    }
                }

                // Store the counterexample and shrink count
                result.counterexample = @as(*anyopaque, @ptrCast(&simplified_value.value));
                simplified_value.deinit(allocator);
                result.num_shrinks = shrink_iterations;

                // Return the failing result
                return result;
            }

            // If the predicate passed, clean up and increment the counter
            test_value.deinit(allocator);

            // Test passed, return null
            return null;
        }
    };
}

/// Create a property that checks a condition on generated values.
///
/// Accepts any generator type that has the required methods:
/// `generate` and `shrink`
pub fn property(comptime T: type, generator: anytype, predicate: fn (T) bool) Property(T, @TypeOf(generator)) {
    // Validate that the generator has the required methods at compile time
    const GeneratorType = @TypeOf(generator);

    // Just do basic method existence checks
    comptime {
        // Check if the generator has a ValueType that matches T
        if (!@hasDecl(GeneratorType, "ValueType") or GeneratorType.ValueType != T) {
            @compileError("Generator must produce values of type " ++ @typeName(T));
        }

        // Check for required methods
        if (!@hasDecl(GeneratorType, "generate")) {
            @compileError("Generator must have a generate method");
        }

        if (!@hasDecl(GeneratorType, "shrink")) {
            @compileError("Generator must have a shrink method");
        }
    }

    return Property(T, GeneratorType).init(generator, predicate);
}

test property {
    // Test the commutative property of addition: a + b == b + a
    const TestType = struct { a: i32, b: i32 };
    const commutativeProperty = property(TestType, @import("generator.zig").gen(TestType, .{
        .a = .{ .min = -100, .max = 100 },
        .b = .{ .min = -100, .max = 100 },
    }), struct {
        fn test_(args: TestType) bool {
            return args.a + args.b == args.b + args.a;
        }
    }.test_);

    // Create a byte slice for testing
    var bytes: [4096]u8 = undefined;
    @import("test_helpers").load_bytes(&bytes);

    // Run the property test (should always succeed)
    const result = try commutativeProperty.check(std.testing.allocator, &bytes);

    // Should be successful (null result means success)
    try std.testing.expectEqual(null, result);
}
