//! Tiny localhost HTTP listener for the bell-bearer Chrome extension.
//!
//! The extension POSTs a plain-text body to http://127.0.0.1:41414/focus
//! whenever the focused tab changes:
//!
//!     <tab group title, may be empty>\n<tab title>
//!
//! The latest snapshot is kept behind a lock; the tracker reads it when
//! chrome.exe owns the foreground window. Purely optional: if nothing
//! ever connects, sowon behaves exactly as before.

const std = @import("std");
const w32 = @import("win32.zig");

pub const port: u16 = 41414;

var lock: w32.SRWLOCK = w32.SRWLOCK_INIT;
var group_buf: [200]u8 = undefined;
var group_len: usize = 0;
var title_buf: [400]u8 = undefined;
var title_len: usize = 0;
var have_data: bool = false;

/// Spawns the listener thread. Failure is non-fatal: sowon just won't
/// get browser detail.
pub fn start() void {
    const thread = std.Thread.spawn(.{}, run, .{}) catch |err| {
        std.debug.print("sowon: browser listener not started: {}\n", .{err});
        return;
    };
    thread.detach();
}

/// Latest browser focus formatted for the usage report, or null if no
/// extension has reported yet. `buf` must outlive the returned slice.
pub fn chromeContext(buf: []u8) ?[]const u8 {
    w32.AcquireSRWLockExclusive(&lock);
    defer w32.ReleaseSRWLockExclusive(&lock);

    if (!have_data or title_len == 0) return null;
    const group = group_buf[0..group_len];
    const title = title_buf[0..title_len];
    if (group.len > 0) {
        return std.fmt.bufPrint(buf, "chrome [{s}] {s}", .{ group, title }) catch null;
    }
    return std.fmt.bufPrint(buf, "chrome: {s}", .{title}) catch null;
}

fn run() void {
    var wsa_data: [512]u8 align(8) = undefined;
    if (w32.WSAStartup(0x0202, &wsa_data) != 0) return;

    const sock = w32.socket(w32.AF_INET, w32.SOCK_STREAM, w32.IPPROTO_TCP);
    if (sock == w32.INVALID_SOCKET) return;

    const addr = w32.sockaddr_in{
        .sin_family = w32.AF_INET,
        .sin_port = @byteSwap(port),
        .sin_addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
        .sin_zero = @splat(0),
    };
    if (w32.bind(sock, &addr, @sizeOf(w32.sockaddr_in)) != 0) return;
    if (w32.listen(sock, 4) != 0) return;

    while (true) {
        const conn = w32.accept(sock, null, null);
        if (conn == w32.INVALID_SOCKET) continue;
        handle(conn);
        _ = w32.closesocket(conn);
    }
}

fn handle(conn: w32.SOCKET) void {
    var req: [8192]u8 = undefined;
    var len: usize = 0;

    while (len < req.len) {
        const n = w32.recv(conn, req[len..].ptr, @intCast(req.len - len), 0);
        if (n <= 0) break;
        len += @intCast(n);
        if (completeBody(req[0..len])) |body| {
            storeFocus(body);
            break;
        }
    }

    const response = "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    _ = w32.send(conn, response.ptr, response.len, 0);
}

/// Returns the request body once the buffer holds the complete request.
fn completeBody(data: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;

    var content_len: usize = 0;
    var it = std.mem.splitSequence(u8, data[0..header_end], "\r\n");
    while (it.next()) |line| {
        const prefix = "content-length:";
        if (line.len > prefix.len and std.ascii.startsWithIgnoreCase(line, prefix)) {
            const value = std.mem.trim(u8, line[prefix.len..], " \t");
            content_len = std.fmt.parseInt(usize, value, 10) catch 0;
        }
    }

    const body_start = header_end + 4;
    if (data.len < body_start + content_len) return null;
    return data[body_start..][0..content_len];
}

fn storeFocus(body: []const u8) void {
    var group: []const u8 = "";
    var title: []const u8 = body;
    if (std.mem.indexOfScalar(u8, body, '\n')) |nl| {
        group = std.mem.trim(u8, body[0..nl], " \r");
        title = body[nl + 1 ..];
    }
    title = std.mem.trim(u8, title, " \r\n");

    w32.AcquireSRWLockExclusive(&lock);
    defer w32.ReleaseSRWLockExclusive(&lock);
    group_len = copyValidUtf8(&group_buf, group);
    title_len = copyValidUtf8(&title_buf, title);
    have_data = true;
}

/// Copies src into dst, truncating without splitting a UTF-8 sequence.
fn copyValidUtf8(dst: []u8, src: []const u8) usize {
    var n = @min(dst.len, src.len);
    while (n > 0 and !std.unicode.utf8ValidateSlice(src[0..n])) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    return n;
}
