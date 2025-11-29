const std = @import("std");

const win32 = @import("win32");

const encode = @import("encode.zig");
const log = @import("log.zig");

const cc = win32.system.character_conversion;
const fnd = win32.foundation;
const th = win32.system.threading;
const tl = win32.system.diagnostics.tool_help;

pub const ProcessContext = struct {
    parent_hwnd: fnd.HANDLE,
    pid: u32,
    main_hwnd: ?fnd.HWND = null,
};

fn buildCommandLine(
    allocator: std.mem.Allocator,
    program: []const u8,
    args: []const []const u8,
) ![:0]u16 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Force console host (incase Windows Terminal is default)
    // conhost.exe -- "program" args...
    try buf.appendSlice(allocator, "conhost.exe -- ");

    // "program"
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, program);
    try buf.append(allocator, '"');

    // space + each arg (quoted if contains spaces)
    for (args) |a| {
        try buf.append(allocator, ' ');
        const needs_quotes = std.mem.indexOfScalar(u8, a, ' ') != null;

        if (needs_quotes) {
            try buf.append(allocator, '"');
        }

        try buf.appendSlice(allocator, a);

        if (needs_quotes) {
            try buf.append(allocator, '"');
        }
    }

    std.log.info("Command line built for child process.", .{});

    // buf.items is UTF-8 text; convert to UTF-16 with trailing NUL
    return try encode.utf8ToWideNul(allocator, buf.items);
}

pub fn spawnChild(
    allocator: std.mem.Allocator,
    program: []const u8,
    args: []const []const u8,
) !ProcessContext {
    std.log.info("Building command line for child process...", .{});
    const cmdline_w = try buildCommandLine(allocator, program, args);
    defer allocator.free(cmdline_w);

    // For logging: dump UTF-16 command line
    std.log.info("Command line (wide) (len={d}):", .{cmdline_w.len});
    const cmdline = std.unicode.utf16LeToUtf8Alloc(allocator, cmdline_w) catch |err| return err;
    defer allocator.free(cmdline);
    std.log.info("{s}", .{cmdline});

    // PWSTR for CreateProcessW
    const cmdline_pwstr: [*:0]u16 = @ptrCast(cmdline_w.ptr);

    std.log.info("Preparing STARTUPINFO and PROCESS_INFORMATION...", .{});

    var si: th.STARTUPINFOW = std.mem.zeroes(th.STARTUPINFOW);
    si.cb = @sizeOf(th.STARTUPINFOW);

    var pi: th.PROCESS_INFORMATION = undefined;

    // PROCESS_CREATION_FLAGS: CREATE_NEW_CONSOLE
    const creation_bits: u32 = @as(u32, @bitCast(th.CREATE_NEW_CONSOLE));
    const creation_flags: th.PROCESS_CREATION_FLAGS =
        @as(th.PROCESS_CREATION_FLAGS, @bitCast(creation_bits));

    std.log.info("Preparing to call CreateProcessW...", .{});

    const ok = th.CreateProcessW(
        null, // lpApplicationName
        cmdline_pwstr, // lpCommandLine (mutable in Win32, but we pass writable buffer)
        null, // lpProcessAttributes
        null, // lpThreadAttributes
        0, // bInheritHandles = FALSE
        creation_flags, // dwCreationFlags = CREATE_NEW_CONSOLE
        null, // lpEnvironment
        null, // lpCurrentDirectory
        &si,
        &pi,
    );

    if (ok == 0) {
        std.log.info("CreateProcessW failed.", .{});
        return error.CreateProcessFailed;
    }

    const hproc = pi.hProcess orelse return error.CreateProcessFailed;
    const host_pid = pi.dwProcessId;

    // Try to resolve the console client PID (child of conhost)
    var client_pid: u32 = host_pid; // fallback: host PID if we find nothing

    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        if (findFirstProcessContext(host_pid)) |cp| {
            client_pid = cp;
            std.log.info("Resolved console client PID {d} (host PID {d})", .{ cp, host_pid });
            break;
        }

        // Give conhost a moment to spawn the client
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const child = ProcessContext{
        .parent_hwnd = hproc, // still the process handle we wait on (conhost)
        .pid = client_pid, // PID used for window discovery (console client)
        .main_hwnd = null,
    };
    return child;
}

pub fn terminateChild(child: *ProcessContext) void {
    // Access mask for TerminateProcess
    const PROCESS_TERMINATE: th.PROCESS_ACCESS_RIGHTS = @bitCast(@as(u32, 0x0001));

    // Kill the console client (user's program)
    if (th.OpenProcess(PROCESS_TERMINATE, 0, child.pid)) |h_child| {
        defer _ = fnd.CloseHandle(h_child);

        const rc_child = th.TerminateProcess(h_child, 1);
        if (rc_child == 0) {
            std.log.info("TerminateProcess failed for client PID {d}", .{child.pid});
        } else {
            std.log.info("Terminated console client PID {d}", .{child.pid});
        }
    } else {
        std.log.info("OpenProcess failed for client PID {d}", .{child.pid});
    }

    // Kill the console host (conhost.exe)
    const rc_host = th.TerminateProcess(child.parent_hwnd, 1);
    if (rc_host == 0) {
        std.log.info("TerminateProcess failed for host of PID {d}", .{child.pid});
    } else {
        std.log.info("Terminated console host for PID {d}", .{child.pid});
    }
}

/// Find the first process whose parent PID matches the given PID.
fn findFirstProcessContext(parent_pid: u32) ?u32 {
    // Snapshot of all processes
    const snapshot = tl.CreateToolhelp32Snapshot(tl.TH32CS_SNAPPROCESS, 0);
    defer _ = fnd.CloseHandle(snapshot);

    if (snapshot == fnd.INVALID_HANDLE_VALUE) {
        return null;
    }

    var entry: tl.PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(tl.PROCESSENTRY32W);

    if (tl.Process32FirstW(snapshot, &entry) == 0) {
        return null;
    }

    while (true) {
        if (entry.th32ParentProcessID == parent_pid) {
            return entry.th32ProcessID;
        }
        if (tl.Process32NextW(snapshot, &entry) == 0) {
            break;
        }
    }
    return null;
}

pub fn waitForExit(child: *ProcessContext) void {
    const INFINITE: u32 = 0xFFFFFFFF;
    _ = th.WaitForSingleObject(child.parent_hwnd, INFINITE);
}
