const std = @import("std");

pub const sheet_width = 1650;
pub const sheet_height = 570;
pub const char_width = 150;
pub const char_height = 190;
pub const wiggle_count = 3;
pub const colon_column = 10;

const raw = @embedFile("digits.bgra");
pub const byte_len = raw.len;

comptime {
    std.debug.assert(raw.len == sheet_width * sheet_height * 4);
}

pub fn writeTintedPremultiplied(dst: []u8, rgb: [3]u8) void {
    tintPremultiply(dst, raw, rgb);
}

fn tintPremultiply(dst: []u8, src: []const u8, rgb: [3]u8) void {
    std.debug.assert(dst.len == src.len);
    var i: usize = 0;
    while (i + 3 < src.len) : (i += 4) {
        const a: u32 = src[i + 3];
        inline for (0..3) |c| dst[i + c] = @intCast(@as(u32, src[i + c]) * rgb[2 - c] / 255 * a / 255);
        dst[i + 3] = src[i + 3];
    }
}

const testing = std.testing;

fn expectPremultiplied(px: []const u8, stride: usize) !void {
    var i: usize = 0;
    while (i + 3 < px.len) : (i += stride) {
        for (px[i..][0..3]) |c| try testing.expect(c <= px[i + 3]);
    }
}

test "atlas dimensions match the embedded data" {
    try testing.expectEqual(11, sheet_width / char_width);
    try testing.expectEqual(wiggle_count, sheet_height / char_height);
    try testing.expect(colon_column < sheet_width / char_width);
}

test "tintPremultiply: opaque white takes the tint exactly" {
    var dst: [4]u8 = undefined;
    tintPremultiply(&dst, &.{ 255, 255, 255, 255 }, .{ 220, 120, 60 });
    try testing.expectEqualSlices(u8, &.{ 60, 120, 220, 255 }, &dst);
}

test "tintPremultiply: fully transparent pixels become zero" {
    var dst: [4]u8 = undefined;
    tintPremultiply(&dst, &.{ 255, 255, 255, 0 }, .{ 220, 220, 220 });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &dst);
}

test "tintPremultiply: half alpha halves the colour" {
    var dst: [4]u8 = undefined;
    tintPremultiply(&dst, &.{ 255, 255, 255, 128 }, .{ 255, 255, 255 });
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 128 }, &dst);
}

test "tintPremultiply: output never exceeds alpha" {
    var src: [4 * 256]u8 = undefined;
    for (0..256) |i| src[i * 4 ..][0..4].* = .{ 255, 200, 128, @intCast(i) };
    var dst: [4 * 256]u8 = undefined;
    tintPremultiply(&dst, &src, .{ 255, 255, 255 });
    try expectPremultiplied(&dst, 4);
}

test "writeTintedPremultiplied: processes the whole real atlas" {
    const dst = try testing.allocator.alloc(u8, byte_len);
    defer testing.allocator.free(dst);
    writeTintedPremultiplied(dst, .{ 220, 220, 220 });
    try expectPremultiplied(dst, 4 * 997);
}
