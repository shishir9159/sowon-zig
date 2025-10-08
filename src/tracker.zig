const std = @import("std");
const w32 = @import("win32.zig");
const server = @import("server.zig");

pub const Tracker = struct {
    map: std.StringHashMap(u64),

    pub const Entry = struct {
        name: []const u8,
        seconds: u64,
    };

    pub fn init(alloc: std.mem.Allocator) Tracker {
        return .{ .map = std.StringHashMap(u64).init(alloc) };
    }

    /// Credits `seconds` to the current foreground app and returns the
    /// (map-owned, stable) usage key it was counted under.
    pub fn sample(self: *Tracker, seconds: u64) ![]const u8 {
        var buf: [512]u8 = undefined;
        var chrome_buf: [700]u8 = undefined;
        var name = foregroundAppName(&buf);

        // With the bell-bearer extension connected, split Chrome time
        // by tab group and site instead of lumping it together.
        if (std.ascii.eqlIgnoreCase(name, "chrome.exe")) {
            if (server.chromeContext(&chrome_buf)) |ctx| name = ctx;
        }

        return self.add(name, seconds);
    }

    /// Credits `seconds` to `name` directly (also used to fold one
    /// session's totals into the whole-run aggregate).
    pub fn add(self: *Tracker, name: []const u8, seconds: u64) ![]const u8 {
        const gop = try self.map.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.map.allocator.dupe(u8, name);
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += seconds;
        return gop.key_ptr.*;
    }

    pub fn sortedEntries(self: *const Tracker, alloc: std.mem.Allocator) ![]Entry {
        const out = try alloc.alloc(Entry, self.map.count());
        var it = self.map.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            out[i] = .{ .name = kv.key_ptr.*, .seconds = kv.value_ptr.* };
        }
        std.mem.sort(Entry, out, {}, moreUsed);
        return out;
    }

    fn moreUsed(_: void, a: Entry, b: Entry) bool {
        return a.seconds > b.seconds;
    }
};

fn foregroundAppName(buf: []u8) []const u8 {
    const hwnd = w32.GetForegroundWindow() orelse return "(no focused window)";

    var pid: w32.DWORD = 0;
    _ = w32.GetWindowThreadProcessId(hwnd, &pid);
    if (pid == 0) return "(unknown)";

    const proc = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return "(unknown)";
    defer _ = w32.CloseHandle(proc);

    var path_buf: [1024]u16 = undefined;
    var len: w32.DWORD = path_buf.len;
    if (w32.QueryFullProcessImageNameW(proc, 0, &path_buf, &len) == 0) return "(unknown)";
    const path = path_buf[0..len];

    var base_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '\\' or c == '/') base_start = i + 1;
    }

    const n = std.unicode.utf16LeToUtf8(buf, path[base_start..]) catch return "(unknown)";
    return buf[0..n];
}