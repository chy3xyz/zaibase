const std = @import("std");
const zaibase = @import("zaibase");
const ourclaw = @import("ourclaw");

pub fn main() !void {
    var app = try ourclaw.runtime.AppContext.init(std.heap.page_allocator, .{});
    defer app.destroy();

    app.framework_context.logger.min_level = .trace;
    if (app.framework_context.console_sink) |sink| {
        sink.min_level = .trace;
    }

    app.framework_context.logger.child("zigf_api").info("🚀 Starting BF API - Zig BaseFramework", &.{});
    app.framework_context.logger.child("zigf_api").info("📋 Loading configuration...", &.{});
    app.framework_context.logger.child("zigf_api").child("config").info("Configuration loaded successfully", &.{
        zaibase.LogField.string("environment", "development"),
        zaibase.LogField.string("server", "0.0.0.0:3000"),
        zaibase.LogField.string("logging_format", "pretty"),
    });

    var response = try ourclaw.interfaces.http_adapter.handle(std.heap.page_allocator, app, .{
        .request_id = "http_req_demo_01",
        .route = "/v1/app/meta",
        .params = &.{},
        .authority = .admin,
    });
    defer response.deinit(std.heap.page_allocator);
}


