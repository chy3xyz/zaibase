//! Experience data types — the raw material for self-evolution.
//!
//! An Experience records what an agent did (action), in what context,
//! what outcome occurred, and optional structured feedback (reward).
//! The learner uses experiences to derive Insights.

const std = @import("std");

/// Whether an experience had a positive or negative result.
pub const ExperienceOutcome = enum {
    success,
    failure,
    partial,

    pub fn asText(self: ExperienceOutcome) []const u8 {
        return switch (self) {
            .success => "success",
            .failure => "failure",
            .partial => "partial",
        };
    }

    pub fn isPositive(self: ExperienceOutcome) bool {
        return self == .success or self == .partial;
    }
};

/// Record of a single agent action and its result.
pub const Experience = struct {
    /// Unique id.
    id: []const u8,
    /// What the agent did (e.g. "tool.execute", "decision.retry").
    action: []const u8,
    /// Structured context (e.g. "{\"tool\":\"repo.health\",\"args\":{\"path\":\"/tmp\"}}").
    context_json: []const u8,
    /// Outcome.
    outcome: ExperienceOutcome,
    /// Optional numeric reward (0.0 - 1.0).
    reward: f64 = 0.0,
    /// Optional structured result/error message.
    detail: []const u8 = "",
    /// Timestamp (unix ms).
    ts_unix_ms: i64 = 0,
    /// Optional tags (e.g. "tool", "http", "retry").
    tags: []const []const u8 = &.{},

    pub fn clone(self: Experience, allocator: std.mem.Allocator) !Experience {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .action = try allocator.dupe(u8, self.action),
            .context_json = try allocator.dupe(u8, self.context_json),
            .outcome = self.outcome,
            .reward = self.reward,
            .detail = if (self.detail.len > 0) try allocator.dupe(u8, self.detail) else "",
            .ts_unix_ms = self.ts_unix_ms,
            .tags = if (self.tags.len > 0) try allocator.dupe([]const u8, self.tags) else &.{},
        };
    }

    pub fn deinit(self: *Experience, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.action);
        allocator.free(self.context_json);
        if (self.detail.len > 0) allocator.free(self.detail);
        for (self.tags) |t| allocator.free(t);
        if (self.tags.len > 0) allocator.free(self.tags);
    }
};

/// In-memory experience store. Same pattern as EpisodicMemory.
pub const NativeExperienceStore = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Experience),
    capacity: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
        return .{ .allocator = allocator, .entries = .empty, .capacity = capacity };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn record(self: *Self, exp: Experience) !void {
        if (self.entries.items.len >= self.capacity) {
            var oldest = self.entries.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        var cloned = try exp.clone(self.allocator);
        self.entries.append(self.allocator, cloned) catch {
            cloned.deinit(self.allocator);
            return error.OutOfMemory;
        };
    }

    pub fn recent(self: *Self, allocator: std.mem.Allocator, limit: usize) ![]Experience {
        const n = @min(limit, self.entries.items.len);
        var results = try allocator.alloc(Experience, n);
        errdefer allocator.free(results);
        for (0..n) |i| {
            const idx = self.entries.items.len - n + i;
            results[i] = try self.entries.items[idx].clone(allocator);
        }
        return results;
    }

    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    pub fn clear(self: *Self) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
    }
};

/// Vtable interface for ExperienceStore (can be swapped for persistent backends).
pub const ExperienceStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        record: *const fn (ptr: *anyopaque, exp: Experience) anyerror!void,
        recent: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, limit: usize) anyerror![]Experience,
        count: *const fn (ptr: *anyopaque) usize,
        clear: *const fn (ptr: *anyopaque) void,
    };

    pub fn record(self: ExperienceStore, exp: Experience) anyerror!void {
        return self.vtable.record(self.ptr, exp);
    }
    pub fn recent(self: ExperienceStore, allocator: std.mem.Allocator, limit: usize) anyerror![]Experience {
        return self.vtable.recent(self.ptr, allocator, limit);
    }
    pub fn count(self: ExperienceStore) usize {
        return self.vtable.count(self.ptr);
    }
    pub fn clear(self: ExperienceStore) void {
        return self.vtable.clear(self.ptr);
    }
};

test "Experience clone lifecycle" {
    const exp_src = Experience{ .id = "exp_01", .action = "tool.execute", .context_json = "{\"tool\":\"repo.health\"}", .outcome = .success, .reward = 0.95, .detail = "completed", .ts_unix_ms = 1000, .tags = &.{"tool"} };
    var exp = try exp_src.clone(std.testing.allocator);
    defer exp.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("exp_01", exp.id);
    try std.testing.expectEqualStrings("tool.execute", exp.action);
    try std.testing.expectEqual(.success, exp.outcome);
    try std.testing.expect(exp.outcome.isPositive());
}

test "NativeExperienceStore ring-buffer" {
    var store = NativeExperienceStore.init(std.testing.allocator, 3);
    defer store.deinit();

    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "e{d}", .{i});
        var e_src = Experience{ .id = id, .action = "act", .context_json = "{}", .outcome = .success };
        var e = try e_src.clone(std.testing.allocator);
        defer e.deinit(std.testing.allocator);
        try store.record(e);
    }
    try std.testing.expectEqual(@as(usize, 3), store.count());

    const recent = try store.recent(std.testing.allocator, 10);
    defer {
        for (recent) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(recent);
    }
    try std.testing.expectEqual(@as(usize, 3), recent.len);
    try std.testing.expectEqualStrings("e4", recent[2].id); // newest
    try std.testing.expectEqualStrings("e2", recent[0].id); // oldest in window
}
