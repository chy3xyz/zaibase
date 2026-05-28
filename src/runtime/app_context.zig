const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");
const config_model = @import("../config/root.zig");
const observability = @import("../observability/root.zig");
const app_model = @import("../app/root.zig");
const event_bus_model = @import("event_bus.zig");
const task_runner_model = @import("task_runner.zig");

pub const LogLevel = core.logging.LogLevel;
pub const MemorySink = core.logging.sinks.Memory;
pub const ConsoleSink = core.logging.sinks.Console;
pub const ConsoleStyle = core.logging.ConsoleStyle;
pub const JsonlFileSink = core.logging.sinks.JsonlFile;
pub const MultiSink = core.logging.sinks.Multi;
pub const Logger = core.logging.Logger;
pub const Observer = observability.Observer;
pub const MemoryObserver = observability.MemoryObserver;
pub const MetricsObserver = observability.MetricsObserver;
pub const LogObserver = observability.LogObserver;
pub const JsonlFileObserver = observability.JsonlFileObserver;
pub const MultiObserver = observability.MultiObserver;
pub const MemoryEventBus = event_bus_model.MemoryEventBus;
pub const EventBus = event_bus_model.EventBus;
pub const TaskRunner = task_runner_model.TaskRunner;
pub const CommandRegistry = app_model.CommandRegistry;
pub const CommandDispatcher = app_model.CommandDispatcher;
pub const CommandDefinition = app_model.CommandDefinition;
pub const FieldDefinition = core.validation.FieldDefinition;
pub const ConfigRule = core.validation.ConfigRule;
pub const ConfigPostWriteHook = config_model.ConfigPostWriteHook;
pub const ConfigWritePipeline = config_model.ConfigWritePipeline;
pub const MemoryConfigStore = config_model.MemoryConfigStore;
pub const MemoryConfigChangeLog = config_model.MemoryConfigChangeLog;
pub const MemoryConfigSideEffectSink = config_model.MemoryConfigSideEffectSink;

pub const AppBootstrapConfig = struct {
    log_level: LogLevel = .info,
    console_log_enabled: bool = !builtin.is_test,
    console_log_style: ConsoleStyle = .pretty,
    log_file_path: ?[]const u8 = null,
    log_file_max_bytes: ?u64 = 8 * 1024 * 1024,
    memory_log_capacity: usize = 256,
    observer_log_subsystem: []const u8 = "observer",
    observer_file_path: ?[]const u8 = null,
    observer_file_max_bytes: ?u64 = 1024 * 1024,
    max_event_subscriptions: usize = 64,
};

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    memory_sink: *MemorySink,
    console_sink: ?*ConsoleSink,
    current_console_style: ConsoleStyle,
    logger_file_sink: ?*JsonlFileSink,
    logger_multi_sink: ?*MultiSink,
    logger: *Logger,
    memory_observer: *MemoryObserver,
    metrics_observer: *MetricsObserver,
    log_observer: *LogObserver,
    file_observer: ?*JsonlFileObserver,
    multi_observer: *MultiObserver,
    event_bus: *MemoryEventBus,
    task_runner: *TaskRunner,
    command_registry: *CommandRegistry,
    config_store: *MemoryConfigStore,
    config_change_log: *MemoryConfigChangeLog,
    config_side_effects: *MemoryConfigSideEffectSink,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: AppBootstrapConfig) anyerror!Self {
        const memory_sink = try allocator.create(MemorySink);
        errdefer allocator.destroy(memory_sink);
        memory_sink.* = MemorySink.init(allocator, config.memory_log_capacity);

        var console_sink: ?*ConsoleSink = null;
        if (config.console_log_enabled) {
            const instance = try allocator.create(ConsoleSink);
            errdefer allocator.destroy(instance);
            instance.* = ConsoleSink.init(config.log_level, config.console_log_style);
            console_sink = instance;
        }

        var logger_file_sink: ?*JsonlFileSink = null;
        if (config.log_file_path) |log_file_path| {
            const instance = try allocator.create(JsonlFileSink);
            errdefer allocator.destroy(instance);
            instance.* = try JsonlFileSink.init(allocator, log_file_path, config.log_file_max_bytes, io);
            logger_file_sink = instance;
        }

        var logger_multi_sink: ?*MultiSink = null;
        if (console_sink != null or logger_file_sink != null) {
            var sinks: std.ArrayListUnmanaged(core.logging.LogSink) = .empty;
            defer sinks.deinit(allocator);
            try sinks.append(allocator, memory_sink.asLogSink());
            if (console_sink) |instance| try sinks.append(allocator, instance.asLogSink());
            if (logger_file_sink) |instance| try sinks.append(allocator, instance.asLogSink());

            const instance = try allocator.create(MultiSink);
            errdefer allocator.destroy(instance);
            instance.* = try MultiSink.init(allocator, sinks.items);
            logger_multi_sink = instance;
            // MultiSink owns a copy; safe to free the source.
        }

        const logger = try allocator.create(Logger);
        errdefer allocator.destroy(logger);
        logger.* = Logger.init(if (logger_multi_sink) |instance| instance.asLogSink() else memory_sink.asLogSink(), config.log_level);

        const memory_observer = try allocator.create(MemoryObserver);
        errdefer allocator.destroy(memory_observer);
        memory_observer.* = MemoryObserver.init(allocator);

        const metrics_observer = try allocator.create(MetricsObserver);
        errdefer allocator.destroy(metrics_observer);
        metrics_observer.* = MetricsObserver.init();

        const log_observer = try allocator.create(LogObserver);
        errdefer allocator.destroy(log_observer);
        log_observer.* = LogObserver.init(logger, config.observer_log_subsystem);

        var file_observer: ?*JsonlFileObserver = null;
        if (config.observer_file_path) |observer_file_path| {
            const instance = try allocator.create(JsonlFileObserver);
            errdefer allocator.destroy(instance);
            instance.* = try JsonlFileObserver.init(allocator, observer_file_path, config.observer_file_max_bytes);
            file_observer = instance;
        }

        var observers: std.ArrayListUnmanaged(Observer) = .empty;
        defer observers.deinit(allocator);
        try observers.append(allocator, memory_observer.asObserver());
        try observers.append(allocator, metrics_observer.asObserver());
        try observers.append(allocator, log_observer.asObserver());
        if (file_observer) |instance| {
            try observers.append(allocator, instance.asObserver());
        }

        const multi_observer = try allocator.create(MultiObserver);
        errdefer allocator.destroy(multi_observer);
        multi_observer.* = try MultiObserver.init(allocator, observers.items);

        const event_bus = try allocator.create(MemoryEventBus);
        errdefer allocator.destroy(event_bus);
        event_bus.* = MemoryEventBus.init(allocator);
        event_bus.max_subscriptions = config.max_event_subscriptions;

        const task_runner = try allocator.create(TaskRunner);
        errdefer allocator.destroy(task_runner);
        task_runner.* = TaskRunner.initWithObservability(allocator, multi_observer.asObserver(), event_bus.asEventBus());

        const command_registry = try allocator.create(CommandRegistry);
        errdefer allocator.destroy(command_registry);
        command_registry.* = CommandRegistry.init(allocator);

        const config_store = try allocator.create(MemoryConfigStore);
        errdefer allocator.destroy(config_store);
        config_store.* = MemoryConfigStore.init(allocator);

        const config_change_log = try allocator.create(MemoryConfigChangeLog);
        errdefer allocator.destroy(config_change_log);
        config_change_log.* = MemoryConfigChangeLog.init(allocator);

        const config_side_effects = try allocator.create(MemoryConfigSideEffectSink);
        errdefer allocator.destroy(config_side_effects);
        config_side_effects.* = MemoryConfigSideEffectSink.init(allocator);

        return .{
            .allocator = allocator,
            .memory_sink = memory_sink,
            .console_sink = console_sink,
            .current_console_style = config.console_log_style,
            .logger_file_sink = logger_file_sink,
            .logger_multi_sink = logger_multi_sink,
            .logger = logger,
            .memory_observer = memory_observer,
            .metrics_observer = metrics_observer,
            .log_observer = log_observer,
            .file_observer = file_observer,
            .multi_observer = multi_observer,
            .event_bus = event_bus,
            .task_runner = task_runner,
            .command_registry = command_registry,
            .config_store = config_store,
            .config_change_log = config_change_log,
            .config_side_effects = config_side_effects,
        };
    }

    pub fn deinit(self: *Self) void {
        self.multi_observer.flush();
        self.logger.flush();

        self.task_runner.deinit();
        self.allocator.destroy(self.task_runner);

        self.command_registry.deinit();
        self.allocator.destroy(self.command_registry);

        self.config_side_effects.deinit();
        self.allocator.destroy(self.config_side_effects);

        self.config_change_log.deinit();
        self.allocator.destroy(self.config_change_log);

        self.config_store.deinit();
        self.allocator.destroy(self.config_store);

        self.event_bus.deinit();
        self.allocator.destroy(self.event_bus);

        self.multi_observer.deinit();
        self.allocator.destroy(self.multi_observer);

        if (self.file_observer) |file_observer| {
            file_observer.deinit();
            self.allocator.destroy(file_observer);
        }

        self.log_observer.flush();
        self.allocator.destroy(self.log_observer);

        self.metrics_observer.flush();
        self.allocator.destroy(self.metrics_observer);

        self.memory_observer.deinit();
        self.allocator.destroy(self.memory_observer);

        self.logger.deinit();
        self.allocator.destroy(self.logger);

        if (self.logger_multi_sink) |logger_multi_sink| {
            logger_multi_sink.deinit();
            self.allocator.destroy(logger_multi_sink);
        }

        if (self.logger_file_sink) |logger_file_sink| {
            logger_file_sink.deinit();
            self.allocator.destroy(logger_file_sink);
        }

        if (self.console_sink) |console_sink| {
            console_sink.deinit();
            self.allocator.destroy(console_sink);
        }

        self.memory_sink.deinit();
        self.allocator.destroy(self.memory_sink);
    }

    pub fn observer(self: *Self) Observer {
        return self.multi_observer.asObserver();
    }

    pub fn eventBus(self: *Self) EventBus {
        return self.event_bus.asEventBus();
    }

    pub fn makeDispatcher(self: *Self) CommandDispatcher {
        return CommandDispatcher.initWithRuntime(
            self.allocator,
            self.logger,
            self.command_registry,
            self.task_runner,
            self.observer(),
            self.eventBus(),
        );
    }

    pub fn makeConfigPipeline(
        self: *Self,
        field_definitions: []const FieldDefinition,
        config_rules: []const ConfigRule,
        post_write_hook: ?ConfigPostWriteHook,
    ) ConfigWritePipeline {
        return ConfigWritePipeline.initWithDependencies(
            self.allocator,
            field_definitions,
            config_rules,
            self.config_store.asConfigStore(),
            self.config_change_log.asChangeLog(),
            self.config_side_effects.asSideEffect(),
            post_write_hook,
            self.observer(),
            self.eventBus(),
            self.logger,
        );
    }

    pub fn registerCommand(self: *Self, definition: CommandDefinition) anyerror!void {
        try self.command_registry.register(definition);
    }
};

test "app context initializes and exposes assembled runtime services" {
    var app_context = try AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{});
    defer app_context.deinit();

    try std.testing.expect(app_context.command_registry.count() == 0);
    try std.testing.expectEqual(@as(usize, 0), app_context.memory_observer.count());
    try std.testing.expectEqual(@as(usize, 0), app_context.event_bus.count());
}

test "app context can wire console logger sink when enabled" {
    var app_context = try AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = true,
        .console_log_style = .pretty,
    });
    defer app_context.deinit();

    try std.testing.expect(app_context.console_sink != null);
    try std.testing.expect(app_context.logger_multi_sink != null);
}

test "app context can dispatch commands through assembled dependencies" {
    const Handler = struct {
        fn call(_: *const app_model.CommandContext) anyerror![]const u8 {
            return "{\"name\":\"ourclaw\"}";
        }
    };

    var app_context = try AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{});
    defer app_context.deinit();

    try app_context.registerCommand(.{
        .id = "app.meta",
        .method = "app.meta",
        .handler = Handler.call,
    });

    var dispatcher = app_context.makeDispatcher();
    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_ctx_01",
        .method = "app.meta",
        .params = &.{},
        .source = .@"test",
    }, false);

    try std.testing.expect(envelope.ok);
    try std.testing.expect(app_context.memory_observer.count() >= 2);
    try std.testing.expect(app_context.event_bus.count() >= 2);
}

test "app context can build config pipeline with shared stores" {
    var app_context = try AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{});
    defer app_context.deinit();

    const fields = [_]FieldDefinition{
        .{ .key = "gateway.port", .required = true, .requires_restart = true, .value_kind = .integer, .rules = &.{.port} },
    };

    var pipeline = app_context.makeConfigPipeline(fields[0..], &.{}, null);
    var attempt = try pipeline.applyWrite(&.{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
    }, false);
    defer attempt.deinit();

    try std.testing.expect(attempt.applied());
    try std.testing.expectEqual(@as(usize, 1), app_context.config_change_log.count());
    try std.testing.expectEqual(@as(usize, 1), app_context.config_side_effects.count());
}


