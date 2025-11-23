const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const keylib_dep = b.dependency("keylib", .{
        .target = target,
        .optimize = optimize,
    });

    const kdbx_dep = b.dependency("kdbx", .{
        .target = target,
        .optimize = optimize,
    });

    const uuid_dep = b.dependency("uuid", .{
        .target = target,
        .optimize = optimize,
    });

    const dvui_dep = b.dependency(
        "dvui",
        .{ .target = target, .optimize = optimize, .backend = .sdl3 },
    );

    const exe = b.addExecutable(.{
        .name = "passkeez",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "keylib", .module = keylib_dep.module("keylib") },
                .{ .name = "uhid", .module = keylib_dep.module("uhid") },
                .{ .name = "zbor", .module = keylib_dep.module("zbor") },
                .{ .name = "kdbx", .module = kdbx_dep.module("kdbx") },
                .{ .name = "uuid", .module = uuid_dep.module("uuid") },
            },
        }),
    });
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

    const manager_exe = b.addExecutable(.{
        .name = "passkeez-gui",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/gui.zig"),
            .imports = &.{
                .{ .name = "kdbx", .module = kdbx_dep.module("kdbx") },
                .{ .name = "uuid", .module = uuid_dep.module("uuid") },
                .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
            },
        }),
    });
    const install_step = b.addInstallArtifact(manager_exe, .{});
    const manager_step = b.step("manager", "Compile the PassKeeZ password manager GUI application");
    manager_step.dependOn(&install_step.step);
}
