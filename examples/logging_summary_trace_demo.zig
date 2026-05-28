const std = @import("std");
const zaibase = @import("zaibase");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.*.io();
    var file_sink = try zaibase.TraceTextFileSink.init(
        std.heap.page_allocator,
        .{ .path = "/tmp/zaibase-summary-trace.log", .max_bytes = 1024 * 1024 },
        io,
    );
    var console_sink = zaibase.ConsoleSink.init(.trace, .pretty);

    var sinks = [_]zaibase.LogSink{ console_sink.asLogSink(), file_sink.asLogSink() };
    var multi = try zaibase.MultiSink.init(std.heap.page_allocator, &sinks);
    var logger = zaibase.Logger.init(multi.asLogSink(), .trace);
    defer logger.deinit();

    var trace = try zaibase.SummaryTrace.begin(std.heap.page_allocator, &logger, "Auth.Login", 1000);
    defer trace.deinit();
    trace.finishSuccess();

    logger.child("demo").info("summary trace written", &.{
        zaibase.LogField.string("method", "Auth.Login"),
        zaibase.LogField.boolean("completed", true),
    });
}
