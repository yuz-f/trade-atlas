const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const atlas = b.addModule("atlas", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "atlas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "atlas", .module = atlas }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the atlas CLI").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests and fixture tests");
    const unit = b.addTest(.{ .root_module = atlas });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Parser tests against real responses captured by `atlas probe`.
    const fixtures = b.createModule(.{ .root_source_file = b.path("fixtures/fixtures.zig") });
    const fixture_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/fixture_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "atlas", .module = atlas },
            .{ .name = "fixtures", .module = fixtures },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(fixture_tests).step);
}
