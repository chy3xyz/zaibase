const std = @import("std");
const framework = @import("zaibase");

pub fn main() !void {
    _ = framework;
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "framework bootstrap ready\n");
}


