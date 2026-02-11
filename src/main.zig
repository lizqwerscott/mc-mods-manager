const std = @import("std");

const toml = @import("toml");

const mc_mods_manager = @import("mc_mods_manager");

const LocalConfig = struct {
    path: []const u8,
};

const RemoteConfig = struct {
    host: []const u8,
    path: []const u8,
};

const Config = struct { local: *LocalConfig, remote: *RemoteConfig };

var stdout_buffer: [512]u8 = undefined;
// var stdin_buffer: [512]u8 = undefined;
var stderr_buffer: [512]u8 = undefined;

var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

// var stdin_writer = std.fs.File.stdin().writer(&stdin_buffer);
// const stdin = &stdin_writer.interface;

var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const main_allocator = arena.allocator();

    const config_path = try parseCommandLineWithArena(main_allocator);
    defer main_allocator.free(config_path);

    if (std.fs.cwd().access(config_path, .{})) {
        try stdout.print("load config {s}\n", .{config_path});
        try stdout.flush();
        const config = try loadConfig(config_path, main_allocator);

        try stdout.print("Scan Local Dir: {s}\n", .{config.local.path});
        try stdout.flush();

        const local_mods = try mc_mods_manager.scanDirFile(config.local.path, main_allocator);
        try stdout.print("\nFound {d} mods:\n", .{local_mods.len});
        try stdout.flush();

        for (local_mods, 0..) |mod, i| {
            for (mod.mods) |mod_info| {
                try stdout.print("Mod {d}: {s} (v{s})\n", .{ i + 1, mod_info.displayName, mod_info.version });
            }
            try stdout.flush();
        }
    } else |err| {
        switch (err) {
            error.FileNotFound => {
                try stderr.print("Error: {s} not exists!", .{config_path});
            },
            else => {
                try stderr.print("Cannot access config file '{s}': {s}\n", .{ config_path, @errorName(err) });
            },
        }
        try stderr.flush();
        return;
    }
}

fn parseCommandLineWithArena(main_allocator: std.mem.Allocator) ![]const u8 {
    const DEFAULT_CONFIG = "./config.toml";

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var args_iter = try std.process.argsWithAllocator(arena_allocator);
    defer args_iter.deinit();

    _ = args_iter.next();

    if (args_iter.next()) |arg| {
        return try main_allocator.dupe(u8, arg);
    }

    return try main_allocator.dupe(u8, DEFAULT_CONFIG);
}

fn loadConfig(config_path: []const u8, main_allocator: std.mem.Allocator) !Config {
    var parser = toml.Parser(Config).init(main_allocator);
    defer parser.deinit();

    var result = try parser.parseFile(config_path);

    defer result.deinit();

    const config = result.value;

    try stdout.writeAll("Local:\n");
    try stdout.print("  path: {s}\n", .{config.local.path});

    try stdout.writeAll("Remote:\n");
    try stdout.print("  host: {s}\n", .{config.remote.host});
    try stdout.print("  path: {s}\n", .{config.remote.path});
    try stdout.flush();

    return config;
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
