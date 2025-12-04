//! sowon's glyph-blitting shaders, written in Zig and compiled to SPIR-V by
//! the Zig compiler itself (`-target spirv64-vulkan -ofmt=spirv`). No glslc,
//! DXC, or Vulkan SDK is involved in the build.
//!
//! Both entry points live in this one module; Vulkan selects between them by
//! entry-point name (VkPipelineShaderStageCreateInfo.pName).
//!
//! One draw call per glyph: 4 vertices as a triangle strip, with the source
//! and destination rectangles supplied through push constants. The digit
//! atlas is bound as a *storage buffer* of BGRA texels rather than a sampled
//! image, because Zig's SPIR-V backend does not yet emit image/sampler types.
//! Sampling is therefore nearest-neighbour, done by hand in `fragmentMain`.

const std = @import("std");
const gpu = std.gpu;

const Vec2 = @Vector(2, f32);
const Vec4 = @Vector(4, f32);

/// Must match Push in src/render/spirv.zig (64 bytes, std430 layout).
pub const Push = extern struct {
    /// Destination rect in pixels: x, y, w, h.
    dst: Vec4,
    /// Source rect in atlas texels: x, y, w, h.
    src: Vec4,
    /// Colour multiplier (rgb used, a ignored).
    tint: Vec4,
    /// Viewport size in pixels.
    screen: Vec2,
    /// Atlas width in texels, for row addressing.
    atlas_width: u32,
    _pad: u32,
};

/// The digit atlas as raw BGRA8 texels, one u32 each.
/// Sized generously; the real length comes from the bound buffer range.
const Atlas = extern struct {
    texels: [1 << 20]u32,
};

extern const push: Push addrspace(.push_constant);
extern var atlas: Atlas addrspace(.storage_buffer);

// Varying: source position in atlas texels.
extern var v_atlas_uv_out: Vec2 addrspace(.output);
extern var v_atlas_uv_in: Vec2 addrspace(.input);

extern var out_color: Vec4 addrspace(.output);

export fn vertexMain() callconv(.spirv_vertex) void {
    asm volatile ("OpDecorate %uv Location 0"
        :
        : [uv] "" (&v_atlas_uv_out),
    );

    // gl_VertexIndex 0..3 -> unit-quad corner, as a triangle strip.
    const i = gpu.vertex_index;
    const u: f32 = if (i & 1 == 0) 0.0 else 1.0;
    const v: f32 = if (i & 2 == 0) 0.0 else 1.0;

    // Destination rect -> pixels -> normalised device coordinates.
    const px = push.dst[0] + push.dst[2] * u;
    const py = push.dst[1] + push.dst[3] * v;
    const ndc_x = (px / push.screen[0]) * 2.0 - 1.0;
    const ndc_y = (py / push.screen[1]) * 2.0 - 1.0;

    gpu.position_out.* = Vec4{ ndc_x, ndc_y, 0.0, 1.0 };
    v_atlas_uv_out = Vec2{
        push.src[0] + push.src[2] * u,
        push.src[1] + push.src[3] * v,
    };
}

export fn fragmentMain() callconv(.spirv_fragment) void {
    asm volatile ("OpDecorate %uv Location 0"
        :
        : [uv] "" (&v_atlas_uv_in),
    );
    asm volatile ("OpDecorate %c Location 0"
        :
        : [c] "" (&out_color),
    );
    asm volatile ("OpDecorate %a DescriptorSet 0"
        :
        : [a] "" (&atlas),
    );
    asm volatile ("OpDecorate %a Binding 0"
        :
        : [a] "" (&atlas),
    );

    // Nearest-neighbour fetch from the storage-buffer atlas.
    const uv = v_atlas_uv_in;
    const x: u32 = @intFromFloat(@max(uv[0], 0.0));
    const y: u32 = @intFromFloat(@max(uv[1], 0.0));
    const texel = atlas.texels[y * push.atlas_width + x];

    // Atlas is BGRA8 with straight alpha (byte order B,G,R,A).
    const b: f32 = @floatFromInt(texel & 0xff);
    const g: f32 = @floatFromInt((texel >> 8) & 0xff);
    const r: f32 = @floatFromInt((texel >> 16) & 0xff);
    const a: f32 = @floatFromInt((texel >> 24) & 0xff);

    // Straight alpha out; the pipeline blends SRC_ALPHA / ONE_MINUS_SRC_ALPHA.
    out_color = Vec4{
        (r / 255.0) * push.tint[0],
        (g / 255.0) * push.tint[1],
        (b / 255.0) * push.tint[2],
        a / 255.0,
    };
}
