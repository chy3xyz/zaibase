const std = @import("std");
const observer_model = @import("observer.zig");

pub const Observer = observer_model.Observer;

pub const MultiObserver = struct {
    allocator: std.mem.Allocator,
    observers: []Observer,
    record_failures: usize = 0,
    flush_failures: usize = 0,

    const Self = @This();

    const vtable = Observer.VTable{
        .record = recordErased,
        .flush = flushErased,
    };

    pub fn init(allocator: std.mem.Allocator, observers: []const Observer) !Self {
        return .{
            .allocator = allocator,
            .observers = try allocator.dupe(Observer, observers),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.observers);
    }

    pub fn asObserver(self: *Self) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn record(self: *Self, topic: []const u8, payload_json: []const u8) void {
        for (self.observers) |observer| {
            observer.record(topic, payload_json);
        }
    }

    pub fn flush(self: *Self) void {
        for (self.observers) |observer| {
            observer.flush();
        }
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

test "multi observer fans out events" {
    var first = observer_model.MemoryObserver.init(std.testing.allocator);
    defer first.deinit();
    var second = observer_model.MemoryObserver.init(std.testing.allocator);
    defer second.deinit();

    var multi = try MultiObserver.init(std.testing.allocator, &.{
        first.asObserver(),
        second.asObserver(),
    });
    defer multi.deinit();

    multi.record("command.completed", "{\"method\":\"app.meta\"}");

    try std.testing.expectEqual(@as(usize, 1), first.count());
    try std.testing.expectEqual(@as(usize, 1), second.count());
}
