const std = @import("std");
/// Position within a command sequence
pub const CommandPosition = struct {
    /// Start index (inclusive)
    start: usize,

    /// End index (exclusive)
    end: usize,
};

/// Interface for anything that can produce a sequence of commands
pub fn CommandSequence(comptime CommandType: type) type {
    return struct {
        /// Get an iterator over the commands in this sequence
        /// Optionally starting at a specific position
        pub fn iterator(self: @This(), position: ?CommandPosition) Iterator {
            _ = self; // autofix
            _ = position;
            @compileError("iterator() not implemented");
        }

        /// Get a slice of commands from this sequence
        pub fn getSlice(self: @This(), position: CommandPosition) []const CommandType {
            _ = self; // autofix
            _ = position;
            @compileError("getSlice() not implemented");
        }

        /// Iterator type for this sequence
        pub const Iterator = struct {
            /// Get the next command in the sequence, or null if done
            pub fn next(self: *Iterator) ?CommandType {
                _ = self; // autofix
                @compileError("next() not implemented");
            }

            /// Reset the iterator to the beginning
            pub fn reset(self: *Iterator) void {
                _ = self; // autofix
                @compileError("reset() not implemented");
            }

            /// Get the current position in the sequence
            pub fn getPosition(self: *Iterator) CommandPosition {
                _ = self; // autofix
                @compileError("getPosition() not implemented");
            }
        };
    };
}

/// Result of a stateful test failure
/// However, the StatefulFailure seems to contain too much information:
/// we can’t retrieve the failure bytes, because we might not have generators, so that’s not really priority. I do want to be able to serialize them, but we should discuss this later. Let’s leave them in the function
///
/// Do we need to keep the allocator in, though? we know which allocator we’re using, and these bytes aren’t owned by the Failure struct, they’re owned by the finite_prng. As a result, we can remove the denit function as well.
/// num_passed and num_shrinks should be u16s instead of usize, which is architecture-dependent.
pub const StatefulFailure = struct {
    /// Position of the failing command sequence
    failing_position: CommandPosition,

    /// Number of test cases that passed before failure
    num_passed: usize,

    /// Number of shrinking steps performed
    num_shrinks: usize,

    /// The byte sequence that produced the failure (if available)
    failure_bytes: ?BytePosition,

    /// Allocator used for this result
    allocator: std.mem.Allocator,

    /// Free resources associated with this failure
    pub fn deinit(self: *StatefulFailure) void {
        if (self.failure_bytes) |bytes| {
            self.allocator.free(bytes);
        }
    }
};

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
    random: finite_prng.random,
) !?StatefulFailure {
    // Get an iterator for the command sequence
    var iterator = command_sequence.iterator(null);

    const start_byte = random.prng.fixed_buffer.pos;

    var cmd_index: usize = 0;

    // Run through the commands
    while (try iterator.next()) |cmd| {
        // Check precondition
        if (!cmd.checkPrecondition(model)) {
            // Skip commands that don't meet preconditions
            continue;
        }

        // Apply to model
        cmd.apply(model);

        // Run on the system under test
        if (cmd.run(model, sut)) |_| {

            // Get the current position in the sequence
            const position = iterator.getPosition();

            // Create a failure result
            var result = StatefulFailure{
                .failing_position = position,
                .num_passed = cmd_index,
                .num_shrinks = 0,
                .failure_bytes = .{ .start = start_byte, .end = random.prng.fixed_buffer.pos },
                .allocator = allocator,
            };

            // Try to get the bytes that produced this failure if available
            // This would be implementation-specific and handled by the command sequence

            // Try to shrink the command sequence
            const shrunk_position = try shrinkCommandSequence(ModelType, SystemType, command_sequence, model, sut, position, config, allocator);

            // Update the failure with the shrunk position
            result.failing_position = shrunk_position;

            return result;
        }

        cmd_index += 1;
    }

    // If we get here, all commands passed
    return null;
}

/// Shrink a command sequence while preserving the failure
pub fn shrinkCommandSequence(
    comptime ModelType: type,
    comptime SystemType: type,
    command_sequence: anytype,
    model: *ModelType,
    sut: *SystemType,
    failing_position: CommandPosition,
    config: StatefulConfig,
    allocator: std.mem.Allocator,
) !CommandPosition {
    _ = config;
    _ = allocator;

    // Get the failing slice
    const failing_slice = command_sequence.getSlice(failing_position);

    // Try various shrinking strategies:
    // 1. Remove commands from the end
    // 2. Remove commands from the middle
    // 3. Simplify individual commands

    // For now, just return the original position
    // Actual shrinking implementation would go here
    return failing_position;
}

pub fn AllocatingCommandSequence(comptime T: type) type {
    return struct {
        const Self = @This();

        generator: Generator(T),
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

        pub fn iterator(self: *Self, position: ?CommandPosition) Iterator {
            return Iterator{
                .parent = self,
                .start = if (position) |pos| pos.start else 0,
                .end = if (position) |pos| pos.end else self.max_length,
                .index = if (position) |pos| pos.start else 0,
            };
        }

        pub fn getSlice(self: *Self, position: CommandPosition) []const T {
            const end = @min(position.end, self.commands.items.len);
            return self.commands.items[position.start..end];
        }

        pub const Iterator = struct {
            parent: *Self,
            start: usize,
            end: usize,
            index: usize,

            pub fn next(self: *Iterator) !?T {
                // If we've reached the end position or maximum length
                if (self.index >= self.end || (self.index >= self.parent.max_length)) return null;

                // If we're replaying existing commands
                if (self.index < self.parent.commands.items.len) {
                    const cmd = self.parent.commands.items[self.index];
                    self.index += 1;
                    return cmd;
                }

                // Generate a new command
                const value = try self.parent.generator.generate(self.parent.random, self.parent.allocator);

                // Store it in our history
                try self.parent.commands.append(value.value);

                // Clean up the generator context since we've copied the value
                value.deinit(self.parent.allocator);

                self.index += 1;
                return self.parent.commands.items[self.index - 1];
            }

            pub fn reset(self: *Iterator) void {
                // Reset to the start position
                self.index = self.start;
            }

            pub fn getPosition(self: *Iterator) CommandPosition {
                return .{
                    .start = self.start,
                    .end = self.index,
                };
            }
        };
    };
}

pub fn FixedCommandSequence(comptime T: type) type {
    return struct {
        commands: []const T,

        pub fn iterator(self: @This(), position: ?CommandPosition) Iterator {
            return Iterator{
                .commands = self.commands,
                .start = if (position) |pos| pos.start else 0,
                .end = if (position) |pos| pos.end else self.commands.len,
                .index = if (position) |pos| pos.start else 0,
            };
        }

        pub fn getSlice(self: @This(), position: CommandPosition) []const T {
            const end = @min(position.end, self.commands.len);
            return self.commands[position.start..end];
        }

        pub const Iterator = struct {
            commands: []const T,
            start: usize,
            end: usize,
            index: usize,

            pub fn next(self: *Iterator) ?T {
                if (self.index >= self.end) return null;
                const cmd = self.commands[self.index];
                self.index += 1;
                return cmd;
            }

            pub fn reset(self: *Iterator) void {
                self.index = self.start;
            }

            pub fn getPosition(self: *Iterator) CommandPosition {
                return .{
                    .start = self.start,
                    .end = self.index,
                };
            }
        };
    };
}
