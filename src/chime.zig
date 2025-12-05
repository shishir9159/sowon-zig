const std = @import("std");

const sample_rate = 44100;
const decay_tau = 0.45;
const attack = 0.008;
const peak_amplitude = 0.7;

const Note = struct { freq: f64, at: f64 };

const Header = extern struct {
    riff: [4]u8 = "RIFF".*,
    size: u32,
    wave: [4]u8 = "WAVE".*,
    fmt: [4]u8 = "fmt ".*,
    fmt_size: u32 = 16,
    format: u16 = 1,
    channels: u16 = 1,
    rate: u32 = sample_rate,
    byte_rate: u32 = sample_rate * 2,
    block_align: u16 = 2,
    bits: u16 = 16,
    data: [4]u8 = "data".*,
    data_size: u32,
};

pub fn buildWav(alloc: std.mem.Allocator) ![]u8 {
    return build(alloc, &.{ .{ .freq = 523.25, .at = 0 }, .{ .freq = 659.25, .at = 0.12 }, .{ .freq = 783.99, .at = 0.24 }, .{ .freq = 1046.5, .at = 0.36 } }, 2.4);
}

pub fn buildBreakWav(alloc: std.mem.Allocator) ![]u8 {
    return build(alloc, &.{ .{ .freq = 783.99, .at = 0 }, .{ .freq = 1046.5, .at = 0.1 } }, 1.2);
}

pub fn buildNudgeWav(alloc: std.mem.Allocator) ![]u8 {
    return build(alloc, &.{.{ .freq = 659.25, .at = 0 }}, 0.5);
}

fn build(alloc: std.mem.Allocator, notes: []const Note, seconds: f64) ![]u8 {
    const n: usize = @intFromFloat(seconds * sample_rate);
    const mix = try alloc.alloc(f64, n);
    defer alloc.free(mix);
    @memset(mix, 0);

    for (notes) |note| {
        const start: usize = @intFromFloat(note.at * sample_rate);
        for (mix[start..], 0..) |*m, k| {
            const t = @as(f64, @floatFromInt(k)) / sample_rate;
            const w = 2.0 * std.math.pi * note.freq * t;
            m.* += @min(t / attack, 1.0) * @exp(-t / decay_tau) * (@sin(w) + 0.35 * @sin(2.0 * w) + 0.15 * @sin(3.0 * w));
        }
    }

    var peak: f64 = 1e-9;
    for (mix) |s| peak = @max(peak, @abs(s));
    const gain = peak_amplitude / peak;

    const data_len: u32 = @intCast(n * 2);
    const wav = try alloc.alloc(u8, @sizeOf(Header) + data_len);
    @memcpy(wav[0..@sizeOf(Header)], std.mem.asBytes(&Header{ .size = 36 + data_len, .data_size = data_len }));
    for (mix, std.mem.bytesAsSlice(i16, wav[@sizeOf(Header)..])) |s, *out| {
        out.* = @intFromFloat(std.math.clamp(s * gain, -1.0, 1.0) * 32767.0);
    }
    return wav;
}

const testing = std.testing;

fn expectValidWav(wav: []const u8, seconds: f64) !void {
    const h = std.mem.bytesToValue(Header, wav[0..@sizeOf(Header)]);
    try testing.expectEqualDeep(Header{ .size = @intCast(wav.len - 8), .data_size = @intCast(wav.len - @sizeOf(Header)) }, h);
    try testing.expectEqual(@as(u32, @intFromFloat(seconds * sample_rate)), h.data_size / 2);
}

fn samples(wav: []const u8) []align(1) const i16 {
    return std.mem.bytesAsSlice(i16, wav[@sizeOf(Header)..]);
}

test "buildWav produces a valid 2.4s mono PCM chime" {
    const wav = try buildWav(testing.allocator);
    defer testing.allocator.free(wav);
    try testing.expectEqual(44, @sizeOf(Header));
    try expectValidWav(wav, 2.4);
}

test "buildBreakWav and buildNudgeWav are valid and shorter" {
    const brk = try buildBreakWav(testing.allocator);
    defer testing.allocator.free(brk);
    try expectValidWav(brk, 1.2);

    const nudge = try buildNudgeWav(testing.allocator);
    defer testing.allocator.free(nudge);
    try expectValidWav(nudge, 0.5);
    try testing.expect(nudge.len < brk.len);
}

test "chime is normalised: peaks near full scale but never clips" {
    const wav = try buildWav(testing.allocator);
    defer testing.allocator.free(wav);

    var peak: u16 = 0;
    for (samples(wav)) |v| peak = @max(peak, @abs(v));
    const expected: i32 = @intFromFloat(peak_amplitude * 32767.0);
    try testing.expect(peak <= 32767);
    try testing.expect(@abs(@as(i32, peak) - expected) < 200);
}

test "chime starts near silence so there is no click" {
    const wav = try buildWav(testing.allocator);
    defer testing.allocator.free(wav);
    try testing.expect(@abs(samples(wav)[0]) < 500);
}
