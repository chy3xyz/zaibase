//! In-memory sink for testing and runtime buffering.

const std = @import("std");
const LogRecord = @import("../record.zig").LogRecord;
const LogSink = @import("../sink.zig").LogSink;

/// Ring-buffer sink that stores the last N records in memory.
pub const Memory = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(LogRecord),
    capacity: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
        return .{
            .allocator = allocator,
            .records = .empty,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *Self) void {
        self.records.deinit(self.allocator);
    }

    pub fn asLogSink(self: *Self) LogSink {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .write = writeErased,
                .flush = flushErased,
                .deinit = deinitErased,
            },
        };
    }

    pub fn drain(self: *Self) []LogRecord {
        return self.records.items;
    }

    pub fn latest(self: *const Self) ?LogRecord {
        if (self.records.items.len == 0) return null;
        return self.records.items[self.records.items.len - 1];
    }

    pub fn snapshot(self: *const Self) []const LogRecord {
        return self.records.items;
    }

    pub fn count(self: *const Self) usize {
        return self.records.items.len;
    }

    pub fn recordAt(self: *const Self, index: usize) ?LogRecord {
        if (index >= self.records.items.len) return null;
        return self.records.items[index];
    }

    fn writeErased(ptr: *anyopaque, record: LogRecord) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.records.items.len >= self.capacity) {
            _ = self.records.orderedRemove(0);
        }
        self.records.append(self.allocator, record) catch {};
    }

    fn flushErased(_: *anyopaque) void {}

    fn deinitErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

test "Memory sink stores and drains" {
    var sink = Memory.init(std.testing.allocator, 4);
    defer sink.deinit();

    const ls = sink.asLogSink();
    ls.write(.{ .ts_unix_ms = 1, .level = .info, .subsystem = "test", .message = "hello" });
    ls.write(.{ .ts_unix_ms = 2, .level = .err, .subsystem = "test", .message = "fail" });

    try std.testing.expectEqual(@as(usize, 2), sink.drain().len);
    try std.testing.expectEqualStrings("hello", sink.drain()[0].message);
}

test "Memory sink drops oldest when full" {
    var sink = Memory.init(std.testing.allocator, 2);
    defer sink.deinit();

    const ls = sink.asLogSink();
    ls.write(.{ .ts_unix_ms = 1, .level = .info, .subsystem = "t", .message = "a" });
    ls.write(.{ .ts_unix_ms = 2, .level = .info, .subsystem = "t", .message = "b" });
    ls.write(.{ .ts_unix_ms = 3, .level = .info, .subsystem = "t", .message = "c" });

    try std.testing.expectEqual(@as(usize, 2), sink.drain().len);
    try std.testing.expectEqualStrings("b", sink.drain()[0].message);
    try std.testing.expectEqualStrings("c", sink.drain()[1].message);
}
