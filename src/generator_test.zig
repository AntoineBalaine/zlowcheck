const std = @import("std");
const Generator = @import("generator.zig").Generator;
const gen = @import("generator.zig").gen;

test "int generator produces values within range" {
    // Create a generator for integers between 10 and 20
    const intGenerator = gen(i32, .{ .min = 10, .max = 20 });
    
    var prng = std.rand.DefaultPrng.init(42); // Fixed seed for reproducibility
    var random = prng.random();
    
    // Generate 100 values and check they're all within range
    for (0..100) |_| {
        const value = try intGenerator.generate(random, 10, std.testing.allocator);
        try std.testing.expect(value >= 10 and value <= 20);
    }
}

test "int generator produces boundary values" {
    // Create a generator for integers
    const intGenerator = gen(i32, .{ .min = -100, .max = 100 });
    
    var prng = std.rand.DefaultPrng.init(42);
    var random = prng.random();
    
    // Set to track boundary values we've seen
    var seen_boundaries = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer seen_boundaries.deinit();
    
    // Expected boundary values
    try seen_boundaries.put(-100, {}); // min
    try seen_boundaries.put(-99, {});  // min+1
    try seen_boundaries.put(-1, {});
    try seen_boundaries.put(0, {});
    try seen_boundaries.put(1, {});
    try seen_boundaries.put(99, {});   // max-1
    try seen_boundaries.put(100, {});  // max
    
    // Generate many values to increase chance of hitting boundaries
    var found_count: usize = 0;
    for (0..1000) |_| {
        const value = try intGenerator.generate(random, 10, std.testing.allocator);
        
        // If it's a boundary value, remove it from our map
        if (seen_boundaries.contains(value)) {
            _ = seen_boundaries.remove(value);
            found_count += 1;
            
            // If we've found all boundaries, we can stop
            if (seen_boundaries.count() == 0) break;
        }
    }
    
    // We should have found at least some boundary values
    try std.testing.expect(found_count > 0);
    std.debug.print("Found {d} of 7 boundary values\n", .{found_count});
}

test "float generator produces values within range" {
    // Create a generator for floats between -10.0 and 10.0
    const floatGenerator = gen(f64, .{ .min = -10.0, .max = 10.0 });
    
    var prng = std.rand.DefaultPrng.init(42);
    var random = prng.random();
    
    // Generate 100 values and check they're all within range
    for (0..100) |_| {
        const value = try floatGenerator.generate(random, 10, std.testing.allocator);
        
        // Skip NaN and infinity checks
        if (std.math.isNan(value) or std.math.isInf(value)) continue;
        
        try std.testing.expect(value >= -10.0 and value <= 10.0);
    }
}

test "float generator produces special values" {
    const floatGenerator = gen(f64, .{});
    
    var prng = std.rand.DefaultPrng.init(42);
    var random = prng.random();
    
    // Track special values we've seen
    var seen_inf_pos = false;
    var seen_inf_neg = false;
    var seen_nan = false;
    var seen_zero = false;
    var seen_one = false;
    var seen_neg_one = false;
    
    // Generate many values to increase chance of hitting special values
    for (0..1000) |_| {
        const value = try floatGenerator.generate(random, 10, std.testing.allocator);
        
        if (std.math.isPositiveInf(value)) seen_inf_pos = true;
        if (std.math.isNegativeInf(value)) seen_inf_neg = true;
        if (std.math.isNan(value)) seen_nan = true;
        if (value == 0.0) seen_zero = true;
        if (value == 1.0) seen_one = true;
        if (value == -1.0) seen_neg_one = true;
        
        // If we've seen all special values, we can stop
        if (seen_inf_pos and seen_inf_neg and seen_nan and 
            seen_zero and seen_one and seen_neg_one) break;
    }
    
    // We should have found at least some special values
    const found_count = @intFromBool(seen_inf_pos) + 
                        @intFromBool(seen_inf_neg) + 
                        @intFromBool(seen_nan) + 
                        @intFromBool(seen_zero) + 
                        @intFromBool(seen_one) + 
                        @intFromBool(seen_neg_one);
                        
    try std.testing.expect(found_count > 0);
    std.debug.print("Found {d} of 6 special float values\n", .{found_count});
}

test "bool generator produces both true and false" {
    const boolGenerator = gen(bool, .{});
    
    var prng = std.rand.DefaultPrng.init(42);
    var random = prng.random();
    
    var seen_true = false;
    var seen_false = false;
    
    // Generate values until we've seen both true and false
    for (0..100) |_| {
        const value = try boolGenerator.generate(random, 10, std.testing.allocator);
        
        if (value) seen_true = true else seen_false = true;
        
        if (seen_true and seen_false) break;
    }
    
    // We should have seen both true and false
    try std.testing.expect(seen_true and seen_false);
}

test "map transforms values correctly" {
    // Create a generator for integers
    const intGenerator = gen(i32, .{ .min = 1, .max = 10 });
    
    // Map to double the values
    const doubledGenerator = intGenerator.map(i32, struct {
        fn double(n: i32) i32 {
            return n * 2;
        }
    }.double);
    
    var prng = std.rand.DefaultPrng.init(42);
    var random = prng.random();
    
    // Generate values and check they're all doubled
    for (0..100) |_| {
        const value = try doubledGenerator.generate(random, 10, std.testing.allocator);
        try std.testing.expect(value >= 2 and value <= 20 and value % 2 == 0);
    }
}

test "filter constrains values correctly" {
    // Create a generator for integers
    const intGenerator = gen(i32, .{ .min = -10, .max = 10 });
    
    // Filter to only positive values
    const positiveGenerator = intGenerator.filter(struct {
        fn isPositive(n: i32) bool {
            return n > 0;
        }
    }.isPositive);
    
    var prng = std.rand.DefaultPrng.init(42);
    var random = prng.random();
    
    // Generate values and check they're all positive
    for (0..100) |_| {
        const value = try positiveGenerator.generate(random, 10, std.testing.allocator);
        try std.testing.expect(value > 0 and value <= 10);
    }
}
