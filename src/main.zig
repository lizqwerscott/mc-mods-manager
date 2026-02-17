const std = @import("std");

const mc_mods_manager = @import("mc_mods_manager");
const config = @import("config.zig");
const print_utils = @import("print_utils.zig");

const Color = print_utils.Color;
const SEPARATOR = print_utils.SEPARATOR;
const SUB_SEPARATOR = print_utils.SUB_SEPARATOR;
const printSeparator = print_utils.printSeparator;
const printSubSeparator = print_utils.printSubSeparator;
const printSectionHeader = print_utils.printSectionHeader;
const printWarning = print_utils.printWarning;
const printc = print_utils.printc;
const printSectionHeaderColored = print_utils.printSectionHeaderColored;

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
        try printSectionHeaderColored(stdout, "Configuration", Color.cyan);
        try printc(stdout, Color.cyan, "Config file: {s}\n", .{config_path});
        try printc(stdout, Color.cyan, "\nLocal Settings:\n", .{});

        try printc(stdout, Color.green, "  *", .{});
        try printc(stdout, Color.white, " Path: {s}\n", .{config_cli.local.path});

        try printc(stdout, Color.yellow, "\nRemote Settings:\n", .{});
        try printc(stdout, Color.green, "  *", .{});
        try printc(stdout, Color.white, " Host: {s}\n", .{config_cli.remote.host});
        try printc(stdout, Color.green, "  *", .{});
        try printc(stdout, Color.white, " Path: {s}\n", .{config_cli.remote.path});
        try stdout.flush();

        try stdout.writeAll("\n");

        try printSeparator(stdout);
        try printSectionHeaderColored(stdout, "Local Mods Scan", Color.bright_blue);
        try stdout.print("Scanning directory: {s}\n\n", .{config_cli.local.path});
        try stdout.flush();

        var local_jars = try mc_mods_manager.scanDirFile(config_cli.local.path, main_allocator);
        defer {
            for (local_jars.items) |item| item.deinit(main_allocator);
            local_jars.deinit(main_allocator);
        }
        try printc(stdout, Color.cyan, "\nLocal Found {d} mods:\n", .{local_jars.items.len});
        try stdout.flush();

        for (local_jars.items, 0..) |jar, i| {
            try printc(stdout, Color.bright_blue, "{d:>2}. {s}\n", .{ i + 1, jar.name });
            for (jar.mods) |mod_info| {
                try printc(stdout, Color.green, "  └─ {s} ", .{mod_info.displayName});
                try printc(stdout, Color.yellow, "(v{s})\n", .{mod_info.version});
            }
            if (jar.parsed_mod_info) |parsed_info| {
                try printc(stdout, Color.magenta, "  └─ [Parsed] {s} ", .{parsed_info.name});
                try printc(stdout, Color.yellow, "(v{s})\n", .{if (parsed_info.version) |version| version else "Null"});
            }
            if (jar.mods.len == 0 and jar.parsed_mod_info == null) {
                try printc(stdout, Color.bright_red, "Warning  No mod info found in this file\n", .{});
            }

            if (i < local_jars.items.len - 1) {
                try stdout.writeAll("\n");
            }

            try stdout.flush();
        }

        try stdout.writeAll("\n");
        try printSeparator(stdout);
        try printSectionHeaderColored(stdout, "Remote Mods Scan", Color.bright_blue);
        try stdout.print("Scanning remote: {s}:{s}\n\n", .{ config_cli.remote.host, config_cli.remote.path });
        try stdout.flush();

        var remote_jars = try mc_mods_manager.scanRemoteDirFile(config_cli.remote.host, config_cli.remote.path, main_allocator);
        defer {
            for (remote_jars.items) |item| item.deinit(main_allocator);
            remote_jars.deinit(main_allocator);
        }

        try printc(stdout, Color.cyan, "\nRemote Found {d} mods:\n", .{remote_jars.items.len});
        try stdout.flush();

        for (remote_jars.items, 0..) |jar, i| {
            try printc(stdout, Color.bright_blue, "{d:>2}. {s}\n", .{ i + 1, jar.name });
            for (jar.mods) |mod_info| {
                try printc(stdout, Color.green, "  └─ {s} ", .{mod_info.displayName});
                try printc(stdout, Color.yellow, "(v{s})\n", .{mod_info.version});
            }

            if (jar.parsed_mod_info) |parsed_info| {
                try printc(stdout, Color.magenta, "  └─ [Parsed] {s} ", .{parsed_info.name});
                try printc(stdout, Color.yellow, "(v{s})\n", .{if (parsed_info.version) |version| version else "Null"});
            }
            if (jar.mods.len == 0 and jar.parsed_mod_info == null) {
                try printc(stdout, Color.bright_red, "Warning  No mod info found in this file\n", .{});
            }

            if (i < remote_jars.items.len - 1) {
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
