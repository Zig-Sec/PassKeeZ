const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const kdbx = @import("kdbx");
const Config = @import("Config.zig");

const EntryTable = @import("gui/EntryTable.zig");

pub var config: Config = undefined;

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
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
    // Load configuration
    config = try Config.load(gpa);

    orig_content_scale = win.content_scale;
    //try dvui.addFont("NOTO", @embedFile("../src/fonts/NotoSansKR-Regular.ttf"), null);

    if (false) {
        // If you need to set a theme based on the users preferred color scheme, do it here
        win.theme = switch (win.backend.preferredColorScheme() orelse .light) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        };
    }

    uId = dvui.parentGet().extendId(@src(), 0);
    window = dvui.currentWindow();
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn AppDeinit() void {
    close_database(window, uId);
    config.deinit(gpa);
}

// Run each frame to do normal UI
pub fn AppFrame() !dvui.App.Result {
    return frame();
}

pub fn frame() !dvui.App.Result {
    var scaler = dvui.scale(@src(), .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global }, .{ .rect = .cast(dvui.windowRect()) });
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
                .color_fill = .fromHex("373737"),
            },
        );
        defer m.deinit();

        if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .tag = "first-focusable" })) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();

            if (dvui.menuItemLabel(@src(), "New Database", .{}, .{ .expand = .horizontal }) != null) {}

            if (dvui.menuItemLabel(@src(), "Open Database", .{}, .{ .expand = .horizontal }) != null) {}

            _ = dvui.separator(@src(), .{});

            if (dvui.dataGetPtr(null, uId, "database", kdbx.Database) != null) {
                if (dvui.menuItemLabel(
                    @src(),
                    "Close Database",
                    .{},
                    .{
                        .expand = .horizontal,
                    },
                ) != null) {
                    close_database(window, uId);
                }
            }

            if (dvui.backend.kind != .web) {
                if (dvui.menuItemLabel(@src(), "Exit", .{}, .{ .expand = .horizontal }) != null) {
                    return .close;
                }
            }
        }
    }

    if (dvui.dataGetPtr(null, uId, "database", kdbx.Database) != null) {
        var outer_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer outer_hbox.deinit();

        try sidePannel(uId);

        {
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
            defer scroll.deinit();

            // TODO: put here the main element
            EntryTable.draw(uId);
        }

        // Those window functions will return if the show window flag is not set
    } else {
        try loginWidget(uId);
    }

    return .ok;
}

pub fn sidePannel(uniqueId: dvui.Id) !void {
    const icon_color: dvui.Color = .{ .r = 0x3c, .g = 0xa3, .b = 0x70, .a = 0xff };

    const recursor = struct {
        fn search(
            group: *kdbx.Group,
            tree: *dvui.TreeWidget,
            uid: dvui.Id,
            branch_options: dvui.Options,
            expander_options: dvui.Options,
        ) !void {
            var id_extra: usize = 0;
            for (group.groups.items) |*inner_group| {
                id_extra += 1;

                var branch_opts_override = dvui.Options{
                    .id_extra = id_extra,
                    .expand = .horizontal,
                };

                const color = icon_color;

                const branch = tree.branch(@src(), .{
                    .expanded = false,
                }, branch_opts_override.override(branch_options));
                defer branch.deinit();

                _ = dvui.icon(
                    @src(),
                    "FolderIcon",
                    dvui.entypo.folder,
                    .{
                        .fill_color = icon_color,
                    },
                    .{
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(4),
                    },
                );
                dvui.label(@src(), "{s}", .{inner_group.name}, .{
                    .color_text = dvui.themeGet().color(.control, .text),
                    .padding = dvui.Rect.all(4),
                });
                _ = dvui.icon(
                    @src(),
                    "DropIcon",
                    if (branch.expanded) dvui.entypo.triangle_down else dvui.entypo.triangle_right,
                    .{ .fill_color = icon_color },
                    .{
                        .gravity_y = 0.5,
                        .gravity_x = 1.0,
                        .padding = dvui.Rect.all(4),
                    },
                );

                var expander_opts_override = dvui.Options{
                    .margin = .{ .x = 14 },
                    .color_border = color,
                    .expand = .horizontal,
                };

                if (branch.expander(@src(), .{ .indent = 14 }, expander_opts_override.override(expander_options))) {
                    try search(
                        inner_group,
                        tree,
                        uid,
                        branch_options,
                        expander_options,
                    );
                }
            }
        }
    }.search;

    const bopts: dvui.Options = .{
        .margin = dvui.Rect.all(1),
        .padding = dvui.Rect.all(2),
    };
    const eopts: dvui.Options = .{
        .border = .{ .x = 1 },
        .corner_radius = dvui.Rect.all(4),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -5, .y = 5 },
            .shrink = 5,
            .fade = 10,
            .alpha = 0.15,
        },
    };

    var outer_vbox = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 250 },
        .max_size_content = .size(.{ .w = 250 }),
        .expand = .vertical,
        .border = dvui.Rect.all(1),
        .gravity_x = 0.0,
    });
    defer outer_vbox.deinit();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    if (dvui.dataGetPtr(null, uniqueId, "database", kdbx.Database)) |db| {
        var tree = dvui.TreeWidget.tree(
            @src(),
            .{},
            .{ .expand = .horizontal },
        );
        defer tree.deinit();

        { // Root is always expanded
            const branch = tree.branch(
                @src(),
                .{
                    .expanded = true,
                },
                .{ .expand = .horizontal },
            );
            defer branch.deinit();

            _ = dvui.icon(
                @src(),
                "FileIcon",
                dvui.entypo.folder,
                .{ .fill_color = icon_color },
                .{
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(4),
                },
            );
            dvui.label(@src(), "{s}", .{"Root"}, .{
                .color_text = dvui.themeGet().color(.control, .text),
                .padding = dvui.Rect.all(4),
            });
            _ = dvui.icon(
                @src(),
                "DropIcon",
                if (branch.expanded) dvui.entypo.triangle_down else dvui.entypo.triangle_right,
                .{
                    .fill_color = icon_color,
                },
                .{
                    .gravity_y = 0.5,
                    .gravity_x = 1.0,
                    .padding = dvui.Rect.all(4),
                },
            );

            if (branch.expander(
                @src(),
                .{ .indent = 14.0 },
                .{
                    .color_fill = dvui.themeGet().color(.window, .fill),
                    .color_border = icon_color,
                    .expand = .horizontal,
                    .corner_radius = branch.button.wd.options.corner_radius,
                    .background = true,
                    .border = .{ .x = 1 },
                    .box_shadow = .{
                        .color = .black,
                        .offset = .{ .x = -5, .y = 5 },
                        .shrink = 5,
                        .fade = 10,
                        .alpha = 0.15,
                    },
                },
            )) {
                try recursor(
                    &db.body.root,
                    tree,
                    uniqueId,
                    bopts,
                    eopts,
                );
            }
        }
    }
}

pub fn loginWidget(uniqueId: dvui.Id) !void {
    const local = struct {
        var password: [128]u8 = .{0} ** 128;
        var path: [256]u8 = .{0} ** 256;
        var spinner_active: bool = false;

        pub fn setPath(p: []const u8) void {
            @memset(&path, 0);
            @memcpy(path[0..p.len], p);
        }

        pub fn setPw(p: []const u8) void {
            std.crypto.secureZero(u8, &password);
            @memcpy(password[0..p.len], p);
        }

        var first: bool = true;

        pub fn setTestData() void {}
    };

    if (local.first) {
        local.first = false;
        local.setTestData();
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

            dvui.label(@src(), "Path", .{}, .{ .gravity_y = 0.5 });

            left_alignment.spacer(@src(), 0);

            var te = dvui.textEntry(
                @src(),
                .{ .text = .{ .buffer = &local.path } },
                .{
                    .expand = .horizontal,
                },
            );
            te.deinit();

            var ttout: dvui.WidgetData = undefined;
            if (dvui.buttonIcon(
                @src(),
                "folder",
                dvui.entypo.folder,
                .{},
                .{},
                .{
                    .gravity_y = 0.5,
                    .data_out = &ttout,
                },
            )) {
                const filename = dvui.dialogNativeFileOpen(
                    dvui.currentWindow().arena(),
                    .{ .title = "Select Database File" },
                ) catch |err| blk: {
                    dvui.log.debug("unable to select file ({any})", .{err});
                    break :blk null;
                };
                if (filename) |f| {
                    local.setPath(f);
                }
            }
            dvui.tooltip(
                @src(),
                .{ .active_rect = ttout.borderRectScale().r },
                "Select a database file",
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
                },
            );
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
            if (dvui.button(@src(), "unlock", .{}, .{
                .expand = .horizontal,
            })) blk: {
                local.spinner_active = true;

                const bg_thread = std.Thread.spawn(
                    .{},
                    unlock_database_process,
                    .{
                        dvui.currentWindow(),
                        &local.path,
                        &local.password,
                        gpa,
                        uniqueId,
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
}

fn close_database(
    win: ?*dvui.Window,
    uniqueId: dvui.Id,
) void {
    if (dvui.dataGetPtr(win, uniqueId, "database", kdbx.Database)) |database| {
        database.deinit();
        dvui.dataRemove(win, uniqueId, "database");
    }
}

fn unlock_database_process(
    win: *dvui.Window,
    path_: []const u8,
    pw_: []u8,
    a: std.mem.Allocator,
    uniqueId: dvui.Id,
    spinner_active: *bool,
) void {
    defer spinner_active.* = false;
    defer std.crypto.secureZero(u8, pw_);

    const path = getSlice(path_);
    const pw = getSlice(pw_);

    var f = std.fs.openFileAbsolute(path, .{}) catch {
        dvui.log.info(
            "unable to open database file '{s}'",
            .{path},
        );
        return;
    };
    defer f.close();

    var buffer: [1024]u8 = undefined;
    var reader = f.reader(&buffer);

    const key = kdbx.DatabaseKey{
        .password = a.dupe(u8, getSlice(pw)) catch return,
        .allocator = a,
    };
    defer key.deinit();

    const database = kdbx.Database.open(&reader.interface, .{
        .allocator = a,
        .key = key,
    }) catch |e| {
        dvui.log.info(
            "unable to unlock database '{s}' ({any})",
            .{ path, e },
        );
        dvui.toast(@src(), .{ .window = win, .message = "Unlocking the database failed.\nDid you provide the correct password?" });
        return;
    };

    dvui.dataSet(win, uniqueId, "database", database);

    const root_ptr = &dvui.dataGetPtr(win, uniqueId, "database", kdbx.Database).?.body.root;
    dvui.dataSet(win, uniqueId, "group", root_ptr);

    dvui.toast(@src(), .{ .window = win, .message = "Database unlocked successfully" });
}

pub fn getSlice(s: []const u8) []const u8 {
    for (s, 0..) |c, i|
        if (c == 0) return s[0..i];
    return s;
}

test {}
