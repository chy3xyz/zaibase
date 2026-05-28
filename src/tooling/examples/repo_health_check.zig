const std = @import("std");
const zaibase = @import("../../root.zig");

pub const RepoHealthCheckTool = struct {
    pub const tool_id = "repo.health_check";
    pub const tool_description = "Inspect a repository-like directory and report basic health signals";
    pub const tool_params = &[_]zaibase.FieldDefinition{
        .{
            .key = "path",
            .required = true,
            .value_kind = .string,
            .rules = &.{.non_empty_string},
        },
    };

    pub fn execute(ctx: *const zaibase.ToolContext) ![]u8 {
        const path = ctx.param("path").?.value.string;
        const entries = try ctx.effects.file_system.listDir(ctx.allocator, path);
        defer {
            for (entries) |*entry| entry.deinit(ctx.allocator);
            ctx.allocator.free(entries);
        }

        const has_git = hasEntry(entries, ".git");
        const has_readme = hasEntry(entries, "README.md") or hasEntry(entries, "README");
        const has_build_zig = hasEntry(entries, "build.zig");
        const has_src_dir = hasDirectory(entries, "src");
        const status = if (has_git and has_build_zig and has_src_dir) "healthy" else "partial";

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(ctx.allocator);

        try out.append(ctx.allocator, '{');
        try out.print(ctx.allocator, "\"path\":{f}", .{std.json.fmt(path, .{})});
        try out.print(ctx.allocator, ",\"entry_count\":{d}", .{entries.len});
        try out.appendSlice(ctx.allocator, if (has_git) ",\"is_git_repo\":true" else ",\"is_git_repo\":false");
        try out.appendSlice(ctx.allocator, if (has_readme) ",\"has_readme\":true" else ",\"has_readme\":false");
        try out.appendSlice(ctx.allocator, if (has_build_zig) ",\"has_build_zig\":true" else ",\"has_build_zig\":false");
        try out.appendSlice(ctx.allocator, if (has_src_dir) ",\"has_src_dir\":true" else ",\"has_src_dir\":false");
        try out.print(ctx.allocator, ",\"status\":{f}", .{std.json.fmt(status, .{})});
        try out.append(ctx.allocator, '}');
        return try ctx.allocator.dupe(u8, out.items);
    }
};

fn hasEntry(entries: []const zaibase.FsEntry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn hasDirectory(entries: []const zaibase.FsEntry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name) and entry.kind == .directory) return true;
    }
    return false;
}

test "repo health check supports direct tool execution" {
    const definition = zaibase.defineTool(RepoHealthCheckTool);

    var sink = zaibase.MemorySink.init(std.testing.allocator, 1);
    defer sink.deinit();
    var logger = zaibase.Logger.init(sink.asLogSink(), .silent);
    defer logger.deinit();

    var bus = zaibase.MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();
    var effects_runtime = zaibase.EffectsRuntime.init(.{});

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    const git_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, ".git" });
    defer std.testing.allocator.free(git_path);
    try effects_runtime.file_system.makePath(git_path);

    const src_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "src" });
    defer std.testing.allocator.free(src_path);
    try effects_runtime.file_system.makePath(src_path);

    const readme_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "README.md" });
    defer std.testing.allocator.free(readme_path);
    try effects_runtime.file_system.writeFile(readme_path, "demo");

    const build_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "build.zig" });
    defer std.testing.allocator.free(build_path);
    try effects_runtime.file_system.writeFile(build_path, "pub fn build() void {}");

    const params = [_]zaibase.ValidationField{
        .{ .key = "path", .value = .{ .string = root_path } },
    };
    const ctx = zaibase.ToolContext{
        .allocator = std.testing.allocator,
        .request = .{
            .request_id = "repo_health_direct_01",
            .source = .@"test",
            .authority = .public,
        },
        .tool_id = definition.id,
        .logger = logger.child("tool"),
        .validated_params = params[0..],
        .event_bus = bus.asEventBus(),
        .effects = &effects_runtime,
    };

    const output = try definition.native_handler.?(&ctx);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\":\"healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"has_build_zig\":true") != null);
}

test "repo health check supports command surface execution" {
    var app_context = try zaibase.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var effects_runtime = zaibase.EffectsRuntime.init(.{});
    var registry = zaibase.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(zaibase.defineTool(RepoHealthCheckTool));

    var runner = zaibase.ToolRunner.init(
        std.testing.allocator,
        &registry,
        &effects_runtime,
        null,
        app_context.logger,
        app_context.eventBus(),
    );
    var surface = zaibase.CommandSurface.init(
        std.testing.allocator,
        &runner,
        &effects_runtime,
        app_context.eventBus(),
    );
    try surface.registerAll(app_context.command_registry, &registry);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    const src_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "src" });
    defer std.testing.allocator.free(src_path);
    try effects_runtime.file_system.makePath(src_path);

    const build_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "build.zig" });
    defer std.testing.allocator.free(build_path);
    try effects_runtime.file_system.writeFile(build_path, "pub fn build() void {}");

    const fields = [_]zaibase.ValidationField{
        .{ .key = "path", .value = .{ .string = root_path } },
    };

    var dispatcher = app_context.makeDispatcher();
    var envelope = try dispatcher.dispatch(.{
        .request_id = "repo_health_cmd_01",
        .method = RepoHealthCheckTool.tool_id,
        .params = fields[0..],
        .source = .@"test",
        .authority = .public,
    }, false);
    defer if (envelope.result) |*result| {
        switch (result.*) {
            .success_json => |json| std.testing.allocator.free(json),
            else => {},
        }
    };

    try std.testing.expect(envelope.ok);
    try std.testing.expect(envelope.result != null);
    switch (envelope.result.?) {
        .success_json => |json| {
            try std.testing.expect(std.mem.indexOf(u8, json, "\"has_src_dir\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"partial\"") != null);
        },
        else => return error.UnexpectedEnvelopeVariant,
    }
}


