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
    var i: usize = 0;
    while (i < raw.len) : (i += 4) {
        const a: u32 = raw[i + 3];
        dst[i + 0] = @intCast(@as(u32, raw[i + 0]) * rgb[2] / 255 * a / 255); // B
        dst[i + 1] = @intCast(@as(u32, raw[i + 1]) * rgb[1] / 255 * a / 255); // G
        dst[i + 2] = @intCast(@as(u32, raw[i + 2]) * rgb[0] / 255 * a / 255); // R
        dst[i + 3] = @intCast(a);
    }
}