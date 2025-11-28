const std = @import("std");

const win32 = @import("win32");

const fnd = win32.foundation;
const wm = win32.ui.windows_and_messaging;
const sc = win32.system.console;

pub const SW_HIDE: wm.SHOW_WINDOW_CMD =
    @as(wm.SHOW_WINDOW_CMD, @bitCast(@as(u32, 0)));
pub const SW_SHOW: wm.SHOW_WINDOW_CMD =
    @as(wm.SHOW_WINDOW_CMD, @bitCast(@as(u32, 5)));

// Global storage for EnumWindows callback
var found_hwnd: ?fnd.HWND = null;

pub fn activateWindow(hwnd: ?fnd.HWND) void {
    if (hwnd) |h| {
        _ = wm.SetForegroundWindow(h);
    }
}

pub fn hideOwnConsole() void {
    const hwnd_opt = sc.GetConsoleWindow();
    if (hwnd_opt) |hwnd| {
        _ = wm.ShowWindow(hwnd, SW_HIDE);
    }
}

pub fn hideWindow(hwnd: ?fnd.HWND) void {
    if (hwnd) |h| {
        _ = wm.ShowWindow(h, SW_HIDE);
    }
}

pub fn showWindow(hwnd: ?fnd.HWND) void {
    if (hwnd) |h| {
        _ = wm.ShowWindow(h, SW_SHOW);
    }
}

pub fn toggleWindow(hwnd: ?fnd.HWND) void {
    if (hwnd) |h| {
        // IsWindowVisible returns BOOL (i32); nonzero means visible
        if (wm.IsWindowVisible(h) != 0) {
            _ = wm.ShowWindow(h, SW_HIDE);
        } else {
            _ = wm.ShowWindow(h, SW_SHOW);
        }
    }
}

/// Callback for EnumWindows to find main window of a process.
fn enumMainWindow(hwnd: fnd.HWND, lp: fnd.LPARAM) callconv(.winapi) fnd.BOOL {
    var window_pid: u32 = 0;
    _ = wm.GetWindowThreadProcessId(hwnd, &window_pid);

    const target_pid: u32 = @as(u32, @intCast(lp));

    if (window_pid == target_pid and wm.IsWindowVisible(hwnd) != 0) {
        found_hwnd = hwnd;
        // 0 == FALSE -> stop enumeration
        return 0;
    }
    // nonzero == TRUE -> continue enumeration
    return 1;
}

/// Find a top-level visible window whose owning process has the given PID.
pub fn findMainWindowForProcessId(pid: u32) ?fnd.HWND {
    found_hwnd = null;

    const lparam: fnd.LPARAM = @as(fnd.LPARAM, @intCast(pid));
    _ = wm.EnumWindows(enumMainWindow, lparam);

    return found_hwnd;
}

/// Attach to the parent console if we do not already have a console.
/// Safe to call unconditionally; does nothing if it fails.
/// Returns true if we have a console after this call.
pub fn ensureParentConsoleAttached() bool {
    // Already have a console window -> nothing to do.
    if (sc.GetConsoleWindow() != null) {
        return true;
    }

    const ATTACH_PARENT_PROCESS: u32 = 0xFFFFFFFF;
    const ok = sc.AttachConsole(ATTACH_PARENT_PROCESS);
    return ok != 0;
}
