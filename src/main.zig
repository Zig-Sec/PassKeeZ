const std = @import("std");
const keylib = @import("keylib");
const dt = keylib.common.dt;
const cbor = @import("zbor");
const uhid = @import("uhid");

const UpResult = keylib.ctap.authenticator.callbacks.UpResult;
const UvResult = keylib.ctap.authenticator.callbacks.UvResult;
const Error = keylib.ctap.authenticator.callbacks.Error;
const Credential = keylib.ctap.authenticator.Credential;
const CallbackError = keylib.ctap.authenticator.callbacks.CallbackError;
const Meta = keylib.ctap.authenticator.Meta;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const State = @import("state.zig");

var initialized = false;

var fetch_index: ?usize = null;
var fetch_rp: ?dt.ABS128T = null;
var fetch_hash: ?[32]u8 = null;
var fetch_ts: ?i64 = null;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

pub fn main() !void {
    State.init(allocator) catch |e| {
        std.log.err("Unable to initialize application ({any})", .{e});
        return std.c.exit(1);
    };

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
            .versions = &.{ .FIDO_2_0, .FIDO_2_1 },
            // The extensions are defined as strings which should make it easy to extend
            // the authenticator (in combination with a new command).
            .extensions = &.{"credProtect"},
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
            .algorithms = &.{.{ .alg = .Es256 }},
            .firmwareVersion = 0x0036,
            .remainingDiscoverableCredentials = 100,
        },
        // Here we initialize the pinUvAuth token data structure wich handles the generation
        // and management of pinUvAuthTokens.
        .token = keylib.ctap.pinuv.PinUvAuth.v2(std.crypto.random),
        // Here we set the supported algorithm. You can also implement your
        // own and add them here.
        .algorithms = &.{
            keylib.ctap.crypto.algorithms.Es256,
        },
        // A function to get the epoch time as i64.
        .milliTimestamp = std.time.milliTimestamp,
        // A cryptographically secure random number generator
        .random = std.crypto.random,
        // If you don't want to increment the sign counts
        // of credentials (e.g. because you sync them between devices)
        // set this to true.
        .constSignCount = true,
    };

    // Here we instantiate a CTAPHID handler.
    var ctaphid = keylib.ctap.transports.ctaphid.authenticator.CtapHid.init(allocator, std.crypto.random);
    defer ctaphid.deinit();

    // We use the uhid module on linux to simulate a USB device. If you use
    // tinyusb or something similar you have to adapt the code.
    var u = uhid.Uhid.open() catch |e| {
        std.log.err("unable to open uhid device ({any})", .{e});
        return e;
    };
    defer u.close();

    // This is the main loop
    while (true) {
        State.update();

        // We read in usb packets with a size of 64 bytes.
        var buffer: [64]u8 = .{0} ** 64;
        if (u.read(&buffer)) |packet| {
            // Those packets are passed to the CTAPHID handler who assembles
            // them into a CTAPHID message.
            var response = ctaphid.handle(packet);
            // Once a message is complete (or an error has occured) you
            // get a response.
            if (response) |*res| blk: {
                var skip = false;

                switch (res.cmd) {
                    .cbor => {
                        // We have to handle this here as we don't need to
                        // decrypt the database for this
                        if (res._data[0] == 0x0b) { // authenticator selection
                            res._data[0] = @intFromEnum(authenticatorSelection());
                            res.len = 1;
                            skip = true;
                        }
                    },
                    else => {},
                }

                if (!skip) {
                    State.authenticate(allocator) catch |e| {
                        std.log.err("authentication failed ({any})", .{e});
                        res._data[0] = 0x3f;
                        res.len = 1;
                        skip = true;
                    };
                }

                if (!skip) {
                    if (!initialized) {
                        try auth.init();
                        initialized = true;
                    }

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
        var timer = std.time.Timer.start() catch {
            std.log.err("failed to start timer in main", .{});
            continue;
        };
        while (timer.read() < 10000000) {
            std.mem.doNotOptimizeAway(void);
        }
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

pub fn authenticatorSelection() keylib.ctap.StatusCodes {
    const r = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "zigenity",
            "--question",
            "--window-icon=/usr/share/passkeez/passkeez.png",
            "--icon=/usr/share/passkeez/passkeez-question.png",
            i18n.get(State.conf.lang).auth_select,
            i18n.get(State.conf.lang).auth_select_title,
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

    switch (r.term.Exited) {
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
) UvResult {
    _ = info;
    _ = user;
    _ = rp;

    return State.uv_result;
}

pub fn my_up(
    /// Information about the context (e.g., make credential)
    info: []const u8,
    /// Information about the user (e.g., `David Sugar (david@example.com)`)
    user: ?keylib.common.User,
    /// Information about the relying party (e.g., `Github (github.com)`)
    rp: ?keylib.common.RelyingParty,
) UpResult {
    _ = info;
    _ = user;

    std.log.info("up: {any}", .{State.up_result});
    if (State.up_result) |r| return r;

    const text = std.fmt.allocPrint(allocator, "{s} {s}", .{
        i18n.get(State.conf.lang).user_presence,
        if (rp) |rp_| rp_.id.get() else i18n.get(State.conf.lang).user_presence_fallback,
    }) catch |e| {
        std.log.err("up: unable to allocate memory for text ({any})", .{e});
        return UpResult.Denied;
    };
    defer allocator.free(text);

    const r = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "zigenity",
            "--question",
            "--window-icon=/usr/local/bin/passkeez/passkeez.png",
            "--icon=/usr/local/bin/passkeez/passkeez-question.png",
            text,
            i18n.get(State.conf.lang).user_presence_title,
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

    std.log.info("up result: {d}", .{r.term.Exited});
    switch (r.term.Exited) {
        0 => return UpResult.Accepted,
        5 => return UpResult.Timeout,
        else => return UpResult.Denied,
    }
}

pub fn my_read_first(
    id: ?dt.ABS64B,
    rp: ?dt.ABS128T,
    hash: ?[32]u8,
) CallbackError!Credential {
    std.log.info("my_first_read:\n  id:   {s}\n  rpId: {s}", .{
        if (id) |uid| uid.get() else "n.a.",
        if (rp) |rpid| rpid.get() else "n.a.",
    });

    if (rp != null or hash != null) {
        fetch_index = 0;
        fetch_rp = rp;
        fetch_hash = hash;
        fetch_ts = std.time.milliTimestamp();

        return State.database.?.getCredential(&State.database.?, if (fetch_rp) |frp| frp.get() else null, hash, &fetch_index.?) catch |e| {
            std.log.info("No entry found: {any}", .{e});
            fetch_index = null;
            fetch_rp = null;
            fetch_hash = null;
            fetch_ts = null;
            return error.DoesNotExist;
        };
    } else {
        fetch_index = 0;
        fetch_rp = null;
        fetch_hash = null;
        fetch_ts = std.time.milliTimestamp();

        return State.database.?.getCredential(&State.database.?, null, null, &fetch_index.?) catch |e| {
            std.log.info("No entry found: {any}", .{e});
            fetch_index = null;
            fetch_rp = null;
            fetch_hash = null;
            fetch_ts = null;
            return error.DoesNotExist;
        };
    }

    return error.DoesNotExist;
}

pub fn my_read_next() CallbackError!Credential {
    std.log.info("my_read_next: fetch_ts {any}, fetch_index {any}, fetch_rp {any}", .{ fetch_ts, fetch_index, fetch_rp });
    if (fetch_ts == null or fetch_index == null) {
        fetch_index = null;
        fetch_rp = null;
        fetch_hash = null;
        fetch_ts = null;

        return error.Other;
    }

    return State.database.?.getCredential(&State.database.?, if (fetch_rp) |rp| rp.get() else null, fetch_hash, &fetch_index.?) catch |e| {
        std.log.info("No entry found: {any}", .{e});
        fetch_index = null;
        fetch_rp = null;
        fetch_hash = null;
        fetch_ts = null;
        return error.DoesNotExist;
    };
}

pub fn my_write(
    data: Credential,
) CallbackError!void {
    State.database.?.setCredential(&State.database.?, data) catch {
        return error.Other;
    };
}

pub fn my_delete(
    id: [*c]const u8,
) callconv(.c) Error {
    _ = id;
    // TODO: remove this from keylib!

    return Error.Other;
}

pub fn my_read_settings() Meta {
    return Meta{
        .always_uv = true,
    };
}

pub fn my_write_settings(data: Meta) void {
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
