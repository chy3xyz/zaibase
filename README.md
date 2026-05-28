# zaibase

zaibase — Zig AI development base code. Provides shared foundational capabilities for `ourclaw` and other Zig applications.

> **Prerequisite:** use Zig 0.17.0 for build and tests.

## What's Included

| Module | Area | Status |
|--------|------|--------|
| `src/core/logging/` | Structured logging (zero external deps) | ✅ Production-ready |
| `src/memory/` | Agent episodic memory store | ✅ Active |
| `src/evolution/` | Self-evolution — experience recording + learner | ✅ Active |
| `src/servicekit/` | Service vtable interface + lifecycle manager | ✅ Active |
| `src/core/validation/` | Config & request validation | ✅ Active |
| `src/observability/` | Traces, metrics, observers | ✅ Active |
| `src/contracts/` | Shared error model, envelopes, capability manifests | ✅ Active |
| `src/config/` | Config store, write pipeline | ✅ Active |
| `src/runtime/` | AppContext, event bus, task runner | ✅ Active |
| `src/app/` | Command dispatch, CLI adapters | ✅ Active |
| `src/effects/` | File I/O, process runner, clock, HTTP client | ✅ Active |
| `src/tooling/` | MCP, script host, tool registry | ✅ Active |
| `src/workflow/` | Workflow steps & state machine | ⚠ Evolving |
| `src/agentkit/` | Provider definitions | ⚠ Evolving |

## Recent Changes

### Zero External Dependencies

- **Removed external `zig-logging`** — replaced with native 1,173-line logging module
- **Removed `zig-release`** — no longer required
- `build.zig.zon` has `.dependencies = .{}` — entire framework builds from Zig 0.17 stdlib only

### Zig 0.17 Migration

- Updated `build.zig.zon` to `minimum_zig_version = "0.17.0"`
- All I/O uses `std.Io` APIs (Io.File, Io.Dir, Io.Timestamp)
- File sinks and effects require an `std.Io` parameter

### Agent Memory & Evolution

- **`src/memory/`** — `MemoryStore` vtable interface + `EpisodicMemory` ring-buffer implementation with tag/timestamp queries
- **`src/evolution/`** — `Experience` recording, `NativeExperienceStore`, `SimpleLearner` that extracts success-rate insights from past actions

### Service Kit

- **`src/servicekit/`** — `Service` vtable interface (start/stop/health), `NativeEchoService`, `ServiceManager` with lifecycle and aggregate health reporting

## Quick Start

```zig
const zaibase = @import("zaibase");

// Logger with console output
var sink = zaibase.ConsoleSink.init(.trace, .pretty);
var logger = zaibase.Logger.init(sink.asLogSink(), .info);

logger.info("hello zaibase", &.{});

// Scoped child logger
var child = logger.child("my_subsystem");
child.warn("something worth noting", &.{});

// With structured fields
logger.info("request completed", &.{
    zaibase.LogField.string("method", "GET"),
    zaibase.LogField.uint("duration_ms", 42),
});
```

## Documentation

- [Logging, Memory & Evolution Reference](docs/architecture/logging-module.md) — English API docs covering all 3 modules
- [docs/README.md](docs/README.md) — Full document index
- `examples/` — Runnable demo programs

## Build & Test

```bash
zig build          # compile the framework
zig build test     # run all tests
```

### Known Test Failures

5 tests in `native process runner` fail on macOS due to a Zig 0.17 `Io` / test-runner IPC interaction. The same process-spawning and pipe-reading code works correctly in standalone binaries. These tests are expected to pass on Linux and on future Zig releases.

## Project Structure

```
src/
├── core/          # Core types: logging, validation, error, security
├── memory/        # Agent memory store (MemoryStore vtable + EpisodicMemory)
├── evolution/     # Self-evolution (Experience + Learner/Insight)
├── servicekit/    # Service vtable interface + ServiceManager
├── config/        # Configuration store & write pipeline
├── effects/       # Side-effect abstractions: file I/O, process, clock, HTTP
├── observability/ # Log observers, metrics, traces, request/step/summary traces
├── runtime/       # AppContext DI container, event bus, task runner
├── app/           # Command dispatch, CLI adapters
├── contracts/     # Shared envelopes, capability manifests
├── tooling/       # MCP client/server, script host, tool registry & runner
├── workflow/      # Workflow steps & state machine
├── agentkit/      # Provider definitions
└── root.zig       # Public module exports
```
