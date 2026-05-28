const std = @import("std");
const core = @import("../core/root.zig");
const store_model = @import("store.zig");
const observer_model = @import("../observability/observer.zig");
const event_bus_model = @import("../runtime/event_bus.zig");

pub const Logger = core.logging.Logger;
pub const LogField = core.logging.LogField;
pub const ValidationField = core.validation.ValidationField;
pub const FieldDefinition = core.validation.FieldDefinition;
pub const ConfigRule = core.validation.ConfigRule;
pub const Validator = core.validation.Validator;
pub const ValidationReport = core.validation.ValidationReport;
pub const ConfigStore = store_model.ConfigStore;
pub const ConfigWriteStats = store_model.ConfigWriteStats;
pub const ConfigChangeKind = store_model.ConfigChangeKind;
pub const ConfigDiffSummary = store_model.ConfigDiffSummary;
pub const ConfigChange = store_model.ConfigChange;
pub const ConfigChangeLog = store_model.ConfigChangeLog;
pub const ConfigChangeLogEntry = store_model.ConfigChangeLogEntry;
pub const Observer = observer_model.Observer;
pub const EventBus = event_bus_model.EventBus;
const rules_config = core.validation.rules_config;

pub const ConfigSideEffect = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        apply: *const fn (ptr: *anyopaque, change: *const ConfigChange) anyerror!void,
    };

    pub fn apply(self: ConfigSideEffect, change: *const ConfigChange) anyerror!void {
        return self.vtable.apply(self.ptr, change);
    }
};

pub const ConfigSideEffectRecord = struct {
    path: []u8,
    kind: ConfigChangeKind,
    side_effect_kind: store_model.ConfigSideEffectKind,
    requires_restart: bool,

    pub fn deinit(self: *ConfigSideEffectRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const MemoryConfigSideEffectSink = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(ConfigSideEffectRecord) = .empty,

    const Self = @This();

    const vtable = ConfigSideEffect.VTable{
        .apply = applyErased,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.records.items) |*record| {
            record.deinit(self.allocator);
        }
        self.records.deinit(self.allocator);
    }

    pub fn asSideEffect(self: *Self) ConfigSideEffect {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn apply(self: *Self, change: *const ConfigChange) anyerror!void {
        try self.records.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, change.path),
            .kind = change.kind,
            .side_effect_kind = change.side_effect_kind,
            .requires_restart = change.requires_restart,
        });
    }

    pub fn count(self: *const Self) usize {
        return self.records.items.len;
    }

    fn applyErased(ptr: *anyopaque, change: *const ConfigChange) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.apply(change);
    }
};

pub const ConfigPostWriteSummary = struct {
    applied_count: usize,
    changed_count: usize,
    requires_restart: bool,
    change_log_count: usize,
    side_effect_count: usize,
};

pub const ConfigPostWriteHook = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        after_write: *const fn (ptr: *anyopaque, summary: *const ConfigPostWriteSummary) anyerror!void,
    };

    pub fn afterWrite(self: ConfigPostWriteHook, summary: *const ConfigPostWriteSummary) anyerror!void {
        return self.vtable.after_write(self.ptr, summary);
    }
};

pub const MemoryConfigPostWriteHookSink = struct {
    records: std.ArrayListUnmanaged(ConfigPostWriteSummary) = .empty,
    allocator: std.mem.Allocator,

    const Self = @This();

    const vtable = ConfigPostWriteHook.VTable{
        .after_write = afterWriteErased,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.records.deinit(self.allocator);
    }

    pub fn asPostWriteHook(self: *Self) ConfigPostWriteHook {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn afterWrite(self: *Self, summary: *const ConfigPostWriteSummary) anyerror!void {
        try self.records.append(self.allocator, summary.*);
    }

    pub fn count(self: *const Self) usize {
        return self.records.items.len;
    }

    fn afterWriteErased(ptr: *anyopaque, summary: *const ConfigPostWriteSummary) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.afterWrite(summary);
    }
};

pub const ConfigWriteAttempt = struct {
    report: ValidationReport,
    stats: ?ConfigWriteStats = null,
    diff_summary: ?ConfigDiffSummary = null,
    change_log_count: usize = 0,
    side_effect_count: usize = 0,
    post_write_hook_count: usize = 0,

    pub fn deinit(self: *ConfigWriteAttempt) void {
        if (self.diff_summary) |*diff_summary| {
            diff_summary.deinit(self.report.allocator);
        }
        self.report.deinit();
    }

    pub fn applied(self: *const ConfigWriteAttempt) bool {
        return self.report.isOk() and self.stats != null;
    }

    pub fn requiresRestart(self: *const ConfigWriteAttempt) bool {
        return if (self.diff_summary) |diff_summary| diff_summary.requires_restart else false;
    }
};

pub const ConfigWritePipeline = struct {
    allocator: std.mem.Allocator,
    logger: ?*Logger = null,
    field_definitions: []const FieldDefinition,
    config_rules: []const ConfigRule = &.{},
    store: ?ConfigStore = null,
    change_log: ?ConfigChangeLog = null,
    side_effect: ?ConfigSideEffect = null,
    post_write_hook: ?ConfigPostWriteHook = null,
    observer: ?Observer = null,
    event_bus: ?EventBus = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, field_definitions: []const FieldDefinition, logger: ?*Logger) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
            .field_definitions = field_definitions,
        };
    }

    pub fn initWithRules(
        allocator: std.mem.Allocator,
        field_definitions: []const FieldDefinition,
        config_rules: []const ConfigRule,
        logger: ?*Logger,
    ) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
            .field_definitions = field_definitions,
            .config_rules = config_rules,
        };
    }

    pub fn initWithStore(
        allocator: std.mem.Allocator,
        field_definitions: []const FieldDefinition,
        config_rules: []const ConfigRule,
        store: ConfigStore,
        logger: ?*Logger,
    ) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
            .field_definitions = field_definitions,
            .config_rules = config_rules,
            .store = store,
        };
    }

    pub fn initWithDependencies(
        allocator: std.mem.Allocator,
        field_definitions: []const FieldDefinition,
        config_rules: []const ConfigRule,
        store: ConfigStore,
        change_log: ?ConfigChangeLog,
        side_effect: ?ConfigSideEffect,
        post_write_hook: ?ConfigPostWriteHook,
        observer: ?Observer,
        event_bus: ?EventBus,
        logger: ?*Logger,
    ) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
            .field_definitions = field_definitions,
            .config_rules = config_rules,
            .store = store,
            .change_log = change_log,
            .side_effect = side_effect,
            .post_write_hook = post_write_hook,
            .observer = observer,
            .event_bus = event_bus,
        };
    }

    pub fn validateWrite(self: *const Self, updates: []const ValidationField, confirm_risk: bool) !ValidationReport {
        var validator = Validator.init(self.allocator, self.field_definitions, .{
            .mode = .config_write,
            .strict_unknown_fields = true,
            .confirm_risk = confirm_risk,
        });

        var report = try validator.validateObject(updates);
        try rules_config.applyRules(self.allocator, &report, updates, self.config_rules, confirm_risk);

        if (self.logger) |logger| {
            const config_logger = logger.child("config").child("write");
            if (report.isOk()) {
                config_logger.info("config validated", &.{
                    LogField.int("update_count", @intCast(updates.len)),
                });
            } else {
                const app_error = core.error_model.fromValidationReport(&report);
                config_logger.warn("config validation failed", &.{
                    LogField.string("error_code", app_error.code),
                });
            }
        }

        return report;
    }

    pub fn applyWrite(self: *const Self, updates: []const ValidationField, confirm_risk: bool) anyerror!ConfigWriteAttempt {
        const store = self.store orelse return error.ConfigStoreNotConfigured;

        var report = try self.validateWrite(updates, confirm_risk);
        if (!report.isOk()) {
            try self.emitConfigEvent("config.validation_failed", updates.len, 0, false, 0, 0);
            return .{ .report = report };
        }

        var diff_summary = try self.buildDiffSummary(store, updates);
        errdefer diff_summary.deinit(self.allocator);

        const stats = try store.applyValidatedWrites(updates);
        const change_log_count = try self.appendChangeLogEntries(diff_summary);
        const side_effect_count = try self.applySideEffects(diff_summary);
        const post_write_hook_count = try self.runPostWriteHook(.{
            .applied_count = stats.applied_count,
            .changed_count = diff_summary.changed_count,
            .requires_restart = diff_summary.requires_restart,
            .change_log_count = change_log_count,
            .side_effect_count = side_effect_count,
        });

        if (self.logger) |logger| {
            logger.child("config").child("write").info("config written", &.{
                LogField.int("applied_count", @intCast(stats.applied_count)),
                LogField.int("changed_count", @intCast(stats.changed_count)),
                LogField.boolean("requires_restart", diff_summary.requires_restart),
            });
        }

        try self.emitConfigEvent(
            "config.changed",
            updates.len,
            diff_summary.changed_count,
            diff_summary.requires_restart,
            side_effect_count,
            post_write_hook_count,
        );

        return .{
            .report = report,
            .stats = stats,
            .diff_summary = diff_summary,
            .change_log_count = change_log_count,
            .side_effect_count = side_effect_count,
            .post_write_hook_count = post_write_hook_count,
        };
    }

    pub fn previewWrite(self: *const Self, updates: []const ValidationField, confirm_risk: bool) anyerror!ConfigWriteAttempt {
        const store = self.store orelse return error.ConfigStoreNotConfigured;

        var report = try self.validateWrite(updates, confirm_risk);
        if (!report.isOk()) {
            return .{ .report = report };
        }

        const diff_summary = try self.buildDiffSummary(store, updates);
        return .{
            .report = report,
            .diff_summary = diff_summary,
        };
    }

    fn buildDiffSummary(self: *const Self, store: ConfigStore, updates: []const ValidationField) anyerror!ConfigDiffSummary {
        const changes = try self.allocator.alloc(ConfigChange, updates.len);
        errdefer self.allocator.free(changes);

        var changed_count: usize = 0;
        var requires_restart = false;

        for (updates, 0..) |update, index| {
            const old_value_json = try store.readValueJson(self.allocator, update.key);
            errdefer if (old_value_json) |value| self.allocator.free(value);

            const new_value_json = try store_model.serializeValidationValue(self.allocator, update.value);
            errdefer self.allocator.free(new_value_json);

            const changed = if (old_value_json) |old_value|
                !std.mem.eql(u8, old_value, new_value_json)
            else
                true;

            const definition = findDefinition(self.field_definitions, update.key);
            const field_requires_restart = if (definition) |field_definition| field_definition.requires_restart else false;
            const field_sensitive = if (definition) |field_definition| field_definition.sensitive else false;
            const field_kind = if (definition) |field_definition| field_definition.value_kind else update.value.kind();
            const field_side_effect_kind = classifySideEffect(update.key, field_requires_restart);

            const change_kind: ConfigChangeKind = if (old_value_json == null)
                .added
            else if (changed)
                .updated
            else
                .unchanged;

            const display_old_value_json = if (old_value_json) |old_value|
                try displayJson(self.allocator, field_sensitive, old_value)
            else
                null;
            errdefer if (display_old_value_json) |value| self.allocator.free(value);

            const display_new_value_json = try displayJson(self.allocator, field_sensitive, new_value_json);
            errdefer self.allocator.free(display_new_value_json);

            if (changed) {
                changed_count += 1;
                requires_restart = requires_restart or field_requires_restart;
            }

            changes[index] = .{
                .path = try self.allocator.dupe(u8, update.key),
                .kind = change_kind,
                .changed = changed,
                .sensitive = field_sensitive,
                .requires_restart = field_requires_restart,
                .side_effect_kind = if (changed) field_side_effect_kind else .none,
                .value_kind = field_kind,
                .old_value_json = display_old_value_json,
                .new_value_json = display_new_value_json,
            };

            if (old_value_json) |value| self.allocator.free(value);
            self.allocator.free(new_value_json);
        }

        return .{
            .changes = changes,
            .changed_count = changed_count,
            .requires_restart = requires_restart,
        };
    }

    fn appendChangeLogEntries(self: *const Self, diff_summary: ConfigDiffSummary) anyerror!usize {
        const change_log = self.change_log orelse return 0;

        var appended: usize = 0;
        for (diff_summary.changes) |change| {
            if (!change.changed) {
                continue;
            }

            try change_log.append(.{
                .ts_unix_ms = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }),
                .path = change.path,
                .requires_restart = change.requires_restart,
                .side_effect_kind = change.side_effect_kind,
                .old_value_json = change.old_value_json,
                .new_value_json = change.new_value_json,
            });
            appended += 1;
        }

        return appended;
    }

    fn applySideEffects(self: *const Self, diff_summary: ConfigDiffSummary) anyerror!usize {
        const side_effect = self.side_effect orelse return 0;

        var applied: usize = 0;
        for (diff_summary.changes) |*change| {
            if (!change.changed) {
                continue;
            }
            try side_effect.apply(change);
            applied += 1;
        }
        return applied;
    }

    fn runPostWriteHook(self: *const Self, summary: ConfigPostWriteSummary) anyerror!usize {
        const post_write_hook = self.post_write_hook orelse return 0;
        try post_write_hook.afterWrite(&summary);
        return 1;
    }

    fn emitConfigEvent(
        self: *const Self,
        topic: []const u8,
        update_count: usize,
        changed_count: usize,
        requires_restart: bool,
        side_effect_count: usize,
        post_write_hook_count: usize,
    ) anyerror!void {
        if (self.observer == null and self.event_bus == null) {
            return;
        }

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"updateCount\":{d},\"changedCount\":{d},\"requiresRestart\":{s},\"sideEffectCount\":{d},\"postWriteHookCount\":{d}}}",
            .{ update_count, changed_count, if (requires_restart) "true" else "false", side_effect_count, post_write_hook_count },
        );
        defer self.allocator.free(payload);

        if (self.event_bus) |event_bus| {
            _ = try event_bus.publish(topic, payload);
        }
        if (self.observer) |observer| {
            observer.record(topic, payload);
        }
    }
};

fn findDefinition(fields: []const FieldDefinition, key: []const u8) ?FieldDefinition {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key)) {
            return field;
        }
    }
    return null;
}

fn classifySideEffect(path: []const u8, requires_restart: bool) store_model.ConfigSideEffectKind {
    if (requires_restart) {
        return .restart_required;
    }
    if (std.mem.startsWith(u8, path, "logging.")) {
        return .reload_logging;
    }
    if (std.mem.startsWith(u8, path, "providers.")) {
        return .refresh_providers;
    }
    return .notify_runtime;
}

fn displayJson(allocator: std.mem.Allocator, sensitive: bool, value_json: []const u8) anyerror![]u8 {
    if (!sensitive) {
        return allocator.dupe(u8, value_json);
    }
    return allocator.dupe(u8, "\"[REDACTED]\"");
}

test "config pipeline validates flat config updates" {
    const definitions = [_]FieldDefinition{
        .{ .key = "gateway.port", .required = true, .value_kind = .integer, .rules = &.{.port} },
        .{ .key = "logging.file.path", .required = false, .value_kind = .string, .rules = &.{.path_no_traversal} },
    };
    const updates = [_]ValidationField{
        .{ .key = "gateway.port", .value = .{ .integer = 0 } },
        .{ .key = "logging.file.path", .value = .{ .string = "../bad.log" } },
    };

    const pipeline = ConfigWritePipeline.init(std.testing.allocator, definitions[0..], null);
    var report = try pipeline.validateWrite(updates[0..], false);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 2), report.issueCount());
}

test "config pipeline applies config cross-field rules" {
    const definitions = [_]FieldDefinition{
        .{ .key = "logging.file.enabled", .required = false, .value_kind = .boolean },
        .{ .key = "logging.file.path", .required = false, .value_kind = .string, .rules = &.{.path_no_traversal} },
    };
    const config_rules = [_]ConfigRule{
        .{ .require_non_empty_string_when_bool = .{
            .flag_path = "logging.file.enabled",
            .expected = true,
            .required_path = "logging.file.path",
            .message = "logging.file.path is required when file logging is enabled",
        } },
    };
    const updates = [_]ValidationField{
        .{ .key = "logging.file.enabled", .value = .{ .boolean = true } },
    };

    const pipeline = ConfigWritePipeline.initWithRules(std.testing.allocator, definitions[0..], config_rules[0..], null);
    var report = try pipeline.validateWrite(updates[0..], false);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 1), report.issueCount());
    try std.testing.expectEqualStrings("logging.file.path", report.issues.items[0].path);
}

test "config pipeline writes validated updates into config store" {
    const store_file = @import("store.zig");

    const definitions = [_]FieldDefinition{
        .{ .key = "gateway.port", .required = true, .value_kind = .integer, .rules = &.{.port} },
        .{ .key = "gateway.host", .required = true, .value_kind = .string, .rules = &.{.hostname_or_ipv4} },
    };

    var memory_store = store_file.MemoryConfigStore.init(std.testing.allocator);
    defer memory_store.deinit();

    const pipeline = ConfigWritePipeline.initWithStore(
        std.testing.allocator,
        definitions[0..],
        &.{},
        memory_store.asConfigStore(),
        null,
    );

    var attempt = try pipeline.applyWrite(&.{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
        .{ .key = "gateway.host", .value = .{ .string = "127.0.0.1" } },
    }, false);
    defer attempt.deinit();

    try std.testing.expect(attempt.applied());
    try std.testing.expectEqual(@as(usize, 2), attempt.stats.?.changed_count);
    try std.testing.expect(attempt.diff_summary != null);
    try std.testing.expectEqual(@as(i64, 8080), memory_store.get("gateway.port").?.integer);
}

test "config pipeline keeps validation report when write is rejected" {
    const store_file = @import("store.zig");

    const definitions = [_]FieldDefinition{
        .{ .key = "gateway.port", .required = true, .value_kind = .integer, .rules = &.{.port} },
    };

    var memory_store = store_file.MemoryConfigStore.init(std.testing.allocator);
    defer memory_store.deinit();

    const pipeline = ConfigWritePipeline.initWithStore(
        std.testing.allocator,
        definitions[0..],
        &.{},
        memory_store.asConfigStore(),
        null,
    );

    var attempt = try pipeline.applyWrite(&.{
        .{ .key = "gateway.port", .value = .{ .integer = 0 } },
    }, false);
    defer attempt.deinit();

    try std.testing.expect(!attempt.applied());
    try std.testing.expectEqual(@as(usize, 1), attempt.report.issueCount());
    try std.testing.expectEqual(@as(usize, 0), memory_store.count());
}

test "config pipeline reports diff summary and restart requirement" {
    const store_file = @import("store.zig");

    const definitions = [_]FieldDefinition{
        .{ .key = "gateway.port", .required = true, .requires_restart = true, .value_kind = .integer, .rules = &.{.port} },
        .{ .key = "gateway.host", .required = true, .requires_restart = false, .value_kind = .string, .rules = &.{.hostname_or_ipv4} },
    };

    var memory_store = store_file.MemoryConfigStore.init(std.testing.allocator);
    defer memory_store.deinit();
    _ = try memory_store.applyValidatedWrites(&.{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
        .{ .key = "gateway.host", .value = .{ .string = "127.0.0.1" } },
    });

    const pipeline = ConfigWritePipeline.initWithStore(
        std.testing.allocator,
        definitions[0..],
        &.{},
        memory_store.asConfigStore(),
        null,
    );

    var attempt = try pipeline.applyWrite(&.{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
        .{ .key = "gateway.host", .value = .{ .string = "0.0.0.0" } },
    }, false);
    defer attempt.deinit();

    try std.testing.expect(attempt.applied());
    try std.testing.expectEqual(@as(usize, 1), attempt.diff_summary.?.changed_count);
    try std.testing.expect(!attempt.requiresRestart());
}

test "config pipeline appends change log entries for changed values" {
    const store_file = @import("store.zig");

    const definitions = [_]FieldDefinition{
        .{ .key = "gateway.port", .required = true, .requires_restart = true, .value_kind = .integer, .rules = &.{.port} },
    };

    var memory_store = store_file.MemoryConfigStore.init(std.testing.allocator);
    defer memory_store.deinit();
    var change_log = store_file.MemoryConfigChangeLog.init(std.testing.allocator);
    defer change_log.deinit();

    const pipeline = ConfigWritePipeline.initWithDependencies(
        std.testing.allocator,
        definitions[0..],
        &.{},
        memory_store.asConfigStore(),
        change_log.asChangeLog(),
        null,
        null,
        null,
        null,
        null,
    );

    var attempt = try pipeline.applyWrite(&.{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
    }, false);
    defer attempt.deinit();

    try std.testing.expectEqual(@as(usize, 1), attempt.change_log_count);
    try std.testing.expectEqual(@as(usize, 1), change_log.count());
    try std.testing.expectEqualStrings("gateway.port", change_log.entries.items[0].path);
}

test "config pipeline redacts sensitive diff values and runs side effects" {
    const store_file = @import("store.zig");

    const definitions = [_]FieldDefinition{
        .{ .key = "providers.openai.api_key", .required = true, .sensitive = true, .value_kind = .string },
    };

    var memory_store = store_file.MemoryConfigStore.init(std.testing.allocator);
    defer memory_store.deinit();
    var side_effect_sink = MemoryConfigSideEffectSink.init(std.testing.allocator);
    defer side_effect_sink.deinit();

    const pipeline = ConfigWritePipeline.initWithDependencies(
        std.testing.allocator,
        definitions[0..],
        &.{},
        memory_store.asConfigStore(),
        null,
        side_effect_sink.asSideEffect(),
        null,
        null,
        null,
        null,
    );

    var attempt = try pipeline.applyWrite(&.{
        .{ .key = "providers.openai.api_key", .value = .{ .string = "sk-secret" } },
    }, false);
    defer attempt.deinit();

    try std.testing.expect(attempt.applied());
    try std.testing.expectEqual(@as(usize, 1), attempt.side_effect_count);
    try std.testing.expect(attempt.diff_summary.?.changes[0].sensitive);
    try std.testing.expectEqualStrings("\"[REDACTED]\"", attempt.diff_summary.?.changes[0].new_value_json);
    try std.testing.expectEqual(ConfigChangeKind.added, attempt.diff_summary.?.changes[0].kind);
    try std.testing.expectEqual(@as(usize, 1), side_effect_sink.count());
}

test "config pipeline emits observer and event bus notifications" {
    const store_file = @import("store.zig");

    const definitions = [_]FieldDefinition{
        .{ .key = "gateway.port", .required = true, .requires_restart = true, .value_kind = .integer, .rules = &.{.port} },
    };

    var memory_store = store_file.MemoryConfigStore.init(std.testing.allocator);
    defer memory_store.deinit();
    var observer = observer_model.MemoryObserver.init(std.testing.allocator);
    defer observer.deinit();
    var event_bus = event_bus_model.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    const pipeline = ConfigWritePipeline.initWithDependencies(
        std.testing.allocator,
        definitions[0..],
        &.{},
        memory_store.asConfigStore(),
        null,
        null,
        null,
        observer.asObserver(),
        event_bus.asEventBus(),
        null,
    );

    var attempt = try pipeline.applyWrite(&.{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
    }, false);
    defer attempt.deinit();

    try std.testing.expect(attempt.applied());
    try std.testing.expectEqual(@as(usize, 1), observer.count());
    try std.testing.expectEqual(@as(usize, 1), event_bus.count());
}

test "config pipeline runs post write hook and exposes summary" {
    const store_file = @import("store.zig");

    const definitions = [_]FieldDefinition{
        .{ .key = "logging.level", .required = true, .value_kind = .string },
    };

    var memory_store = store_file.MemoryConfigStore.init(std.testing.allocator);
    defer memory_store.deinit();
    var post_write_hook = MemoryConfigPostWriteHookSink.init(std.testing.allocator);
    defer post_write_hook.deinit();

    const pipeline = ConfigWritePipeline.initWithDependencies(
        std.testing.allocator,
        definitions[0..],
        &.{},
        memory_store.asConfigStore(),
        null,
        null,
        post_write_hook.asPostWriteHook(),
        null,
        null,
        null,
    );

    var attempt = try pipeline.applyWrite(&.{
        .{ .key = "logging.level", .value = .{ .string = "debug" } },
    }, false);
    defer attempt.deinit();

    try std.testing.expectEqual(@as(usize, 1), attempt.post_write_hook_count);
    try std.testing.expectEqual(@as(usize, 1), post_write_hook.count());
    try std.testing.expectEqual(@as(usize, 1), post_write_hook.records.items[0].changed_count);
}


