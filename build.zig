const std = @import("std");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Select the optimization mode",
    ) orelse .ReleaseFast;
    const release_binary = optimize == .ReleaseFast or optimize == .ReleaseSmall;

    const flux_module = builder.addModule("flux", .{
        .root_source_file = builder.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = release_binary,
        .omit_frame_pointer = release_binary,
        .error_tracing = !release_binary,
    });

    const executable = builder.addExecutable(.{
        .name = "flux",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = release_binary,
            .omit_frame_pointer = release_binary,
            .error_tracing = !release_binary,
            .imports = &.{
                .{ .name = "flux", .module = flux_module },
            },
        }),
    });
    builder.installArtifact(executable);

    const run_command = builder.addRunArtifact(executable);
    run_command.step.dependOn(builder.getInstallStep());
    if (builder.args) |arguments| run_command.addArgs(arguments);

    const run_step = builder.step("run", "Run Flux");
    run_step.dependOn(&run_command.step);

    const test_module = builder.createModule(.{
        .root_source_file = builder.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
        .strip = false,
        .error_tracing = true,
    });
    const unit_tests = builder.addTest(.{ .root_module = test_module });
    const test_command = builder.addRunArtifact(unit_tests);
    const test_step = builder.step("test", "Run Flux tests");
    test_step.dependOn(&test_command.step);
}
