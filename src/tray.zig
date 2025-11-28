const std = @import("std");
const win32 = @import("win32");

const fnd = win32.foundation;
const wm = win32.ui.windows_and_messaging;
const sh = win32.ui.shell;
const ss = win32.system.system_services;

const zeroes = std.mem.zeroes;

// Menu IDs
pub const ID_TRAY_FIRST: u32 = 1000;
pub const ID_TRAY_EXIT: u32 = ID_TRAY_FIRST + 1;

// Custom message used by Shell_NotifyIconW
const TRAY_MSG: u32 = wm.WM_APP + 1;

// Left-click handler type
pub const ClickHandler = *const fn (hwnd: fnd.HWND) void;

pub var running: bool = true;

pub const Tray = struct {
    hinst: fnd.HINSTANCE,
    hwnd: ?fnd.HWND,
    nid: sh.NOTIFYICONDATAW,
    icon: ?wm.HICON,
    click_handler: ?ClickHandler,

    pub fn init(
        hinst: fnd.HINSTANCE,
        icon: ?wm.HICON,
        tooltip_utf16: []const u16,
        click_handler: ?ClickHandler,
    ) !Tray {
        try registerWindowClass(hinst);

        const ex_style_zero: wm.WINDOW_EX_STYLE =
            @as(wm.WINDOW_EX_STYLE, @bitCast(@as(u32, 0)));

        const style_zero: wm.WINDOW_STYLE =
            @as(wm.WINDOW_STYLE, @bitCast(@as(u32, 0)));

        const hwnd_opt = wm.CreateWindowExW(
            ex_style_zero,
            WINDOW_CLASS_NAME.ptr,
            WINDOW_TITLE.ptr,
            style_zero,
            0,
            0,
            0,
            0,
            null,
            null,
            hinst,
            null,
        );

        if (hwnd_opt == null) {
            return error.CreateWindowFailed;
        }

        const hwnd: fnd.HWND = hwnd_opt.?;

        var nid = zeroes(sh.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(sh.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;

        const nif_bits: u32 =
            @as(u32, @bitCast(sh.NIF_ICON)) |
            @as(u32, @bitCast(sh.NIF_TIP)) |
            @as(u32, @bitCast(sh.NIF_MESSAGE));
        nid.uFlags = @as(@TypeOf(sh.NIF_ICON), @bitCast(nif_bits));

        nid.uCallbackMessage = TRAY_MSG;

        if (icon) |hicon| {
            nid.hIcon = hicon;
        }

        // Copy tooltip (truncate if necessary)
        const tip_len = tooltip_utf16.len;
        const max_tip = nid.szTip.len - 1;
        const copy_len = if (tip_len > max_tip) max_tip else tip_len;
        std.mem.copyForwards(u16, nid.szTip[0..copy_len], tooltip_utf16[0..copy_len]);
        nid.szTip[copy_len] = 0;

        if (sh.Shell_NotifyIconW(sh.NIM_ADD, &nid) == @intFromBool(false)) {
            return error.ShellNotifyAddFailed;
        }

        tray_ctx = Tray{
            .hinst = hinst,
            .hwnd = hwnd,
            .nid = nid,
            .icon = icon,
            .click_handler = click_handler,
        };

        return tray_ctx;
    }

    pub fn deinit(self: *Tray) void {
        // remove icon, destroy window
        _ = sh.Shell_NotifyIconW(sh.NIM_DELETE, &self.nid);
        if (self.hwnd != null) {
            _ = wm.DestroyWindow(self.hwnd);
        }
    }

    pub fn messageLoop(self: *Tray) void {
        var msg: wm.MSG = undefined;
        while (running) {
            const res = wm.GetMessageW(&msg, null, 0, 0);
            if (res == 0) {
                break; // WM_QUIT
            } else if (res == -1) {
                break; // error
            }

            _ = wm.TranslateMessage(&msg);
            _ = wm.DispatchMessageW(&msg);
        }

        // on exit, ensure icon is removed
        _ = sh.Shell_NotifyIconW(sh.NIM_DELETE, &self.nid);
    }
};

var tray_ctx: Tray = undefined;

// ----- Window class / WndProc -----

const WINDOW_CLASS_NAME: [:0]const u16 = &[_:0]u16{ 'Z', 'T', 'r', 'a', 'y', 'C', 'l', 'a', 's', 's', 0 };
const WINDOW_TITLE: [:0]const u16 = &[_:0]u16{ 'Z', 'T', 'r', 'a', 'y', 'W', 'i', 'n', 'd', 'o', 'w', 0 };

fn registerWindowClass(hinst: fnd.HINSTANCE) !void {
    var wc: wm.WNDCLASSEXW = zeroes(wm.WNDCLASSEXW);
    wc.cbSize = @sizeOf(wm.WNDCLASSEXW);

    const style_bits: u32 =
        @as(u32, @bitCast(wm.CS_HREDRAW)) |
        @as(u32, @bitCast(wm.CS_VREDRAW));
    wc.style = @as(wm.WNDCLASS_STYLES, @bitCast(style_bits));

    wc.lpfnWndProc = wndProc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = hinst;
    wc.hIcon = null;
    wc.hCursor = wm.LoadCursorW(null, wm.IDC_ARROW);
    wc.hbrBackground = null;
    wc.lpszMenuName = null;
    wc.lpszClassName = WINDOW_CLASS_NAME.ptr;
    wc.hIconSm = null;

    const atom = wm.RegisterClassExW(&wc);
    if (atom == 0) return error.RegisterClassFailed;
}

fn wndProc(
    hwnd: fnd.HWND,
    msg: u32,
    wparam: fnd.WPARAM,
    lparam: fnd.LPARAM,
) callconv(.winapi) fnd.LRESULT {
    switch (msg) {
        TRAY_MSG => {
            switch (@as(u32, @intCast(lparam))) {
                wm.WM_LBUTTONUP => {
                    if (tray_ctx.click_handler) |cb| {
                        cb(hwnd);
                    }
                },
                wm.WM_RBUTTONUP => {
                    showContextMenu(hwnd);
                },
                else => {},
            }
            return 0;
        },
        wm.WM_COMMAND => {
            const id: u32 = @as(u32, @intCast(wparam & 0xFFFF));
            if (id == ID_TRAY_EXIT) {
                running = false;
            }
            return 0;
        },
        wm.WM_DESTROY => {
            wm.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }

    return wm.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn showContextMenu(hwnd: fnd.HWND) void {
    const hmenu = wm.CreatePopupMenu();
    if (hmenu == null) return;

    const text: [:0]const u16 = &[_:0]u16{ 'E', 'x', 'i', 't', 0 };

    _ = wm.AppendMenuW(
        hmenu,
        wm.MF_STRING,
        ID_TRAY_EXIT,
        text.ptr,
    );

    var pt: fnd.POINT = .{ .x = 0, .y = 0 };
    _ = wm.GetCursorPos(&pt);

    const tpm_bits: u32 =
        @as(u32, @bitCast(wm.TPM_RIGHTBUTTON)) |
        @as(u32, @bitCast(wm.TPM_BOTTOMALIGN)) |
        @as(u32, @bitCast(wm.TPM_LEFTALIGN));

    const tpm_flags = @as(@TypeOf(wm.TPM_RIGHTBUTTON), @bitCast(tpm_bits));

    _ = wm.SetForegroundWindow(hwnd);
    _ = wm.TrackPopupMenu(
        hmenu,
        tpm_flags,
        pt.x,
        pt.y,
        0,
        hwnd,
        null,
    );
    _ = wm.PostMessageW(hwnd, wm.WM_NULL, 0, 0);
    _ = wm.DestroyMenu(hmenu);
}
