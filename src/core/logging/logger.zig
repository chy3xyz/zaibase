//! Logger — the primary API for emitting structured log records.

const std = @import("std");
const LogLevel = @import("level.zig").LogLevel;
const LogField = @import("field.zig").LogField;
const LogRecord = @import("record.zig").LogRecord;
const LogRecordKind = @import("record.zig").LogRecordKind;
const LogSink = @import("sink.zig").LogSink;

/// Provides trace context (trace_id, span_id, request_id) to log records.
pub const TraceContext = struct {
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

/// Thread-local provider for trace context.
pub const TraceContextProvider = struct {
    ptr: *anyopaque,
    get_fn: *const fn (ptr: *anyopaque) ?TraceContext,

    pub fn get(self: TraceContextProvider) ?TraceContext {
        return self.get_fn(self.ptr);
    }

    pub fn getCurrent(self: TraceContextProvider) TraceContext {
        return self.get() orelse .{};
    }

    pub const current = getCurrent;
};

/// Logger options for construction.
pub const LoggerOptions = struct {
    level: LogLevel = .info,
};

/// The core logger. Owns a sink reference and a minimum level filter.
pub const Logger = struct {
    sink: LogSink,
    min_level: LogLevel,
    trace_context_provider: ?TraceContextProvider = null,

    const Self = @This();

    pub fn init(sink: LogSink, min_level: LogLevel) Self {
        return .{ .sink = sink, .min_level = min_level };
    }

    pub fn deinit(self: *Self) void {
        self.sink.flush();
    }

    pub fn flush(self: *Self) void {
        self.sink.flush();
    }

    /// Create a child subsystem logger that prepends a subsystem prefix.
    pub fn child(self: *Self, subsystem: []const u8) SubsystemLogger {
        return .{ .logger = self, .subsystem = subsystem, .extra_fields = &.{} };
    }

    /// Log at a specific level with message and optional fields.
    pub fn log(self: *Self, level: LogLevel, subsystem: []const u8, message: []const u8, fields: []const LogField) void {
        self.logWithKind(level, subsystem, message, .plain, fields);
    }

    /// Log with an explicit record kind.
    pub fn logWithKind(self: *Self, level: LogLevel, subsystem: []const u8, message: []const u8, kind: LogRecordKind, fields: []const LogField) void {
        if (!level.enabled(self.min_level)) return;

        const ts = blk: {
            const io = std.Io.Threaded.global_single_threaded.*.io();
            break :blk std.Io.Timestamp.now(io, .real).toMilliseconds();
        };

        var trace_id: ?[]const u8 = null;
        var span_id: ?[]const u8 = null;
        var request_id: ?[]const u8 = null;
        if (self.trace_context_provider) |p| {
            if (p.get()) |ctx| {
                trace_id = ctx.trace_id;
                span_id = ctx.span_id;
                request_id = ctx.request_id;
            }
        }

        self.sink.write(.{
            .ts_unix_ms = ts,
            .level = level,
            .subsystem = subsystem,
            .message = message,
            .trace_id = trace_id,
            .span_id = span_id,
            .request_id = request_id,
            .kind = kind,
            .fields = fields,
        });
    }

    /// Convenience methods.
    pub fn info(self: *Self, message: []const u8, fields: []const LogField) void {
        self.log(.info, "", message, fields);
    }

    pub fn warn(self: *Self, message: []const u8, fields: []const LogField) void {
        self.log(.warn, "", message, fields);
    }

    pub fn err(self: *Self, message: []const u8, fields: []const LogField) void {
        self.log(.err, "", message, fields);
    }

    pub fn debug(self: *Self, message: []const u8, fields: []const LogField) void {
        self.log(.debug, "", message, fields);
    }
};

/// A subsystem-scoped logger that prepends a fixed subsystem prefix.
pub const SubsystemLogger = struct {
    logger: *Logger,
    subsystem: []const u8,
    extra_fields: []const LogField = &.{},

    const ChildSelf = @This();

    pub fn child(self: ChildSelf, sub: []const u8) ChildSelf {
        // Combine subsystem segments with '/'.
        // Use a thread-local buffer to build "parent/child" prefix.
        const combined = combineSubsystem(self.subsystem, sub);
        return .{
            .logger = self.logger,
            .subsystem = combined,
            .extra_fields = self.extra_fields,
        };
    }

    fn combineSubsystem(parent: []const u8, child_name: []const u8) []const u8 {
        const S = struct {
            threadlocal var storage: [256]u8 = undefined;
        };
        if (parent.len == 0) return child_name;
        const total = parent.len + 1 + child_name.len;
        if (total > S.storage.len) return child_name;
        // If parent already points into our TLS buffer, don't copy from self.
        if (@intFromPtr(parent.ptr) == @intFromPtr(&S.storage)) {
            S.storage[parent.len] = '/';
            @memcpy(S.storage[parent.len + 1 .. total], child_name);
        } else {
            @memcpy(S.storage[0..parent.len], parent);
            S.storage[parent.len] = '/';
            @memcpy(S.storage[parent.len + 1 .. total], child_name);
        }
        return S.storage[0..total];
    }

    pub fn withField(self: ChildSelf, _: LogField) ChildSelf {
        return .{
            .logger = self.logger,
            .subsystem = self.subsystem,
            .extra_fields = self.extra_fields,
        };
    }

    pub fn log(self: ChildSelf, level: LogLevel, message: []const u8, fields: []const LogField) void {
        self.logger.log(level, self.subsystem, message, fields);
    }

    /// Log with an explicit record kind (for trace types).
    pub fn logKind(self: ChildSelf, level: LogLevel, kind: LogRecordKind, message: []const u8, fields: []const LogField) void {
        self.logger.logWithKind(level, self.subsystem, message, kind, fields);
    }

    pub fn info(self: ChildSelf, message: []const u8, fields: []const LogField) void {
        self.log(.info, message, fields);
    }

    pub fn warn(self: ChildSelf, message: []const u8, fields: []const LogField) void {
        self.log(.warn, message, fields);
    }

    pub fn err(self: ChildSelf, message: []const u8, fields: []const LogField) void {
        self.log(.err, message, fields);
    }

    pub fn debug(self: ChildSelf, message: []const u8, fields: []const LogField) void {
        self.log(.debug, message, fields);
    }

    pub fn @"error"(self: ChildSelf, message: []const u8, fields: []const LogField) void {
        self.log(.err, message, fields);
    }
};

test "Logger filters by level" {
    const MemorySink = @import("sinks/memory.zig").Memory;
    var mem = MemorySink.init(std.testing.allocator, 16);
    defer mem.deinit();

    var logger = Logger.init(mem.asLogSink(), .warn);
    defer logger.deinit();

    logger.info("should be filtered", &.{});
    logger.warn("should pass", &.{});
    logger.err("also passes", &.{});

    try std.testing.expectEqual(@as(usize, 2), mem.drain().len);
    try std.testing.expectEqualStrings("should pass", mem.drain()[0].message);
    try std.testing.expectEqualStrings("also passes", mem.drain()[1].message);
}

test "SubsystemLogger scopes subsystem" {
    const MemorySink = @import("sinks/memory.zig").Memory;
    var mem = MemorySink.init(std.testing.allocator, 16);
    defer mem.deinit();

    var logger = Logger.init(mem.asLogSink(), .debug);
    defer logger.deinit();

    const sub = logger.child("myapp");
    sub.info("hello", &.{});

    try std.testing.expectEqual(@as(usize, 1), mem.drain().len);
    try std.testing.expectEqualStrings("myapp", mem.drain()[0].subsystem);
    try std.testing.expectEqualStrings("hello", mem.drain()[0].message);
}
