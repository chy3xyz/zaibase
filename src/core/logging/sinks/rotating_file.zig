//! Rotating file sink — JSONL output with size-based rotation and max file count.

const std = @import("std");
const LogRecord = @import("../record.zig").LogRecord;
const LogSink = @import("../sink.zig").LogSink;

/// Configuration for rotating file behavior.
pub const RotatingFileSinkConfig = struct {
    path: []const u8,
    max_bytes: u64 = 8 * 1024 * 1024,
    max_files: u32 = 3,
};

/// JSONL file sink with automatic rotation when size limit is reached.
pub const RotatingFile = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    path: []const u8,
    max_bytes: u64,
    max_files: u32,
    written_bytes: u64 = 0,
    current_index: u32 = 0,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: RotatingFileSinkConfig, io: std.Io) !Self {
        const file = try std.Io.Dir.cwd().createFile(io, config.path, .{ .truncate = false });
        errdefer file.close(io);

        return .{
            .allocator = allocator,
            .file = file,
            .path = config.path,
            .max_bytes = config.max_bytes,
            .max_files = config.max_files,
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

    fn rotate(self: *Self) !void {
        self.file.close(self.io);
        self.current_index = (self.current_index + 1) % self.max_files;

        var path_buf: [512]u8 = undefined;
        const rotated = std.fmt.bufPrint(&path_buf, "{s}.{d}", .{ self.path, self.current_index }) catch self.path;

        const cwd = std.Io.Dir.cwd();
        cwd.rename(self.path, cwd, rotated, self.io) catch {};

        self.file = try cwd.createFile(self.io, self.path, .{ .truncate = true });
        self.written_bytes = 0;
    }

    fn writeRecord(self: *Self, record: LogRecord) !void {
        if (self.written_bytes >= self.max_bytes) {
            try self.rotate();
        }

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

test "RotatingFile writes and rotates" {
    const io = std.Io.Threaded.global_single_threaded.*.io();
    const path = "/tmp/test_framework_rotating.jsonl";
    defer {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        std.Io.Dir.cwd().deleteFile(io, path ++ ".0") catch {};
        std.Io.Dir.cwd().deleteFile(io, path ++ ".1") catch {};
    }

    var sink = try RotatingFile.init(std.testing.allocator, .{
        .path = path,
        .max_bytes = 200,
        .max_files = 2,
    }, io);
    defer sink.deinit();

    const ls = sink.asLogSink();
    for (0..10) |i| {
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "message {d}", .{i}) catch "msg";
        ls.write(.{ .ts_unix_ms = @intCast(i), .level = .info, .subsystem = "test", .message = msg });
    }
    ls.flush();
}
