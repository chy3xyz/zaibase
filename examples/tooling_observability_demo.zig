const std = @import("std");
const zaibase = @import("zaibase");

pub fn main() !void {
    var app_context = try zaibase.AppContext.init(std.heap.page_allocator, .{
        .console_log_enabled = true,
    });
    defer app_context.deinit();

    var effects_runtime = zaibase.EffectsRuntime.init(.{});
    var registry = zaibase.ToolRegistry.init(std.heap.page_allocator);
    defer registry.deinit();
    try registry.register(zaibase.defineTool(zaibase.RepoHealthCheckTool));

    var runner = zaibase.ToolRunner.init(
        std.heap.page_allocator,
        &registry,
        &effects_runtime,
        null,
        app_context.logger,
        app_context.eventBus(),
    );

    const fields = [_]zaibase.ValidationField{
        .{ .key = "path", .value = .{ .string = "." } },
    };
    var result = try runner.run(.{
        .tool_id = zaibase.RepoHealthCheckTool.tool_id,
        .request = .{
            .request_id = "tooling_obs_demo",
            .source = .cli,
            .authority = .public,
        },
        .params = fields[0..],
    });
    defer result.deinit(std.heap.page_allocator);
}


