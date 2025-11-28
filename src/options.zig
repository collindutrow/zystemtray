const std = @import("std");

pub const Options = struct {
    program: []const u8,
    args: []const []const u8,

    icon_path: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    start_minimized: bool = false,
    persistent: bool = false,
};
