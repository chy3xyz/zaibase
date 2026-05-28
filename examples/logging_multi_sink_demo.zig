const std = @import("std");
const zaibase = @import("zaibase");

pub fn main() !void {
    var memory = zaibase.MemorySink.init(std.heap.page_allocator, 8);
    defer memory.deinit();

    var console = zaibase.ConsoleSink.init(.trace, .pretty);
    var sink_list = [_]zaibase.LogSink{ memory.asLogSink(), console.asLogSink() };
    var multi = try zaibase.MultiSink.init(std.heap.page_allocator, &sink_list);
    defer multi.deinit();

    var logger = zaibase.Logger.init(multi.asLogSink(), .trace);
    defer logger.deinit();

    logger.child("demo").info("multi sink", &.{
        zaibase.LogField.string("sink_count", "2"),
    });
}
