const std = @import("std");

pub fn parseDuration(s: []const u8) !u64 {
    var total: f64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        var j = i;
        while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.')) j += 1;
        if (j == i) return error.InvalidDuration;
        const x = std.fmt.parseFloat(f64, s[i..j]) catch return error.InvalidDuration;
        var mult: f64 = 1;
        if (j < s.len) {
            mult = switch (s[j]) {
                's' => 1,
                'm' => 60,
                'h' => 3600,
                else => return error.InvalidDuration,
            };
            j += 1;
        }
        total += x * mult;
        i = j;
    }
    if (total < 1) return error.InvalidDuration;
    return @intFromFloat(total);
}

pub fn fmtDur(buf: []u8, secs: u64) ![]const u8 {
    const h = secs / 3600;
    const m = secs / 60 % 60;
    const s = secs % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h {d:0>2}m {d:0>2}s", .{ h, m, s });
    if (m > 0) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ m, s });
    return std.fmt.bufPrint(buf, "{d}s", .{s});
}

pub fn focusPct(focused: u64, distracted: u64) ?u64 {
    const tracked = focused + distracted;
    return if (tracked > 0) focused * 100 / tracked else null;
}

pub fn isAllowedIn(allow: []const []const u8, name: []const u8) bool {
    const group_prefix = "chrome [";
    const plain_prefix = "chrome: ";
    for (allow) |pattern| {
        if (std.ascii.eqlIgnoreCase(name, pattern)) return true;
        if (std.mem.startsWith(u8, name, group_prefix)) {
            const rest = name[group_prefix.len..];
            const end = std.mem.indexOfScalar(u8, rest, ']') orelse continue;
            if (std.ascii.eqlIgnoreCase(rest[0..end], pattern)) return true;
            if (end + 2 <= rest.len and std.ascii.eqlIgnoreCase(rest[end + 2 ..], pattern)) return true;
        } else if (std.mem.startsWith(u8, name, plain_prefix) and std.ascii.eqlIgnoreCase(name[plain_prefix.len..], pattern)) {
            return true;
        }
    }
    return false;
}

const testing = std.testing;

test parseDuration {
    for ([_]struct { []const u8, u64 }{
        .{ "90s", 90 },    .{ "90", 90 },      .{ "25m", 1500 },
        .{ "1.5h", 5400 }, .{ "1h30m", 5400 }, .{ "1h1m1s", 3661 },
    }) |c| try testing.expectEqual(c[1], try parseDuration(c[0]));
    for ([_][]const u8{ "abc", "10x", "0s", "" }) |s| try testing.expectError(error.InvalidDuration, parseDuration(s));
}

test fmtDur {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("3s", try fmtDur(&buf, 3));
    try testing.expectEqualStrings("25m 00s", try fmtDur(&buf, 1500));
    try testing.expectEqualStrings("1h 05m 09s", try fmtDur(&buf, 3909));
    try testing.expectEqualStrings("0s", try fmtDur(&buf, 0));
}

test focusPct {
    try testing.expectEqual(75, focusPct(30, 10).?);
    try testing.expectEqual(null, focusPct(0, 0));
}

test isAllowedIn {
    const allow = [_][]const u8{ "explorer.exe", "Research", "ziglang.org" };
    for ([_][]const u8{
        "explorer.exe",
        "EXPLORER.EXE",
        "chrome [Research] news.example",
        "chrome [Work] ziglang.org",
        "chrome: ziglang.org",
    }) |name| try testing.expect(isAllowedIn(&allow, name));
    for ([_][]const u8{ "chrome.exe", "chrome [Play] youtube.com", "chrome: youtube.com" }) |name| {
        try testing.expect(!isAllowedIn(&allow, name));
    }
    try testing.expect(!isAllowedIn(&.{}, "explorer.exe"));
}
