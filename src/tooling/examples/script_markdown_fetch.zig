const std = @import("std");
const zaibase = @import("../../root.zig");

pub const ScriptMarkdownFetchTool = struct {
    pub const tool_id = "script.markdown_fetch";
    pub const tool_description = "Fetch a URL through an external script and return markdown-shaped JSON";
    pub const script_path = "examples/scripts/script_markdown_fetch.py";
    pub const script_args = &[_][]const u8{script_path};
    pub const tool_params = &[_]zaibase.FieldDefinition{
        .{
            .key = "url",
            .required = true,
            .value_kind = .string,
            .rules = &.{.non_empty_string},
        },
    };

    pub fn definition() zaibase.ToolDefinition {
        return .{
            .id = tool_id,
            .description = tool_description,
            .params = tool_params,
            .execution_kind = .external_json_stdio,
            .script_spec = .{
                .program = "python3",
                .args = script_args,
                .timeout_ms = 1500,
            },
        };
    }
};

test "script markdown fetch supports direct tool execution" {
    var app_context = try zaibase.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var effects_runtime = zaibase.EffectsRuntime.init(.{});
    var registry = zaibase.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(ScriptMarkdownFetchTool.definition());

    var host = zaibase.tooling.script_host.ScriptHost.init(
        std.testing.allocator,
        effects_runtime.process_runner,
        app_context.logger,
        app_context.eventBus(),
    );
    var runner = zaibase.ToolRunner.init(
        std.testing.allocator,
        &registry,
        &effects_runtime,
        &host,
        app_context.logger,
        app_context.eventBus(),
    );

    const fields = [_]zaibase.ValidationField{
        .{ .key = "url", .value = .{ .string = "https://example.com/post" } },
    };
    var result = try runner.run(.{
        .tool_id = ScriptMarkdownFetchTool.tool_id,
        .request = .{
            .request_id = "script_markdown_direct_01",
            .source = .@"test",
            .authority = .public,
        },
        .params = fields[0..],
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output_json, "\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output_json, "https://example.com/post") != null);
}

test "script markdown fetch supports command surface execution" {
    var app_context = try zaibase.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var effects_runtime = zaibase.EffectsRuntime.init(.{});
    var registry = zaibase.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(ScriptMarkdownFetchTool.definition());

    var host = zaibase.tooling.script_host.ScriptHost.init(
        std.testing.allocator,
        effects_runtime.process_runner,
        app_context.logger,
        app_context.eventBus(),
    );
    var runner = zaibase.ToolRunner.init(
        std.testing.allocator,
        &registry,
        &effects_runtime,
        &host,
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

    const fields = [_]zaibase.ValidationField{
        .{ .key = "url", .value = .{ .string = "https://example.com/doc" } },
    };
    var dispatcher = app_context.makeDispatcher();
    var envelope = try dispatcher.dispatch(.{
        .request_id = "script_markdown_cmd_01",
        .method = ScriptMarkdownFetchTool.tool_id,
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
            const Parsed = struct {
                source: []const u8,
                url: []const u8,
                markdown: []const u8,
            };
            const parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, json, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("script-markdown-fetch", parsed.value.source);
            try std.testing.expectEqualStrings("https://example.com/doc", parsed.value.url);
            try std.testing.expect(std.mem.indexOf(u8, parsed.value.markdown, "https://example.com/doc") != null);
        },
        else => return error.UnexpectedEnvelopeVariant,
    }
}


