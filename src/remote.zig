const std = @import("std");

pub const RemoteCommandError = error{FailedExecute};

pub fn executeRemoteCommand(
    allocator: std.mem.Allocator,
    host: []const u8,
    command: []const u8,
    args: []const []const u8,
) ![]const u8 {
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    defer argv.deinit(allocator);

    try argv.append(allocator, "ssh");
    try argv.append(allocator, host);
    try argv.append(allocator, command);
    try argv.appendSlice(allocator, args);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        // .max_output_bytes = 10 * 1024 * 1024, // 允许的最大输出字节数，防止爆炸
    });
    defer {
        // allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                return result.stdout;
            } else {
                try stderr.print("Error: run {s} in {s}, exit code = {d}\n", .{ command, host, code });
                try stderr.print("Error: {s}\n", .{result.stderr});
            }
        },
        else => try stderr.print("Error: {}\n", .{result.term}),
    }
    return error.FailedExecute;
}

pub fn getRemoteDirFile(allocator: std.mem.Allocator, host: []const u8, dir_path: []const u8) ![][]const u8 {
    const remote_dir = try executeRemoteCommand(allocator, host, "ls", &[_][]const u8{ "-1", dir_path });
    var lines = std.mem.splitScalar(u8, remote_dir, '\n');

    var file_names = try std.ArrayList([]const u8).initCapacity(allocator, 0);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            continue;
        }
        try file_names.append(allocator, line);
    }

    return file_names.toOwnedSlice(allocator);
}
