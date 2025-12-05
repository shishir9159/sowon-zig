const std = @import("std");
const w32 = @import("../win32.zig");
const digits = @import("../digits.zig");
const frame = @import("frame.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const bg_color = w32.rgb(24, 24, 24);
const text_color = w32.rgb(220, 220, 220);

var sprites = std.enums.EnumArray(frame.Tint, ?w32.HDC).initFill(null);

pub const reportVisibleLines = frame.reportVisibleLines;

pub fn init() !void {
    for (std.enums.values(frame.Tint)) |tint| sprites.set(tint, try makeSpriteDc(frame.tintRgb(tint)));
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

    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const bitmap = w32.CreateCompatibleBitmap(hdc, width, height) orelse return;
    defer _ = w32.DeleteObject(bitmap);
    const old_bitmap = w32.SelectObject(mem_dc, bitmap);
    defer if (old_bitmap) |b| {
        _ = w32.SelectObject(mem_dc, b);
    };

    if (w32.CreateSolidBrush(bg_color)) |brush| {
        _ = w32.FillRect(mem_dc, &rc, brush);
        _ = w32.DeleteObject(brush);
    }

    switch (view) {
        .clock => |clock| drawClockFace(mem_dc, width, height, clock),
        .report => |report| drawReport(mem_dc, height, report),
    }

    _ = w32.BitBlt(hdc, 0, 0, width, height, mem_dc, 0, 0, w32.SRCCOPY);
}

fn makeSpriteDc(tint: [3]u8) !w32.HDC {
    var bi = std.mem.zeroes(w32.BITMAPINFO);
    bi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = digits.sheet_width;
    bi.bmiHeader.biHeight = -@as(i32, digits.sheet_height);
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = w32.BI_RGB;

    var bits: ?*anyopaque = null;
    const bmp = w32.CreateDIBSection(null, &bi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return error.CreateDIBSectionFailed;
    const pixels: [*]u8 = @ptrCast(bits orelse return error.CreateDIBSectionFailed);
    digits.writeTintedPremultiplied(pixels[0..digits.byte_len], tint);

    const dc = w32.CreateCompatibleDC(null) orelse return error.CreateDCFailed;
    _ = w32.SelectObject(dc, bmp);
    return dc;
}

fn drawClockFace(hdc: w32.HDC, width: i32, height: i32, clock: frame.ClockFace) void {
    const sprite_dc = sprites.get(clock.tint) orelse return;

    var cell_h = height;
    var cell_w = @divTrunc(cell_h * digits.char_width, digits.char_height);
    if (cell_w * frame.chars_count > width) {
        cell_w = @divTrunc(width, frame.chars_count);
        cell_h = @divTrunc(cell_w * digits.char_height, digits.char_width);
    }
    const pen_x = @divTrunc(width - cell_w * frame.chars_count, 2);
    const pen_y = @divTrunc(height - cell_h, 2);
    const blend = w32.BLENDFUNCTION{ .BlendOp = w32.AC_SRC_OVER, .BlendFlags = 0, .SourceConstantAlpha = 255, .AlphaFormat = w32.AC_SRC_ALPHA };

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

fn drawReport(hdc: w32.HDC, height: i32, report: frame.ReportView) void {
    const line_height = frame.reportLineHeight(height);
    const font = w32.CreateFontW(-(line_height - 6), 0, 0, 0, w32.FW_NORMAL, 0, 0, 0, w32.DEFAULT_CHARSET, 0, 0, w32.CLEARTYPE_QUALITY, 0, L("Consolas")) orelse return;
    defer _ = w32.DeleteObject(font);
    const old_font = w32.SelectObject(hdc, font);
    defer if (old_font) |f| {
        _ = w32.SelectObject(hdc, f);
    };

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, text_color);

    const max_scroll = @max(@as(i32, @intCast(report.lines.len)) - reportVisibleLines(height), 0);
    report.scroll.* = std.math.clamp(report.scroll.*, 0, max_scroll);

    var y = frame.report_top_margin;
    for (report.lines[@intCast(report.scroll.*)..]) |line| {
        if (y >= height) break;
        textOut(hdc, 24, y, line);
        y += line_height;
    }
    if (report.scroll.* > 0) textOut(hdc, 4, frame.report_top_margin, L("^^^"));
    if (report.scroll.* < max_scroll) textOut(hdc, 4, height - line_height, L("vvv"));
}

fn textOut(hdc: w32.HDC, x: i32, y: i32, text: []const u16) void {
    _ = w32.TextOutW(hdc, x, y, text.ptr, @intCast(text.len));
}
