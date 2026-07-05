const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const client = @import("client");

const misc = @import("misc.zig");

pub fn drawSetPassword(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    allocator: std.mem.Allocator,
    io: std.Io,
    paned: *dvui.PanedWidget,
    device: *client.Transports.Transport,
    deviceInfo: client.Info,
) !void {
    _ = paned;

    const local = struct {
        var new_password: [64]u8 = .{0} ** 64;
        var verify_new_password: [64]u8 = .{0} ** 64;
        var spinner_active: bool = false;
    };

    var enter_pressed = false;

    var left_alignment = dvui.Alignment.init(@src(), 0);
    defer left_alignment.deinit();

    var inner_vbox = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .width(360.0),
        },
    );
    defer inner_vbox.deinit();

    {
        var hbox = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{ .expand = .horizontal },
        );
        defer hbox.deinit();

        dvui.label(@src(), "New PIN", .{}, .{
            .gravity_y = 0.5,
        });

        left_alignment.spacer(@src(), 0);

        var te = dvui.textEntry(
            @src(),
            .{
                .text = .{ .buffer = &local.new_password },
                .password_char = "*",
            },
            .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .corners = .square,
            },
        );

        // Check if the user pressed enter. We treat this the same as clicking the
        // button below.
        enter_pressed = te.enter_pressed;

        te.deinit();
    }

    {
        var hbox = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{ .expand = .horizontal },
        );
        defer hbox.deinit();

        dvui.label(@src(), "Repeat New PIN", .{}, .{
            .gravity_y = 0.5,
        });

        left_alignment.spacer(@src(), 0);

        var te = dvui.textEntry(
            @src(),
            .{
                .text = .{ .buffer = &local.verify_new_password },
                .password_char = "*",
            },
            .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .corners = .square,
            },
        );

        // Check if the user pressed enter. We treat this the same as clicking the
        // button below.
        enter_pressed = te.enter_pressed;

        te.deinit();
    }

    if (local.spinner_active) {
        dvui.spinner(
            @src(),
            .{
                .color_text = .{ .r = 100, .g = 200, .b = 100 },
                .gravity_x = 0.5,
            },
        );
    } else {
        if (dvui.button(@src(), "Set PIN", .{}, .{
            .expand = .horizontal,
            .corners = .square,
        }) or enter_pressed) blk: {
            const new = misc.getSlice(&local.new_password);
            const new2 = misc.getSlice(&local.verify_new_password);

            if (deviceInfo.minPINLength) |len| {
                if (new.len < len) {
                    dvui.toast(@src(), .{ .window = win, .message = "New PIN too short" });
                    break :blk;
                }
            }

            if (!std.mem.eql(u8, new, new2)) {
                dvui.toast(@src(), .{ .window = win, .message = "PINs don't match" });
                break :blk;
            }

            local.spinner_active = true;

            const bg_thread = std.Thread.spawn(
                .{},
                set_pin,
                .{
                    win,
                    uniqueId,
                    allocator,
                    io,
                    null,
                    new,
                    &local.spinner_active,
                    device,
                    deviceInfo,
                },
            ) catch |err| {
                dvui.log.info(
                    "failed to spawn background thread to unlock database ({any})",
                    .{err},
                );
                break :blk;
            };
            bg_thread.detach();
        }
    }
}

pub fn drawChangePassword(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    allocator: std.mem.Allocator,
    io: std.Io,
    paned: *dvui.PanedWidget,
    device: *client.Transports.Transport,
    deviceInfo: client.Info,
) !void {
    _ = paned;

    const local = struct {
        var old_password: [64]u8 = .{0} ** 64;
        var new_password: [64]u8 = .{0} ** 64;
        var verify_new_password: [64]u8 = .{0} ** 64;
        var spinner_active: bool = false;
    };

    var enter_pressed = false;

    var left_alignment = dvui.Alignment.init(@src(), 0);
    defer left_alignment.deinit();

    var inner_vbox = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .width(360.0),
        },
    );
    defer inner_vbox.deinit();

    {
        var hbox = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{ .expand = .horizontal },
        );
        defer hbox.deinit();

        dvui.label(@src(), "Current PIN", .{}, .{
            .gravity_y = 0.5,
        });

        left_alignment.spacer(@src(), 0);

        var te = dvui.textEntry(
            @src(),
            .{
                .text = .{ .buffer = &local.old_password },
                .password_char = "*",
            },
            .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .corners = .square,
            },
        );
        // Fucus on the password entry
        if (dvui.firstFrame(te.data().id)) {
            dvui.focusWidget(te.data().id, null, null);
        }

        // Check if the user pressed enter. We treat this the same as clicking the
        // button below.
        enter_pressed = te.enter_pressed;

        te.deinit();
    }

    {
        var hbox = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{ .expand = .horizontal },
        );
        defer hbox.deinit();

        dvui.label(@src(), "New PIN", .{}, .{
            .gravity_y = 0.5,
        });

        left_alignment.spacer(@src(), 0);

        var te = dvui.textEntry(
            @src(),
            .{
                .text = .{ .buffer = &local.new_password },
                .password_char = "*",
            },
            .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .corners = .square,
            },
        );

        // Check if the user pressed enter. We treat this the same as clicking the
        // button below.
        enter_pressed = te.enter_pressed;

        te.deinit();
    }

    {
        var hbox = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{ .expand = .horizontal },
        );
        defer hbox.deinit();

        dvui.label(@src(), "Repeat New PIN", .{}, .{
            .gravity_y = 0.5,
        });

        left_alignment.spacer(@src(), 0);

        var te = dvui.textEntry(
            @src(),
            .{
                .text = .{ .buffer = &local.verify_new_password },
                .password_char = "*",
            },
            .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .corners = .square,
            },
        );

        // Check if the user pressed enter. We treat this the same as clicking the
        // button below.
        enter_pressed = te.enter_pressed;

        te.deinit();
    }

    if (local.spinner_active) {
        dvui.spinner(
            @src(),
            .{
                .color_text = .{ .r = 100, .g = 200, .b = 100 },
                .gravity_x = 0.5,
            },
        );
    } else {
        if (dvui.button(@src(), "Change PIN", .{}, .{
            .expand = .horizontal,
            .corners = .square,
        }) or enter_pressed) blk: {
            const old = misc.getSlice(&local.old_password);
            const new = misc.getSlice(&local.new_password);
            const new2 = misc.getSlice(&local.verify_new_password);

            if (deviceInfo.minPINLength) |len| {
                if (new.len < len) {
                    dvui.toast(@src(), .{ .window = win, .message = "New PIN too short" });
                    break :blk;
                }
            }

            if (!std.mem.eql(u8, new, new2)) {
                dvui.toast(@src(), .{ .window = win, .message = "PINs don't match" });
                break :blk;
            }

            local.spinner_active = true;

            const bg_thread = std.Thread.spawn(
                .{},
                set_pin,
                .{
                    win,
                    uniqueId,
                    allocator,
                    io,
                    old,
                    new,
                    &local.spinner_active,
                    device,
                    deviceInfo,
                },
            ) catch |err| {
                dvui.log.info(
                    "failed to spawn background thread to unlock database ({any})",
                    .{err},
                );
                break :blk;
            };
            bg_thread.detach();
        }
    }
}

fn set_pin(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    a: std.mem.Allocator,
    io: std.Io,
    curPin: ?[]const u8,
    newPin: []const u8,
    spinner_active: *bool,
    device: *client.Transports.Transport,
    deviceInfo: client.Info,
) void {
    _ = uniqueId;

    defer spinner_active.* = false;

    std.log.info("changing existing PIN", .{});

    if (deviceInfo.options.clientPin == null) {
        std.log.warn("client PIN not supported by authenticator", .{});
        return;
    }

    // Obtain a shared secret from the authenticator.
    if (deviceInfo.pinUvAuthProtocols == null) {
        std.log.err("pinUvAuthProtocols list not provided or empty", .{});
        return;
    }

    const pinUvAuthProtocol = deviceInfo.pinUvAuthProtocols.?[0];

    var shared_secret = client.getKeyAgreement(
        device,
        pinUvAuthProtocol,
        a,
        io,
    ) catch |e| {
        std.log.err("failed to get key agreement key ({any})", .{e});
        return;
    };

    // Change an existing PIN
    if (deviceInfo.options.clientPin.?) {
        if (curPin == null) {
            std.log.err("curPin argument required", .{});
            return;
        }

        var cpr = client.changePin(
            device,
            &shared_secret,
            curPin.?,
            newPin,
            a,
            io,
        ) catch |e| {
            std.log.err("failed to change pin: {any}", .{e});
            return;
        };

        var cp_state = cpr.await(a, io) catch |e| {
            std.log.err("awaiting response failed ({any})", .{e});
            return;
        };
        defer cp_state.deinit(a);

        switch (cp_state) {
            .fulfilled => |data| {
                const status_code = data[0];

                if (status_code != 0) {
                    std.log.err("failed to change pin ({d})", .{status_code});
                    dvui.toast(@src(), .{ .window = win, .message = "Failed to change PIN" });
                    return;
                }
            },
            else => {
                std.log.err("failed to change pin", .{});
                dvui.toast(@src(), .{ .window = win, .message = "Failed to change PIN" });
                return;
            },
        }
    } else { // set a new PIN
        const spr = client.setPin(
            device,
            &shared_secret,
            newPin,
            a,
            io,
        ) catch |e| {
            std.log.err("failed to set pin: {any}", .{e});
            dvui.toast(@src(), .{ .window = win, .message = "Failed to set PIN" });
            return;
        };
        _ = spr;
    }

    dvui.toast(@src(), .{ .window = win, .message = "PIN successfully changed" });
}
