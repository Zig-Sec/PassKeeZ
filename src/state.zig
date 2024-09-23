const std = @import("std");
const ccdb = @import("ccdb");
const Database = @import("Database.zig");
const Config = @import("database/Config.zig");
const keylib = @import("keylib");
const UpResult = keylib.ctap.authenticator.callbacks.UpResult;
const UvResult = keylib.ctap.authenticator.callbacks.UvResult;

pub var conf: Config = undefined;

/// The open database
///
/// This variable is accessed by the main and the authenticator
/// thread if the application is in `main` state.
///
/// TODO: currently the main thread uses the database only for reading
///       but we probably need a lock in the future.
pub var database: ?Database = null;

pub var uv_result = UvResult.Denied;
pub var up_result: ?UpResult = null;

var ts: ?i64 = null;
const tout1: i64 = 10; // seconds
const tout2: i64 = 60; // seconds

pub fn init(a: std.mem.Allocator) !void {
    conf = Config.load(a) catch |e| blk: {
        std.log.err("unable to load configuration file ({any})", .{e});
        Config.create(a) catch |e2| {
            std.log.err("unable to create configuration file ({any})", .{e2});
            return e2;
        };
        const conf_ = Config.load(a) catch |e2| {
            std.log.err("unable to load configuration file after new database creation ({any})", .{e2});
            return e2;
        };
        std.log.info("Configuration file created", .{});
        break :blk conf_;
    };
}

pub fn update() void {
    if (ts) |ts_| {
        const now = std.time.timestamp();
        if (now - ts_ > tout2) {
            deinit();
        } else if (now - ts_ > tout1) {
            // Requre UP after 10 seconds
            uv_result = UvResult.Accepted;
            up_result = null;
        }
    }
}

pub fn authenticate(a: std.mem.Allocator) !void {
    if (ts != null) return; // nothing to do

    var i: usize = 3;

    outer: while (i > 0) : (i -= 1) {
        var password = std.process.Child.run(.{
            .allocator = a,
            .argv = &.{
                "zigenity",
                "--password",
                "--window-icon=/usr/share/passkeez/passkeez.png",
                "--title=PassKeeZ: Unlock Database",
                "--ok-label=Unlock",
                "--timeout=60",
            },
        }) catch |e| {
            std.log.err("unable to execute zigenity ({any})", .{e});
            return e;
        };
        defer {
            @memset(password.stdout, 0);
            a.free(password.stdout);
            @memset(password.stderr, 0);
            a.free(password.stderr);
        }
        std.log.info("{any}", .{password});

        switch (password.term.Exited) {
            0 => {
                var db = Database.ccdb.Database(
                    conf.db_path,
                    password.stdout[0 .. password.stdout.len - 1],
                    a,
                ) catch {
                    std.log.err("unable to instantiate Database", .{});
                    continue :outer;
                };

                db.init(&db) catch |e| {
                    std.log.err("unable to decrypt database {s} ({any})", .{ conf.db_path, e });
                    const r = std.process.Child.run(.{
                        .allocator = a,
                        .argv = &.{
                            "zigenity",
                            "--question",
                            "--window-icon=/usr/share/passkeez/passkeez.png",
                            "--icon=/usr/share/passkeez/passkeez-error.png",
                            "--text=Credential database decryption failed",
                            "--title=PassKeeZ: Wrong Password",
                            "--ok-label=Ok",
                            "--switch-cancel",
                            "--timeout=15",
                        },
                    }) catch |e2| {
                        std.log.err("unable to execute zigenity ({any})", .{e2});
                        return e2;
                    };
                    defer {
                        a.free(r.stdout);
                        a.free(r.stderr);
                    }
                    continue :outer;
                };

                ts = std.time.timestamp();
                uv_result = UvResult.AcceptedWithUp;
                up_result = UpResult.Accepted;
                database = db;
                return;
            },
            else => {
                return error.RejectedByUser;
            },
        }
    } else {
        const r = std.process.Child.run(.{
            .allocator = a,
            .argv = &.{
                "zigenity",
                "--question",
                "--window-icon=/usr/share/passkeez/passkeez.png",
                "--icon=/usr/share/passkeez/passkeez-error.png",
                "--text=Too many incorrect password attempts",
                "--title=PassKeeZ: Authentication failed",
                "--ok-label=Ok",
                "--switch-cancel",
                "--timeout=15",
            },
        }) catch |e| {
            std.log.err("unable to execute zigenity ({any})", .{e});
            return e;
        };
        defer {
            a.free(r.stdout);
            a.free(r.stderr);
        }
        return error.Failed;
    }
}

pub fn deinit() void {
    if (database) |*db| {
        db.deinit(db);
    }
    ts = null;
    uv_result = UvResult.Denied;
    up_result = null;
}
