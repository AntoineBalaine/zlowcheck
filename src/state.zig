const std = @import("std");
const FinitePrng = @import("finite_prng");
const generator_mod = @import("generator.zig");
const Generator = generator_mod.Generator;

pub const CommandPosition = struct {
    /// Start index (inclusive)
    start: usize,

    /// End index (exclusive)
    end: usize,
};

/// Configuration for stateful testing
pub const StatefulConfig = struct {
    /// Whether to print verbose output
    verbose: bool = false,
};

pub fn Command(comptime ModelType: type, comptime SystemType: type) type {
    return struct {
        const Self = @This();

        /// Function that checks if the command can be applied to the current model state
        checkPreconditionFn: *const fn (ctx: *const anyopaque, model: *ModelType) bool,

        /// Function that applies the command to the model
        onModelOnlyFn: *const fn (ctx: *const anyopaque, model: *ModelType) void,

        /// Function that runs the command on the system under test
        onPairFn: *const fn (ctx: *const anyopaque, model: *ModelType, sut: *SystemType) anyerror!bool,

        name: []const u8,
        /// Context pointer for the command implementation
        ctx: *const anyopaque,

        /// Check if this command can be applied to the current model state
        pub fn checkPrecondition(self: *const Self, model: *ModelType) bool {
            return self.checkPreconditionFn(self.ctx, model);
        }

        /// Apply this command to the model (update model state)
        pub fn onModelOnly(self: *const Self, model: *ModelType) void {
            self.onModelOnlyFn(self.ctx, model);
        }

        /// Run this command on the SUT/model pair and check the result.
        /// Returns false if the command fails or if the system state doesn't match expectations
        pub fn onPair(self: *const Self, model: *ModelType, sut: *SystemType) !bool {
            return self.onPairFn(self.ctx, model, sut);
        }

        pub fn format(self: *const Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) anyerror!void {
            _ = fmt;
            _ = options;
            try writer.writeAll(self.name);
        }

        /// Format the command for debugging
        /// Create a command from any type that implements the required methods
        pub fn init(cmd: anytype) Self {
            const T = @TypeOf(cmd);
            const ChildType = @TypeOf(cmd.*);

            // Get name from the command type if available
            const name = if (@hasDecl(ChildType, "name"))
                ChildType.name
            else
                @typeName(ChildType);

            return .{
                .checkPreconditionFn = struct {
                    fn checkPrecondition(ctx: *const anyopaque, model: *ModelType) bool {
                        const self = @as(T, @ptrCast(@constCast(@alignCast(ctx))));
                        return self.checkPrecondition(model);
                    }
                }.checkPrecondition,

                .onModelOnlyFn = struct {
                    fn onModelOnly(ctx: *const anyopaque, model: *ModelType) void {
                        const self = @as(T, @ptrCast(@constCast(@alignCast(ctx))));
                        self.onModelOnly(model);
                    }
                }.onModelOnly,

                .onPairFn = struct {
                    fn onPair(ctx: *const anyopaque, model: *ModelType, sut: *SystemType) !bool {
                        const self = @as(T, @ptrCast(@constCast(@alignCast(ctx))));
                        return self.onPair(model, sut);
                    }
                }.onPair,

                .ctx = cmd,
                .name = name,
            };
        }
    };
}

pub const StatefulFailure = struct {
    /// Number of test cases that passed before failure
    num_passed: usize,

    /// The byte sequence that produced the failure (if available)
    failing_position: CommandPosition,

    /// NOT meant to be used from the shrinking logic
    /// this is only for a first run.
    pub fn init(failure_idx: usize) @This() {
        return @This(){
            .num_passed = failure_idx - 1,
            .failing_position = .{ .start = 0, .end = @intCast(failure_idx) },
        };
    }
};

/// Assert that a stateful system behaves according to its model
/// Caller is responsible for initializing and cleaning up model and sut
pub fn assertStateful(
    comptime ModelType: type,
    comptime SystemType: type,
    command_sequence: anytype, // we could convert this to an anytype for more flexibility
    model: *ModelType,
    sut: *SystemType,
    config: StatefulConfig,
) !?StatefulFailure {
    std.debug.assert(command_sequence.max_runs <= std.math.maxInt(u32));
    // Get an iterator for the command sequence
    var iterator = command_sequence.iterator(null);

    // Run through the commands
    while (try iterator.next()) |*cmd| {
        // Check precondition
        if (!cmd.checkPrecondition(model)) {
            // Skip commands that don't meet preconditions
            continue;
        }

        // Run on the system under test
        if (try cmd.onPair(model, sut)) continue;

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
            try formatStatefulFailure(ModelType, SystemType, command_sequence, model, result);
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
    command_sequence: *CommandList(ModelType, SystemType),
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
    command_sequence: *CommandList(ModelType, SystemType),
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
    while (try iterator.nextReplay()) |cmd| {
        // Check precondition
        if (!cmd.checkPrecondition(model)) {
            // Skip commands that don't meet preconditions
            continue;
        }

        // Run on the system under test
        if (!try cmd.onPair(model, sut)) {
            // Found a failure - this chunk reproduces the issue
            return true;
        }
    }

    // No failure found with this chunk
    return false;
}

pub fn CommandList(comptime M: type, comptime S: type) type {
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
            std.debug.assert(max_runs <= std.math.maxInt(u32));
            return .{
                .random = random,
                .max_runs = @intCast(max_runs),
                .commands = commands,
                .sequence = try std.ArrayListUnmanaged(Entry).initCapacity(allocator, max_runs),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.sequence.deinit(allocator);
        }

        pub fn iterator(self: *Self, position: ?CommandPosition) Iterator {
            if (position) |pos| {
                self.random.prng.fixed_buffer.pos = self.sequence.items[pos.start].byte_pos;
                return Iterator{ .parent = self, .index = pos.start, .max_runs = pos.end };
            }

            return Iterator{ .parent = self, .index = if (position) |pos| pos.start else 0, .max_runs = self.max_runs };
        }

        pub const Iterator = struct {
            parent: *Self,
            index: usize,
            max_runs: usize,

            pub fn next(self: *Iterator) !?Command(M, S) {
                if (self.index >= self.max_runs) return null;

                const byte_pos = self.parent.random.prng.fixed_buffer.pos;
                const cmd_idx = try self.parent.random.intRangeLessThan(u32, 0, @intCast(self.parent.commands.len));

                // Store it in our history
                self.parent.sequence.appendAssumeCapacity(.{ .byte_pos = @intCast(byte_pos), .cmd_idx = Idx.fromIndex(cmd_idx) });

                self.index += 1;
                return self.parent.commands[@intCast(cmd_idx)];
            }

            /// doesn’t record the commands into the sequence list,
            /// doesn’t generate new command selection - only replays through the list of decisions
            pub fn nextReplay(self: *Iterator) !?Command(M, S) {
                if (self.index >= self.max_runs) return null;

                const cmd_idx = try self.parent.random.intRangeLessThan(u32, 0, @intCast(self.parent.commands.len));

                self.index += 1;
                return self.parent.commands[@intCast(cmd_idx)];
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
            const last_cmd_idx = position.end - 1;
            const first_entry = self.sequence.items[position.start];
            const last_entry = self.sequence.items[last_cmd_idx];

            // Return the bytes up to this position
            return self.random.prng.fixed_buffer.buffer[first_entry.byte_pos..last_entry.byte_pos];
        }
    };
}

pub fn formatStatefulFailure(
    comptime ModelType: type,
    comptime SystemType: type,
    command_sequence: *CommandList(ModelType, SystemType),
    model: *ModelType,
    failure: StatefulFailure,
) !void {
    // Basic failure information is always printed
    std.debug.print("\n=== Stateful Test Failed ===\n{}\n", .{failure});

    // If verbose mode is enabled, print detailed information
    const failure_pos = failure.failing_position;
    std.debug.print("\nFailing commands:\n", .{});

    // Reset model to initial state
    model.reset();

    // Create an iterator for the failing sequence
    var iterator = command_sequence.iterator(failure_pos);

    while (try iterator.nextReplay()) |cmd| {
        if (!cmd.checkPrecondition(model)) {
            std.debug.print("  {}: [SKIPPED] ", .{iterator.index});
        } else {
            std.debug.print("  {}: ", .{iterator.index});
            cmd.onModelOnly(model);
        }

        // Print the command (using its format method)
        std.debug.print("{}\n", .{cmd});
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

test assertStateful {
    // Define a simple model
    const Model = struct {
        value: u32 = 0,

        pub fn reset(self: *@This()) void {
            self.value = 0;
        }
    };

    // Define a simple system under test
    const System = struct {
        value: u32 = 0,

        pub fn reset(self: *@This()) void {
            self.value = 0;
        }

        pub fn increment(self: *@This()) void {
            if (self.value >= 5) return;
            self.value += 1;
        }

        pub fn decrement(self: *@This()) void {
            if (self.value > 0) {
                self.value -= 1;
            }
        }
    };

    // Define commands
    const IncrementCommand = struct {
        pub const name = "increment";
        pub fn checkPrecondition(self: *@This(), model: *Model) bool {
            _ = self;
            _ = model;
            return true;
        }

        pub fn onModelOnly(self: *@This(), model: *Model) void {
            _ = self;
            model.value += 1;
        }

        pub fn onPair(self: *@This(), model: *Model, sut: *System) !bool {
            _ = self;
            sut.increment();

            model.value += 1;
            return model.value == sut.value;
        }
    };

    const DecrementCommand = struct {
        pub const name = "decrement";
        pub fn checkPrecondition(self: *@This(), model: *Model) bool {
            _ = self;
            return model.value > 0;
        }

        pub fn onModelOnly(self: *@This(), model: *Model) void {
            _ = self;
            model.value -= 1;
        }

        pub fn onPair(self: *@This(), model: *Model, sut: *System) !bool {
            _ = self;
            sut.decrement();

            model.value -= 1;
            return model.value == sut.value;
        }
    };

    var inc_cmd = IncrementCommand{};
    var dec_cmd = DecrementCommand{};
    // Create commands array
    const commands = [_]Command(Model, System){
        Command(Model, System).init(&inc_cmd),
        Command(Model, System).init(&dec_cmd),
    };

    // Create test configuration
    const config = StatefulConfig{ .verbose = false };

    // Initialize model and system
    var model = Model{};
    var sut = System{};

    // Create random source
    // var random_bytes: [1024]u8 = undefined;
    // @import("test_helpers").load_bytes(&random_bytes);
    var random_bytes = [_]u8{
        0x8B, 0xBE, 0x02, 0x2C, 0x87, 0x0A, 0xF6, 0x54, 0x4A, 0x59, 0x73, 0xA8, 0x12, 0xF7, 0x2B, 0x85,
        //
        0xAD, 0x95, 0x90, 0x8A, 0x21, 0xF1, 0xAC, 0x64, 0x42, 0x32, 0xA5, 0x0D, 0x10, 0x1F, 0xBA, 0xE7,
        //
        0x0F, 0xEE, 0xF9, 0x62, 0x62, 0x62, 0x62, 0x62, 0x62, 0x62, 0x62,
    };
    var prng = FinitePrng.init(&random_bytes);
    var random = prng.random();

    // Create command sequence
    var cmd_seq = try CommandList(Model, System).init(&commands, &random, 50, std.testing.allocator);
    defer cmd_seq.deinit(std.testing.allocator);

    // Run the test
    const rv = try assertStateful(Model, System, &cmd_seq, &model, &sut, config);
    try std.testing.expect(rv != null);
}
