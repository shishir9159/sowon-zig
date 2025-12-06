const std = @import("std");
const w32 = @import("win32.zig");
const util = @import("util.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const Writer = std.Io.Writer;

const Sqlite3 = opaque {};
const Stmt = opaque {};

const sqlite_ok = 0;
const sqlite_row = 100;
const sqlite_done = 101;
const transient: *anyopaque = @ptrFromInt(std.math.maxInt(usize));

const Api = struct {
    open: *const fn ([*:0]const u8, *?*Sqlite3) callconv(.c) c_int,
    exec: *const fn (?*Sqlite3, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*?[*:0]u8) callconv(.c) c_int,
    prepare_v2: *const fn (?*Sqlite3, [*]const u8, c_int, *?*Stmt, ?*?[*]const u8) callconv(.c) c_int,
    bind_text: *const fn (?*Stmt, c_int, [*]const u8, c_int, ?*anyopaque) callconv(.c) c_int,
    bind_int64: *const fn (?*Stmt, c_int, i64) callconv(.c) c_int,
    step: *const fn (?*Stmt) callconv(.c) c_int,
    finalize: *const fn (?*Stmt) callconv(.c) c_int,
    last_insert_rowid: *const fn (?*Sqlite3) callconv(.c) i64,
    column_text: *const fn (?*Stmt, c_int) callconv(.c) ?[*:0]const u8,
    column_int64: *const fn (?*Stmt, c_int) callconv(.c) i64,
};

pub const UsageRow = struct { app: []const u8, seconds: u64, allowed: bool };

pub const Session = struct {
    started_at: []const u8,
    duration_sec: u64,
    elapsed_sec: u64,
    message: []const u8,
    tag: []const u8,
    cycle: u32,
    focused_sec: u64,
    distracted_sec: u64,
    rows: []const UsageRow,
};

pub const Db = struct {
    api: Api,
    handle: *Sqlite3,

    pub const Range = enum { today, week };

    pub fn open() ?Db {
        const api = loadApi() orelse {
            std.debug.print("sowon: winsqlite3.dll not available; session history disabled\n", .{});
            return null;
        };

        var dir16: [600]u16 = undefined;
        const base_len = w32.GetEnvironmentVariableW(L("LOCALAPPDATA"), &dir16, 512);
        if (base_len == 0 or base_len >= 512) return null;
        const suffix = L("\\sowon");
        const dir_len = base_len + suffix.len;
        @memcpy(dir16[base_len..dir_len], suffix);
        dir16[dir_len] = 0;
        _ = w32.CreateDirectoryW(dir16[0..dir_len :0], null);

        var dir8: [1200]u8 = undefined;
        const dir8_len = std.unicode.utf16LeToUtf8(&dir8, dir16[0..dir_len]) catch return null;
        var path_buf: [1300]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}\\sowon.db", .{dir8[0..dir8_len]}) catch return null;

        var handle: ?*Sqlite3 = null;
        if (api.open(path.ptr, &handle) != sqlite_ok or handle == null) {
            std.debug.print("sowon: could not open {s}; session history disabled\n", .{path});
            return null;
        }

        var db = Db{ .api = api, .handle = handle.? };
        db.exec(
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  started_at TEXT NOT NULL,
            \\  duration_sec INTEGER NOT NULL,
            \\  elapsed_sec INTEGER NOT NULL DEFAULT 0,
            \\  message TEXT NOT NULL,
            \\  cycle INTEGER NOT NULL,
            \\  focused_sec INTEGER NOT NULL,
            \\  distracted_sec INTEGER NOT NULL,
            \\  tag TEXT NOT NULL DEFAULT ''
            \\);
            \\CREATE TABLE IF NOT EXISTS app_usage (
            \\  session_id INTEGER NOT NULL REFERENCES sessions(id),
            \\  app TEXT NOT NULL,
            \\  seconds INTEGER NOT NULL,
            \\  allowed INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS allow_list (
            \\  pattern TEXT PRIMARY KEY
            \\);
        );
        for ([_][*:0]const u8{
            "ALTER TABLE sessions ADD COLUMN tag TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE sessions ADD COLUMN elapsed_sec INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE sessions DROP COLUMN kind",
        }) |sql| _ = api.exec(db.handle, sql, null, null, null);
        return db;
    }

    pub fn recordSession(self: *Db, s: Session) void {
        self.exec("BEGIN");
        if (!self.run(
            "INSERT INTO sessions (started_at, duration_sec, elapsed_sec, message, cycle, focused_sec, distracted_sec, tag)" ++
                " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            .{ s.started_at, s.duration_sec, s.elapsed_sec, s.message, s.cycle, s.focused_sec, s.distracted_sec, s.tag },
        )) {
            std.debug.print("sowon: failed to record session\n", .{});
            return self.exec("ROLLBACK");
        }
        const id = self.api.last_insert_rowid(self.handle);
        for (s.rows) |row| {
            _ = self.run("INSERT INTO app_usage (session_id, app, seconds, allowed) VALUES (?1, ?2, ?3, ?4)", .{ id, row.app, row.seconds, row.allowed });
        }
        self.exec("COMMIT");
    }

    pub fn allowAdd(self: *Db, pattern: []const u8) void {
        _ = self.run("INSERT OR IGNORE INTO allow_list (pattern) VALUES (?1)", .{pattern});
    }

    pub fn allowRemove(self: *Db, pattern: []const u8) void {
        _ = self.run("DELETE FROM allow_list WHERE pattern = ?1 COLLATE NOCASE", .{pattern});
    }

    pub fn loadAllow(self: *Db, alloc: std.mem.Allocator) []const []const u8 {
        var list = std.ArrayList([]const u8).empty;
        const stmt = self.query("SELECT pattern FROM allow_list ORDER BY pattern", .{}) orelse return &.{};
        defer _ = self.api.finalize(stmt);
        while (self.api.step(stmt) == sqlite_row) {
            list.append(alloc, alloc.dupe(u8, self.text(stmt, 0)) catch continue) catch continue;
        }
        return list.toOwnedSlice(alloc) catch &.{};
    }

    pub fn printHistory(self: *Db, w: *Writer, limit: u32) Writer.Error!void {
        const stmt = self.query(
            "SELECT started_at, duration_sec, elapsed_sec, tag, message, focused_sec, distracted_sec FROM sessions ORDER BY id DESC LIMIT ?1",
            .{limit},
        ) orelse return;
        defer _ = self.api.finalize(stmt);

        const row_fmt = "{s:<19}  {s:>9}  {s:>9}  {s:>5}  {s:<12}  {s}\n";
        try w.print(row_fmt, .{ "started", "active", "elapsed", "focus", "tag", "message" });
        var b: [3][64]u8 = undefined;
        while (self.api.step(stmt) == sqlite_row) {
            const active = self.int(stmt, 1);
            const elapsed = self.int(stmt, 2);
            const pct: []const u8 = if (util.focusPct(self.int(stmt, 5), self.int(stmt, 6))) |p|
                std.fmt.bufPrint(&b[2], "{d}%", .{p}) catch "-"
            else
                "-";
            try w.print(row_fmt, .{
                self.text(stmt, 0),
                dur(&b[0], active),
                dur(&b[1], if (elapsed > 0) elapsed else active),
                pct,
                self.text(stmt, 3),
                self.text(stmt, 4),
            });
        }
    }

    pub fn printReport(self: *Db, w: *Writer, range: Range, tag: []const u8) Writer.Error!void {
        var st: w32.SYSTEMTIME = undefined;
        w32.GetLocalTime(&st);
        var today_buf: [16]u8 = undefined;
        const today = std.fmt.bufPrint(&today_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ st.wYear, st.wMonth, st.wDay }) catch return;
        const modifier: []const u8 = if (range == .today) "+0 days" else "-6 days";
        const label: []const u8 = if (range == .today) "today" else "last 7 days";
        const filter = " WHERE started_at >= date(?1,?2) AND (?3 = '' OR tag = ?3)";
        const args = .{ today, modifier, tag };
        var b: [4][64]u8 = undefined;

        {
            const stmt = self.query(
                "SELECT COUNT(*), COALESCE(SUM(duration_sec),0), COALESCE(SUM(focused_sec),0)," ++
                    " COALESCE(SUM(distracted_sec),0), COALESCE(SUM(elapsed_sec),0) FROM sessions" ++ filter,
                args,
            ) orelse return;
            defer _ = self.api.finalize(stmt);
            if (self.api.step(stmt) != sqlite_row) return;

            const total = self.int(stmt, 1);
            const focused = self.int(stmt, 2);
            const distracted = self.int(stmt, 3);
            const elapsed = self.int(stmt, 4);
            try w.print("=== sowon report: {s}", .{label});
            if (tag.len > 0) try w.print(", tag [{s}]", .{tag});
            try w.print(" ===\nsessions: {d}   active work: {s}   elapsed: {s}\n", .{
                self.int(stmt, 0), dur(&b[0], total), dur(&b[1], if (elapsed > 0) elapsed else total),
            });
            if (util.focusPct(focused, distracted)) |p| {
                try w.print("focus score: {d}%  (focused {s} / distracted {s})\n", .{ p, dur(&b[2], focused), dur(&b[3], distracted) });
            }
        }

        try w.writeAll("\ntop apps:\n");
        const stmt = self.query(
            "SELECT app, SUM(seconds) AS s, MAX(allowed) FROM app_usage JOIN sessions ON sessions.id = app_usage.session_id" ++
                filter ++ " GROUP BY app ORDER BY s DESC LIMIT 20",
            args,
        ) orelse return;
        defer _ = self.api.finalize(stmt);
        while (self.api.step(stmt) == sqlite_row) {
            const mark: []const u8 = if (self.int(stmt, 2) != 0) "+" else " ";
            try w.print("{s:>11} {s} {s}\n", .{ dur(&b[0], self.int(stmt, 1)), mark, self.text(stmt, 0) });
        }
    }

    fn text(self: *Db, stmt: *Stmt, col: c_int) []const u8 {
        return std.mem.span(self.api.column_text(stmt, col) orelse return "");
    }

    fn int(self: *Db, stmt: *Stmt, col: c_int) u64 {
        return @intCast(self.api.column_int64(stmt, col));
    }

    fn query(self: *Db, sql: []const u8, args: anytype) ?*Stmt {
        var stmt: ?*Stmt = null;
        if (self.api.prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != sqlite_ok) return null;
        inline for (args, 1..) |arg, i| {
            switch (@typeInfo(@TypeOf(arg))) {
                .int, .comptime_int => _ = self.api.bind_int64(stmt, i, @intCast(arg)),
                .bool => _ = self.api.bind_int64(stmt, i, @intFromBool(arg)),
                else => {
                    const s: []const u8 = arg;
                    _ = self.api.bind_text(stmt, i, s.ptr, @intCast(s.len), transient);
                },
            }
        }
        return stmt;
    }

    fn run(self: *Db, sql: []const u8, args: anytype) bool {
        const stmt = self.query(sql, args) orelse return false;
        defer _ = self.api.finalize(stmt);
        return self.api.step(stmt) == sqlite_done;
    }

    fn exec(self: *Db, sql: [*:0]const u8) void {
        var err: ?[*:0]u8 = null;
        if (self.api.exec(self.handle, sql, null, null, &err) != sqlite_ok) {
            if (err) |m| std.debug.print("sowon: sqlite error: {s}\n", .{m});
        }
    }
};

fn dur(buf: *[64]u8, secs: u64) []const u8 {
    return util.fmtDur(buf, secs) catch "?";
}

fn loadApi() ?Api {
    const lib = w32.LoadLibraryW(L("winsqlite3.dll")) orelse return null;
    var api: Api = undefined;
    inline for (@typeInfo(Api).@"struct".fields) |f| {
        const proc = w32.GetProcAddress(lib, "sqlite3_" ++ f.name) orelse return null;
        @field(api, f.name) = @ptrCast(@alignCast(proc));
    }
    return api;
}
