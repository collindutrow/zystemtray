const std = @import("std");

const clap = @import("clap");

const log = @import("log.zig");
const Options = @import("options.zig").Options;
const winutil = @import("winutil.zig");

const params_string =
    \\-h, --help            Show this help and exit.
    \\-i, --icon <STR>      Path to .ico file to use as tray icon.
    \\-t, --tooltip <STR>   Tray tooltip text.
    \\-m, --minimized       Start target application hidden.
    \\-p, --persistent      Do not kill child process when tray exits.
    \\<PROGRAM>             Program to launch.
    \\<ARG>...              Arguments for the program.
    \\
;

pub fn parseOptions(allocator: std.mem.Allocator) !Options {
    const params = comptime clap.parseParamsComptime(params_string);

    const parsers = .{
        .STR = clap.parsers.string,
        .PROGRAM = clap.parsers.string,
        .ARG = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        _ = winutil.ensureParentConsoleAttached();
        try diag.reportToFile(.stderr(), err);
        std.log.info("Error parsing command-line options.", .{});
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        // Attach to parent console if present so user can see help text since we exit immediately
        _ = winutil.ensureParentConsoleAttached();
        std.debug.print(
            \\Usage: ztray [options] <program> [-- program-args...]
            \\
            \\Options:
        , .{});
        std.debug.print(params_string, .{});
        std.debug.print(
            \\Examples:
            \\  ztray ping.exe -- 127.0.0.1 -t
            \\  ztray -m ping.exe -- 127.0.0.1 -t
            \\
        , .{});
        std.log.info("Displayed help, exiting.", .{});
        std.process.exit(0);
    }

    // Validate required PROGRAM argument
    const prog_opt = res.positionals[0];
    if (prog_opt == null) {
        std.log.info("Missing program argument.", .{});
        return error.MissingProgram;
    }
    const program_raw = prog_opt.?;

    // Owned copies (so we don't point into clap's arena after res.deinit)
    var program: []u8 = undefined;
    var program_init = false;

    var args_buf = std.ArrayListUnmanaged([]const u8){};
    var icon_path_owned: ?[]u8 = null;
    var tooltip_owned: ?[]u8 = null;

    // Cleanup on error
    errdefer {
        if (program_init) allocator.free(program);
        if (icon_path_owned) |s| allocator.free(s);
        if (tooltip_owned) |s| allocator.free(s);
        for (args_buf.items) |a| allocator.free(a);
        args_buf.deinit(allocator);
    }

    // Duplicate program
    program = try allocator.dupe(u8, program_raw);
    program_init = true;

    // Duplicate args
    const arg_slice = res.positionals[1];

    // If there are any args
    if (arg_slice.len > 0) {
        var start: usize = 0;

        // Skip leading "--" if present
        if (std.mem.eql(u8, arg_slice[0], "--")) {
            start = 1;
        }

        var i: usize = start;
        while (i < arg_slice.len) : (i += 1) {
            const a = arg_slice[i];
            const dup = try allocator.dupe(u8, a);
            try args_buf.append(allocator, dup);
        }
    }

    // Duplicate icon/tooltip if present
    if (res.args.icon) |icon_raw| {
        icon_path_owned = try allocator.dupe(u8, icon_raw);
    }

    if (res.args.tooltip) |tooltip_raw| {
        tooltip_owned = try allocator.dupe(u8, tooltip_raw);
    }

    const args_owned = try args_buf.toOwnedSlice(allocator);

    // Success: return owned slices; errdefer will not run.
    return Options{
        .program = program, // []u8 → []const u8
        .args = args_owned,
        .icon_path = if (icon_path_owned) |s| s else null,
        .tooltip = if (tooltip_owned) |s| s else null,
        .start_minimized = res.args.minimized != 0,
        .persistent = res.args.persistent != 0,
    };
}
