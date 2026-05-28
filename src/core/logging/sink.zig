//! Log sink interface — the output destination for log records.

const LogRecord = @import("record.zig").LogRecord;

/// Type-erased sink interface. Concrete sinks wrap a vtable.
pub const LogSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, record: LogRecord) void,
        flush: *const fn (ptr: *anyopaque) void,
        deinit: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub fn write(self: LogSink, record: LogRecord) void {
        self.vtable.write(self.ptr, record);
    }

    pub fn flush(self: LogSink) void {
        self.vtable.flush(self.ptr);
    }

    pub fn deinit(self: LogSink) void {
        if (self.vtable.deinit) |f| f(self.ptr);
    }
};
