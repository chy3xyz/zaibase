# Development Rules & Conventions

This document captures the idiomatic patterns and conventions used throughout zaibase. When adding or reviewing code, follow these rules.

## 1. VTable Interface Pattern

Every pluggable subsystem uses the same erased-dispatch pattern:

```zig
// --- Interface (the type consumers use) ---
pub const MyService = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        doThing: *const fn (ptr: *anyopaque, arg: u32) DoThingError!void,
        getName: *const fn (ptr: *anyopaque) []const u8,
    };

    pub fn doThing(self: MyService, arg: u32) DoThingError!void {
        return self.vtable.doThing(self.ptr, arg);
    }
    pub fn getName(self: MyService) []const u8 {
        return self.vtable.getName(self.ptr);
    }
};

// --- Implementation (one per backend) ---
pub const NativeMyService = struct {
    state: u32 = 0,

    const vtable = MyService.VTable{
        .doThing = doThingErased,
        .getName = getNameErased,
    };

    pub fn init() NativeMyService { return .{}; }
    pub fn asService(self: *NativeMyService) MyService {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    // --- erased trampolines ---
    fn doThingErased(ptr: *anyopaque, arg: u32) MyService.DoThingError!void {
        const self: *NativeMyService = @ptrCast(@alignCast(ptr));
        return self.doThing(arg);
    }
    fn getNameErased(ptr: *anyopaque) []const u8 {
        const self: *NativeMyService = @ptrCast(@alignCast(ptr));
        return self.name;
    }
};
```

**Rules:**
- Always use `@ptrCast(@alignCast(ptr))` — never just `@ptrCast`
- Erased functions are `pub` (VTable can be read-only or in another file scope)
- Error sets are declared on the interface, not on individual VTable fn types

## 2. Error Handling

### 2.1 Narrow error sets — never `anyerror!`

```zig
// BAD — callers can't handle specific errors:
pub fn publish(self: *Self, topic: []const u8) anyerror!u64;

// GOOD — explicit error set:
pub const PublishError = error{ OutOfMemory, TopicTooLong } || std.mem.Allocator.Error;
pub fn publish(self: *Self, topic: []const u8) PublishError!u64;
```

### 2.2 Observer-style: swallow errors internally

When a write/flush path must never block the caller, catch internally:

```zig
pub fn record(self: *Self, topic: []const u8, payload: []const u8) void {
    self.recordInternal(topic, payload) catch {
        self.degraded = true;
        self.dropped += 1;
    };
}
```

## 3. Module Structure

Every module follows the same layout:

```
src/mymod/
├── root.zig      # Barrel: re-exports, MODULE_NAME, MODULE_STAGE, refAllDecls test
├── some_type.zig # Types or interfaces
└── impl.zig      # Default implementation (e.g. NativeXxx)
```

`root.zig` template:

```zig
const std = @import("std");
pub const MODULE_NAME = "mymod";
pub const sub_one = @import("sub_one.zig");
pub const SubType = sub_one.SubType;

pub const ModuleStage = enum { scaffold, evolving, stable };
pub const MODULE_STAGE: ModuleStage = .evolving;

test { std.testing.refAllDecls(@This()); }
```

## 4. Error Sets in VTable Dispatch

Error sets must be declared on the **Interface** as a named type, not inlined:

```zig
// GOOD
pub const MyInterface = struct {
    pub const DoError = error{ SpecificError };
    pub const VTable = struct {
        doIt: *const fn (ptr: *anyopaque) DoError!void,
    };
};

// BAD — can't reference this from callers
pub const VTable = struct {
    doIt: *const fn (ptr: *anyopaque) error{SpecificError}!void,
};
```

## 5. Testing

### 5.1 Memory / resource lifecycle

Always pair `init` with `defer deinit()`:

```zig
test "episodic memory stores and forgets" {
    var mem = EpisodicMemory.init(std.testing.allocator, 8);
    defer mem.deinit();

    const entry = MemoryEntry{ .id = "m1", .key = "k", .value = "v" };
    try mem.store(try entry.clone(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 1), mem.count());
}
```

### 5.2 Clone from const struct literals

Zig 0.17 does not allow method calls on struct literals directly. Always store first:

```zig
// BAD — compile error:
const e = try MemoryEntry{ .id = "m1" }.clone(allocator);

// GOOD:
const src = MemoryEntry{ .id = "m1", .key = "k", .value = "v" };
const e = try src.clone(allocator);
defer e.deinit(allocator);
```

### 5.3 Allocator conventions

- Use `std.testing.allocator` for tests (catches leaks)
- Never use `std.heap.page_allocator` except in page-size-aware internal buffers
- Pass allocators as parameters, never hardcode

## 6. JSON Handling

Use `std.json` for structured output. Avoid hand-rolling serialization:

```zig
// GOOD:
const output = try std.json.stringifyAlloc(allocator, data, .{});

// BAD — manual string concatenation:
try out.appendSlice(allocator, "{\"key\":\"value\"}");
```

## 7. Regression Prevention

| Check | Command |
|-------|---------|
| Compile | `zig build` |
| Full test | `zig build test` |
| Leak check | **Require 0 leaks** in `std.testing.allocator` |
| Crash check | **Require 0 crashes** in test output |

Add the following to `.gitignore`:

```
zig-cache/
zig-out/
.deepseek/
.test_*
```

## 8. Documentation

- Public API functions get doc comments (`///` or `//!`)
- Module root has a `//!` doc comment explaining the module's purpose
- Examples live in `examples/`, not `src/`
- Architecture docs live in `docs/architecture/`
- English preferred for new docs; existing Chinese docs are gradually migrated

## 9. Common Mistakes

| Mistake | Fix |
|---------|-----|
| `while (!mutex.tryLock()) {}` | Add `{ std.atomic.spinLoopHint(); }` |
| `anyerror!void` return on record/flush | Return `void`, swallow errors internally |
| `@memcpy` from TLS buffer to itself | Check pointer equality before copying |
| MultiSink borrowing a freed slice | Own a copy via `allocator.dupe` |
| Freeing a `&"literal string"` | Track which allocations succeeded |
| Method call on struct literal | Assign to `const` variable first |

## 10. VTable Pattern Cheatsheet

```zig
// Module layout for "MyService" with in-memory backend:

pub const MyService = struct {          // ← Interface
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {         // ← VTable type
        doIt: *const fn (ptr: *anyopaque, arg: u32) DoError!void,
    };
    pub const DoError = error{ SomeErr };

    // ← VTable dispatch methods
    pub fn doIt(self: @This(), arg: u32) DoError!void {
        return self.vtable.doIt(self.ptr, arg);
    }
};

// --- Implementation in separate file ---
pub const NativeMyService = struct {
    const Self = @This();
    const vtable = MyService.VTable{ .doIt = doItErased };
    pub fn asInterface(self: *Self) MyService { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }
    fn doItErased(ptr: *anyopaque, arg: u32) MyService.DoError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.doIt(arg);           // ← real implementation
    }
};
```
