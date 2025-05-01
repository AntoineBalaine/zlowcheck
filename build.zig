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
}
