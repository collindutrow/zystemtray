const std = @import("std");

pub var file: ?std.fs.File = null;

pub fn writeToFileBackend(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (file) |*f| {
        var buf: [256]u8 = undefined;

        // Prefix: timestamp
        const ts = std.time.milliTimestamp();
        const prefix = std.fmt.bufPrint(&buf, "[{d}]", .{ts}) catch return;
        var used: usize = prefix.len;

        // Prefix: scope
        var scope_buf: [32]u8 = undefined;
        const scope_name = @tagName(scope); // e.g. "App"
        const scope_upper = std.ascii.upperString(&scope_buf, scope_name);
        const scope_prefix = std.fmt.bufPrint(buf[used..], "[{s}]", .{scope_upper}) catch return;
        used += scope_prefix.len;

        // Prefix: level
        const level_str = switch (level) {
            .debug => "DBG",
            .info => "INF",
            .warn => "WRN",
            .err => "ERR",
        };

        const level_prefix = std.fmt.bufPrint(buf[used..], "[{s}]: ", .{level_str}) catch return;
        used += level_prefix.len;

        // Message body
        const msg_slice = std.fmt.bufPrint(buf[used..], fmt, args) catch return;
        used += msg_slice.len;

        // Write full line
        f.writeAll(buf[0..used]) catch return;
        f.writeAll("\n") catch {};
    }
}
