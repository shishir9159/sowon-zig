const std = @import("std");

const sample_rate: u32 = 44100;
const decay_tau: f64 = 0.45; // seconds; bigger = longer ring-out
const attack: f64 = 0.008; // seconds; avoids a click at note onset
const peak_amplitude: f64 = 0.7; // headroom after normalization

const Note = struct { freq: f64, at: f64 };

const finish_notes = [_]Note{
    .{ .freq = 523.25, .at = 0.00 }, // C5
    .{ .freq = 659.25, .at = 0.12 }, // E5
    .{ .freq = 783.99, .at = 0.24 }, // G5
    .{ .freq = 1046.50, .at = 0.36 }, // C6
};

// Shorter two-note "back to work" cue for break-end.
const break_notes = [_]Note{
    .{ .freq = 783.99, .at = 0.00 }, // G5
    .{ .freq = 1046.50, .at = 0.10 }, // C6
};

/// Full end-of-work chime.
pub fn buildWav(alloc: std.mem.Allocator) ![]u8 {
    return build(alloc, &finish_notes, 2.4);
}

/// Short end-of-break chime.
pub fn buildBreakWav(alloc: std.mem.Allocator) ![]u8 {
    return build(alloc, &break_notes, 1.2);
}

// Single soft note used as the distraction nudge.
const nudge_notes = [_]Note{
    .{ .freq = 659.25, .at = 0.0 }, // E5
};

/// Quiet, short attention tick.
pub fn buildNudgeWav(alloc: std.mem.Allocator) ![]u8 {
    return build(alloc, &nudge_notes, 0.5);
}

/// Returns a complete WAV file image. The caller must keep it alive
/// for as long as the sound may be playing (PlaySound with SND_ASYNC
/// reads from the buffer while it plays).
fn build(alloc: std.mem.Allocator, notes: []const Note, total_seconds: f64) ![]u8 {
    const n: usize = @intFromFloat(total_seconds * @as(f64, sample_rate));

    const mix = try alloc.alloc(f64, n);
    defer alloc.free(mix);
    @memset(mix, 0);

    for (notes) |note| {
        const start: usize = @intFromFloat(note.at * @as(f64, sample_rate));
        for (start..n) |i| {
            const t = @as(f64, @floatFromInt(i - start)) / @as(f64, sample_rate);
            const env = @min(t / attack, 1.0) * @exp(-t / decay_tau);
            const w = 2.0 * std.math.pi * note.freq * t;
            mix[i] += env * (@sin(w) + 0.35 * @sin(2.0 * w) + 0.15 * @sin(3.0 * w));
        }
    }

    var peak: f64 = 1e-9;
    for (mix) |s| peak = @max(peak, @abs(s));
    const gain = peak_amplitude / peak;

    const data_len: u32 = @intCast(n * 2);
    const wav = try alloc.alloc(u8, 44 + data_len);

    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 36 + data_len, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, wav[22..24], 1, .little); // mono
    std.mem.writeInt(u32, wav[24..28], sample_rate, .little);
    std.mem.writeInt(u32, wav[28..32], sample_rate * 2, .little); // byte rate
    std.mem.writeInt(u16, wav[32..34], 2, .little); // block align
    std.mem.writeInt(u16, wav[34..36], 16, .little); // bits per sample
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], data_len, .little);

    for (mix, 0..) |s, i| {
        const v: i16 = @intFromFloat(std.math.clamp(s * gain, -1.0, 1.0) * 32767.0);
        std.mem.writeInt(i16, wav[44 + i * 2 ..][0..2], v, .little);
    }

    return wav;
}

const testing = std.testing;

/// Parses the parts of the RIFF header the Windows audio APIs rely on.
fn expectValidWav(wav: []const u8, expect_seconds: f64) !void {
    try testing.expect(wav.len > 44);
    try testing.expectEqualStrings("RIFF", wav[0..4]);
    try testing.expectEqualStrings("WAVE", wav[8..12]);
    try testing.expectEqualStrings("fmt ", wav[12..16]);
    try testing.expectEqualStrings("data", wav[36..40]);

    // RIFF size must cover everything after the first 8 bytes.
    try testing.expectEqual(
        @as(u32, @intCast(wav.len - 8)),
        std.mem.readInt(u32, wav[4..8], .little),
    );
    // data chunk size must match the actual payload.
    const data_len = std.mem.readInt(u32, wav[40..44], .little);
    try testing.expectEqual(@as(usize, data_len), wav.len - 44);

    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, wav[20..22], .little)); // PCM
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, wav[22..24], .little)); // mono
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, wav[34..36], .little)); // bits
    try testing.expectEqual(sample_rate, std.mem.readInt(u32, wav[24..28], .little));
    // byte rate = sample_rate * channels * bytes-per-sample
    try testing.expectEqual(sample_rate * 2, std.mem.readInt(u32, wav[28..32], .little));
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, wav[32..34], .little)); // block align

    const expected_samples: usize = @intFromFloat(expect_seconds * @as(f64, sample_rate));
    try testing.expectEqual(expected_samples, data_len / 2);
}

test "buildWav produces a valid 2.4s mono PCM chime" {
    const wav = try buildWav(testing.allocator);
    defer testing.allocator.free(wav);
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

    var peak: i32 = 0;
    var i: usize = 44;
    while (i + 1 < wav.len) : (i += 2) {
        const v: i32 = std.mem.readInt(i16, wav[i..][0..2], .little);
        const mag: i32 = @intCast(@abs(v));
        peak = @max(peak, mag);
    }

    // peak_amplitude is 0.7 of full scale, so expect ~22937.
    const expected: i32 = @intFromFloat(peak_amplitude * 32767.0);
    try testing.expect(peak <= 32767); // never clips
    try testing.expect(peak > expected - 200); // and is actually normalised
    try testing.expect(peak < expected + 200);
}

test "chime starts near silence so there is no click" {
    const wav = try buildWav(testing.allocator);
    defer testing.allocator.free(wav);
    const first = std.mem.readInt(i16, wav[44..46], .little);
    try testing.expect(@abs(@as(i32, first)) < 500);
}