const std = @import("std");

const mc_mods_manager = @import("mc_mods_manager");

const config = @import("config.zig");

const SEPARATOR = "=" ** 60;
const SUB_SEPARATOR = "-" ** 40;

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
        const config_cli = try config.loadConfig(config_path, main_allocator);
        defer config_cli.deinit(main_allocator);

        try printSeparator(stdout);
        try printSectionHeader(stdout, "Configuration");
        try stdout.print("Config file: {s}\n", .{config_path});
        try stdout.print("\nLocal Settings:\n", .{});
        try stdout.print("  • Path: {s}\n", .{config_cli.local.path});
        try stdout.print("\nRemote Settings:\n", .{});
        try stdout.print("  • Host: {s}\n", .{config_cli.remote.host});
        try stdout.print("  • Path: {s}\n", .{config_cli.remote.path});
        try stdout.flush();

        try stdout.writeAll("\n");

        try printSeparator(stdout);
        try printSectionHeader(stdout, "Local Mods Scan");
        try stdout.print("Scanning directory: {s}\n\n", .{config_cli.local.path});
        try stdout.flush();

        const local_jars = try mc_mods_manager.scanDirFile(config_cli.local.path, main_allocator);
        try stdout.print("\nLocal Found {d} mods:\n", .{local_jars.len});
        try stdout.flush();

        for (local_jars, 0..) |jar, i| {
            try stdout.print("{d:>2}. {s}\n", .{ i + 1, jar.name });
            for (jar.mods) |mod_info| {
                try stdout.print("  └─ {s} (v{s})\n", .{ mod_info.displayName, mod_info.version });
            }
            if (jar.parsed_mod_info) |parsed_info| {
                try stdout.print("  └─ [Parsed] {s} (v{s})\n", .{ parsed_info.name, if (parsed_info.version) |version| version else "Null" });
            }
            if (jar.mods.len == 0 and jar.parsed_mod_info == null) {
                try printWarning(stdout, "No mod info found in this file\n", .{});
            }

            if (i < local_jars.len - 1) {
                try stdout.writeAll("\n");
            }

            try stdout.flush();
        }

        try stdout.writeAll("\n");
        try printSeparator(stdout);
        try printSectionHeader(stdout, "Remote Mods Scan");
        try stdout.print("Scanning remote: {s}:{s}\n\n", .{ config_cli.remote.host, config_cli.remote.path });
        try stdout.flush();

        const remote_jars = try mc_mods_manager.scanRemoteDirFile(config_cli.remote.host, config_cli.remote.path, main_allocator);

        try stdout.print("\nRemote Found {d} mods:\n", .{remote_jars.len});
        try stdout.flush();

        for (remote_jars, 0..) |jar, i| {
            try stdout.print("{d:>2}. {s}\n", .{ i + 1, jar.name });
            for (jar.mods) |mod_info| {
                try stdout.print("  └─ {s} (v{s})\n", .{ mod_info.displayName, mod_info.version });
            }

            if (jar.parsed_mod_info) |parsed_info| {
                try stdout.print("  └─ [Parsed] {s} (v{s})\n", .{ parsed_info.name, if (parsed_info.version) |version| version else "Null" });
            }
            if (jar.mods.len == 0 and jar.parsed_mod_info == null) {
                try printWarning(stdout, "No mod info found in this file\n", .{});
            }

            if (i < local_jars.len - 1) {
                try stdout.writeAll("\n");
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

// 添加格式化函数
fn printSeparator(writer: anytype) !void {
    try writer.print("{s}\n", .{SEPARATOR});
}

fn printSubSeparator(writer: anytype) !void {
    try writer.print("{s}\n", .{SUB_SEPARATOR});
}

fn printSectionHeader(writer: anytype, title: []const u8) !void {
    try writer.print("{s}\n", .{title});
    try printSubSeparator(writer);
}

fn printWarning(writer: anytype, comptime format: []const u8, args: anytype) !void {
    try writer.print("Warring  " ++ format, args);
}
