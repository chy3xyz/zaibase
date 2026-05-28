const std = @import("std");
const builtin = @import("builtin");

pub const ProcessEnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const ProcessRunRequest = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const ProcessEnvVar = &.{},
    stdin: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
    max_output_bytes: usize = 64 * 1024,
};

pub const ProcessTerminationKind = enum {
    exited, signal, stopped, unknown,
    pub fn asText(self: ProcessTerminationKind) []const u8 {
        return switch (self) {
            .exited => "exited", .signal => "signal", .stopped => "stopped", .unknown => "unknown",
        };
    }
};

pub const ProcessRunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,
    term_kind: ProcessTerminationKind,
    pub fn deinit(self: *ProcessRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const ProcessRunner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: ProcessRunRequest) anyerror!ProcessRunResult,
        name: *const fn (ptr: *anyopaque) []const u8,
        deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
    };
    pub fn run(self: ProcessRunner, allocator: std.mem.Allocator, request: ProcessRunRequest) anyerror!ProcessRunResult {
        return self.vtable.run(self.ptr, allocator, request);
    }
    pub fn name(self: ProcessRunner) []const u8 { return self.vtable.name(self.ptr); }
    pub fn deinit(self: ProcessRunner, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |deinit_fn| deinit_fn(self.ptr, allocator);
    }
};

pub const NativeProcessRunner = struct {
    const vtable = ProcessRunner.VTable{ .run = runErased, .name = nameErased, .deinit = null };
    pub fn init() NativeProcessRunner { return .{}; }
    pub fn runner(self: *NativeProcessRunner) ProcessRunner {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
    pub fn runnerName() []const u8 { return "native"; }

    fn getIo() std.Io {
        const t = std.Io.Threaded.global_single_threaded;
        if (t.allocator.vtable == std.mem.Allocator.failing.vtable) {
            t.allocator = std.heap.page_allocator;
        }
        return t.*.io();
    }

    pub fn run(_: *NativeProcessRunner, allocator: std.mem.Allocator, request: ProcessRunRequest) !ProcessRunResult {
        if (request.argv.len == 0) return error.EmptyProcessArgv;
        const io = getIo();

        var env_map = try buildEnvMap(allocator, request.env);
        defer if (env_map) |*map| map.deinit();

        var child = try std.process.spawn(io, .{
            .argv = request.argv,
            .stdin = if (request.stdin != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = if (request.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = if (env_map) |*map| map else null,
        });
        errdefer child.kill(io);

        if (request.stdin) |stdin_bytes| {
            const stdin_file = child.stdin.?;
            try stdin_file.writeStreamingAll(io, stdin_bytes);
            stdin_file.close(io);
            child.stdin = null;
        }

        const stdout_file = child.stdout.?;
        child.stdout = null;
        const stderr_file = child.stderr.?;
        child.stderr = null;

        var stdout_cap = PipeCapture.init(stdout_file, io, request.max_output_bytes);
        var stderr_cap = PipeCapture.init(stderr_file, io, request.max_output_bytes);
        const stdout_thread = try std.Thread.spawn(.{}, PipeCapture.run, .{&stdout_cap});
        const stderr_thread = try std.Thread.spawn(.{}, PipeCapture.run, .{&stderr_cap});

        const term = waitForExit(&child, request.timeout_ms) catch |err| {
            if (err == error.ProcessTimedOut) child.kill(io);
            stdout_thread.join();
            stderr_thread.join();
            stdout_cap.deinit();
            stderr_cap.deinit();
            return err;
        };

        stdout_thread.join();
        stderr_thread.join();
        defer stdout_cap.deinit();
        defer stderr_cap.deinit();

        const stdout_bytes = try stdout_cap.toOwnedSlice(allocator);
        errdefer allocator.free(stdout_bytes);
        const stderr_bytes = try stderr_cap.toOwnedSlice(allocator);
        errdefer allocator.free(stderr_bytes);

        return .{
            .stdout = stdout_bytes,
            .stderr = stderr_bytes,
            .exit_code = exitCodeFromTerm(term),
            .term_kind = termKindFromTerm(term),
        };
    }

    fn runErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: ProcessRunRequest) anyerror!ProcessRunResult {
        return @as(*NativeProcessRunner, @ptrCast(@alignCast(ptr))).run(allocator, request);
    }
    fn nameErased(_: *anyopaque) []const u8 { return runnerName(); }
};

const PipeCapture = struct {
    file: std.Io.File,
    io: std.Io,
    max_output_bytes: usize,
    bytes: ?[]u8 = null,
    status: Status = .pending,
    const Status = enum { pending, ok, too_long, read_failed };

    fn init(file: std.Io.File, io: std.Io, max_output_bytes: usize) PipeCapture {
        return .{ .file = file, .io = io, .max_output_bytes = max_output_bytes };
    }

    fn run(self: *PipeCapture) void {
        defer self.file.close(self.io);
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(std.heap.page_allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.file.readStreaming(self.io, &.{&buf}) catch break;
            if (n == 0) break;
            if (list.items.len + n > self.max_output_bytes) {
                self.status = .too_long;
                return;
            }
            list.appendSlice(std.heap.page_allocator, buf[0..n]) catch {
                self.status = .read_failed;
                return;
            };
        }
        self.bytes = list.toOwnedSlice(std.heap.page_allocator) catch {
            self.status = .read_failed;
            return;
        };
        self.status = .ok;
    }

    fn toOwnedSlice(self: *const PipeCapture, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.status) {
            .ok => allocator.dupe(u8, self.bytes orelse &.{}),
            .too_long => error.OutputTooLong,
            .read_failed => error.StdoutReadFailed,
            .pending => unreachable,
        };
    }

    fn deinit(self: *PipeCapture) void {
        if (self.bytes) |bytes| {
            std.heap.page_allocator.free(bytes);
            self.bytes = null;
        }
    }
};

fn buildEnvMap(allocator: std.mem.Allocator, env_vars: []const ProcessEnvVar) !?std.process.Environ.Map {
    if (env_vars.len == 0) return null;
    var env_map = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
    errdefer env_map.deinit();
    for (env_vars) |entry| try env_map.put(entry.key, entry.value);
    return env_map;
}

fn waitForExit(child: *std.process.Child, timeout_ms: ?u32) !std.process.Child.Term {
    const io = std.Io.Threaded.global_single_threaded.*.io();
    if (timeout_ms == null) return child.wait(io);
    const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + @as(i64, timeout_ms.?);
    while (true) {
        if (std.Io.Timestamp.now(io, .real).toMilliseconds() >= deadline) return error.ProcessTimedOut;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
        if (try pollExited(child)) |term| return term;
    }
}

fn pollExited(child: *std.process.Child) !?std.process.Child.Term {
    if (child.id == null) return null;
    const pid = child.id.?;
    var status: c_int = 0;
    const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (rc == 0) return null;
    if (rc < 0) return error.ProcessWaitFailed;
    const term = statusToTerm(@bitCast(status));
    child.id = null;
    return term;
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

fn exitCodeFromTerm(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .stopped => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .unknown => |status| -@as(i32, @intCast(status)),
    };
}

fn termKindFromTerm(term: std.process.Child.Term) ProcessTerminationKind {
    return switch (term) {
        .exited => .exited, .signal => .signal, .stopped => .stopped, .unknown => .unknown,
    };
}

pub fn shellArgv(command: []const u8) []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "cmd.exe", "/C", command },
        else => &.{ "sh", "-c", command },
    };
}

fn trimLineEndings(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, "\r\n");
}

test "native process runner executes command successfully" {
    var runner_inst = NativeProcessRunner.init();
    var result = try runner_inst.run(std.testing.allocator, .{ .argv = shellArgv("echo hello") });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("hello", trimLineEndings(result.stdout));
    try std.testing.expectEqualStrings("", trimLineEndings(result.stderr));
    try std.testing.expectEqualStrings("exited", result.term_kind.asText());
}

test "native process runner reports missing command" {
    var runner_inst = NativeProcessRunner.init();
    try std.testing.expectError(error.FileNotFound, runner_inst.run(std.testing.allocator, .{
        .argv = &.{"definitely_missing_framework_process_runner_binary"},
    }));
}

test "native process runner returns non-zero exit code" {
    const command = switch (builtin.os.tag) { .windows => "exit /B 7", else => "exit 7" };
    var runner_inst = NativeProcessRunner.init();
    var result = try runner_inst.run(std.testing.allocator, .{ .argv = shellArgv(command) });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 7), result.exit_code);
    try std.testing.expectEqualStrings("exited", result.term_kind.asText());
}

test "native process runner enforces timeout" {
    const command = switch (builtin.os.tag) { .windows => "ping 127.0.0.1 -n 3 >NUL", else => "sleep 1" };
    var runner_inst = NativeProcessRunner.init();
    try std.testing.expectError(error.ProcessTimedOut, runner_inst.run(std.testing.allocator, .{
        .argv = shellArgv(command), .timeout_ms = 100,
    }));
}

test "native process runner honors cwd" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.*.io();
    const cwd_path = try tmp_dir.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    const command = switch (builtin.os.tag) { .windows => "cd", else => "pwd" };
    var runner_inst = NativeProcessRunner.init();
    var result = try runner_inst.run(std.testing.allocator, .{ .argv = shellArgv(command), .cwd = cwd_path });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(cwd_path, trimLineEndings(result.stdout));
}

test "native process runner injects env vars" {
    const command = switch (builtin.os.tag) { .windows => "echo %FRAMEWORK_EFFECT_TEST_ENV%", else => "printf '%s' \"$FRAMEWORK_EFFECT_TEST_ENV\"" };
    var runner_inst = NativeProcessRunner.init();
    var result = try runner_inst.run(std.testing.allocator, .{
        .argv = shellArgv(command),
        .env = &.{.{ .key = "FRAMEWORK_EFFECT_TEST_ENV", .value = "effects-ok" }},
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("effects-ok", trimLineEndings(result.stdout));
}
