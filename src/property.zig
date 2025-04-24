const std = @import("std");
const generator2 = @import("generator2.zig");
const Generator = generator2.Generator;
const Value = generator2.Value;
const ValueList = generator2.ValueList;

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
};

/// A property is a testable statement about inputs
/// It combines a generator with a predicate function
pub fn Property(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The generator used to create test values
        generator: Generator(T),

        /// The predicate function that tests each value
        predicate: fn (T) bool,

        /// Setup function called before each test case (optional)
        before_each: ?fn () void,

        /// Teardown function called after each test case (optional)
        after_each: ?fn () void,

        /// Create a new property from a generator and predicate
        pub fn init(generator: Generator(T), predicate: fn (T) bool) Self {
            return .{
                .generator = generator,
                .predicate = predicate,
                .before_each = null,
                .after_each = null,
            };
        }

        /// Add a setup function to be called before each test case
        pub fn beforeEach(self: Self, hook: fn () void) Self {
            var result = self;
            result.before_each = hook;
            return result;
        }

        /// Add a teardown function to be called after each test case
        pub fn afterEach(self: Self, hook: fn () void) Self {
            var result = self;
            result.after_each = hook;
            return result;
        }

        /// Run the property check for a specific number of iterations
        pub fn check(self: Self, allocator: std.mem.Allocator, iterations: usize, seed: u64) !PropertyResult {
            var prng = std.rand.DefaultPrng.init(seed);
            const random = prng.random();

            var result = PropertyResult{
                .success = true,
                .counterexample = null,
                .num_passed = 0,
                .num_skipped = 0,
                .num_shrinks = 0,
                .timestamp = std.time.milliTimestamp(),
            };

            // Run the test for the specified number of iterations
            var iter: usize = 0;
            while (iter < iterations) : (iter += 1) {
                // Generate a test value
                const test_value = try self.generator.generate(random, iter, allocator);

                // Call the before hook if any
                if (self.before_each) |hook| {
                    hook();
                }

                // Run the predicate on the generated value
                const predicate_result = self.predicate(test_value.value);

                // Call the after hook if any
                if (self.after_each) |hook| {
                    hook();
                }

                if (!predicate_result) {
                    // The predicate failed, we have a counterexample
                    result.success = false;

                    // Try to shrink the counterexample
                    var simplified_value = test_value;
                    var shrink_iterations: usize = 0;

                    // Main shrinking loop
                    var found_simpler = true;
                    while (found_simpler) {
                        found_simpler = false;

                        // Get possible simplifications
                        const shrinks = try self.generator.shrink(simplified_value.value, simplified_value.context, allocator);
                        defer shrinks.deinit();

                        // Find the first shrink that still fails the test
                        for (shrinks.values) |shrink| {
                            // Run the before hook if any
                            if (self.before_each) |hook| {
                                hook();
                            }

                            const shrink_result = self.predicate(shrink.value);

                            // Run the after hook if any
                            if (self.after_each) |hook| {
                                hook();
                            }

                            if (!shrink_result) {
                                // Found a simpler failing case
                                simplified_value.deinit(allocator);

                                // Create a copy of the shrunk value
                                simplified_value = shrink;
                                shrink_iterations += 1;
                                found_simpler = true;
                                break;
                            }
                        }
                    }

                    // Store the counterexample and shrink count
                    result.counterexample = @as(*anyopaque, @ptrCast(&simplified_value.value));
                    result.num_shrinks = shrink_iterations;

                    // Exit early since we found a failing case
                    return result;
                }

                // If the predicate passed, clean up and increment the counter
                test_value.deinit(allocator);
                result.num_passed += 1;
            }

            return result;
        }
    };
}

/// Create a property that checks a condition on generated values
pub fn property(comptime T: type, generator: Generator(T), predicate: fn (T) bool) Property(T) {
    return Property(T).init(generator, predicate);
}

/// Create a property for a tuple of generated values
pub fn tupleProperty(comptime Tuple: type, generators: anytype, predicate: fn (Tuple) bool) !Property(Tuple) {
    _ = generators;
    _ = predicate;
    // We would implement a way to create a tuple generator from multiple generators
    // For now, this is a placeholder
    @compileError("tupleProperty not yet implemented");
}
