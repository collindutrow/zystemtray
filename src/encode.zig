const std = @import("std");

pub fn utf8ToWideNul(allocator: std.mem.Allocator, utf8: []const u8) ![:0]u16 {
    // Convert UTF-8 -> UTF-16 (no sentinel)
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, utf8);
    defer allocator.free(utf16);

    // Allocate UTF-16 with trailing NUL sentinel
    const out = try allocator.allocSentinel(u16, utf16.len, 0);

    // Copy and return
    std.mem.copyForwards(u16, out[0..utf16.len], utf16);
    return out;
}
