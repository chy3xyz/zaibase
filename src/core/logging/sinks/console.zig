//! Console sink with pretty and compact rendering styles.

const std = @import("std");
const LogLevel = @import("../level.zig").LogLevel;
const LogRecord = @import("../record.zig").LogRecord;
const LogSink = @import("../sink.zig").LogSink;

/// Console output style.
pub const ConsoleStyle = enum {
    pretty,
    compact,
};

/// Writes log records to stderr.
pub const Console = struct {
    min_level: LogLevel,
    style: ConsoleStyle,
    io: std.Io,

    const Self = @This();

    pub fn init(min_level: LogLevel, style: ConsoleStyle) Self {
        return .{
            .min_level = min_level,
            .style = style,
            .io = std.Io.Threaded.global_single_threaded.*.io(),
        };
    }

    pub fn initWithIo(min_level: LogLevel, style: ConsoleStyle, io: std.Io) Self {
        return .{ .min_level = min_level, .style = style, .io = io };
    }

    pub fn deinit(_: *Self) void {}

    pub fn asLogSink(self: *Self) LogSink {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .write = writeErased,
                .flush = flushErased,
            },
        };
    }

    fn writeErased(ptr: *anyopaque, record: LogRecord) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!record.level.enabled(self.min_level)) return;

        var buf: [4096]u8 = undefined;
        const line = switch (self.style) {
            .pretty => formatPretty(&buf, record) catch return,
            .compact => formatCompact(&buf, record) catch return,
        };

        const stderr = std.Io.File.stderr();
        _ = stderr.writeStreamingAll(self.io, line) catch return;
    }

    fn flushErased(_: *anyopaque) void {}

    fn formatPretty(buf: []u8, record: LogRecord) ![]u8 {
        var pos: usize = 0;

        const ts_sec: u64 = @intCast(@divTrunc(record.ts_unix_ms, 1000));
        const ts_ms: u64 = @intCast(@mod(record.ts_unix_ms, 1000));
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts_sec };
        const day_seconds = epoch_seconds.getDaySeconds();
        const hours = day_seconds.getHoursIntoDay();
        const minutes = day_seconds.getMinutesIntoHour();
        const seconds = day_seconds.getSecondsIntoMinute();

        const header = try std.fmt.bufPrint(buf[pos..], "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s} {s}: {s}", .{
            hours, minutes, seconds, ts_ms,
            record.level.label(),
            record.subsystem,
            record.message,
        });
        pos += header.len;

        if (record.trace_id) |id| {
            const s = try std.fmt.bufPrint(buf[pos..], " trace_id={s}", .{id});
            pos += s.len;
        }
        if (record.request_id) |id| {
            const s = try std.fmt.bufPrint(buf[pos..], " request_id={s}", .{id});
            pos += s.len;
        }

        for (record.fields) |field| {
            const s = switch (field.value) {
                .string => |v| try std.fmt.bufPrint(buf[pos..], " {s}={s}", .{ field.key, v }),
                .int => |v| try std.fmt.bufPrint(buf[pos..], " {s}={d}", .{ field.key, v }),
                .uint => |v| try std.fmt.bufPrint(buf[pos..], " {s}={d}", .{ field.key, v }),
                .float => |v| try std.fmt.bufPrint(buf[pos..], " {s}={d:.3}", .{ field.key, v }),
                .boolean => |v| try std.fmt.bufPrint(buf[pos..], " {s}={s}", .{ field.key, if (v) "true" else "false" }),
                .err => |v| try std.fmt.bufPrint(buf[pos..], " {s}={s}", .{ field.key, @errorName(v) }),
                .null => try std.fmt.bufPrint(buf[pos..], " {s}=null", .{field.key}),
            };
            pos += s.len;
        }

        buf[pos] = '\n';
        pos += 1;

        return buf[0..pos];
    }

    fn formatCompact(buf: []u8, record: LogRecord) ![]u8 {
        const level_char: u8 = switch (record.level) {
            .trace => 'T',
            .debug => 'D',
            .info => 'I',
            .warn => 'W',
            .err => 'E',
            .fatal => 'F',
            .silent => 'S',
        };
        const ts_sec: u64 = @intCast(@divTrunc(record.ts_unix_ms, 1000));
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts_sec };
        const day_seconds = epoch_seconds.getDaySeconds();
        const seconds = day_seconds.getSecondsIntoMinute();

        const line = try std.fmt.bufPrint(buf, "{d:0>2} {c} {s}: {s}\n", .{
            seconds,
            level_char,
            record.subsystem,
            record.message,
        });
        return line;
    }
};

test "Console sink writes without panic" {
    var sink = Console.init(.info, .compact);
    const ls = sink.asLogSink();
    ls.write(.{ .ts_unix_ms = 1000, .level = .info, .subsystem = "test", .message = "ok" });
    ls.write(.{ .ts_unix_ms = 1000, .level = .debug, .subsystem = "test", .message = "filtered" });
}
