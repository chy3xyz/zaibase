const zaibase = @import("zaibase");

pub fn main() !void {
    var sink = zaibase.ConsoleSink.init(.debug, .compact);
    var logger = zaibase.Logger.init(sink.asLogSink(), .debug);
    defer logger.deinit();

    logger.child("demo").info("basic log", &.{
        zaibase.LogField.string("mode", "basic"),
        zaibase.LogField.boolean("ok", true),
    });
}


