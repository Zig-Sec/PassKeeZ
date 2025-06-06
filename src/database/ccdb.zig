const std = @import("std");
const TDatabase = @import("../Database.zig");
const misc = @import("misc.zig");
const ccdb = @import("ccdb");
const keylib = @import("keylib");
const Credential = keylib.ctap.authenticator.Credential;
const i18n = @import("../i18n.zig");
const State = @import("../state.zig");

pub fn Database(
    path: []const u8,
    pw: []const u8,
    allocator: std.mem.Allocator,
) TDatabase.Error!TDatabase {
    return TDatabase{
        .path = allocator.dupe(u8, path) catch return error.OutOfMemory,
        .pw = allocator.dupe(u8, pw) catch return error.OutOfMemory,
        .allocator = allocator,
        .init = init,
        .deinit = deinit,
        .save = save,
        .getCredential = getCredential,
        .setCredential = setCredential,
        .deleteCredential = deleteCredential,
    };
}

fn init(self: *TDatabase) TDatabase.Error!void {
    var file = misc.openFile(self.path) catch |e| blk: {
        if (e == error.WouldBlock) {
            std.log.err("Cannot open database: ({any})", .{e});
            return error.WouldBlock;
        } else { // FileNotFound
            break :blk createDialog(self.allocator, self.path) catch |e2| {
                std.log.err("Cannot open database: ({any})", .{e2});
                return error.FileNotFound;
            };
        }
    };
    defer file.close();

    const mem = file.readToEndAlloc(self.allocator, 50_000_000) catch return error.FileError;
    defer self.allocator.free(mem);

    const db = try self.allocator.create(ccdb.Db);
    errdefer self.allocator.destroy(db);

    db.* = ccdb.Db.open(
        mem,
        self.allocator,
        std.time.milliTimestamp,
        std.crypto.random,
        self.pw,
    ) catch return error.DatabaseError;

    self.db = db;
}

fn deinit(self: *const TDatabase) void {
    if (self.db) |db| {
        var db_ = @as(*ccdb.Db, @alignCast(@ptrCast(db)));
        db_.deinit();
    }
    self.allocator.free(self.path);
    self.allocator.free(self.pw);
}

fn save(self: *const TDatabase, a: std.mem.Allocator) TDatabase.Error!void {
    var db = @as(*ccdb.Db, @alignCast(@ptrCast(self.db.?)));
    const raw = db.seal(a) catch |e| {
        std.log.err("Cannot to seal database: {any}", .{e});
        return error.DatabaseError;
    };
    defer {
        @memset(raw, 0);
        a.free(raw);
    }
    misc.writeFile(self.path, raw, a) catch |e| {
        std.log.err("Cannot to save database: {any}", .{e});
        return error.DatabaseError;
    };
}

fn deleteCredential(
    self: *const TDatabase,
    id: [36]u8,
) TDatabase.Error!void {
    const db = @as(*ccdb.Db, @alignCast(@ptrCast(self.db.?)));

    db.body.deleteEntryById(id) catch |e| {
        std.log.err("Cannot to delete entry with id: {s} ({any})", .{ id, e });
        return error.DoesNotExist;
    };

    // persist data
    save(self, self.allocator) catch {
        return error.Other;
    };
}

fn getCredential(
    self: *const TDatabase,
    rp_id: ?[]const u8,
    rp_id_hash: ?[32]u8,
    idx: *usize,
) TDatabase.Error!Credential {
    const db = @as(*ccdb.Db, @alignCast(@ptrCast(self.db.?)));

    while (db.body.entries.len > idx.*) {
        const entry = db.body.entries[idx.*];
        idx.* += 1;

        if (rp_id) |rpId| {
            if (entry.url) |url| {
                if (std.mem.eql(u8, url, rpId)) {
                    return credentialFromEntry(&entry) catch {
                        std.log.warn("Entry with id {s} is not a credential ({any})", .{
                            entry.uuid[0..],
                            entry,
                        });
                        continue;
                    };
                }
            }
        } else if (rp_id_hash) |hash| {
            var digest: [32]u8 = .{0} ** 32;

            if (entry.url) |url| {
                std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});

                if (std.mem.eql(u8, &hash, &digest)) {
                    return credentialFromEntry(&entry) catch {
                        std.log.warn("Entry with id {s} is not a credential ({any})", .{
                            entry.uuid[0..],
                            entry,
                        });
                        continue;
                    };
                }
            }
        } else { // if no rpId is given: return every entry
            return credentialFromEntry(&entry) catch {
                std.log.warn("Entry with id {s} is not a credential ({any})", .{
                    entry.uuid[0..],
                    entry,
                });
                continue;
            };
        }
    }

    return error.DoesNotExist;
}

fn setCredential(
    self: *const TDatabase,
    data: Credential,
) TDatabase.Error!void {
    const db = @as(*ccdb.Db, @alignCast(@ptrCast(self.db.?)));

    var e = if (db.body.getEntryById(data.id.get())) |e| e else blk: {
        var e = db.body.newEntry() catch {
            std.log.err("unable to create new entry", .{});
            return error.Other;
        };
        // We use the uuid generated by keylib as uuid for our entry.
        @memcpy(e.uuid[0..], data.id.get());
        break :blk e;
    };

    // update user
    e.setUser(.{
        .id = data.user.id.get(),
        .name = if (data.user.name) |name| name.get() else null,
        .display_name = if (data.user.displayName) |name| name.get() else null,
    }) catch {
        std.log.err("unable to update name of entry with id {s}", .{data.id.get()});
        return error.Other;
    };

    // update rp
    e.setUrl(data.rp.id.get()) catch {
        std.log.err("unable to update url of entry with id {s}", .{data.id.get()});
        return error.Other;
    };

    e.times.cnt = data.sign_count;

    e.setKey(data.key);

    if (e.tags) |tags| {
        for (tags, 0..) |tag, i| {
            if (tag.len < 8) continue;
            if (!std.mem.eql(u8, "policy:", tag[0..7])) continue;

            e.removeTag(i);

            break;
        }
    }

    const p = std.fmt.allocPrint(self.allocator, "policy:{s}", .{
        data.policy.toString(),
    }) catch {
        std.log.err("unable to allocate memory for policy of entry with id {s}", .{data.id.get()});
        return error.Other;
    };
    defer self.allocator.free(p);

    e.addTag(p) catch {
        std.log.err("unable to update policy of entry with id {s}", .{data.id.get()});
        return error.Other;
    };

    // persist data
    save(self, self.allocator) catch {
        return error.Other;
    };
}

// ----------------- Helper ----------------------

pub fn createDialog(allocator: std.mem.Allocator, path: []const u8) !std.fs.File {
    const r1 = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "zigenity",
            "--question",
            "--window-icon=/usr/share/passkeez/passkeez.png",
            "--icon=/usr/share/passkeez/passkeez-question.png",
            i18n.get(State.conf.lang).no_database_title,
            i18n.get(State.conf.lang).no_database,
        },
    }) catch |e| {
        std.log.err("unable to execute zigenity ({any})", .{e});
        return error.Other;
    };

    defer {
        allocator.free(r1.stdout);
        allocator.free(r1.stderr);
    }

    switch (r1.term.Exited) {
        0 => {},
        else => return error.CreateDbRejected,
    }

    outer: while (true) {
        var r2 = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "zigenity",
                "--password",
                "--window-icon=/usr/share/passkeez/passkeez.png",
                i18n.get(State.conf.lang).new_database_title,
                i18n.get(State.conf.lang).new_database,
                i18n.get(State.conf.lang).new_database_ok,
                "--cancel-label=Cancel",
            },
        }) catch |e| {
            std.log.err("unable to execute zigenity ({any})", .{e});
            return error.Other;
        };
        defer {
            allocator.free(r2.stdout);
            allocator.free(r2.stderr);
        }

        switch (r2.term.Exited) {
            0 => {
                std.log.info("{s}", .{r2.stdout});
                const pw1 = r2.stdout[0 .. r2.stdout.len - 1];

                if (pw1.len < 8) {
                    const r = std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &.{
                            "zigenity",
                            "--question",
                            "--window-icon=/usr/share/passkeez/passkeez.png",
                            "--icon=/usr/share/passkeez/passkeez-error.png",
                            "--text=Password must be 8 characters long",
                            "--title=PassKeeZ: Error",
                            "--timeout=15",
                            "--switch-cancel",
                            "--ok-label=Ok",
                        },
                    }) catch |e| {
                        std.log.err("unable to execute zigenity ({any})", .{e});
                        return error.Other;
                    };
                    defer {
                        allocator.free(r.stdout);
                        allocator.free(r.stderr);
                    }
                    continue :outer;
                }

                const f_db = misc.createFile(path) catch |e| {
                    std.log.err("Cannot create new database file: {any}", .{e});
                    return error.FileError;
                };
                errdefer f_db.close();

                var store = ccdb.Db.new("PassKeeZ", "Passkeys", .{}, allocator) catch |e| {
                    std.log.err("Cannot create database: {any}", .{e});
                    return error.DatabaseError;
                };
                defer store.deinit();
                store.setKey(pw1) catch |e| {
                    std.log.err("Cannot set database key: {any}", .{e});
                    return error.DatabaseError;
                };
                const raw = store.seal(allocator) catch |e| {
                    std.log.err("Cannot seal database: {any}", .{e});
                    return error.DatabaseError;
                };
                defer {
                    @memset(raw, 0);
                    allocator.free(raw);
                }

                f_db.writer().writeAll(raw) catch |e| {
                    std.log.err("Cannot write to database: {any}", .{e});
                    return error.DatabaseError;
                };

                const r = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{
                        "zigenity",
                        "--question",
                        "--window-icon=/usr/share/passkeez/passkeez.png",
                        "--icon=/usr/share/passkeez/passkeez-ok.png",
                        i18n.get(State.conf.lang).database_created,
                        i18n.get(State.conf.lang).database_created_title,
                        "--timeout=15",
                        "--switch-cancel",
                        "--ok-label=Ok",
                    },
                }) catch |e| {
                    std.log.err("Cannot execute zigenity: {any}", .{e});
                    return error.Other;
                };
                defer {
                    allocator.free(r.stdout);
                    allocator.free(r.stderr);
                }

                return f_db;
            },
            else => return error.CreateDbRejected,
        }
    }
}

pub fn credentialFromEntry(entry: *const ccdb.Entry) !keylib.ctap.authenticator.Credential {
    if (entry.user == null) return error.MissingUser;
    if (entry.url == null) return error.MissingRelyingParty;
    if (entry.key == null) return error.MissingKey;
    if (entry.tags == null) return error.MissingPolicy;

    const policy = blk: for (entry.tags.?) |tag| {
        if (tag.len < 8) continue;
        if (!std.mem.eql(u8, "policy:", tag[0..7])) continue;

        if (keylib.ctap.extensions.CredentialCreationPolicy.fromString(tag[7..])) |p| {
            break :blk p;
        } else {
            return error.MissingPolicy;
        }
    } else {
        return error.MissingPolicy;
    };

    return .{
        .id = (try keylib.common.dt.ABS64B.fromSlice(entry.uuid[0..])).?,
        .user = try keylib.common.User.new(entry.user.?.id.?, entry.user.?.name, entry.user.?.display_name),
        .rp = try keylib.common.RelyingParty.new(entry.url.?, null),
        .sign_count = if (entry.times.cnt) |cnt| cnt else 0,
        .key = entry.key.?,
        .created = entry.times.creat,
        .discoverable = true,
        .policy = policy,
    };
}
