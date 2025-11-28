// Imports and
const std = @import("std");

const builtin = @import("builtin");

const win32 = @import("win32");

const cli = @import("cli.zig");
const log = @import("log.zig");
const trayapp = @import("trayapp.zig");

const wm = win32.ui.windows_and_messaging;
const fnd = win32.foundation;
// -----------------------------------------------------------------------------

pub const std_options: std.Options = .{
    .log_level = if (@import("builtin").mode == .Debug) .debug else .err,
    .logFn = log.writeToFileBackend,
};

pub fn main() !void {
    // Init logging
    const cwd = std.fs.cwd();
    log.file = cwd.createFile("ztray.log", .{}) catch null;
    defer {
        if (log.file) |f| {
            _ = f.sync() catch {};
            f.close();
        }
    }

    std.log.info("----------------- starting -----------------", .{});

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa_state.deinit();

        if (builtin.mode == .Debug) {
            std.debug.assert(status == .ok);
        }
    }
    const allocator = gpa_state.allocator();

    std.log.info("Parsing command-line options...", .{});
    const opts = try cli.parseOptions(allocator);
    defer allocator.free(opts.args);

    std.log.info("Running tray application...", .{});
    try trayapp.runTrayApp(allocator, opts);
}
