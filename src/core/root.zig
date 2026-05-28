const std = @import("std");

pub const MODULE_NAME = "core";
pub const error_model = @import("error.zig");
pub const logging = @import("logging/root.zig");
pub const validation = @import("validation/root.zig");
pub const security = @import("security/root.zig");

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test "core scaffold exports are stable" {
    try std.testing.expectEqualStrings("core", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);
    try std.testing.expectEqualStrings(
        "CORE_INTERNAL_ERROR",
        error_model.code.CORE_INTERNAL_ERROR,
    );
    try std.testing.expectEqualStrings("validation", validation.MODULE_NAME);
}
