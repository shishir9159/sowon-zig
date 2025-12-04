//! The original sowon digit sprite sheet (assets/digits.png), embedded
//! as raw BGRA pixels: 11 columns (digits 0-9 plus colon) by 3 wiggle
//! rows of 150x190 glyphs.

const std = @import("std");

pub const sheet_width = 1650;
pub const sheet_height = 570;
pub const char_width = 150;
pub const char_height = 190;
pub const wiggle_count = 3;
pub const colon_column = 10;

const raw = @embedFile("digits.bgra"); // straight-alpha BGRA, top-down

pub const byte_len = raw.len;

comptime {
    std.debug.assert(raw.len == sheet_width * sheet_height * 4);
}

/// Fills `dst` with the sprite sheet tinted by `rgb` and converted to
/// premultiplied alpha, the format GDI's AlphaBlend expects.
pub fn writeTintedPremultiplied(dst: []u8, rgb: [3]u8) void {
    std.debug.assert(dst.len == raw.len);
    tintPremultiply(dst, raw, rgb);
}

/// The per-pixel conversion, split out so it can be unit-tested against a
/// synthetic source without allocating a copy of the 3.7 MB atlas.
fn tintPremultiply(dst: []u8, src: []const u8, rgb: [3]u8) void {
    std.debug.assert(dst.len == src.len);
    var i: usize = 0;
    while (i + 3 < src.len) : (i += 4) {
        const a: u32 = src[i + 3];
        dst[i + 0] = @intCast(@as(u32, src[i + 0]) * rgb[2] / 255 * a / 255); // B
        dst[i + 1] = @intCast(@as(u32, src[i + 1]) * rgb[1] / 255 * a / 255); // G
        dst[i + 2] = @intCast(@as(u32, src[i + 2]) * rgb[0] / 255 * a / 255); // R
        dst[i + 3] = @intCast(a);
    }
}

const testing = std.testing;

test "atlas dimensions match the embedded data" {
    try testing.expectEqual(@as(usize, sheet_width * sheet_height * 4), byte_len);
    // 11 glyph columns (0-9 plus the colon) and 3 wiggle rows.
    try testing.expectEqual(@as(usize, 11), sheet_width / char_width);
    try testing.expectEqual(@as(usize, wiggle_count), sheet_height / char_height);
    try testing.expect(colon_column < sheet_width / char_width);
}

test "tintPremultiply: opaque white takes the tint exactly" {
    // BGRA opaque white.
    const src = [_]u8{ 255, 255, 255, 255 };
    var dst: [4]u8 = undefined;
    tintPremultiply(&dst, &src, .{ 220, 120, 60 }); // r, g, b
    try testing.expectEqual(@as(u8, 60), dst[0]); // B
    try testing.expectEqual(@as(u8, 120), dst[1]); // G
    try testing.expectEqual(@as(u8, 220), dst[2]); // R
    try testing.expectEqual(@as(u8, 255), dst[3]); // A preserved
}

test "tintPremultiply: fully transparent pixels become zero" {
    const src = [_]u8{ 255, 255, 255, 0 };
    var dst: [4]u8 = undefined;
    tintPremultiply(&dst, &src, .{ 220, 220, 220 });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &dst);
}

test "tintPremultiply: half alpha halves the colour (premultiplied)" {
    const src = [_]u8{ 255, 255, 255, 128 };
    var dst: [4]u8 = undefined;
    tintPremultiply(&dst, &src, .{ 255, 255, 255 });
    // 255 * 255/255 * 128/255 = 128
    try testing.expectEqual(@as(u8, 128), dst[0]);
    try testing.expectEqual(@as(u8, 128), dst[3]);
}

test "tintPremultiply: output never exceeds alpha (valid premultiplied)" {
    // Any premultiplied channel must be <= alpha, or GDI renders halos.
    var src: [4 * 256]u8 = undefined;
    for (0..256) |i| {
        src[i * 4 + 0] = 255;
        src[i * 4 + 1] = 200;
        src[i * 4 + 2] = 128;
        src[i * 4 + 3] = @intCast(i);
    }
    var dst: [4 * 256]u8 = undefined;
    tintPremultiply(&dst, &src, .{ 255, 255, 255 });

    for (0..256) |i| {
        const a = dst[i * 4 + 3];
        try testing.expect(dst[i * 4 + 0] <= a);
        try testing.expect(dst[i * 4 + 1] <= a);
        try testing.expect(dst[i * 4 + 2] <= a);
    }
}

test "writeTintedPremultiplied: processes the whole real atlas" {
    const dst = try testing.allocator.alloc(u8, byte_len);
    defer testing.allocator.free(dst);
    writeTintedPremultiplied(dst, .{ 220, 220, 220 });

    // Spot-check the invariant across the real sprite sheet.
    var i: usize = 0;
    while (i + 3 < dst.len) : (i += 4 * 997) { // stride by a prime to sample widely
        const a = dst[i + 3];
        try testing.expect(dst[i + 0] <= a);
        try testing.expect(dst[i + 1] <= a);
        try testing.expect(dst[i + 2] <= a);
    }
}