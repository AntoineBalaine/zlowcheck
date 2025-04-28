const std = @import("std");
const property = @import("property2.zig");
const generator2 = @import("generator2.zig");
const Property = property.Property;
const PropertyResult = property.PropertyResult;

/// Configuration for running property-based tests
pub const RunConfig = struct {
    /// Number of test cases to run
    iterations: usize = 100,

    /// Random seed (null means use time-based seed)
    seed: ?u64 = null,

    /// Whether to print verbose output
    verbose: bool = false,

    /// Maximum number of iterations to run when shrinking
    max_shrink_iterations: usize = 100,

    /// Whether to stop on the first failure
    stop_on_failure: bool = true,
};

/// Runner for property-based tests
pub const Runner = struct {
    /// Allocator for test resources
    allocator: std.mem.Allocator,

    /// Configuration
    config: RunConfig,

    /// Initialize a new runner
    pub fn init(allocator: std.mem.Allocator, config: RunConfig) Runner {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Run a single property test
    pub fn run(self: *Runner, comptime T: type, prop: Property(T)) !PropertyResult {
        const seed: u64 = self.config.seed orelse @intCast(std.time.milliTimestamp());

        if (self.config.verbose) {
            std.debug.print("Running property with seed: {}\n", .{seed});
        }

        // Run the property check
        const result = try prop.check(self.allocator, self.config.iterations, seed);

        // Print the results
        if (self.config.verbose or !result.success) {
            self.printResults(T, result);
        }

        return result;
    }

    /// Run multiple property tests
    pub fn runAll(self: *Runner, properties: anytype) !void {
        const PropertiesType = @TypeOf(properties);
        if (@typeInfo(@TypeOf(properties)) != .@"struct") {
            @compileError("Properties must be a struct, got " ++ @typeName(@TypeOf(properties)));
        }

        const fields = std.meta.fields(PropertiesType);

        var failures: usize = 0;

        inline for (fields) |field| {
            const prop_name = field.name;
            const PropertyType = @TypeOf(@field(properties, prop_name));
            const ValueType = PropertyType.ValueType;

            if (PropertyType != Property) {
                @compileError(std.fmt.comptimePrint("Field {s} is not a Property, got {s}", .{ prop_name, @typeName(PropertyType) }));
            }

            std.debug.print("Testing property: {s}\n", .{prop_name});

            const result = try self.run(ValueType, @field(properties, prop_name));

            if (!result.success) {
                failures += 1;
                if (self.config.stop_on_failure) {
                    break;
                }
            }
        }

        if (failures > 0) {
            std.debug.print("\n{} properties failed!\n", .{failures});
        } else {
            std.debug.print("\nAll properties passed!\n", .{});
        }
    }

    /// Print the results of a property test
    fn printResults(self: *Runner, comptime T: type, result: PropertyResult) void {
        _ = self;

        if (result.success) {
            std.debug.print("✅ Property passed after {} tests\n", .{result.num_passed});
        } else {
            std.debug.print("❌ Property failed after {} tests\n", .{result.num_passed});

            if (result.counterexample) |counter_ptr| {
                const counterexample = @as(*const T, @ptrCast(counter_ptr)).*;
                std.debug.print("Counterexample: {any}\n", .{counterexample});
                std.debug.print("Found after {} shrinking steps\n", .{result.num_shrinks});
            }
        }

        const duration_ms = std.time.milliTimestamp() - result.timestamp;
        std.debug.print("Test completed in {}ms\n", .{duration_ms});
    }
};

/// Run a single property test with default configuration
pub fn check(comptime T: type, prop: Property(T), allocator: std.mem.Allocator) !PropertyResult {
    var runner = Runner.init(allocator, .{});
    return runner.run(T, prop);
}

/// Run a single property test and assert that it passes
/// Convenience function that wraps calling `check` and `std.testing.expect`
pub fn assert(comptime T: type, prop: Property(T), allocator: std.mem.Allocator) !void {
    const result = try check(T, prop, allocator);

    try std.testing.expect(result.success, "Property test failed with counterexample: {any}", .{@as(*const T, @ptrCast(result.counterexample)).*});
}
