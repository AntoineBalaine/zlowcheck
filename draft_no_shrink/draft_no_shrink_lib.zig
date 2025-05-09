//! ZLowCheck: A property-based testing library for Zig
//!
//! This library provides tools for property-based testing, including:
//! - Generators for creating random test values
//! - Properties for defining testable statements
//! - Assertion utilities for running property tests

const std = @import("std");
const testing = std.testing;

const generator = @import("generator.zig");
pub const Generator = generator.Generator;
pub const gen = generator.gen;
pub const tuple = generator.tuple;
pub const oneOf = generator.oneOf;
pub const MappedGenerator = generator.MappedGenerator;
pub const FilteredGenerator = generator.FilteredGenerator;

const property_mod = @import("property.zig");
pub const Property = property_mod.Property;
pub const PropertyFailure = property_mod.PropertyFailure;
pub const property = property_mod.property;

const assert_mod = @import("assert.zig");
pub const assert = assert_mod.assert;
pub const AssertConfig = assert_mod.AssertConfig;

// pub const FinitePrng = @import("finite_prng");

test {
    std.testing.refAllDecls(@This());

    _ = @import("generator_test.zig");
    _ = @import("property_test.zig");
    _ = @import("assert.zig");
}
