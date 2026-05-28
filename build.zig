const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Library module ──────────────────────────────────────────────
    const lib_mod = b.addModule("zaibase", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Executable ──────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "zaibase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zaibase", lib_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zaibase executable");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ───────────────────────────────────────────────────────
    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    root_tests.root_module.addImport("zaibase", lib_mod);
    const run_root_tests = b.addRunArtifact(root_tests);

    const test_step = b.step("test", "Run zaibase unit tests");
    test_step.dependOn(&run_root_tests.step);

    // ── Example executables ────────────────────────────────────────
    inline for (.{
        .{ "logging-basic", "examples/logging_basic_demo.zig" },
        .{ "logging-multi-sink", "examples/logging_multi_sink_demo.zig" },
        .{ "logging-method-trace", "examples/logging_method_trace_demo.zig" },
        .{ "logging-summary-trace", "examples/logging_summary_trace_demo.zig" },
    }) |ex| {
        const ex_name = ex[0];
        const ex_path = ex[1];
        const exe_obj = b.addExecutable(.{
            .name = ex_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe_obj.root_module.addImport("zaibase", lib_mod);
        b.installArtifact(exe_obj);
    }

    // ── Format check ────────────────────────────────────────────────
    const fmt_step = b.step("fmt", "Check source formatting");
    const fmt = b.addFmt(.{ .paths = &.{"src"}, .check = true });
    fmt_step.dependOn(&fmt.step);
}
