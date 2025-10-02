const std = @import("std");
const TDatabase = @import("../Database.zig");
const misc = @import("misc.zig");
const kdbx = @import("kdbx");
const keylib = @import("keylib");
const Credential = keylib.ctap.authenticator.Credential;
const i18n = @import("../i18n.zig");
const State = @import("../state.zig");
const Uuid = @import("uuid");
const cbor = @import("zbor");

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

    var reader = std.Io.Reader.fixed(mem);

    const db = try self.allocator.create(kdbx.Database);
    errdefer self.allocator.destroy(db);

    const db_key = kdbx.DatabaseKey{
        .password = try self.allocator.dupe(u8, self.pw),
        .allocator = self.allocator,
    };
    defer db_key.deinit();

    db.* = kdbx.Database.open(&reader, .{
        .allocator = self.allocator,
        .key = db_key,
    }) catch |e| {
        std.log.err("unable to decrypt database {any}", .{e});
        return error.DatabaseError;
    };

    self.db = db;
}

fn deinit(self: *const TDatabase) void {
    if (self.db) |db| {
        var db_ = @as(*kdbx.Database, @ptrCast(@alignCast(db)));
        db_.deinit();
    }
    self.allocator.free(self.path);
    self.allocator.free(self.pw);
}

fn save(self: *const TDatabase, a: std.mem.Allocator) TDatabase.Error!void {
    var db = @as(*kdbx.Database, @ptrCast(@alignCast(self.db.?)));

    var raw = std.Io.Writer.Allocating.init(a);
    defer raw.deinit();

    const db_key = kdbx.DatabaseKey{
        .password = try self.allocator.dupe(u8, self.pw),
        .allocator = self.allocator,
    };
    defer db_key.deinit();

    db.save(
        &raw.writer,
        db_key,
        a,
    ) catch |e| {
        std.log.err("Cannot to seal database: {any}", .{e});
        return error.DatabaseError;
    };

    misc.writeFile(self.path, raw.written(), a) catch |e| {
        std.log.err("Cannot to save database: {any}", .{e});
        return error.DatabaseError;
    };
}

fn deleteCredential(
    self: *const TDatabase,
    urn: [36]u8,
) TDatabase.Error!void {
    const db = @as(*kdbx.Database, @ptrCast(@alignCast(self.db.?)));

    const grp = db.body.root.getGroupByName("Passkeys") orelse return;
    const id = Uuid.urn.deserialize(&urn) catch return;

    var e1 = grp.removeEntryByUuid(id);
    if (e1) |*e1_| e1_.deinit();

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
    const db: *kdbx.Database = @as(*kdbx.Database, @ptrCast(@alignCast(self.db.?)));

    const grp = db.body.root.getGroupByName("Passkeys") orelse return error.DatabaseError;
    while (grp.entries.items.len > idx.*) {
        const entry = grp.entries.items[idx.*];
        idx.* += 1;

        if (!entry.isValidKeePassXCPasskey()) continue;

        if (rp_id) |rpId| {
            if (std.mem.eql(u8, entry.get("KPEX_PASSKEY_RELYING_PARTY").?, rpId)) {
                return credentialFromEntry(&entry) catch |e| {
                    std.log.err("Entry is not a KeePassXC passkey ({any})", .{e});
                    continue;
                };
            }
        } else if (rp_id_hash) |hash| {
            var digest: [32]u8 = .{0} ** 32;
            const url = entry.get("KPEX_PASSKEY_RELYING_PARTY").?;
            std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});

            if (std.mem.eql(u8, &hash, &digest)) {
                return credentialFromEntry(&entry) catch |e| {
                    std.log.err("Entry is not a KeePassXC passkey ({any})", .{e});
                    continue;
                };
            }
        } else {
            return credentialFromEntry(&entry) catch |e| {
                std.log.err("Entry is not a KeePassXC passkey ({any})", .{e});
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
    const db: *kdbx.Database = @as(*kdbx.Database, @ptrCast(@alignCast(self.db.?)));

    const grp = db.body.root.getGroupByName("Passkeys") orelse return error.DatabaseError;
    const id = Uuid.urn.deserialize(data.id.get()) catch {
        std.log.err("The entry id {s} is not a UUID", .{data.id.get()});
        return error.Other;
    };

    const e = if (grp.getEntryById(id)) |e| e else blk: {
        const e = grp.createEntry() catch {
            std.log.err("unable to create new entry", .{});
            return error.Other;
        };
        // We use the uuid generated by keylib as uuid for our entry.
        e.uuid = id;
        break :blk e;
    };
    errdefer {
        var e_ = grp.removeEntryByUuid(id);
        if (e_) |*e__| e__.deinit();
    }

    const pem_key = switch (data.key) {
        .P256 => |k| blk: {
            if (k.alg != .Es256) return error.InvalidCipherSuite;
            const priv = std.crypto.sign.ecdsa.EcdsaP256Sha256.SecretKey.fromBytes(k.d.?) catch return error.Other;
            const kp = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.fromSecretKey(priv) catch return error.Other;

            const pem_key = try kdbx.pem.pemFromKey(kp, self.allocator);
            break :blk pem_key;
        },
    };
    defer self.allocator.free(pem_key);

    e.setKeePassXCPasskeyValues(
        data.rp.id.get(),
        if (data.user.name) |name| name.get() else "",
        data.user.id.get(),
        pem_key,
    ) catch return TDatabase.Error.DatabaseError;

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
                //std.debug.print("{s}", .{r2.stdout});
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

                var database = kdbx.Database.new(.{
                    .generator = "PassKeeZ",
                    .name = "PassKeeZ Database",
                    .allocator = allocator,
                }) catch |e| {
                    std.log.err("Cannot create database: {any}", .{e});
                    return error.DatabaseError;
                };
                defer database.deinit();

                const grp = kdbx.Group.new("Passkeys", allocator) catch |e| {
                    std.log.err("Cannot create group: {any}", .{e});
                    return error.DatabaseError;
                };
                database.body.root.addGroup(grp) catch |e| {
                    std.log.err("Cannot create group: {any}", .{e});
                    return error.DatabaseError;
                };

                const db_key = kdbx.DatabaseKey{
                    .password = try allocator.dupe(u8, pw1),
                    .allocator = allocator,
                };
                defer db_key.deinit();

                var raw = std.Io.Writer.Allocating.init(allocator);
                defer raw.deinit();

                database.save(
                    &raw.writer,
                    db_key,
                    allocator,
                ) catch |e| {
                    std.log.err("Cannot seal database: {any}", .{e});
                    return error.DatabaseError;
                };

                var writer = f_db.writer(&.{});
                writer.interface.writeAll(raw.written()) catch |e| {
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

fn credentialFromEntry(entry: *const kdbx.Entry) !keylib.ctap.authenticator.Credential {
    // we have already verified that this is a valid KeePassXC passkey
    var buffer: [8192]u8 = .{0} ** 8192;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const pem_key = entry.get("KPEX_PASSKEY_PRIVATE_KEY_PEM").?;
    const k_ = kdbx.pem.asymmetricKeyPairFromPem(pem_key, allocator) catch return error.InvalidKey;

    const k = switch (k_) {
        .EcdsaP256Sha256 => |k| cbor.cose.Key.fromP256PrivPub(.Es256, k.secret_key, k.public_key),
    };

    const cred_id = entry.get("KPEX_PASSKEY_CREDENTIAL_ID").?;
    const user_name = entry.get("KPEX_PASSKEY_USERNAME").?;
    const user_handle = entry.get("KPEX_PASSKEY_USER_HANDLE").?;
    const rp_id = entry.get("KPEX_PASSKEY_RELYING_PARTY").?;

    const l = try std.base64.standard.Decoder.calcSizeForSlice(user_handle);
    const uid = try allocator.alloc(u8, l);
    defer std.crypto.secureZero(u8, uid);
    try std.base64.standard.Decoder.decode(uid, user_handle);

    return .{
        .id = (try keylib.common.dt.ABS64B.fromSlice(cred_id)).?,
        .user = try keylib.common.User.new(uid, user_name, user_name),
        .rp = try keylib.common.RelyingParty.new(rp_id, null),
        .sign_count = 0,
        .key = k,
        .created = 0,
        .discoverable = true,
        .policy = .userVerificationOptional,
    };
}
