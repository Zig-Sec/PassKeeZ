const std = @import("std");

const commands = struct {
    const macos = struct {
        const read_cmd = "pbpaste";
        const write_cmd = "pbcopy";
    };
};

pub fn write(text: []const u8) !void {
    var proc = std.process.Child.init(
        &[_][]const u8{commands.macos.write_cmd},
        std.heap.page_allocator,
    );
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;

    try proc.spawn();
    try proc.stdin.?.writeAll(text);
    proc.stdin.?.close();
    proc.stdin = null;
    _ = try proc.wait();
}
