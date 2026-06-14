const std = @import("std");
const Database = @import("Database.zig");
const Config = @import("Config.zig");
const keylib = @import("keylib");
const UpResult = keylib.ctap.authenticator.callbacks.UpResult;
const UvResult = keylib.ctap.authenticator.callbacks.UvResult;
const i18n = @import("i18n.zig");
const misc = @import("database/misc.zig");

conf: Config,
home: []const u8,

conf_abs_path: []const u8,
db_abs_path: []const u8,

/// The open database
///
/// This variable is accessed by the main and the authenticator
/// thread if the application is in `main` state.
database: ?Database = null,

uv_result: UvResult = UvResult.Denied,
up_result: ?UpResult = null,

ts: ?i64 = null,

const tout1: i64 = 10; // seconds
const tout2: i64 = 60; // seconds

var s: ?@This() = null;

pub fn get() *@This() {
    if (s == null) {
        std.log.err("state not initialized! Exiting...", .{});
        std.process.exit(1);
    }

    return &s.?;
}

pub fn init(a: std.mem.Allocator, io: std.Io, home_: []const u8) !void {
    const conf = Config.load(a, io, home_) catch |e| {
        std.log.err("unable to load configuration file ({any})", .{e});
        return e;
    };

    s = .{
        .conf = conf,
        .home = try a.dupe(u8, home_),
        .conf_abs_path = try confPathAlloc(a, home_),
        .db_abs_path = try dbPathAlloc(a, home_, conf.db_path),
    };

    std.log.info("initialized configuration", .{});
    std.log.info("conf path: {s}", .{s.?.conf_abs_path});
    std.log.info("db path: {s}", .{s.?.db_abs_path});
}

pub fn deinit(a: std.mem.Allocator) void {
    if (s) |*s_| {
        s_.deinitDb();
        s_.conf.deinit(a);
        a.free(s_.home);
        a.free(s_.db_abs_path);
        a.free(s_.conf_abs_path);
    }
    s = null;
}

pub fn reloadConfig(self: *@This(), a: std.mem.Allocator, io: std.Io) !void {
    std.log.info("reloading configuration", .{});

    // First load new config
    const conf = Config.load(a, io, self.home) catch |e| {
        std.log.err("unable to load configuration file ({any})", .{e});
        return e;
    };
    errdefer conf.deinit(a);
    const db_abs_path = try dbPathAlloc(a, self.home, self.conf.db_path);

    // Deinit old config
    self.deinitDb();
    self.conf.deinit(a);
    a.free(self.db_abs_path);

    // Assign new config
    self.conf = conf;
    self.db_abs_path = db_abs_path;
}

pub fn deinitDb(self: *@This()) void {
    if (self.database) |*db| {
        std.log.info("deinitializing database", .{});
        db.deinit(db);
    }
    self.database = null;
    std.log.info("resetting uv/ up state", .{});
    self.ts = null;
    self.uv_result = UvResult.Denied;
    self.up_result = null;
}

fn dbPathAlloc(a: std.mem.Allocator, home: []const u8, p: []const u8) ![]const u8 {
    return if (p.len >= 2 and p[0] == '~' and p[1] == '/') blk: {
        break :blk try std.fmt.allocPrint(
            a,
            "{s}/{s}",
            .{ home, p },
        );
    } else if (p.len >= 1 and p[0] == '/') blk: {
        break :blk try a.dupe(u8, p);
    } else error.InvalidPath;
}

fn confPathAlloc(a: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        a,
        "{s}/{s}/{s}",
        .{ home, Config.config_dir_name, Config.config_name },
    );
}

pub fn update(self: *@This(), io: std.Io) void {
    if (self.ts) |ts_| {
        const now = std.Io.Timestamp.now(io, .real).toSeconds();
        if (now - ts_ > tout2) {
            self.deinitDb();
        } else if (now - ts_ > tout1) {
            // Requre UP after 10 seconds
            self.uv_result = UvResult.Accepted;
            self.up_result = null;
        }
    }
}

pub fn authenticate(self: *@This(), a: std.mem.Allocator, io: std.Io) !void {
    if (self.ts != null) return; // nothing to do

    var i: usize = 3;

    const f = misc.openFile(io, self.conf.db_path, self.home) catch |e| blk: {
        if (e != error.WouldBlock) {
            if (std.mem.containsAtLeast(u8, self.conf.db_path, 1, ".ccdb")) {
                std.log.err("Databases of the format '.ccdb' are deprecated. Please check your config or use an earlier version of PassKeeZ.", .{});
                return error.DeprecatedDatabaseFormat;
            } else if (std.mem.containsAtLeast(u8, self.conf.db_path, 1, ".kdbx")) {
                break :blk Database.kdbx.createDialog(a, io, self.conf.db_path, self.home) catch |e_| {
                    std.log.err("unable to create database '{s}' ({any})", .{ self.conf.db_path, e });
                    return e_;
                };
            } else {
                std.log.err("invalid database path or name '{s}'", .{self.conf.db_path});
                return error.InvalidDatabasePathOrName;
            }
        } else {
            return error.WouldBlock;
        }
    };
    f.close(io);

    outer: while (i > 0) : (i -= 1) {
        var password = std.process.run(a, io, .{
            .argv = &.{
                "zigenity",
                "--password",
                "--window-icon=/usr/share/passkeez/passkeez.png",
                i18n.get(self.conf.lang).unlock_database_title,
                i18n.get(self.conf.lang).unlock_database,
                i18n.get(self.conf.lang).unlock_database_ok,
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
        //std.debug.print("{any}", .{password});

        switch (password.term.exited) {
            0 => {
                var db = if (std.mem.containsAtLeast(u8, self.conf.db_path, 1, ".ccdb")) {
                    std.log.err("unsupported database {s}", .{self.conf.db_path});
                    const r = std.process.run(a, io, .{
                        .argv = &.{
                            "zigenity",
                            "--question",
                            "--window-icon=/usr/share/passkeez/passkeez.png",
                            "--icon=/usr/share/passkeez/passkeez-error.png",
                            "Databases of type .ccdb are deprecated and no longer supported.",
                            "Invalid database format",
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
                    return error.Failed;
                } else if (std.mem.containsAtLeast(u8, self.conf.db_path, 1, ".kdbx")) blk: {
                    break :blk Database.kdbx.Database(
                        self.conf.db_path,
                        self.home,
                        password.stdout[0 .. password.stdout.len - 1],
                        a,
                        io,
                    ) catch {
                        std.log.err("unable to instantiate Database", .{});
                        continue :outer;
                    };
                } else {
                    std.log.err("unsupported database {s}", .{self.conf.db_path});
                    const r = std.process.run(a, io, .{
                        .argv = &.{
                            "zigenity",
                            "--question",
                            "--window-icon=/usr/share/passkeez/passkeez.png",
                            "--icon=/usr/share/passkeez/passkeez-error.png",
                            "Unable to open the configured database.",
                            "Invalid database format",
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
                    return error.Failed;
                };

                db.init(&db) catch |e| {
                    std.log.err("unable to decrypt database {s} ({any})", .{ self.conf.db_path, e });
                    const r = std.process.run(a, io, .{
                        .argv = &.{
                            "zigenity",
                            "--question",
                            "--window-icon=/usr/share/passkeez/passkeez.png",
                            "--icon=/usr/share/passkeez/passkeez-error.png",
                            i18n.get(self.conf.lang).database_decryption_failed,
                            i18n.get(self.conf.lang).database_decryption_failed_title,
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

                self.ts = std.Io.Timestamp.now(io, .real).toSeconds();
                self.uv_result = UvResult.AcceptedWithUp;
                self.up_result = UpResult.Accepted;
                self.database = db;
                return;
            },
            else => {
                return error.RejectedByUser;
            },
        }
    } else {
        const r = std.process.run(a, io, .{
            .argv = &.{
                "zigenity",
                "--question",
                "--window-icon=/usr/share/passkeez/passkeez.png",
                "--icon=/usr/share/passkeez/passkeez-error.png",
                i18n.get(self.conf.lang).too_many_attempts,
                i18n.get(self.conf.lang).too_many_attempts_title,
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
