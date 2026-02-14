const std = @import("std");

pub const SEPARATOR = "=" ** 60;
pub const SUB_SEPARATOR = "-" ** 40;

// ANSI Color codes
pub const Color = struct {
    pub const reset: []const u8 = "\x1b[0m";
    pub const red: []const u8 = "\x1b[31m";
    pub const green: []const u8 = "\x1b[32m";
    pub const yellow: []const u8 = "\x1b[33m";
    pub const blue: []const u8 = "\x1b[34m";
    pub const magenta: []const u8 = "\x1b[35m";
    pub const cyan: []const u8 = "\x1b[36m";
    pub const white: []const u8 = "\x1b[37m";
    pub const bright_red: []const u8 = "\x1b[1;31m";
    pub const bright_green: []const u8 = "\x1b[1;32m";
    pub const bright_yellow: []const u8 = "\x1b[1;33m";
    pub const bright_blue: []const u8 = "\x1b[1;34m";
    pub const bright_magenta: []const u8 = "\x1b[1;35m";
    pub const bright_cyan: []const u8 = "\x1b[1;36m";
};

// 添加格式化函数
pub fn printSeparator(writer: anytype) !void {
    try writer.print("{s}\n", .{SEPARATOR});
}

pub fn printSubSeparator(writer: anytype) !void {
    try writer.print("{s}\n", .{SUB_SEPARATOR});
}

pub fn printSectionHeader(writer: anytype, title: []const u8) !void {
    try writer.print("{s}\n", .{title});
    try printSubSeparator(writer);
}

pub fn printSectionHeaderColored(writer: anytype, title: []const u8, color: []const u8) !void {
    try writer.writeAll(color);
    try writer.print("{s}\n", .{title});
    try writer.writeAll(Color.reset);
    try printSubSeparator(writer);
}

pub fn printWarning(writer: anytype, comptime format: []const u8, args: anytype) !void {
    try writer.print("Warning  " ++ format, args);
}

pub fn printc(writer: anytype, color: []const u8, comptime format: []const u8, args: anytype) !void {
    try writer.writeAll(color);
    try writer.print(format, args);
    try writer.writeAll(Color.reset);
}
