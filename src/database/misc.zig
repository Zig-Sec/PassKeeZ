const std = @import("std");

pub fn openFile(io: std.Io, path: []const u8, home: []const u8) !std.Io.File {
    return if (path.len >= 2 and path[0] == '~' and path[1] == '/') blk: {
        var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
        defer home_dir.close(io);
        const file = try home_dir.openFile(io, path[2..], .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        break :blk file;
    } else if (path.len >= 1 and path[0] == '/') blk: {
        const file = try std.Io.Dir.openFileAbsolute(io, path[0..], .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        break :blk file;
    } else blk: {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        break :blk file;
    };
}

pub fn createFile(io: std.Io, path: []const u8, home: []const u8) !std.Io.File {
    return if (path.len >= 2 and path[0] == '~' and path[1] == '/') blk: {
        var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
        defer home_dir.close(io);
        const file = try home_dir.createFile(io, path[2..], .{
            .exclusive = true,
        });
        break :blk file;
    } else if (path.len >= 1 and path[0] == '/') blk: {
        const file = try std.Io.Dir.createFileAbsolute(io, path[0..], .{
            .exclusive = true,
        });
        break :blk file;
    } else blk: {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .exclusive = true,
        });
        break :blk file;
    };
}

pub fn writeFile(a: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8, home: []const u8) !void {
    const tmp_file_name = "/tmp/passkeez.tmp";

    var f2 = std.Io.Dir.createFileAbsolute(io, tmp_file_name, .{ .truncate = true }) catch |e| {
        std.log.err("Cannot create temporary file: {any}", .{e});
        return e;
    };
    defer f2.close(io);
    var writer = f2.writer(io, &.{});

    writer.interface.writeAll(data) catch |e| {
        std.log.err("Cannot persist data: ({any})", .{e});
        return e;
    };

    if (path.len >= 2 and path[0] == '~' and path[1] == '/') {
        // TODO: check home
        const new_file_path = std.fmt.allocPrint(a, "{s}/{s}", .{ home, path[2..] }) catch |e| {
            std.log.err("out of memory", .{});
            return e;
        };
        defer a.free(new_file_path);

        std.Io.Dir.copyFileAbsolute(tmp_file_name, new_file_path, io, .{}) catch |e| {
            std.log.err("Cannot save file to `{s}`: {any}", .{ new_file_path, e });
            return e;
        };
    } else if (path.len >= 1 and path[0] == '/') {
        std.Io.Dir.copyFileAbsolute(tmp_file_name, path, io, .{}) catch |e| {
            std.log.err("Cannot save file to `{s}`: {any}", .{ path, e });
            return e;
        };
    } else {
        std.log.err("support for file prefix not implemented yet!!!", .{});
        return error.InvalidFilePrefix;
    }
}
