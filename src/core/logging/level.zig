//! Log level definitions and comparison.

const std = @import("std");

/// Standard log levels ordered from most verbose to most severe.
pub const LogLevel = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,
    silent = 6,

    /// Returns true if `self` is at least as severe as `min_level`.
    /// Alias for `.err` — matches the `error` keyword style used in some call sites.
    pub const @"error" = LogLevel.err;

    pub fn enabled(self: LogLevel, min_level: LogLevel) bool {
        return @intFromEnum(self) >= @intFromEnum(min_level);
    }

    /// Short uppercase label for console rendering.
    pub fn label(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
            .fatal => "FATAL",
            .silent => "SILENT",
        };
    }

    /// Parse a level name (case-insensitive).
    pub fn parse(text: []const u8) ?LogLevel {
        const map = std.StaticStringMap(LogLevel).initComptime(.{
            .{ "trace", .trace },
            .{ "debug", .debug },
            .{ "info", .info },
            .{ "warn", .warn },
            .{ "warning", .warn },
            .{ "error", .err },
            .{ "err", .err },
            .{ "fatal", .fatal },
            .{ "silent", .silent },
            .{ "off", .silent },
        });
        var buf: [16]u8 = undefined;
        if (text.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, text);
        return map.get(lower);
    }
};

test "LogLevel.enabled" {
    try std.testing.expect(LogLevel.warn.enabled(.info));
    try std.testing.expect(!LogLevel.debug.enabled(.info));
    try std.testing.expect(LogLevel.err.enabled(.err));
}

test "LogLevel.parse" {
    try std.testing.expectEqual(LogLevel.info, LogLevel.parse("INFO"));
    try std.testing.expectEqual(LogLevel.warn, LogLevel.parse("warning"));
    try std.testing.expectEqual(null, LogLevel.parse("unknown"));
}
