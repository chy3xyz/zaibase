const zaibase = @import("zaibase");

pub fn main() !void {
    var sink = zaibase.ConsoleSink.init(.info, .compact);
    var logger = zaibase.Logger.initWithOptions(sink.asLogSink(), .{
        .min_level = .info,
        .redact_mode = .strict,
    });
    defer logger.deinit();

    logger.child("demo").info("redaction demo", &.{
        zaibase.LogField.sensitiveString("project_root", "E:/secret/workspace"),
        zaibase.LogField.string("api_key", "top-secret"),
        zaibase.LogField.string("model", "gpt-5"),
    });
}


