# zaibase

zaibase — Zig AI development base code. Provides shared foundational capabilities for `ourclaw` and other Zig applications.

> **Prerequisite:** use Zig 0.17.0 for build and tests.

## What's Included

| Module | Area | Status |
|--------|------|--------|
| `src/core/logging/` | Structured logging (zero external deps) | ✅ Production-ready |
| `src/core/validation/` | Config & request validation | ✅ Active |
| `src/observability/` | Traces, metrics, observers | ✅ Active |
| `src/contracts/` | Shared error model, envelopes | ✅ Active |
| `src/config/` | Config store, write pipeline | ✅ Active |
| `src/runtime/` | AppContext, event bus, task runner | ✅ Active |
| `src/app/` | Command dispatch, CLI adapters | ✅ Active |
| `src/effects/` | File I/O, process runner, clock | ✅ Active |
| `src/tooling/` | MCP, script host, tool registry | ✅ Active |
| `src/workflow/` | Workflow steps & state machine | ⚠ Evolving |
| `src/servicekit/` | Service framework | ⚠ Evolving |

## Recent Changes

### Dependency Cleanup

- **Removed external `zig-logging` dependency** — replaced with a native logging module (`src/core/logging/`)
- **Removed `zig-release` dependency** — no longer required
- **Zero external runtime dependencies** — the framework now builds entirely from Zig 0.17 standard library

### Zig 0.17 Migration

- Updated `build.zig.zon` to `minimum_zig_version = "0.17.0"`
- All I/O uses `std.Io` APIs (Io.File, Io.Dir, Io.Timestamp)
- File sinks require an `std.Io` parameter

## Logging Module

A self-contained structured logging subsystem at `src/core/logging/`. See [docs/architecture/logging-module.md](docs/architecture/logging-module.md).

### Quick Start

```zig
const framework = @import("framework");

// Logger with console output
var console_sink = framework.ConsoleSink.init(.trace, .pretty);
const io = std.Io.Threaded.global_single_threaded.*.io();
var logger = framework.Logger.init(console_sink.asLogSink(), .info);

logger.info("hello framework", &.{});

// Scoped child logger
var child = logger.child("my_subsystem");
child.warn("something worth noting", &.{});

// With structured fields
logger.info("request completed", &.{
    framework.LogField.string("method", "GET"),
    framework.LogField.uint("duration_ms", 42),
});
```

### Available Sinks

| Sink | File | Description |
|------|------|-------------|
| Console | `sinks/console.zig` | stderr with pretty/compact format |
| Memory | `sinks/memory.zig` | Ring buffer for testing |
| JsonlFile | `sinks/jsonl_file.zig` | Newline-delimited JSON to file |
| TraceTextFile | `sinks/trace_text_file.zig` | Human-readable text file |
| RotatingFile | `sinks/rotating_file.zig` | JSONL with size-based rotation |
| Multi | `sinks/multi.zig` | Fan-out to multiple sinks |

## Documentation

- [Logging Module](docs/architecture/logging-module.md) — Architecture & API reference (English)
- [docs/README.md](docs/README.md) — Full document index
- `examples/` — Runnable demo programs

## Build & Test

```bash
zig build          # compile the framework
zig build test     # run all tests (166/186 pass, see below)
```

### Known Test Failures

5 tests in `native process runner` fail on macOS due to a Zig 0.17 `Io` / test-runner IPC interaction. The same process-spawning and pipe-reading code works correctly in standalone binaries. These tests are expected to pass on Linux and on future Zig releases.

## Project Structure

```
src/
├── core/         # Core types: logging, validation, error, security
├── config/       # Configuration store & pipeline
├── effects/      # Side-effect abstractions: file I/O, process, clock, HTTP
├── observability/# Log observers, metrics, traces
├── runtime/      # AppContext, event bus, task runner
├── app/          # Command dispatch, CLI
├── contracts/    # Shared envelopes, capability manifests
├── tooling/      # MCP client/server, script host, tool registry
├── servicekit/   # Service abstraction
├── workflow/     # Workflow steps & runner
└── root.zig      # Public module exports
```
