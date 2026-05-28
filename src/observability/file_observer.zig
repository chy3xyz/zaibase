const std = @import("std");
const observer_model = @import("observer.zig");

pub const Observer = observer_model.Observer;

pub const JsonlFileObserver = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    max_bytes: ?u64 = null,
    current_bytes: u64 = 0,
    dropped_events: usize = 0,
    flush_count: usize = 0,
    degraded: bool = false,

    const Self = @This();

    const vtable = Observer.VTable{
        .record = recordErased,
        .flush = flushErased,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8, max_bytes: ?u64) !Self {
        var self = Self{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .max_bytes = max_bytes,
        };
        self.current_bytes = currentSize(self.path);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.path);
    }

    pub fn asObserver(self: *Self) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn record(self: *Self, topic: []const u8, payload_json: []const u8) void {
        self.recordInternal(topic, payload_json) catch {
            self.degraded = true;
            self.dropped_events += 1;
        };
    }

    pub fn flush(self: *Self) void {
        self.flush_count += 1;
    }

    fn recordInternal(self: *Self, topic: []const u8, payload_json: []const u8) !void {
        var alloc_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer alloc_writer.deinit();

        const w = &alloc_writer.writer;
        try w.writeAll("{\"topic\":");
        try writeJsonString(w, topic);
        try w.writeAll(",\"ts\":");
        try w.print("{d}", .{(blk: {
            const io = std.Io.Threaded.global_single_threaded.*.io();
            break :blk std.Io.Timestamp.now(io, .real).toMilliseconds();
        })});
        try w.writeAll(",\"payload\":");
        try w.writeAll(payload_json);
        try w.writeAll("}\n");

        const json_line = w.buffered();
        const io = std.Io.Threaded.global_single_threaded.*.io();
        var file = try std.Io.Dir.cwd().createFile(io, self.path, .{ .truncate = false });
        defer file.close(io);
        try file.writeStreamingAll(io, json_line);
        self.current_bytes += json_line.len;
    }

    fn recordErased(ptr: *anyopaque, topic: []const u8, payload_json: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.record(topic, payload_json);
    }

    fn flushErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.flush();
    }
};

fn currentSize(path: []const u8) u64 {
    const io = std.Io.Threaded.global_single_threaded.*.io();
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return 0;
    defer file.close(io);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return stat.size;
}

fn ensureParentDirectory(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().makePath(std.Io.Threaded.global_single_threaded.*.io(), dir);
    }
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        if (ch == '"' or ch == '\\') {
            try writer.writeByte('\\');
        }
        try writer.writeByte(ch);
    }
    try writer.writeByte('"');
}

test "jsonl file observer writes a valid json line" {
    const io = std.Io.Threaded.global_single_threaded.*.io();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    var file_path_buf: [256]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/test_observer.jsonl", .{root_path});

    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    var observer = try JsonlFileObserver.init(std.testing.allocator, file_path, null);
    defer observer.deinit();

    observer.record("command.completed", "{\"method\":\"app.meta\"}");
    observer.flush();

    const content = try tmp_dir.dir.readFileAlloc(io, "test_observer.jsonl", std.testing.allocator, std.Io.Limit.limited(4096));
    defer std.testing.allocator.free(content);

    try std.testing.expect(content.len > 5);
    try std.testing.expect(std.mem.indexOf(u8, content, "command.completed") != null);
    try std.testing.expectEqual(@as(usize, 0), observer.dropped_events);
    try std.testing.expect(!observer.degraded);
}
