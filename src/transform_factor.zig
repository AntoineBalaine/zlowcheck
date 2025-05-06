
fn measureTransformFactorSlope() !void {
    // Create a reference byte stream
    var bytes = [_]u8{...}; // Some representative bytes

    // For multiple positions in the byte stream
    for (0..bytes.len) |pos| {
        // Skip bytes used for structural decisions
        if (isDecisionByte(pos)) continue;

        std.debug.print("Testing byte position: {}\n", .{pos});

        // Test with increasing mutation magnitudes
        var results = std.ArrayList(struct { input_delta: i32, output_delta: f64 }).init(allocator);
        defer results.deinit();

        for ([_]i8{-128, -64, -32, -16, -8, -4, -2, -1, 1, 2, 4, 8, 16, 32, 64, 127}) |delta| {
            // Create a mutated byte stream
            var mutated = try allocator.dupe(u8, &bytes);
            defer allocator.free(mutated);

            // Apply mutation (with bounds checking)
            const old_value = mutated[pos];
            mutated[pos] = @intCast(u8, @max(0, @min(255, @as(i16, old_value) + delta)));

            // Generate values with reference and mutated streams
            var ref_prng = FinitePrng.init(&bytes);
            var mut_prng = FinitePrng.init(mutated);

            // Measure output difference
            const output_delta = measureOutputDelta(&ref_prng, &mut_prng);

            try results.append(.{ .input_delta = delta, .output_delta = output_delta });
        }

        // Calculate slope using linear regression
        const slope = calculateSlope(results.items);

        // Categorize the transform behavior
        const behavior = if (slope < 0.1) "Minimal"
            else if (slope < 1.0) "Sub-linear"
            else if (slope < 2.0) "Linear"
            else if (slope < 10.0) "Super-linear"
            else "Exponential";

        std.debug.print("Position {}: Slope = {d:.4} ({s})\n",
            .{pos, slope, behavior});
    }
}

fn calculateSlope(data: []const struct { input_delta: i32, output_delta: f64 }) f64 {
    // Simple linear regression to find slope
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var sum_xy: f64 = 0;
    var sum_xx: f64 = 0;

    for (data) |point| {
        const x = @intToFloat(f64, @abs(point.input_delta));
        const y = point.output_delta;

        sum_x += x;
        sum_y += y;
        sum_xy += x * y;
        sum_xx += x * x;
    }

    const n = @intToFloat(f64, data.len);
    return (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x);
}

fn measureOutputDelta(ref_prng: *FinitePrng, mut_prng: *FinitePrng) f64 {
    // Generate a sequence of values and measure differences
    var total_delta: f64 = 0;

    // For numeric values
    for (0..100) |_| {
        const ref_val = ref_prng.random.uintAtMost(u32, 1000);
        const mut_val = mut_prng.random.uintAtMost(u32, 1000);

        // Normalized difference
        total_delta += @intToFloat(f64, @max(ref_val, mut_val) - @min(ref_val, mut_val)) / 1000.0;
    }

    return total_delta / 100.0;
}


