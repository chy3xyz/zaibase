const std = @import("std");

const Section = struct { prefix: []const u8, label: []const u8 };
const sections = [_]Section{
    .{ .prefix = "feat", .label = "### ✨ 新功能" },
    .{ .prefix = "fix", .label = "### 🐛 Bug 修复" },
    .{ .prefix = "docs", .label = "### 📝 文档" },
    .{ .prefix = "refactor", .label = "### ♻️ 重构" },
    .{ .prefix = "perf", .label = "### ⚡ 性能优化" },
    .{ .prefix = "ci", .label = "### 👷 CI/CD" },
    .{ .prefix = "chore", .label = "### 🔧 其他" },
};

const Config = struct {
    repo_url: []const u8 = "",
    bump: []const u8 = "patch",
};

var io_instance: ?std.Io = null;

fn getIo() std.Io {
    if (io_instance) |io| return io;
    const t = std.Io.Threaded.global_single_threaded;
    t.allocator = std.heap.page_allocator;
    const io = t.*.io();
    io_instance = io;
    return io;
}

fn print(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(getIo(), s) catch {};
}

fn readLine() ?u8 {
    var buf: [8]u8 = undefined;
    const slice: []u8 = &buf;
    const n = std.Io.File.stdin().readStreaming(getIo(), &.{slice}) catch return null;
    if (n == 0) return null;
    return buf[0];
}

fn git(alloc: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const io = getIo();
    var full: std.ArrayListUnmanaged([]const u8) = .empty;
    defer full.deinit(alloc);
    try full.append(alloc, "git");
    try full.appendSlice(alloc, argv);

    var child = try std.process.spawn(io, .{ .argv = full.items, .stdout = .pipe, .stderr = .pipe });
    const file = child.stdout.?;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&tmp}) catch break;
        if (n == 0) break;
        try buf.appendSlice(alloc, tmp[0..n]);
    }
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    return std.mem.trim(u8, buf.items, " \n\r");
}

pub fn parseVersion(s: []const u8) [3]u32 {
    const t = std.mem.trim(u8, s, " \n\rv");
    var it = std.mem.splitScalar(u8, t, '.');
    return .{
        std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0,
        std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0,
        std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0,
    };
}

pub fn bumpVersion(v: [3]u32, bump: []const u8) [3]u32 {
    if (std.mem.eql(u8, bump, "major")) return .{ v[0] + 1, 0, 0 };
    if (std.mem.eql(u8, bump, "minor")) return .{ v[0], v[1] + 1, 0 };
    if (std.mem.eql(u8, bump, "patch")) return .{ v[0], v[1], v[2] + 1 };
    return parseVersion(bump);
}

fn fmtVer(alloc: std.mem.Allocator, v: [3]u32) ![]const u8 {
    return std.fmt.allocPrint(alloc, "v{d}.{d}.{d}", .{ v[0], v[1], v[2] });
}

/// Check if a commit message matches a conventional commit type.
/// Matches "type:", "type(scope):", but not "typewriter" or "fixture".
fn matchesType(msg: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, msg, prefix)) return false;
    if (msg.len <= prefix.len) return false;
    const next = msg[prefix.len];
    return next == ':' or next == '(';
}

fn generateChangelog(alloc: std.mem.Allocator, repo_url: []const u8, tag: []const u8, date: []const u8, log: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, "## [");
    try buf.appendSlice(alloc, tag);
    if (repo_url.len > 0) {
        try buf.appendSlice(alloc, "](");
        try buf.appendSlice(alloc, repo_url);
        try buf.appendSlice(alloc, "/releases/tag/");
        try buf.appendSlice(alloc, tag);
        try buf.appendSlice(alloc, ")");
    } else {
        try buf.appendSlice(alloc, "]");
    }
    try buf.appendSlice(alloc, " (");
    try buf.appendSlice(alloc, date);
    try buf.appendSlice(alloc, ")\n");

    for (&sections) |sec| {
        var found = false;
        var lines = std.mem.splitScalar(u8, log, '\n');
        while (lines.next()) |line| {
            if (line.len < 42) continue;
            const msg = line[41..];
            if (matchesType(msg, sec.prefix)) {
                if (!found) {
                    try buf.appendSlice(alloc, "\n");
                    try buf.appendSlice(alloc, sec.label);
                    try buf.appendSlice(alloc, "\n\n");
                    found = true;
                }
                try buf.appendSlice(alloc, "- ");
                try buf.appendSlice(alloc, msg);
                if (repo_url.len > 0 and line.len >= 40) {
                    try buf.appendSlice(alloc, " ([");
                    try buf.appendSlice(alloc, line[0..7]);
                    try buf.appendSlice(alloc, "](");
                    try buf.appendSlice(alloc, repo_url);
                    try buf.appendSlice(alloc, "/commit/");
                    try buf.appendSlice(alloc, line[0..40]);
                    try buf.appendSlice(alloc, "))");
                }
                try buf.append(alloc, '\n');
            }
        }
    }
    const result = try alloc.dupe(u8, buf.items);
    buf.deinit(alloc);
    return result;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const io = getIo();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    try file.writeStreamingAll(io, content);
    file.close(io);
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(getIo(), path, alloc, @enumFromInt(1048576)) catch null;
}

fn detectRepoUrl(alloc: std.mem.Allocator) []const u8 {
    const remote = git(alloc, &.{ "remote", "get-url", "origin" }) catch return "";
    if (std.mem.endsWith(u8, remote, ".git")) return remote[0 .. remote.len - 4];
    return remote;
}

fn parseArgs(init: std.process.Init, alloc: std.mem.Allocator) Config {
    var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, alloc) catch return .{};
    _ = args_it.next(); // skip program name

    var cfg = Config{};
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--repo")) {
            cfg.repo_url = args_it.next() orelse "";
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            cfg.bump = arg;
        }
    }
    return cfg;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cfg = parseArgs(init, alloc);
    const repo_url = if (cfg.repo_url.len > 0) cfg.repo_url else detectRepoUrl(alloc);

    const latest = git(alloc, &.{ "describe", "--tags", "--abbrev=0" }) catch "v0.0.0";
    const cur = parseVersion(latest);
    const new = bumpVersion(cur, cfg.bump);
    const tag = try fmtVer(alloc, new);
    const date = git(alloc, &.{ "log", "-1", "--format=%cd", "--date=short" }) catch "unknown";

    print(alloc, "\n当前版本: {s}\n新版本:   {s}\n\n", .{ latest, tag });

    const range = try std.fmt.allocPrint(alloc, "{s}..HEAD", .{latest});
    const log = git(alloc, &.{ "log", "--format=%H %s", range, "--no-merges" }) catch "";
    const changelog = try generateChangelog(alloc, repo_url, tag, date, log);

    print(alloc, "--- CHANGELOG 预览 ---\n{s}\n----------------------\n\n确认发布 {s}? (y/N) ", .{ changelog, tag });

    const ch = readLine() orelse return;
    if (ch != 'y' and ch != 'Y') {
        print(alloc, "已取消\n", .{});
        return;
    }

    // Update CHANGELOG.md
    if (readFile(alloc, "CHANGELOG.md")) |old| {
        const content = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ changelog, old });
        try writeFile("CHANGELOG.md", content);
    } else {
        const content = try std.fmt.allocPrint(alloc, "# Changelog\n\nAll notable changes to this project will be documented in this file.\n\n{s}\n", .{changelog});
        try writeFile("CHANGELOG.md", content);
    }

    // Update build.zig.zon version
    if (readFile(alloc, "build.zig.zon")) |old| {
        const needle = ".version = \"";
        if (std.mem.indexOf(u8, old, needle)) |start| {
            const after = start + needle.len;
            if (std.mem.indexOfScalarPos(u8, old, after, '"')) |end| {
                const ver_str = try std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{ new[0], new[1], new[2] });
                const content = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ old[0..after], ver_str, old[end..] });
                try writeFile("build.zig.zon", content);
            }
        }
    }

    _ = git(alloc, &.{ "add", "CHANGELOG.md", "build.zig.zon" }) catch {};
    const msg = try std.fmt.allocPrint(alloc, "chore(release): {s}", .{tag});
    _ = git(alloc, &.{ "commit", "-m", msg }) catch {};
    _ = git(alloc, &.{ "tag", tag }) catch {};
    _ = git(alloc, &.{ "push", "origin", "HEAD" }) catch {};
    _ = git(alloc, &.{ "push", "origin", tag }) catch {};

    print(alloc, "\n✓ {s} 已发布！\n", .{tag});
    if (repo_url.len > 0) {
        print(alloc, "  Release: {s}/releases\n", .{repo_url});
    }
}

// --- Tests ---

test "parseVersion" {
    try std.testing.expectEqual([3]u32{ 1, 2, 3 }, parseVersion("v1.2.3"));
    try std.testing.expectEqual([3]u32{ 0, 0, 0 }, parseVersion(""));
    try std.testing.expectEqual([3]u32{ 10, 0, 1 }, parseVersion("  v10.0.1\n"));
}

test "bumpVersion" {
    try std.testing.expectEqual([3]u32{ 1, 2, 4 }, bumpVersion(.{ 1, 2, 3 }, "patch"));
    try std.testing.expectEqual([3]u32{ 1, 3, 0 }, bumpVersion(.{ 1, 2, 3 }, "minor"));
    try std.testing.expectEqual([3]u32{ 2, 0, 0 }, bumpVersion(.{ 1, 2, 3 }, "major"));
    try std.testing.expectEqual([3]u32{ 5, 0, 0 }, bumpVersion(.{ 1, 2, 3 }, "5.0.0"));
}

test "matchesType" {
    try std.testing.expect(matchesType("feat: add feature", "feat"));
    try std.testing.expect(matchesType("feat(scope): add feature", "feat"));
    try std.testing.expect(matchesType("fix: bug", "fix"));
    try std.testing.expect(!matchesType("feature: not a match", "feat"));
    try std.testing.expect(!matchesType("fixture: not a match", "fix"));
    try std.testing.expect(!matchesType("fe", "feat"));
}

test "generateChangelog" {
    const log = "a" ** 40 ++ " " ++ "feat: add something\n" ++
        "b" ** 40 ++ " " ++ "fix: broken thing\n" ++
        "c" ** 40 ++ " " ++ "feature: should not match";

    const result = try generateChangelog(std.testing.allocator, "https://github.com/test/repo", "v1.0.0", "2026-01-01", log);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "feat: add something") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fix: broken thing") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "feature: should not match") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "✨ 新功能") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "🐛 Bug 修复") != null);
}

test "fmtVer" {
    const v = try fmtVer(std.testing.allocator, .{ 2, 1, 0 });
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("v2.1.0", v);
}
