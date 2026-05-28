const std = @import("std");
const core = @import("../core/root.zig");
const contracts = @import("../contracts/root.zig");
const observer_model = @import("../observability/observer.zig");
const observability = @import("../observability/root.zig");
const event_bus_model = @import("../runtime/event_bus.zig");
const command_types = @import("command_types.zig");
const command_context = @import("command_context.zig");
const command_registry = @import("command_registry.zig");
const task_runner_model = @import("../runtime/task_runner.zig");

pub const Logger = core.logging.Logger;
pub const SubsystemLogger = core.logging.SubsystemLogger;
pub const LogField = core.logging.LogField;
pub const Validator = core.validation.Validator;
pub const ValidationField = core.validation.ValidationField;
pub const ValidationReport = core.validation.ValidationReport;
pub const RequestSource = command_types.RequestSource;
pub const Authority = command_types.Authority;
pub const CommandExecutionMode = command_types.CommandExecutionMode;
pub const CommandRequest = command_types.CommandRequest;
pub const RequestContext = command_types.RequestContext;
pub const Observer = observer_model.Observer;
pub const EventBus = event_bus_model.EventBus;
pub const CommandContext = command_context.CommandContext;
pub const FieldDefinition = command_registry.FieldDefinition;
pub const CommandDefinition = command_registry.CommandDefinition;
pub const CommandRegistry = command_registry.CommandRegistry;
pub const TaskRunner = task_runner_model.TaskRunner;
pub const TaskAccepted = contracts.envelope.TaskAccepted;
pub const EnvelopeMeta = contracts.envelope.EnvelopeMeta;

pub const CommandSchema = struct {
    method: []const u8,
    params: []const FieldDefinition,
};

pub const CommandDispatchResult = union(enum) {
    success_json: []const u8,
    task_accepted: TaskAccepted,
};

pub const CommandEnvelope = contracts.envelope.Envelope(CommandDispatchResult);

fn summarizeParamsJson(allocator: std.mem.Allocator, fields: []const ValidationField) anyerror![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    for (fields, 0..) |field, index| {
        if (index > 0) try buf.append(allocator, ',');
        try buf.print(allocator, "\"{s}\":", .{field.key});
        switch (field.value) {
            .string => |value| try buf.print(allocator, "\"{s}\"", .{value}),
            .integer => |value| try buf.print(allocator, "{d}", .{value}),
            .boolean => |value| try buf.appendSlice(allocator, if (value) "true" else "false"),
            else => try buf.appendSlice(allocator, "null"),
        }
    }
    try buf.append(allocator, '}');
    return allocator.dupe(u8, buf.items);
}

fn summarizeResultJson(result_json: []const u8) []const u8 {
    if (result_json.len <= 96) return result_json;
    return result_json[0..96];
}

const AsyncCommandJobData = struct {
    request: RequestContext,
    command_id: []u8,
    command_method: []u8,
    command_description: []u8,
    user_data: ?*anyopaque,
    validated_params: []ValidationField,
    async_handler: command_registry.AsyncCommandHandler,

    fn run(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));

        var sink = core.logging.sinks.Memory.init(allocator, 1);
        defer sink.deinit();
        var logger = core.logging.Logger.init(sink.asLogSink(), .silent);
        defer logger.deinit();

        if (self.request.trace_id != null or self.request.span_id != null) {
            logger.trace_context_provider = observability.TraceScope.provider();
            observability.TraceScope.set(.{
                .trace_id = self.request.trace_id,
                .request_id = self.request.request_id,
                .span_id = self.request.span_id,
            });
        }
        defer observability.TraceScope.clear();

        var ctx = CommandContext{
            .allocator = allocator,
            .request = self.request,
            .command_id = self.command_id,
            .command_method = self.command_method,
            .command_description = self.command_description,
            .user_data = self.user_data,
            .logger = logger.child("runtime").child("task").child(self.command_method),
            .validated_params = self.validated_params,
        };

        const params_summary = summarizeParamsJson(allocator, self.validated_params) catch try allocator.dupe(u8, "{}");
        defer allocator.free(params_summary);
        const method_name = try std.fmt.allocPrint(allocator, "AsyncCommand.{s}", .{self.command_method});
        defer allocator.free(method_name);
        var method_trace = try observability.MethodTrace.begin(allocator, ctx.logger.logger, method_name, params_summary, 250);
        defer method_trace.deinit();

        const result = self.async_handler(&ctx) catch |err| {
            method_trace.finishError(@errorName(err), null, true);
            return err;
        };
        defer allocator.free(result);
        method_trace.finishSuccess(summarizeResultJson(result), true);
        return allocator.dupe(u8, result);
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));

        allocator.free(self.request.request_id);
        if (self.request.trace_id) |trace_id| allocator.free(trace_id);
        if (self.request.span_id) |span_id| allocator.free(span_id);
        allocator.free(self.command_id);
        allocator.free(self.command_method);
        allocator.free(self.command_description);
        for (self.validated_params) |*field| {
            field.deinit(allocator);
        }
        allocator.free(self.validated_params);
        allocator.destroy(self);
    }
};

pub const CommandDispatcher = struct {
    allocator: std.mem.Allocator,
    logger: ?*Logger = null,
    registry: ?*const CommandRegistry = null,
    task_runner: ?*TaskRunner = null,
    observer: ?Observer = null,
    event_bus: ?EventBus = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, logger: ?*Logger) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn initWithRegistry(allocator: std.mem.Allocator, logger: ?*Logger, registry: *const CommandRegistry) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
            .registry = registry,
        };
    }

    pub fn initWithServices(
        allocator: std.mem.Allocator,
        logger: ?*Logger,
        registry: *const CommandRegistry,
        task_runner: ?*TaskRunner,
    ) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
            .registry = registry,
            .task_runner = task_runner,
        };
    }

    pub fn initWithRuntime(
        allocator: std.mem.Allocator,
        logger: ?*Logger,
        registry: *const CommandRegistry,
        task_runner: ?*TaskRunner,
        observer: ?Observer,
        event_bus: ?EventBus,
    ) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
            .registry = registry,
            .task_runner = task_runner,
            .observer = observer,
            .event_bus = event_bus,
        };
    }

    pub fn validateRequest(self: *const Self, request: CommandRequest, schema: CommandSchema, confirm_risk: bool) anyerror!ValidationReport {
        var validator = Validator.init(self.allocator, schema.params, .{
            .mode = .request,
            .field_path_prefix = "params",
            .strict_unknown_fields = true,
            .confirm_risk = confirm_risk,
        });

        var report = try validator.validateObject(request.params);
        if (self.dispatchLogger()) |dispatch_logger| {
            if (report.isOk()) {
                dispatch_logger.info("command validated", &.{
                    LogField.string("method", request.method),
                    LogField.string("source", @tagName(request.source)),
                    LogField.string("request_id", request.request_id),
                });
            } else {
                const app_error = core.error_model.fromValidationReport(&report);
                dispatch_logger.warn("command validation failed", &.{
                    LogField.string("method", request.method),
                    LogField.string("source", @tagName(request.source)),
                    LogField.string("request_id", request.request_id),
                    LogField.string("error_code", app_error.code),
                });
            }
        }

        return report;
    }

    pub fn dispatch(self: *const Self, request: CommandRequest, confirm_risk: bool) anyerror!CommandEnvelope {
        const started_at_ms = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); });
        self.logInfo("command received", request, null, null);
        try self.emitCommandEvent("command.started", request, null, null, null, null);

        const registry = self.registry orelse {
            const app_error = core.error_model.internal("command registry is not configured");
            self.logFailure("command registry missing", request, app_error.code);
            try self.emitCommandEvent("command.failed", request, null, app_error.code, null, elapsedSince(started_at_ms));
            return CommandEnvelope.failure(app_error, self.metaForRequest(request));
        };

        const command = registry.findByMethod(request.method) orelse {
            const app_error = core.error_model.methodNotFound(request.method);
            self.logFailure("command method not found", request, app_error.code);
            try self.emitCommandEvent("command.failed", request, null, app_error.code, null, elapsedSince(started_at_ms));
            return CommandEnvelope.failure(app_error, self.metaForRequest(request));
        };

        if (!sourceAllowed(command.allowed_sources, request.source)) {
            const app_error = core.error_model.fromKind(.method_not_allowed, .{ .target = request.method });
            self.logFailure("command source not allowed", request, app_error.code);
            try self.emitCommandEvent("command.failed", request, command, app_error.code, null, elapsedSince(started_at_ms));
            return CommandEnvelope.failure(app_error, self.metaForRequest(request));
        }

        if (!Authority.allows(request.authority, command.authority)) {
            const app_error = core.error_model.fromKind(.method_not_allowed, .{ .target = request.method });
            self.logFailure("command authority denied", request, app_error.code);
            try self.emitCommandEvent("command.failed", request, command, app_error.code, null, elapsedSince(started_at_ms));
            return CommandEnvelope.failure(app_error, self.metaForRequest(request));
        }

        var report = try self.validateRequest(request, .{
            .method = command.method,
            .params = command.params,
        }, confirm_risk);
        defer report.deinit();

        if (!report.isOk()) {
            const app_error = core.error_model.fromValidationReport(&report);
            try self.emitCommandEvent("command.validation_failed", request, command, app_error.code, null, elapsedSince(started_at_ms));
            return CommandEnvelope.failure(app_error, self.metaForRequest(request));
        }

        return switch (command.execution_mode) {
            .sync => self.dispatchSync(request, command, started_at_ms),
            .async_task => self.dispatchAsync(request, command, started_at_ms),
        };
    }

    fn dispatchSync(self: *const Self, request: CommandRequest, command: *const CommandDefinition, started_at_ms: i64) anyerror!CommandEnvelope {
        const handler = command.handler orelse {
            const app_error = core.error_model.internal("sync command handler is missing");
            try self.emitCommandEvent("command.failed", request, command, app_error.code, null, elapsedSince(started_at_ms));
            return CommandEnvelope.failure(app_error, self.metaForRequest(request));
        };

        var fallback_sink = core.logging.sinks.Memory.init(self.allocator, 1);
        defer fallback_sink.deinit();
        var fallback_logger = core.logging.Logger.init(fallback_sink.asLogSink(), .silent);
        defer fallback_logger.deinit();

        const command_logger = if (self.dispatchLogger()) |dispatch_logger|
            dispatch_logger.child(command.method)
        else
            fallback_logger.child("runtime").child("dispatch").child(command.method);

        var ctx = CommandContext{
            .allocator = self.allocator,
            .request = self.requestContextFor(request),
            .command_id = command.id,
            .command_method = command.method,
            .command_description = command.description,
            .user_data = command.user_data,
            .logger = command_logger,
            .validated_params = request.params,
        };

        const params_summary = summarizeParamsJson(self.allocator, request.params) catch try self.allocator.dupe(u8, "{}");
        defer self.allocator.free(params_summary);
        const method_name = try std.fmt.allocPrint(self.allocator, "Command.{s}", .{command.method});
        defer self.allocator.free(method_name);
        var method_trace = try observability.MethodTrace.begin(self.allocator, ctx.logger.logger, method_name, params_summary, 250);
        defer method_trace.deinit();

        const result_json = handler(&ctx) catch |err| {
            const app_error = core.error_model.fromInternalError(err, .{ .target = command.method });
            method_trace.finishError(@errorName(err), app_error.code, false);
            self.logFailure("command failed", request, app_error.code);
            try self.emitCommandEvent("command.failed", request, command, app_error.code, null, elapsedSince(started_at_ms));
            return CommandEnvelope.failure(app_error, self.metaForRequest(request));
        };

        method_trace.finishSuccess(summarizeResultJson(result_json), false);

        self.logInfo("command completed", request, command, null);
        try self.emitCommandEvent("command.completed", request, command, null, null, elapsedSince(started_at_ms));
        return CommandEnvelope.success(.{ .success_json = result_json }, self.metaForRequest(request));
    }

    fn dispatchAsync(self: *const Self, request: CommandRequest, command: *const CommandDefinition, started_at_ms: i64) anyerror!CommandEnvelope {
        const runner = self.task_runner orelse {
            const app_error = core.error_model.fromKind(.runtime_task_failed, .{
                .message = "task runner is not configured",
                .target = command.method,
            });
            try self.emitCommandEvent("command.failed", request, command, app_error.code, null, elapsedSince(started_at_ms));
            return CommandEnvelope.failure(app_error, self.metaForRequest(request));
        };

        const async_handler = command.async_handler orelse {
            const app_error = core.error_model.internal("async command handler is missing");
            try self.emitCommandEvent("command.failed", request, command, app_error.code, null, elapsedSince(started_at_ms));
            return CommandEnvelope.failure(app_error, self.metaForRequest(request));
        };

        const job_data = try self.buildAsyncJobData(request, command, async_handler);
        const accepted = try runner.submitJob(command.method, request.request_id, .{
            .ptr = @ptrCast(job_data),
            .vtable = &.{
                .run = AsyncCommandJobData.run,
                .deinit = AsyncCommandJobData.deinit,
            },
        });

        self.logInfo("async command accepted", request, command, accepted.task_id);
        try self.emitCommandEvent("command.accepted", request, command, null, accepted.task_id, elapsedSince(started_at_ms));

        var meta = self.metaForRequest(request);
        meta.task_id = accepted.task_id;
        return CommandEnvelope.success(.{ .task_accepted = accepted }, meta);
    }

    fn buildAsyncJobData(
        self: *const Self,
        request: CommandRequest,
        command: *const CommandDefinition,
        async_handler: command_registry.AsyncCommandHandler,
    ) anyerror!*AsyncCommandJobData {
        const job_data = try self.allocator.create(AsyncCommandJobData);
        errdefer self.allocator.destroy(job_data);

        const request_context = try self.cloneRequestContext(request);
        errdefer freeRequestContext(self.allocator, request_context);

        const params = try cloneValidationFields(self.allocator, request.params);
        errdefer freeValidationFields(self.allocator, params);

        job_data.* = .{
            .request = request_context,
            .command_id = try self.allocator.dupe(u8, command.id),
            .command_method = try self.allocator.dupe(u8, command.method),
            .command_description = try self.allocator.dupe(u8, command.description),
            .user_data = command.user_data,
            .validated_params = params,
            .async_handler = async_handler,
        };

        return job_data;
    }

    fn cloneRequestContext(self: *const Self, request: CommandRequest) anyerror!RequestContext {
        const request_context = self.requestContextFor(request);
        return .{
            .request_id = try self.allocator.dupe(u8, request_context.request_id),
            .trace_id = if (request_context.trace_id) |trace_id| try self.allocator.dupe(u8, trace_id) else null,
            .span_id = if (request_context.span_id) |span_id| try self.allocator.dupe(u8, span_id) else null,
            .source = request_context.source,
            .authority = request_context.authority,
            .timeout_ms = request_context.timeout_ms,
        };
    }

    fn requestContextFor(self: *const Self, request: CommandRequest) RequestContext {
        var request_context = RequestContext{
            .request_id = request.request_id,
            .trace_id = request.trace_id,
            .span_id = request.span_id,
            .source = request.source,
            .authority = request.authority,
            .timeout_ms = request.timeout_ms,
        };

        if (self.logger) |logger| {
            if (request_context.trace_id == null) {
                if (logger.trace_context_provider) |provider| {
                    const trace_context = provider.getCurrent();
                    request_context.trace_id = trace_context.trace_id;
                    request_context.span_id = trace_context.span_id;
                }
            }
        }

        return request_context;
    }

    fn dispatchLogger(self: *const Self) ?SubsystemLogger {
        if (self.logger) |logger| {
            return logger.child("runtime").child("dispatch");
        }
        return null;
    }

    fn metaForRequest(self: *const Self, request: CommandRequest) EnvelopeMeta {
        var meta = EnvelopeMeta{
            .request_id = request.request_id,
        };

        if (self.logger) |logger| {
            if (logger.trace_context_provider) |provider| {
                const trace_context = provider.getCurrent();
                meta.trace_id = trace_context.trace_id;
            }
        }

        return meta;
    }

    fn logFailure(self: *const Self, message: []const u8, request: CommandRequest, error_code: []const u8) void {
        if (self.dispatchLogger()) |dispatch_logger| {
            dispatch_logger.warn(message, &.{
                LogField.string("method", request.method),
                LogField.string("source", @tagName(request.source)),
                LogField.string("request_id", request.request_id),
                LogField.string("error_code", error_code),
            });
        }
    }

    fn logInfo(self: *const Self, message: []const u8, request: CommandRequest, command: ?*const CommandDefinition, task_id: ?[]const u8) void {
        if (self.dispatchLogger()) |dispatch_logger| {
            var fields: [5]LogField = undefined;
            var count: usize = 0;

            fields[count] = LogField.string("method", request.method);
            count += 1;
            fields[count] = LogField.string("source", @tagName(request.source));
            count += 1;
            fields[count] = LogField.string("request_id", request.request_id);
            count += 1;
            if (command) |cmd| {
                fields[count] = LogField.string("command_id", cmd.id);
                count += 1;
            }
            if (task_id) |value| {
                fields[count] = LogField.string("task_id", value);
                count += 1;
            }

            dispatch_logger.info(message, fields[0..count]);
        }
    }

    fn emitCommandEvent(
        self: *const Self,
        topic: []const u8,
        request: CommandRequest,
        command: ?*const CommandDefinition,
        error_code: ?[]const u8,
        task_id: ?[]const u8,
        duration_ms: ?u64,
    ) anyerror!void {
        if (self.event_bus == null and self.observer == null) {
            return;
        }

        const payload = try self.buildCommandPayload(request, command, error_code, task_id, duration_ms);
        defer self.allocator.free(payload);

        if (self.event_bus) |event_bus| {
            _ = try event_bus.publish(topic, payload);
        }
        if (self.observer) |observer| {
            observer.record(topic, payload);
        }
    }

    fn buildCommandPayload(
        self: *const Self,
        request: CommandRequest,
        command: ?*const CommandDefinition,
        error_code: ?[]const u8,
        task_id: ?[]const u8,
        duration_ms: ?u64,
    ) anyerror![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.append(self.allocator, '{');
        try appendJsonStringField(&buf, self.allocator, "method", request.method, true);
        try appendJsonStringField(&buf, self.allocator, "requestId", request.request_id, false);
        try appendJsonStringField(&buf, self.allocator, "source", @tagName(request.source), false);
        try appendJsonStringField(&buf, self.allocator, "authority", request.authority.asText(), false);
        if (command) |cmd| {
            try appendJsonStringField(&buf, self.allocator, "commandId", cmd.id, false);
            try appendJsonStringField(&buf, self.allocator, "executionMode", @tagName(cmd.execution_mode), false);
        }
        if (error_code) |value| {
            try appendJsonStringField(&buf, self.allocator, "errorCode", value, false);
        }
        if (task_id) |value| {
            try appendJsonStringField(&buf, self.allocator, "taskId", value, false);
        }
        if (duration_ms) |value| {
            try buf.print(self.allocator, ",\"durationMs\":{d}", .{value});
        }
        if (self.metaForRequest(request).trace_id) |trace_id| {
            try appendJsonStringField(&buf, self.allocator, "traceId", trace_id, false);
        }
        try buf.append(self.allocator, '}');
        return self.allocator.dupe(u8, buf.items);
    }
};

fn elapsedSince(started_at_ms: i64) u64 {
    const now = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); });
    if (now <= started_at_ms) {
        return 0;
    }
    return @intCast(now - started_at_ms);
}

fn sourceAllowed(allowed_sources: []const RequestSource, source: RequestSource) bool {
    for (allowed_sources) |allowed_source| {
        if (allowed_source == source) {
            return true;
        }
    }
    return false;
}

fn cloneValidationFields(allocator: std.mem.Allocator, fields: []const ValidationField) anyerror![]ValidationField {
    const cloned = try allocator.alloc(ValidationField, fields.len);
    errdefer allocator.free(cloned);

    for (fields, 0..) |field, index| {
        cloned[index] = try field.clone(allocator);
    }

    return cloned;
}

fn freeValidationFields(allocator: std.mem.Allocator, fields: []ValidationField) void {
    for (fields) |*field| {
        field.deinit(allocator);
    }
    allocator.free(fields);
}

fn freeRequestContext(allocator: std.mem.Allocator, request_context: RequestContext) void {
    allocator.free(request_context.request_id);
    if (request_context.trace_id) |trace_id| allocator.free(trace_id);
    if (request_context.span_id) |span_id| allocator.free(span_id);
}

fn appendJsonStringField(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8, first: bool) anyerror!void {
    if (!first) {
        try buf.append(allocator, ',');
    }
    try writeJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try writeJsonString(buf, allocator, value);
}

fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) anyerror!void {
    try buf.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 32) {
                    try buf.print(allocator, "\\u00{x:0>2}", .{ch});
                } else {
                    try buf.append(allocator, ch);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

test "command dispatcher validates request params through shared validator" {
    const schema = CommandSchema{
        .method = "config.set",
        .params = &.{
            .{ .key = "path", .required = true, .value_kind = .string, .rules = &.{.non_empty_string} },
            .{ .key = "value", .required = true, .value_kind = .string },
        },
    };
    const request = CommandRequest{
        .request_id = "req_01",
        .method = "config.set",
        .params = &.{
            .{ .key = "path", .value = .{ .string = "" } },
            .{ .key = "extra", .value = .{ .string = "unexpected" } },
        },
        .source = .@"test",
    };

    const dispatcher = CommandDispatcher.init(std.testing.allocator, null);
    var report = try dispatcher.validateRequest(request, schema, false);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 3), report.issueCount());
    try std.testing.expectEqualStrings("params.extra", report.issues.items[0].path);
}

test "command dispatcher writes validation lifecycle logs" {
    const memory_sink_model = @import("../core/logging/root.zig");

    var memory_sink = memory_sink_model.sinks.Memory.init(std.testing.allocator, 8);
    defer memory_sink.deinit();

    var logger = Logger.init(memory_sink.asLogSink(), .info);
    defer logger.deinit();

    const schema = CommandSchema{
        .method = "app.meta",
        .params = &.{},
    };
    const request = CommandRequest{
        .request_id = "req_02",
        .method = "app.meta",
        .params = &.{},
        .source = .cli,
    };

    const dispatcher = CommandDispatcher.init(std.testing.allocator, &logger);
    var report = try dispatcher.validateRequest(request, schema, false);
    defer report.deinit();

    try std.testing.expect(report.isOk());
    try std.testing.expectEqualStrings("runtime/dispatch", memory_sink.latest().?.subsystem);
    try std.testing.expectEqualStrings("command validated", memory_sink.latest().?.message);
}

test "command dispatcher dispatches sync handler and returns envelope" {
    const Handler = struct {
        fn call(ctx: *const CommandContext) anyerror![]const u8 {
            _ = ctx;
            return "{\"name\":\"ourclaw\"}";
        }
    };

    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "app.meta",
        .method = "app.meta",
        .handler = Handler.call,
    });

    const request = CommandRequest{
        .request_id = "req_03",
        .method = "app.meta",
        .params = &.{},
        .source = .cli,
    };

    const dispatcher = CommandDispatcher.initWithRegistry(std.testing.allocator, null, &registry);
    const envelope = try dispatcher.dispatch(request, false);

    try std.testing.expect(envelope.ok);
    try std.testing.expectEqualStrings("{\"name\":\"ourclaw\"}", envelope.result.?.success_json);
    try std.testing.expectEqualStrings("req_03", envelope.meta.request_id.?);
}

test "command dispatcher maps method not found to stable app error" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const request = CommandRequest{
        .request_id = "req_04",
        .method = "missing.command",
        .params = &.{},
        .source = .cli,
    };

    const dispatcher = CommandDispatcher.initWithRegistry(std.testing.allocator, null, &registry);
    const envelope = try dispatcher.dispatch(request, false);

    try std.testing.expect(!envelope.ok);
    try std.testing.expectEqualStrings(core.error_model.code.CORE_METHOD_NOT_FOUND, envelope.app_error.?.code);
}

test "command dispatcher enforces authority checks" {
    const Handler = struct {
        fn call(_: *const CommandContext) anyerror![]const u8 {
            return "{}";
        }
    };

    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "service.restart",
        .method = "service.restart",
        .authority = .admin,
        .handler = Handler.call,
    });

    const request = CommandRequest{
        .request_id = "req_05",
        .method = "service.restart",
        .params = &.{},
        .source = .cli,
        .authority = .public,
    };

    const dispatcher = CommandDispatcher.initWithRegistry(std.testing.allocator, null, &registry);
    const envelope = try dispatcher.dispatch(request, false);

    try std.testing.expect(!envelope.ok);
    try std.testing.expectEqualStrings(core.error_model.code.CORE_METHOD_NOT_ALLOWED, envelope.app_error.?.code);
}

test "command dispatcher accepts async task commands via task runner" {
    const AsyncHandler = struct {
        fn call(ctx: *const CommandContext) anyerror![]const u8 {
            return ctx.allocator.dupe(u8, "{\"status\":\"ok\"}");
        }
    };

    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "diagnostics.doctor",
        .method = "diagnostics.doctor",
        .execution_mode = .async_task,
        .async_handler = AsyncHandler.call,
    });

    var task_runner = TaskRunner.init(std.testing.allocator);
    defer task_runner.deinit();

    const request = CommandRequest{
        .request_id = "req_06",
        .method = "diagnostics.doctor",
        .params = &.{},
        .source = .cli,
    };

    const dispatcher = CommandDispatcher.initWithServices(std.testing.allocator, null, &registry, &task_runner);
    const envelope = try dispatcher.dispatch(request, false);

    try std.testing.expect(envelope.ok);
    try std.testing.expectEqualStrings("queued", envelope.result.?.task_accepted.state);
    try std.testing.expectEqual(@as(usize, 1), task_runner.count());
}

test "command dispatcher emits observer and event bus events" {
    const Handler = struct {
        fn call(_: *const CommandContext) anyerror![]const u8 {
            return "{\"ok\":true}";
        }
    };

    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "app.meta",
        .method = "app.meta",
        .handler = Handler.call,
    });

    var observer = observer_model.MemoryObserver.init(std.testing.allocator);
    defer observer.deinit();
    var event_bus = event_bus_model.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    const request = CommandRequest{
        .request_id = "req_07",
        .method = "app.meta",
        .params = &.{},
        .source = .cli,
    };

    const dispatcher = CommandDispatcher.initWithRuntime(
        std.testing.allocator,
        null,
        &registry,
        null,
        observer.asObserver(),
        event_bus.asEventBus(),
    );
    const envelope = try dispatcher.dispatch(request, false);

    try std.testing.expect(envelope.ok);
    try std.testing.expect(observer.count() >= 2);
    try std.testing.expect(event_bus.count() >= 2);
}

test "command dispatcher maps handler failure to shared app error" {
    const Handler = struct {
        fn call(_: *const CommandContext) anyerror![]const u8 {
            return error.Timeout;
        }
    };

    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .id = "service.restart",
        .method = "service.restart",
        .handler = Handler.call,
    });

    const request = CommandRequest{
        .request_id = "req_08",
        .method = "service.restart",
        .params = &.{},
        .source = .cli,
    };

    const dispatcher = CommandDispatcher.initWithRegistry(std.testing.allocator, null, &registry);
    const envelope = try dispatcher.dispatch(request, false);

    try std.testing.expect(!envelope.ok);
    try std.testing.expectEqualStrings(core.error_model.code.CORE_TIMEOUT, envelope.app_error.?.code);
}


