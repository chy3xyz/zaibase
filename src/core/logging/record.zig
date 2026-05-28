//! Structured log record.

const LogLevel = @import("level.zig").LogLevel;
const LogField = @import("field.zig").LogField;

/// A structured log event produced by the logger and consumed by sinks.
pub const LogRecord = struct {
    ts_unix_ms: i64,
    level: LogLevel,
    subsystem: []const u8,
    message: []const u8,
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    kind: LogRecordKind = .plain,
    fields: []const LogField = &.{},
};

/// Discriminator for record rendering.
pub const LogRecordKind = enum {
    plain,
    request,
    summary,
    method,
    step,
};
