const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const client = @import("client");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 600.0, .h = 900.0 },
            .min_size = .{ .w = 400.0, .h = 600.0 },
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
pub fn AppDeinit() void {}

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

    try loginWidget(uId);

    return .ok;
}

pub fn loginWidget(uniqueId: dvui.Id) !void {
    _ = uniqueId;

    const local = struct {
        var password: [128]u8 = .{0} ** 128;

        var transport_labels: ?std.ArrayList([]const u8) = null;
        var transports: ?client.Transports = null;
        var loading_transports: bool = false;
        var choice: ?usize = null;
        var selected_device: ?*client.Transports.Transport = null;
        var info: ?client.Info = null;

        var spinner_active: bool = false;

        pub fn closeDevice() void {
            if (selected_device) |dev| {
                std.log.info("closing old device", .{});
                dev.close();
                selected_device = null;
            }

            if (info != null) {
                info.?.deinit(gpa);
                info = null;
            }
        }
    };

    var enter_pressed = false;

    // Load list of available devices
    if (local.transports == null and !local.loading_transports) blk: {
        local.loading_transports = true;

        const bg_thread = std.Thread.spawn(
            .{},
            list_available_devices,
            .{
                &local.transports,
                &local.transport_labels,
                &local.loading_transports,
                &local.choice,
                gpa,
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

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer vbox.deinit();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    var left_alignment = dvui.Alignment.init(@src(), 0);
    defer left_alignment.deinit();

    {
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
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hbox.deinit();

            dvui.label(@src(), "Device", .{}, .{ .gravity_y = 0.5 });

            left_alignment.spacer(@src(), 0);

            if (local.transport_labels) |labels| {
                if (dvui.dropdown(
                    @src(),
                    labels.items,
                    .{ .choice_nullable = &local.choice },
                    .{},
                    .{
                        .gravity_y = 0.5,
                        .corner_radius = .all(0),
                        .expand = .horizontal,
                    },
                )) blk: {
                    if (local.choice) |i| {
                        std.log.info("selected device [{d}] '{s}'", .{ i, local.transport_labels.?.items[i] });

                        local.closeDevice();

                        const bg_thread = std.Thread.spawn(
                            .{},
                            open_device,
                            .{
                                &local,
                                gpa,
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
                        local.closeDevice();
                    }
                }
            } else {
                _ = dvui.dropdown(
                    @src(),
                    &.{},
                    .{ .choice_nullable = &local.choice },
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
                dvui.entypo.arrow_with_circle_up,
                .{},
                .{},
                .{
                    .gravity_y = 0.5,
                    .data_out = &ttout,
                    .corner_radius = .all(0),
                },
            )) {
                if (!local.loading_transports) blk: {
                    local.loading_transports = true;

                    const bg_thread = std.Thread.spawn(
                        .{},
                        list_available_devices,
                        .{
                            &local.transports,
                            &local.transport_labels,
                            &local.loading_transports,
                            &local.choice,
                            gpa,
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

        {
            var hbox = dvui.box(
                @src(),
                .{ .dir = .horizontal },
                .{ .expand = .horizontal },
            );
            defer hbox.deinit();

            dvui.label(@src(), "Password", .{}, .{
                .gravity_y = 0.5,
            });

            left_alignment.spacer(@src(), 0);

            var te = dvui.textEntry(
                @src(),
                .{
                    .text = .{ .buffer = &local.password },
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

        if (local.spinner_active) {
            dvui.spinner(
                @src(),
                .{
                    .color_text = .{ .r = 100, .g = 200, .b = 100 },
                    .gravity_x = 0.5,
                },
            );
        } else {
            if (dvui.button(@src(), "connect", .{}, .{
                .expand = .horizontal,
                .corner_radius = .all(0),
            }) or enter_pressed) {
                local.spinner_active = true;

                //const bg_thread = std.Thread.spawn(
                //    .{},
                //    unlock_database_process,
                //    .{
                //        dvui.currentWindow(),
                //        &local.path,
                //        &local.password,
                //        gpa,
                //        uniqueId,
                //        &local.spinner_active,
                //    },
                //) catch |err| {
                //    dvui.log.info(
                //        "failed to spawn background thread to unlock database ({any})",
                //        .{err},
                //    );
                //    break :blk;
                //};
                //bg_thread.detach();
            }
        }
    }
}

fn open_device(
    local: anytype,
    a: std.mem.Allocator,
) void {
    if (local.choice == null) return;

    std.log.info("opening device", .{});

    local.selected_device = &local.transports.?.devices[local.choice.?];

    local.selected_device.?.open() catch |e| {
        std.log.err("failed to open selected device ({any})", .{e});
        local.closeDevice();
        local.choice = null;
        return;
    };

    var info_state_ = client.getInfo(local.selected_device.?) catch |e| {
        std.log.err("failed to obtain device information ({any})", .{e});
        local.closeDevice();
        local.choice = null;
        return;
    };

    var info_state = info_state_.await(a) catch |e| {
        std.log.err("failed to obtain device information ({any})", .{e});
        local.closeDevice();
        local.choice = null;
        return;
    };
    defer info_state.deinit(a);

    std.log.info("[cbor]: {x}", .{info_state.fulfilled});

    local.info = info_state.deserializeCbor(client.Info, a) catch |e| {
        std.log.err("failed to deserialize info CBOR data ({any})", .{e});
        local.closeDevice();
        local.choice = null;
        return;
    };
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
//
//pub fn getSlice(s: []const u8) []const u8 {
//    for (s, 0..) |c, i|
//        if (c == 0) return s[0..i];
//    return s;
//}

test {}
