# Evolution Module

Self-evolution subsystem — records agent experiences and extracts insights for continuous improvement.

## Module Layout

```
src/evolution/
├── root.zig        # Module exports
├── experience.zig  # Experience, ExperienceOutcome, NativeExperienceStore
└── learner.zig     # Insight, SimpleLearner, Learner vtable
```

## API Reference

### Experience

Records a single agent action and its result.

```zig
const exp = zaibase.evolution.Experience{
    .id = "exp_01",
    .action = "tool.execute",         // What was done
    .context_json = "{\"tool\":\"repo.health\"}",  // Structured context
    .outcome = .success,              // success | failure | partial
    .reward = 0.95,                   // Numeric feedback (0.0-1.0)
    .detail = "completed in 1.2s",    // Optional result detail
    .ts_unix_ms = 1000,
    .tags = &.{"tool"},
};
```

### ExperienceOutcome

```zig
pub const ExperienceOutcome = enum {
    success,   // Positive result
    failure,   // Negative result
    partial,   // Partial or degraded result
};
```

### NativeExperienceStore

Ring-buffer experience log. Drops oldest when full.

```zig
var store = zaibase.evolution.NativeExperienceStore.init(allocator, 1024);
defer store.deinit();
try store.record(exp);
const recent = try store.recent(allocator, 10);
```

### Insight

A structured pattern derived from past experiences.

```zig
pub const Insight = struct {
    title: []const u8,        // e.g. "tool.execute success rate"
    sample_count: usize,      // How many experiences
    success_rate: f64,        // 0.0 - 1.0
    suggestion: []const u8,   // "continue using" | "review or replace" | "monitor"
};
```

### SimpleLearner

Produces insights by grouping experiences by action and computing success rates.

```zig
var learner = zaibase.evolution.SimpleLearner.init(allocator, &store);
const insights = try learner.insights(10);  // Analyze last 10 experiences
```

### Learner VTable

```zig
pub const Learner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        insights: *const fn (ptr, allocator, limit) anyerror![]Insight,
    };
};
```
