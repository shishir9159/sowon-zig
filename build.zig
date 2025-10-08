const std = @import("std");

pub const Renderer = enum { gdi, opengl, vulkan, sdl, glfw };
pub const ShaderBackend = enum { none, slang };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Foreground-app sampling interval in seconds. Overridable at build
    // time: SOWON_SAMPLE_INTERVAL=5 zig build ...
    var sample_interval: u64 = 10;
    if (b.graph.environ_map.get("SOWON_SAMPLE_INTERVAL")) |v| {
        sample_interval = std.fmt.parseInt(u64, v, 10) catch sample_interval;
    }
    if (sample_interval < 1) sample_interval = 1;

    // Rendering backend selection: only the chosen backend's module is
    // analyzed and compiled; the rest are discarded by lazy compilation.
    const renderer = b.option(
        Renderer,
        "renderer",
        "Rendering backend to compile in (default: gdi)",
    ) orelse .gdi;

    const shader_backend = b.option(
        ShaderBackend,
        "shader-backend",
        "Shader toolchain for GPU renderers (default: none)",
    ) orelse .none;

    if (shader_backend == .slang and renderer == .gdi) {
        std.process.fatal(
            "-Dshader-backend=slang requires a GPU renderer (-Drenderer=opengl|vulkan|sdl|glfw); gdi does not run shaders",
            .{},
        );
    }

    const options = b.addOptions();
    options.addOption(u64, "sample_interval_secs", sample_interval);
    options.addOption(Renderer, "renderer", renderer);
    options.addOption(ShaderBackend, "shader_backend", shader_backend);

    const exe = b.addExecutable(.{
        .name = "sowon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    // Libraries every build needs (window, sound, listener, tray).
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("winmm", .{});
    exe.root_module.linkSystemLibrary("ws2_32", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});

    // Backend-specific libraries.
    switch (renderer) {
        .gdi => {
            exe.root_module.linkSystemLibrary("gdi32", .{});
            exe.root_module.linkSystemLibrary("msimg32", .{});
        },
        .opengl => {
            exe.root_module.linkSystemLibrary("opengl32", .{});
            exe.root_module.linkSystemLibrary("gdi32", .{}); // wgl pixel formats
        },
        // Stub backends: link their libraries (vulkan-1, SDL, GLFW)
        // here once they get an implementation. Linking now would just
        // mask the stub's "not implemented" compile error with a
        // missing-library linker error.
        .vulkan, .sdl, .glfw => {},
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run sowon");
    run_step.dependOn(&run_cmd.step);

    // `zig build test`: unit tests for the pure helpers and the
    // protobuf decoder. These modules have no OS/global-state deps.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/util.zig", "src/server.zig" }) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}