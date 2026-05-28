const std = @import("std");
const exp_mod = @import("experience.zig");

pub const Insight = struct {
    title: []const u8,
    sample_count: usize,
    success_rate: f64,
    suggestion: []const u8,
    tags: []const []const u8 = &.{},
    pub fn deinit(self: *Insight, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.suggestion);
        for (self.tags) |t| allocator.free(t);
        allocator.free(self.tags);
    }
};

const AcStats = struct { total: usize = 0, success: usize = 0 };

pub const SimpleLearner = struct {
    allocator: std.mem.Allocator,
    store: *exp_mod.NativeExperienceStore,
    const Self = @This();
    pub fn init(allocator: std.mem.Allocator, store: *exp_mod.NativeExperienceStore) Self {
        return .{ .allocator = allocator, .store = store };
    }
    pub fn insights(self: *Self, limit: usize) ![]Insight {
        const recent = try self.store.recent(self.allocator, limit);
        defer { for (recent) |*r| r.deinit(self.allocator); self.allocator.free(recent); }
        var ac = std.StringHashMap(AcStats).init(self.allocator);
        defer ac.deinit();
        for (recent) |exp| {
            var e = try ac.getOrPut(exp.action);
            _ = &e;
            if (!e.found_existing) e.value_ptr.* = .{};
            e.value_ptr.*.total += 1;
            if (exp.outcome.isPositive()) e.value_ptr.*.success += 1;
        }
        var results = std.ArrayListUnmanaged(Insight).empty;
        errdefer { for (results.items) |*r| r.deinit(self.allocator); results.deinit(self.allocator); }
        var iter = ac.iterator();
        while (iter.next()) |entry| {
            const stats = entry.value_ptr.*;
            const rate = if (stats.total > 0) @as(f64, @floatFromInt(stats.success)) / @as(f64, @floatFromInt(stats.total)) else 0.0;
            const sug = if (rate >= 0.7) "continue using"
                else if (rate < 0.3) "review or replace"
                else "monitor";
            try results.append(self.allocator, .{
                .title = try std.fmt.allocPrint(self.allocator, "{s} success rate", .{entry.key_ptr.*}),
                .sample_count = stats.total, .success_rate = rate,
                .suggestion = try self.allocator.dupe(u8, sug),
            });
        }
        return results.toOwnedSlice(self.allocator);
    }
};

pub const Learner = struct {
    ptr: *anyopaque, vtable: *const VTable,
    pub const VTable = struct {
        insights: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, limit: usize) anyerror![]Insight,
    };
    pub fn insights(self: Learner, allocator: std.mem.Allocator, limit: usize) anyerror![]Insight {
        return self.vtable.insights(self.ptr, allocator, limit);
    }
};

test "SimpleLearner generates insights" {
    var store = exp_mod.NativeExperienceStore.init(std.testing.allocator, 32);
    defer store.deinit();
    const src = exp_mod.Experience{ .id = "e1", .action = "tool.x", .context_json = "{}", .outcome = .success, .tags = &.{"http"} };
    try store.record(try src.clone(std.testing.allocator));
    try store.record(try src.clone(std.testing.allocator));
    var sf = exp_mod.Experience{ .id = "e3", .action = "tool.x", .context_json = "{}", .outcome = .failure, .tags = &.{"http"} };
    try store.record(try sf.clone(std.testing.allocator));
    const sy = exp_mod.Experience{ .id = "e4", .action = "tool.y", .context_json = "{}", .outcome = .failure, .tags = &.{"db"} };
    try store.record(try sy.clone(std.testing.allocator));
    try store.record(try sy.clone(std.testing.allocator));
    var learner = SimpleLearner.init(std.testing.allocator, &store);
    const insights = try learner.insights(10);
    defer { for (insights) |*ins| ins.deinit(std.testing.allocator); std.testing.allocator.free(insights); }
    try std.testing.expectEqual(@as(usize, 2), insights.len);
}
