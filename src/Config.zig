const std = @import("std");

pub const config_dir_name = ".passkeez";
pub const config_name = "config.json";
pub const default_db_path = "~/" ++ config_dir_name ++ "/db.kdbx";

/// Path to the .kdbx database
db_path: []const u8 = default_db_path,
/// Language
lang: []const u8 = "english",
/// MLDSA signature algorithm support (TODO: WIP)
mldsa: bool = false,
/// Lock memory
/// Probably requires raising the limits in /etc/security/limits.conf
///                hard    memlock          65536
///                soft    memlock          65536
mlock: bool = false,
/// Grace window in which a new User Presence (UP) request is
/// auto-accepted without re-prompting
tout_up: u64 = 10,
/// After this idle period the database is fully deinitialized
tout_db: u64 = 60,

pub fn load(a: std.mem.Allocator, io: std.Io, home: []const u8) !@This() {
    var file = openOrCreate(a, io, home) catch |e| {
        std.log.err(
            "unable to open or create '~/{s}/{s}' ({any})",
            .{ config_dir_name, config_name, e },
        );
        return error.NotFound;
    };
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &buffer);

    const mem = try reader.interface.readAlloc(a, try file.length(io));
    defer a.free(mem);

    const parsed = try std.json.parseFromSlice(
        @This(),
        a,
        mem,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    var conf = parsed.value;
    const empty_db_path = conf.db_path.len == 0;
    // Omitted JSON fields use static defaults, which deinit must not free.
    conf.db_path = try a.dupe(u8, if (empty_db_path) default_db_path else conf.db_path);
    errdefer a.free(conf.db_path);
    conf.lang = try a.dupe(u8, conf.lang);
    errdefer a.free(conf.lang);

    if (empty_db_path) {
        try conf.write(file, io);
    }

    return conf;
}

pub fn openOrCreate(a: std.mem.Allocator, io: std.Io, home_: []const u8) !std.Io.File {
    _ = a;

    var created = false;

    var home = try std.Io.Dir.openDirAbsolute(io, home_, .{});
    defer home.close(io);

    var conf_dir = try home.createDirPathOpen(io, config_dir_name, .{});
    defer conf_dir.close(io);

    var f = conf_dir.openFile(
        io,
        config_name,
        .{ .mode = .read_write },
    ) catch |e| blk: {
        if (e != error.FileNotFound) return e;
        const f = try conf_dir.createFile(
            io,
            config_name,
            .{ .read = true },
        );
        created = true;
        break :blk f;
    };
    errdefer f.close(io);

    if (created) {
        const x = @This(){};
        try x.write(f, io);
    }

    return f;
}

fn write(self: *const @This(), file: std.Io.File, io: std.Io) !void {
    var writer = file.writer(io, &.{});
    try std.json.Stringify.value(
        self.*,
        .{ .whitespace = .indent_2 },
        &writer.interface,
    );
    try writer.interface.flush();
    try file.setLength(io, writer.pos);
}

pub fn deinit(self: *const @This(), a: std.mem.Allocator) void {
    a.free(self.db_path);
    a.free(self.lang);
}
