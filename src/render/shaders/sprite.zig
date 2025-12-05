const std = @import("std");
const gpu = std.gpu;

const Vec2 = @Vector(2, f32);
const Vec4 = @Vector(4, f32);

pub const Push = extern struct {
    dst: Vec4,
    src: Vec4,
    tint: Vec4,
    screen: Vec2,
    atlas_width: u32,
    _pad: u32,
};

const Atlas = extern struct {
    texels: [1 << 20]u32,
};

extern const push: Push addrspace(.push_constant);
extern var atlas: Atlas addrspace(.storage_buffer);
extern var v_atlas_uv_out: Vec2 addrspace(.output);
extern var v_atlas_uv_in: Vec2 addrspace(.input);
extern var out_color: Vec4 addrspace(.output);

export fn vertexMain() callconv(.spirv_vertex) void {
    asm volatile ("OpDecorate %uv Location 0"
        :
        : [uv] "" (&v_atlas_uv_out),
    );

    const i = gpu.vertex_index;
    const u: f32 = if (i & 1 == 0) 0.0 else 1.0;
    const v: f32 = if (i & 2 == 0) 0.0 else 1.0;
    const px = push.dst[0] + push.dst[2] * u;
    const py = push.dst[1] + push.dst[3] * v;

    gpu.position_out.* = Vec4{ px / push.screen[0] * 2.0 - 1.0, py / push.screen[1] * 2.0 - 1.0, 0.0, 1.0 };
    v_atlas_uv_out = Vec2{ push.src[0] + push.src[2] * u, push.src[1] + push.src[3] * v };
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

    const uv = v_atlas_uv_in;
    const x: u32 = @intFromFloat(@max(uv[0], 0.0));
    const y: u32 = @intFromFloat(@max(uv[1], 0.0));
    const texel = atlas.texels[y * push.atlas_width + x];

    const b: f32 = @floatFromInt(texel & 0xff);
    const g: f32 = @floatFromInt((texel >> 8) & 0xff);
    const r: f32 = @floatFromInt((texel >> 16) & 0xff);
    const a: f32 = @floatFromInt((texel >> 24) & 0xff);

    out_color = Vec4{ r / 255.0 * push.tint[0], g / 255.0 * push.tint[1], b / 255.0 * push.tint[2], a / 255.0 };
}
