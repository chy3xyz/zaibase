const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Library module ──────────────────────────────────────────────
    const lib_mod = b.addModule("framework", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Executable ──────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "framework",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("framework", lib_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the framework executable");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ───────────────────────────────────────────────────────
    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    root_tests.root_module.addImport("framework", lib_mod);
    const run_root_tests = b.addRunArtifact(root_tests);

    const test_step = b.step("test", "Run framework unit tests");
    test_step.dependOn(&run_root_tests.step);

    // ── Format check ────────────────────────────────────────────────
    const fmt_step = b.step("fmt", "Check source formatting");
    const fmt = b.addFmt(.{ .paths = &.{"src"}, .check = true });
    fmt_step.dependOn(&fmt.step);
}
