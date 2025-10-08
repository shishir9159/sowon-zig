//! Pure helpers shared across modules and covered by unit tests
//! (`zig build test`). Nothing here touches global state or the OS, so
//! it can be exercised in isolation.

const std = @import("std");

/// Parses a duration like "90s", "25m", "1.5h", "1h30m" into whole
/// seconds. Returns error.InvalidDuration on anything malformed or < 1s.
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

/// Human-friendly duration, e.g. "1h 05m 09s", "25m 00s", "3s".
pub fn fmtDur(buf: []u8, secs: u64) ![]const u8 {
    const h = secs / 3600;
    const m = secs / 60 % 60;
    const s = secs % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h {d:0>2}m {d:0>2}s", .{ h, m, s });
    if (m > 0) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ m, s });
    return std.fmt.bufPrint(buf, "{d}s", .{s});
}

/// True if `name` matches any allow-list pattern: the app name itself
/// ("explorer.exe"), or for Chrome entries reported by the extension,
/// the tab-group name or the site domain
/// ("chrome [Research] ziglang.org", "chrome: ziglang.org").
pub fn isAllowedIn(allow: []const []const u8, name: []const u8) bool {
    const group_prefix = "chrome [";
    const plain_prefix = "chrome: ";

    for (allow) |pattern| {
        if (std.ascii.eqlIgnoreCase(name, pattern)) return true;

        if (std.mem.startsWith(u8, name, group_prefix)) {
            const rest = name[group_prefix.len..];
            if (std.mem.indexOfScalar(u8, rest, ']')) |end| {
                if (std.ascii.eqlIgnoreCase(rest[0..end], pattern)) return true;
                // "] " is followed by the domain (or title fallback).
                if (end + 2 <= rest.len and std.ascii.eqlIgnoreCase(rest[end + 2 ..], pattern)) return true;
            }
        } else if (std.mem.startsWith(u8, name, plain_prefix)) {
            if (std.ascii.eqlIgnoreCase(name[plain_prefix.len..], pattern)) return true;
        }
    }
    return false;
}

test parseDuration {
    try std.testing.expectEqual(@as(u64, 90), try parseDuration("90s"));
    try std.testing.expectEqual(@as(u64, 90), try parseDuration("90"));
    try std.testing.expectEqual(@as(u64, 1500), try parseDuration("25m"));
    try std.testing.expectEqual(@as(u64, 5400), try parseDuration("1.5h"));
    try std.testing.expectEqual(@as(u64, 5400), try parseDuration("1h30m"));
    try std.testing.expectEqual(@as(u64, 3661), try parseDuration("1h1m1s"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("abc"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("10x"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("0s"));
    try std.testing.expectError(error.InvalidDuration, parseDuration(""));
}

test fmtDur {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("3s", try fmtDur(&buf, 3));
    try std.testing.expectEqualStrings("25m 00s", try fmtDur(&buf, 1500));
    try std.testing.expectEqualStrings("1h 05m 09s", try fmtDur(&buf, 3909));
    try std.testing.expectEqualStrings("0s", try fmtDur(&buf, 0));
}

test isAllowedIn {
    const allow = [_][]const u8{ "explorer.exe", "Research", "ziglang.org" };

    // Plain app name, case-insensitive.
    try std.testing.expect(isAllowedIn(&allow, "explorer.exe"));
    try std.testing.expect(isAllowedIn(&allow, "EXPLORER.EXE"));
    try std.testing.expect(!isAllowedIn(&allow, "chrome.exe"));

    // Chrome tab-group match and domain match within a grouped entry.
    try std.testing.expect(isAllowedIn(&allow, "chrome [Research] news.example"));
    try std.testing.expect(isAllowedIn(&allow, "chrome [Work] ziglang.org"));
    try std.testing.expect(!isAllowedIn(&allow, "chrome [Play] youtube.com"));

    // Ungrouped chrome entry matched by domain.
    try std.testing.expect(isAllowedIn(&allow, "chrome: ziglang.org"));
    try std.testing.expect(!isAllowedIn(&allow, "chrome: youtube.com"));

    // Empty allow list allows nothing.
    try std.testing.expect(!isAllowedIn(&.{}, "explorer.exe"));
}
