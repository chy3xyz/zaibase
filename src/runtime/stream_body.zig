const std = @import("std");
const sink_model = @import("stream_sink.zig");

pub const ByteSink = sink_model.ByteSink;

pub const StreamingBody = struct {
    ptr: *anyopaque,
    write: *const fn (ptr: *anyopaque, sink: ByteSink) anyerror!void,
    deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
};

pub const WebSocketClientEventHandler = struct {
    ptr: *anyopaque,
    on_text: *const fn (ptr: *anyopaque, text: []const u8) anyerror!void,
    on_close: *const fn (ptr: *anyopaque, close_code: ?u16, close_reason: ?[]const u8) void,
};

pub const WebSocketBody = struct {
    pub const ClientEventHandler = WebSocketClientEventHandler;

    accept_key: [28]u8,
    ptr: *anyopaque,
    write: *const fn (ptr: *anyopaque, sink: ByteSink) anyerror!void,
    client_events: ?WebSocketClientEventHandler = null,
    deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
};

test "stream body contracts keep callback shapes" {
    const streaming = StreamingBody{
        .ptr = undefined,
        .write = struct {
            fn call(_: *anyopaque, _: ByteSink) anyerror!void {}
        }.call,
        .deinit = struct {
            fn call(_: *anyopaque, _: std.mem.Allocator) void {}
        }.call,
    };
    _ = streaming;

    const websocket = WebSocketBody{
        .accept_key = comptime blk: { var k: [28]u8 = undefined; @memset(&k, 'a'); break :blk k; },
        .ptr = undefined,
        .write = struct {
            fn call(_: *anyopaque, _: ByteSink) anyerror!void {}
        }.call,
        .client_events = .{
            .ptr = undefined,
            .on_text = struct {
                fn call(_: *anyopaque, _: []const u8) anyerror!void {}
            }.call,
            .on_close = struct {
                fn call(_: *anyopaque, _: ?u16, _: ?[]const u8) void {}
            }.call,
        },
        .deinit = struct {
            fn call(_: *anyopaque, _: std.mem.Allocator) void {}
        }.call,
    };
    _ = websocket;
}


