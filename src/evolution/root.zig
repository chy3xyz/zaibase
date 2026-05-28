const std = @import("std");

pub const MODULE_NAME = "evolution";

pub const experience = @import("experience.zig");
pub const learner = @import("learner.zig");

pub const Experience = experience.Experience;
pub const ExperienceOutcome = experience.ExperienceOutcome;
pub const ExperienceStore = experience.ExperienceStore;
pub const NativeExperienceStore = experience.NativeExperienceStore;
pub const Learner = learner.Learner;
pub const Insight = learner.Insight;
pub const SimpleLearner = learner.SimpleLearner;

pub const ModuleStage = enum { scaffold, evolving, stable };
pub const MODULE_STAGE: ModuleStage = .evolving;

test {
    std.testing.refAllDecls(@This());
}
