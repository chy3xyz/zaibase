//! Built-in structured logging subsystem — zero external dependencies.

pub const level = @import("level.zig");
pub const field = @import("field.zig");
pub const record = @import("record.zig");
pub const sink = @import("sink.zig");
pub const redact = @import("redact.zig");
pub const logger = @import("logger.zig");

pub const sinks = struct {
    pub const Memory = @import("sinks/memory.zig").Memory;
    pub const Console = @import("sinks/console.zig").Console;
    pub const JsonlFile = @import("sinks/jsonl_file.zig").JsonlFile;
    pub const Multi = @import("sinks/multi.zig").Multi;
    pub const RotatingFile = @import("sinks/rotating_file.zig").RotatingFile;
    pub const TraceTextFile = @import("sinks/trace_text_file.zig").TraceTextFile;
};

// Re-export primary types at module level for ergonomic access.
pub const LogLevel = level.LogLevel;
pub const LogField = field.LogField;
pub const LogFieldValue = field.LogFieldValue;
pub const LogRecord = record.LogRecord;
pub const LogRecordKind = record.LogRecordKind;
pub const LogSink = sink.LogSink;
pub const RedactMode = redact.RedactMode;
pub const Logger = logger.Logger;
pub const LoggerOptions = logger.LoggerOptions;
pub const SubsystemLogger = logger.SubsystemLogger;
pub const TraceContext = logger.TraceContext;
pub const TraceContextProvider = logger.TraceContextProvider;
pub const ConsoleStyle = @import("sinks/console.zig").ConsoleStyle;
pub const RotatingFileSinkConfig = @import("sinks/rotating_file.zig").RotatingFileSinkConfig;
pub const TraceTextFileSinkOptions = @import("sinks/trace_text_file.zig").TraceTextFileSinkOptions;
