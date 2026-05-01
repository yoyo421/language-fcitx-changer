const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const dbus = b.addTranslateC(.{
        .root_source_file = b.path("c.c"),
        .target = target,
        .optimize = optimize,
    });
    const dbusModule = dbus.addModule("sd-bus");
    dbusModule.linkSystemLibrary("libsystemd", .{});

    const langChanger = b.addModule("lang", .{
        .root_source_file = b.path("language-changer.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    langChanger.addImport("sd-bus", dbusModule);

    const exe = b.addExecutable(.{ .name = "language-changer", .root_module = langChanger, .use_llvm = true });

    b.installArtifact(exe);
    const exeRun = b.addRunArtifact(exe);

    const runStep = b.step("run", "Run the language changer executable");
    runStep.dependOn(&exeRun.step);
}
