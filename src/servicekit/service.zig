//! Service vtable interface — the core abstraction for servicekit.
//!
//! A Service represents a long-running component with a lifecycle (start/stop),
//! health monitoring, and zero-cost vtable dispatch (consistent with the
//! framework's PatternRunner / EventBus / Observer patterns).

const std = @import("std");
const health_mod = @import("health.zig");

/// The vtable-based service interface.
/// Implements the standard framework pattern: `{ ptr: *anyopaque, vtable: *const VTable }`.
pub const Service = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Human-readable name for diagnostics.
        name: *const fn (ptr: *anyopaque) []const u8,
        /// Attempt to start the service. Called once.
        start: *const fn (ptr: *anyopaque) StartError!void,
        /// Gracefully stop the service. Called once.
        stop: *const fn (ptr: *anyopaque) void,
        /// Return the current health of the service.
        health: *const fn (ptr: *anyopaque) health_mod.HealthReport,
        /// Release resources held by the service.
        destroy: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
    };

    pub const StartError = error{
        /// Service has already been started.
        AlreadyStarted,
        /// Service failed to initialize or connect to its dependencies.
        StartFailed,
        /// Required dependency service was not found.
        DependencyMissing,
    } || std.mem.Allocator.Error;

    pub fn name(self: Service) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn start(self: Service) StartError!void {
        return self.vtable.start(self.ptr);
    }

    pub fn stop(self: Service) void {
        self.vtable.stop(self.ptr);
    }

    pub fn health(self: Service) health_mod.HealthReport {
        return self.vtable.health(self.ptr);
    }

    pub fn destroy(self: Service, allocator: std.mem.Allocator) void {
        if (self.vtable.destroy) |destroy_fn| {
            destroy_fn(self.ptr, allocator);
        }
    }
};

test "Service vtable dispatch" {
    var native = NativeEchoService.init();
    var svc = native.service();

    try std.testing.expectEqualStrings("echo", svc.name());
    try svc.start();
    try std.testing.expectEqualStrings("healthy", svc.health().status.asText());
    try std.testing.expectEqualStrings("EchoService operational", svc.health().message);
    svc.stop();
    try std.testing.expectEqualStrings("healthy", svc.health().status.asText());
}

test "Service double-start returns error" {
    var native = NativeEchoService.init();
    var svc = native.service();
    try svc.start();
    try std.testing.expectError(error.AlreadyStarted, svc.start());
    svc.stop();
}

/// A trivial service implementation for testing and quick scaffolding.
pub const NativeEchoService = struct {
    running: bool = false,
    started_at_ms: ?i64 = null,

    const Self = @This();

    const vtable = Service.VTable{
        .name = nameErased,
        .start = startErased,
        .stop = stopErased,
        .health = healthErased,
    };

    pub fn init() Self {
        return .{};
    }

    pub fn service(self: *Self) Service {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    fn nameErased(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "echo";
    }

    fn startErased(ptr: *anyopaque) Service.StartError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.running) return error.AlreadyStarted;
        const io = std.Io.Threaded.global_single_threaded.*.io();
        self.started_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        self.running = true;
    }

    fn stopErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.running = false;
    }

    fn healthErased(ptr: *anyopaque) health_mod.HealthReport {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .service_name = "echo",
            .status = .healthy,
            .message = "EchoService operational",
            .last_change_ms = self.started_at_ms,
        };
    }
};

test "NativeEchoService defaults to stopped" {
    var native = NativeEchoService.init();
    try std.testing.expect(!native.isRunning());
}

test "NativeEchoService start/stop lifecycle" {
    var native = NativeEchoService.init();
    var svc = native.service();
    try svc.start();
    try std.testing.expect(native.isRunning());
    svc.stop();
    try std.testing.expect(!native.isRunning());
}
