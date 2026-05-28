const std = @import("std");

pub const MODULE_NAME = "memory";

pub const store = @import("store.zig");
pub const episodic = @import("episodic.zig");

pub const MemoryEntry = store.MemoryEntry;
pub const MemoryStore = store.MemoryStore;
pub const MemoryQuery = store.MemoryQuery;
pub const EpisodicMemory = episodic.EpisodicMemory;

pub const ModuleStage = enum { scaffold, evolving, stable };
pub const MODULE_STAGE: ModuleStage = .evolving;

test {
    std.testing.refAllDecls(@This());
}
