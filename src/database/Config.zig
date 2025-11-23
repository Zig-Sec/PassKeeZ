const std = @import("std");
const misc = @import("misc.zig");

const config_path = "~/.passkeez/config.json";

db_path: []const u8 = "",
lang: []const u8 = "english",

pub fn load(a: std.mem.Allocator) !@This() {
    var file = openOrCreate(a) catch |e| {
        std.log.err(
            "unable to open or create '{s}' ({any})",
            .{ config_path, e },
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

pub fn save(self: *const @This()) !void {
    const home = std.c.getenv("HOME");
    if (home == null) return error.NoHome;
    var home_dir = try std.fs.openDirAbsolute(home.?[0..std.zig.c_builtins.__builtin_strlen(home.?)], .{});
    defer home_dir.close();
    var file = try home_dir.createFile(".passkeez/config.json", .{ .exclusive = false });
    defer file.close();
    try std.json.stringify(self, .{}, file.writer());
}

pub fn create(a: std.mem.Allocator) !void {
    const home = std.c.getenv("HOME");
    if (home == null) return error.NoHome;
    var home_dir = try std.fs.openDirAbsolute(home.?[0..std.zig.c_builtins.__builtin_strlen(home.?)], .{});
    defer home_dir.close();
    home_dir.makeDir(".passkeez") catch {};
    var file = try home_dir.createFile(".passkeez/config.json", .{ .exclusive = true });
    defer file.close();

    var str = std.Io.Writer.Allocating.init(a);
    defer str.deinit();

    const x = @This(){};
    try std.json.Stringify.value(x, .{}, &str.writer);

    try file.writeAll(str.written());
}

pub fn openOrCreate(a: std.mem.Allocator) !std.fs.File {
    var created = false;
    const rp = try std.fs.realpathAlloc(a, config_path);
    defer a.deinit(rp);

    var f = std.fs.openFileAbsolute(
        rp,
        .{ .mode = .read_write },
    ) catch blk: {
        const f = try std.fs.createFileAbsolute(
            rp,
            .{ .mode = .read_write },
        );
        created = true;
        break :blk f;
    };
    errdefer f.close();

    if (created) {
        var writer = f.writer(&.{});
        writer.interface.flush();

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
}
