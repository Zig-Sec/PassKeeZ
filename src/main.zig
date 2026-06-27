const std = @import("std");
const keylib = @import("keylib");
const dt = keylib.common.dt;
const cbor = @import("zbor");
const uhid = @import("uhid");
const nightwatch = @import("nightwatch");

const UpResult = keylib.ctap.authenticator.callbacks.UpResult;
const UvResult = keylib.ctap.authenticator.callbacks.UvResult;
const Error = keylib.ctap.authenticator.callbacks.Error;
const Credential = keylib.ctap.authenticator.Credential;
const CallbackError = keylib.ctap.authenticator.callbacks.CallbackError;
const Meta = keylib.ctap.authenticator.Meta;

var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

const State = @import("State.zig");

var fetch_index: ?usize = null;
var fetch_rp: ?dt.ABS128T = null;
var fetch_hash: ?[32]u8 = null;
var fetch_ts: ?i64 = null;

const c = @import("c");

// The .polling variant is Linux-only (inotify). Unlike the threaded backends,
// it does not spawn an internal thread; instead the caller drives event
// delivery by polling poll_fd() for readability and calling handle_read_ready()
// whenever data is available. The handler vtable requires an extra
// wait_readable callback that the backend calls to notify the handler that it
// should re-arm the fd in its polling loop before the next handle_read_ready().
//const Watcher = nightwatch.Create(.polling);
const Watcher = nightwatch.Default;

// On Ubuntu, saving a file is registered as: `close`, `delete`, i.e., we
// have to act on delete and "rearm" the watcher afterwards.
var rearm_conf_watcher: bool = false;
const H = struct {
    handler: Watcher.Handler,

    const vtable = Watcher.Handler.VTable{ .change = change, .rename = rename };

    fn change(_: *Watcher.Handler, path: []const u8, event: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        _ = path;
        //std.debug.print("rename  {any}  ->  {s}\n", .{ event, path });

        if (event == .deleted) {
            // As the watcher runs in a different thread, we just set the
            // flag and handle reloading the configuration in the main loop
            // to prevent data races.
            rearm_conf_watcher = true;
        }
    }

    fn rename(_: *Watcher.Handler, src: []const u8, dst: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        std.log.debug("rename  {s}  ->  {s}\n", .{ src, dst });
    }

    // Called by the backend at arm time and after each handle_read_ready().
    // Return .will_notify (currently the only option) to signal that the
    // caller's loop will drive delivery.
    fn wait_readable(_: *Watcher.Handler) error{HandlerFailed}!Watcher.Handler.ReadableStatus {
        return .will_notify;
    }
};

pub fn main(init: std.process.Init) !void {
    defer _ = gpa.detectLeaks();

    // Do NOT swap out memory.
    _ = c.mlockall(c.MCL_CURRENT | c.MCL_FUTURE);

    // We need the path to the home folder.
    // TODO: add command line argument as backup
    const home = init.minimal.environ.getAlloc(allocator, "HOME") catch |e| {
        std.log.err("missing \"HOME\" environment variable ({any})", .{e});
        std.process.exit(1);
    };
    defer allocator.free(home);

    // State keeps track of the opened database, the config file and all timers.
    State.init(allocator, init.io, home) catch |e| {
        std.log.err("Unable to initialize application ({any})", .{e});
        return std.c.exit(1);
    };
    defer State.deinit(allocator);

    // Setup file watcher for configuration file
    var h = H{ .handler = .{ .vtable = &H.vtable } };
    var conf_watcher = try Watcher.init(init.io, allocator, &h.handler);
    defer conf_watcher.deinit();
    conf_watcher.watch(State.get().conf_abs_path) catch |e| {
        std.log.err("start watching configuration file failed ({any})", .{e});
        std.process.exit(1);
    };
    //var pfd = [_]std.posix.pollfd{
    //    .{ .fd = conf_watcher.poll_fd(), .events = std.posix.POLL.IN, .revents = 0 },
    //};

    // The Auth struct is the most important part of your authenticator. It defines
    // its capabilities and behavior.
    var auth = keylib.ctap.authenticator.Auth{
        // The callbacks are the interface between the authenticator and the rest of the application (see below).
        .callbacks = callbacks,
        // The commands map from a command code to a command function. All functions have the
        // same interface and you can implement your own to extend the authenticator beyond
        // the official spec, e.g. add a command to store passwords.
        .commands = &.{
            .{ .cmd = 0x01, .cb = keylib.ctap.commands.authenticator.authenticatorMakeCredential },
            .{ .cmd = 0x02, .cb = keylib.ctap.commands.authenticator.authenticatorGetAssertion },
            .{ .cmd = 0x04, .cb = keylib.ctap.commands.authenticator.authenticatorGetInfo },
            .{ .cmd = 0x06, .cb = keylib.ctap.commands.authenticator.authenticatorClientPin },
            .{ .cmd = 0x08, .cb = keylib.ctap.commands.authenticator.authenticatorGetNextAssertion },
            .{ .cmd = 0x0a, .cb = @import("cred_mgmt.zig").authenticatorCredentialManagement },
            .{ .cmd = 0x41, .cb = @import("cred_mgmt.zig").authenticatorCredentialManagement },
            .{ .cmd = 0x0b, .cb = keylib.ctap.commands.authenticator.authenticatorSelection },
        },
        // The settings are returned by a getInfo request and describe the capabilities
        // of your authenticator. Make sure your configuration is valid based on the
        // CTAP2 spec!
        .settings = .{
            // Those are the FIDO2 spec you support
            .versions = &.{
                .FIDO_2_0,
                .FIDO_2_1,
                .FIDO_2_2,
            },
            // The extensions are defined as strings which should make it easy to extend
            // the authenticator (in combination with a new command).
            .extensions = &.{
                "credProtect",
                "hmac-secret",
            },
            // This should be unique for all models of the same authenticator.
            .aaguid = "\x73\x79\x63\x2e\x70\x61\x73\x73\x6b\x65\x65\x7a\x2e\x6f\x72\x67".*,
            .options = .{
                // We don't support the credential management command. If you want to
                // then you need to implement it yourself and add it to commands and
                // set this flag to true.
                .credMgmt = true,
                // We support discoverable credentials, a.k.a resident keys, a.k.a passkeys
                .rk = true,
                // We support built in user verification (see the callback below)
                .uv = true,
                // This is a platform authenticator even if we use usb for ipc
                .plat = true,
                // We don't support client pin but you could also add the command
                // yourself and set this to false (not initialized) or true (initialized).
                .clientPin = null,
                // We support pinUvAuthToken
                .pinUvAuthToken = true,
                // If you want to enforce alwaysUv you also have to set this to true.
                .alwaysUv = true,
            },
            // The pinUvAuth protocol to support. This library implements V1 and V2.
            .pinUvAuthProtocols = &.{.V2},
            // The transports your authenticator supports.
            .transports = &.{.usb},
            // The algorithms you support.
            .algorithms = &.{
                .{ .alg = .@"ML-DSA-87" },
                .{ .alg = .@"ML-DSA-65" },
                .{ .alg = .@"ML-DSA-44" },
                .{ .alg = .Es256 },
            },
            .firmwareVersion = 0x0036,
            .remainingDiscoverableCredentials = 100,
        },
        // Here we initialize the pinUvAuth token data structure wich handles the generation
        // and management of pinUvAuthTokens.
        .token = keylib.ctap.pinuv.PinUvAuth.v2(init.io),
        .io = init.io,
        // This allocator is used by the authenticator instance and is
        // also passed to every callback.
        //
        // As a general rule:
        // 1. If pass a credential to the authenticator instance via
        //    a read or read_next callback, make sure to copy the all
        //    dynamic fields of the `Credential` (currently this is
        //    only the `key`). The instance will automatically call deinit
        //    on the credential after use, when using the default
        //    command handlers.
        // 2. If you receive a credential (e.g., via write), make sure to copy it before
        //    making any modifications. The authenticator is responsible
        //    for freeing the passed `Credential`.
        .allocator = allocator,
        // If you don't want to increment the sign counts
        // of credentials (e.g. because you sync them between devices)
        // set this to true.
        .constSignCount = true,
        .general_backup_eligibility = true,
    };
    auth.init() catch |e| {
        std.log.err("[main]: failed to initialize authenticator ({any})", .{e});
        std.process.exit(1);
    };

    // Here we instantiate a CTAPHID handler.
    var ctaphid = keylib.ctap.transports.ctaphid.authenticator.CtapHid.init(allocator, init.io);
    defer ctaphid.deinit();

    // We use the uhid module on linux to simulate a USB device. If you use
    // tinyusb or something similar you have to adapt the code.
    var u = uhid.Uhid.open(init.io, "PassKeeZ authenticator") catch |e| {
        std.log.err("unable to open uhid device ({any})", .{e});
        std.process.exit(1);
    };
    defer u.close();

    // This is the main loop
    while (true) {
        // The `rearm_conf_watcher` tells us that the configuration file
        // has been changed, i.e., we reload the configuration and "rearm"
        // the watcher.
        if (rearm_conf_watcher) {
            State.get().reloadConfig(allocator, init.io) catch |e| {
                std.log.err("reloading configuration failed ({any})", .{e});
            };

            conf_watcher.watch(State.get().conf_abs_path) catch |e| {
                std.log.err("rearming configuration file watcher failed ({any})", .{e});
            };

            rearm_conf_watcher = false;
        }

        State.get().update(init.io);

        // We read in usb packets with a size of 64 bytes.
        var buffer: [64]u8 = .{0} ** 64;
        if (u.read(&buffer)) |packet| {
            // Those packets are passed to the CTAPHID handler who assembles
            // them into a CTAPHID message.
            var response = ctaphid.handle(packet);
            // Once a message is complete (or an error has occured) you
            // get a response.
            if (response) |*res| blk: {
                switch (res.cmd) {
                    // Here we check if its a cbor message and if so, pass
                    // it to the handle() function of our authenticator.
                    .cbor => {
                        var out: [7609]u8 = undefined;
                        const r = auth.handle(&out, res.getData());
                        @memcpy(res._data[0..r.len], r);
                        res.len = r.len;
                    },
                    else => {},
                }

                var iter = res.iterator();
                // Here we iterate over the response packets of our authenticator.
                while (iter.next()) |p| {
                    u.write(p) catch |e| {
                        std.log.err("unable to write usb packet ({any})", .{e});
                        break :blk;
                    };
                }
            }
        }

        init.io.sleep(std.Io.Duration.fromMilliseconds(25), .real) catch {};
    }
}

// /////////////////////////////////////////
// Data
// /////////////////////////////////////////

const Data = struct {
    rp: []const u8,
    id: []const u8,
    data: []const u8,
};

// /////////////////////////////////////////
// Auth
//
// Below you can see all the callbacks you have to implement
// (that are expected by the default command functions). Make
// sure you allocate memory with the same allocator that you
// passed to the Auth sturct.
//
// How you check user presence, conduct user verification or
// store the credentials is up to you.
// /////////////////////////////////////////
const i18n = @import("i18n.zig");

pub fn authenticatorSelection(state_: *State, io: std.Io) keylib.ctap.StatusCodes {
    const r = std.process.run(allocator, io, .{
        .argv = &.{
            "zigenity",
            "--question",
            "--window-icon=/usr/share/passkeez/passkeez.png",
            "--icon=/usr/share/passkeez/passkeez-question.png",
            i18n.get(state_.conf.lang).auth_select,
            i18n.get(state_.conf.lang).auth_select_title,
            "--timeout=15",
        },
    }) catch |e| {
        std.log.err("select: unable to create select dialog ({any})", .{e});
        return .ctap2_err_operation_denied;
    };
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    switch (r.term.exited) {
        0 => return .ctap1_err_success,
        5 => return .ctap2_err_user_action_timeout,
        else => return .ctap2_err_operation_denied,
    }
}

//pub fn getInfo(
//    auth: *keylib.ctap.authenticator.Auth,
//    out: []u8,
//) usize {
//    var arr = std.ArrayList(u8).init(allocator);
//    defer arr.deinit();
//
//    cbor.stringify(auth.settings, .{}, arr.writer()) catch {
//        out[0] = @intFromEnum(keylib.ctap.StatusCodes.ctap1_err_other);
//        return 1;
//    };
//
//    out[0] = @intFromEnum(keylib.ctap.StatusCodes.ctap1_err_success);
//    @memcpy(out[1 .. arr.items.len + 1], arr.items);
//    return arr.items.len + 1;
//}

pub fn my_uv(
    /// Information about the context (e.g., make credential)
    info: []const u8,
    /// Information about the user (e.g., `David Sugar (david@example.com)`)
    user: ?keylib.common.User,
    /// Information about the relying party (e.g., `Github (github.com)`)
    rp: ?keylib.common.RelyingParty,
    /// The pinHash can be used for comparison with the stored PIN hash
    /// when using PIN based authentication.
    pinHash: ?[]const u8,
    a: std.mem.Allocator,
    io: std.Io,
) UvResult {
    _ = info;
    _ = user;
    _ = rp;
    _ = pinHash;

    State.get().authenticate(a, io) catch |e| {
        std.log.err("[my_uv]: authentication failed ({any})", .{e});
        return UvResult.Denied;
    };

    return State.get().uv_result;
}

pub fn my_up(
    /// Information about the context (e.g., make credential)
    info: []const u8,
    /// Information about the user (e.g., `David Sugar (david@example.com)`)
    user: ?keylib.common.User,
    /// Information about the relying party (e.g., `Github (github.com)`)
    rp: ?keylib.common.RelyingParty,
    a: std.mem.Allocator,
    io: std.Io,
) UpResult {
    _ = info;
    _ = user;
    _ = a;

    std.log.debug("[my_up]: {any}", .{State.get().up_result});
    if (State.get().up_result) |r| return r;

    const text = std.fmt.allocPrint(allocator, "{s} {s}", .{
        i18n.get(State.get().conf.lang).user_presence,
        if (rp) |rp_| rp_.id.get() else i18n.get(State.get().conf.lang).user_presence_fallback,
    }) catch |e| {
        std.log.err("up: unable to allocate memory for text ({any})", .{e});
        return UpResult.Denied;
    };
    defer allocator.free(text);

    const r = std.process.run(allocator, io, .{
        .argv = &.{
            "zigenity",
            "--question",
            "--window-icon=/usr/share/passkeez/passkeez.png",
            "--icon=/usr/share/passkeez/passkeez-question.png",
            text,
            i18n.get(State.get().conf.lang).user_presence_title,
            "--timeout=30",
        },
    }) catch |e| {
        std.log.err("up: unable to create up dialog ({any})", .{e});
        return UpResult.Denied;
    };
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    std.log.debug("up result: {d}", .{r.term.exited});
    switch (r.term.exited) {
        0 => return UpResult.Accepted,
        5 => return UpResult.Timeout,
        else => return UpResult.Denied,
    }
}

pub fn my_read_first(
    id: ?dt.ABS64B,
    rp: ?dt.ABS128T,
    hash: ?[32]u8,
    a: std.mem.Allocator,
    io: std.Io,
) CallbackError!Credential {
    std.log.debug("my_first_read:\n  id:   {s}\n  rpId: {s}", .{
        if (id) |uid| uid.get() else "n.a.",
        if (rp) |rpid| rpid.get() else "n.a.",
    });

    fetch_index = 0;
    fetch_rp = null;
    fetch_hash = null;
    fetch_ts = std.Io.Timestamp.now(io, .real).toMilliseconds();

    if (rp != null or hash != null) {
        fetch_rp = rp;
        fetch_hash = hash;

        const cred = State.get().database.?.getCredential(&State.get().database.?, if (fetch_rp) |frp| frp.get() else null, hash, &fetch_index.?, a) catch |e| {
            std.log.debug("No entry found: {any}", .{e});
            fetch_index = null;
            fetch_rp = null;
            fetch_hash = null;
            fetch_ts = null;
            return error.DoesNotExist;
        };

        return cred;
    } else {
        return State.get().database.?.getCredential(&State.get().database.?, null, null, &fetch_index.?, a) catch |e| {
            std.log.debug("No entry found: {any}", .{e});
            fetch_index = null;
            fetch_rp = null;
            fetch_hash = null;
            fetch_ts = null;
            return error.DoesNotExist;
        };
    }

    return error.DoesNotExist;
}

pub fn my_read_next(
    a: std.mem.Allocator,
    io: std.Io,
) CallbackError!Credential {
    _ = io;

    std.log.debug("my_read_next: fetch_ts {any}, fetch_index {any}, fetch_rp {any}", .{ fetch_ts, fetch_index, fetch_rp });
    if (fetch_ts == null or fetch_index == null) {
        fetch_index = null;
        fetch_rp = null;
        fetch_hash = null;
        fetch_ts = null;

        return error.Other;
    }

    return State.get().database.?.getCredential(&State.get().database.?, if (fetch_rp) |rp| rp.get() else null, fetch_hash, &fetch_index.?, a) catch |e| {
        std.log.debug("No entry found: {any}", .{e});
        fetch_index = null;
        fetch_rp = null;
        fetch_hash = null;
        fetch_ts = null;
        return error.DoesNotExist;
    };
}

pub fn my_write(
    data: Credential,
    a: std.mem.Allocator,
    io: std.Io,
) CallbackError!void {
    _ = a;
    _ = io;

    State.get().database.?.setCredential(&State.get().database.?, data) catch {
        return error.Other;
    };
}

pub fn my_delete(
    id: []const u8,
    a: std.mem.Allocator,
    io: std.Io,
) CallbackError!void {
    _ = id;
    _ = a;
    _ = io;

    return error.Other;
}

pub fn my_read_settings(
    a: std.mem.Allocator,
    io: std.Io,
) Meta {
    _ = a;
    _ = io;

    return Meta{
        .always_uv = true,
    };
}

pub fn my_write_settings(
    data: Meta,
    a: std.mem.Allocator,
    io: std.Io,
) void {
    _ = a;
    _ = io;

    _ = data;
}

const callbacks = keylib.ctap.authenticator.callbacks.Callbacks{
    .up = my_up,
    .uv = my_uv,
    .read_first = my_read_first,
    .read_next = my_read_next,
    .write = my_write,
    .delete = my_delete,
    .read_settings = my_read_settings,
    .write_settings = my_write_settings,
};
