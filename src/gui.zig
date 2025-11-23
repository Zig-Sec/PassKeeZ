const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const kdbx = @import("kdbx");
const Config = @import("Config.zig");

var config: Config = undefined;
var database: ?kdbx.Database = null;

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
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn AppDeinit() void {
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

            if (dvui.backend.kind != .web) {
                if (dvui.menuItemLabel(@src(), "Exit", .{}, .{ .expand = .horizontal }) != null) {
                    return .close;
                }
            }
        }
    }

    if (database) |db| {
        _ = db;

        var outer_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer outer_hbox.deinit();

        try sidePannel();

        {
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
            defer scroll.deinit();

            // TODO: put here the main element
        }

        // Those window functions will return if the show window flag is not set
    } else {
        try loginWidget();
    }

    return .ok;
}

pub fn sidePannel() !void {
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
}

pub fn loginWidget() !void {
    const local = struct {
        var password: [128]u8 = .{0} ** 128;
        var path: [256]u8 = .{0} ** 256;
        var spinner_active: bool = false;

        pub fn setPath(p: []const u8) void {
            @memset(&path, 0);
            @memcpy(path[0..p.len], p);
        }
    };

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

            if (dvui.button(@src(), "Select File", .{}, .{})) {
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
                //var f = std.fs.openFileAbsolute(getSlice(&local.path), .{}) catch {
                //    dvui.log.info(
                //        "unable to open database file '{s}'",
                //        .{getSlice(&local.path)},
                //    );
                //    break :blk;
                //};
                //defer f.close();

                //var buffer: [1024]u8 = undefined;
                //var reader = f.reader(&buffer);

                //const key = kdbx.DatabaseKey{
                //    .password = try gpa.dupe(u8, getSlice(&local.password)),
                //    .allocator = gpa,
                //};
                //defer key.deinit();

                //const db = kdbx.Database.open(&reader.interface, .{
                //    .allocator = gpa,
                //    .key = key,
                //}) catch |e| {
                //    dvui.log.info(
                //        "unable to unlock database '{s}' ({any})",
                //        .{ getSlice(&local.path), e },
                //    );
                //    break :blk;
                //};

                //database = db;

                local.spinner_active = true;

                const bg_thread = std.Thread.spawn(
                    .{},
                    unlock_database_process,
                    .{
                        dvui.currentWindow(),
                        getSlice(&local.path),
                        getSlice(&local.password),
                        &database,
                        gpa,
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

fn unlock_database_process(
    win: *dvui.Window,
    path: []const u8,
    pw: []const u8,
    db: *?kdbx.Database,
    a: std.mem.Allocator,
    spinner_active: *bool,
) void {
    defer spinner_active.* = false;
    //_ = spinner_active;
    _ = win;

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

    db.* = kdbx.Database.open(&reader.interface, .{
        .allocator = a,
        .key = key,
    }) catch |e| {
        dvui.log.info(
            "unable to unlock database '{s}' ({any})",
            .{ path, e },
        );
        return;
    };
}

pub fn getSlice(s: []const u8) []const u8 {
    for (s, 0..) |c, i|
        if (c == 0) return s[0..i];
    return s;
}

test {}
