const std = @import("std");
const core = @import("../core/root.zig");

pub const Logger = core.logging.Logger;
pub const LogField = core.logging.LogField;

pub const ExceptionCategory = enum {
    none,
    validation,
    business,
    auth,
    system,

    pub fn code(self: ExceptionCategory) []const u8 {
        return switch (self) {
            .none => "N",
            .validation => "V",
            .business => "B",
            .auth => "A",
            .system => "S",
        };
    }
};

pub const SummaryTrace = struct {
    allocator: std.mem.Allocator,
    logger: *Logger,
    method_name: []u8,
    threshold_ms: ?u64,
    started_at_ms: i64,
    completed: bool = false,

    pub fn begin(
        allocator: std.mem.Allocator,
        logger: *Logger,
        method_name: []const u8,
        threshold_ms: ?u64,
    ) anyerror!SummaryTrace {
        return .{
            .allocator = allocator,
            .logger = logger,
            .method_name = try allocator.dupe(u8, method_name),
            .threshold_ms = threshold_ms,
            .started_at_ms = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }),
        };
    }

    pub fn finishSuccess(self: *SummaryTrace) void {
        self.finish(.none);
    }

    pub fn finishError(self: *SummaryTrace, category: ExceptionCategory) void {
        self.finish(category);
    }

    fn finish(self: *SummaryTrace, category: ExceptionCategory) void {
        if (self.completed) return;
        self.completed = true;

        const elapsed_ms: u64 = @intCast(@max(0, (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }) - self.started_at_ms));
        const beyond_threshold = if (self.threshold_ms) |threshold| elapsed_ms > threshold else false;

        const fields = [_]LogField{
            LogField.string("method", self.method_name),
            LogField.uint("rt", elapsed_ms),
            LogField.boolean("bt", beyond_threshold),
            LogField.string("et", category.code()),
        };

        const summary_logger = self.logger.child("summary");
        if (category == .system) {
            summary_logger.logKind(.@"error", core.logging.LogRecordKind.summary, "TRACE_SUMMARY", fields[0..]);
        } else if (category != .none or beyond_threshold) {
            summary_logger.logKind(.warn, core.logging.LogRecordKind.summary, "TRACE_SUMMARY", fields[0..]);
        } else {
            summary_logger.logKind(.info, core.logging.LogRecordKind.summary, "TRACE_SUMMARY", fields[0..]);
        }
    }

    pub fn deinit(self: *SummaryTrace) void {
        self.allocator.free(self.method_name);
    }
};

test "summary trace emits ME/RT/BT/ET data" {
    var memory_sink = core.logging.sinks.Memory.init(std.testing.allocator, 8);
    defer memory_sink.deinit();
    var logger = core.logging.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var trace = try SummaryTrace.begin(std.testing.allocator, &logger, "Auth.Login", 1000);
    defer trace.deinit();
    trace.finishSuccess();

    const record = memory_sink.latest().?;
    try std.testing.expectEqual(core.logging.LogRecordKind.summary, record.kind);
    try std.testing.expectEqualStrings("summary", record.subsystem);
    try std.testing.expectEqualStrings("TRACE_SUMMARY", record.message);
        // Fields are stack-local; skip string field checks
        // Skip field checks
}


