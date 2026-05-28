//! Human-friendly text file sink for trace/debugging — grep-friendly output.

const std = @import("std");
const LogRecord = @import("../record.zig").LogRecord;
const LogSink = @import("../sink.zig").LogSink;

/// Options for the trace text file sink.
pub const TraceTextFileSinkOptions = struct {
    path: []const u8,
    max_bytes: u64 = 4 * 1024 * 1024,
};

/// Writes log records as human-readable text lines.
pub const TraceTextFile = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    path: []const u8,
    max_bytes: u64,
    written_bytes: u64 = 0,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, opts: TraceTextFileSinkOptions, io: std.Io) !Self {
        const file = try std.Io.Dir.cwd().createFile(io, opts.path, .{ .truncate = false });
        errdefer file.close(io);

        return .{
            .allocator = allocator,
            .file = file,
            .path = opts.path,
            .max_bytes = opts.max_bytes,
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

        var buf: [8192]u8 = undefined;
        var pos: usize = 0;

        const ts_sec: u64 = @intCast(@divTrunc(record.ts_unix_ms, 1000));
        const ts_ms: u64 = @intCast(@mod(record.ts_unix_ms, 1000));
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts_sec };
        const day_seconds = epoch_seconds.getDaySeconds();
        const hours = day_seconds.getHoursIntoDay();
        const minutes = day_seconds.getMinutesIntoHour();
        const seconds = day_seconds.getSecondsIntoMinute();

        const header = try std.fmt.bufPrint(buf[pos..], "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} [{s}] {s}: {s}", .{
            hours, minutes, seconds, ts_ms,
            record.level.label(),
            record.subsystem,
            record.message,
        });
        pos += header.len;

        if (record.trace_id) |id| {
            const s = try std.fmt.bufPrint(buf[pos..], " | trace={s}", .{id});
            pos += s.len;
        }
        if (record.request_id) |id| {
            const s = try std.fmt.bufPrint(buf[pos..], " | req={s}", .{id});
            pos += s.len;
        }
        if (record.duration_ms) |ms| {
            const s = try std.fmt.bufPrint(buf[pos..], " | {d}ms", .{ms});
            pos += s.len;
        }

        for (record.fields) |field| {
            const s = switch (field.value) {
                .string => |v| try std.fmt.bufPrint(buf[pos..], " | {s}={s}", .{ field.key, v }),
                .int => |v| try std.fmt.bufPrint(buf[pos..], " | {s}={d}", .{ field.key, v }),
                .uint => |v| try std.fmt.bufPrint(buf[pos..], " | {s}={d}", .{ field.key, v }),
                .float => |v| try std.fmt.bufPrint(buf[pos..], " | {s}={d:.3}", .{ field.key, v }),
                .boolean => |v| try std.fmt.bufPrint(buf[pos..], " | {s}={s}", .{ field.key, if (v) "true" else "false" }),
                .err => |v| try std.fmt.bufPrint(buf[pos..], " | {s}={s}", .{ field.key, @errorName(v) }),
                .null => try std.fmt.bufPrint(buf[pos..], " | {s}=null", .{field.key}),
            };
            pos += s.len;
        }

        buf[pos] = '\n';
        pos += 1;

        _ = try self.file.writeStreamingAll(self.io, buf[0..pos]);
        self.written_bytes += pos;
    }
};

test "TraceTextFile writes readable lines" {
    const io = std.Io.Threaded.global_single_threaded.*.io();
    const path = "/tmp/test_framework_trace.txt";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var sink = try TraceTextFile.init(std.testing.allocator, .{ .path = path }, io);
    defer sink.deinit();

    const ls = sink.asLogSink();
    ls.write(.{ .ts_unix_ms = 1000, .level = .info, .subsystem = "test", .message = "trace line" });
    ls.flush();
}
