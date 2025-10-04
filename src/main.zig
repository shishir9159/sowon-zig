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
const Tracker = @import("tracker.zig").Tracker;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const bg_color = w32.rgb(24, 24, 24);
const main_color = w32.rgb(220, 220, 220);
const pause_color = w32.rgb(220, 120, 120);

const chars_count = 8; // HH:MM:SS
const char_aspect_w = 150;
const char_aspect_h = 190;
const max_display_secs = 99 * 3600 + 59 * 60 + 59;

const timer_id_tick: usize = 1; // repaint + countdown check, 100 ms
const timer_id_track: usize = 2; // usage sampling, 1 s

const Mode = enum { clock, timer };
const Phase = enum { running, paused, finished };

// Segment bits: A top, B top-right, C bottom-right, D bottom,
// E bottom-left, F top-left, G middle.
const seg_a: u8 = 1 << 0;
const seg_b: u8 = 1 << 1;
const seg_c: u8 = 1 << 2;
const seg_d: u8 = 1 << 3;
const seg_e: u8 = 1 << 4;
const seg_f: u8 = 1 << 5;
const seg_g: u8 = 1 << 6;

const seg_table = [10]u8{
    seg_a | seg_b | seg_c | seg_d | seg_e | seg_f, // 0
    seg_b | seg_c, // 1
    seg_a | seg_b | seg_g | seg_e | seg_d, // 2
    seg_a | seg_b | seg_g | seg_c | seg_d, // 3
    seg_f | seg_g | seg_b | seg_c, // 4
    seg_a | seg_f | seg_g | seg_c | seg_d, // 5
    seg_a | seg_f | seg_g | seg_e | seg_c | seg_d, // 6
    seg_a | seg_b | seg_c, // 7
    seg_a | seg_b | seg_c | seg_d | seg_e | seg_f | seg_g, // 8
    seg_a | seg_b | seg_c | seg_d | seg_f | seg_g, // 9
};
const colon_index = 10;

const App = struct {
    alloc: std.mem.Allocator,
    mode: Mode,
    phase: Phase,
    total_ms: i64, // full timer length
    end_ms: i64, // deadline while running
    remaining_ms: i64, // frozen remainder while paused
    tracker: Tracker,
    chime_wav: []u8,
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

fn parseArgs(args: []const [:0]const u8) Config {
    if (args.len <= 1) return .{ .mode = .clock };
    if (std.mem.eql(u8, args[1], "clock")) return .{ .mode = .clock };

    const seconds = parseDuration(args[1]) catch {
        std.debug.print(
            \\usage:
            \\  sowon           clock mode
            \\  sowon clock     clock mode
            \\  sowon 25m       timer mode (also: 90s, 1.5h, 1h30m)
            \\
        , .{});
        std.process.exit(1);
    };
    return .{ .mode = .timer, .seconds = seconds };
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
        try std.fmt.bufPrint(&buf, "Time's up!  Session length: {s}", .{session}),
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
    std.debug.print("\n=== sowon: time's up! (session: {s}) ===\n", .{session});
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
    _ = w32.SetWindowTextW(hwnd, L("Time's up! - sowon"));
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

fn fillRect(hdc: w32.HDC, brush: w32.HBRUSH, left: i32, top: i32, right: i32, bottom: i32) void {
    const rc = w32.RECT{ .left = left, .top = top, .right = right, .bottom = bottom };
    _ = w32.FillRect(hdc, &rc, brush);
}

fn drawCell(hdc: w32.HDC, brush: w32.HBRUSH, x: i32, y: i32, cw: i32, ch: i32, digit: u8) void {
    const pad = @divTrunc(cw, 10);
    const x0 = x + pad;
    const x1 = x + cw - pad;
    const y0 = y + pad;
    const y1 = y + ch - pad;
    const t = @divTrunc(cw, 6); // segment thickness
    const ym = @divTrunc(y0 + y1, 2);

    if (digit == colon_index) {
        const cx = @divTrunc(x0 + x1, 2);
        const third = @divTrunc(y1 - y0, 3);
        const half = @divTrunc(t, 2);
        fillRect(hdc, brush, cx - half, y0 + third - half, cx + half, y0 + third + half);
        fillRect(hdc, brush, cx - half, y0 + 2 * third - half, cx + half, y0 + 2 * third + half);
        return;
    }

    const seg = seg_table[digit];
    if (seg & seg_a != 0) fillRect(hdc, brush, x0, y0, x1, y0 + t);
    if (seg & seg_g != 0) fillRect(hdc, brush, x0, ym - @divTrunc(t, 2), x1, ym + @divTrunc(t, 2));
    if (seg & seg_d != 0) fillRect(hdc, brush, x0, y1 - t, x1, y1);
    if (seg & seg_f != 0) fillRect(hdc, brush, x0, y0, x0 + t, ym);
    if (seg & seg_b != 0) fillRect(hdc, brush, x1 - t, y0, x1, ym);
    if (seg & seg_e != 0) fillRect(hdc, brush, x0, ym, x0 + t, y1);
    if (seg & seg_c != 0) fillRect(hdc, brush, x1 - t, ym, x1, y1);
}

fn drawClockFace(hdc: w32.HDC, width: i32, height: i32) void {
    const hms = displayedHms();
    const digits = [chars_count]u8{
        @intCast(hms[0] / 10), @intCast(hms[0] % 10), colon_index,
        @intCast(hms[1] / 10), @intCast(hms[1] % 10), colon_index,
        @intCast(hms[2] / 10), @intCast(hms[2] % 10),
    };

    const color = if (app.phase == .paused) pause_color else main_color;
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(brush);

    // Fit HH:MM:SS into the client area, preserving cell aspect ratio.
    var cell_h = height;
    var cell_w = @divTrunc(cell_h * char_aspect_w, char_aspect_h);
    if (cell_w * chars_count > width) {
        cell_w = @divTrunc(width, chars_count);
        cell_h = @divTrunc(cell_w * char_aspect_h, char_aspect_w);
    }
    const pen_x = @divTrunc(width - cell_w * chars_count, 2);
    const pen_y = @divTrunc(height - cell_h, 2);

    for (digits, 0..) |d, i| {
        const x = pen_x + @as(i32, @intCast(i)) * cell_w;
        drawCell(hdc, brush, x, pen_y, cell_w, cell_h, d);
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
    };

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
