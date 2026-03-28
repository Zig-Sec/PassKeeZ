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

    pub fn name(self: @This()) []const u8 {
        return switch (self) {
            .none => "None",
            .change_password => "Change Password",
        };
    }

    pub fn scaleOffset(self: @This()) struct { scale: f32, offset: dvui.Point } {
        return switch (self) {
            .none => .{ .scale = 0.45, .offset = .{} },
            .change_password => .{ .scale = 0.45, .offset = .{} },
        };
    }
};

var menu_active = MenuKind.none;
var deviceInfo: ?client.Info = null;
var device: ?*client.Transports.Transport = null;

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
    closeDevice(window, uId, gpa);

    //_ = gpa_instance.detectLeaks();
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
    }

    paned.deinit();
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
                    menu_active = .change_password;
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
    const local = struct {
        var transport_labels: ?std.ArrayList([]const u8) = null;
        var transports: ?client.Transports = null;
        var loading_transports: bool = false;
        var choice: ?usize = null;
    };

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

                    closeDevice(win, uniqueId, allocator);

                    const bg_thread = std.Thread.spawn(
                        .{},
                        open_device,
                        .{
                            win,
                            uniqueId,
                            local,
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
                    closeDevice(win, uniqueId, allocator);
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
            dvui.entypo.cycle,
            .{},
            .{},
            .{
                .gravity_y = 0.5,
                .data_out = &ttout,
                .corner_radius = .all(0),
            },
        )) {
            if (!local.loading_transports) blk: {
                closeDevice(win, uniqueId, allocator);

                local.loading_transports = true;

                const bg_thread = std.Thread.spawn(
                    .{},
                    list_available_devices,
                    .{
                        &local.transports,
                        &local.transport_labels,
                        &local.loading_transports,
                        &local.choice,
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
}

pub fn closeDevice(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    allocator: std.mem.Allocator,
) void {
    _ = win;
    _ = uniqueId;

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

fn open_device(
    win: *dvui.Window,
    uniqueId: dvui.Id,
    local: anytype,
    a: std.mem.Allocator,
) void {
    if (local.choice == null) return;

    std.log.info("opening device", .{});

    var device_ = &local.transports.?.devices[local.choice.?];

    device_.open() catch |e| {
        std.log.err("failed to open selected device ({any})", .{e});
        closeDevice(win, uniqueId, a);
        local.choice = null;
        return;
    };

    var info_state_ = client.getInfo(device_) catch |e| {
        std.log.err("failed to obtain device information ({any})", .{e});
        closeDevice(win, uniqueId, a);
        local.choice = null;
        return;
    };

    var info_state = info_state_.await(a) catch |e| {
        std.log.err("failed to obtain device information ({any})", .{e});
        closeDevice(win, uniqueId, a);
        local.choice = null;
        return;
    };
    defer info_state.deinit(a);

    std.log.info("[cbor]: {x}", .{info_state.fulfilled});

    const info = info_state.deserializeCbor(client.Info, a) catch |e| {
        std.log.err("failed to deserialize info CBOR data ({any})", .{e});
        closeDevice(win, uniqueId, a);
        local.choice = null;
        return;
    };

    device = device_;
    deviceInfo = info;
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
