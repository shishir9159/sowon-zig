const std = @import("std");
const w32 = @import("win32.zig");

pub const port: u16 = 41414;
pub const method_path = "/bellbearer.FocusService/ReportFocus";

var lock: w32.SRWLOCK = w32.SRWLOCK_INIT;
var group_buf: [200]u8 = undefined;
var group_len: usize = 0;
var title_buf: [400]u8 = undefined;
var title_len: usize = 0;
var domain_buf: [200]u8 = undefined;
var domain_len: usize = 0;
var have_data = false;

pub fn start() void {
    const thread = std.Thread.spawn(.{}, run, .{}) catch |err| {
        std.debug.print("sowon: browser listener not started: {}\n", .{err});
        return;
    };
    thread.detach();
}

pub fn chromeContext(buf: []u8) ?[]const u8 {
    w32.AcquireSRWLockExclusive(&lock);
    defer w32.ReleaseSRWLockExclusive(&lock);
    if (!have_data) return null;
    const group = group_buf[0..group_len];
    const what = if (domain_len > 0) domain_buf[0..domain_len] else title_buf[0..title_len];
    if (what.len == 0) return null;
    if (group.len > 0) return std.fmt.bufPrint(buf, "chrome [{s}] {s}", .{ group, what }) catch null;
    return std.fmt.bufPrint(buf, "chrome: {s}", .{what}) catch null;
}

fn run() void {
    var wsa_data: [512]u8 align(8) = undefined;
    if (w32.WSAStartup(0x0202, &wsa_data) != 0) return;
    const sock = w32.socket(w32.AF_INET, w32.SOCK_STREAM, w32.IPPROTO_TCP);
    if (sock == w32.INVALID_SOCKET) return;

    const addr = w32.sockaddr_in{
        .sin_family = w32.AF_INET,
        .sin_port = std.mem.nativeToBig(u16, port),
        .sin_addr = std.mem.nativeToBig(u32, 0x7F000001),
        .sin_zero = @splat(0),
    };
    if (w32.bind(sock, &addr, @sizeOf(w32.sockaddr_in)) != 0 or w32.listen(sock, 4) != 0) return;

    const timeout_ms: w32.DWORD = 3000;
    while (true) {
        const conn = w32.accept(sock, null, null);
        if (conn == w32.INVALID_SOCKET) continue;
        _ = w32.setsockopt(conn, w32.SOL_SOCKET, w32.SO_RCVTIMEO, std.mem.asBytes(&timeout_ms), @sizeOf(w32.DWORD));
        handle(conn);
        _ = w32.closesocket(conn);
    }
}

fn handle(conn: w32.SOCKET) void {
    var req: [8192]u8 = undefined;
    var len: usize = 0;
    const ok = while (len < req.len) {
        const n = w32.recv(conn, req[len..].ptr, @intCast(req.len - len), 0);
        if (n <= 0) break false;
        len += @intCast(n);
        if (completeRequest(req[0..len])) |request| break handleRpc(request);
    } else false;
    const resp = if (ok) comptime response("0") else comptime response("3");
    _ = w32.send(conn, resp.ptr, @intCast(resp.len), 0);
}

fn response(comptime status: []const u8) []const u8 {
    const trailer = "grpc-status: " ++ status ++ "\r\n";
    const body = [_]u8{0} ** 5 ++ [_]u8{0x80} ++ std.mem.toBytes(std.mem.nativeToBig(u32, trailer.len)) ++ trailer;
    const out = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Type: application/grpc-web+proto\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    ) ++ body;
    return out;
}

const Request = struct { path: []const u8, body: []const u8 };

fn completeRequest(data: []const u8) ?Request {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    var lines = std.mem.splitSequence(u8, data[0..header_end], "\r\n");
    var parts = std.mem.splitScalar(u8, lines.first(), ' ');
    _ = parts.next();
    const path = parts.next() orelse "";

    const prefix = "content-length:";
    var content_len: usize = 0;
    while (lines.next()) |line| {
        if (line.len > prefix.len and std.ascii.startsWithIgnoreCase(line, prefix)) {
            content_len = std.fmt.parseInt(usize, std.mem.trim(u8, line[prefix.len..], " \t"), 10) catch 0;
        }
    }
    const body_start = header_end + 4;
    if (data.len < body_start + content_len) return null;
    return .{ .path = path, .body = data[body_start..][0..content_len] };
}

fn handleRpc(request: Request) bool {
    const body = request.body;
    if (!std.mem.eql(u8, request.path, method_path) or body.len < 5 or body[0] != 0) return false;
    const msg_len = std.mem.readInt(u32, body[1..5], .big);
    if (body.len - 5 < msg_len) return false;
    const update = decodeFocusUpdate(body[5..][0..msg_len]) orelse return false;
    storeSnapshot(update.tab_group, update.tab_title, update.domain);
    return true;
}

fn storeSnapshot(group: []const u8, title: []const u8, domain: []const u8) void {
    w32.AcquireSRWLockExclusive(&lock);
    defer w32.ReleaseSRWLockExclusive(&lock);
    group_len = copyValidUtf8(&group_buf, std.mem.trim(u8, group, " \r\n"));
    title_len = copyValidUtf8(&title_buf, std.mem.trim(u8, title, " \r\n"));
    domain_len = copyValidUtf8(&domain_buf, std.mem.trim(u8, domain, " \r\n"));
    have_data = true;
}

const FocusUpdate = struct {
    tab_group: []const u8 = "",
    tab_title: []const u8 = "",
    domain: []const u8 = "",
};

fn decodeFocusUpdate(msg: []const u8) ?FocusUpdate {
    var update = FocusUpdate{};
    var i: usize = 0;
    while (i < msg.len) {
        const tag = readVarint(msg, &i) orelse return null;
        const len: u64 = switch (@as(u3, @truncate(tag))) {
            0 => if (readVarint(msg, &i)) |_| 0 else return null,
            1 => 8,
            2 => readVarint(msg, &i) orelse return null,
            5 => 4,
            else => return null,
        };
        if (len > msg.len - i) return null;
        const bytes = msg[i..][0..@intCast(len)];
        i += bytes.len;
        if (tag & 7 != 2) continue;
        switch (tag >> 3) {
            1 => update.tab_group = bytes,
            2 => update.tab_title = bytes,
            3 => update.domain = bytes,
            else => {},
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
        if (shift >= 56) return null;
        shift += 7;
    }
    return null;
}

fn copyValidUtf8(dst: []u8, src: []const u8) usize {
    var n = @min(dst.len, src.len);
    while (n > 0 and !std.unicode.utf8ValidateSlice(src[0..n])) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

const testing = std.testing;

fn expectUpdate(msg: []const u8, group: []const u8, title: []const u8, domain: []const u8) !void {
    const update = decodeFocusUpdate(msg).?;
    try testing.expectEqualStrings(group, update.tab_group);
    try testing.expectEqualStrings(title, update.tab_title);
    try testing.expectEqualStrings(domain, update.domain);
}

test decodeFocusUpdate {
    try expectUpdate("\x0a\x08Research\x12\x08Zig docs\x1a\x0bziglang.org", "Research", "Zig docs", "ziglang.org");
    try expectUpdate("\x18\x2a\x12\x05Hello", "", "Hello", "");
    try expectUpdate("", "", "", "");
    try expectUpdate("\x0a\x00\x12\x00\x1a\x00", "", "", "");
    try expectUpdate("\x25\x01\x02\x03\x04\x12\x02hi", "", "hi", "");
    try expectUpdate("\x29\x01\x02\x03\x04\x05\x06\x07\x08\x12\x02hi", "", "hi", "");

    var long: [3 + 300]u8 = undefined;
    long[0..3].* = .{ 0x12, 0xac, 0x02 };
    @memset(long[3..], 'x');
    try testing.expectEqual(300, decodeFocusUpdate(&long).?.tab_title.len);
}

test "decodeFocusUpdate: rejects malformed input" {
    for ([_][]const u8{
        "\x0a\xff",
        "\x12\xc8\x01abc",
        "\x25\x01\x02",
        "\x29\x01\x02\x03",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
    }) |msg| try testing.expect(decodeFocusUpdate(msg) == null);
}

test readVarint {
    for ([_]struct { []const u8, u64 }{ .{ "\x00", 0 }, .{ "\x7f", 127 }, .{ "\x80\x01", 128 }, .{ "\xac\x02", 300 } }) |c| {
        var i: usize = 0;
        try testing.expectEqual(c[1], readVarint(c[0], &i).?);
    }
    var i: usize = 0;
    try testing.expect(readVarint("\x80", &i) == null);
}

test completeRequest {
    try testing.expect(completeRequest("POST /x HTTP/1.1\r\nContent-Length: 5\r\n") == null);
    try testing.expect(completeRequest("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nab") == null);

    const req = completeRequest("POST " ++ method_path ++ " HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello").?;
    try testing.expectEqualStrings(method_path, req.path);
    try testing.expectEqualStrings("hello", req.body);
    try testing.expectEqualStrings("abc", completeRequest("POST /p HTTP/1.1\r\ncOnTeNt-LeNgTh:  3\r\n\r\nabc").?.body);

    const get = completeRequest("GET /p HTTP/1.1\r\nHost: x\r\n\r\n").?;
    try testing.expectEqualStrings("/p", get.path);
    try testing.expectEqualStrings("", get.body);
}

test handleRpc {
    const payload = "\x0a\x04Work\x12\x03Zig\x1a\x07zig.org";
    const body = [_]u8{0} ++ std.mem.toBytes(std.mem.nativeToBig(u32, payload.len)) ++ payload;
    try testing.expect(handleRpc(.{ .path = method_path, .body = body }));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("chrome [Work] zig.org", chromeContext(&buf).?);

    try testing.expect(!handleRpc(.{ .path = "/wrong/Path", .body = "\x00\x00\x00\x00\x00" }));
    for ([_][]const u8{ "", "\x01\x00\x00\x00\x00", "\x00\x00\x00\x00\x64ab" }) |b| {
        try testing.expect(!handleRpc(.{ .path = method_path, .body = b }));
    }
}

test "response frames an empty Ack plus grpc-status trailers" {
    const resp = comptime response("0");
    const body = resp[std.mem.indexOf(u8, resp, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings("\x00\x00\x00\x00\x00\x80\x00\x00\x00\x10grpc-status: 0\r\n", body);
    try testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 26\r\n") != null);
}

test chromeContext {
    var buf: [256]u8 = undefined;
    storeSnapshot("", "Some Page Title", "example.com");
    try testing.expectEqualStrings("chrome: example.com", chromeContext(&buf).?);
    storeSnapshot("Research", "Some Page Title", "example.com");
    try testing.expectEqualStrings("chrome [Research] example.com", chromeContext(&buf).?);
    storeSnapshot("", "Settings", "");
    try testing.expectEqualStrings("chrome: Settings", chromeContext(&buf).?);
    storeSnapshot("", "", "");
    try testing.expect(chromeContext(&buf) == null);
}

test copyValidUtf8 {
    var dst: [4]u8 = undefined;
    const n = copyValidUtf8(&dst, "ééé");
    try testing.expectEqual(4, n);
    try testing.expect(std.unicode.utf8ValidateSlice(dst[0..n]));
    try testing.expectEqual(0, copyValidUtf8(&dst, "\x80"));
    try testing.expectEqualStrings("hi", dst[0..copyValidUtf8(&dst, "hi")]);
}
