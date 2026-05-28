//! Memory store vtable interface.
//!
//! Follows the standard zaibase pattern: `{ ptr, vtable }` dispatch.
//! A MemoryStore persists structured entries — decisions, observations,
//! task outcomes — for recall across agent sessions.

const std = @import("std");

/// A single memory entry.
pub const MemoryEntry = struct {
    /// Unique identifier for this entry.
    id: []const u8,
    /// Human-readable label (e.g. "decision.retry_strategy").
    key: []const u8,
    /// Structured value (JSON or plain text).
    value: []const u8,
    /// Optional tags for filtering.
    tags: []const []const u8 = &.{},
    /// Entry timestamp (unix ms).
    ts_unix_ms: i64 = 0,
    /// Time-to-live in milliseconds; 0 means permanent.
    ttl_ms: u64 = 0,

    /// Deep-clone for ownership transfer.
    pub fn clone(self: MemoryEntry, allocator: std.mem.Allocator) !MemoryEntry {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .key = try allocator.dupe(u8, self.key),
            .value = try allocator.dupe(u8, self.value),
            .tags = if (self.tags.len > 0) try allocator.dupe([]const u8, self.tags) else &.{},
            .ts_unix_ms = self.ts_unix_ms,
            .ttl_ms = self.ttl_ms,
        };
    }

    pub fn deinit(self: *MemoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.key);
        allocator.free(self.value);
        for (self.tags) |t| allocator.free(t);
        allocator.free(self.tags);
    }
};

/// Query parameters for memory recall.
pub const MemoryQuery = struct {
    /// Exact key match (optional).
    key: ?[]const u8 = null,
    /// Substring search in key or value.
    search: ?[]const u8 = null,
    /// Filter by tag (any match).
    tag: ?[]const u8 = null,
    /// Maximum results.
    limit: usize = 32,
    /// Return entries at or after this timestamp.
    since_ms: ?i64 = null,
};

/// The vtable-based memory store interface.
pub const MemoryStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        store: *const fn (ptr: *anyopaque, entry: MemoryEntry) StoreError!void,
        recall: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, query: MemoryQuery) StoreError![]MemoryEntry,
        forget: *const fn (ptr: *anyopaque, id: []const u8) StoreError!void,
        count: *const fn (ptr: *anyopaque) usize,
        clear: *const fn (ptr: *anyopaque) void,
    };

    pub const StoreError = error{
        OutOfMemory,
        EntryAlreadyExists,
        EntryNotFound,
    } || std.mem.Allocator.Error;

    pub fn store(self: MemoryStore, entry: MemoryEntry) StoreError!void {
        return self.vtable.store(self.ptr, entry);
    }

    pub fn recall(self: MemoryStore, allocator: std.mem.Allocator, query: MemoryQuery) StoreError![]MemoryEntry {
        return self.vtable.recall(self.ptr, allocator, query);
    }

    pub fn forget(self: MemoryStore, id: []const u8) StoreError!void {
        return self.vtable.forget(self.ptr, id);
    }

    pub fn count(self: MemoryStore) usize {
        return self.vtable.count(self.ptr);
    }

    pub fn clear(self: MemoryStore) void {
        return self.vtable.clear(self.ptr);
    }
};

test "MemoryEntry clone and deinit lifecycle" {
    var entry = MemoryEntry{ .id = "mem_01", .key = "decision.strategy", .value = "retry", .tags = &.{"retry", "http"}, .ts_unix_ms = 1000 };
    var cloned = try entry.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("mem_01", cloned.id);
    try std.testing.expectEqualStrings("decision.strategy", cloned.key);
    try std.testing.expectEqualStrings("retry", cloned.value);
    try std.testing.expectEqual(@as(usize, 2), cloned.tags.len);
    try std.testing.expectEqualStrings("retry", cloned.tags[0]);
    try std.testing.expectEqualStrings("http", cloned.tags[1]);
    try std.testing.expectEqual(@as(i64, 1000), cloned.ts_unix_ms);
}
