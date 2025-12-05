const std = @import("std");

pub const Renderer = enum { gdi, opengl, spirv, sdl, glfw };
pub const ShaderBackend = enum { none, zig, slang };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sample_interval: u64 = if (b.graph.environ_map.get("SOWON_SAMPLE_INTERVAL")) |v|
        @max(std.fmt.parseInt(u64, v, 10) catch 10, 1)
    else
        10;
    const renderer = b.option(Renderer, "renderer", "Rendering backend to compile in (default: gdi)") orelse .gdi;
    const shader_backend = b.option(
        ShaderBackend,
        "shader-backend",
        "Shader toolchain for GPU renderers (default: zig for spirv, none otherwise)",
    ) orelse if (renderer == .spirv) ShaderBackend.zig else .none;

    if (shader_backend != .none and renderer == .gdi) {
        std.process.fatal("-Dshader-backend={s} requires a GPU renderer (-Drenderer=spirv|opengl|sdl|glfw)", .{@tagName(shader_backend)});
    }
    if (shader_backend == .slang) {
        std.process.fatal("-Dshader-backend=slang is not wired up; the spirv backend uses -Dshader-backend=zig", .{});
    }

    const options = b.addOptions();
    options.addOption(u64, "sample_interval_secs", sample_interval);
    options.addOption(Renderer, "renderer", renderer);

    const exe = b.addExecutable(.{ .name = "sowon", .root_module = module(b, "src/main.zig", target, optimize) });
    exe.root_module.addOptions("build_options", options);
    link(exe.root_module, &.{ "user32", "winmm", "ws2_32", "shell32" });
    link(exe.root_module, switch (renderer) {
        .gdi => &.{ "gdi32", "msimg32" },
        .opengl => &.{ "opengl32", "gdi32" },
        .spirv, .sdl, .glfw => &.{},
    });

    if (shader_backend == .zig) {
        // Zig 0.16: the build server can't emit SPIR-V (NotOpenForWriting) and
        // release modes produce an empty module, so run build-obj in Debug.
        const spv = b.addSystemCommand(&.{ b.graph.zig_exe, "build-obj", "-ofmt=spirv", "-target", "spirv64-vulkan", "-ODebug" });
        spv.addFileArg(b.path("src/render/shaders/sprite.zig"));
        exe.root_module.addAnonymousImport("sprite_spv", .{ .root_source_file = spv.addPrefixedOutputFileArg("-femit-bin=", "sprite.spv") });
    }

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run sowon").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/util.zig", "src/server.zig", "src/chime.zig", "src/digits.zig" }) |src| {
        const t = b.addTest(.{ .root_module = module(b, src, target, optimize) });
        link(t.root_module, &.{ "kernel32", "user32", "ws2_32" });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

fn module(b: *std.Build, src: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(src), .target = target, .optimize = optimize });
}

fn link(m: *std.Build.Module, libs: []const []const u8) void {
    for (libs) |lib| m.linkSystemLibrary(lib, .{});
}
