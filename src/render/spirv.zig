//! SPIR-V rendering backend: a Vulkan renderer whose shaders are written in
//! Zig (src/render/shaders/sprite.zig) and compiled to SPIR-V by the Zig
//! compiler itself. Selected with -Drenderer=spirv.
//!
//! Status: the shader half is complete and verified — `zig build
//! -Drenderer=spirv` compiles the Zig shaders to a real Vulkan SPIR-V module
//! (both entry points, BuiltIn/Location/DescriptorSet decorations) and embeds
//! it here, with the magic number asserted at compile time.
//!
//! The Vulkan HOST side (instance, surface, device, swapchain, pipeline,
//! command buffers, atlas upload) is not implemented yet, so `init` fails at
//! runtime with a clear message rather than pretending to draw. Everything it
//! will need — the shader module, entry-point names, and the exact push
//! constant layout — is defined below.

const std = @import("std");
const w32 = @import("../win32.zig");
const digits = @import("../digits.zig");
const frame = @import("frame.zig");

/// The compiled SPIR-V module, produced by build.zig from the Zig shader
/// sources and injected as an anonymous import.
pub const spirv_module = @embedFile("sprite_spv");

/// Entry-point names inside `spirv_module`; Vulkan picks between them via
/// VkPipelineShaderStageCreateInfo.pName.
pub const vertex_entry_point = "vertexMain";
pub const fragment_entry_point = "fragmentMain";

comptime {
    // A real SPIR-V module starts with the magic number 0x07230203. This
    // turns "did the shader toolchain actually work?" into a build error
    // rather than a black screen at runtime.
    if (spirv_module.len < 20) @compileError("sprite_spv is too small to be a SPIR-V module");
    const magic = std.mem.readInt(u32, spirv_module[0..4], .little);
    if (magic != 0x07230203) @compileError("sprite_spv is not a valid SPIR-V module (bad magic)");
}

/// Mirrors `Push` in the shader. std430 layout: three 16-byte vectors, then
/// an 8-byte vec2 and two u32s — 64 bytes total, well inside the 128-byte
/// guaranteed push-constant limit.
pub const Push = extern struct {
    dst: [4]f32, // destination rect in pixels: x, y, w, h
    src: [4]f32, // source rect in atlas texels: x, y, w, h
    tint: [4]f32, // colour multiplier (rgb used)
    screen: [2]f32, // viewport size in pixels
    atlas_width: u32,
    _pad: u32 = 0,
};

comptime {
    if (@sizeOf(Push) != 64) @compileError("Push must stay 64 bytes to match the shader");
}

/// RGB multiplier per tint, matching the GDI backend's palette. With the
/// SPIR-V backend the atlas is uploaded once, untinted, and coloured in the
/// fragment shader — no per-tint copies.
pub fn tintRgb(tint: frame.Tint) [3]f32 {
    return switch (tint) {
        .normal => .{ 220.0 / 255.0, 220.0 / 255.0, 220.0 / 255.0 },
        .paused => .{ 220.0 / 255.0, 120.0 / 255.0, 120.0 / 255.0 },
        .brk => .{ 130.0 / 255.0, 210.0 / 255.0, 150.0 / 255.0 },
    };
}

/// Atlas dimensions the shader addresses the storage buffer with.
pub const atlas_width: u32 = digits.sheet_width;
pub const atlas_height: u32 = digits.sheet_height;

const report_top_margin: i32 = 24;

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

pub fn paint(hwnd: w32.HWND, view: frame.View) void {
    _ = hwnd;
    _ = view;
}

/// Pure layout maths, independent of the graphics API, so it is already
/// correct for this backend.
pub fn reportVisibleLines(height: i32) i32 {
    const line_height = std.math.clamp(@divTrunc(height, 18), 18, 44);
    return @max(@divTrunc(height - report_top_margin, line_height), 1);
}
