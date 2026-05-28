const std = @import("std");
const zaibase = @import("zaibase");

pub fn main() !void {
    var console_sink = zaibase.ConsoleSink.init(.trace, .pretty);
    var logger = zaibase.Logger.init(console_sink.asLogSink(), .trace);

    logger.child("zigf_api").info("🚀 Starting BF API - Zig BaseFramework", &.{});

    var request_trace = try zaibase.observability.request_trace.begin(
        std.heap.page_allocator,
        &logger,
        .http,
        "req_demo_02",
        "POST",
        "/api/auth/login",
        null,
    );
    defer request_trace.deinit();

    var controller = try zaibase.observability.MethodTrace.begin(
        std.heap.page_allocator,
        &logger,
        "Controller.Auth.Login",
        "{\"userName\":\"admin\",\"password\":\"***\"}",
        500,
    );
    defer controller.deinit();

    var repository_exists = try zaibase.observability.MethodTrace.begin(
        std.heap.page_allocator,
        &logger,
        "Repository.UserRepository.ExistsAndEnabledAsync",
        "{\"loginId\":\"admin\"}",
        100,
    );
    defer repository_exists.deinit();
    repository_exists.finishSuccess("True", true);

    var repository_get = try zaibase.observability.MethodTrace.begin(
        std.heap.page_allocator,
        &logger,
        "Repository.UserRepository.GetByLoginIdAsync",
        "{\"loginId\":\"admin\"}",
        100,
    );
    defer repository_get.deinit();
    repository_get.finishSuccess("SYS_UserInfo", true);

    controller.finishSuccess("Ok(200)", false);
    zaibase.observability.request_trace.complete(&logger, &request_trace, 200, null);
}


