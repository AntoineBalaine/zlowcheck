const std = @import("std");
const FinitePrng = @import("finite_prng");
const state = @import("state.zig");

// Define a simple model for testing
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

        // Intentional bug for fuzzer to find:
        // After 5 increments, model and system will diverge
        if (model.value <= 5) {
            model.value += 1;
        } else {
            model.value += 2; // BUG: model increments by 2 after value > 5
        }

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

pub const StatufelFuzz = error{
    SkipZigTest,
};

// This function will be called by the fuzzer with different inputs
fn runStatefulTest(_: void, input: []const u8) !void {

    // Create a copy of the data that we can use
    const fuzz_data = std.testing.allocator.alloc(u8, input.len) catch return error.SkipZigTest;
    defer std.testing.allocator.free(fuzz_data);
    @memcpy(fuzz_data, input);

    // Initialize PRNG with the fuzzer data
    var prng = FinitePrng.init(fuzz_data);
    var random = prng.random();

    // Create commands
    var inc_cmd = IncrementCommand{};
    var dec_cmd = DecrementCommand{};
    const commands = [_]state.Command(Model, System){
        state.Command(Model, System).init(&inc_cmd),
        state.Command(Model, System).init(&dec_cmd),
    };

    // Initialize model and system
    var model = Model{};
    var sut = System{};

    // Create command sequence
    var cmd_seq = state.CommandList(Model, System).init(&commands, &random, 50, std.testing.allocator) catch return error.SkipZigTest;
    defer cmd_seq.deinit(std.testing.allocator);

    // Run the stateful test
    const config = state.StatefulConfig{ .verbose = true };
    const rv = state.assertStateful(Model, System, &cmd_seq, &model, &sut, config) catch |err| {
        // We expect some errors due to OutOfEntropy, which is fine
        if (err == FinitePrng.FinitePrngErr.OutOfEntropy) return;
        return err;
    };
    try std.testing.expect(rv == null);
}

// Add a fuzz test that will be picked up by the build system
test "fuzz stateful testing" {
    try std.testing.fuzz({}, runStatefulTest, .{});
}
