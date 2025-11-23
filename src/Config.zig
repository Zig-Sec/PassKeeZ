const std = @import("std");

const config_dir_name = ".passkeez";
const config_name = "config.json";

db_path: []const u8 = "",
lang: []const u8 = "english",

pub fn load(a: std.mem.Allocator) !@This() {
    var file = openOrCreate(a) catch |e| {
        std.log.err(
            "unable to open or create '~/{s}/{s}' ({any})",
            .{ config_dir_name, config_name, e },
        );
        return error.NotFound;
    };
    defer file.close();

    const mem = try file.readToEndAlloc(a, 50_000_000);
    defer a.free(mem);

    return try std.json.parseFromSliceLeaky(
        @This(),
        a,
        mem,
        .{ .allocate = .alloc_always },
    );
}

pub fn getHomeDir(a: std.mem.Allocator) !std.fs.Dir {
    const home = try std.process.getEnvVarOwned(a, "HOME");
    defer a.free(home);

    return std.fs.openDirAbsolute(home, .{});
}

pub fn openOrCreate(a: std.mem.Allocator) !std.fs.File {
    var created = false;

    var home = try getHomeDir(a);
    defer home.close();

    var conf_dir = try home.makeOpenPath(config_dir_name, .{});
    defer conf_dir.close();

    var f = conf_dir.openFile(
        config_name,
        .{ .mode = .read_write },
    ) catch blk: {
        const f = try conf_dir.createFile(
            config_name,
            .{ .read = true },
        );
        created = true;
        break :blk f;
    };
    errdefer f.close();

    if (created) {
        var writer = f.writer(&.{});
        try writer.interface.flush();

        const x = @This(){};
        try std.json.Stringify.value(
            x,
            .{ .whitespace = .indent_2 },
            &writer.interface,
        );

        try f.seekTo(0);
    }

    return f;
}

pub fn deinit(self: *const @This(), a: std.mem.Allocator) void {
    a.free(self.db_path);
    a.free(self.lang);
}
