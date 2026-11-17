const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library. Consumers import it with:
    //   b.dependency("envsh", .{}).module("dotenv")
    const dotenv = b.addModule("dotenv", .{
        .root_source_file = b.path("src/dotenv.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The CLI. Only built when a step that needs it runs (install, run, test).
    const exe = b.addExecutable(.{
        .name = "envsh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dotenv", .module = dotenv },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run envsh");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addRunArtifact(
        b.addTest(.{ .root_module = dotenv }),
    );
    const exe_tests = b.addRunArtifact(
        b.addTest(.{ .root_module = exe.root_module }),
    );
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&lib_tests.step);
    test_step.dependOn(&exe_tests.step);
}
