//! Renderer-agnostic frame description. main.zig computes WHAT to draw
//! (digit columns, wiggle rows, tint, report lines); the selected
//! backend decides HOW. Every backend consumes exactly this interface:
//!
//!   pub fn init() !void
//!   pub fn paint(hwnd: w32.HWND, view: frame.View) void
//!   pub fn reportVisibleLines(height: i32) i32

pub const chars_count = 8; // HH:MM:SS

pub const Tint = enum { normal, paused, brk };

pub const ClockFace = struct {
    /// Sprite-sheet column per character (0-9, or the colon column).
    columns: [chars_count]u8,
    /// Wiggle row per character.
    rows: [chars_count]u8,
    tint: Tint,
};

pub const ReportView = struct {
    lines: []const [:0]const u16,
    /// First visible line; the renderer clamps it against the current
    /// window size (line metrics are backend knowledge).
    scroll: *i32,
};

pub const View = union(enum) {
    clock: ClockFace,
    report: ReportView,
};
