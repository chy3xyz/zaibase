const std = @import("std");
const zaibase = @import("zaibase");

pub fn main() !void {
    var sink = try zaibase.TraceTextFileSink.init(
        std.heap.page_allocator,
        "logs/summary-trace-demo.log",
        1024 * 1024,
        .{},
    );
    defer sink.deinit();

    var logger = zaibase.Logger.init(sink.asLogSink(), .debug);
    defer logger.deinit();

    var request_trace = try zaibase.observability.request_trace.begin(
        std.heap.page_allocator,
        &logger,
        .cli,
        "req_demo_summary",
        "POST",
        "demo.summary",
        null,
    );
    defer request_trace.deinit();

    var controller_trace = try zaibase.MethodTrace.begin(
        std.heap.page_allocator,
        &logger,
        "Controller.Auth.Login",
        "{\"userName\":\"admin\",\"password\":\"***\"}",
        500,
    );
    defer controller_trace.deinit();

    var controller_summary = try zaibase.SummaryTrace.begin(
        std.heap.page_allocator,
        &logger,
        "Controller.Auth.Login",
        500,
    );
    defer controller_summary.deinit();

    var repository_trace = try zaibase.MethodTrace.begin(
        std.heap.page_allocator,
        &logger,
        "Repository.UserRepository.GetByLoginIdAsync",
        "{\"loginId\":\"admin\"}",
        100,
    );
    defer repository_trace.deinit();
    repository_trace.finishSuccess("SYS_UserInfo", true);

    var repository_summary = try zaibase.SummaryTrace.begin(
        std.heap.page_allocator,
        &logger,
        "Repository.UserRepository.GetByLoginIdAsync",
        100,
    );
    defer repository_summary.deinit();
    repository_summary.finishSuccess();

    controller_trace.finishSuccess("Ok(200)", false);
    controller_summary.finishSuccess();
    zaibase.observability.request_trace.complete(&logger, &request_trace, 200, null);
}


