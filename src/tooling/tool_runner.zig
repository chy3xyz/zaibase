const std = @import("std");
const app = @import("../app/root.zig");
const core = @import("../core/root.zig");
const effects = @import("../effects/root.zig");
const runtime = @import("../runtime/root.zig");
const script_host = @import("script_host.zig");
const tool_context = @import("tool_context.zig");
const tool_registry = @import("tool_registry.zig");

pub const ToolRunRequest = struct {
    tool_id: []const u8,
    request: app.RequestContext,
    params: []const core.validation.ValidationField,
};

pub const ToolExecutionResult = struct {
    tool_id: []u8,
    output_json: []u8,
    duration_ms: u64,

    pub fn deinit(self: *ToolExecutionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_id);
        allocator.free(self.output_json);
    }
};

pub const ToolRunner = struct {
    allocator: std.mem.Allocator,
    registry: *const tool_registry.ToolRegistry,
    effects: *effects.EffectsRuntime,
    script_host: ?*script_host.ScriptHost = null,
    logger: ?*core.logging.Logger = null,
    event_bus: ?runtime.EventBus = null,

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *const tool_registry.ToolRegistry,
        effects_runtime: *effects.EffectsRuntime,
        script_host_ref: ?*script_host.ScriptHost,
        logger: ?*core.logging.Logger,
        event_bus: ?runtime.EventBus,
    ) ToolRunner {
        return .{
            .allocator = allocator,
            .registry = registry,
            .effects = effects_runtime,
            .script_host = script_host_ref,
            .logger = logger,
            .event_bus = event_bus,
        };
    }

    pub fn run(self: *ToolRunner, request: ToolRunRequest) !ToolExecutionResult {
        const definition = self.registry.find(request.tool_id) orelse return error.ToolNotFound;

        if (!app.Authority.allows(request.request.authority, definition.authority)) {
            try self.emitEvent("tool.denied", request.tool_id, "TOOL_AUTHORITY_DENIED");
            return error.ToolAuthorityDenied;
        }

        return switch (definition.execution_kind) {
            .native_zig => try self.runNative(definition, request),
            .external_json_stdio => try self.runScript(definition, request),
        };
    }

    fn runNative(
        self: *ToolRunner,
        definition: tool_registry.ToolDefinition,
        request: ToolRunRequest,
    ) !ToolExecutionResult {
        const handler = definition.native_handler orelse return error.ToolHandlerMissing;
        var report = try validateRequest(self.allocator, request.params, definition.params);
        defer report.deinit();
        if (!report.isOk()) {
            try self.emitEvent("tool.validation_failed", request.tool_id, "TOOL_VALIDATION_FAILED");
            return error.ToolValidationFailed;
        }

        const started = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); });
        var fallback_sink = core.logging.sinks.Memory.init(self.allocator, 1);
        defer fallback_sink.deinit();
        var fallback_logger = core.logging.Logger.init(fallback_sink.asLogSink(), .silent);
        defer fallback_logger.deinit();
        const logger = if (self.logger) |provided| provided else &fallback_logger;

        var ctx = tool_context.ToolContext{
            .allocator = self.allocator,
            .request = request.request,
            .tool_id = definition.id,
            .logger = logger.child("tool").child(definition.id),
            .validated_params = request.params,
            .event_bus = self.event_bus orelse emptyEventBus().asEventBus(),
            .effects = self.effects,
        };

        try self.emitEvent("tool.started", request.tool_id, null);
        const output_json = handler(&ctx) catch |err| {
            try self.emitEvent("tool.failed", request.tool_id, @errorName(err));
            return error.ToolExecutionFailed;
        };

        try self.emitEvent("tool.completed", request.tool_id, null);
        return .{
            .tool_id = try self.allocator.dupe(u8, definition.id),
            .output_json = output_json,
            .duration_ms = @intCast((blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }) - started),
        };
    }

    fn runScript(
        self: *ToolRunner,
        definition: tool_registry.ToolDefinition,
        request: ToolRunRequest,
    ) !ToolExecutionResult {
        const host = self.script_host orelse return error.ScriptHostMissing;
        const spec = definition.script_spec orelse return error.ScriptSpecMissing;

        const started = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); });
        var fallback_sink = core.logging.sinks.Memory.init(self.allocator, 1);
        defer fallback_sink.deinit();
        var fallback_logger = core.logging.Logger.init(fallback_sink.asLogSink(), .silent);
        defer fallback_logger.deinit();
        const logger = if (self.logger) |provided| provided else &fallback_logger;

        var ctx = tool_context.ToolContext{
            .allocator = self.allocator,
            .request = request.request,
            .tool_id = definition.id,
            .logger = logger.child("tool").child(definition.id),
            .validated_params = request.params,
            .event_bus = self.event_bus orelse emptyEventBus().asEventBus(),
            .effects = self.effects,
        };

        try self.emitEvent("tool.started", request.tool_id, null);
        var script_result = host.run(&ctx, spec) catch |err| {
            try self.emitEvent("tool.failed", request.tool_id, @errorName(err));
            return error.ToolExecutionFailed;
        };
        defer script_result.deinit(self.allocator);

        if (!script_result.ok) {
            try self.emitEvent("tool.failed", request.tool_id, script_result.error_code orelse "SCRIPT_RESULT_FAILED");
            return error.ToolExecutionFailed;
        }

        try self.emitEvent("tool.completed", request.tool_id, null);
        return .{
            .tool_id = try self.allocator.dupe(u8, definition.id),
            .output_json = if (script_result.output_json) |value| try self.allocator.dupe(u8, value) else try self.allocator.dupe(u8, "null"),
            .duration_ms = @intCast((blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }) - started),
        };
    }

    fn emitEvent(self: *ToolRunner, topic: []const u8, tool_id: []const u8, error_code: ?[]const u8) !void {
        const bus = self.event_bus orelse return;
        const payload = if (error_code) |code|
            try std.fmt.allocPrint(self.allocator, "{{\"tool_id\":\"{s}\",\"error_code\":\"{s}\"}}", .{ tool_id, code })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"tool_id\":\"{s}\"}}", .{tool_id});
        defer self.allocator.free(payload);
        _ = try bus.publish(topic, payload);
    }
};

fn validateRequest(
    allocator: std.mem.Allocator,
    params: []const core.validation.ValidationField,
    schema: []const core.validation.FieldDefinition,
) !core.validation.ValidationReport {
    var validator = core.validation.Validator.init(allocator, schema, .{
        .mode = .request,
        .field_path_prefix = "params",
        .strict_unknown_fields = true,
    });
    return validator.validateObject(params);
}

fn emptyEventBus() *runtime.MemoryEventBus {
    const Holder = struct {
        var bus: runtime.MemoryEventBus = undefined;
        var initialized = false;
    };
    if (!Holder.initialized) {
        Holder.bus = runtime.MemoryEventBus.init(std.heap.page_allocator);
        Holder.initialized = true;
    }
    return &Holder.bus;
}

test "tool runner executes native tool successfully" {
    const Demo = struct {
        fn call(ctx: *const tool_context.ToolContext) ![]u8 {
            const value = ctx.param("value").?.value.string;
            return ctx.allocator.dupe(u8, value);
        }
    };

    var registry = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const params = [_]core.validation.FieldDefinition{
        .{ .key = "value", .required = true, .value_kind = .string },
    };
    try registry.register(.{
        .id = "demo.echo",
        .description = "echo tool",
        .params = params[0..],
        .native_handler = Demo.call,
    });

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var runner = ToolRunner.init(std.testing.allocator, &registry, &effects_runtime, null, null, null);
    const fields = [_]core.validation.ValidationField{
        .{ .key = "value", .value = .{ .string = "{\"ok\":true}" } },
    };

    var result = try runner.run(.{
        .tool_id = "demo.echo",
        .request = .{
            .request_id = "tool_req_01",
            .source = .@"test",
            .authority = .public,
        },
        .params = fields[0..],
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("demo.echo", result.tool_id);
    try std.testing.expectEqualStrings("{\"ok\":true}", result.output_json);
}

test "tool runner rejects invalid input" {
    const Demo = struct {
        fn call(_: *const tool_context.ToolContext) ![]u8 {
            return error.Unreachable;
        }
    };

    var registry = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const params = [_]core.validation.FieldDefinition{
        .{ .key = "value", .required = true, .value_kind = .string },
    };
    try registry.register(.{
        .id = "demo.validation",
        .description = "validation tool",
        .params = params[0..],
        .native_handler = Demo.call,
    });

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var event_bus = runtime.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();
    var runner = ToolRunner.init(std.testing.allocator, &registry, &effects_runtime, null, null, event_bus.asEventBus());

    try std.testing.expectError(error.ToolValidationFailed, runner.run(.{
        .tool_id = "demo.validation",
        .request = .{
            .request_id = "tool_req_02",
            .source = .@"test",
            .authority = .public,
        },
        .params = &.{},
    }));
}

test "tool runner enforces authority checks" {
    const Demo = struct {
        fn call(ctx: *const tool_context.ToolContext) ![]u8 {
            return ctx.allocator.dupe(u8, "{}");
        }
    };

    var registry = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "demo.admin",
        .description = "admin tool",
        .authority = .admin,
        .native_handler = Demo.call,
    });

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var runner = ToolRunner.init(std.testing.allocator, &registry, &effects_runtime, null, null, null);

    try std.testing.expectError(error.ToolAuthorityDenied, runner.run(.{
        .tool_id = "demo.admin",
        .request = .{
            .request_id = "tool_req_03",
            .source = .@"test",
            .authority = .public,
        },
        .params = &.{},
    }));
}

test "tool runner maps tool internal failure" {
    const Demo = struct {
        fn call(_: *const tool_context.ToolContext) ![]u8 {
            return error.AccessDenied;
        }
    };

    var registry = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "demo.fail",
        .description = "failing tool",
        .native_handler = Demo.call,
    });

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var runner = ToolRunner.init(std.testing.allocator, &registry, &effects_runtime, null, null, null);

    try std.testing.expectError(error.ToolExecutionFailed, runner.run(.{
        .tool_id = "demo.fail",
        .request = .{
            .request_id = "tool_req_04",
            .source = .@"test",
            .authority = .public,
        },
        .params = &.{},
    }));
}

test "tool runner executes script-backed tool successfully" {
    var registry = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "demo.script",
        .description = "script-backed tool",
        .execution_kind = .external_json_stdio,
        .script_spec = .{
            .program = "python3",
            .args = &.{ "-c", "import json,sys; req=json.load(sys.stdin); print(json.dumps({'ok': True, 'output_json': req['params_json']}))" },
            .timeout_ms = 1000,
        },
    });

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var host = script_host.ScriptHost.init(std.testing.allocator, effects_runtime.process_runner, null, null);
    var runner = ToolRunner.init(std.testing.allocator, &registry, &effects_runtime, &host, null, null);
    const fields = [_]core.validation.ValidationField{
        .{ .key = "path", .value = .{ .string = "README.md" } },
    };

    var result = try runner.run(.{
        .tool_id = "demo.script",
        .request = .{
            .request_id = "tool_req_script_01",
            .source = .@"test",
            .authority = .public,
        },
        .params = fields[0..],
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("demo.script", result.tool_id);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", result.output_json);
}

test "tool runner maps script-backed failures" {
    var registry = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "demo.script.fail",
        .description = "failing script-backed tool",
        .execution_kind = .external_json_stdio,
        .script_spec = .{
            .program = "python3",
            .args = &.{ "-c", "print('not-json')" },
            .timeout_ms = 1000,
        },
    });

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var host = script_host.ScriptHost.init(std.testing.allocator, effects_runtime.process_runner, null, null);
    var runner = ToolRunner.init(std.testing.allocator, &registry, &effects_runtime, &host, null, null);

    try std.testing.expectError(error.ToolExecutionFailed, runner.run(.{
        .tool_id = "demo.script.fail",
        .request = .{
            .request_id = "tool_req_script_02",
            .source = .@"test",
            .authority = .public,
        },
        .params = &.{},
    }));
}

test "tool runner emits events and logs for native tool execution" {
    const Demo = struct {
        fn call(ctx: *const tool_context.ToolContext) ![]u8 {
            ctx.logger.info("tool executing", &.{@import("../root.zig").LogField.string("mode", "test")});
            return ctx.allocator.dupe(u8, "{\"logged\":true}");
        }
    };

    var app_context = try runtime.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var registry = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "demo.observed",
        .description = "observed tool",
        .native_handler = Demo.call,
    });

    var runner = ToolRunner.init(
        std.testing.allocator,
        &registry,
        &effects_runtime,
        null,
        app_context.logger,
        app_context.eventBus(),
    );

    var result = try runner.run(.{
        .tool_id = "demo.observed",
        .request = .{
            .request_id = "tool_req_obs_01",
            .source = .@"test",
            .authority = .public,
        },
        .params = &.{},
    });
    defer result.deinit(std.testing.allocator);

    const events = try app_context.event_bus.snapshot(std.testing.allocator);
    defer {
        for (events) |*event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }
    try std.testing.expect(events.len >= 2);
    try std.testing.expectEqualStrings("tool.started", events[0].topic);
    try std.testing.expectEqualStrings("tool.completed", events[1].topic);

    const logs = app_context.memory_sink.snapshot();
    var saw_tool_log = false;
    for (logs) |entry| {
        if (std.mem.eql(u8, entry.message, "tool executing")) saw_tool_log = true;
    }
    try std.testing.expect(saw_tool_log);
}


