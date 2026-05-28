const std = @import("std");

pub const RuntimeEvent = struct {
    seq: u64,
    topic: []u8,
    ts_unix_ms: i64,
    payload_json: []u8,

    pub fn clone(self: RuntimeEvent, allocator: std.mem.Allocator) anyerror!RuntimeEvent {
        return .{
            .seq = self.seq,
            .topic = try allocator.dupe(u8, self.topic),
            .ts_unix_ms = self.ts_unix_ms,
            .payload_json = try allocator.dupe(u8, self.payload_json),
        };
    }

    pub fn deinit(self: *RuntimeEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.topic);
        allocator.free(self.payload_json);
    }
};

pub const EventBatch = struct {
    events: []RuntimeEvent,
    last_seq: u64,
    has_more: bool,

    pub fn deinit(self: *EventBatch, allocator: std.mem.Allocator) void {
        for (self.events) |*event| {
            event.deinit(allocator);
        }
        allocator.free(self.events);
    }
};

pub const EventBus = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        publish: *const fn (ptr: *anyopaque, topic: []const u8, payload_json: []const u8) anyerror!u64,
        snapshot: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]RuntimeEvent,
        poll_after: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, after_seq: u64) anyerror![]RuntimeEvent,
        latest_seq: *const fn (ptr: *anyopaque) u64,
        subscribe: *const fn (ptr: *anyopaque, topic_filters: []const []const u8, after_seq: u64) anyerror!u64,
        unsubscribe: *const fn (ptr: *anyopaque, subscription_id: u64) anyerror!void,
        poll_subscription: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, subscription_id: u64, limit: usize) anyerror!EventBatch,
        subscription_count: *const fn (ptr: *anyopaque) usize,
    };

    pub fn publish(self: EventBus, topic: []const u8, payload_json: []const u8) anyerror!u64 {
        return self.vtable.publish(self.ptr, topic, payload_json);
    }

    pub fn snapshot(self: EventBus, allocator: std.mem.Allocator) anyerror![]RuntimeEvent {
        return self.vtable.snapshot(self.ptr, allocator);
    }

    pub fn pollAfter(self: EventBus, allocator: std.mem.Allocator, after_seq: u64) anyerror![]RuntimeEvent {
        return self.vtable.poll_after(self.ptr, allocator, after_seq);
    }

    pub fn latestSeq(self: EventBus) u64 {
        return self.vtable.latest_seq(self.ptr);
    }

    pub fn subscribe(self: EventBus, topic_filters: []const []const u8, after_seq: u64) anyerror!u64 {
        return self.vtable.subscribe(self.ptr, topic_filters, after_seq);
    }

    pub fn unsubscribe(self: EventBus, subscription_id: u64) anyerror!void {
        return self.vtable.unsubscribe(self.ptr, subscription_id);
    }

    pub fn pollSubscription(self: EventBus, allocator: std.mem.Allocator, subscription_id: u64, limit: usize) anyerror!EventBatch {
        return self.vtable.poll_subscription(self.ptr, allocator, subscription_id, limit);
    }

    pub fn subscriptionCount(self: EventBus) usize {
        return self.vtable.subscription_count(self.ptr);
    }
};

pub const MemoryEventBus = struct {
    allocator: std.mem.Allocator,
    next_seq: u64 = 1,
    next_subscription_id: u64 = 1,
    max_subscriptions: usize = 64,
    events: std.ArrayListUnmanaged(RuntimeEvent) = .empty,
    subscriptions: std.ArrayListUnmanaged(SubscriptionState) = .empty,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const SubscriptionState = struct {
        id: u64,
        cursor_seq: u64,
        topic_filters: [][]u8,

        fn deinit(self: *SubscriptionState, allocator: std.mem.Allocator) void {
            for (self.topic_filters) |filter| {
                allocator.free(filter);
            }
            allocator.free(self.topic_filters);
        }
    };

    const vtable = EventBus.VTable{
        .publish = publishErased,
        .snapshot = snapshotErased,
        .poll_after = pollAfterErased,
        .latest_seq = latestSeqErased,
        .subscribe = subscribeErased,
        .unsubscribe = unsubscribeErased,
        .poll_subscription = pollSubscriptionErased,
        .subscription_count = subscriptionCountErased,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        for (self.events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);

        for (self.subscriptions.items) |*subscription| {
            subscription.deinit(self.allocator);
        }
        self.subscriptions.deinit(self.allocator);
    }

    pub fn asEventBus(self: *Self) EventBus {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn publish(self: *Self, topic: []const u8, payload_json: []const u8) anyerror!u64 {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const seq = self.next_seq;
        self.next_seq += 1;

        try self.events.append(self.allocator, .{
            .seq = seq,
            .topic = try self.allocator.dupe(u8, topic),
            .ts_unix_ms = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }),
            .payload_json = try self.allocator.dupe(u8, payload_json),
        });

        return seq;
    }

    pub fn snapshot(self: *Self, allocator: std.mem.Allocator) anyerror![]RuntimeEvent {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        return self.cloneEvents(allocator, self.events.items);
    }

    pub fn pollAfter(self: *Self, allocator: std.mem.Allocator, after_seq: u64) anyerror![]RuntimeEvent {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        var matches: std.ArrayListUnmanaged(RuntimeEvent) = .empty;
        defer matches.deinit(allocator);

        for (self.events.items) |event| {
            if (event.seq > after_seq) {
                try matches.append(allocator, try event.clone(allocator));
            }
        }

        return allocator.dupe(RuntimeEvent, matches.items);
    }

    pub fn latestSeq(self: *Self) u64 {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        if (self.events.items.len == 0) {
            return 0;
        }
        return self.events.items[self.events.items.len - 1].seq;
    }

    pub fn subscribe(self: *Self, topic_filters: []const []const u8, after_seq: u64) anyerror!u64 {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        if (self.subscriptions.items.len >= self.max_subscriptions) {
            return error.SubscriptionLimitReached;
        }

        const id = self.next_subscription_id;
        self.next_subscription_id += 1;

        const filters = try self.allocator.alloc([]u8, topic_filters.len);
        errdefer self.allocator.free(filters);

        for (topic_filters, 0..) |filter, index| {
            filters[index] = try self.allocator.dupe(u8, filter);
        }

        try self.subscriptions.append(self.allocator, .{
            .id = id,
            .cursor_seq = after_seq,
            .topic_filters = filters,
        });

        return id;
    }

    pub fn unsubscribe(self: *Self, subscription_id: u64) anyerror!void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        for (self.subscriptions.items, 0..) |*subscription, index| {
            if (subscription.id == subscription_id) {
                var removed = self.subscriptions.orderedRemove(index);
                removed.deinit(self.allocator);
                return;
            }
        }
        return error.SubscriptionNotFound;
    }

    pub fn pollSubscription(self: *Self, allocator: std.mem.Allocator, subscription_id: u64, limit: usize) anyerror!EventBatch {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const subscription = self.findSubscriptionLocked(subscription_id) orelse return error.SubscriptionNotFound;

        var events: std.ArrayListUnmanaged(RuntimeEvent) = .empty;
        defer events.deinit(allocator);

        var has_more = false;
        var last_seq = subscription.cursor_seq;

        for (self.events.items) |event| {
            if (event.seq <= subscription.cursor_seq) {
                continue;
            }
            if (!matchesTopic(subscription.topic_filters, event.topic)) {
                continue;
            }

            if (events.items.len >= limit and limit > 0) {
                has_more = true;
                break;
            }

            if (limit == 0) {
                has_more = true;
                break;
            }

            try events.append(allocator, try event.clone(allocator));
            last_seq = event.seq;
        }

        if (events.items.len > 0) {
            subscription.cursor_seq = last_seq;
        }

        return .{
            .events = try allocator.dupe(RuntimeEvent, events.items),
            .last_seq = last_seq,
            .has_more = has_more,
        };
    }

    pub fn subscriptionCount(self: *Self) usize {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        return self.subscriptions.items.len;
    }

    pub fn count(self: *Self) usize {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        return self.events.items.len;
    }

    fn cloneEvents(_: *Self, allocator: std.mem.Allocator, source: []const RuntimeEvent) anyerror![]RuntimeEvent {
        const events = try allocator.alloc(RuntimeEvent, source.len);
        errdefer allocator.free(events);

        for (source, 0..) |event, index| {
            events[index] = try event.clone(allocator);
        }

        return events;
    }

    fn findSubscriptionLocked(self: *Self, subscription_id: u64) ?*SubscriptionState {
        for (self.subscriptions.items) |*subscription| {
            if (subscription.id == subscription_id) {
                return subscription;
            }
        }
        return null;
    }

    fn publishErased(ptr: *anyopaque, topic: []const u8, payload_json: []const u8) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.publish(topic, payload_json);
    }

    fn snapshotErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]RuntimeEvent {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.snapshot(allocator);
    }

    fn pollAfterErased(ptr: *anyopaque, allocator: std.mem.Allocator, after_seq: u64) anyerror![]RuntimeEvent {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.pollAfter(allocator, after_seq);
    }

    fn latestSeqErased(ptr: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.latestSeq();
    }

    fn subscribeErased(ptr: *anyopaque, topic_filters: []const []const u8, after_seq: u64) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.subscribe(topic_filters, after_seq);
    }

    fn unsubscribeErased(ptr: *anyopaque, subscription_id: u64) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.unsubscribe(subscription_id);
    }

    fn pollSubscriptionErased(ptr: *anyopaque, allocator: std.mem.Allocator, subscription_id: u64, limit: usize) anyerror!EventBatch {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.pollSubscription(allocator, subscription_id, limit);
    }

    fn subscriptionCountErased(ptr: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.subscriptionCount();
    }
};

fn matchesTopic(filters: [][]u8, topic: []const u8) bool {
    if (filters.len == 0) {
        return true;
    }
    for (filters) |filter| {
        if (std.mem.startsWith(u8, topic, filter)) {
            return true;
        }
    }
    return false;
}

test "memory event bus publishes and snapshots events" {
    var bus = MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = try bus.publish("command.started", "{\"method\":\"app.meta\"}");
    _ = try bus.publish("command.completed", "{\"method\":\"app.meta\"}");

    const events = try bus.snapshot(std.testing.allocator);
    defer {
        for (events) |*event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(u64, 2), bus.latestSeq());
    try std.testing.expectEqualStrings("command.started", events[0].topic);
}

test "memory event bus can poll after sequence" {
    var bus = MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = try bus.publish("task.queued", "{}");
    _ = try bus.publish("task.running", "{}");
    _ = try bus.publish("task.finished", "{}");

    const events = try bus.pollAfter(std.testing.allocator, 1);
    defer {
        for (events) |*event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("task.running", events[0].topic);
}

test "memory event bus supports subscriptions with stable cursors" {
    var bus = MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = try bus.publish("task.queued", "{}");
    _ = try bus.publish("task.running", "{}");
    _ = try bus.publish("task.succeeded", "{}");

    const subscription_id = try bus.subscribe(&.{"task."}, 0);
    var batch = try bus.pollSubscription(std.testing.allocator, subscription_id, 2);
    defer batch.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), batch.events.len);
    try std.testing.expect(batch.has_more);
    try std.testing.expectEqual(@as(u64, 2), batch.last_seq);

    var second_batch = try bus.pollSubscription(std.testing.allocator, subscription_id, 2);
    defer second_batch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second_batch.events.len);
    try std.testing.expect(!second_batch.has_more);
    try std.testing.expectEqualStrings("task.succeeded", second_batch.events[0].topic);
}

test "memory event bus can unsubscribe subscriptions" {
    var bus = MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();

    const subscription_id = try bus.subscribe(&.{}, 0);
    try std.testing.expectEqual(@as(usize, 1), bus.subscriptionCount());
    try bus.unsubscribe(subscription_id);
    try std.testing.expectEqual(@as(usize, 0), bus.subscriptionCount());
}


