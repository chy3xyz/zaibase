const std = @import("std");
const store_mod = @import("store.zig");

pub const EpisodicMemory = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(store_mod.MemoryEntry),
    capacity: usize,
    const Self = @This();
    const vtable = store_mod.MemoryStore.VTable{
        .store = storeErased, .recall = recallErased,
        .forget = forgetErased, .count = countErased, .clear = clearErased,
    };
    pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
        return .{ .allocator = allocator, .entries = .empty, .capacity = capacity };
    }
    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }
    pub fn asMemoryStore(self: *Self) store_mod.MemoryStore {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
    pub fn store(self: *Self, entry: store_mod.MemoryEntry) store_mod.MemoryStore.StoreError!void {
        for (self.entries.items) |existing| {
            if (std.mem.eql(u8, existing.id, entry.id)) return error.EntryAlreadyExists;
        }
        if (self.entries.items.len >= self.capacity) {
            var oldest = self.entries.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        var cloned = try entry.clone(self.allocator);
        self.entries.append(self.allocator, cloned) catch {
            cloned.deinit(self.allocator);
            return error.OutOfMemory;
        };
    }
    pub fn recall(self: *Self, allocator: std.mem.Allocator, query: store_mod.MemoryQuery) ![]store_mod.MemoryEntry {
        var results = std.ArrayListUnmanaged(store_mod.MemoryEntry).empty;
        errdefer { for (results.items) |*r| r.deinit(allocator); results.deinit(allocator); }
        var idx: usize = self.entries.items.len;
        while (idx > 0) {
            idx -= 1;
            const cur = self.entries.items[idx];
            if (query.since_ms) |since| if (cur.ts_unix_ms < since) continue;
            if (query.key) |k| if (!std.mem.eql(u8, cur.key, k)) continue;
            if (query.search) |s| { if (std.mem.indexOf(u8, cur.key, s) == null and std.mem.indexOf(u8, cur.value, s) == null) continue; }
            if (query.tag) |t| { var matched = false; for (cur.tags) |tag| if (std.mem.eql(u8, tag, t)) { matched = true; break; }; if (!matched) continue; }
            if (results.items.len >= query.limit) break;
            try results.append(allocator, try cur.clone(allocator));
        }
        return results.toOwnedSlice(allocator);
    }
    pub fn forget(self: *Self, id: []const u8) store_mod.MemoryStore.StoreError!void {
        for (self.entries.items, 0..) |*e, idx| {
            if (std.mem.eql(u8, e.id, id)) { var removed = self.entries.orderedRemove(idx); removed.deinit(self.allocator); return; }
        }
        return error.EntryNotFound;
    }
    pub fn count(self: *const Self) usize { return self.entries.items.len; }
    pub fn clear(self: *Self) void { for (self.entries.items) |*e| e.deinit(self.allocator); self.entries.clearRetainingCapacity(); }
    fn storeErased(ptr: *anyopaque, entry: store_mod.MemoryEntry) store_mod.MemoryStore.StoreError!void { const self: *Self = @ptrCast(@alignCast(ptr)); return self.store(entry); }
    fn recallErased(ptr: *anyopaque, allocator: std.mem.Allocator, query: store_mod.MemoryQuery) store_mod.MemoryStore.StoreError![]store_mod.MemoryEntry { const self: *Self = @ptrCast(@alignCast(ptr)); return self.recall(allocator, query); }
    fn forgetErased(ptr: *anyopaque, id: []const u8) store_mod.MemoryStore.StoreError!void { const self: *Self = @ptrCast(@alignCast(ptr)); return self.forget(id); }
    fn countErased(ptr: *anyopaque) usize { const self: *Self = @ptrCast(@alignCast(ptr)); return self.count(); }
    fn clearErased(ptr: *anyopaque) void { const self: *Self = @ptrCast(@alignCast(ptr)); self.clear(); }
};

test "basic crud" {
    var mem = EpisodicMemory.init(std.testing.allocator, 8);
    defer mem.deinit();
    const e1 = store_mod.MemoryEntry{ .id = "m1", .key = "k", .value = "v" };
    try mem.store(try e1.clone(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 1), mem.count());
    try mem.forget("m1");
    try std.testing.expectEqual(@as(usize, 0), mem.count());
}
