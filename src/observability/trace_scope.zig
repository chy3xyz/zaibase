const core = @import("../core/root.zig");

pub const TraceContext = core.logging.TraceContext;
pub const TraceContextProvider = core.logging.TraceContextProvider;

threadlocal var current_context: TraceContext = .{};

pub fn set(context: TraceContext) void {
    current_context = context;
}

pub fn clear() void {
    current_context = .{};
}

pub fn current() TraceContext {
    return current_context;
}

pub fn provider() TraceContextProvider {
    return .{ .ptr = undefined, .get_fn = currentFromThreadLocal };
}

fn currentFromThreadLocal(_: *anyopaque) ?TraceContext {
    return current_context;
}

test "trace scope stores and clears current context" {
    const empty = current();
    try @import("std").testing.expect(empty.trace_id == null);

    set(.{ .trace_id = "trc_01", .request_id = "req_01" });
    const loaded = current();
    try @import("std").testing.expectEqualStrings("trc_01", loaded.trace_id.?);
    try @import("std").testing.expectEqualStrings("req_01", loaded.request_id.?);

    clear();
    try @import("std").testing.expect(current().trace_id == null);
}


