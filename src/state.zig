const std = @import("std");
const FinitePrng = @import("finite_prng.zig");
const generator = @import("generator.zig");
const property = @import("property.zig");
const assert = @import("assert.zig");

/// Define the Command interface for model-based testing
pub fn Command(comptime ModelType: type, comptime SystemType: type) type {
    return struct {
        const Self = @This();

        /// Check if this command can be applied to the current model state
        pub fn checkPrecondition(self: *Self, model: *ModelType) bool {
            _ = self;
            _ = model;
            return true; // Default implementation always allows command
        }

        /// Apply this command to the model (update model state)
        pub fn apply(self: *Self, model: *ModelType) void {
            _ = self;
            _ = model;
            // Default implementation does nothing
        }

        /// Run this command on the actual system under test and verify the results
        /// Returns an error if the command fails or if the system state doesn't match expectations
        pub fn run(self: *Self, model: *ModelType, sut: *SystemType) !void {
            _ = self;
            _ = model;
            _ = sut;
            // Default implementation does nothing
        }

        /// Format the command for debugging
        pub fn format(self: *Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = self;
            _ = fmt;
            _ = options;
            try writer.writeAll("Command");
        }
    };
}

/// Interface for anything that can produce a sequence of commands
pub fn CommandSequence(comptime CommandType: type) type {
    return struct {
        /// Get an iterator over the commands in this sequence
        pub fn iterator(self: @This()) Iterator {
            @compileError("iterator() not implemented");
        }

        /// Iterator type for this sequence
        pub const Iterator = struct {
            /// Get the next command in the sequence, or null if done
            pub fn next(self: *Iterator) ?CommandType {
                @compileError("next() not implemented");
            }

            /// Reset the iterator to the beginning
            pub fn reset(self: *Iterator) void {
                @compileError("reset() not implemented");
            }
        };
    };
}

/// A fixed sequence of commands
pub fn FixedCommandSequence(comptime T: type) type {
    return struct {
        commands: []const T,

        pub fn iterator(self: @This()) Iterator {
            return Iterator{ .commands = self.commands, .index = 0 };
        }

        pub const Iterator = struct {
            commands: []const T,
            index: usize,

            pub fn next(self: *Iterator) ?T {
                if (self.index >= self.commands.len) return null;
                const cmd = self.commands[self.index];
                self.index += 1;
                return cmd;
            }

            pub fn reset(self: *Iterator) void {
                self.index = 0;
            }
        };
    };
}

/// Create a fixed command sequence
pub fn fixedCommands(commands: anytype) FixedCommandSequence(@TypeOf(commands[0])) {
    return .{ .commands = commands };
}

/// A sequence of commands generated on-the-fly
pub fn GeneratedCommandSequence(comptime T: type) type {
    return struct {
        generator: Generator,
        random: *FinitePrng.FiniteRandom,
        max_length: usize,

        pub fn iterator(self: @This()) Iterator {
            return Iterator{
                .generator = self.generator,
                .random = self.random,
                .max_length = self.max_length,
                .count = 0,
            };
        }

        pub const Iterator = struct {
            generator: Generator,
            random: *FinitePrng.FiniteRandom,
            max_length: usize,
            count: usize,

            pub fn next(self: *Iterator) ?T {
                if (self.count >= self.max_length) return null;
                self.count += 1;
                return self.generator.generate(self.random);
            }

            pub fn reset(self: *Iterator) void {
                // Note: This doesn't reset the random state,
                // so it will generate different commands
                self.count = 0;
            }
        };
    };
}

/// Create a generated command sequence
pub fn generatedCommands(generator: anytype, random: *FinitePrng.FiniteRandom, max_length: usize) GeneratedCommandSequence(@TypeOf(generator.generate(random))) {
    return .{
        .generator = generator,
        .random = random,
        .max_length = max_length,
    };
}

/// A sequence of commands for model-based testing
pub fn CommandSeq(comptime ModelType: type, comptime SystemType: type, comptime CmdType: type) type {
    return struct {
        const Self = @This();

        commands: []CmdType,
        allocator: std.mem.Allocator,

        /// Initialize a new command sequence
        pub fn init(commands: []CmdType, allocator: std.mem.Allocator) Self {
            return .{
                .commands = commands,
                .allocator = allocator,
            };
        }

        /// Free resources associated with this command sequence
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.commands);
        }

        /// Apply each cmd in `cmds` to the given model
        pub fn applyAll(self: Self, model: *ModelType) void {
            for (self.commands) |*cmd| {
                cmd.apply(model);
            }
        }

        /// Run each cmd in `cmds` on the given sut, assuming the state of the given model
        pub fn runAll(self: Self, model: *ModelType, sut: *SystemType) !void {
            for (self.commands) |*cmd| {
                try cmd.run(model, sut);
            }
        }

        /// Check if this is a valid sequence for the given model
        pub fn isValidSequence(self: Self, model: *ModelType) bool {
            var model_copy = model.*;

            for (self.commands) |*cmd| {
                if (!cmd.checkPrecondition(&model_copy)) {
                    return false;
                }
                cmd.apply(&model_copy);
            }

            return true;
        }
    };
}

/// Configuration for stateful testing
pub const StatefulConfig = struct {
    /// Number of bytes to use for testing (more bytes = more test cases)
    /// If null, random bytes will be generated
    bytes: ?[]const u8 = null,

    /// Number of runs to attempt (only used if bytes is null)
    runs: u32 = 100,

    /// Maximum number of commands per test sequence
    max_commands_per_run: u32 = 100,

    /// Whether to print verbose output
    verbose: bool = false,
};

/// Result of a stateful test failure
pub const StatefulFailure = struct {
    /// The failing command sequence
    failing_sequence: []const u8,

    /// Index of the command that failed
    failing_command_index: usize,

    /// Number of test cases that passed before failure
    num_passed: usize,

    /// Number of shrinking steps performed
    num_shrinks: usize,

    /// The byte sequence that produced the failure
    failure_bytes: []const u8,

    /// Allocator used for this result
    allocator: std.mem.Allocator,

    /// Free resources associated with this failure
    pub fn deinit(self: *StatefulFailure) void {
        self.allocator.free(self.failing_sequence);
        self.allocator.free(self.failure_bytes);
    }
};

/// Assert that a stateful system behaves according to its model
/// Returns null if the test passes, or a StatefulFailure if it fails
pub fn assertStateful(
    comptime ModelType: type,
    comptime SystemType: type,
    command_sequence: anytype,
    config: StatefulConfig,
    allocator: std.mem.Allocator,
) !?StatefulFailure {
    // Implementation will be added later
    _ = ModelType;
    _ = SystemType;
    _ = command_sequence;
    _ = config;
    _ = allocator;
    return null;
}

/// Assert that a stateful system behaves according to its model (unmanaged version)
/// Caller is responsible for initializing and cleaning up model and sut
pub fn assertStatefulUnmanaged(
    comptime ModelType: type,
    comptime SystemType: type,
    command_sequence: anytype,
    model: *ModelType,
    sut: *SystemType,
    config: StatefulConfig,
    allocator: std.mem.Allocator,
) !?StatefulFailure {
    // Implementation will be added later
    _ = ModelType;
    _ = SystemType;
    _ = command_sequence;
    _ = model;
    _ = sut;
    _ = config;
    _ = allocator;
    return null;
}

/// Generate a valid command sequence using the provided generator
pub fn generateCommandSequence(
    comptime ModelType: type,
    comptime SystemType: type,
    command_generator: anytype,
    random: *FinitePrng.FiniteRandom,
    model: *ModelType,
    max_length: usize,
    allocator: std.mem.Allocator,
) ![]anyopaque {
    // Implementation will be added later
    _ = ModelType;
    _ = SystemType;
    _ = command_generator;
    _ = random;
    _ = model;
    _ = max_length;
    _ = allocator;
    return allocator.alloc(u8, 0);
}

/// Shrink a command sequence while preserving the failure
pub fn shrinkCommandSequence(
    comptime ModelType: type,
    comptime SystemType: type,
    command_generator: anytype,
    allocator: std.mem.Allocator,
    failing_sequence: []const anyopaque,
    failing_index: usize,
    config: StatefulConfig,
) ![]const u8 {
    // Implementation will be added later
    _ = ModelType;
    _ = SystemType;
    _ = command_generator;
    _ = allocator;
    _ = failing_sequence;
    _ = failing_index;
    _ = config;
    return allocator.dupe(u8, @as([]const u8, @ptrCast(failing_sequence)));
}

test {
    std.testing.refAllDecls(@This());
}

pub fn AllocatingCommandSequence(comptime T: type) type {
    return struct {
        const Self = @This();

        generator: Generator,
        random: *FinitePrng.FiniteRandom,
        max_length: usize,
        allocator: std.mem.Allocator,
        commands: std.ArrayList(T),

        pub fn init(generator: anytype, random: *FinitePrng.FiniteRandom, max_length: usize, allocator: std.mem.Allocator) Self {
            var commands = std.ArrayList(T).init(allocator);
            // Preallocate capacity to avoid reallocations
            commands.ensureTotalCapacity(max_length) catch {};

            return .{
                .generator = generator,
                .random = random,
                .max_length = max_length,
                .allocator = allocator,
                .commands = commands,
            };
        }

        pub fn deinit(self: *Self) void {
            // Clean up any resources in the commands if needed
            for (self.commands.items) |*cmd| {
                if (@hasDecl(@TypeOf(cmd.*), "deinit")) {
                    cmd.deinit(self.allocator);
                }
            }
            self.commands.deinit();
        }

        pub fn iterator(self: *Self) Iterator {
            return Iterator{
                .parent = self,
                .index = 0,
            };
        }

        pub const Iterator = struct {
            parent: *Self,
            index: usize,

            pub fn next(self: *Iterator) !?T {
                // If we've reached the maximum length
                if (self.index >= self.parent.max_length) return null;

                // If we're replaying existing commands
                if (self.index < self.parent.commands.items.len) {
                    const cmd = self.parent.commands.items[self.index];
                    self.index += 1;
                    return cmd;
                }

                // Generate a new command
                const cmd = try self.parent.generator.generate(self.parent.random, self.parent.allocator);

                // Store it in our history
                try self.parent.commands.append(cmd.value);

                // Clean up the generator context since we've copied the value
                cmd.deinit(self.parent.allocator);

                self.index += 1;
                return self.parent.commands.items[self.index - 1];
            }

            pub fn reset(self: *Iterator) void {
                // Just reset the index to replay from the beginning
                self.index = 0;
            }

            pub fn getHistory(self: *Iterator) []const T {
                return self.parent.commands.items[0..self.index];
            }
        };
    };
}
