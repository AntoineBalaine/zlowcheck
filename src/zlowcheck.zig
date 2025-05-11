//! ZlowCheck: A property-based testing library for Zig
//!
//! This library provides tools for property-based testing, including:
//! - Generators for creating random test values
//! - Properties for defining testable statements
//! - Assertion utilities for running property tests

const std = @import("std");
const testing = std.testing;

const generator = @import("generator.zig");
pub const Generator = generator.Generator;
pub const Value = generator.Value;
pub const ValueList = generator.ValueList;
pub const BytePosition = generator.BytePosition;
pub const gen = generator.gen;
pub const tuple = generator.tuple;
pub const oneOf = generator.oneOf;
pub const MappedGenerator = generator.MappedGenerator;
pub const FilteredGenerator = generator.FilteredGenerator;

const property_mod = @import("property.zig");
pub const Property = property_mod.Property;
pub const PropertyResult = property_mod.PropertyResult;
pub const property = property_mod.property;

const assert_mod = @import("assert.zig");
pub const assert = assert_mod.assert;
pub const AssertConfig = assert_mod.AssertConfig;

const state_mod = @import("state.zig");
pub const assertStateful = state_mod.assertStateful;
pub const CommandList = state_mod.CommandList;
pub const Command = state_mod.Command;
pub const StatefulConfig = state_mod.StatefulConfig;
pub const CommandPosition = state_mod.CommandPosition;

pub const FinitePrng = @import("finite_prng");

test {
    std.testing.refAllDecls(@This());

    _ = @import("generator_test.zig");
    _ = @import("property_test.zig");
    _ = @import("assert.zig");
    _ = @import("state.zig");
    _ = @import("fuzz_stateful.zig");
}
