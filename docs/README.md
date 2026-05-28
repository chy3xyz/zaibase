# docs

## Quick Start

```bash
zig build                  # compile
zig build test             # run tests
zig-out/bin/logging-basic  # run a logging example
```

Add zaibase as a Zig dependency in `build.zig.zon`:

```zig
.dependencies = .{
    .zaibase = .{
        .url = "https://github.com/chy3xyz/zaibase/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

Then in your code:

```zig
const zaibase = @import("zaibase");

var sink = zaibase.ConsoleSink.init(.trace, .pretty);
var logger = zaibase.Logger.init(sink.asLogSink(), .info);
logger.info("hello zaibase", &.{});
```

## Modules

| Document | Covers |
|----------|--------|
| `architecture/logging.md` | LogLevel, LogRecord, LogField, logger API, all sink types, observability integration |
| `architecture/memory.md` | MemoryStore vtable, MemoryEntry, MemoryQuery, EpisodicMemory |
| `architecture/evolution.md` | Experience, ExperienceOutcome, NativeExperienceStore, SimpleLearner, Insight |

## Project

- Source: `src/`
- Examples: `examples/`
- Conventions: `references/RULES.md`
