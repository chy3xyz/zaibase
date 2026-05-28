[中文](README_CN.md) | English

# zig-release

Cross-platform release tool for Zig projects. Auto-generates CHANGELOG, bumps version, tags, and pushes to trigger CI.

Zero external dependencies. Pure Zig. Works on Windows/Linux/macOS.

## Usage in Your Project

### 1. Add dependency

`build.zig.zon`:

```zig
.@"zig-release" = .{
    .url = "https://github.com/topaihub/zig-release/archive/{COMMIT_HASH}.tar.gz",
    .hash = "...",
},
```

### 2. Add release step

`build.zig`:

```zig
const release_dep = b.dependency("zig-release", .{});
const zig_release = @import("zig-release");
zig_release.addReleaseStep(b, release_dep, .{});
```

To specify a repo URL (auto-detected from `git remote` by default):

```zig
zig_release.addReleaseStep(b, release_dep, .{
    .repo_url = "https://github.com/yourname/yourproject",
});
```

### 3. Release

```bash
zig build release -- patch    # v1.0.0 -> v1.0.1
zig build release -- minor    # v1.0.0 -> v1.1.0
zig build release -- major    # v1.0.0 -> v2.0.0
zig build release -- 2.5.0    # specify version directly
```

## What It Does

1. Gets current version from latest git tag
2. Calculates new version
3. Generates CHANGELOG from git log (grouped by conventional commits, with emoji)
4. Shows preview and asks for confirmation
5. Updates `CHANGELOG.md`
6. Updates version in `build.zig.zon`
7. git commit → tag → push
8. Triggers GitHub Actions / CI build

## Commit Categories

| Prefix | Category |
|--------|----------|
| `feat` | ✨ New Features |
| `fix` | 🐛 Bug Fixes |
| `docs` | 📝 Documentation |
| `refactor` | ♻️ Refactoring |
| `perf` | ⚡ Performance |
| `ci` | 👷 CI/CD |
| `chore` | 🔧 Other |

## Requirements

- Zig 0.16.0+
- Git

## License

MIT
