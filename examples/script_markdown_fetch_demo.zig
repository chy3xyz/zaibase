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
    try tool_registry.register(zaibase.ScriptMarkdownFetchTool.definition());

    var host = zaibase.tooling.script_host.ScriptHost.init(
        std.heap.page_allocator,
        effects_runtime.process_runner,
        app_context.logger,
        app_context.eventBus(),
    );
    var runner = zaibase.ToolRunner.init(
        std.heap.page_allocator,
        &tool_registry,
        &effects_runtime,
        &host,
        app_context.logger,
        app_context.eventBus(),
    );

    const fields = [_]zaibase.ValidationField{
        .{ .key = "url", .value = .{ .string = "https://example.com/post" } },
    };

    var result = try runner.run(.{
        .tool_id = zaibase.ScriptMarkdownFetchTool.tool_id,
        .request = .{
            .request_id = "script_markdown_demo_01",
            .source = .cli,
            .authority = .public,
        },
        .params = fields[0..],
    });
    defer result.deinit(std.heap.page_allocator);

    try std.Io.stdout().writeAll(result.output_json);
    try std.Io.stdout().writeAll("\n");
}


