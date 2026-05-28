const std = @import("std");
const observer_model = @import("observer.zig");

pub const Observer = observer_model.Observer;

pub const MetricsSnapshot = struct {
    total_events: usize = 0,
    command_started: usize = 0,
    command_completed: usize = 0,
    command_failed: usize = 0,
    command_accepted: usize = 0,
    validation_failed: usize = 0,
    total_request_duration_ms: u64 = 0,
    last_request_duration_ms: u64 = 0,
    request_duration_samples: usize = 0,
    config_changed: usize = 0,
    config_validation_failed: usize = 0,
    config_changed_fields: usize = 0,
    config_restart_required_writes: usize = 0,
    config_side_effect_runs: usize = 0,
    config_post_write_hook_runs: usize = 0,
    task_queued: usize = 0,
    task_running: usize = 0,
    task_succeeded: usize = 0,
    task_failed: usize = 0,
    task_cancelled: usize = 0,
    active_tasks: usize = 0,
    queue_depth: usize = 0,
    max_active_tasks: usize = 0,
    max_queue_depth: usize = 0,
    total_task_duration_ms: u64 = 0,
    last_task_duration_ms: u64 = 0,
    task_duration_samples: usize = 0,
    task_results_written: usize = 0,
    flush_count: usize = 0,
};

pub const MetricsObserver = struct {
    snapshot_data: MetricsSnapshot = .{},
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const vtable = Observer.VTable{
        .record = recordErased,
        .flush = flushErased,
    };

    pub fn init() Self {
        return .{};
    }

    pub fn asObserver(self: *Self) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn record(self: *Self, topic: []const u8, payload_json: []const u8) void {
        return self.recordWithPayload(topic, payload_json);
    }

    pub fn recordWithPayload(self: *Self, topic: []const u8, payload_json: []const u8) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        self.snapshot_data.total_events += 1;
        if (std.mem.eql(u8, topic, "command.started")) self.snapshot_data.command_started += 1;
        if (std.mem.eql(u8, topic, "command.completed")) self.snapshot_data.command_completed += 1;
        if (std.mem.eql(u8, topic, "command.failed")) self.snapshot_data.command_failed += 1;
        if (std.mem.eql(u8, topic, "command.accepted")) self.snapshot_data.command_accepted += 1;
        if (std.mem.eql(u8, topic, "command.validation_failed")) self.snapshot_data.validation_failed += 1;
        if (std.mem.eql(u8, topic, "config.changed")) self.snapshot_data.config_changed += 1;
        if (std.mem.eql(u8, topic, "config.validation_failed")) self.snapshot_data.config_validation_failed += 1;

        if (std.mem.startsWith(u8, topic, "command.")) {
            if (extractUnsignedField(payload_json, "durationMs")) |duration_ms| {
                self.snapshot_data.total_request_duration_ms += duration_ms;
                self.snapshot_data.last_request_duration_ms = duration_ms;
                self.snapshot_data.request_duration_samples += 1;
            }
        }

        if (std.mem.eql(u8, topic, "config.changed")) {
            if (extractUnsignedField(payload_json, "changedCount")) |changed_count| {
                self.snapshot_data.config_changed_fields += @intCast(changed_count);
            }
            if (extractUnsignedField(payload_json, "sideEffectCount")) |side_effect_count| {
                self.snapshot_data.config_side_effect_runs += @intCast(side_effect_count);
            }
            if (extractUnsignedField(payload_json, "postWriteHookCount")) |post_write_hook_count| {
                self.snapshot_data.config_post_write_hook_runs += @intCast(post_write_hook_count);
            }
            if (extractBoolField(payload_json, "requiresRestart")) |requires_restart| {
                if (requires_restart) self.snapshot_data.config_restart_required_writes += 1;
            }
        }

        if (std.mem.eql(u8, topic, "task.queued")) {
            self.snapshot_data.task_queued += 1;
            self.snapshot_data.active_tasks += 1;
            self.snapshot_data.queue_depth += 1;
            if (self.snapshot_data.active_tasks > self.snapshot_data.max_active_tasks) {
                self.snapshot_data.max_active_tasks = self.snapshot_data.active_tasks;
            }
            if (self.snapshot_data.queue_depth > self.snapshot_data.max_queue_depth) {
                self.snapshot_data.max_queue_depth = self.snapshot_data.queue_depth;
            }
        }
        if (std.mem.eql(u8, topic, "task.running")) {
            self.snapshot_data.task_running += 1;
            if (self.snapshot_data.queue_depth > 0) self.snapshot_data.queue_depth -= 1;
        }
        if (std.mem.eql(u8, topic, "task.succeeded")) {
            self.snapshot_data.task_succeeded += 1;
            if (self.snapshot_data.active_tasks > 0) self.snapshot_data.active_tasks -= 1;
            if (extractUnsignedField(payload_json, "durationMs")) |duration_ms| {
                self.snapshot_data.total_task_duration_ms += duration_ms;
                self.snapshot_data.last_task_duration_ms = duration_ms;
                self.snapshot_data.task_duration_samples += 1;
            }
            if (std.mem.indexOf(u8, payload_json, "\"result\":") != null) {
                self.snapshot_data.task_results_written += 1;
            }
        }
        if (std.mem.eql(u8, topic, "task.failed")) {
            self.snapshot_data.task_failed += 1;
            if (self.snapshot_data.active_tasks > 0) self.snapshot_data.active_tasks -= 1;
            if (extractUnsignedField(payload_json, "durationMs")) |duration_ms| {
                self.snapshot_data.total_task_duration_ms += duration_ms;
                self.snapshot_data.last_task_duration_ms = duration_ms;
                self.snapshot_data.task_duration_samples += 1;
            }
        }
        if (std.mem.eql(u8, topic, "task.cancelled")) {
            self.snapshot_data.task_cancelled += 1;
            if (self.snapshot_data.active_tasks > 0) self.snapshot_data.active_tasks -= 1;
            if (extractUnsignedField(payload_json, "durationMs")) |duration_ms| {
                self.snapshot_data.total_task_duration_ms += duration_ms;
                self.snapshot_data.last_task_duration_ms = duration_ms;
                self.snapshot_data.task_duration_samples += 1;
            }
        }
    }

    pub fn flush(self: *Self) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        self.snapshot_data.flush_count += 1;
    }

    pub fn snapshot(self: *Self) MetricsSnapshot {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        return self.snapshot_data;
    }

    fn recordErased(ptr: *anyopaque, topic: []const u8, payload_json: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.recordWithPayload(topic, payload_json);
    }

    fn flushErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.flush();
    }
};

fn extractUnsignedField(payload_json: []const u8, key: []const u8) ?u64 {
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, payload_json, marker) orelse return null;
    const index = start + marker.len;
    var end = index;
    while (end < payload_json.len and std.ascii.isDigit(payload_json[end])) : (end += 1) {}
    if (end == index) return null;
    return std.fmt.parseInt(u64, payload_json[index..end], 10) catch null;
}

fn extractBoolField(payload_json: []const u8, key: []const u8) ?bool {
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, payload_json, marker) orelse return null;
    const rest = payload_json[start + marker.len ..];
    if (std.mem.startsWith(u8, rest, "true")) return true;
    if (std.mem.startsWith(u8, rest, "false")) return false;
    return null;
}

test "metrics observer tracks command and task counters" {
    var observer = MetricsObserver.init();
    observer.record("command.started", "{\"durationMs\":2}");
    observer.record("command.completed", "{\"durationMs\":5}");
    observer.record("task.queued", "{}");
    observer.record("task.running", "{}");
    observer.record("task.succeeded", "{\"durationMs\":11,\"result\":{}} ");
    observer.record("config.changed", "{\"changedCount\":3,\"requiresRestart\":true,\"sideEffectCount\":2,\"postWriteHookCount\":1}");
    observer.flush();

    const snapshot = observer.snapshot();
    try std.testing.expectEqual(@as(usize, 6), snapshot.total_events);
    try std.testing.expectEqual(@as(usize, 1), snapshot.command_started);
    try std.testing.expectEqual(@as(usize, 1), snapshot.command_completed);
    try std.testing.expectEqual(@as(usize, 1), snapshot.task_queued);
    try std.testing.expectEqual(@as(usize, 1), snapshot.task_running);
    try std.testing.expectEqual(@as(usize, 1), snapshot.task_succeeded);
    try std.testing.expectEqual(@as(u64, 7), snapshot.total_request_duration_ms);
    try std.testing.expectEqual(@as(u64, 11), snapshot.total_task_duration_ms);
    try std.testing.expectEqual(@as(usize, 0), snapshot.active_tasks);
    try std.testing.expectEqual(@as(usize, 0), snapshot.queue_depth);
    try std.testing.expectEqual(@as(usize, 1), snapshot.max_active_tasks);
    try std.testing.expectEqual(@as(usize, 1), snapshot.max_queue_depth);
    try std.testing.expectEqual(@as(usize, 3), snapshot.config_changed_fields);
    try std.testing.expectEqual(@as(usize, 1), snapshot.config_restart_required_writes);
    try std.testing.expectEqual(@as(usize, 2), snapshot.config_side_effect_runs);
    try std.testing.expectEqual(@as(usize, 1), snapshot.config_post_write_hook_runs);
    try std.testing.expectEqual(@as(usize, 1), snapshot.task_results_written);
    try std.testing.expectEqual(@as(usize, 1), snapshot.flush_count);
}


