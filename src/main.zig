//! sowon-zig — a minimal clock/timer for Windows, ported from
//! tsoding/sowon (C + OpenGL) to pure Zig + Win32/GDI.
//!
//! Modes:
//!   sowon             clock (local time)
//!   sowon clock       clock (explicit)
//!   sowon 25m         countdown timer (also 90s, 1.5h, 1h30m, ...)
//!
//! In timer mode the foreground app is sampled once per second; when
//! the countdown hits zero a chime plays and the window switches to a
//! per-app usage report.
//!
//! Keys: SPACE pause/resume (timer), ESC quit.

const std = @import("std");
const w32 = @import("win32.zig");
const chime = @import("chime.zig");
const digits = @import("digits.zig");
const server = @import("server.zig");
const Tracker = @import("tracker.zig").Tracker;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const bg_color = w32.rgb(24, 24, 24);
const main_color = w32.rgb(220, 220, 220);
const main_tint = [3]u8{ 220, 220, 220 };
const pause_tint = [3]u8{ 220, 120, 120 };

const chars_count = 8; // HH:MM:SS
const max_display_secs = 99 * 3600 + 59 * 60 + 59;
const wiggle_period_ms = 133; // = 0.40s / WIGGLE_COUNT, like the original

const timer_id_tick: usize = 1; // repaint + countdown check, 100 ms
const timer_id_track: usize = 2; // usage sampling, 1 s

const Mode = enum { clock, timer };
const Phase = enum { running, paused, finished };

const App = struct {
    alloc: std.mem.Allocator,
    mode: Mode,
    phase: Phase,
    total_ms: i64, // full timer length
    end_ms: i64, // deadline while running
    remaining_ms: i64, // frozen remainder while paused
    tracker: Tracker,
    chime_wav: []u8,
    message: []const u8,
    report_lines: []const [:0]const u16 = &.{},
    last_title_sec: i64 = -1,
};

var app: App = undefined;

fn nowMs() i64 {
    // Monotonic milliseconds since boot; immune to wall-clock changes.
    return @intCast(w32.GetTickCount64());
}

// --- Command line -----------------------------------------------------

const Config = struct {
    mode: Mode,
    seconds: u64 = 0,
    message: []const u8 = "Time's up!",
};

fn parseDuration(s: []const u8) !u64 {
    var total: f64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        var j = i;
        while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.')) j += 1;
        if (j == i) return error.InvalidDuration;
        const x = try std.fmt.parseFloat(f64, s[i..j]);

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

fn usageAndExit() noreturn {
    std.debug.print(
        \\usage:
        \\  sowon                        clock mode
        \\  sowon clock                  clock mode
        \\  sowon 25m                    timer mode (also: 90s, 1.5h, 1h30m)
        \\  sowon 25m -m "Take a walk"   message shown when the time runs out
        \\
    , .{});
    std.process.exit(1);
}

fn parseArgs(args: []const [:0]const u8) Config {
    var cfg = Config{ .mode = .clock };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i >= args.len) usageAndExit();
            cfg.message = args[i];
        } else if (std.mem.eql(u8, arg, "clock")) {
            cfg.mode = .clock;
        } else {
            cfg.seconds = parseDuration(arg) catch usageAndExit();
            cfg.mode = .timer;
        }
    }
    return cfg;
}

// --- Time & state -----------------------------------------------------

fn displayedHms() [3]u32 {
    switch (app.mode) {
        .clock => {
            var st: w32.SYSTEMTIME = undefined;
            w32.GetLocalTime(&st);
            return .{ st.wHour, st.wMinute, st.wSecond };
        },
        .timer => {
            const rem_ms: i64 = switch (app.phase) {
                .running => app.end_ms - nowMs(),
                .paused => app.remaining_ms,
                .finished => 0,
            };
            // Round up so the display reaches 00:00:00 exactly when
            // the chime fires, not a second early.
            const secs: u64 = @intCast(@divTrunc(@max(rem_ms, 0) + 999, 1000));
            const t = @min(secs, max_display_secs);
            return .{
                @intCast(t / 3600),
                @intCast(t / 60 % 60),
                @intCast(t % 60),
            };
        },
    }
}

fn togglePause() void {
    switch (app.phase) {
        .running => {
            app.remaining_ms = app.end_ms - nowMs();
            app.phase = .paused;
        },
        .paused => {
            app.end_ms = nowMs() + app.remaining_ms;
            app.phase = .running;
        },
        .finished => {},
    }
}

fn fmtDur(buf: []u8, secs: u64) ![]const u8 {
    const h = secs / 3600;
    const m = secs / 60 % 60;
    const s = secs % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h {d:0>2}m {d:0>2}s", .{ h, m, s });
    if (m > 0) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ m, s });
    return std.fmt.bufPrint(buf, "{d}s", .{s});
}

fn buildReport() !void {
    const alloc = app.alloc;
    const entries = try app.tracker.sortedEntries(alloc);

    const lines = try alloc.alloc([:0]const u16, entries.len + 3);
    var buf: [640]u8 = undefined;
    var dur_buf: [64]u8 = undefined;

    var session_buf: [64]u8 = undefined;
    const session = try fmtDur(&session_buf, @intCast(@divTrunc(app.total_ms, 1000)));
    lines[0] = try std.unicode.utf8ToUtf16LeAllocZ(
        alloc,
        try std.fmt.bufPrint(&buf, "{s}  (session: {s})", .{ app.message, session }),
    );
    lines[1] = try std.unicode.utf8ToUtf16LeAllocZ(alloc, "");
    lines[2] = try std.unicode.utf8ToUtf16LeAllocZ(alloc, "Foreground app usage:");

    for (entries, 0..) |e, i| {
        const dur = try fmtDur(&dur_buf, e.seconds);
        lines[3 + i] = try std.unicode.utf8ToUtf16LeAllocZ(
            alloc,
            try std.fmt.bufPrint(&buf, "{s:>11}   {s}", .{ dur, e.name }),
        );
    }
    app.report_lines = lines;

    // Mirror the report to the console for terminal users.
    std.debug.print("\n=== sowon: {s} (session: {s}) ===\n", .{ app.message, session });
    for (entries) |e| {
        const dur = fmtDur(&dur_buf, e.seconds) catch continue;
        std.debug.print("{s:>11}   {s}\n", .{ dur, e.name });
    }
}

fn finishTimer(hwnd: w32.HWND) void {
    app.phase = .finished;
    _ = w32.KillTimer(hwnd, timer_id_track);
    _ = w32.PlaySoundW(
        app.chime_wav.ptr,
        null,
        w32.SND_MEMORY | w32.SND_ASYNC | w32.SND_NODEFAULT,
    );
    buildReport() catch |err| {
        std.debug.print("failed to build usage report: {}\n", .{err});
    };

    // Show the custom message in the title bar, truncated if needed.
    var tbuf: [128]u8 = undefined;
    var wbuf: [128]u16 = undefined;
    const head = app.message[0..@min(app.message.len, 80)];
    if (std.fmt.bufPrint(&tbuf, "{s} - sowon", .{head})) |title| {
        if (std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], title)) |n| {
            wbuf[n] = 0;
            _ = w32.SetWindowTextW(hwnd, wbuf[0..n :0]);
        } else |_| {}
    } else |_| {}
    _ = w32.InvalidateRect(hwnd, null, 0);
}

fn updateTitle(hwnd: w32.HWND) void {
    const hms = displayedHms();
    const sec_stamp: i64 = @as(i64, hms[0]) * 3600 + @as(i64, hms[1]) * 60 + hms[2];
    if (sec_stamp == app.last_title_sec) return;
    app.last_title_sec = sec_stamp;

    var buf: [64]u8 = undefined;
    const suffix = if (app.phase == .paused) " (paused)" else "";
    const title = std.fmt.bufPrint(
        &buf,
        "{d:0>2}:{d:0>2}:{d:0>2}{s} - sowon",
        .{ hms[0], hms[1], hms[2], suffix },
    ) catch return;

    var wbuf: [64]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], title) catch return;
    wbuf[n] = 0;
    _ = w32.SetWindowTextW(hwnd, wbuf[0..n :0]);
}

// --- Rendering --------------------------------------------------------

// One memory DC per tint, each holding the sprite sheet as a
// premultiplied-alpha DIB. Created once in main, live for the process.
var sprite_main: ?w32.HDC = null;
var sprite_pause: ?w32.HDC = null;

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

fn drawClockFace(hdc: w32.HDC, width: i32, height: i32) void {
    const hms = displayedHms();
    const columns = [chars_count]u8{
        @intCast(hms[0] / 10), @intCast(hms[0] % 10), digits.colon_column,
        @intCast(hms[1] / 10), @intCast(hms[1] % 10), digits.colon_column,
        @intCast(hms[2] / 10), @intCast(hms[2] % 10),
    };
    // Same per-position wiggle phases as the original renderer.
    const wiggle_offsets = [chars_count]u8{ 0, 1, 0, 2, 3, 1, 4, 5 };
    const wiggle_index: u32 = @intCast(@mod(@divTrunc(nowMs(), wiggle_period_ms), digits.wiggle_count));

    const sprite_dc = (if (app.phase == .paused) sprite_pause else sprite_main) orelse return;

    // Fit HH:MM:SS into the client area, preserving glyph aspect ratio.
    var cell_h = height;
    var cell_w = @divTrunc(cell_h * digits.char_width, digits.char_height);
    if (cell_w * chars_count > width) {
        cell_w = @divTrunc(width, chars_count);
        cell_h = @divTrunc(cell_w * digits.char_height, digits.char_width);
    }
    const pen_x = @divTrunc(width - cell_w * chars_count, 2);
    const pen_y = @divTrunc(height - cell_h, 2);

    const blend = w32.BLENDFUNCTION{
        .BlendOp = w32.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = 255,
        .AlphaFormat = w32.AC_SRC_ALPHA,
    };

    for (columns, wiggle_offsets, 0..) |col, wiggle_offset, i| {
        const row = (wiggle_index + wiggle_offset) % digits.wiggle_count;
        _ = w32.AlphaBlend(
            hdc,
            pen_x + @as(i32, @intCast(i)) * cell_w,
            pen_y,
            cell_w,
            cell_h,
            sprite_dc,
            @as(i32, col) * digits.char_width,
            @as(i32, @intCast(row)) * digits.char_height,
            digits.char_width,
            digits.char_height,
            blend,
        );
    }
}

fn drawReport(hdc: w32.HDC, height: i32) void {
    const line_height = std.math.clamp(@divTrunc(height, 18), 18, 44);
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
    _ = w32.SetTextColor(hdc, main_color);

    var y: i32 = 24;
    for (app.report_lines) |line| {
        _ = w32.TextOutW(hdc, 24, y, line.ptr, @intCast(line.len));
        y += line_height;
    }
}

fn onPaint(hwnd: w32.HWND) void {
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

    if (app.phase == .finished) {
        drawReport(mem_dc, height);
    } else {
        drawClockFace(mem_dc, width, height);
    }

    _ = w32.BitBlt(hdc, 0, 0, width, height, mem_dc, 0, 0, w32.SRCCOPY);
}

// --- Window proc & main -----------------------------------------------

fn wndProc(hwnd: w32.HWND, msg: w32.UINT, wparam: w32.WPARAM, lparam: w32.LPARAM) callconv(.winapi) w32.LRESULT {
    switch (msg) {
        w32.WM_PAINT => {
            onPaint(hwnd);
            return 0;
        },
        w32.WM_ERASEBKGND => return 1, // memory bitmap covers everything
        w32.WM_TIMER => {
            switch (wparam) {
                timer_id_tick => {
                    if (app.mode == .timer and app.phase == .running and nowMs() >= app.end_ms) {
                        finishTimer(hwnd);
                    }
                    if (app.phase != .finished) updateTitle(hwnd);
                    _ = w32.InvalidateRect(hwnd, null, 0);
                },
                timer_id_track => {
                    if (app.phase == .running) app.tracker.sample() catch {};
                },
                else => {},
            }
            return 0;
        },
        w32.WM_KEYDOWN => {
            switch (wparam) {
                w32.VK_SPACE => {
                    if (app.mode == .timer) {
                        togglePause();
                        app.last_title_sec = -1; // force title refresh
                        _ = w32.InvalidateRect(hwnd, null, 0);
                    }
                },
                w32.VK_ESCAPE => _ = w32.DestroyWindow(hwnd),
                else => {},
            }
            return 0;
        },
        w32.WM_SIZE => {
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_DESTROY => {
            w32.PostQuitMessage(0);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

pub fn main(init: std.process.Init) !void {
    // Everything lives for the whole run; the process arena keeps
    // cleanup trivial.
    const alloc = init.arena.allocator();

    const cfg = parseArgs(try init.minimal.args.toSlice(alloc));
    const total_ms: i64 = @intCast(cfg.seconds * 1000);

    app = .{
        .alloc = alloc,
        .mode = cfg.mode,
        .phase = .running,
        .total_ms = total_ms,
        .end_ms = nowMs() + total_ms,
        .remaining_ms = total_ms,
        .tracker = Tracker.init(alloc),
        .chime_wav = try chime.buildWav(alloc),
        .message = cfg.message,
    };

    sprite_main = try makeSpriteDc(main_tint);
    sprite_pause = try makeSpriteDc(pause_tint);

    // Focus tracking wants browser detail; the listener is harmless if
    // the extension never connects.
    if (cfg.mode == .timer) server.start();

    const instance = w32.GetModuleHandleW(null);
    const class_name = L("sowon-zig");

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.makeIntResourceW(w32.IDC_ARROW)),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

    const hwnd = w32.CreateWindowExW(
        0,
        class_name,
        L("sowon"),
        w32.WS_OVERLAPPEDWINDOW,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        900,
        280,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);

    if (w32.SetTimer(hwnd, timer_id_tick, 100, null) == 0) return error.SetTimerFailed;
    if (app.mode == .timer) {
        if (w32.SetTimer(hwnd, timer_id_track, 1000, null) == 0) return error.SetTimerFailed;
    }

    var msg: w32.MSG = undefined;
    while (w32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}
