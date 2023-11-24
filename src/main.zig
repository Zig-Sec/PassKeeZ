const std = @import("std");
const tresor = @import("tresor");
const keylib = @import("keylib");
const cbor = @import("zbor");
const uhid = @import("uhid");
const dvui = @import("dvui");
const Backend = @import("SDLBackend");
const db = @import("db.zig");
const style = @import("style.zig");
const application_state = @import("state.zig");
const gui = @import("gui.zig");

const window_icon_png = @embedFile("static/passkeez.png");

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
pub const gpa = gpa_instance.allocator();

const vsync = true;

var win: dvui.Window = undefined;

/// This example shows how to use the dvui for a normal application:
/// - dvui renders the whole application
/// - render frames only when needed
pub fn main() !void {

    // //////////////////////////////////////
    // GUI Init
    // //////////////////////////////////////

    // init SDL backend (creates OS window)
    var backend = try Backend.init(.{
        .width = 680,
        .height = 400,
        .vsync = vsync,
        .title = "PassKeeZ",
    });
    defer backend.deinit();
    backend.setIconFromFileContent(window_icon_png);

    // init dvui Window (maps onto a single OS window)
    win = try dvui.Window.init(@src(), 0, gpa, backend.backend());
    win.content_scale = backend.initial_scale;
    defer win.deinit();

    win.theme = &style.keypass_light;

    // //////////////////////////////////////
    // App Init
    // //////////////////////////////////////

    application_state.app_state = application_state.AppState{
        .states = std.ArrayList(application_state.AppState.State).init(gpa),
    };
    defer application_state.app_state.deinit();

    var config_file = db.Config.load(gpa) catch blk: {
        std.log.info("No configuration file found in `~/.keypass`", .{});
        try db.Config.create(gpa);
        var f = try db.Config.load(gpa);
        std.log.info("Configuration file created", .{});
        break :blk f;
    };

    try application_state.app_state.pushState(application_state.AppState.State{ .login = .{} });
    @memset(application_state.app_state.getState().login.path[0..], 0);
    @memcpy(
        application_state.app_state.getState().login.path[0..config_file.db_path.len],
        config_file.db_path,
    );

    config_file.deinit(gpa);
    // //////////////////////////////////////
    // Main
    // //////////////////////////////////////

    main_loop: while (true) {
        // beginWait coordinates with waitTime below to run frames only when needed
        var nstime = win.beginWait(backend.hasEvent());

        // marks the beginning of a frame for dvui, can call dvui functions after this
        try win.begin(nstime);

        // send all SDL events to dvui for processing
        const quit = try backend.addAllEvents(&win);
        if (quit) break :main_loop;

        try dvui_frame();

        // marks end of dvui frame, don't call dvui functions after this
        // - sends all dvui stuff to backend for rendering, must be called before renderPresent()
        const end_micros = try win.end(.{});

        // cursor management
        backend.setCursor(win.cursorRequested());

        // render frame to OS
        backend.renderPresent();

        // waitTime and beginWait combine to achieve variable framerates
        const wait_event_micros = win.waitTime(end_micros, null);
        backend.waitEventTimeout(wait_event_micros);
    }

    switch (application_state.app_state.getStateTag()) {
        .login => {},
        .main => {
            application_state.deinit(gpa);
        },
    }
}

pub var show_dialog: bool = false;
pub var show_create_dialog: bool = false;

fn dvui_frame() !void {
    {
        var m = try dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
        defer m.deinit();

        if (try dvui.menuItemLabel(@src(), "Database", .{ .submenu = true }, .{
            .expand = .none,
            .corner_radius = dvui.Rect.all(0),
        })) |r| {
            var fw = try dvui.popup(
                @src(),
                dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }),
                .{
                    .corner_radius = dvui.Rect.all(0),
                },
            );
            defer fw.deinit();

            if (try dvui.menuItemLabel(@src(), "New Database...", .{}, .{
                .corner_radius = dvui.Rect.all(0),
            }) != null) {
                dvui.menuGet().?.close();
                show_create_dialog = true;
            }

            switch (application_state.app_state.getStateTag()) {
                .login => {},
                .main => {
                    if (try dvui.menuItemLabel(@src(), "Lock Database", .{}, .{
                        .corner_radius = dvui.Rect.all(0),
                    }) != null) {
                        application_state.deinit(gpa);
                    }
                },
            }
        }

        if (try dvui.menuItemLabel(@src(), "Help", .{ .submenu = true }, .{
            .expand = .none,
            .corner_radius = dvui.Rect.all(0),
        })) |r| {
            var fw = try dvui.popup(
                @src(),
                dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }),
                .{
                    .corner_radius = dvui.Rect.all(0),
                },
            );
            defer fw.deinit();
            if (try dvui.menuItemLabel(@src(), "About", .{}, .{
                .corner_radius = dvui.Rect.all(0),
            }) != null) {
                dvui.menuGet().?.close();
                show_dialog = true;
            }
        }
    }

    var scroll = try dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_style = .window });
    defer scroll.deinit();

    switch (application_state.app_state.getStateTag()) {
        .login => try gui.login_frame(),
        .main => try main_frame(),
    }

    if (show_dialog) {
        try gui.info_dialog();
    }

    if (show_create_dialog) {
        try gui.create_db_dialog();
    }
}

fn main_frame() !void {
    if (application_state.database.data.entries) |*entries| {
        if (entries.len > 1) {
            for (entries.*, 0..) |*entry, i| {
                if (entry.getField("Data", std.time.milliTimestamp())) |data| {
                    var buffer: [1024]u8 = .{0} ** 1024;
                    const slice = try std.fmt.hexToBytes(&buffer, data);

                    const cred = cbor.parse(
                        keylib.ctap.authenticator.Credential,
                        try cbor.DataItem.new(slice),
                        .{ .allocator = gpa },
                    ) catch {
                        continue;
                    };
                    defer cred.deinit(gpa);

                    var box = try dvui.box(@src(), .vertical, .{
                        .margin = dvui.Rect{ .x = 8.0, .y = 8.0, .w = 8.0 },
                        .padding = dvui.Rect.all(8),
                        .background = true,
                        .expand = .horizontal,
                        .id_extra = i,
                    });
                    defer box.deinit();

                    {
                        //var rp_box = try dvui.box(@src(), .vertical, .{});
                        //defer rp_box.deinit();

                        {
                            var hbox = try dvui.box(@src(), .horizontal, .{});
                            defer hbox.deinit();

                            try dvui.label(@src(), "Relying Party:", .{}, .{});
                            if (try dvui.labelClick(@src(), "{s}", .{cred.rp.id}, .{ .gravity_y = 0.5, .color_text = .{ .r = 0x35, .g = 0x84, .b = 0xe4 } })) {
                                if (cred.rp.id.len < 5 or !std.mem.eql(u8, "https", cred.rp.id[0..5])) {
                                    var rps = try gpa.alloc(u8, cred.rp.id.len + 8);
                                    defer gpa.free(rps);
                                    @memcpy(rps[0..8], "https://");
                                    @memcpy(rps[8..], cred.rp.id);
                                    try dvui.openURL(rps);
                                } else {
                                    try dvui.openURL(cred.rp.id);
                                }
                            }
                        }

                        //try dvui.label(@src(), "Relying Party: {s}", .{cred.rp.id}, .{ .gravity_y = 0.5 });
                        try dvui.label(@src(), "User: {s}", .{if (cred.user.displayName) |dn| blk: {
                            break :blk dn;
                        } else if (cred.user.name) |n| blk: {
                            break :blk n;
                        } else blk: {
                            break :blk "?";
                        }}, .{ .gravity_y = 0.5 });
                        try dvui.label(@src(), "Signatures Created: {d}", .{cred.sign_count}, .{ .gravity_y = 0.5 });
                        if (try dvui.button(@src(), "Delete", .{}, .{
                            .color_style = .err,
                            .corner_radius = dvui.Rect.all(0),
                            .gravity_x = 1.0,
                            .gravity_y = 1.0,
                        })) {}
                    }
                }
            }
        } else { // entries.len == 0
            try dvui.label(@src(), "No Passkeys available, go and create one!", .{}, .{ .font_style = .title_3, .gravity_x = 0.5, .gravity_y = 0.5 });
            if (try dvui.labelClick(@src(), "https://passkey.org/", .{}, .{ .font_style = .title_4, .gravity_x = 0.5, .color_text = .{ .r = 0x35, .g = 0x84, .b = 0xe4 } })) {
                try dvui.openURL("https://passkey.org/");
            }
        }
    }
}

pub inline fn slen(s: []const u8) usize {
    return std.mem.indexOfScalar(u8, s, 0) orelse s.len;
}

pub fn strlen(s: [*c]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

// /////////////////////////////////////////
// Auth
// /////////////////////////////////////////

const UpResult = keylib.ctap.authenticator.callbacks.UpResult;
const UvResult = keylib.ctap.authenticator.callbacks.UvResult;
const Error = keylib.ctap.authenticator.callbacks.Error;

pub fn my_uv(
    /// Information about the context (e.g., make credential)
    info: [*c]const u8,
    /// Information about the user (e.g., `David Sugar (david@example.com)`)
    user: [*c]const u8,
    /// Information about the relying party (e.g., `Github (github.com)`)
    rp: [*c]const u8,
) callconv(.C) UvResult {
    _ = info;
    _ = user;
    _ = rp;
    // The authenticator backend is only started if a correct password has been provided
    // so we return Accepted. As this state may last for multiple minutes it's important
    // that we ask for user presence, i.e. we DONT return AcceptedWithUp!
    //
    // TODO: "logout after being inactive for m minutes"
    return UvResult.Accepted;
}

pub fn my_up(
    /// Information about the context (e.g., make credential)
    info: [*c]const u8,
    /// Information about the user (e.g., `David Sugar (david@example.com)`)
    user: [*c]const u8,
    /// Information about the relying party (e.g., `Github (github.com)`)
    rp: [*c]const u8,
) callconv(.C) UpResult {
    if (info) |i| {
        std.log.info("{s}", .{i});
    }

    const dialogsFollowup = struct {
        var confirm: ?bool = null;
        fn callafter(id: u32, response: dvui.enums.DialogResponse) dvui.Error!void {
            _ = id;
            confirm = (response == dvui.enums.DialogResponse.ok);
        }
    };

    const begin = std.time.milliTimestamp();

    const title = std.fmt.allocPrint(gpa, "User Presence Check{s}{s}", .{
        if (info != null) ": " else "",
        if (info != null) info[0..strlen(info)] else "",
    }) catch blk: {
        break :blk "oops";
    };

    var message = std.fmt.allocPrint(gpa, "Please confirm your presence for {s} {s}{s}{s} by clicking ok", .{
        if (rp != null) rp[0..strlen(rp)] else "???",
        if (user != null) "(" else "",
        if (user != null) user[0..strlen(user)] else "",
        if (user != null) "(" else "",
    }) catch blk: {
        break :blk "oops";
    };

    dvui.dialog(@src(), .{
        .window = &win,
        .modal = false,
        .title = title,
        .message = message,
        .callafterFn = dialogsFollowup.callafter,
    }) catch return .Denied;

    while (std.time.milliTimestamp() - begin < 60_000) {
        // If the authenticator thread gets a stop signal, return timeout
        if (application_state.app_state.getState().main.stop) {
            return .Timeout;
        }

        if (dialogsFollowup.confirm != null) {
            defer dialogsFollowup.confirm = null;
            if (dialogsFollowup.confirm.?) {
                return .Accepted;
            } else {
                return .Denied;
            }
        }
        std.time.sleep(10000000);
    }

    return UpResult.Timeout;
}

pub fn my_select(
    rpId: [*c]const u8,
    users: [*c][*c]const u8,
) callconv(.C) i32 {
    _ = rpId;
    _ = users;
    return 0;
}

pub fn my_read(
    id: [*c]const u8,
    rp: [*c]const u8,
    out: *[*c][*c]u8,
) callconv(.C) Error {
    if (id != null) {
        if (application_state.database.getEntry(id[0..strlen(id)])) |*e| {
            if (e.*.getField("Data", std.time.microTimestamp())) |data| {
                var d = gpa.alloc(u8, data.len + 1) catch {
                    std.log.err("out of memory", .{});
                    return Error.OutOfMemory;
                };
                @memcpy(d[0..data.len], data);
                d[data.len] = 0;
                //var d = gpa.dupeZ(u8, data) catch {
                //    std.log.err("out of memory", .{});
                //    return Error.OutOfMemory;
                //};

                var x = gpa.alloc([*c]u8, 2) catch {
                    std.log.err("out of memory", .{});
                    return Error.OutOfMemory;
                };

                x[0] = d.ptr;
                x[1] = null;
                out.* = x.ptr;

                return Error.SUCCESS;
            } else {
                std.log.err("Data field not present", .{});
                return Error.Other;
            }
        } else {
            std.log.warn("no entry with id {s} found", .{id[0..strlen(id)]});
            return Error.DoesNotExist;
        }
    } else if (rp != null) {
        var arr = std.ArrayList([*c]u8).init(gpa);
        if (application_state.database.getEntries(
            &.{.{ .key = "Url", .value = rp[0..strlen(rp)] }},
            gpa,
        )) |entries| {
            for (entries) |*e| {
                if (e.*.getField("Data", std.time.microTimestamp())) |data| {
                    var d = gpa.dupeZ(u8, data) catch {
                        std.log.err("out of memory", .{});
                        return Error.OutOfMemory;
                    };
                    arr.append(d) catch {
                        std.log.err("out of memory", .{});
                        return Error.OutOfMemory;
                    };
                } else {
                    std.log.err("Data field not present", .{});
                    continue;
                }
            }
        }

        if (arr.items.len > 0) {
            var x = arr.toOwnedSliceSentinel(null) catch {
                std.log.err("out of memory", .{});
                arr.deinit();
                return Error.OutOfMemory;
            };
            out.* = x.ptr;
            return Error.SUCCESS;
        } else {
            arr.deinit();
            return Error.DoesNotExist;
        }
    }

    return Error.DoesNotExist;
}

pub fn my_write(
    id: [*c]const u8,
    rp: [*c]const u8,
    data: [*c]const u8,
) callconv(.C) Error {
    if (application_state.database.getEntry(id[0..strlen(id)])) |*e| {
        e.*.updateField("Data", data[0..strlen(data)], std.time.milliTimestamp()) catch {
            std.log.err("unable to update field", .{});
            return Error.Other;
        };
    } else {
        var e = application_state.database.createEntry(id[0..strlen(id)]) catch {
            std.log.err("unable to create new entry", .{});
            return Error.Other;
        };

        e.addField(
            "Url",
            rp[0..strlen(rp)],
            std.time.milliTimestamp(),
        ) catch {
            std.log.err("unable to add Url field", .{});
            e.deinit();
            return Error.Other;
        };

        e.addField(
            "Data",
            data[0..strlen(data)],
            std.time.milliTimestamp(),
        ) catch {
            std.log.err("unable to add Data field", .{});
            e.deinit();
            return Error.Other;
        };

        application_state.database.addEntry(e) catch {
            std.log.err("unable to add entry to database", .{});
            e.deinit();
            return Error.Other;
        };
    }

    var f2 = std.fs.createFileAbsolute("/tmp/db.trs", .{ .truncate = true }) catch {
        std.log.err("unable to open temporary file in /tmp", .{});
        return Error.Other;
    };
    defer f2.close();

    application_state.database.seal(f2.writer(), application_state.pw) catch {
        std.log.err("unable to persist database", .{});
        return Error.Other;
    };

    if (application_state.f[0] == '~' and application_state.f[1] == '/') {
        if (std.os.getenv("HOME")) |home| {
            var path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, application_state.f[2..] }) catch {
                std.log.err("out of memory", .{});
                return Error.Other;
            };
            defer gpa.free(path);
            std.log.err("{s}", .{path});

            std.fs.copyFileAbsolute("/tmp/db.trs", path, .{}) catch {
                std.log.err("unable to overwrite file `{s}`", .{application_state.f});
                return Error.Other;
            };
        } else {
            std.log.err("no HOME path", .{});
            return Error.Other;
        }
    } else if (application_state.f[0] == '/') {
        std.fs.copyFileAbsolute("/tmp/db.trs", application_state.f, .{}) catch {
            std.log.err("unable to overwrite file `{s}`", .{application_state.f});
            return Error.Other;
        };
    } else {
        std.log.err("support for file prefix not implemented yet!!!", .{});
        return Error.Other;
    }

    return Error.SUCCESS;
}

pub fn my_delete(
    id: [*c]const u8,
) callconv(.C) Error {
    _ = id;
    return Error.Other;
}

const callbacks = keylib.ctap.authenticator.callbacks.Callbacks{
    .up = my_up,
    .uv = my_uv,
    .select = my_select,
    .read = my_read,
    .write = my_write,
    .delete = my_delete,
};

pub fn auth_fn() !void {
    var auth = keylib.ctap.authenticator.Auth.default(callbacks, gpa);
    auth.constSignCount = true;
    try auth.init();

    var ctaphid = keylib.ctap.transports.ctaphid.authenticator.CtapHid.init(gpa);
    defer ctaphid.deinit();

    var u = try uhid.Uhid.open();
    defer u.close();

    while (true) {
        var buffer: [64]u8 = .{0} ** 64;
        if (u.read(&buffer)) |packet| {
            var response = ctaphid.handle(packet, &auth);
            if (response) |*res| blk: {
                defer res.deinit();

                while (res.next()) |p| {
                    u.write(p) catch {
                        break :blk;
                    };
                }
            }
        }
        std.time.sleep(10000000);

        // We send all data back before we end the thread
        if (application_state.app_state.getState().main.stop) {
            return;
        }
    }
}
