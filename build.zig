const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const pbt_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const prng_mod = b.createModule(.{
        .root_source_file = b.path("src/finite_prng.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the test_helpers module
    const test_helpers_mod = b.createModule(.{
        .root_source_file = b.path("src/test_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies for the main modules
    pbt_mod.addImport("finite_prng", prng_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const pbt_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zlowcheck",
        .root_module = pbt_mod,
    });

    const prng_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "FinitePrng",
        .root_module = prng_mod,
    });

    b.installArtifact(pbt_lib);
    b.installArtifact(prng_lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zlowcheck", pbt_mod);
    exe_mod.addImport("finite_prng", prng_mod);

    const exe = b.addExecutable(.{
        .name = "zlowcheck",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Set up tests with the test_helpers module
    const pbt_unit_tests = b.addTest(.{
        .root_module = pbt_mod,
    });
    // Add test_helpers to the test build only
    pbt_unit_tests.root_module.addImport("test_helpers", test_helpers_mod);

    const prng_unit_tests = b.addTest(.{
        .root_module = prng_mod,
    });
    // Add finite_prng to itself for testing
    prng_unit_tests.root_module.addImport("finite_prng", prng_mod);
    // Add test_helpers to the test build only
    prng_unit_tests.root_module.addImport("test_helpers", test_helpers_mod);

    const run_lib_unit_tests = b.addRunArtifact(pbt_unit_tests);
    const run_prng_unit_tests = b.addRunArtifact(prng_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_prng_unit_tests.step);
    docs_gen(
        b,
        .{ .target = target, .optimize = optimize },
    );
    draft_no_module(
        b,
        .{ .prng_mod = prng_mod, .test_helpers_mod = test_helpers_mod },
        .{ .target = target, .optimize = optimize },
    );
}

fn docs_gen(b: *std.Build, build_config: anytype) void {
    const docs_obj = b.addObject(.{
        .name = "zlowcheck_docs",
        .root_source_file = b.path("src/root.zig"),
        .target = build_config.target,
        .optimize = build_config.optimize,
    });

    const install_docs = b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs",
        .source_dir = docs_obj.getEmittedDocs(),
    });

    const docs_step = b.step("docs", "Generate library documentation");
    docs_step.dependOn(&install_docs.step);
}

pub fn draft_no_module(b: *std.Build, modules: anytype, build_config: anytype) void {
    const draft_step = b.step("test-draft", "Run tests for draft_no_shrink module");

    // Create a single module for the draft library
    const draft_lib_mod = b.createModule(.{
        .root_source_file = b.path("draft_no_shrink/draft_no_shrink_lib.zig"),
        .target = build_config.target,
        .optimize = build_config.optimize,
    });

    // Add dependencies to the draft library module
    draft_lib_mod.addImport("finite_prng", modules.prng_mod);
    draft_lib_mod.addImport("test_helpers", modules.test_helpers_mod);

    // Create a single test for the draft library
    const draft_tests = b.addTest(.{
        .root_module = draft_lib_mod,
    });

    // Create the run artifact and connect it to the step
    const run_draft_tests = b.addRunArtifact(draft_tests);
    draft_step.dependOn(&run_draft_tests.step);
}
