const std = @import("std");

pub const Renderer = enum { gdi, opengl, spirv, sdl, glfw };
pub const ShaderBackend = enum { none, zig, slang };

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

    // Shader toolchain. 'zig' compiles the shaders in src/render/shaders/
    // to SPIR-V with the Zig compiler itself — no Vulkan SDK, glslc or DXC
    // required. It is the default (and currently only) choice for -Drenderer=spirv.
    const shader_backend = b.option(
        ShaderBackend,
        "shader-backend",
        "Shader toolchain for GPU renderers (default: zig for spirv, none otherwise)",
    ) orelse if (renderer == .spirv) ShaderBackend.zig else ShaderBackend.none;

    if (shader_backend != .none and (renderer == .gdi)) {
        std.process.fatal(
            "-Dshader-backend={s} requires a GPU renderer (-Drenderer=spirv|opengl|sdl|glfw); gdi does not run shaders",
            .{@tagName(shader_backend)},
        );
    }
    if (shader_backend == .slang) {
        std.process.fatal(
            "-Dshader-backend=slang is not wired up; the spirv backend compiles its shaders with -Dshader-backend=zig",
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
        // Nothing to link: the host layer loads vulkan-1.dll at runtime with
        // LoadLibrary/GetProcAddress (as db.zig does for winsqlite3.dll), so
        // no Vulkan SDK import library is needed to build.
        .spirv => {},
        // Stub backends: link their libraries (SDL, GLFW) here once they
        // get an implementation. Linking now would just mask the stub's
        // "not implemented" compile error with a missing-library error.
        .sdl, .glfw => {},
    }

    // Compile the Zig shaders to SPIR-V with the Zig compiler and embed the
    // resulting module in the executable. Runs only for -Drenderer=spirv, so
    // no other build pays for it.
    if (shader_backend == .zig) {
        // Invoke the compiler directly rather than via b.addObject: on Zig
        // 0.16.0 the SPIR-V backend cannot emit through the build server's
        // --listen protocol and fails with "NotOpenForWriting". Driving
        // `zig build-obj ... -femit-bin=` as a plain subprocess works.
        const spv = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build-obj",
            "-ofmt=spirv",
            "-target",
            "spirv64-vulkan",
            // MUST stay Debug: every release mode crashes the SPIR-V backend
            // on 0.16.0 and silently produces a 0-byte module. Harmless — the
            // driver optimises SPIR-V anyway — and src/render/spirv.zig
            // asserts the magic number, so a regression fails the build
            // rather than the GPU.
            "-ODebug",
        });
        spv.addFileArg(b.path("src/render/shaders/sprite.zig"));
        const spv_bin = spv.addPrefixedOutputFileArg("-femit-bin=", "sprite.spv");

        // Exposed to the backend as @embedFile("sprite_spv").
        exe.root_module.addAnonymousImport("sprite_spv", .{ .root_source_file = spv_bin });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run sowon");
    run_step.dependOn(&run_cmd.step);

    // `zig build test`: unit tests for the modules that can run headless.
    // (main.zig and the renderers need a window and are covered by running
    // the app; the browser-extension side has its own suite in
    // bell-bearer/tests/.)
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{
        "src/util.zig", // duration parsing, formatting, allow-list matching
        "src/server.zig", // HTTP + gRPC-Web + protobuf decoding
        "src/chime.zig", // synthesized WAV correctness
        "src/digits.zig", // sprite atlas premultiply maths
    }) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        // server.zig pulls in the Win32 externs (SRWLOCK, winsock).
        t.root_module.linkSystemLibrary("kernel32", .{});
        t.root_module.linkSystemLibrary("user32", .{});
        t.root_module.linkSystemLibrary("ws2_32", .{});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}