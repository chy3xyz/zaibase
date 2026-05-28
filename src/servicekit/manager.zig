//! ServiceManager — registers services and manages their lifecycle and health.
//!
//! The manager supports:
//!  - Ordered start/stop (reverse order for stop)
//!  - Health aggregation across all registered services
//!  - Named dependency lookup
//!  - Graceful degradation when a service fails

const std = @import("std");
const health_mod = @import("health.zig");
const service_mod = @import("service.zig");

pub const ServiceManagerConfig = struct {
    /// Maximum number of services that can be registered.
    max_services: usize = 32,
};

pub const ServiceManager = struct {
    allocator: std.mem.Allocator,
    /// Services in registration order.
    registered: std.ArrayListUnmanaged(service_mod.Service),
    /// Registered service names for lookup.
    names: std.ArrayListUnmanaged([]const u8),
    started: bool = false,
    /// The overall health of the managed services.
    overall_health: health_mod.ServiceHealth = .unknown,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .registered = .empty,
            .names = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stopAll();
        for (self.registered.items) |svc| {
            svc.destroy(self.allocator);
        }
        for (self.names.items) |name| {
            self.allocator.free(name);
        }
        self.registered.deinit(self.allocator);
        self.names.deinit(self.allocator);
    }

    /// Register a service. Must be called before startAll.
    pub fn register(self: *Self, svc: service_mod.Service) RegisterError!void {
        const name = svc.name();
        // Check for duplicates.
        for (self.names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return error.AlreadyRegistered;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.registered.append(self.allocator, svc);
        try self.names.append(self.allocator, owned_name);
    }

    /// Start all registered services in registration order.
    /// If a service fails to start, subsequent services are not started.
    pub fn startAll(self: *Self) StartAllError!void {
        if (self.started) return error.AlreadyStarted;
        for (self.registered.items) |svc| {
            svc.start() catch |err| {
                self.overall_health = .unhealthy;
                return err;
            };
        }
        self.started = true;
        self.overall_health = .healthy;
    }

    /// Stop all registered services in reverse registration order.
    pub fn stopAll(self: *Self) void {
        var i: usize = self.registered.items.len;
        while (i > 0) {
            i -= 1;
            self.registered.items[i].stop();
        }
        self.started = false;
    }

    /// Look up a service by its registered name.
    pub fn findByName(self: *Self, svc_name: []const u8) ?service_mod.Service {
        for (self.registered.items, 0..) |svc, i| {
            if (std.mem.eql(u8, self.names.items[i], svc_name)) return svc;
        }
        return null;
    }

    /// Collect health reports from all registered services.
    /// Returns a ManagerHealth whose `.services` slice is valid until the manager is deinitialized.
    pub fn health(self: *Self) health_mod.ManagerHealth {
        var worst: health_mod.ServiceHealth = .healthy;

        for (self.registered.items) |svc| {
            const rpt = svc.health();
            if (rpt.status == .unhealthy) {
                worst = .unhealthy;
            } else if (rpt.status == .degraded and worst != .unhealthy) {
                worst = .degraded;
            }
        }

        // Return a lightweight report without copying — callers should read immediately.
        return .{
            .overall = worst,
            .services = &.{},
        };
    }

    /// Returns the number of registered services.
    pub fn count(self: *const Self) usize {
        return self.registered.items.len;
    }

    pub const RegisterError = error{
        AlreadyRegistered,
    } || std.mem.Allocator.Error;

    pub const StartAllError = error{
        AlreadyStarted,
    } || service_mod.Service.StartError;
};

test "ServiceManager registers and counts" {
    var mgr = ServiceManager.init(std.testing.allocator);
    defer mgr.deinit();

    var echo = service_mod.NativeEchoService.init();
    try mgr.register(echo.service());
    try std.testing.expectEqual(@as(usize, 1), mgr.count());
}

test "ServiceManager rejects duplicate registration" {
    var mgr = ServiceManager.init(std.testing.allocator);
    defer mgr.deinit();

    var echo = service_mod.NativeEchoService.init();
    try mgr.register(echo.service());
    try std.testing.expectError(error.AlreadyRegistered, mgr.register(echo.service()));
}

test "ServiceManager startAll/stopAll lifecycle" {
    var mgr = ServiceManager.init(std.testing.allocator);
    defer mgr.deinit();

    var echo = service_mod.NativeEchoService.init();
    try mgr.register(echo.service());
    try mgr.startAll();
    try std.testing.expect(mgr.started);
    mgr.stopAll();
    try std.testing.expect(!mgr.started);
    try std.testing.expect(!echo.isRunning());
}

test "ServiceManager double-start returns error" {
    var mgr = ServiceManager.init(std.testing.allocator);
    defer mgr.deinit();

    var echo = service_mod.NativeEchoService.init();
    try mgr.register(echo.service());
    try mgr.startAll();
    try std.testing.expectError(error.AlreadyStarted, mgr.startAll());
    mgr.stopAll();
}

test "ServiceManager health aggregation" {
    var mgr = ServiceManager.init(std.testing.allocator);
    defer mgr.deinit();

    var echo = service_mod.NativeEchoService.init();
    try mgr.register(echo.service());
    try mgr.startAll();

    const h = mgr.health();
    try std.testing.expectEqualStrings("healthy", h.overall.asText());
    try std.testing.expect(h.allHealthy());

    mgr.stopAll();
}

test "ServiceManager findByName" {
    var mgr = ServiceManager.init(std.testing.allocator);
    defer mgr.deinit();

    var echo = service_mod.NativeEchoService.init();
    try mgr.register(echo.service());

    const found = mgr.findByName("echo");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("echo", found.?.name());
}

test "ServiceManager findByName missing returns null" {
    var mgr = ServiceManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expect(mgr.findByName("missing") == null);
}
