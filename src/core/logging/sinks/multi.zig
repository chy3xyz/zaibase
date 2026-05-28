//! Fan-out sink that forwards records to multiple child sinks.
//! Owns a copy of the sink slice so callers can free their source.

const std = @import("std");
const LogRecord = @import("../record.zig").LogRecord;
const LogSink = @import("../sink.zig").LogSink;

/// Writes each record to all registered child sinks.
pub const Multi = struct {
    allocator: std.mem.Allocator,
    sinks: []LogSink,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sink_slice: []LogSink) !Self {
        return .{
            .allocator = allocator,
            .sinks = try allocator.dupe(LogSink, sink_slice),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sinks);
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

    fn writeErased(ptr: *anyopaque, record: LogRecord) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        for (self.sinks) |sink| {
            sink.write(record);
        }
    }

    fn flushErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        for (self.sinks) |sink| {
            sink.flush();
        }
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

test "Multi fans out to children" {
    var mem1 = @import("memory.zig").Memory.init(std.testing.allocator, 8);
    defer mem1.deinit();
    var mem2 = @import("memory.zig").Memory.init(std.testing.allocator, 8);
    defer mem2.deinit();

    var sinks = [_]LogSink{ mem1.asLogSink(), mem2.asLogSink() };
    var multi = try Multi.init(std.testing.allocator, &sinks);
    defer multi.deinit();
    const ls = multi.asLogSink();

    ls.write(.{ .ts_unix_ms = 1, .level = .info, .subsystem = "t", .message = "x" });

    try std.testing.expectEqual(@as(usize, 1), mem1.drain().len);
    try std.testing.expectEqual(@as(usize, 1), mem2.drain().len);
}
