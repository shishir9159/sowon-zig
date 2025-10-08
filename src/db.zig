//! Session history stored in SQLite, using the copy Windows ships
//! (System32\winsqlite3.dll) loaded at runtime — no vendored C, no
//! import library. If the DLL or the database can't be opened, history
//! is silently disabled and the timer works as before.
//!
//! Database: %LOCALAPPDATA%\sowon\sowon.db
//!
//!   sessions(id, started_at, duration_sec, elapsed_sec, message,
//!            cycle, focused_sec, distracted_sec, tag)
//!   app_usage(session_id, app, seconds, allowed)
//!   allow_list(pattern)
//!
//! Report/history output is written to a caller-supplied std.Io.Writer
//! (so `sowon history`/`report` go to stdout); only diagnostics go to
//! stderr via std.debug.print.

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

// SQLITE_TRANSIENT: tells sqlite to copy bound text immediately.
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

pub const UsageRow = struct {
    app: []const u8,
    seconds: u64,
    allowed: bool,
};

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

    /// Opens (creating if needed) %LOCALAPPDATA%\sowon\sowon.db.
    pub fn open() ?Db {
        const api = loadApi() orelse {
            std.debug.print("sowon: winsqlite3.dll not available; session history disabled\n", .{});
            return null;
        };

        var dir16: [600]u16 = undefined;
        const base_len = w32.GetEnvironmentVariableW(L("LOCALAPPDATA"), &dir16, 512);
        if (base_len == 0 or base_len >= 512) return null;

        const suffix = L("\\sowon");
        @memcpy(dir16[base_len..][0..suffix.len], suffix);
        dir16[base_len + suffix.len] = 0;
        _ = w32.CreateDirectoryW(dir16[0 .. base_len + suffix.len :0], null); // ok if it exists

        // sqlite3_open wants UTF-8.
        var dir8: [1200]u8 = undefined;
        const dir8_len = std.unicode.utf16LeToUtf8(&dir8, dir16[0 .. base_len + suffix.len]) catch return null;
        var path8: [1300]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path8, "{s}\\sowon.db", .{dir8[0..dir8_len]}) catch return null;

        var handle: ?*Sqlite3 = null;
        if (api.open(path.ptr, &handle) != sqlite_ok or handle == null) {
            std.debug.print("sowon: could not open {s}; session history disabled\n", .{path});
            return null;
        }

        var db = Db{ .api = api, .handle = handle.? };
        db.execSimple(
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
        // Migrations for databases created by older builds. Each fails
        // harmlessly (duplicate column / no such column) when already
        // in the target shape.
        db.execSilent("ALTER TABLE sessions ADD COLUMN tag TEXT NOT NULL DEFAULT ''");
        db.execSilent("ALTER TABLE sessions ADD COLUMN elapsed_sec INTEGER NOT NULL DEFAULT 0");
        db.execSilent("ALTER TABLE sessions DROP COLUMN kind"); // always 'work'; dropped
        return db;
    }

    /// Records one finished work session with its per-app breakdown.
    /// Failures are logged and swallowed: history must never take the
    /// timer down.
    pub fn recordSession(self: *Db, s: Session) void {
        self.execSimple("BEGIN");

        var stmt = self.prepare(
            "INSERT INTO sessions (started_at, duration_sec, elapsed_sec, message, cycle, focused_sec, distracted_sec, tag)" ++
                " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        ) orelse {
            self.execSimple("ROLLBACK");
            return;
        };
        _ = self.api.bind_text(stmt, 1, s.started_at.ptr, @intCast(s.started_at.len), transient);
        _ = self.api.bind_int64(stmt, 2, @intCast(s.duration_sec));
        _ = self.api.bind_int64(stmt, 3, @intCast(s.elapsed_sec));
        _ = self.api.bind_text(stmt, 4, s.message.ptr, @intCast(s.message.len), transient);
        _ = self.api.bind_int64(stmt, 5, s.cycle);
        _ = self.api.bind_int64(stmt, 6, @intCast(s.focused_sec));
        _ = self.api.bind_int64(stmt, 7, @intCast(s.distracted_sec));
        _ = self.api.bind_text(stmt, 8, s.tag.ptr, @intCast(s.tag.len), transient);
        const session_ok = self.api.step(stmt) == sqlite_done;
        _ = self.api.finalize(stmt);
        if (!session_ok) {
            std.debug.print("sowon: failed to record session\n", .{});
            self.execSimple("ROLLBACK");
            return;
        }
        const session_id = self.api.last_insert_rowid(self.handle);

        for (s.rows) |row| {
            stmt = self.prepare(
                "INSERT INTO app_usage (session_id, app, seconds, allowed) VALUES (?1, ?2, ?3, ?4)",
            ) orelse continue;
            _ = self.api.bind_int64(stmt, 1, session_id);
            _ = self.api.bind_text(stmt, 2, row.app.ptr, @intCast(row.app.len), transient);
            _ = self.api.bind_int64(stmt, 3, @intCast(row.seconds));
            _ = self.api.bind_int64(stmt, 4, @intFromBool(row.allowed));
            _ = self.api.step(stmt);
            _ = self.api.finalize(stmt);
        }

        self.execSimple("COMMIT");
    }

    // --- Persisted allow list -----------------------------------------

    pub fn allowAdd(self: *Db, pattern: []const u8) void {
        const stmt = self.prepare("INSERT OR IGNORE INTO allow_list (pattern) VALUES (?1)") orelse return;
        defer _ = self.api.finalize(stmt);
        _ = self.api.bind_text(stmt, 1, pattern.ptr, @intCast(pattern.len), transient);
        _ = self.api.step(stmt);
    }

    pub fn allowRemove(self: *Db, pattern: []const u8) void {
        const stmt = self.prepare("DELETE FROM allow_list WHERE pattern = ?1 COLLATE NOCASE") orelse return;
        defer _ = self.api.finalize(stmt);
        _ = self.api.bind_text(stmt, 1, pattern.ptr, @intCast(pattern.len), transient);
        _ = self.api.step(stmt);
    }

    /// Loads the persisted allow list; caller owns the returned slice
    /// and its strings (allocated from `alloc`).
    pub fn loadAllow(self: *Db, alloc: std.mem.Allocator) []const []const u8 {
        var list = std.ArrayList([]const u8).empty;
        const stmt = self.prepare("SELECT pattern FROM allow_list ORDER BY pattern") orelse return &.{};
        defer _ = self.api.finalize(stmt);
        while (self.api.step(stmt) == sqlite_row) {
            const p = alloc.dupe(u8, self.columnText(stmt, 0)) catch continue;
            list.append(alloc, p) catch continue;
        }
        return list.toOwnedSlice(alloc) catch &.{};
    }

    pub fn printAllow(self: *Db, w: *Writer) void {
        const stmt = self.prepare("SELECT pattern FROM allow_list ORDER BY pattern") orelse return;
        defer _ = self.api.finalize(stmt);
        var any = false;
        while (self.api.step(stmt) == sqlite_row) {
            w.print("  {s}\n", .{self.columnText(stmt, 0)}) catch return;
            any = true;
        }
        if (!any) w.print("(allow list is empty)\n", .{}) catch return;
    }

    // --- Reports -------------------------------------------------------

    /// `sowon history [N]`: the N most recent sessions, newest first.
    pub fn printHistory(self: *Db, w: *Writer, limit: u32) void {
        const stmt = self.prepare(
            "SELECT started_at, duration_sec, elapsed_sec, tag, message, focused_sec, distracted_sec" ++
                " FROM sessions ORDER BY id DESC LIMIT ?1",
        ) orelse return;
        defer _ = self.api.finalize(stmt);
        _ = self.api.bind_int64(stmt, 1, limit);

        w.print("{s:<19}  {s:>9}  {s:>9}  {s:>5}  {s:<12}  {s}\n", .{
            "started", "active", "elapsed", "focus", "tag", "message",
        }) catch return;

        var dur_buf: [64]u8 = undefined;
        var el_buf: [64]u8 = undefined;
        while (self.api.step(stmt) == sqlite_row) {
            const started = self.columnText(stmt, 0);
            const dur = util.fmtDur(&dur_buf, @intCast(self.api.column_int64(stmt, 1))) catch "?";
            const elapsed_raw: u64 = @intCast(self.api.column_int64(stmt, 2));
            // Older rows predate elapsed tracking (stored 0): fall back
            // to the active duration so the column is never blank.
            const elapsed = util.fmtDur(&el_buf, if (elapsed_raw > 0) elapsed_raw else @intCast(self.api.column_int64(stmt, 1))) catch "?";
            const tag = self.columnText(stmt, 3);
            const message = self.columnText(stmt, 4);
            const focused: u64 = @intCast(self.api.column_int64(stmt, 5));
            const distracted: u64 = @intCast(self.api.column_int64(stmt, 6));

            var pct_buf: [8]u8 = undefined;
            const tracked = focused + distracted;
            const pct: []const u8 = if (tracked > 0)
                std.fmt.bufPrint(&pct_buf, "{d}%", .{focused * 100 / tracked}) catch "-"
            else
                "-";
            w.print("{s:<19}  {s:>9}  {s:>9}  {s:>5}  {s:<12}  {s}\n", .{
                started, dur, elapsed, pct, tag, message,
            }) catch return;
        }
    }

    pub const Range = enum { today, week };

    /// `sowon report today|week [-t tag]`: aggregate totals plus the
    /// top apps for the period.
    ///
    /// The local "today" anchor is computed here with GetLocalTime and
    /// passed into SQL, because winsqlite3.dll is built without the
    /// 'localtime' modifier (it returns NULL).
    pub fn printReport(self: *Db, w: *Writer, range: Range, tag: []const u8) void {
        var st: w32.SYSTEMTIME = undefined;
        w32.GetLocalTime(&st);
        var today_buf: [16]u8 = undefined;
        const today = std.fmt.bufPrint(&today_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            st.wYear, st.wMonth, st.wDay,
        }) catch return;

        const modifier: []const u8 = switch (range) {
            .today => "+0 days",
            .week => "-6 days",
        };
        const label: []const u8 = switch (range) {
            .today => "today",
            .week => "last 7 days",
        };

        var dur_bufs: [4][64]u8 = undefined;
        {
            const stmt = self.prepare(
                "SELECT COUNT(*), COALESCE(SUM(duration_sec),0), COALESCE(SUM(focused_sec),0)," ++
                    " COALESCE(SUM(distracted_sec),0), COALESCE(SUM(elapsed_sec),0) FROM sessions" ++
                    " WHERE started_at >= date(?1,?2) AND (?3 = '' OR tag = ?3)",
            ) orelse return;
            defer _ = self.api.finalize(stmt);
            _ = self.api.bind_text(stmt, 1, today.ptr, @intCast(today.len), transient);
            _ = self.api.bind_text(stmt, 2, modifier.ptr, @intCast(modifier.len), transient);
            _ = self.api.bind_text(stmt, 3, tag.ptr, @intCast(tag.len), transient);
            if (self.api.step(stmt) != sqlite_row) return;

            const count = self.api.column_int64(stmt, 0);
            const total: u64 = @intCast(self.api.column_int64(stmt, 1));
            const focused: u64 = @intCast(self.api.column_int64(stmt, 2));
            const distracted: u64 = @intCast(self.api.column_int64(stmt, 3));
            const elapsed: u64 = @intCast(self.api.column_int64(stmt, 4));

            if (tag.len > 0) {
                w.print("=== sowon report: {s}, tag [{s}] ===\n", .{ label, tag }) catch return;
            } else {
                w.print("=== sowon report: {s} ===\n", .{label}) catch return;
            }
            w.print("sessions: {d}   active work: {s}   elapsed: {s}\n", .{
                count,
                util.fmtDur(&dur_bufs[0], total) catch "?",
                util.fmtDur(&dur_bufs[3], if (elapsed > 0) elapsed else total) catch "?",
            }) catch return;
            const tracked = focused + distracted;
            if (tracked > 0) {
                w.print("focus score: {d}%  (focused {s} / distracted {s})\n", .{
                    focused * 100 / tracked,
                    util.fmtDur(&dur_bufs[1], focused) catch "?",
                    util.fmtDur(&dur_bufs[2], distracted) catch "?",
                }) catch return;
            }
        }

        w.print("\ntop apps:\n", .{}) catch return;
        const stmt = self.prepare(
            "SELECT app, SUM(seconds) AS s, MAX(allowed) FROM app_usage" ++
                " JOIN sessions ON sessions.id = app_usage.session_id" ++
                " WHERE started_at >= date(?1,?2) AND (?3 = '' OR tag = ?3)" ++
                " GROUP BY app ORDER BY s DESC LIMIT 20",
        ) orelse return;
        defer _ = self.api.finalize(stmt);
        _ = self.api.bind_text(stmt, 1, today.ptr, @intCast(today.len), transient);
        _ = self.api.bind_text(stmt, 2, modifier.ptr, @intCast(modifier.len), transient);
        _ = self.api.bind_text(stmt, 3, tag.ptr, @intCast(tag.len), transient);

        var dur_buf: [64]u8 = undefined;
        while (self.api.step(stmt) == sqlite_row) {
            const name = self.columnText(stmt, 0);
            const secs: u64 = @intCast(self.api.column_int64(stmt, 1));
            const mark: []const u8 = if (self.api.column_int64(stmt, 2) != 0) "+" else " ";
            const dur = util.fmtDur(&dur_buf, secs) catch continue;
            w.print("{s:>11} {s} {s}\n", .{ dur, mark, name }) catch return;
        }
    }

    fn columnText(self: *Db, stmt: ?*Stmt, col: c_int) []const u8 {
        const ptr = self.api.column_text(stmt, col) orelse return "";
        return std.mem.span(ptr);
    }

    fn prepare(self: *Db, sql: []const u8) ?*Stmt {
        var stmt: ?*Stmt = null;
        if (self.api.prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != sqlite_ok) {
            return null;
        }
        return stmt;
    }

    fn execSimple(self: *Db, sql: [*:0]const u8) void {
        var errmsg: ?[*:0]u8 = null;
        if (self.api.exec(self.handle, sql, null, null, &errmsg) != sqlite_ok) {
            if (errmsg) |m| std.debug.print("sowon: sqlite error: {s}\n", .{m});
        }
    }

    /// Like execSimple but errors are expected and ignored (migrations).
    fn execSilent(self: *Db, sql: [*:0]const u8) void {
        var errmsg: ?[*:0]u8 = null;
        _ = self.api.exec(self.handle, sql, null, null, &errmsg);
    }
};

fn loadApi() ?Api {
    const lib = w32.LoadLibraryW(L("winsqlite3.dll")) orelse return null;
    return .{
        .open = getProc(lib, "sqlite3_open", @TypeOf(@as(Api, undefined).open)) orelse return null,
        .exec = getProc(lib, "sqlite3_exec", @TypeOf(@as(Api, undefined).exec)) orelse return null,
        .prepare_v2 = getProc(lib, "sqlite3_prepare_v2", @TypeOf(@as(Api, undefined).prepare_v2)) orelse return null,
        .bind_text = getProc(lib, "sqlite3_bind_text", @TypeOf(@as(Api, undefined).bind_text)) orelse return null,
        .bind_int64 = getProc(lib, "sqlite3_bind_int64", @TypeOf(@as(Api, undefined).bind_int64)) orelse return null,
        .step = getProc(lib, "sqlite3_step", @TypeOf(@as(Api, undefined).step)) orelse return null,
        .finalize = getProc(lib, "sqlite3_finalize", @TypeOf(@as(Api, undefined).finalize)) orelse return null,
        .last_insert_rowid = getProc(lib, "sqlite3_last_insert_rowid", @TypeOf(@as(Api, undefined).last_insert_rowid)) orelse return null,
        .column_text = getProc(lib, "sqlite3_column_text", @TypeOf(@as(Api, undefined).column_text)) orelse return null,
        .column_int64 = getProc(lib, "sqlite3_column_int64", @TypeOf(@as(Api, undefined).column_int64)) orelse return null,
    };
}

fn getProc(lib: w32.HMODULE, name: [*:0]const u8, comptime T: type) ?T {
    const ptr = w32.GetProcAddress(lib, name) orelse return null;
    return @ptrCast(@alignCast(ptr));
}
