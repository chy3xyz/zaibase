const std = @import("std");
const observer_model = @import("observer.zig");
const logging = @import("../core/logging/root.zig");

pub const Observer = observer_model.Observer;
pub const Logger = logging.Logger;
pub const LogField = logging.LogField;

pub const LogObserver = struct {
    logger: *Logger,
    subsystem_storage: [96]u8 = undefined,
    subsystem_len: usize = 0,
    record_count: usize = 0,
    flush_count: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const vtable = Observer.VTable{
        .record = recordErased,
        .flush = flushErased,
    };

    pub fn init(logger: *Logger, subsystem_name: []const u8) Self {
        var self = Self{ .logger = logger };
        self.setSubsystem(subsystem_name);
        return self;
    }

    pub fn asObserver(self: *Self) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn record(self: *Self, topic: []const u8, payload_json: []const u8) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        self.record_count += 1;
        self.mutex.unlock();
        self.logger.child(self.subsystem()).info("observer event", &.{
            LogField.string("topic", topic),
            LogField.string("payload_json", payload_json),
        });
    }

    pub fn flush(self: *Self) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        self.flush_count += 1;
        self.mutex.unlock();
        self.logger.flush();
    }

    pub fn subsystem(self: *const Self) []const u8 {
        return self.subsystem_storage[0..self.subsystem_len];
    }

    fn setSubsystem(self: *Self, subsystem_name: []const u8) void {
        const copy_len = @min(self.subsystem_storage.len, subsystem_name.len);
        @memcpy(self.subsystem_storage[0..copy_len], subsystem_name[0..copy_len]);
        self.subsystem_len = copy_len;
    }

    fn recordErased(ptr: *anyopaque, topic: []const u8, payload_json: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.record(topic, payload_json);
    }

    fn flushErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.flush();
    }
};

test "log observer bridges observer events into logger" {
    const memory_sink_model = @import("../core/logging/root.zig");

    var sink = memory_sink_model.sinks.Memory.init(std.testing.allocator, 4);
    defer sink.deinit();
    var logger = Logger.init(sink.asLogSink(), .info);
    defer logger.deinit();

    var observer = LogObserver.init(&logger, "observer");
    observer.record("command.started", "{\"method\":\"app.meta\"}");
    observer.flush();

    try std.testing.expectEqual(@as(usize, 1), observer.record_count);
    try std.testing.expectEqual(@as(usize, 1), observer.flush_count);
    try std.testing.expectEqualStrings("observer", sink.latest().?.subsystem);
    try std.testing.expectEqualStrings("observer event", sink.latest().?.message);
}
