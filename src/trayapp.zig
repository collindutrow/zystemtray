const std = @import("std");

const win32 = @import("win32");

const encode = @import("encode.zig");
const log = @import("log.zig");
const Options = @import("options.zig").Options;
const process = @import("process.zig");
const traylib = @import("tray.zig");
const winutil = @import("winutil.zig");

const fs = win32.storage.file_system;
const fnd = win32.foundation;
const wm = win32.ui.windows_and_messaging;
const lib = win32.system.library_loader;
const shell = win32.ui.shell;

var child_process: process.ProcessContext = undefined;

fn onTrayClick(hwnd: fnd.HWND) void {
    _ = hwnd;

    // If child's main window is unknown
    if (child_process.main_hwnd == null) {
        // Try to discover main window
        std.log.info("Tray click: main window unknown, trying to discover...", .{});
        child_process.main_hwnd = winutil.findMainWindowForProcessId(child_process.pid);
        if (child_process.main_hwnd == null) {
            // Still no main window
            std.log.info("Tray click: still no main window for PID {d}", .{child_process.pid});
            return;
        }
        std.log.info("Tray click: discovered main window for PID {d}", .{child_process.pid});
    }

    winutil.toggleWindow(child_process.main_hwnd);
    winutil.activateWindow(child_process.main_hwnd);
}

fn loadIconFromFile(
    allocator: std.mem.Allocator,
    utf8_path: []const u8,
) ?wm.HICON {
    const wide = encode.utf8ToWideNul(allocator, utf8_path) catch return null;
    defer allocator.free(wide);

    const pw: [*:0]u16 = @ptrCast(wide.ptr);

    const icon = wm.LoadImageW(
        null,
        pw,
        wm.IMAGE_ICON,
        0,
        0,
        wm.LR_LOADFROMFILE,
    );
    return if (icon == null) null else @ptrCast(icon);
}

fn loadProgramIcon(allocator: std.mem.Allocator, program_utf8: []const u8) ?wm.HICON {
    // Very simple heuristic: only treat as path if it looks like one.
    if (std.mem.indexOfAny(u8, program_utf8, "\\/:") == null) return null;

    const utf16 = encode.utf8ToWideNul(allocator, program_utf8) catch return null;
    defer allocator.free(utf16);

    const prog_pwstr: [*:0]u16 = @as([*:0]u16, @ptrCast(utf16.ptr));

    // Try to resolve full path via SearchPathW
    var buf: [260:0]u16 = undefined;
    var file_part: ?[*:0]u16 = null;

    const result = fs.SearchPathW(
        null, // lpPath
        prog_pwstr, // lpFileName
        null, // lpExtension
        buf.len, // nBufferLength
        &buf, // lpBuffer
        &file_part, // lpFilePart
    );
    if (result == 0 or result > buf.len) {
        // Fall back to original string directly
        const icon1 = shell.ExtractIconW(null, prog_pwstr, 0);
        if (icon1 != null and icon1 != @as(wm.HICON, @ptrFromInt(1))) return icon1;
        return null;
    }

    // buf now contains NUL-terminated full path
    const full_path: [*:0]u16 = @as([*:0]u16, @ptrCast(&buf));

    const icon2 = shell.ExtractIconW(null, full_path, 0);
    if (icon2 == null or icon2 == @as(wm.HICON, @ptrFromInt(1))) return null;

    return icon2;
}

fn loadOwnIcon(hinst: fnd.HINSTANCE) ?wm.HICON {
    // Try default application icon (resource ID 32512)
    const icon = wm.LoadIconW(hinst, wm.IDI_APPLICATION);
    return if (icon == null) null else @ptrCast(icon);
}

fn makeTooltip(allocator: std.mem.Allocator, opts: Options) ![:0]u16 {
    const text = blk: {
        if (opts.tooltip) |t| break :blk t;
        break :blk std.fs.path.basename(opts.program);
    };

    // Convert UTF-8 → UTF-16 (no sentinel)
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(utf16);

    // Allocate UTF-16 with sentinel 0
    const out = try allocator.allocSentinel(u16, utf16.len, 0);

    // Copy and return
    std.mem.copyForwards(u16, out[0..utf16.len], utf16);
    return out;
}

fn waitThreadMain(child: *process.ProcessContext) void {
    process.waitForExit(child);
    std.log.info("Child process exited, terminating.", .{});
    std.process.exit(0);
}

pub fn runTrayApp(allocator: std.mem.Allocator, opts: Options) !void {
    std.log.info("Spawning child process...", .{});
    // Spawn child process
    child_process = try process.spawnChild(allocator, opts.program, opts.args);

    // Repeatedly try to discover the main window for up to ~5 seconds
    var attempt: usize = 0;
    while (attempt < 50 and child_process.main_hwnd == null) : (attempt += 1) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        child_process.main_hwnd = winutil.findMainWindowForProcessId(child_process.pid);
    }

    if (child_process.main_hwnd) |h| {
        std.log.info("Startup: discovered main window HWND={any} for PID {d}", .{ h, child_process.pid });
        if (opts.start_minimized) {
            winutil.hideWindow(child_process.main_hwnd);
        }
    } else {
        std.log.info("Startup: failed to discover main window for PID {d}", .{child_process.pid});
    }

    // Hide our own console window
    winutil.hideOwnConsole();

    std.log.info("Creating tooltip text...", .{});

    // Tooltip text
    const tooltip_w = try makeTooltip(allocator, opts);
    defer allocator.free(tooltip_w);

    std.log.info("Aqcuiring HINSTANCE...", .{});

    // HINSTANCE
    const hinst: fnd.HINSTANCE =
        lib.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;

    std.log.info("Creating tray icon...", .{});

    var hicon: ?wm.HICON = null;

    // log the value of hicon.
    std.log.info("Initial hicon value: {any}", .{hicon});

    // User-specified --icon
    if (hicon == null) {
        if (opts.icon_path) |icon_path_utf8| {
            std.log.info("Loading icon from file: {s}", .{icon_path_utf8});
            hicon = loadIconFromFile(allocator, icon_path_utf8);
        }
    }

    // Fall back to program’s icon
    if (hicon == null) {
        std.log.info("Loading icon from target program...", .{});
        hicon = loadProgramIcon(allocator, opts.program);
    }

    // Fall back to the icon inside ztray.exe
    if (hicon == null) {
        std.log.info("Loading own application icon...", .{});
        hicon = loadOwnIcon(hinst);
    }

    // Fall back to default Win32 application icon
    if (hicon == null) {
        std.log.info("Loading default Win32 application icon...", .{});
        hicon = wm.LoadIconW(null, wm.IDI_APPLICATION);
    }

    var tray = try traylib.Tray.init(
        hinst,
        hicon,
        tooltip_w,
        &onTrayClick,
    );
    defer tray.deinit();

    // Background waiter thread: exits when child exits
    var waiter = try std.Thread.spawn(.{}, waitThreadMain, .{&child_process});
    waiter.detach();

    std.log.info("Running tray message loop...", .{});

    // Run tray message loop, blocks until exit.
    tray.messageLoop();

    // Tray is exiting because the user hit "Exit" or WM_QUIT was posted.
    if (!opts.persistent) {
        std.log.info("Tray exiting, terminating child PID {d}", .{child_process.pid});
        process.terminateChild(&child_process);
    } else {
        std.log.info("Tray exiting, but --persistent is set; leaving child PID {d} running", .{child_process.pid});
        // Show the child window if we can
        if (child_process.main_hwnd) |h| {
            winutil.showWindow(h);
        }
    }
}
