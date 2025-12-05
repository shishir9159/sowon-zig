const std = @import("std");
const w32 = @import("../win32.zig");
const frame = @import("frame.zig");

pub const spirv_module = @embedFile("sprite_spv");
pub const vertex_entry_point = "vertexMain";
pub const fragment_entry_point = "fragmentMain";

pub const Push = extern struct {
    dst: [4]f32,
    src: [4]f32,
    tint: [4]f32,
    screen: [2]f32,
    atlas_width: u32,
    _pad: u32 = 0,
};

comptime {
    if (spirv_module.len < 20 or std.mem.readInt(u32, spirv_module[0..4], .little) != 0x07230203)
        @compileError("sprite_spv is not a valid SPIR-V module");
    if (@sizeOf(Push) != 64) @compileError("Push must stay 64 bytes to match the shader");
}

pub fn tintRgb(tint: frame.Tint) [3]f32 {
    const rgb: @Vector(3, f32) = @floatFromInt(@as(@Vector(3, u8), frame.tintRgb(tint)));
    return rgb / @as(@Vector(3, f32), @splat(255));
}

pub const reportVisibleLines = frame.reportVisibleLines;

pub fn init() !void {
    std.debug.print(
        \\sowon: the 'spirv' renderer's shaders are compiled and embedded
        \\  ({d} bytes of SPIR-V, entry points '{s}' / '{s}'), but the Vulkan
        \\  host layer (swapchain, pipeline, command buffers) is not written
        \\  yet. Build with -Drenderer=gdi to run sowon today.
        \\
    , .{ spirv_module.len, vertex_entry_point, fragment_entry_point });
    return error.VulkanHostNotImplemented;
}

pub fn paint(_: w32.HWND, _: frame.View) void {}
