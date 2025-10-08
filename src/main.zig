const std = @import("std");
const build_options = @import("build_options");
const w32 = @import("win32.zig");
const chime = @import("chime.zig");
const digits = @import("digits.zig");
const server = @import("server.zig");
const db = @import("db.zig");
const util = @import("util.zig");
const frame = @import("render/frame.zig");
const Tracker = @import("tracker.zig").Tracker;

const parseDuration = util.parseDuration;
const fmtDur = util.fmtDur;

// Usage credited to this bucket when input has been idle for a while;
// excluded from the focus/distraction split so a bio break neither
// flatters nor punishes the score.
const idle_key = "(idle)";
const idle_threshold_secs: u64 = 120;

// Build-time backend selection (-Drenderer=...): only the chosen
// module is analyzed and compiled; the others are discarded.
const renderer = switch (build_options.renderer) {
    .gdi => @import("render/gdi.zig"),
    .opengl => @import("render/opengl.zig"),
    .vulkan => @import("render/vulkan.zig"),
    .sdl => @import("render/sdl.zig"),
    .glfw => @import("render/glfw.zig"),
};

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const max_display_secs = 99 * 3600 + 59 * 60 + 59;
const wiggle_period_ms = 133; // = 0.40s / WIGGLE_COUNT, like the original

const timer_id_tick: usize = 1; // repaint + countdown check, 100 ms
const timer_id_track: usize = 2; // usage sampling

// Set at build time: SOWON_SAMPLE_INTERVAL=5 zig build ... (default 10).
const sample_interval_secs: u64 = @max(build_options.sample_interval_secs, 1);

const Mode = enum { clock, timer };
const Phase = enum { running, paused, finished };
const Kind = enum { work, brk };

const SessionSummary = struct {
    start_buf: [32]u8 = undefined,
    start_len: usize = 0,
    focused: u64 = 0,
    distracted: u64 = 0,
};

const App = struct {
    alloc: std.mem.Allocator,
    mode: Mode,
    phase: Phase,
    kind: Kind = .work,
    cycle: u32 = 1, // 1-based work-session counter
    cycles_total: u32 = 1,
    work_secs: u64 = 0,
    break_secs: u64 = 0,
    total_ms: i64, // length of the countdown currently running
    end_ms: i64, // deadline while running
    remaining_ms: i64, // frozen remainder while paused
    tracker: Tracker, // current work session only
    total_tracker: Tracker, // aggregated across all cycles
    summaries: []SessionSummary = &.{},
    summary_count: usize = 0,
    chime_wav: []u8,
    break_chime_wav: []u8,
    nudge_wav: []u8,
    message: []const u8,
    tag: []const u8 = "",
    allow: []const []const u8 = &.{},
    nudge_threshold: u64 = 0, // seconds of distraction before a nudge; 0 = off
    nudge_run: u64 = 0, // consecutive distracted seconds so far
    history: ?db.Db = null,
    session_start_buf: [32]u8 = undefined,
    session_start_len: usize = 0,
    session_start_ms: i64 = 0, // monotonic; for actual elapsed wall-clock
    report_lines: []const [:0]const u16 = &.{},
    report_scroll: i32 = 0, // first visible report line
    last_title_sec: i64 = -1,
};

var app: App = undefined;

fn nowMs() i64 {
    // Monotonic milliseconds since boot; immune to wall-clock changes.
    return @intCast(w32.GetTickCount64());
}

fn nowLocalString(buf: []u8) []const u8 {
    var st: w32.SYSTEMTIME = undefined;
    w32.GetLocalTime(&st);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
    }) catch buf[0..0];
}

// --- Command line -----------------------------------------------------

const Config = struct {
    mode: Mode,
    seconds: u64 = 0,
    message: []const u8 = "Time's up!",
    tag: []const u8 = "",
    repeats: u32 = 1,
    break_seconds: u64 = 0,
    nudge_seconds: u64 = 0, // 0 = nudge off
    topmost: bool = false,
    allow: []const []const u8 = &.{},
};

fn usageAndExit() noreturn {
    std.debug.print(
        \\usage:
        \\  sowon                        clock mode
        \\  sowon clock                  clock mode
        \\  sowon 25m                    timer mode (also: 90s, 1.5h, 1h30m)
        \\    -m "Take a walk"           message shown when the time runs out
        \\    -t deep-work               tag this session (for tagged reports)
        \\    -r 4                       repeat: 4 work sessions (pomodoro)
        \\    -b 5m                      break between work sessions
        \\    -a explorer.exe            allow an app, Chrome tab group, or
        \\                               domain in focus mode; repeatable.
        \\                               Adds to the saved allow list.
        \\    -n 30s                     nudge (flash + tick) after being
        \\                               distracted this long; needs allows
        \\    --top                      keep the window always on top
        \\
        \\  sowon history [N]            show the last N sessions (default 15)
        \\  sowon report today|week      aggregate report
        \\    -t deep-work               ... only sessions with this tag
        \\  sowon allow list             show the saved allow list
        \\  sowon allow add <pattern>    add an app/group/domain to it
        \\  sowon allow remove <pattern> remove one
        \\
        \\Sessions are recorded to %LOCALAPPDATA%\sowon\sowon.db.
        \\
    , .{});
    std.process.exit(1);
}

fn parseArgs(alloc: std.mem.Allocator, args: []const [:0]const u8) Config {
    var cfg = Config{ .mode = .clock };

    var allow = alloc.alloc([]const u8, args.len) catch usageAndExit();
    var allow_count: usize = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i >= args.len) usageAndExit();
            cfg.message = args[i];
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tag")) {
            i += 1;
            if (i >= args.len) usageAndExit();
            cfg.tag = args[i];
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--nudge")) {
            i += 1;
            if (i >= args.len) usageAndExit();
            cfg.nudge_seconds = parseDuration(args[i]) catch usageAndExit();
        } else if (std.mem.eql(u8, arg, "--top")) {
            cfg.topmost = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--repeat")) {
            i += 1;
            if (i >= args.len) usageAndExit();
            cfg.repeats = std.fmt.parseInt(u32, args[i], 10) catch usageAndExit();
            if (cfg.repeats < 1) usageAndExit();
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--break")) {
            i += 1;
            if (i >= args.len) usageAndExit();
            cfg.break_seconds = parseDuration(args[i]) catch usageAndExit();
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--allow")) {
            i += 1;
            if (i >= args.len) usageAndExit();
            allow[allow_count] = args[i];
            allow_count += 1;
        } else if (std.mem.eql(u8, arg, "clock")) {
            cfg.mode = .clock;
        } else {
            cfg.seconds = parseDuration(arg) catch usageAndExit();
            cfg.mode = .timer;
        }
    }
    cfg.allow = allow[0..allow_count];
    return cfg;
}

// --- Focus classification ----------------------------------------------

fn isAllowed(name: []const u8) bool {
    return util.isAllowedIn(app.allow, name);
}

const FocusSplit = struct { focused: u64, distracted: u64 };

fn splitFocus(entries: []const Tracker.Entry) FocusSplit {
    var split = FocusSplit{ .focused = 0, .distracted = 0 };
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, idle_key)) continue; // idle is neither
        if (isAllowed(e.name)) {
            split.focused += e.seconds;
        } else {
            split.distracted += e.seconds;
        }
    }
    return split;
}

/// Seconds since the last keyboard/mouse input, system-wide.
fn idleSeconds() u64 {
    var info = w32.LASTINPUTINFO{ .cbSize = @sizeOf(w32.LASTINPUTINFO), .dwTime = 0 };
    if (w32.GetLastInputInfo(&info) == 0) return 0;
    // 32-bit GetTickCount stamp; wrapping subtraction handles rollover.
    const now32: u32 = @truncate(@as(u64, @bitCast(nowMs())));
    return (now32 -% info.dwTime) / 1000;
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

fn startCountdown(secs: u64) void {
    app.total_ms = @intCast(secs * 1000);
    app.end_ms = nowMs() + app.total_ms;
    app.remaining_ms = app.total_ms;
    app.phase = .running;
    app.last_title_sec = -1;
}

fn startWork(cycle: u32) void {
    app.kind = .work;
    app.cycle = cycle;
    app.tracker = Tracker.init(app.alloc); // fresh stats per work session
    app.report_lines = &.{};
    app.session_start_len = nowLocalString(&app.session_start_buf).len;
    app.session_start_ms = nowMs();
    startCountdown(app.work_secs);
}

fn startBreak() void {
    app.kind = .brk;
    startCountdown(app.break_secs);
}

fn playWav(wav: []u8) void {
    _ = w32.PlaySoundW(wav.ptr, null, w32.SND_MEMORY | w32.SND_ASYNC | w32.SND_NODEFAULT);
}

// --- Tray icon, toast, nudge -------------------------------------------

const wm_tray: w32.UINT = w32.WM_APP + 1;

fn copyUtf16z(dst: []u16, src: []const u8) void {
    const n = std.unicode.utf8ToUtf16Le(dst[0 .. dst.len - 1], src) catch 0;
    dst[n] = 0;
}

fn trayBase(hwnd: w32.HWND) w32.NOTIFYICONDATAW {
    var nid = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    return nid;
}

fn trayAdd(hwnd: w32.HWND) void {
    var nid = trayBase(hwnd);
    nid.uFlags = w32.NIF_MESSAGE | w32.NIF_ICON | w32.NIF_TIP;
    nid.uCallbackMessage = wm_tray;
    nid.hIcon = w32.LoadIconW(null, w32.makeIntResourceW(w32.IDI_APPLICATION));
    copyUtf16z(&nid.szTip, "sowon");
    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
}

fn trayRemove(hwnd: w32.HWND) void {
    var nid = trayBase(hwnd);
    _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
}

/// Balloon notification — rendered as a Windows toast on Win 10/11.
fn trayToast(hwnd: w32.HWND, text: []const u8) void {
    var nid = trayBase(hwnd);
    nid.uFlags = w32.NIF_INFO;
    nid.dwInfoFlags = w32.NIIF_INFO;
    copyUtf16z(&nid.szInfoTitle, "sowon");
    copyUtf16z(&nid.szInfo, text[0..@min(text.len, 250)]);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);
}

/// Distraction nudge: flash the taskbar button and play a soft tick.
fn nudge(hwnd: w32.HWND) void {
    const info = w32.FLASHWINFO{
        .cbSize = @sizeOf(w32.FLASHWINFO),
        .hwnd = hwnd,
        .dwFlags = w32.FLASHW_ALL,
        .uCount = 3,
        .dwTimeout = 0,
    };
    _ = w32.FlashWindowEx(&info);
    playWav(app.nudge_wav);
}

/// Wraps up the just-finished work session: remembers its summary,
/// folds its usage into the whole-run aggregate, and persists it.
fn endWorkSession() void {
    const entries = app.tracker.sortedEntries(app.alloc) catch return;
    const split = splitFocus(entries);

    if (app.summary_count < app.summaries.len) {
        const s = &app.summaries[app.summary_count];
        s.start_buf = app.session_start_buf;
        s.start_len = app.session_start_len;
        s.focused = split.focused;
        s.distracted = split.distracted;
        app.summary_count += 1;
    }

    for (entries) |e| {
        _ = app.total_tracker.add(e.name, e.seconds) catch {};
    }

    if (app.history) |*history| {
        const rows = app.alloc.alloc(db.UsageRow, entries.len) catch return;
        for (entries, 0..) |e, i| {
            rows[i] = .{ .app = e.name, .seconds = e.seconds, .allowed = isAllowed(e.name) };
        }
        // Actual wall-clock span, including any paused time — this is
        // what makes started_at + elapsed line up, unlike the planned
        // (active) duration.
        const elapsed: u64 = @intCast(@divTrunc(@max(nowMs() - app.session_start_ms, 0) + 500, 1000));
        history.recordSession(.{
            .started_at = app.session_start_buf[0..app.session_start_len],
            .duration_sec = app.work_secs,
            .elapsed_sec = elapsed,
            .message = app.message,
            .tag = app.tag,
            .cycle = app.cycle,
            .focused_sec = split.focused,
            .distracted_sec = split.distracted,
            .rows = rows,
        });
    }
}

/// A countdown (work or break) reached zero.
fn onCountdownDone(hwnd: w32.HWND) void {
    switch (app.kind) {
        .work => {
            endWorkSession();
            if (app.cycle < app.cycles_total) {
                playWav(app.chime_wav);
                if (app.break_secs > 0) {
                    startBreak();
                } else {
                    startWork(app.cycle + 1);
                }
            } else {
                finishAll(hwnd);
            }
        },
        .brk => {
            playWav(app.break_chime_wav);
            startWork(app.cycle + 1);
        },
    }
    _ = w32.InvalidateRect(hwnd, null, 0);
}

fn putLine(lines: [][:0]const u16, idx: *usize, text: []const u8) !void {
    lines[idx.*] = try std.unicode.utf8ToUtf16LeAllocZ(app.alloc, text);
    idx.* += 1;
}

/// Builds the end-of-run report from the aggregate of ALL work
/// sessions, listing each session individually when there were cycles.
fn buildReport() !void {
    const alloc = app.alloc;
    const entries = try app.total_tracker.sortedEntries(alloc);
    const scored = app.allow.len > 0;
    const list_sessions = app.summary_count > 1;

    var line_count: usize = 2 + 1 + entries.len; // header, blank, usage header, entries
    if (scored) line_count += 1;
    if (list_sessions) line_count += app.summary_count + 2; // "Sessions:", rows, blank

    const lines = try alloc.alloc([:0]const u16, line_count);
    var idx: usize = 0;
    var buf: [640]u8 = undefined;
    var dur_buf: [64]u8 = undefined;

    var session_buf: [64]u8 = undefined;
    const completed: u64 = @max(app.summary_count, 1);
    const total_work = try fmtDur(&session_buf, app.work_secs * completed);
    if (app.summary_count > 1) {
        try putLine(lines, &idx, try std.fmt.bufPrint(&buf, "{s}  ({d} sessions, {s} work)", .{
            app.message, app.summary_count, total_work,
        }));
    } else {
        try putLine(lines, &idx, try std.fmt.bufPrint(&buf, "{s}  (session: {s})", .{
            app.message, total_work,
        }));
    }
    try putLine(lines, &idx, "");

    if (scored) {
        const split = splitFocus(entries);
        const tracked = split.focused + split.distracted;
        const pct = if (tracked > 0) split.focused * 100 / tracked else 0;
        var fbuf: [64]u8 = undefined;
        var dbuf: [64]u8 = undefined;
        const fs = try fmtDur(&fbuf, split.focused);
        const ds = try fmtDur(&dbuf, split.distracted);
        try putLine(lines, &idx, try std.fmt.bufPrint(
            &buf,
            "Focus score: {d}%  (focused {s} / distracted {s})",
            .{ pct, fs, ds },
        ));
    }

    if (list_sessions) {
        try putLine(lines, &idx, "Sessions:");
        for (app.summaries[0..app.summary_count], 1..) |s, n| {
            const started = s.start_buf[0..s.start_len];
            if (scored) {
                const tracked = s.focused + s.distracted;
                const pct = if (tracked > 0) s.focused * 100 / tracked else 0;
                try putLine(lines, &idx, try std.fmt.bufPrint(&buf, "  {d})  {s}   focus {d}%", .{ n, started, pct }));
            } else {
                try putLine(lines, &idx, try std.fmt.bufPrint(&buf, "  {d})  {s}", .{ n, started }));
            }
        }
        try putLine(lines, &idx, "");
    }

    const usage_header: []const u8 = if (scored)
        "Foreground app usage, all sessions (+ = allowed):"
    else
        "Foreground app usage, all sessions:";
    try putLine(lines, &idx, usage_header);

    for (entries) |e| {
        const dur = try fmtDur(&dur_buf, e.seconds);
        const mark: []const u8 = if (scored and isAllowed(e.name)) "+" else " ";
        try putLine(lines, &idx, try std.fmt.bufPrint(&buf, "{s:>11} {s} {s}", .{ dur, mark, e.name }));
    }
    app.report_lines = lines[0..idx];
    app.report_scroll = 0;

    // Mirror the report to the console for terminal users.
    std.debug.print("\n=== sowon: {s} ({d} session(s), {s} work) ===\n", .{
        app.message, completed, total_work,
    });
    for (entries) |e| {
        const dur = fmtDur(&dur_buf, e.seconds) catch continue;
        const mark: []const u8 = if (scored and isAllowed(e.name)) "+" else " ";
        std.debug.print("{s:>11} {s} {s}\n", .{ dur, mark, e.name });
    }
}

/// Final work session done: chime, toast, report view, custom message.
fn finishAll(hwnd: w32.HWND) void {
    app.phase = .finished;
    playWav(app.chime_wav);
    trayToast(hwnd, app.message);
    buildReport() catch |err| {
        std.debug.print("failed to build usage report: {}\n", .{err});
    };

    // Bring the report to the user even if the window was minimized to
    // the tray while the timer ran.
    _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
    _ = w32.SetForegroundWindow(hwnd);

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

    var cycle_buf: [24]u8 = undefined;
    var cycle_part: []const u8 = "";
    if (app.mode == .timer and app.cycles_total > 1) {
        const kind_tag: []const u8 = if (app.kind == .brk) " break" else "";
        cycle_part = std.fmt.bufPrint(&cycle_buf, "[{d}/{d}{s}] ", .{
            app.cycle, app.cycles_total, kind_tag,
        }) catch "";
    } else if (app.mode == .timer and app.kind == .brk) {
        cycle_part = "[break] ";
    }

    var buf: [96]u8 = undefined;
    const suffix = if (app.phase == .paused) " (paused)" else "";
    const title = std.fmt.bufPrint(
        &buf,
        "{s}{d:0>2}:{d:0>2}:{d:0>2}{s} - sowon",
        .{ cycle_part, hms[0], hms[1], hms[2], suffix },
    ) catch return;

    var wbuf: [96]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], title) catch return;
    wbuf[n] = 0;
    _ = w32.SetWindowTextW(hwnd, wbuf[0..n :0]);
}

// --- Rendering --------------------------------------------------------
// main.zig only decides WHAT to show; the backend selected at build
// time (-Drenderer=...) decides HOW to draw it.

/// Describes the current frame for the renderer.
fn currentView() frame.View {
    if (app.phase == .finished) {
        return .{ .report = .{
            .lines = app.report_lines,
            .scroll = &app.report_scroll,
        } };
    }

    const hms = displayedHms();
    // Same per-position wiggle phases as the original renderer.
    const wiggle_offsets = [frame.chars_count]u8{ 0, 1, 0, 2, 3, 1, 4, 5 };
    const wiggle_index: u32 = @intCast(@mod(@divTrunc(nowMs(), wiggle_period_ms), digits.wiggle_count));

    var rows: [frame.chars_count]u8 = undefined;
    for (wiggle_offsets, 0..) |offset, i| {
        rows[i] = @intCast((wiggle_index + offset) % digits.wiggle_count);
    }

    const tint: frame.Tint = if (app.phase == .paused)
        .paused
    else if (app.mode == .timer and app.kind == .brk)
        .brk
    else
        .normal;

    return .{ .clock = .{
        .columns = .{
            @intCast(hms[0] / 10), @intCast(hms[0] % 10), digits.colon_column,
            @intCast(hms[1] / 10), @intCast(hms[1] % 10), digits.colon_column,
            @intCast(hms[2] / 10), @intCast(hms[2] % 10),
        },
        .rows = rows,
        .tint = tint,
    } };
}

/// Clamps and applies a scroll request against the current window size.
fn scrollReport(hwnd: w32.HWND, delta_lines: i32) void {
    if (app.phase != .finished) return;

    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    const visible = renderer.reportVisibleLines(rc.bottom - rc.top);
    const total: i32 = @intCast(app.report_lines.len);
    const max_scroll = @max(total - visible, 0);

    app.report_scroll = std.math.clamp(app.report_scroll +| delta_lines, 0, max_scroll);
    _ = w32.InvalidateRect(hwnd, null, 0);
}

// --- Window proc & main -----------------------------------------------

fn wndProc(hwnd: w32.HWND, msg: w32.UINT, wparam: w32.WPARAM, lparam: w32.LPARAM) callconv(.winapi) w32.LRESULT {
    switch (msg) {
        w32.WM_PAINT => {
            renderer.paint(hwnd, currentView());
            return 0;
        },
        w32.WM_ERASEBKGND => return 1, // memory bitmap covers everything
        w32.WM_TIMER => {
            switch (wparam) {
                timer_id_tick => {
                    if (app.mode == .timer and app.phase == .running and nowMs() >= app.end_ms) {
                        onCountdownDone(hwnd);
                    }
                    if (app.phase != .finished) updateTitle(hwnd);
                    _ = w32.InvalidateRect(hwnd, null, 0);
                },
                timer_id_track => {
                    // Only work time counts; breaks and pauses don't.
                    if (app.phase == .running and app.kind == .work) {
                        // Away from the keyboard/mouse? Credit idle time
                        // instead of whatever window happens to be focused.
                        const idle = idleSeconds() >= idle_threshold_secs;
                        const name: ?[]const u8 = if (idle)
                            (app.tracker.add(idle_key, sample_interval_secs) catch null)
                        else
                            (app.tracker.sample(sample_interval_secs) catch null);

                        // Nudge only for real, non-idle distraction.
                        if (!idle and app.nudge_threshold > 0 and app.allow.len > 0 and
                            name != null and !isAllowed(name.?))
                        {
                            app.nudge_run += sample_interval_secs;
                            if (app.nudge_run >= app.nudge_threshold) {
                                app.nudge_run = 0; // re-nudge after another run
                                nudge(hwnd);
                            }
                        } else {
                            app.nudge_run = 0;
                        }
                    }
                },
                else => {},
            }
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            // High word of wparam: wheel delta in multiples of 120.
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            scrollReport(hwnd, @divTrunc(-@as(i32, delta), 120) * 3);
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
                w32.VK_UP => scrollReport(hwnd, -1),
                w32.VK_DOWN => scrollReport(hwnd, 1),
                w32.VK_PRIOR => scrollReport(hwnd, -10),
                w32.VK_NEXT => scrollReport(hwnd, 10),
                w32.VK_HOME => scrollReport(hwnd, std.math.minInt(i32) + 1),
                w32.VK_END => scrollReport(hwnd, std.math.maxInt(i32) - 1),
                w32.VK_F5 => {
                    // Restart from cycle 1, like the original's re-parse.
                    if (app.mode == .timer) {
                        app.total_tracker = Tracker.init(app.alloc);
                        app.summary_count = 0;
                        startWork(1);
                        _ = w32.InvalidateRect(hwnd, null, 0);
                    }
                },
                w32.VK_ESCAPE => _ = w32.DestroyWindow(hwnd),
                else => {},
            }
            return 0;
        },
        w32.WM_SIZE => {
            // Minimize hides to the tray; the tray icon brings it back.
            if (wparam == w32.SIZE_MINIMIZED) {
                _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
            }
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        wm_tray => {
            if (lparam == w32.WM_LBUTTONUP) {
                _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                _ = w32.SetForegroundWindow(hwnd);
            }
            return 0;
        },
        w32.WM_DESTROY => {
            trayRemove(hwnd);
            w32.PostQuitMessage(0);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Writes report/history output to real stdout (so it can be piped or
/// redirected), not stderr.
fn writeStdout(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

/// `sowon history [N]` — print recent sessions and exit.
fn runHistory(alloc: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) void {
    var limit: u32 = 15;
    if (args.len >= 3) limit = std.fmt.parseInt(u32, args[2], 10) catch usageAndExit();
    var d = db.Db.open() orelse return;
    var aw = std.Io.Writer.Allocating.init(alloc);
    d.printHistory(&aw.writer, limit);
    writeStdout(io, aw.written());
}

/// `sowon report today|week [-t tag]` — print aggregates and exit.
fn runReport(alloc: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) void {
    var range: db.Db.Range = .today;
    var tag: []const u8 = "";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "today")) {
            range = .today;
        } else if (std.mem.eql(u8, args[i], "week")) {
            range = .week;
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--tag")) {
            i += 1;
            if (i >= args.len) usageAndExit();
            tag = args[i];
        } else {
            usageAndExit();
        }
    }
    var d = db.Db.open() orelse return;
    var aw = std.Io.Writer.Allocating.init(alloc);
    d.printReport(&aw.writer, range, tag);
    writeStdout(io, aw.written());
}

/// `sowon allow list|add|remove [pattern]` — manage the saved allow list.
fn runAllow(alloc: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) void {
    if (args.len < 3) usageAndExit();
    var d = db.Db.open() orelse return;
    const sub = args[2];
    if (std.mem.eql(u8, sub, "list")) {
        var aw = std.Io.Writer.Allocating.init(alloc);
        d.printAllow(&aw.writer);
        writeStdout(io, aw.written());
    } else if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 4) usageAndExit();
        d.allowAdd(args[3]);
        writeStdout(io, "added\n");
    } else if (std.mem.eql(u8, sub, "remove")) {
        if (args.len < 4) usageAndExit();
        d.allowRemove(args[3]);
        writeStdout(io, "removed\n");
    } else {
        usageAndExit();
    }
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "history")) return runHistory(alloc, io, args);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "report")) return runReport(alloc, io, args);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "allow")) return runAllow(alloc, io, args);

    const cfg = parseArgs(alloc, args);

    app = .{
        .alloc = alloc,
        .mode = cfg.mode,
        .phase = .running,
        .cycles_total = cfg.repeats,
        .work_secs = cfg.seconds,
        .break_secs = cfg.break_seconds,
        .total_ms = 0,
        .end_ms = 0,
        .remaining_ms = 0,
        .tracker = Tracker.init(alloc),
        .total_tracker = Tracker.init(alloc),
        .summaries = try alloc.alloc(SessionSummary, cfg.repeats),
        .chime_wav = try chime.buildWav(alloc),
        .break_chime_wav = try chime.buildBreakWav(alloc),
        .nudge_wav = try chime.buildNudgeWav(alloc),
        .message = cfg.message,
        .tag = cfg.tag,
        .allow = cfg.allow,
        .nudge_threshold = cfg.nudge_seconds,
    };

    try renderer.init();

    if (cfg.mode == .timer) {
        app.history = db.Db.open();
        if (app.history) |*h| {
            // CLI -a patterns are saved, then the effective allow list
            // is the full persisted set (CLI + previously saved).
            for (cfg.allow) |p| h.allowAdd(p);
            app.allow = h.loadAllow(alloc);
        }
        server.start();
        startWork(1);
    }

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
        if (cfg.topmost) w32.WS_EX_TOPMOST else 0,
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
    trayAdd(hwnd);

    if (w32.SetTimer(hwnd, timer_id_tick, 100, null) == 0) return error.SetTimerFailed;
    if (app.mode == .timer) {
        const interval_ms: w32.UINT = @intCast(sample_interval_secs * 1000);
        if (w32.SetTimer(hwnd, timer_id_track, interval_ms, null) == 0) return error.SetTimerFailed;
    }

    var msg: w32.MSG = undefined;
    while (w32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}
