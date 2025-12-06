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
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const renderer = switch (build_options.renderer) {
    .gdi => @import("render/gdi.zig"),
    .spirv => @import("render/spirv.zig"),
    else => |r| @compileError("the '" ++ @tagName(r) ++ "' renderer is not implemented yet; build with -Drenderer=gdi (default)"),
};

const idle_key = "(idle)";
const idle_threshold_secs: u64 = 120;
const max_display_secs = 99 * 3600 + 59 * 60 + 59;
const wiggle_period_ms = 133;
const timer_id_tick: usize = 1;
const timer_id_track: usize = 2;
const sample_interval_secs: u64 = @max(build_options.sample_interval_secs, 1);
const wm_tray: w32.UINT = w32.WM_APP + 1;

const Mode = enum { clock, timer };
const Phase = enum { running, paused, finished };
const Kind = enum { work, brk };
const FocusSplit = struct { focused: u64 = 0, distracted: u64 = 0 };
const SessionSummary = struct { started: []const u8, split: FocusSplit };

const App = struct {
    alloc: std.mem.Allocator,
    mode: Mode,
    phase: Phase = .running,
    kind: Kind = .work,
    cycle: u32 = 1,
    cycles_total: u32,
    work_secs: u64,
    break_secs: u64,
    total_ms: i64 = 0,
    end_ms: i64 = 0,
    remaining_ms: i64 = 0,
    tracker: Tracker,
    total_tracker: Tracker,
    summaries: std.ArrayList(SessionSummary) = .empty,
    chime_wav: []u8,
    break_chime_wav: []u8,
    nudge_wav: []u8,
    message: []const u8,
    tag: []const u8,
    allow: []const []const u8,
    nudge_threshold: u64,
    nudge_run: u64 = 0,
    history: ?db.Db = null,
    session_start: []const u8 = "",
    session_start_ms: i64 = 0,
    report_lines: []const [:0]const u16 = &.{},
    report_scroll: i32 = 0,
    last_title_sec: i64 = -1,
};

var app: App = undefined;

fn nowMs() i64 {
    return @intCast(w32.GetTickCount64());
}

fn localTimestamp(alloc: std.mem.Allocator) []const u8 {
    var st: w32.SYSTEMTIME = undefined;
    w32.GetLocalTime(&st);
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
    }) catch "";
}

const Config = struct {
    mode: Mode = .clock,
    seconds: u64 = 0,
    message: []const u8 = "Time's up!",
    tag: []const u8 = "",
    repeats: u32 = 1,
    break_seconds: u64 = 0,
    nudge_seconds: u64 = 0,
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

fn isFlag(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

fn parseArgs(alloc: std.mem.Allocator, args: []const [:0]const u8) Config {
    var cfg = Config{};
    var allow = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--top")) {
            cfg.topmost = true;
        } else if (std.mem.eql(u8, arg, "clock")) {
            cfg.mode = .clock;
        } else if (arg.len > 1 and arg[0] == '-') {
            i += 1;
            if (i >= args.len) usageAndExit();
            const val = args[i];
            if (isFlag(arg, "-m", "--message")) {
                cfg.message = val;
            } else if (isFlag(arg, "-t", "--tag")) {
                cfg.tag = val;
            } else if (isFlag(arg, "-n", "--nudge")) {
                cfg.nudge_seconds = parseDuration(val) catch usageAndExit();
            } else if (isFlag(arg, "-r", "--repeat")) {
                cfg.repeats = std.fmt.parseInt(u32, val, 10) catch usageAndExit();
                if (cfg.repeats < 1) usageAndExit();
            } else if (isFlag(arg, "-b", "--break")) {
                cfg.break_seconds = parseDuration(val) catch usageAndExit();
            } else if (isFlag(arg, "-a", "--allow")) {
                allow.append(alloc, val) catch usageAndExit();
            } else usageAndExit();
        } else {
            cfg.seconds = parseDuration(arg) catch usageAndExit();
            cfg.mode = .timer;
        }
    }
    cfg.allow = allow.items;
    return cfg;
}

fn isAllowed(name: []const u8) bool {
    return util.isAllowedIn(app.allow, name);
}

fn splitFocus(entries: []const Tracker.Entry) FocusSplit {
    var split = FocusSplit{};
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, idle_key)) continue;
        if (isAllowed(e.name)) split.focused += e.seconds else split.distracted += e.seconds;
    }
    return split;
}

fn idleSeconds() u64 {
    var info = w32.LASTINPUTINFO{ .cbSize = @sizeOf(w32.LASTINPUTINFO), .dwTime = 0 };
    if (w32.GetLastInputInfo(&info) == 0) return 0;
    const now32: u32 = @truncate(@as(u64, @bitCast(nowMs())));
    return (now32 -% info.dwTime) / 1000;
}

fn displayedHms() [3]u32 {
    if (app.mode == .clock) {
        var st: w32.SYSTEMTIME = undefined;
        w32.GetLocalTime(&st);
        return .{ st.wHour, st.wMinute, st.wSecond };
    }
    const rem_ms: i64 = switch (app.phase) {
        .running => app.end_ms - nowMs(),
        .paused => app.remaining_ms,
        .finished => 0,
    };
    const t: u32 = @intCast(@min(@divTrunc(@max(rem_ms, 0) + 999, 1000), max_display_secs));
    return .{ t / 3600, t / 60 % 60, t % 60 };
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

fn startCountdown(kind: Kind, secs: u64) void {
    app.kind = kind;
    app.total_ms = @intCast(secs * 1000);
    app.end_ms = nowMs() + app.total_ms;
    app.remaining_ms = app.total_ms;
    app.phase = .running;
    app.last_title_sec = -1;
}

fn startWork(cycle: u32) void {
    app.cycle = cycle;
    app.tracker = Tracker.init(app.alloc);
    app.report_lines = &.{};
    app.session_start = localTimestamp(app.alloc);
    app.session_start_ms = nowMs();
    startCountdown(.work, app.work_secs);
}

fn playWav(wav: []u8) void {
    _ = w32.PlaySoundW(wav.ptr, null, w32.SND_MEMORY | w32.SND_ASYNC | w32.SND_NODEFAULT);
}

fn copyUtf16z(dst: []u16, src: []const u8) void {
    const n = std.unicode.utf8ToUtf16Le(dst[0 .. dst.len - 1], src[0..@min(src.len, dst.len - 1)]) catch 0;
    dst[n] = 0;
}

fn setTitle(hwnd: w32.HWND, comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    var wbuf: [129]u16 = undefined;
    copyUtf16z(&wbuf, std.fmt.bufPrint(&buf, fmt, args) catch return);
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&wbuf));
}

fn tray(hwnd: w32.HWND, flags: w32.UINT) w32.NOTIFYICONDATAW {
    var nid = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = flags;
    return nid;
}

fn trayAdd(hwnd: w32.HWND) void {
    var nid = tray(hwnd, w32.NIF_MESSAGE | w32.NIF_ICON | w32.NIF_TIP);
    nid.uCallbackMessage = wm_tray;
    nid.hIcon = w32.LoadIconW(null, w32.makeIntResourceW(w32.IDI_APPLICATION));
    copyUtf16z(&nid.szTip, "sowon");
    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
}

fn trayRemove(hwnd: w32.HWND) void {
    var nid = tray(hwnd, 0);
    _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
}

fn trayToast(hwnd: w32.HWND, text: []const u8) void {
    var nid = tray(hwnd, w32.NIF_INFO);
    nid.dwInfoFlags = w32.NIIF_INFO;
    copyUtf16z(&nid.szInfoTitle, "sowon");
    copyUtf16z(&nid.szInfo, text);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);
}

fn nudge(hwnd: w32.HWND) void {
    _ = w32.FlashWindowEx(&.{ .cbSize = @sizeOf(w32.FLASHWINFO), .hwnd = hwnd, .dwFlags = w32.FLASHW_ALL, .uCount = 3, .dwTimeout = 0 });
    playWav(app.nudge_wav);
}

fn endWorkSession() void {
    const entries = app.tracker.sortedEntries(app.alloc) catch return;
    const split = splitFocus(entries);
    app.summaries.append(app.alloc, .{ .started = app.session_start, .split = split }) catch {};
    for (entries) |e| _ = app.total_tracker.add(e.name, e.seconds) catch {};

    const history = if (app.history) |*h| h else return;
    const rows = app.alloc.alloc(db.UsageRow, entries.len) catch return;
    for (entries, rows) |e, *row| row.* = .{ .app = e.name, .seconds = e.seconds, .allowed = isAllowed(e.name) };
    history.recordSession(.{
        .started_at = app.session_start,
        .duration_sec = app.work_secs,
        .elapsed_sec = @intCast(@divTrunc(@max(nowMs() - app.session_start_ms, 0) + 500, 1000)),
        .message = app.message,
        .tag = app.tag,
        .cycle = app.cycle,
        .focused_sec = split.focused,
        .distracted_sec = split.distracted,
        .rows = rows,
    });
}

fn onCountdownDone(hwnd: w32.HWND) void {
    switch (app.kind) {
        .work => {
            endWorkSession();
            if (app.cycle >= app.cycles_total) {
                finishAll(hwnd);
            } else {
                playWav(app.chime_wav);
                if (app.break_secs > 0) startCountdown(.brk, app.break_secs) else startWork(app.cycle + 1);
            }
        },
        .brk => {
            playWav(app.break_chime_wav);
            startWork(app.cycle + 1);
        },
    }
    _ = w32.InvalidateRect(hwnd, null, 0);
}

const Lines = std.ArrayList([:0]const u16);

fn put(lines: *Lines, comptime fmt: []const u8, args: anytype) !void {
    var buf: [640]u8 = undefined;
    try lines.append(app.alloc, try std.unicode.utf8ToUtf16LeAllocZ(app.alloc, try std.fmt.bufPrint(&buf, fmt, args)));
}

fn buildReport() !void {
    const entries = try app.total_tracker.sortedEntries(app.alloc);
    const scored = app.allow.len > 0;
    const sessions = app.summaries.items;
    var lines = Lines.empty;
    var b: [3][64]u8 = undefined;

    const completed: u64 = @max(sessions.len, 1);
    const total_work = try fmtDur(&b[0], app.work_secs * completed);
    if (sessions.len > 1) {
        try put(&lines, "{s}  ({d} sessions, {s} work)", .{ app.message, sessions.len, total_work });
    } else {
        try put(&lines, "{s}  (session: {s})", .{ app.message, total_work });
    }
    try put(&lines, "", .{});

    if (scored) {
        const split = splitFocus(entries);
        try put(&lines, "Focus score: {d}%  (focused {s} / distracted {s})", .{
            util.focusPct(split.focused, split.distracted) orelse 0, try fmtDur(&b[1], split.focused), try fmtDur(&b[2], split.distracted),
        });
    }

    if (sessions.len > 1) {
        try put(&lines, "Sessions:", .{});
        for (sessions, 1..) |s, n| {
            if (scored) {
                try put(&lines, "  {d})  {s}   focus {d}%", .{ n, s.started, util.focusPct(s.split.focused, s.split.distracted) orelse 0 });
            } else {
                try put(&lines, "  {d})  {s}", .{ n, s.started });
            }
        }
        try put(&lines, "", .{});
    }

    try put(&lines, "Foreground app usage, all sessions{s}:", .{if (scored) " (+ = allowed)" else ""});
    std.debug.print("\n=== sowon: {s} ({d} session(s), {s} work) ===\n", .{ app.message, completed, total_work });
    for (entries) |e| {
        const dur = try fmtDur(&b[1], e.seconds);
        const mark: []const u8 = if (scored and isAllowed(e.name)) "+" else " ";
        try put(&lines, "{s:>11} {s} {s}", .{ dur, mark, e.name });
        std.debug.print("{s:>11} {s} {s}\n", .{ dur, mark, e.name });
    }
    app.report_lines = lines.items;
    app.report_scroll = 0;
}

fn finishAll(hwnd: w32.HWND) void {
    app.phase = .finished;
    playWav(app.chime_wav);
    trayToast(hwnd, app.message);
    buildReport() catch |err| std.debug.print("failed to build usage report: {}\n", .{err});
    _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
    _ = w32.SetForegroundWindow(hwnd);
    setTitle(hwnd, "{s} - sowon", .{app.message[0..@min(app.message.len, 80)]});
    _ = w32.InvalidateRect(hwnd, null, 0);
}

fn updateTitle(hwnd: w32.HWND) void {
    const hms = displayedHms();
    const sec_stamp: i64 = hms[0] * 3600 + hms[1] * 60 + hms[2];
    if (sec_stamp == app.last_title_sec) return;
    app.last_title_sec = sec_stamp;

    var cycle_buf: [24]u8 = undefined;
    const brk = app.kind == .brk;
    const cycle: []const u8 = if (app.mode != .timer)
        ""
    else if (app.cycles_total > 1)
        std.fmt.bufPrint(&cycle_buf, "[{d}/{d}{s}] ", .{ app.cycle, app.cycles_total, if (brk) " break" else "" }) catch ""
    else if (brk) "[break] " else "";
    const suffix = if (app.phase == .paused) " (paused)" else "";
    setTitle(hwnd, "{s}{d:0>2}:{d:0>2}:{d:0>2}{s} - sowon", .{ cycle, hms[0], hms[1], hms[2], suffix });
}

fn currentView() frame.View {
    if (app.phase == .finished) return .{ .report = .{ .lines = app.report_lines, .scroll = &app.report_scroll } };

    const hms = displayedHms();
    const wiggle_offsets = [frame.chars_count]u8{ 0, 1, 0, 2, 3, 1, 4, 5 };
    const wiggle_index: u32 = @intCast(@mod(@divTrunc(nowMs(), wiggle_period_ms), digits.wiggle_count));
    var rows: [frame.chars_count]u8 = undefined;
    for (wiggle_offsets, &rows) |offset, *row| row.* = @intCast((wiggle_index + offset) % digits.wiggle_count);

    return .{ .clock = .{
        .columns = .{
            @intCast(hms[0] / 10), @intCast(hms[0] % 10), digits.colon_column,
            @intCast(hms[1] / 10), @intCast(hms[1] % 10), digits.colon_column,
            @intCast(hms[2] / 10), @intCast(hms[2] % 10),
        },
        .rows = rows,
        .tint = if (app.phase == .paused) .paused else if (app.mode == .timer and app.kind == .brk) .brk else .normal,
    } };
}

fn scrollReport(hwnd: w32.HWND, delta_lines: i32) void {
    if (app.phase != .finished) return;
    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    const max_scroll = @max(@as(i32, @intCast(app.report_lines.len)) - renderer.reportVisibleLines(rc.bottom - rc.top), 0);
    app.report_scroll = std.math.clamp(app.report_scroll +| delta_lines, 0, max_scroll);
    _ = w32.InvalidateRect(hwnd, null, 0);
}

fn onTrackTick(hwnd: w32.HWND) void {
    if (app.phase != .running or app.kind != .work) return;
    const idle = idleSeconds() >= idle_threshold_secs;
    const name = (if (idle) app.tracker.add(idle_key, sample_interval_secs) else app.tracker.sample(sample_interval_secs)) catch null;
    if (!idle and app.nudge_threshold > 0 and app.allow.len > 0 and name != null and !isAllowed(name.?)) {
        app.nudge_run += sample_interval_secs;
        if (app.nudge_run >= app.nudge_threshold) {
            app.nudge_run = 0;
            nudge(hwnd);
        }
    } else app.nudge_run = 0;
}

fn wndProc(hwnd: w32.HWND, msg: w32.UINT, wparam: w32.WPARAM, lparam: w32.LPARAM) callconv(.winapi) w32.LRESULT {
    switch (msg) {
        w32.WM_PAINT => renderer.paint(hwnd, currentView()),
        w32.WM_ERASEBKGND => return 1,
        w32.WM_TIMER => switch (wparam) {
            timer_id_tick => {
                if (app.mode == .timer and app.phase == .running and nowMs() >= app.end_ms) onCountdownDone(hwnd);
                if (app.phase != .finished) updateTitle(hwnd);
                _ = w32.InvalidateRect(hwnd, null, 0);
            },
            timer_id_track => onTrackTick(hwnd),
            else => {},
        },
        w32.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            scrollReport(hwnd, @divTrunc(-@as(i32, delta), 120) * 3);
        },
        w32.WM_KEYDOWN => switch (wparam) {
            w32.VK_SPACE => if (app.mode == .timer) {
                togglePause();
                app.last_title_sec = -1;
                _ = w32.InvalidateRect(hwnd, null, 0);
            },
            w32.VK_UP => scrollReport(hwnd, -1),
            w32.VK_DOWN => scrollReport(hwnd, 1),
            w32.VK_PRIOR => scrollReport(hwnd, -10),
            w32.VK_NEXT => scrollReport(hwnd, 10),
            w32.VK_HOME => scrollReport(hwnd, std.math.minInt(i32) + 1),
            w32.VK_END => scrollReport(hwnd, std.math.maxInt(i32) - 1),
            w32.VK_F5 => if (app.mode == .timer) {
                app.total_tracker = Tracker.init(app.alloc);
                app.summaries.clearRetainingCapacity();
                startWork(1);
                _ = w32.InvalidateRect(hwnd, null, 0);
            },
            w32.VK_ESCAPE => _ = w32.DestroyWindow(hwnd),
            else => {},
        },
        w32.WM_SIZE => {
            if (wparam == w32.SIZE_MINIMIZED) _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
            _ = w32.InvalidateRect(hwnd, null, 0);
        },
        wm_tray => if (lparam == w32.WM_LBUTTONUP) {
            _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
            _ = w32.SetForegroundWindow(hwnd);
        },
        w32.WM_DESTROY => {
            trayRemove(hwnd);
            w32.PostQuitMessage(0);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

fn runCommand(alloc: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !bool {
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;
    const cmd = std.meta.stringToEnum(enum { history, report, allow }, args[1]) orelse return false;
    switch (cmd) {
        .history => {
            const limit = if (args.len >= 3) (std.fmt.parseInt(u32, args[2], 10) catch usageAndExit()) else 15;
            var d = db.Db.open() orelse return true;
            try d.printHistory(w, limit);
        },
        .report => {
            var range: db.Db.Range = .today;
            var tag: []const u8 = "";
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.meta.stringToEnum(db.Db.Range, args[i])) |r| {
                    range = r;
                } else if (isFlag(args[i], "-t", "--tag") and i + 1 < args.len) {
                    i += 1;
                    tag = args[i];
                } else usageAndExit();
            }
            var d = db.Db.open() orelse return true;
            try d.printReport(w, range, tag);
        },
        .allow => {
            if (args.len < 3) usageAndExit();
            const sub = std.meta.stringToEnum(enum { list, add, remove }, args[2]) orelse usageAndExit();
            if (sub != .list and args.len < 4) usageAndExit();
            var d = db.Db.open() orelse return true;
            switch (sub) {
                .list => {
                    const list = d.loadAllow(alloc);
                    for (list) |p| try w.print("  {s}\n", .{p});
                    if (list.len == 0) try w.writeAll("(allow list is empty)\n");
                },
                .add => {
                    d.allowAdd(args[3]);
                    try w.writeAll("added\n");
                },
                .remove => {
                    d.allowRemove(args[3]);
                    try w.writeAll("removed\n");
                },
            }
        },
    }
    std.Io.File.stdout().writeStreamingAll(io, aw.written()) catch {};
    return true;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len >= 2 and try runCommand(alloc, init.io, args)) return;

    const cfg = parseArgs(alloc, args);
    app = .{
        .alloc = alloc,
        .mode = cfg.mode,
        .cycles_total = cfg.repeats,
        .work_secs = cfg.seconds,
        .break_secs = cfg.break_seconds,
        .tracker = Tracker.init(alloc),
        .total_tracker = Tracker.init(alloc),
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

    const ex_style: w32.DWORD = if (cfg.topmost) w32.WS_EX_TOPMOST else 0;
    const hwnd = w32.CreateWindowExW(ex_style, class_name, L("sowon"), w32.WS_OVERLAPPEDWINDOW, w32.CW_USEDEFAULT, w32.CW_USEDEFAULT, 900, 280, null, null, instance, null) orelse
        return error.CreateWindowFailed;
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    trayAdd(hwnd);

    if (w32.SetTimer(hwnd, timer_id_tick, 100, null) == 0) return error.SetTimerFailed;
    if (app.mode == .timer and w32.SetTimer(hwnd, timer_id_track, @intCast(sample_interval_secs * 1000), null) == 0) return error.SetTimerFailed;

    var msg: w32.MSG = undefined;
    while (w32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}
