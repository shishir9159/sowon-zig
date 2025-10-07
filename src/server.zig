//! gRPC-Web listener for the bell-bearer Chrome extension.
//!
//! Implements the unary call sowon.FocusService/ReportFocus defined in
//! proto/sowon.proto over gRPC-Web (application/grpc-web+proto), since
//! browsers cannot speak native gRPC. The extension POSTs a framed
//! protobuf FocusUpdate { tab_group = 1, tab_title = 2 } on every focus
//! change; the latest snapshot is kept behind a lock and read by the
//! tracker when chrome.exe owns the foreground window.
//!
//! Purely optional: if nothing ever connects, sowon behaves as before.

const std = @import("std");
const w32 = @import("win32.zig");

pub const port: u16 = 41414;
pub const method_path = "/sowon.FocusService/ReportFocus";

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
    var ok = false;

    while (len < req.len) {
        const n = w32.recv(conn, req[len..].ptr, @intCast(req.len - len), 0);
        if (n <= 0) break;
        len += @intCast(n);
        if (completeRequest(req[0..len])) |request| {
            ok = handleRpc(request);
            break;
        }
    }

    sendResponse(conn, ok);
}

const Request = struct {
    path: []const u8,
    body: []const u8,
};

/// Returns the parsed request once the buffer holds all of it.
fn completeRequest(data: []const u8) ?Request {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    const headers = data[0..header_end];

    // Request line: "POST /path HTTP/1.1"
    const line_end = std.mem.indexOf(u8, headers, "\r\n") orelse headers.len;
    var parts = std.mem.splitScalar(u8, headers[0..line_end], ' ');
    _ = parts.next(); // method
    const path = parts.next() orelse "";

    var content_len: usize = 0;
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        const prefix = "content-length:";
        if (line.len > prefix.len and std.ascii.startsWithIgnoreCase(line, prefix)) {
            const value = std.mem.trim(u8, line[prefix.len..], " \t");
            content_len = std.fmt.parseInt(usize, value, 10) catch 0;
        }
    }

    const body_start = header_end + 4;
    if (data.len < body_start + content_len) return null;
    return .{ .path = path, .body = data[body_start..][0..content_len] };
}

/// Unwraps the gRPC-Web data frame, decodes FocusUpdate, stores it.
fn handleRpc(request: Request) bool {
    if (!std.mem.eql(u8, request.path, method_path)) return false;

    // gRPC-Web frame: 1 flag byte (0 = uncompressed data) + u32 BE length.
    const body = request.body;
    if (body.len < 5 or body[0] != 0) return false;
    const msg_len = std.mem.readInt(u32, body[1..5], .big);
    if (body.len < 5 + msg_len) return false;

    const update = decodeFocusUpdate(body[5..][0..msg_len]) orelse return false;

    w32.AcquireSRWLockExclusive(&lock);
    defer w32.ReleaseSRWLockExclusive(&lock);
    group_len = copyValidUtf8(&group_buf, std.mem.trim(u8, update.tab_group, " \r\n"));
    title_len = copyValidUtf8(&title_buf, std.mem.trim(u8, update.tab_title, " \r\n"));
    have_data = true;
    return true;
}

const FocusUpdate = struct {
    tab_group: []const u8 = "",
    tab_title: []const u8 = "",
};

/// Minimal proto3 decoder for FocusUpdate (two length-delimited string
/// fields). Unknown fields are skipped per protobuf rules.
fn decodeFocusUpdate(msg: []const u8) ?FocusUpdate {
    var update = FocusUpdate{};
    var i: usize = 0;
    while (i < msg.len) {
        const tag = readVarint(msg, &i) orelse return null;
        const field = tag >> 3;
        switch (@as(u3, @truncate(tag))) { // wire type
            2 => { // length-delimited
                const field_len = readVarint(msg, &i) orelse return null;
                if (field_len > msg.len - i) return null;
                const bytes = msg[i..][0..@intCast(field_len)];
                i += @intCast(field_len);
                switch (field) {
                    1 => update.tab_group = bytes,
                    2 => update.tab_title = bytes,
                    else => {},
                }
            },
            0 => _ = readVarint(msg, &i) orelse return null, // varint: skip
            5 => { // fixed32: skip
                if (msg.len - i < 4) return null;
                i += 4;
            },
            1 => { // fixed64: skip
                if (msg.len - i < 8) return null;
                i += 8;
            },
            else => return null,
        }
    }
    return update;
}

fn readVarint(msg: []const u8, i: *usize) ?u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (i.* < msg.len) {
        const byte = msg[i.*];
        i.* += 1;
        result |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return result;
        if (shift >= 56) return null; // malformed: varint too long
        shift += 7;
    }
    return null;
}

/// Unary gRPC-Web response: an empty Ack data frame plus a trailers
/// frame (flag 0x80) carrying the grpc-status. Errors are reported the
/// gRPC way: HTTP 200 with a non-zero grpc-status in the trailers.
fn sendResponse(conn: w32.SOCKET, ok: bool) void {
    const trailer_ok = "grpc-status: 0\r\n";
    const trailer_err = "grpc-status: 3\r\n"; // INVALID_ARGUMENT
    const trailer = if (ok) trailer_ok else trailer_err;

    var body: [5 + 5 + trailer_ok.len]u8 = undefined;
    @memset(body[0..5], 0); // empty Ack message frame
    body[5] = 0x80; // trailers frame flag
    std.mem.writeInt(u32, body[6..10], @intCast(trailer.len), .big);
    @memcpy(body[10..], trailer);

    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/grpc-web+proto\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{body.len},
    ) catch return;

    _ = w32.send(conn, head.ptr, @intCast(head.len), 0);
    _ = w32.send(conn, &body, body.len, 0);
}

/// Copies src into dst, truncating without splitting a UTF-8 sequence.
fn copyValidUtf8(dst: []u8, src: []const u8) usize {
    var n = @min(dst.len, src.len);
    while (n > 0 and !std.unicode.utf8ValidateSlice(src[0..n])) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

test decodeFocusUpdate {
    // FocusUpdate { tab_group: "Research", tab_title: "Zig docs" }
    const msg = "\x0a\x08Research\x12\x08Zig docs";
    const update = decodeFocusUpdate(msg).?;
    try std.testing.expectEqualStrings("Research", update.tab_group);
    try std.testing.expectEqualStrings("Zig docs", update.tab_title);

    // Empty group, unknown extra varint field (3 << 3 | 0), title only.
    const msg2 = "\x18\x2a\x12\x05Hello";
    const update2 = decodeFocusUpdate(msg2).?;
    try std.testing.expectEqualStrings("", update2.tab_group);
    try std.testing.expectEqualStrings("Hello", update2.tab_title);

    // Truncated length prefix must fail, not crash.
    try std.testing.expect(decodeFocusUpdate("\x0a\xff") == null);
}
