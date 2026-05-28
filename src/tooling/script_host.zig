const std = @import("std");
const core = @import("../core/root.zig");
const effects = @import("../effects/root.zig");
const runtime = @import("../runtime/root.zig");
const tool_context = @import("tool_context.zig");
const script_contract = @import("script_contract.zig");

pub const ScriptHost = struct {
    allocator: std.mem.Allocator,
    process_runner: effects.ProcessRunner,
    logger: ?*core.logging.Logger = null,
    event_bus: ?runtime.EventBus = null,

    pub fn init(
        allocator: std.mem.Allocator,
        process_runner: effects.ProcessRunner,
        logger: ?*core.logging.Logger,
        event_bus: ?runtime.EventBus,
    ) ScriptHost {
        return .{
            .allocator = allocator,
            .process_runner = process_runner,
            .logger = logger,
            .event_bus = event_bus,
        };
    }

    pub fn run(self: *ScriptHost, ctx: *const tool_context.ToolContext, spec: script_contract.ScriptSpec) !script_contract.ScriptResult {
        const params_json = try paramsToJson(self.allocator, ctx.validated_params);
        defer self.allocator.free(params_json);

        const stdin_payload = try requestToJson(self.allocator, .{
            .tool_id = ctx.tool_id,
            .request_id = ctx.request.request_id,
            .trace_id = ctx.request.trace_id,
            .params_json = params_json,
        });
        defer self.allocator.free(stdin_payload);

        const argv = try buildArgv(self.allocator, spec.program, spec.args);
        defer freeArgv(self.allocator, argv);

        try self.emitEvent("script.started", ctx.tool_id, null);
        var run_result = self.process_runner.run(self.allocator, .{
            .argv = argv,
            .cwd = spec.cwd,
            .env = spec.env,
            .stdin = stdin_payload,
            .timeout_ms = spec.timeout_ms,
        }) catch |err| {
            try self.emitEvent("script.failed", ctx.tool_id, @errorName(err));
            return err;
        };
        defer run_result.deinit(self.allocator);

        if (self.logger) |logger| {
            if (run_result.stderr.len > 0) {
                logger.child("script").child(ctx.tool_id).warn("script stderr", &.{
                    core.logging.LogField.string("stderr", run_result.stderr),
                });
            }
        }

        if (run_result.exit_code != 0) {
            try self.emitEvent("script.failed", ctx.tool_id, "SCRIPT_PROCESS_FAILED");
            return error.ScriptProcessFailed;
        }

        const result = if (spec.expects_json_stdout)
            parseJsonResult(self.allocator, run_result.stdout) catch |err| {
                try self.emitEvent("script.failed", ctx.tool_id, @errorName(err));
                return err;
            }
        else
            script_contract.ScriptResult{
                .ok = true,
                .output_json = try self.allocator.dupe(u8, run_result.stdout),
            };

        try self.emitEvent("script.completed", ctx.tool_id, null);
        return result;
    }

    fn emitEvent(self: *ScriptHost, topic: []const u8, tool_id: []const u8, error_code: ?[]const u8) !void {
        const bus = self.event_bus orelse return;
        const payload = if (error_code) |code|
            try std.fmt.allocPrint(self.allocator, "{{\"tool_id\":\"{s}\",\"error_code\":\"{s}\"}}", .{ tool_id, code })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"tool_id\":\"{s}\"}}", .{tool_id});
        defer self.allocator.free(payload);
        _ = try bus.publish(topic, payload);
    }
};

fn paramsToJson(allocator: std.mem.Allocator, fields: []const core.validation.ValidationField) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    for (fields, 0..) |field, index| {
        if (index > 0) try buf.append(allocator, ',');
        try buf.print(allocator, "{f}:", .{std.json.fmt(field.key, .{})});
        switch (field.value) {
            .string => |value| try buf.print(allocator, "{f}", .{std.json.fmt(value, .{})}),
            .integer => |value| try buf.print(allocator, "{d}", .{value}),
            .boolean => |value| try buf.appendSlice(allocator, if (value) "true" else "false"),
            .float => |value| try buf.print(allocator, "{d}", .{value}),
            .null => try buf.appendSlice(allocator, "null"),
            else => return error.UnsupportedValidationValue,
        }
    }
    try buf.append(allocator, '}');
    return try allocator.dupe(u8, buf.items);
}

fn requestToJson(allocator: std.mem.Allocator, request: script_contract.ScriptRequest) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try buf.print(allocator, "\"tool_id\":{f},\"request_id\":{f},\"trace_id\":", .{
        std.json.fmt(request.tool_id, .{}),
        std.json.fmt(request.request_id, .{}),
    });
    if (request.trace_id) |trace_id| {
        try buf.print(allocator, "{f}", .{std.json.fmt(trace_id, .{})});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.print(allocator, ",\"params_json\":{f}", .{std.json.fmt(request.params_json, .{})});
    try buf.append(allocator, '}');
    return try allocator.dupe(u8, buf.items);
}

fn buildArgv(allocator: std.mem.Allocator, program: []const u8, args: []const []const u8) ![][]const u8 {
    const items = try allocator.alloc([]const u8, args.len + 1);
    errdefer allocator.free(items);

    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) allocator.free(items[i]);
    }

    items[0] = try allocator.dupe(u8, program);
    initialized = 1;

    for (args, 0..) |arg, index| {
        items[index + 1] = try allocator.dupe(u8, arg);
        initialized = index + 2;
    }
    return items;
}

fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |item| allocator.free(item);
    allocator.free(argv);
}

fn parseJsonResult(allocator: std.mem.Allocator, stdout_bytes: []const u8) !script_contract.ScriptResult {
    const Parsed = struct {
        ok: bool,
        output_json: ?[]const u8 = null,
        error_code: ?[]const u8 = null,
        error_message: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(Parsed, allocator, stdout_bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidScriptJsonOutput;
    defer parsed.deinit();

    return .{
        .ok = parsed.value.ok,
        .output_json = if (parsed.value.output_json) |value| try allocator.dupe(u8, value) else null,
        .error_code = if (parsed.value.error_code) |value| try allocator.dupe(u8, value) else null,
        .error_message = if (parsed.value.error_message) |value| try allocator.dupe(u8, value) else null,
    };
}

test "script host executes json-stdio script successfully" {
    var runner_impl = effects.NativeProcessRunner.init();
    var event_bus = runtime.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();
    var host = ScriptHost.init(std.testing.allocator, runner_impl.runner(), null, event_bus.asEventBus());

    var sink = core.logging.sinks.Memory.init(std.testing.allocator, 1);
    defer sink.deinit();
    var logger = core.logging.Logger.init(sink.asLogSink(), .silent);
    defer logger.deinit();

    var effects_runtime = effects.EffectsRuntime.init(.{});
    const params = [_]core.validation.ValidationField{
        .{ .key = "value", .value = .{ .string = "{\"ok\":true}" } },
    };
    const ctx = tool_context.ToolContext{
        .allocator = std.testing.allocator,
        .request = .{
            .request_id = "script_req_01",
            .source = .@"test",
            .authority = .public,
        },
        .tool_id = "script.demo",
        .logger = logger.child("script"),
        .validated_params = params[0..],
        .event_bus = event_bus.asEventBus(),
        .effects = &effects_runtime,
    };

    const py_code =
        "import json,sys;"
        ++ "req=json.load(sys.stdin);"
        ++ "print(json.dumps({'ok': True, 'output_json': req['params_json']}))";

    var result = try host.run(&ctx, .{
        .program = "python3",
        .args = &.{ "-c", py_code },
        .timeout_ms = 1000,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("{\"value\":\"{\\\"ok\\\":true}\"}", result.output_json.?);
}

test "script host rejects invalid json stdout" {
    var runner_impl = effects.NativeProcessRunner.init();
    var host = ScriptHost.init(std.testing.allocator, runner_impl.runner(), null, null);

    var sink = core.logging.sinks.Memory.init(std.testing.allocator, 1);
    defer sink.deinit();
    var logger = core.logging.Logger.init(sink.asLogSink(), .silent);
    defer logger.deinit();

    var event_bus = runtime.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();
    var effects_runtime = effects.EffectsRuntime.init(.{});
    const ctx = tool_context.ToolContext{
        .allocator = std.testing.allocator,
        .request = .{
            .request_id = "script_req_02",
            .source = .@"test",
            .authority = .public,
        },
        .tool_id = "script.invalid",
        .logger = logger.child("script"),
        .validated_params = &.{},
        .event_bus = event_bus.asEventBus(),
        .effects = &effects_runtime,
    };

    try std.testing.expectError(error.InvalidScriptJsonOutput, host.run(&ctx, .{
        .program = "python3",
        .args = &.{ "-c", "print('not-json')" },
        .timeout_ms = 1000,
    }));
}

test "script host enforces timeout" {
    var runner_impl = effects.NativeProcessRunner.init();
    var host = ScriptHost.init(std.testing.allocator, runner_impl.runner(), null, null);

    var sink = core.logging.sinks.Memory.init(std.testing.allocator, 1);
    defer sink.deinit();
    var logger = core.logging.Logger.init(sink.asLogSink(), .silent);
    defer logger.deinit();

    var event_bus = runtime.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();
    var effects_runtime = effects.EffectsRuntime.init(.{});
    const ctx = tool_context.ToolContext{
        .allocator = std.testing.allocator,
        .request = .{
            .request_id = "script_req_03",
            .source = .@"test",
            .authority = .public,
        },
        .tool_id = "script.timeout",
        .logger = logger.child("script"),
        .validated_params = &.{},
        .event_bus = event_bus.asEventBus(),
        .effects = &effects_runtime,
    };

    const py_code = "import time; time.sleep(1); print('{\"ok\": true}')";
    try std.testing.expectError(error.ProcessTimedOut, host.run(&ctx, .{
        .program = "python3",
        .args = &.{ "-c", py_code },
        .timeout_ms = 50,
    }));
}

test "script host rejects non-zero exit status" {
    var runner_impl = effects.NativeProcessRunner.init();
    var host = ScriptHost.init(std.testing.allocator, runner_impl.runner(), null, null);

    var sink = core.logging.sinks.Memory.init(std.testing.allocator, 1);
    defer sink.deinit();
    var logger = core.logging.Logger.init(sink.asLogSink(), .silent);
    defer logger.deinit();

    var event_bus = runtime.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();
    var effects_runtime = effects.EffectsRuntime.init(.{});
    const ctx = tool_context.ToolContext{
        .allocator = std.testing.allocator,
        .request = .{
            .request_id = "script_req_04",
            .source = .@"test",
            .authority = .public,
        },
        .tool_id = "script.nonzero",
        .logger = logger.child("script"),
        .validated_params = &.{},
        .event_bus = event_bus.asEventBus(),
        .effects = &effects_runtime,
    };

    try std.testing.expectError(error.ScriptProcessFailed, host.run(&ctx, .{
        .program = "python3",
        .args = &.{ "-c", "import sys; print('{\"ok\": false}'); sys.exit(3)" },
        .timeout_ms = 1000,
    }));
}

test "script host logs stderr and emits failure events" {
    var app_context = try runtime.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var runner_impl = effects.NativeProcessRunner.init();
    var host = ScriptHost.init(std.testing.allocator, runner_impl.runner(), app_context.logger, app_context.eventBus());

    var effects_runtime = effects.EffectsRuntime.init(.{});
    const ctx = tool_context.ToolContext{
        .allocator = std.testing.allocator,
        .request = .{
            .request_id = "script_req_05",
            .source = .@"test",
            .authority = .public,
        },
        .tool_id = "script.stderr",
        .logger = app_context.logger.child("script"),
        .validated_params = &.{},
        .event_bus = app_context.eventBus(),
        .effects = &effects_runtime,
    };

    try std.testing.expectError(error.InvalidScriptJsonOutput, host.run(&ctx, .{
        .program = "python3",
        .args = &.{ "-c", "import sys; sys.stderr.write('oops\\n'); print('not-json')" },
        .timeout_ms = 1000,
    }));

    const events = try app_context.event_bus.snapshot(std.testing.allocator);
    defer {
        for (events) |*event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }
    try std.testing.expect(events.len >= 2);
    try std.testing.expectEqualStrings("script.started", events[0].topic);
    try std.testing.expectEqualStrings("script.failed", events[1].topic);

    const logs = app_context.memory_sink.snapshot();
    var saw_stderr_log = false;
    for (logs) |entry| {
        if (std.mem.eql(u8, entry.message, "script stderr")) saw_stderr_log = true;
    }
    try std.testing.expect(saw_stderr_log);
}


