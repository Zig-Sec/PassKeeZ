const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const keylib_dep = b.dependency("keylib", .{
        .target = target,
        .optimize = optimize,
    });

    const tresor_dep = b.dependency("tresor", .{
        .target = target,
        .optimize = optimize,
    });

    const compile_resources = b.addSystemCommand(
        &[_][]const u8{ "glib-compile-resources", "src/keypass.gresources.xml", "--target=src/resources.c", "--sourcedir=src", "--generate-source" },
    );

    const exe = b.addExecutable(.{
        .name = "keypass",
        .root_source_file = .{ .path = "src/main.old.c" },
        .target = target,
        .optimize = optimize,
    });
    exe.step.dependOn(&compile_resources.step);
    //exe.addCSourceFiles(&.{
    //    "src/authenticator.c",
    //    "src/authenticatorwin.c",
    //    "src/login.c",
    //    "src/resources.c",
    //}, &.{});
    exe.linkLibrary(keylib_dep.artifact("keylib"));
    exe.linkLibrary(keylib_dep.artifact("uhid"));
    exe.linkLibrary(tresor_dep.artifact("tresor"));
    //exe.linkSystemLibrary("gtk4");
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    //const unit_tests = b.addTest(.{
    //    .root_source_file = .{ .path = "src/main.zig" },
    //    .target = target,
    //    .optimize = optimize,
    //});

    //const run_unit_tests = b.addRunArtifact(unit_tests);

    //const test_step = b.step("test", "Run unit tests");
    //test_step.dependOn(&run_unit_tests.step);
}
