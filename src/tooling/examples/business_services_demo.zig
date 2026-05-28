const std = @import("std");
const zaibase = @import("../../root.zig");

pub const ExampleServices = struct {
    framework_context: *zaibase.AppContext,
    tooling_runtime: *zaibase.ToolingRuntime,
    project_root: []const u8,

    pub fn fromCommandContext(ctx: *const zaibase.CommandContext) *ExampleServices {
        return @ptrCast(@alignCast(ctx.user_data.?));
    }
};

const DescribeCommand = struct {
    fn call(ctx: *const zaibase.CommandContext) anyerror![]u8 {
        const services = ExampleServices.fromCommandContext(ctx);
        return std.fmt.allocPrint(ctx.allocator, "{{\"project_root\":{f},\"tool_count\":{d}}}", .{
            std.json.fmt(services.project_root, .{}),
            services.tooling_runtime.registry.count(),
        });
    }
};

pub fn registerCommands(registry: *zaibase.CommandRegistry, services: *ExampleServices) !void {
    try registry.register(.{
        .id = "example.services.describe",
        .method = "example.services.describe",
        .description = "Describe the example service bundle",
        .handler = DescribeCommand.call,
        .user_data = services,
    });
}

test "business services demo works through command context user_data" {
    var app_context = try zaibase.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var effects_runtime = zaibase.EffectsRuntime.init(.{});
    var registry = zaibase.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(zaibase.defineTool(zaibase.RepoHealthCheckTool));

    const tooling_runtime = try zaibase.ToolingRuntime.init(.{
        .allocator = std.testing.allocator,
        .app_context = &app_context,
        .effects = &effects_runtime,
        .registry = &registry,
    });
    defer tooling_runtime.deinit();

    var services = ExampleServices{
        .framework_context = &app_context,
        .tooling_runtime = tooling_runtime,
        .project_root = "E:/demo/project",
    };

    try registerCommands(app_context.command_registry, &services);

    var dispatcher = app_context.makeDispatcher();
    var envelope = try dispatcher.dispatch(.{
        .request_id = "business_services_demo_01",
        .method = "example.services.describe",
        .params = &.{},
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
            try std.testing.expect(std.mem.indexOf(u8, json, "\"project_root\":\"E:/demo/project\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_count\":1") != null);
        },
        else => return error.UnexpectedEnvelopeVariant,
    }
}


