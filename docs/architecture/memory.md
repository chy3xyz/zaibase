# Memory Module

Agent memory store for persisting and recalling structured entries across sessions. Follows the same `{ ptr, vtable }` dispatch pattern as other zaibase modules.

## Module Layout

```
src/memory/
├── root.zig       # Module exports
├── store.zig      # MemoryEntry, MemoryQuery, MemoryStore vtable
└── episodic.zig   # EpisodicMemory (ring-buffer implementation)
```

## API Reference

### MemoryEntry

The unit of memory — a structured observation, decision, or fact.

```zig
const entry = zaibase.memory.MemoryEntry{
    .id = "mem_01",          // Unique identifier
    .key = "decision.retry", // Human-readable label
    .value = "{\"strategy\":\"backoff\"}", // Structured value
    .tags = &.{"retry", "http"},
    .ts_unix_ms = 1000,      // Timestamp
    .ttl_ms = 0,             // 0 = permanent
};
```

### MemoryQuery

Filter parameters for `recall()`:

```zig
const query = zaibase.memory.MemoryQuery{
    .key = "decision.retry", // Exact key match
    .tag = "http",           // Tag filter (any tag match)
    .search = "retry",       // Substring in key or value
    .limit = 32,             // Max results (newest-first)
    .since_ms = 1000,        // Only entries at or after this timestamp
};
```

### MemoryStore

```zig
pub fn store(self, entry: MemoryEntry) StoreError!void;
pub fn recall(self, allocator, query: MemoryQuery) StoreError![]MemoryEntry;
pub fn forget(self, id: []const u8) StoreError!void;
pub fn count(self) usize;
pub fn clear(self) void;
```

### EpisodicMemory

Default in-memory ring-buffer implementation. Drops oldest entry when full.

```zig
var mem = zaibase.memory.EpisodicMemory.init(allocator, 1024);
defer mem.deinit();
var store = mem.asMemoryStore();
try store.store(entry);
```

---

