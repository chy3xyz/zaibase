//! Service health reporting type, mirroring the framework's error/diagnostic style.

const std = @import("std");

/// Service health status — the central concept for the servicekit module.
pub const ServiceHealth = enum {
    /// Service has not yet been initialized or started.
    unknown,
    /// Service is operating normally.
    healthy,
    /// Service is operating but with reduced capacity or degraded state.
    degraded,
    /// Service has failed and requires intervention.
    unhealthy,

    pub fn asText(self: ServiceHealth) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .healthy => "healthy",
            .degraded => "degraded",
            .unhealthy => "unhealthy",
        };
    }

    /// True when the service is in a viable operational state.
    pub fn isOperational(self: ServiceHealth) bool {
        return self == .healthy or self == .degraded;
    }
};

/// Structured health report from a single service.
pub const HealthReport = struct {
    service_name: []const u8,
    status: ServiceHealth,
    /// Human-readable message describing the current state.
    message: []const u8,
    /// Optional last error, if any.
    last_error: ?[]const u8 = null,
    /// Optional millisecond timestamp of the last state change.
    last_change_ms: ?i64 = null,
};

/// Aggregate health report from the ServiceManager.
pub const ManagerHealth = struct {
    overall: ServiceHealth,
    services: []const HealthReport,

    /// True when all registered services are healthy.
    pub fn allHealthy(self: ManagerHealth) bool {
        return self.overall == .healthy;
    }

    /// Returns the count of unhealthy/degraded services.
    pub fn unhealthyCount(self: ManagerHealth) usize {
        var count: usize = 0;
        for (self.services) |svc| {
            if (!svc.status.isOperational()) count += 1;
        }
        return count;
    }
};

test "ServiceHealth asText" {
    try std.testing.expectEqualStrings("unknown", ServiceHealth.unknown.asText());
    try std.testing.expectEqualStrings("healthy", ServiceHealth.healthy.asText());
    try std.testing.expectEqualStrings("degraded", ServiceHealth.degraded.asText());
    try std.testing.expectEqualStrings("unhealthy", ServiceHealth.unhealthy.asText());
}

test "ServiceHealth isOperational" {
    try std.testing.expect(ServiceHealth.healthy.isOperational());
    try std.testing.expect(ServiceHealth.degraded.isOperational());
    try std.testing.expect(!ServiceHealth.unknown.isOperational());
    try std.testing.expect(!ServiceHealth.unhealthy.isOperational());
}

test "ManagerHealth allHealthy" {
    var reports = [_]HealthReport{
        .{ .service_name = "a", .status = .healthy, .message = "ok" },
        .{ .service_name = "b", .status = .healthy, .message = "ok" },
    };
    const mh = ManagerHealth{ .overall = .healthy, .services = reports[0..] };
    try std.testing.expect(mh.allHealthy());
    try std.testing.expectEqual(@as(usize, 0), mh.unhealthyCount());
}

test "ManagerHealth with degraded service" {
    var reports = [_]HealthReport{
        .{ .service_name = "a", .status = .healthy, .message = "ok" },
        .{ .service_name = "b", .status = .unhealthy, .message = "down" },
    };
    const mh = ManagerHealth{ .overall = .degraded, .services = reports[0..] };
    try std.testing.expect(!mh.allHealthy());
    try std.testing.expectEqual(@as(usize, 1), mh.unhealthyCount());
}
