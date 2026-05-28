const std = @import("std");
const zaibase = @import("zaibase");

pub fn main() !void {
    var app_context = try zaibase.AppContext.init(std.heap.page_allocator, .{
        .console_log_enabled = true,
    });
    defer app_context.deinit();

    var effects_runtime = zaibase.EffectsRuntime.init(.{});
    var tool_registry = zaibase.ToolRegistry.init(std.heap.page_allocator);
    defer tool_registry.deinit();
    try tool_registry.register(zaibase.defineTool(zaibase.RepoHealthCheckTool));

    const tooling_runtime = try zaibase.ToolingRuntime.init(.{
        .allocator = std.heap.page_allocator,
        .app_context = &app_context,
        .effects = &effects_runtime,
        .registry = &tool_registry,
    });
    defer tooling_runtime.deinit();

    var services = zaibase.tooling.examples.business_services_demo.ExampleServices{
        .framework_context = &app_context,
        .tooling_runtime = tooling_runtime,
        .project_root = ".",
    };
    try zaibase.tooling.examples.business_services_demo.registerCommands(app_context.command_registry, &services);

    var dispatcher = app_context.makeDispatcher();
    var envelope = try dispatcher.dispatch(.{
        .request_id = "business_services_demo_main",
        .method = "example.services.describe",
        .params = &.{},
        .source = .cli,
        .authority = .public,
    }, false);
    defer if (envelope.result) |*result| {
        switch (result.*) {
            .success_json => |json| std.heap.page_allocator.free(json),
            else => {},
        }
    };

    if (envelope.result) |result| switch (result) {
        .success_json => |json| {
            try std.Io.stdout().writeAll(json);
            try std.Io.stdout().writeAll("\n");
        },
        else => {},
    };
}


