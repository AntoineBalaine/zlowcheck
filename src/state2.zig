const std = @import("std");
const FinitePrng = @import("finite_prng.zig");
const generator_mod = @import("generator.zig");
const Generator = generator_mod.Generator;
const finite_prng = @import("finite_prng");

pub const CommandPosition = struct {
    /// Start index (inclusive)
    start: usize,

    /// End index (exclusive)
    end: usize,
};

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
        /// Returns fals if the command fails or if the system state doesn't match expectations
        pub fn run(self: *Self, model: *ModelType, sut: *SystemType) !bool {
            _ = self;
            _ = model;
            _ = sut;
            return true;
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

/// Result of a stateful test failure
/// However, the StatefulFailure seems to contain too much information:
/// we can’t retrieve the failure bytes, because we might not have generators, so that’s not really priority. I do want to be able to serialize them, but we should discuss this later. Let’s leave them in the function
///
/// Do we need to keep the allocator in, though? we know which allocator we’re using, and these bytes aren’t owned by the Failure struct, they’re owned by the finite_prng. As a result, we can remove the denit function as well.
/// num_passed and num_shrinks should be u16s instead of usize, which is architecture-dependent.
pub const StatefulFailure = struct {
    /// Number of test cases that passed before failure
    num_passed: usize,

    /// Number of shrinking steps performed
    num_shrinks: usize,

    /// The byte sequence that produced the failure (if available)
    failing_position: CommandPosition,

    pub fn init(failure_idx: usize) @This() {
        return @This(){
            .num_passed = failure_idx - 1,
            .num_shrinks = 0,
            .failing_position = .{ .start = 0, .end = @intCast(failure_idx) },
        };
    }
};

/// Assert that a stateful system behaves according to its model (unmanaged version)
/// Caller is responsible for initializing and cleaning up model and sut
pub fn assertStatefulUnmanaged(
    comptime ModelType: type,
    comptime SystemType: type,
    command_sequence: CommandSequence(ModelType, SystemType), // we could convert this to an anytype for more flexibility
    model: *ModelType,
    sut: *SystemType,
    config: StatefulConfig,
) !?StatefulFailure {
    std.debug.assert(config.max_commands_per_run <= std.math.maxInt(u32));
    // Get an iterator for the command sequence
    var iterator = command_sequence.iterator(null);

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
        if (cmd.run(model, sut)) continue;

        // Create a failure result
        var result: StatefulFailure = .init(iterator.index);

        // Try to shrink the command sequence
        const shrunk_position = try shrinkCommandSequence(
            ModelType,
            SystemType,
            command_sequence,
            model,
            sut,
            config,
        );

        result.failing_position = shrunk_position;

        if (config.verbose) {
            formatStatefulFailure(ModelType, SystemType, command_sequence, model, result);
        }
        return result;
    }

    // If we get here, all commands passed
    return null;
}

/// Shrink a command sequence while preserving the failure
pub fn shrinkCommandSequence(
    comptime ModelType: type,
    comptime SystemType: type,
    command_sequence: CommandSequence(ModelType, SystemType),
    model: *ModelType,
    sut: *SystemType,
    config: StatefulConfig,
) !CommandPosition {
    // Start with the full sequence that caused the failure
    var best_position = CommandPosition{ .start = 0, .end = command_sequence.sequence.items.len };

    // Track the number of shrinking steps
    var shrink_steps: usize = 0;

    // Binary search to find the smallest failing subsequence
    while (best_position.end - best_position.start > 1) {
        // Divide the current chunk in two
        const mid = best_position.start + (best_position.end - best_position.start) / 2;

        // Try the right half first (where the failure was last seen)
        const right_chunk = CommandPosition{
            .start = mid,
            .end = best_position.end,
        };

        // Test if the right chunk still reproduces the failure
        if (try testChunk(ModelType, SystemType, command_sequence, right_chunk, model, sut)) {
            // Right chunk still fails - we can discard the left chunk
            best_position.start = mid;
            shrink_steps += 1;
        } else {
            // Right chunk doesn't fail - the failure must be in the left chunk
            // or span across both chunks

            // Try the left chunk
            const left_chunk = CommandPosition{
                .start = best_position.start,
                .end = mid,
            };

            if (try testChunk(ModelType, SystemType, command_sequence, left_chunk, model, sut)) {
                // Left chunk fails - we can discard the right chunk
                best_position.end = mid;
                shrink_steps += 1;
            } else {
                // Neither half fails on its own - we need both chunks
                // We can't shrink further with this binary approach
                break;
            }
        }
    }

    if (config.verbose) {
        std.debug.print("Shrunk command sequence to commands {}..{} in {} steps\n", .{ best_position.start, best_position.end, shrink_steps });
    }

    return best_position;
}

/// Test if a chunk of the command sequence reproduces the failure
fn testChunk(
    comptime ModelType: type,
    comptime SystemType: type,
    command_sequence: CommandSequence(ModelType, SystemType),
    chunk: CommandPosition,
    model: *ModelType,
    sut: *SystemType,
) !bool {
    // Reset model and SUT to initial state
    // (These would need to be implemented by the user)
    model.reset();
    sut.reset();

    // Use the existing iterator to replay the chunk
    var iterator = command_sequence.iterator(chunk);

    // Run through the commands in this chunk
    while (try iterator.next()) |cmd| {
        // Check precondition
        if (!cmd.checkPrecondition(model)) {
            // Skip commands that don't meet preconditions
            continue;
        }

        // Apply to model
        cmd.apply(model);

        // Run on the system under test
        if (!try cmd.run(model, sut)) {
            // Found a failure - this chunk reproduces the issue
            return true;
        }
    }

    // No failure found with this chunk
    return false;
}

pub fn CommandSequence(comptime M: type, comptime S: type) type {
    return struct {
        const Self = @This();

        random: *FinitePrng.FiniteRandom,
        max_runs: u32,
        commands: []const Command(M, S),
        sequence: std.ArrayListUnmanaged(Entry),

        const Idx = enum(u32) {
            _,
            // Helper to convert from u32 to enum
            pub fn fromIndex(index: u32) Idx {
                return @enumFromInt(index);
            }
            // Helper to convert back to u32 if needed
            pub fn toIndex(self: Idx) u32 {
                return @intFromEnum(self);
            }
        };

        const Entry = struct {
            byte_pos: u32,
            cmd_idx: Idx,
        };

        pub fn init(
            commands: []const Command(M, S),
            random: *FinitePrng.FiniteRandom,
            max_runs: usize,
            allocator: std.mem.Allocator,
        ) !Self {
            return .{
                .random = random,
                .max_runs = max_runs,
                .commands = commands,
                .sequence = try std.ArrayListUnmanaged(Command(M, S)).initCapacity(allocator, max_runs),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.sequence.deinit(allocator);
        }

        pub fn iterator(self: *Self, position: ?CommandPosition) Iterator {
            if (position) |pos| {
                self.random.prng.fixed_buffer.pos = self.sequence.items[pos.start].byte_pos;
            }
            return Iterator{
                .parent = self,
                .index = if (position) |pos| pos.start else 0,
            };
        }

        pub const Iterator = struct {
            parent: *Self,
            index: usize,

            pub fn next(self: *Iterator) !?Command(M, S) {
                if (self.index >= self.parent.max_runs) return null;

                const cmd_idx = try self.parent.random.intRangeLessThan(u32, 0, self.parent.commands.len);
                const byte_pos = self.parent.random.prng.fixed_buffer.pos;

                // Store it in our history
                self.parent.sequence.appendAssumeCapacity(.{ .byte_pos = byte_pos, .cmd_idx = Idx.fromIndex(cmd_idx) });

                self.index += 1;
                return self.parent.commands[@intCast(cmd_idx.toIndex())];
            }

            pub fn reset(self: *Iterator) void {
                // Reset to the start position
                self.index = self.start;
            }
        };

        pub fn getFailureBytes(self: *const Self, position: CommandPosition) []const u8 {
            // Assert that we have a valid position
            std.debug.assert(position.start < position.end);
            std.debug.assert(position.end > 0);
            std.debug.assert(position.end <= self.sequence.items.len);

            // Get the last command entry
            const last_cmd_idx = position.end;
            const last_entry = self.sequence.items[last_cmd_idx];
            const bytes_pos = last_entry.byte_pos;

            // Return the bytes up to this position
            return self.random.prng.fixed_buffer.buffer[0..bytes_pos];
        }
    };
}

pub fn formatStatefulFailure(
    comptime ModelType: type,
    comptime SystemType: type,
    command_sequence: CommandSequence(ModelType, SystemType),
    model: *ModelType,
    failure: StatefulFailure,
) void {
    // Basic failure information is always printed
    std.debug.print("\n=== Stateful Test Failed ===\n{}\n", .{failure});

    // If verbose mode is enabled, print detailed information
    const failure_pos = failure.failing_position;
    std.debug.print("\nFailing commands:\n", .{});

    // Reset model to initial state
    model.reset();

    // Create an iterator for the failing sequence
    var iterator = command_sequence.iterator(failure_pos);
    var i: usize = failure_pos.start;

    while (iterator.next()) |cmd| {
        if (!cmd.checkPrecondition(model)) {
            std.debug.print("  {}: [SKIPPED] ", .{i});
        } else {
            std.debug.print("  {}: ", .{i});
            cmd.apply(model);
        }

        // Print the command (using its format method)
        std.debug.print("{}\n", .{cmd});
        i += 1;
    }

    const bytes = command_sequence.getFailureBytes(failure.failing_position);

    std.debug.print("\nFailure produced by {} bytes:\n", .{bytes.len});

    // Print in rows of 16 bytes
    var byte_idx: usize = 0;
    while (byte_idx < bytes.len) {
        std.debug.print("{X:0>4}: ", .{byte_idx});

        var j: usize = 0;
        while (j < 16 and byte_idx + j < bytes.len) : (j += 1) {
            std.debug.print("{X:0>2} ", .{bytes[byte_idx + j]});
        }

        // Pad if needed
        while (j < 16) : (j += 1) {
            std.debug.print("   ", .{});
        }

        std.debug.print(" | ", .{});

        j = 0;
        while (j < 16 and byte_idx + j < bytes.len) : (j += 1) {
            const c = bytes[byte_idx + j];
            if (std.ascii.isPrint(c)) {
                std.debug.print("{c}", .{c});
            } else {
                std.debug.print(".", .{});
            }
        }

        std.debug.print("\n", .{});
        byte_idx += 16;
    }
}
