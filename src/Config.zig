const std = @import("std");

pub const config_dir_name = ".passkeez";
pub const config_name = "config.json";

db_path: []const u8 = "",
lang: []const u8 = "english",

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

    return try std.json.parseFromSliceLeaky(
        @This(),
        a,
        mem,
        .{ .allocate = .alloc_always },
    );
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
    ) catch blk: {
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
        var writer = f.writer(io, &.{});

        const x = @This(){};
        try std.json.Stringify.value(
            x,
            .{ .whitespace = .indent_2 },
            &writer.interface,
        );
        try writer.interface.flush();

        try writer.seekTo(0);
    }

    return f;
}

pub fn deinit(self: *const @This(), a: std.mem.Allocator) void {
    a.free(self.db_path);
    a.free(self.lang);
}
