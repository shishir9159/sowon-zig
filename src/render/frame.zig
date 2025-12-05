const std = @import("std");

pub const chars_count = 8;
pub const report_top_margin: i32 = 24;

pub const Tint = enum { normal, paused, brk };

pub fn tintRgb(tint: Tint) [3]u8 {
    return switch (tint) {
        .normal => .{ 220, 220, 220 },
        .paused => .{ 220, 120, 120 },
        .brk => .{ 130, 210, 150 },
    };
}

pub const ClockFace = struct {
    columns: [chars_count]u8,
    rows: [chars_count]u8,
    tint: Tint,
};

pub const ReportView = struct {
    lines: []const [:0]const u16,
    scroll: *i32,
};

pub const View = union(enum) {
    clock: ClockFace,
    report: ReportView,
};

pub fn reportLineHeight(height: i32) i32 {
    return std.math.clamp(@divTrunc(height, 18), 18, 44);
}

pub fn reportVisibleLines(height: i32) i32 {
    return @max(@divTrunc(height - report_top_margin, reportLineHeight(height)), 1);
}
