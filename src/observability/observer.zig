const std = @import("std");

pub const ObservedEvent = struct {
    topic: []u8,
    ts_unix_ms: i64,
    payload_json: []u8,

    pub fn clone(self: ObservedEvent, allocator: std.mem.Allocator) (CloneError || error{OutOfMemory})!ObservedEvent {
        return .{
            .topic = try allocator.dupe(u8, self.topic),
            .ts_unix_ms = self.ts_unix_ms,
            .payload_json = try allocator.dupe(u8, self.payload_json),
        };
    }

    pub const CloneError = std.mem.Allocator.Error;

    pub fn deinit(self: *ObservedEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.topic);
        allocator.free(self.payload_json);
    }
};

pub const Observer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        record: *const fn (ptr: *anyopaque, topic: []const u8, payload_json: []const u8) void,
        flush: *const fn (ptr: *anyopaque) void,
    };

    pub fn record(self: Observer, topic: []const u8, payload_json: []const u8) void {
        self.vtable.record(self.ptr, topic, payload_json);
    }

    pub fn flush(self: Observer) void {
        self.vtable.flush(self.ptr);
    }
};

pub const MemoryObserver = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(ObservedEvent) = .empty,
    flush_count: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const vtable = Observer.VTable{
        .record = recordErased,
        .flush = flushErased,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        for (self.events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);
    }

    pub fn asObserver(self: *Self) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn record(self: *Self, topic: []const u8, payload_json: []const u8) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        self.events.append(self.allocator, .{
            .topic = self.allocator.dupe(u8, topic) catch return,
            .ts_unix_ms = (blk: {
                const io = std.Io.Threaded.global_single_threaded.*.io();
                break :blk std.Io.Timestamp.now(io, .real).toMilliseconds();
            }),
            .payload_json = self.allocator.dupe(u8, payload_json) catch return,
        }) catch {};
    }

    pub fn flush(self: *Self) void {
        self.flush_count += 1;
    }

    pub fn snapshot(self: *Self, allocator: std.mem.Allocator) ![]ObservedEvent {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const events = try allocator.alloc(ObservedEvent, self.events.items.len);
        errdefer allocator.free(events);

        for (self.events.items, 0..) |event, index| {
            events[index] = try event.clone(allocator);
        }

        return events;
    }

    pub fn count(self: *const Self) usize {
        return self.events.items.len;
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

test "memory observer records and snapshots events" {
    var observer = MemoryObserver.init(std.testing.allocator);
    defer observer.deinit();

    observer.record("command.started", "{\"method\":\"app.meta\"}");
    observer.flush();

    const events = try observer.snapshot(std.testing.allocator);
    defer {
        for (events) |*event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(usize, 1), observer.flush_count);
    try std.testing.expectEqualStrings("command.started", events[0].topic);
}
