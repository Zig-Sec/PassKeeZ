const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const client = @import("client");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 600.0, .h = 900.0 },
            .min_size = .{ .w = 400.0, .h = 600.0 },
            .max_size = .{ .w = 800.0, .h = 1200.0 },
            .title = "PassKeeZ",
            .window_init_options = .{
                // Could set a default theme here
                // .theme = dvui.Theme.builtin.dracula,
            },
        },
    },
    .frameFn = AppFrame,
    .initFn = AppInit,
    .deinitFn = AppDeinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

var orig_content_scale: f32 = 1.0;

var uId: dvui.Id = undefined;
var window: *dvui.Window = undefined;

pub const MenuKind = enum {
    none,
    change_password,
    set_password,

    pub fn name(self: @This()) []const u8 {
        return switch (self) {
            .none => "None",
            .change_password => "Change Password",
            .set_password => "Set Password",
        };
    }
};

var menu_active = MenuKind.none;
var deviceInfo: ?client.Info = null;
var device: ?*client.Transports.Transport = null;

const transport = struct {
    var transport_labels: ?std.ArrayList([]const u8) = null;
    var transports: ?client.Transports = null;
    var loading_transports: bool = false;
    var choice: ?usize = null;

    pub fn reset(a: std.mem.Allocator) void {
        if (transport_labels) |*t| {
            for (t.items) |i| a.free(i);
            t.deinit(a);
        }
        transport_labels = null;

        if (transports) |t| {
            t.deinit();
        }
        transports = null;

        choice = null;
    }
};

// Runs before the first frame, after backend and dvui.Window.init()
// - runs between win.begin()/win.end()
pub fn AppInit(win: *dvui.Window) !void {
    orig_content_scale = win.content_scale;

    //if (false) {
    //    // If you need to set a theme based on the users preferred color scheme, do it here
    //    win.theme = switch (win.backend.preferredColorScheme() orelse .light) {
    //        .light => dvui.Theme.builtin.adwaita_light,
    //        .dark => dvui.Theme.builtin.adwaita_dark,
    //    };
    //}

    uId = dvui.parentGet().extendId(@src(), 0);
    window = dvui.currentWindow();
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn AppDeinit() void {
    closeDevice(gpa);
    transport.reset(gpa);

    _ = gpa_instance.detectLeaks();
}

// Run each frame to do normal UI
pub fn AppFrame() !dvui.App.Result {
    return frame();
}

pub fn frame() !dvui.App.Result {
    var scaler = dvui.scale(
        @src(),
        .{
            .scale = &dvui.currentWindow().content_scale,
            .pinch_zoom = .global,
        },
        .{
            .rect = .cast(dvui.windowRect()),
        },
    );
    scaler.deinit();

    {
        var hbox = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{
                .style = .window,
                .background = true,
                .expand = .horizontal,
            },
        );
        defer hbox.deinit();

        var m = dvui.menu(
            @src(),
            .horizontal,
            .{
                .expand = .horizontal,
                .background = true,
                //.color_fill = .fromHex("373737"),
            },
        );
        defer m.deinit();

        if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .tag = "first-focusable" })) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();

            if (dvui.menuItemLabel(@src(), "Disconnect", .{}, .{ .expand = .horizontal }) != null) {}
        }
    }

    try loginWidget(window, uId, gpa);

    return .ok;
}

pub fn loginWidget(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    allocator: std.mem.Allocator,
) !void {
    var paned = dvui.paned(@src(), .{ .direction = .horizontal, .collapsed_size = 1200 }, .{ .expand = .both, .background = false });

    if (paned.showFirst()) {
        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer vbox.deinit();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
        defer scroll.deinit();

        try drawDeviceSelectorWidget(
            win,
            uniqueId,
            allocator,
        );

        try drawDeviceInfo(
            window,
            uniqueId,
            allocator,
            paned,
        );
    }

    if (paned.showSecond()) {
        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer vbox.deinit();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
        defer scroll.deinit();

        if (paned.collapsed() and dvui.button(@src(), "Back", .{}, .{ .min_size_content = .{ .h = 30 } })) {
            paned.animateSplit(1.0);
        }

        switch (menu_active) {
            .change_password => try drawChangePassword(win, uniqueId, allocator, paned),
            .set_password => try drawSetPassword(win, uniqueId, allocator, paned),
            .none => {},
        }
    }

    paned.deinit();
}

fn drawSetPassword(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    allocator: std.mem.Allocator,
    paned: *dvui.PanedWidget,
) !void {
    _ = allocator;
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
                .corner_radius = .all(0),
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
                .corner_radius = .all(0),
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
            .corner_radius = .all(0),
        }) or enter_pressed) blk: {
            const new = getSlice(&local.new_password);
            const new2 = getSlice(&local.verify_new_password);

            if (deviceInfo.?.minPINLength) |len| {
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
                    gpa,
                    null,
                    new,
                    &local.spinner_active,
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

fn drawChangePassword(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    allocator: std.mem.Allocator,
    paned: *dvui.PanedWidget,
) !void {
    _ = allocator;
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
                .corner_radius = .all(0),
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
                .corner_radius = .all(0),
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
                .corner_radius = .all(0),
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
            .corner_radius = .all(0),
        }) or enter_pressed) blk: {
            const old = getSlice(&local.old_password);
            const new = getSlice(&local.new_password);
            const new2 = getSlice(&local.verify_new_password);

            if (deviceInfo.?.minPINLength) |len| {
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
                    gpa,
                    old,
                    new,
                    &local.spinner_active,
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

fn drawDeviceInfo(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    allocator: std.mem.Allocator,
    paned: *dvui.PanedWidget,
) !void {
    _ = win;
    _ = uniqueId;
    _ = allocator;

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

    if (deviceInfo) |info| {
        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hbox.deinit();

            dvui.label(@src(), "AAGUID:", .{}, .{});

            left_alignment.spacer(@src(), 0);

            dvui.label(@src(), "{x}", .{&info.aaguid}, .{});
        }

        if (info.options.clientPin) |cp| {
            {
                var gbox = dvui.groupBox(@src(), "Password Settings", .{ .expand = .horizontal });
                defer gbox.deinit();

                var left_alignment2 = dvui.Alignment.init(@src(), 0);
                defer left_alignment2.deinit();

                {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = .{ .x = 10 } });
                    defer hbox.deinit();

                    dvui.label(@src(), "PIN set:", .{}, .{});

                    left_alignment2.spacer(@src(), 0);

                    dvui.label(@src(), "{any}", .{cp}, .{});
                }

                if (info.minPINLength) |len| {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = .{ .x = 10 } });
                    defer hbox.deinit();

                    dvui.label(@src(), "Minimum PIN length", .{}, .{});

                    left_alignment2.spacer(@src(), 0);

                    dvui.label(@src(), "{d}", .{len}, .{});
                }

                {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = .{ .x = 10 } });
                    defer hbox.deinit();

                    if (info.forcePINChange != null and info.forcePINChange.?) {
                        dvui.label(@src(), "forcePINChange", .{}, .{});
                    }
                }

                if (dvui.button(
                    @src(),
                    if (cp) "Change PIN" else "Set PIN",
                    .{},
                    .{
                        .expand = .horizontal,
                    },
                )) {
                    if (cp) {
                        menu_active = .change_password;
                    } else {
                        menu_active = .set_password;
                    }

                    if (paned.collapsed()) {
                        paned.animateSplit(0.0);
                    }
                }
            }
        }
    }
}

fn drawDeviceSelectorWidget(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    allocator: std.mem.Allocator,
) !void {

    // Load list of available devices
    if (transport.transports == null and !transport.loading_transports) blk: {
        transport.loading_transports = true;

        const bg_thread = std.Thread.spawn(
            .{},
            list_available_devices,
            .{
                &transport.transports,
                &transport.transport_labels,
                &transport.loading_transports,
                &transport.choice,
                allocator,
            },
        ) catch |err| {
            dvui.log.err(
                "failed to spawn background thread to list devices ({any})",
                .{err},
            );
            break :blk;
        };
        bg_thread.detach();
    }

    var left_alignment = dvui.Alignment.init(@src(), 0);
    defer left_alignment.deinit();

    var inner_vbox = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .gravity_x = 0.5,
            .min_size_content = .width(360.0),
        },
    );
    defer inner_vbox.deinit();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Device", .{}, .{ .gravity_y = 0.5 });

        left_alignment.spacer(@src(), 0);

        if (transport.transport_labels) |labels| {
            if (dvui.dropdown(
                @src(),
                labels.items,
                .{ .choice_nullable = &transport.choice },
                .{},
                .{
                    .gravity_y = 0.5,
                    .corner_radius = .all(0),
                    .expand = .horizontal,
                },
            )) blk: {
                if (transport.choice) |i| {
                    std.log.info("selected device [{d}] '{s}'", .{ i, transport.transport_labels.?.items[i] });

                    closeDevice(allocator);

                    const bg_thread = std.Thread.spawn(
                        .{},
                        open_device,
                        .{
                            win,
                            uniqueId,
                            transport,
                            allocator,
                        },
                    ) catch |err| {
                        dvui.log.err(
                            "failed to spawn background thread to open device ({any})",
                            .{err},
                        );
                        break :blk;
                    };
                    bg_thread.detach();
                } else {
                    std.log.info("deselected device", .{});
                    closeDevice(allocator);
                }
            }
        } else {
            _ = dvui.dropdown(
                @src(),
                &.{},
                .{ .choice_nullable = &transport.choice },
                .{},
                .{
                    .gravity_y = 0.5,
                    .corner_radius = .all(0),
                    .expand = .horizontal,
                },
            );
        }

        var ttout: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(
            @src(),
            "refresh",
            dvui.entypo.cycle,
            .{},
            .{},
            .{
                .gravity_y = 0.5,
                .data_out = &ttout,
                .corner_radius = .all(0),
            },
        )) {
            if (!transport.loading_transports) blk: {
                closeDevice(allocator);

                transport.loading_transports = true;

                const bg_thread = std.Thread.spawn(
                    .{},
                    list_available_devices,
                    .{
                        &transport.transports,
                        &transport.transport_labels,
                        &transport.loading_transports,
                        &transport.choice,
                        allocator,
                    },
                ) catch |err| {
                    dvui.log.err(
                        "failed to spawn background thread to list devices ({any})",
                        .{err},
                    );
                    break :blk;
                };
                bg_thread.detach();
            }
        }
        dvui.tooltip(
            @src(),
            .{ .active_rect = ttout.borderRectScale().r },
            "Update list of available devices",
            .{},
            .{},
        );
    }

    if (device != null and deviceInfo == null) {
        if (dvui.button(
            @src(),
            "Open Authenticator",
            .{},
            .{
                .expand = .horizontal,
            },
        )) blk: {
            const bg_thread = std.Thread.spawn(
                .{},
                get_device_info,
                .{
                    win,
                    uniqueId,
                    transport,
                    gpa,
                },
            ) catch |err| {
                dvui.log.info(
                    "failed to spawn background thread to open authenticator ({any})",
                    .{err},
                );
                break :blk;
            };
            bg_thread.detach();
        }

        if (dvui.button(
            @src(),
            "Reset Authenticator",
            .{},
            .{
                .gravity_y = 1.0,
                .expand = .horizontal,
            },
        )) blk: {
            const bg_thread = std.Thread.spawn(
                .{},
                reset,
                .{
                    win,
                    uniqueId,
                    gpa,
                },
            ) catch |err| {
                dvui.log.info(
                    "failed to spawn background thread to reset authenticator ({any})",
                    .{err},
                );
                break :blk;
            };
            bg_thread.detach();
        }
    }
}

pub fn closeDevice(
    allocator: std.mem.Allocator,
) void {
    if (device) |dev| {
        std.log.info("closing old device", .{});
        dev.close();
    }
    device = null;

    if (deviceInfo) |info| {
        std.log.info("deallocating device info", .{});
        info.deinit(allocator);
    }
    deviceInfo = null;
}

fn reset(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    a: std.mem.Allocator,
) void {
    _ = uniqueId;

    if (device == null) {
        std.log.err("reset called despite 'device' being 'null'", .{});
        return;
    }

    var promise = client.reset(device.?, 10000) catch |e| {
        std.log.err("failed to send reset command {any}", .{e});
        dvui.toast(@src(), .{ .window = win, .message = "Device reset failed" });
        return;
    };

    while (true) {
        const state = promise.get(a);
        defer state.deinit(a);

        switch (state) {
            .pending => |p| {
                switch (p) {
                    .processing => std.log.info("processing", .{}),
                    .user_presence => std.log.info("user presence", .{}),
                    .waiting => std.log.info("waiting", .{}),
                }
            },
            .fulfilled => {
                closeDevice(a);
                transport.reset(a);

                dvui.toast(@src(), .{ .window = win, .message = "Device successfully reset" });
                break;
            },
            .rejected => |e| {
                std.log.err("{any}", .{e});
                dvui.toast(@src(), .{ .window = win, .message = "Device reset rejected" });
                break;
            },
        }
    }
}

fn set_pin(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    a: std.mem.Allocator,
    curPin: ?[]const u8,
    newPin: []const u8,
    spinner_active: *bool,
) void {
    _ = uniqueId;

    defer spinner_active.* = false;

    std.log.info("changing existing PIN", .{});

    if (device == null) {
        std.log.err("set_pin called despite 'device' being 'null'", .{});
        return;
    }

    if (deviceInfo.?.options.clientPin == null) {
        std.log.warn("client PIN not supported by authenticator", .{});
        return;
    }

    // Obtain a shared secret from the authenticator.
    if (deviceInfo.?.pinUvAuthProtocols == null) {
        std.log.err("pinUvAuthProtocols list not provided or empty", .{});
        return;
    }

    const pinUvAuthProtocol = deviceInfo.?.pinUvAuthProtocols.?[0];

    var shared_secret = client.getKeyAgreement(
        device.?,
        pinUvAuthProtocol,
        a,
    ) catch |e| {
        std.log.err("failed to get key agreement key ({any})", .{e});
        return;
    };

    // Change an existing PIN
    if (deviceInfo.?.options.clientPin.?) {
        if (curPin == null) {
            std.log.err("curPin argument required", .{});
            return;
        }

        var cpr = client.changePin(
            device.?,
            &shared_secret,
            curPin.?,
            newPin,
            a,
        ) catch |e| {
            std.log.err("failed to change pin: {any}", .{e});
            return;
        };

        var cp_state = cpr.await(a) catch |e| {
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
            device.?,
            &shared_secret,
            newPin,
            a,
        ) catch |e| {
            std.log.err("failed to set pin: {any}", .{e});
            dvui.toast(@src(), .{ .window = win, .message = "Failed to set PIN" });
            return;
        };
        _ = spr;
    }

    dvui.toast(@src(), .{ .window = win, .message = "PIN successfully changed" });
}

fn get_device_info(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    local: anytype,
    a: std.mem.Allocator,
) void {
    _ = win;
    _ = uniqueId;

    if (device == null) {
        std.log.err("expected open device", .{});
        return;
    }

    var info_state_ = client.getInfo(device.?) catch |e| {
        std.log.err("failed to obtain device information ({any})", .{e});
        closeDevice(a);
        local.choice = null;
        return;
    };

    var info_state = info_state_.await(a) catch |e| {
        std.log.err("failed to obtain device information ({any})", .{e});
        closeDevice(a);
        local.choice = null;
        return;
    };
    defer info_state.deinit(a);

    std.log.info("[cbor]: {x}", .{info_state.fulfilled});

    const info = info_state.deserializeCbor(client.Info, a) catch |e| {
        std.log.err("failed to deserialize info CBOR data ({any})", .{e});
        closeDevice(a);
        local.choice = null;
        return;
    };

    deviceInfo = info;
}

fn open_device(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    local: anytype,
    a: std.mem.Allocator,
) void {
    _ = win;
    _ = uniqueId;

    if (local.choice == null) return;

    std.log.info("opening device", .{});

    var device_ = &local.transports.?.devices[local.choice.?];

    device_.open() catch |e| {
        std.log.err("failed to open selected device ({any})", .{e});
        closeDevice(a);
        local.choice = null;
        return;
    };

    device = device_;
}

fn list_available_devices(
    transports: *?client.Transports,
    transport_labels: *?std.ArrayListUnmanaged([]const u8),
    loading_transports: *bool,
    choice: *?usize,
    a: std.mem.Allocator,
) void {
    defer {
        loading_transports.* = false;
        choice.* = null;
    }

    std.log.info("enumerating available FIDO devices", .{});

    const t = client.Transports.enumerate(
        a,
        .{},
    ) catch |e| {
        std.log.err("enumerating available devices failed ({any})", .{e});
        return;
    };

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (t.devices) |*dev| {
        var s = dev.allocPrint(a) catch |e| {
            t.deinit();
            for (list.items) |item| a.free(item);
            list.deinit(a);

            std.log.err("failed to alloc device label ({any})", .{e});
            return;
        };

        std.log.info("{s}", .{s});

        if (std.unicode.utf8ValidateSlice(s)) {
            var s2 = std.Io.Writer.Allocating.init(a);
            var writer = &s2.writer;
            var view = std.unicode.Utf8View.init(s) catch unreachable; // we have already checked that it's valid utf8
            var iter = view.iterator();

            while (iter.nextCodepoint()) |i| {
                const b = @as(u8, @intCast(i & 0xff));

                if (b != 0) {
                    writer.writeByte(b) catch {
                        t.deinit();
                        for (list.items) |item| a.free(item);
                        list.deinit(a);
                        a.free(s);
                        s2.deinit();
                        return;
                    };
                }
            }

            const s2_ = s2.toOwnedSlice() catch {
                t.deinit();
                for (list.items) |item| a.free(item);
                list.deinit(a);
                a.free(s);
                s2.deinit();
                return;
            };

            a.free(s);
            s = s2_;
        }

        if (s.len > 29) {
            var buffer: [32]u8 = .{0} ** 32;
            @memcpy(buffer[0..29], s[0..29]);
            @memcpy(buffer[29..], "...");

            const s3 = a.dupe(u8, buffer[0..]) catch {
                t.deinit();
                for (list.items) |item| a.free(item);
                list.deinit(a);
                a.free(s);
                return;
            };

            a.free(s);
            s = s3;
        }

        list.append(a, s) catch |e| {
            t.deinit();
            for (list.items) |item| a.free(item);
            list.deinit(a);

            std.log.err("failed to append device label ({any})", .{e});
            return;
        };
    }

    std.log.info("{d} devices available", .{t.devices.len});

    if (transports.* != null) {
        std.log.info("deallocating old device list", .{});
        transports.*.?.deinit();
    }

    if (transport_labels.* != null) {
        for (transport_labels.*.?.items) |item| a.free(item);
        transport_labels.*.?.deinit(a);
    }

    std.log.info("assigning new device list", .{});
    transports.* = t;
    transport_labels.* = list;
}

//fn unlock_database_process(
//    win: *dvui.Window,
//    path_: []const u8,
//    pw_: []u8,
//    a: std.mem.Allocator,
//    uniqueId: dvui.Id,
//    spinner_active: *bool,
//) void {
//    defer spinner_active.* = false;
//    defer std.crypto.secureZero(u8, pw_);
//
//    const path = getSlice(path_);
//    const pw = getSlice(pw_);
//
//    var f = std.fs.openFileAbsolute(path, .{}) catch {
//        dvui.log.info(
//            "unable to open database file '{s}'",
//            .{path},
//        );
//        return;
//    };
//    defer f.close();
//
//    var buffer: [1024]u8 = undefined;
//    var reader = f.reader(&buffer);
//
//    const key = kdbx.DatabaseKey{
//        .password = a.dupe(u8, getSlice(pw)) catch return,
//        .allocator = a,
//    };
//    defer key.deinit();
//
//    const database = kdbx.Database.open(&reader.interface, .{
//        .allocator = a,
//        .key = key,
//    }) catch |e| {
//        dvui.log.info(
//            "unable to unlock database '{s}' ({any})",
//            .{ path, e },
//        );
//        dvui.toast(@src(), .{ .window = win, .message = "Unlocking the database failed.\nDid you provide the correct password?" });
//        return;
//    };
//
//    dvui.dataSet(win, uniqueId, "database", database);
//
//    const root_ptr = &dvui.dataGetPtr(win, uniqueId, "database", kdbx.Database).?.body.root;
//    dvui.dataSet(win, uniqueId, "group", root_ptr);
//
//    dvui.toast(@src(), .{ .window = win, .message = "Database unlocked successfully" });
//}

pub fn getSlice(s: []const u8) []const u8 {
    for (s, 0..) |c, i|
        if (c == 0) return s[0..i];
    return s;
}

test {}
