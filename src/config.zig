const std = @import("std");

const toml = @import("toml");

const LocalConfig = struct {
    path: []const u8,

    fn deinit(self: LocalConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }

    fn clone(self: LocalConfig, allocator: std.mem.Allocator) !LocalConfig {
        return LocalConfig{
            .path = try allocator.dupe(u8, self.path),
        };
    }
};

const RemoteConfig = struct {
    host: []const u8,
    path: []const u8,

    fn deinit(self: RemoteConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }

    fn clone(self: RemoteConfig, allocator: std.mem.Allocator) !RemoteConfig {
        return RemoteConfig{
            .host = try allocator.dupe(u8, self.host),
            .path = try allocator.dupe(u8, self.path),
        };
    }
};

const Config = struct {
    local: LocalConfig,
    remote: RemoteConfig,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        self.local.deinit(allocator);
        self.remote.deinit(allocator);
    }

    pub fn clone(self: Config, allocator: std.mem.Allocator) !Config {
        return Config{ .local = try self.local.clone(allocator), .remote = try self.remote.clone(allocator) };
    }
};

pub fn loadConfig(config_path: []const u8, main_allocator: std.mem.Allocator) !Config {
    var parser = toml.Parser(Config).init(main_allocator);
    defer parser.deinit();

    var result = try parser.parseFile(config_path);

    defer result.deinit();

    const config = result.value;

    return try config.clone(main_allocator);
}
