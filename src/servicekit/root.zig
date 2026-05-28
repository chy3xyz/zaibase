const std = @import("std");

pub const MODULE_NAME = "servicekit";

pub const health = @import("health.zig");
pub const service = @import("service.zig");
pub const manager = @import("manager.zig");

pub const ServiceHealth = health.ServiceHealth;
pub const HealthReport = health.HealthReport;
pub const ManagerHealth = health.ManagerHealth;
pub const Service = service.Service;
pub const NativeEchoService = service.NativeEchoService;
pub const ServiceManager = manager.ServiceManager;
pub const ServiceManagerConfig = manager.ServiceManagerConfig;

pub const ModuleStage = enum {
    scaffold,
    evolving,
    stable,
};

pub const MODULE_STAGE: ModuleStage = .evolving;

test {
    std.testing.refAllDecls(@This());
}
