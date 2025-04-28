const std = @import("std");
const Generator = @import("generator.zig").Generator;
const FinitePrng = @import("byte_slice_prng.zig");

/// Represents a failure found during property testing
pub const PropertyFailure = struct {
    /// Start offset in the original byte slice
    start_offset: u32,

    /// End offset in the original byte slice
    end_offset: u32,

    /// Number of shrinking steps performed
    shrink_count: u32,

    pub fn len(self: @This()) u32 {
        return self.end_offset - self.start_offset;
    }
};

/// Represents a range in the original byte slice
pub const ByteRange = struct {
    start: u32,
    end: u32,
    pub fn len(self: @This()) u32 {
        return self.end - self.start;
    }
};

/// Calculate the maximum number of byte ranges needed for shrinking
pub fn maxShrinkRanges(bytes_len: usize) usize {
    if (bytes_len == 0) return 1;
    const log_factor = std.math.log2_int(usize, bytes_len) + 1;
    return log_factor * 3;
}

/// A property is a testable statement about inputs
/// It combines a generator with a predicate function
pub fn Property(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The generator used to create test values
        generator: Generator(T),

        /// The predicate function that tests each value
        predicate: *const fn (T) bool,

        /// Setup function context and callback
        before_each_context: ?*anyopaque = null,
        before_each_fn: ?*const fn (*anyopaque) void = null,

        /// Teardown function context and callback
        after_each_context: ?*anyopaque = null,
        after_each_fn: ?*const fn (*anyopaque) void = null,

        /// Create a new property from a generator and predicate
        pub fn init(generator: Generator(T), predicate: fn (T) bool) Self {
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
                        @compileError("Hook parameter type doesn't match the expected Context type");
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

        /// Managed version that handles allocation internally
        pub fn check(self: Self, allocator: std.mem.Allocator, bytes: []const u8) !?PropertyFailure {

            // Ensure the input isn't too large for our range type
            if (bytes.len > std.math.maxInt(u32)) {
                return error.InputTooLarge;
            }

            // Allocate a buffer for shrinking ranges
            const buffer_size = maxShrinkRanges(bytes.len);
            var range_buffer = try std.ArrayListUnmanaged(ByteRange).initCapacity(allocator, buffer_size);
            defer range_buffer.deinit(allocator);

            // Call the unmanaged version with our allocated buffer
            return try self.checkUnmanaged(allocator, bytes, &range_buffer);
        }

        /// Unmanaged version that uses a provided stack for shrinking
        pub fn checkUnmanaged(self: Self, allocator: std.mem.Allocator, bytes: []const u8, stack: *std.ArrayListUnmanaged(ByteRange)) !?PropertyFailure {
            // Ensure the input isn't too large for our range type
            if (bytes.len > std.math.maxInt(u32)) {
                return error.InputTooLarge;
            }

            if (try self.runWithBytes(allocator, bytes)) |failure| {
                // Try to shrink the counterexample using the provided buffer

                stack.appendAssumeCapacity(.{ .start = 0, .end = failure.end_offset });
                if (try self.shrinkBytes(allocator, bytes[0..failure.end_offset], stack)) |shrunk_failure| {
                    // Return the shrunk failure
                    return shrunk_failure;
                }
                // If shrinking didn't work, return the original failure
                return failure;
            }
            return null;
        }

        /// Shrink the byte sequence to find a minimal failing example
        fn shrinkBytes(self: Self, allocator: std.mem.Allocator, bytes: []const u8, stack: *std.ArrayListUnmanaged(ByteRange)) !?PropertyFailure {
            var result: ?PropertyFailure = null;

            while (stack.pop()) |current| {
                const current_len = current.len();
                if (result) |res| {
                    if (res.len() < current_len) continue;
                }

                if (try self.runWithBytes(allocator, bytes[@intCast(current.start)..@intCast(current.end)])) |smaller_failure| {
                    // Found a smaller failing input!
                    if (result == null) {
                        result = smaller_failure;
                    }
                    result.?.start_offset = current.start + smaller_failure.start_offset;
                    result.?.end_offset = current.start + smaller_failure.end_offset;
                    result.?.shrink_count += 1;

                    // If we're down to 1 byte, we can't do better
                    if (result.?.len() <= 1) {
                        break;
                    }

                    // Add the halves to the stack (in reverse order so we try the first half first)
                    const mid_point = current.start + (current_len / 2);

                    // Second half
                    if (mid_point < current.end) {
                        stack.appendAssumeCapacity(.{ .start = mid_point, .end = current.end });
                    }

                    // First half
                    if (mid_point > current.start) {
                        stack.appendAssumeCapacity(.{ .start = @intCast(current.start), .end = @intCast(mid_point) });
                    }

                    // Also try removing the first and last bytes
                    if (current_len > 1) {
                        stack.appendAssumeCapacity(.{ .start = @intCast(current.start + 1), .end = @intCast(current.end) });

                        stack.appendAssumeCapacity(.{ .start = @intCast(current.start), .end = @intCast(current.end - 1) });
                    }
                }
            }

            return result;
        }

        /// Run the property with a specific byte sequence
        fn runWithBytes(self: Self, allocator: std.mem.Allocator, bytes: []const u8) !?PropertyFailure {
            var finite_prng = FinitePrng.init(bytes);
            var random = finite_prng.random();

            // Generate a test value
            const test_value = try self.generator.generate(&random, allocator);

            // Run hooks and predicate
            self.runBeforeHook();
            defer self.runAfterHook();

            const predicate_result = self.predicate(test_value);

            if (!predicate_result) {
                // Test failed! Return information about the failure
                const bytes_used_len = @as(u32, @truncate(finite_prng.fixed_buffer.pos));
                return PropertyFailure{
                    .start_offset = 0,
                    .end_offset = bytes_used_len,
                    .shrink_count = 0,
                };
            }

            // Test passed
            return null;
        }

        /// Run the before hook if any
        fn runBeforeHook(self: Self) void {
            if (self.before_each_fn) |hookFn| {
                if (self.before_each_context) |ctx| {
                    hookFn(ctx);
                } else {
                    var dummy: u8 = 0;
                    hookFn(&dummy);
                }
            }
        }

        /// Run the after hook if any
        fn runAfterHook(self: Self) void {
            if (self.after_each_fn) |hookFn| {
                if (self.after_each_context) |ctx| {
                    hookFn(ctx);
                } else {
                    var dummy: u8 = 0;
                    hookFn(&dummy);
                }
            }
        }
    };
}

/// Create a property that checks a condition on generated values
pub fn property(comptime T: type, generator: Generator(T), predicate: fn (T) bool) Property(T) {
    return Property(T).init(generator, predicate);
}
