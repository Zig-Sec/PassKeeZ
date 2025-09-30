const std = @import("std");

pub fn openFile(path: []const u8) !std.fs.File {
    return if (path[0] == '~' and path[1] == '/') blk: {
        const home = std.c.getenv("HOME");
        if (home == null) return error.NoHome;
        var home_dir = try std.fs.openDirAbsolute(home.?[0..std.zig.c_builtins.__builtin_strlen(home.?)], .{});
        defer home_dir.close();
        const file = try home_dir.openFile(path[2..], .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        break :blk file;
    } else if (path[0] == '/') blk: {
        const file = try std.fs.openFileAbsolute(path[0..], .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        break :blk file;
    } else blk: {
        const file = try std.fs.cwd().openFile(path[0..], .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        break :blk file;
    };
}

pub fn createFile(path: []const u8) !std.fs.File {
    return if (path[0] == '~' and path[1] == '/') blk: {
        const home = std.c.getenv("HOME");
        if (home == null) return error.NoHome;
        var home_dir = try std.fs.openDirAbsolute(home.?[0..std.zig.c_builtins.__builtin_strlen(home.?)], .{});
        defer home_dir.close();
        const file = try home_dir.createFile(path[2..], .{
            .exclusive = true,
        });
        break :blk file;
    } else if (path[0] == '/') blk: {
        const file = try std.fs.createFileAbsolute(path[0..], .{
            .exclusive = true,
        });
        break :blk file;
    } else blk: {
        const file = try std.fs.cwd().createFile(path[0..], .{
            .exclusive = true,
        });
        break :blk file;
    };
}

pub fn writeFile(path: []const u8, data: []const u8, a: std.mem.Allocator) !void {
    const tmp_file_name = "/tmp/passkeez.tmp";

    var f2 = std.fs.createFileAbsolute(tmp_file_name, .{ .truncate = true }) catch |e| {
        std.log.err("Cannot create temporary file: {any}", .{e});
        return e;
    };
    defer f2.close();
    var writer = f2.writer(&.{});

    writer.interface.writeAll(data) catch |e| {
        std.log.err("Cannot persist data: ({any})", .{e});
        return e;
    };

    if (path[0] == '~' and path[1] == '/') {
        if (std.c.getenv("HOME")) |home| {
            // TODO: check home
            const new_file_path = std.fmt.allocPrint(a, "{s}/{s}", .{ home[0..std.zig.c_builtins.__builtin_strlen(home)], path[2..] }) catch |e| {
                std.log.err("out of memory", .{});
                return e;
            };
            defer a.free(new_file_path);

            std.fs.copyFileAbsolute(tmp_file_name, new_file_path, .{}) catch |e| {
                std.log.err("Cannot save file to `{s}`: {any}", .{ new_file_path, e });
                return e;
            };
        } else {
            std.log.err("no HOME path", .{});
            return error.NoHome;
        }
    } else if (path[0] == '/') {
        std.fs.copyFileAbsolute(tmp_file_name, path, .{}) catch |e| {
            std.log.err("Cannot save file to `{s}`: {any}", .{ path, e });
            return e;
        };
    } else {
        std.log.err("support for file prefix not implemented yet!!!", .{});
        return error.InvalidFilePrefix;
    }
}
