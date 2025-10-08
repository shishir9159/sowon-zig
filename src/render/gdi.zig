//! GDI rendering backend: sprite sheet as premultiplied-alpha DIBs,
//! blitted with AlphaBlend, double-buffered through a memory bitmap.
//! The only backend with an implementation so far; selected with
//! -Drenderer=gdi (the default).

const std = @import("std");
const w32 = @import("../win32.zig");
const digits = @import("../digits.zig");
const frame = @import("frame.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const bg_color = w32.rgb(24, 24, 24);
const text_color = w32.rgb(220, 220, 220);
const report_top_margin: i32 = 24;

fn tintRgb(tint: frame.Tint) [3]u8 {
    return switch (tint) {
        .normal => .{ 220, 220, 220 },
        .paused => .{ 220, 120, 120 },
        .brk => .{ 130, 210, 150 },
    };
}

// One memory DC per tint, each holding the tinted sprite sheet.
// Created once in init, live for the process.
var sprites = [_]?w32.HDC{null} ** std.enums.values(frame.Tint).len;

pub fn init() !void {
    for (std.enums.values(frame.Tint)) |tint| {
        sprites[@intFromEnum(tint)] = try makeSpriteDc(tintRgb(tint));
    }
}

pub fn paint(hwnd: w32.HWND, view: frame.View) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    const width = rc.right - rc.left;
    const height = rc.bottom - rc.top;
    if (width <= 0 or height <= 0) return;

    // Double buffering: draw into a memory bitmap, blit once.
    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const bitmap = w32.CreateCompatibleBitmap(hdc, width, height) orelse return;
    defer _ = w32.DeleteObject(bitmap);
    const old_bitmap = w32.SelectObject(mem_dc, bitmap);
    defer if (old_bitmap) |b| {
        _ = w32.SelectObject(mem_dc, b);
    };

    if (w32.CreateSolidBrush(bg_color)) |bg_brush| {
        _ = w32.FillRect(mem_dc, &rc, bg_brush);
        _ = w32.DeleteObject(bg_brush);
    }

    switch (view) {
        .clock => |clock| drawClockFace(mem_dc, width, height, clock),
        .report => |report| drawReport(mem_dc, height, report),
    }

    _ = w32.BitBlt(hdc, 0, 0, width, height, mem_dc, 0, 0, w32.SRCCOPY);
}

pub fn reportVisibleLines(height: i32) i32 {
    return @max(@divTrunc(height - report_top_margin, reportLineHeight(height)), 1);
}

fn makeSpriteDc(tint: [3]u8) !w32.HDC {
    var bi = std.mem.zeroes(w32.BITMAPINFO);
    bi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = digits.sheet_width;
    bi.bmiHeader.biHeight = -@as(i32, digits.sheet_height); // top-down
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = w32.BI_RGB;

    var bits: ?*anyopaque = null;
    const bmp = w32.CreateDIBSection(null, &bi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse
        return error.CreateDIBSectionFailed;
    const pixels: [*]u8 = @ptrCast(bits orelse return error.CreateDIBSectionFailed);
    digits.writeTintedPremultiplied(pixels[0..digits.byte_len], tint);

    const dc = w32.CreateCompatibleDC(null) orelse return error.CreateDCFailed;
    _ = w32.SelectObject(dc, bmp);
    return dc;
}

fn drawClockFace(hdc: w32.HDC, width: i32, height: i32, clock: frame.ClockFace) void {
    const sprite_dc = sprites[@intFromEnum(clock.tint)] orelse return;

    // Fit HH:MM:SS into the client area, preserving glyph aspect ratio.
    var cell_h = height;
    var cell_w = @divTrunc(cell_h * digits.char_width, digits.char_height);
    if (cell_w * frame.chars_count > width) {
        cell_w = @divTrunc(width, frame.chars_count);
        cell_h = @divTrunc(cell_w * digits.char_height, digits.char_width);
    }
    const pen_x = @divTrunc(width - cell_w * frame.chars_count, 2);
    const pen_y = @divTrunc(height - cell_h, 2);

    const blend = w32.BLENDFUNCTION{
        .BlendOp = w32.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = 255,
        .AlphaFormat = w32.AC_SRC_ALPHA,
    };

    for (clock.columns, clock.rows, 0..) |col, row, i| {
        _ = w32.AlphaBlend(
            hdc,
            pen_x + @as(i32, @intCast(i)) * cell_w,
            pen_y,
            cell_w,
            cell_h,
            sprite_dc,
            @as(i32, col) * digits.char_width,
            @as(i32, row) * digits.char_height,
            digits.char_width,
            digits.char_height,
            blend,
        );
    }
}

fn reportLineHeight(height: i32) i32 {
    return std.math.clamp(@divTrunc(height, 18), 18, 44);
}

fn drawReport(hdc: w32.HDC, height: i32, report: frame.ReportView) void {
    const line_height = reportLineHeight(height);
    const font = w32.CreateFontW(
        -(line_height - 6),
        0,
        0,
        0,
        w32.FW_NORMAL,
        0,
        0,
        0,
        w32.DEFAULT_CHARSET,
        0,
        0,
        w32.CLEARTYPE_QUALITY,
        0,
        L("Consolas"),
    ) orelse return;
    defer _ = w32.DeleteObject(font);

    const old_font = w32.SelectObject(hdc, font);
    defer if (old_font) |f| {
        _ = w32.SelectObject(hdc, f);
    };

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, text_color);

    // Keep the scroll position valid for the current window size.
    const total: i32 = @intCast(report.lines.len);
    const max_scroll = @max(total - reportVisibleLines(height), 0);
    report.scroll.* = std.math.clamp(report.scroll.*, 0, max_scroll);

    var y: i32 = report_top_margin;
    const start: usize = @intCast(report.scroll.*);
    for (report.lines[start..]) |line| {
        if (y >= height) break;
        _ = w32.TextOutW(hdc, 24, y, line.ptr, @intCast(line.len));
        y += line_height;
    }

    // Overflow hints so it's obvious there is more to scroll to.
    if (report.scroll.* > 0) {
        const up = L("^^^");
        _ = w32.TextOutW(hdc, 4, report_top_margin, up.ptr, @intCast(up.len));
    }
    if (report.scroll.* < max_scroll) {
        const down = L("vvv");
        _ = w32.TextOutW(hdc, 4, height - line_height, down.ptr, @intCast(down.len));
    }
}
