# Logging Module

A zero-dependency structured logging subsystem built into zaibase. Replaces the external `zig-logging` package with a native implementation that integrates with zaibase conventions (observability, effects, error model).

## Overview

```
┌─────────────────────────────────────────────────────┐
│                    Your Code                         │
│  logger.info("msg", .{});                            │
│  logger.child("subsystem").warn("msg", .{});         │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│                   Logger                             │
│    ─ level filtering                                  │
│    ─ trace context injection (trace_id, span_id)      │
│    ─ subsystem routing                                │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│                   LogSink  (vtable dispatch)          │
│    ┌─────────┬──────────┬────────┬──────────────┐   │
│    │ Console │ File      │ Memory │ Multi(fanout)│   │
│    └─────────┴──────────┴────────┴──────────────┘   │
└─────────────────────────────────────────────────────┘
```

## Module Layout

```
src/core/logging/
├── root.zig          # Public API re-exports
├── level.zig         # LogLevel enum + "error" alias
├── field.zig         # LogField, LogFieldValue, field factories
├── record.zig        # LogRecord struct + LogRecordKind
├── sink.zig          # LogSink vtable interface
├── logger.zig        # Logger + SubsystemLogger
├── redact.zig        # RedactMode (basic)
└── sinks/
    ├── console.zig         # Console (stderr) sink
    ├── memory.zig          # Ring-buffer in-memory sink
    ├── jsonl_file.zig      # Newline-delimited JSON file sink
    ├── trace_text_file.zig # Human-readable text file sink
    ├── rotating_file.zig   # Rotating JSONL file sink
    └── multi.zig           # Multiplexer (fan-out) sink
```

## Core Types

### LogLevel

```zig
pub const LogLevel = enum(u3) {
    trace,
    debug,
    info,
    warn,
    err,        // Use `.err` or `.@"error"`
    fatal,
    silent,     // Filters everything below this level

    pub const @"error" = LogLevel.err; // Keyword-compatible alias
    pub fn label(self: LogLevel) []const u8;
    pub fn enabled(self: LogLevel, min_level: LogLevel) bool;
};
```

### LogRecord

```zig
pub const LogRecord = struct {
    ts_unix_ms: i64,
    level: LogLevel,
    subsystem: []const u8,
    message: []const u8,
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    duration_ms: ?i64 = null,
    kind: LogRecordKind = .plain,
    fields: []const LogField = &.{},
};
```

### LogRecordKind

```zig
pub const LogRecordKind = enum {
    plain,      // General-purpose log
    request,    // HTTP/CLI request log
    method,     // Method-level trace
    summary,    // Summary trace (ME/RT/BT/ET)
    step,       // Step-level trace
};
```

### LogField

```zig
pub const LogField = struct {
    key: []const u8,
    value: LogFieldValue,

    // Factory functions:
    pub fn string(key: []const u8, value: []const u8) LogField;
    pub fn int(key: []const u8, value: i64) LogField;
    pub fn uint(key: []const u8, value: u64) LogField;
    pub fn float(key: []const u8, value: f64) LogField;
    pub fn boolean(key: []const u8, value: bool) LogField;
};

pub const LogFieldValue = union(enum) {
    string: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    boolean: bool,
    err: anyerror,
    null,
};
```

### LogSink

```zig
pub const LogSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, record: LogRecord) void,
        flush: *const fn (ptr: *anyopaque) void,
        deinit: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub fn write(self: LogSink, record: LogRecord) void;
    pub fn flush(self: LogSink) void;
};
```

## Logger API

### Initialization

```zig
var sink: LogSink = ...;
var logger = Logger.init(sink, .info);
defer logger.deinit();
```

### Logging Methods

```zig
// Basic logging
logger.log(.info, "subsystem", "message", &.{});
logger.logWithKind(.info, "subsystem", "message", .request, &.{});

// Convenience (empty subsystem)
logger.info("message", &.{});
logger.warn("message", &.{});
logger.err("message", &.{});

// With trace context
logger.setTraceContextProvider(provider);
```

### SubsystemLogger

```zig
// Create a scoped child logger
var sub = logger.child("http");  // subsystem = "http"
var nested = sub.child("auth");  // subsystem = "http/auth"

// Log with explicit record kind (for observability layer)
sub.logKind(.err, .request, "TRACE_REQUEST", &.{});
```

## Built-in Sinks

### Console

Writes to stderr with pretty or compact formatting.

```zig
const sink = Console.init(.info, .pretty);
const ls = sink.asLogSink();
```

### Memory

Ring-buffer sink for testing. Stores up to N records.

```zig
var sink = Memory.init(allocator, 64);
const ls = sink.asLogSink();
const r = sink.latest();
const all = sink.drain();
```

### JsonlFile

Newline-delimited JSON output.

```zig
var sink = try JsonlFile.init(allocator, "/tmp/log.jsonl", null, io);
const ls = sink.asLogSink();
```

### TraceTextFile

Human-readable text output with timestamps, optimized for grep.

```zig
var sink = try TraceTextFile.init(allocator, .{ .path = "/tmp/trace.txt" }, io);
const ls = sink.asLogSink();
```

### RotatingFile

JSONL with size-based rotation.

```zig
var sink = try RotatingFile.init(allocator, .{
    .path = "/tmp/app.jsonl",
    .max_bytes = 8 * 1024 * 1024,
    .max_files = 3,
}, io);
const ls = sink.asLogSink();
```

### Multi

Fan-out to multiple sinks. Owns a copy of the sink slice.

```zig
const multi = try Multi.init(allocator, &.{ sink1.asLogSink(), sink2.asLogSink() });
```

## Observability Integration

| Trace Type      | `LogRecordKind` | Sink Label          |
|-----------------|-----------------|---------------------|
| RequestTrace    | `.request`      | `TRACE_REQUEST`     |
| MethodTrace     | `.method`       | `ENTRY` / `EXIT`    |
| SummaryTrace    | `.summary`      | `TRACE_SUMMARY`     |
| StepTrace       | `.step`         | `TRACE_STEP`        |

## Sink Error Handling

All sink write/flush errors are swallowed (via `catch {}` in production sinks). This is by design: logging must never block the main code path.

## Thread Safety

The `Logger` and sink types are **not** internally synchronized. In a multithreaded application, each thread should either own its own `Logger` or use a dedicated logging thread fed via a channel.

## Zig Version Compatibility

Requires Zig 0.17.0+. The module uses `std.Io` APIs (Io.File, Io.Dir, Io.Timestamp) which were introduced in Zig 0.17. File sinks require an `std.Io` parameter for all I/O operations.

---

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
