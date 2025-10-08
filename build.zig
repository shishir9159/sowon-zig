const std = @import("std");

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

    const options = b.addOptions();
    options.addOption(u64, "sample_interval_secs", sample_interval);

    const exe = b.addExecutable(.{
        .name = "sowon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    exe.root_module.linkSystemLibrary("winmm", .{});
    exe.root_module.linkSystemLibrary("msimg32", .{});
    exe.root_module.linkSystemLibrary("ws2_32", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run sowon");
    run_step.dependOn(&run_cmd.step);
}