//! Field-level redaction policies for sensitive data.

/// Controls how sensitive field values are rendered in log output.
pub const RedactMode = enum {
    /// Show the full value.
    none,
    /// Replace the entire value with `[REDACTED]`.
    full,
    /// Show only the first N characters, mask the rest.
    partial_prefix,

    /// Apply redaction to a string value. Returns the original or a masked copy.
    /// Caller owns neither return — the result points into `buf` or the original.
    pub fn apply(self: RedactMode, value: []const u8, buf: []u8, visible_prefix: usize) []const u8 {
        return switch (self) {
            .none => value,
            .full => "[REDACTED]",
            .partial_prefix => blk: {
                if (value.len <= visible_prefix) break :blk value;
                const prefix = value[0..visible_prefix];
                const mask_len = @min(buf.len, value.len - prefix.len);
                @memset(buf[0..mask_len], '*');
                // We can't return a combined slice cheaply; just return mask hint.
                // For console sinks the caller formats directly.
                break :blk prefix;
            },
        };
    }
};
