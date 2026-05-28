//! JSONL file sink with optional size-based rotation.

const std = @import("std");
const LogRecord = @import("../record.zig").LogRecord;
const LogSink = @import("../sink.zig").LogSink;

/// Configuration for the file sink.
pub const Config = struct {
    path: []const u8,
    max_bytes: u64 = 8 * 1024 * 1024,
};

/// Writes log records as newline-delimited JSON to a file.
pub const JsonlFile = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    path: []const u8,
    max_bytes: u64,
    written_bytes: u64 = 0,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8, max_bytes: ?u64, io: std.Io) !Self {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        errdefer file.close(io);

        return .{
            .allocator = allocator,
            .file = file,
            .path = path,
            .max_bytes = max_bytes orelse 8 * 1024 * 1024,
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        self.file.close(self.io);
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
        self.writeRecord(record) catch {};
    }

    fn flushErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.file.sync(self.io) catch {};
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn writeRecord(self: *Self, record: LogRecord) !void {
        if (self.written_bytes >= self.max_bytes) {
            self.file.close(self.io);
            self.file = try std.Io.Dir.cwd().createFile(self.io, self.path, .{ .truncate = true });
            self.written_bytes = 0;
        }

        // Build JSON line using fmt.bufPrint
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;

        const header = try std.fmt.bufPrint(buf[pos..], "{{\"ts\":{d},\"level\":\"{s}\",\"subsystem\":\"{s}\",\"message\":\"{s}\"", .{
            record.ts_unix_ms,
            record.level.label(),
            record.subsystem,
            record.message,
        });
        pos += header.len;

        if (record.trace_id) |id| {
            const s = try std.fmt.bufPrint(buf[pos..], ",\"trace_id\":\"{s}\"", .{id});
            pos += s.len;
        }
        if (record.span_id) |id| {
            const s = try std.fmt.bufPrint(buf[pos..], ",\"span_id\":\"{s}\"", .{id});
            pos += s.len;
        }
        if (record.request_id) |id| {
            const s = try std.fmt.bufPrint(buf[pos..], ",\"request_id\":\"{s}\"", .{id});
            pos += s.len;
        }
        if (record.error_code) |code| {
            const s = try std.fmt.bufPrint(buf[pos..], ",\"error_code\":\"{s}\"", .{code});
            pos += s.len;
        }
        if (record.duration_ms) |ms| {
            const s = try std.fmt.bufPrint(buf[pos..], ",\"duration_ms\":{d}", .{ms});
            pos += s.len;
        }

        buf[pos] = '}';
        pos += 1;
        buf[pos] = '\n';
        pos += 1;

        _ = try self.file.writeStreamingAll(self.io, buf[0..pos]);
        self.written_bytes += pos;
    }
};

test "JsonlFile writes valid JSON lines" {
    const io = std.Io.Threaded.global_single_threaded.*.io();
    const path = "/tmp/test_framework_log.jsonl";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var sink = try JsonlFile.init(std.testing.allocator, path, null, io);
    defer sink.deinit();

    const ls = sink.asLogSink();
    ls.write(.{ .ts_unix_ms = 1000, .level = .info, .subsystem = "test", .message = "hello" });
    ls.flush();
}
