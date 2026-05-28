//! Structured log field types.

/// A key-value pair attached to a log record.
pub const LogField = struct {
    key: []const u8,
    value: LogFieldValue,

    pub fn string(key: []const u8, val: []const u8) LogField {
        return .{ .key = key, .value = .{ .string = val } };
    }

    pub fn int(key: []const u8, val: i64) LogField {
        return .{ .key = key, .value = .{ .int = val } };
    }

    pub fn uint(key: []const u8, val: u64) LogField {
        return .{ .key = key, .value = .{ .uint = val } };
    }

    pub fn float(key: []const u8, val: f64) LogField {
        return .{ .key = key, .value = .{ .float = val } };
    }

    pub fn boolean(key: []const u8, val: bool) LogField {
        return .{ .key = key, .value = .{ .boolean = val } };
    }

    pub fn err(key: []const u8, val: anyerror) LogField {
        return .{ .key = key, .value = .{ .err = val } };
    }
};

/// Tagged union for field values.
pub const LogFieldValue = union(enum) {
    string: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    boolean: bool,
    err: anyerror,
    null,
};
