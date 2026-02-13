//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const toml = @import("toml");

const ModInfo = struct {
    modId: []const u8,
    version: []const u8,
    displayName: []const u8,
    description: []const u8,
    authors: ?[]const u8 = null,
    logoFile: ?[]const u8 = null,

    pub fn deinit(self: ModInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.modId);
        allocator.free(self.version);
        allocator.free(self.displayName);
        allocator.free(self.description);
        if (self.authors) |a| allocator.free(a);
        if (self.logoFile) |l| allocator.free(l);
    }

    pub fn clone(self: ModInfo, allocator: std.mem.Allocator) !ModInfo {
        return ModInfo{
            .modId = try allocator.dupe(u8, self.modId),
            .version = try allocator.dupe(u8, self.version),
            .displayName = try allocator.dupe(u8, self.displayName),
            .description = try allocator.dupe(u8, self.description),
            .authors = if (self.authors) |a| try allocator.dupe(u8, a) else null,
            .logoFile = if (self.logoFile) |l| try allocator.dupe(u8, l) else null,
        };
    }
};

const ModMetadata = struct {
    modLoader: []const u8,
    loaderVersion: []const u8,
    license: []const u8,

    mods: []const ModInfo,

    pub fn deinit(self: ModMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.modLoader);
        allocator.free(self.loaderVersion);
        allocator.free(self.license);
        for (self.mods) |mod| mod.deinit(allocator);
        allocator.free(self.mods);
    }

    pub fn clone(self: ModMetadata, allocator: std.mem.Allocator) !ModMetadata {
        const mods_copy = try allocator.alloc(ModInfo, self.mods.len);
        errdefer allocator.free(mods_copy);
        for (self.mods, 0..) |mod, i| {
            mods_copy[i] = try mod.clone(allocator);
        }
        return ModMetadata{
            .modLoader = try allocator.dupe(u8, self.modLoader),
            .loaderVersion = try allocator.dupe(u8, self.loaderVersion),
            .license = try allocator.dupe(u8, self.license),
            .mods = mods_copy,
        };
    }
};

const ParsedModInfo = struct {
    name: []const u8,
    version: ?[]const u8 = null,

    pub fn deinit(self: ParsedModInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.version) |version| {
            allocator.free(version);
        }
    }

    pub fn clone(self: ParsedModInfo, allocator: std.mem.Allocator) !ParsedModInfo {
        return ParsedModInfo{
            .name = try allocator.dupe(u8, self.name),
            .version = if (self.version) |version| try allocator.dupe(u8, version) else null,
        };
    }
};

const JarInfo = struct {
    name: []const u8,
    full_path: []const u8,

    mods: []const ModInfo,

    parsed_mod_info: ?ParsedModInfo = null,

    pub fn deinit(self: JarInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.full_path);
        if (self.parsed_mod_info) |parsed_mod_info| {
            parsed_mod_info.deinit(allocator);
        }
        for (self.mods) |mod| mod.deinit(allocator);
        allocator.free(self.mods);
    }

    pub fn clone(self: JarInfo, allocator: std.mem.Allocator) !JarInfo {
        const mods_copy = try allocator.alloc(ModInfo, self.mods.len);
        errdefer allocator.free(mods_copy);
        for (self.mods, 0..) |mod, i| {
            mods_copy[i] = try mod.clone(allocator);
        }
        return JarInfo{
            .name = try allocator.dupe(u8, self.name),
            .full_path = try allocator.dupe(u8, self.full_path),
            .parsed_mod_info = if (self.parsed_mod_info) |parsed_mod_info| try allocator.dupe(u8, parsed_mod_info) else null,
            .mods = mods_copy,
        };
    }
};

const ModParseError = error{FailedParseModInfo};

const RemoteCommandError = error{FailedExecute};

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

fn parseModInfo(mod_info: []const u8, allocator: std.mem.Allocator) !ModMetadata {
    var parser = toml.Parser(ModMetadata).init(allocator);
    defer parser.deinit();

    const dependencies_start = std.mem.indexOf(u8, mod_info, "[[dependencies");
    const content_to_parse = if (dependencies_start) |start|
        mod_info[0..start]
    else
        mod_info;

    var lines = std.mem.splitScalar(u8, content_to_parse, '\n');
    var cleaned = try std.ArrayList(u8).initCapacity(allocator, content_to_parse.len);
    defer cleaned.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            continue;
        }
        if (trimmed[0] == '#') {
            continue;
        }

        const hash_pos = std.mem.indexOfScalar(u8, line, '#');
        const content_part = if (hash_pos) |pos| line[0..pos] else line;

        const trimmed_right = std.mem.trimRight(u8, content_part, &std.ascii.whitespace);

        try cleaned.appendSlice(allocator, trimmed_right);

        try cleaned.append(allocator, '\n');
    }

    const cleaned_content = cleaned.items;

    const parse_result = try parser.parseString(cleaned_content);
    defer parse_result.deinit();

    return parse_result.value;
}

pub fn splitAny(allocator: std.mem.Allocator, text: []const u8, delimiters: []const u8) !std.ArrayList([]const u8) {
    var result = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    errdefer result.deinit(allocator);

    var start: usize = 0;
    while (start < text.len) {
        const maybe_pos = for (text[start..], start..) |c, i| {
            if (std.mem.indexOfScalar(u8, delimiters, c) != null) break i;
        } else text.len;

        try result.append(allocator, text[start..maybe_pos]);

        start = maybe_pos + 1;
        if (maybe_pos >= text.len) break;
    }

    return result;
}

pub fn removeVersionLike(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (std.ascii.isDigit(c)) {
            var j = i + 1;
            var looks_like_version = false;

            while (j < input.len) : (j += 1) {
                if (input[j] == '.') {
                    if (j + 1 < input.len and std.ascii.isDigit(input[j + 1])) {
                        looks_like_version = true;
                        break;
                    }
                } else if (!std.ascii.isDigit(input[j])) {
                    break;
                }
            }

            if (looks_like_version) {
                while (j < input.len and (std.ascii.isDigit(input[j]) or input[j] == '.')) {
                    j += 1;
                }
                i = j - 1;
                continue;
            }
        }

        try result.append(allocator, c);
    }

    return try result.toOwnedSlice(allocator);
}

fn parsedModInfoFromName(allocator: std.mem.Allocator, jar_name: []const u8) !ParsedModInfo {
    // delete .jar
    const suffix = ".jar";
    var name = jar_name;
    if (std.mem.endsWith(u8, jar_name, suffix)) {
        name = jar_name[0 .. jar_name.len - suffix.len];
    }

    var name_split = try splitAny(allocator, name, "-+");
    defer name_split.deinit(allocator);

    const discard_strs = &[_][]const u8{ "forge", "all" };

    var version: ?[]const u8 = null;

    var res_name: ?[]const u8 = null;

    for (name_split.items) |item| {
        var containp = false;
        for (discard_strs) |discard| {
            if (std.mem.eql(u8, discard, item)) {
                containp = true;
                break;
            }
        }

        if (containp) {
            continue;
        }

        if (std.mem.startsWith(u8, item, "mc") and item.len >= 3 and std.ascii.isDigit(item[3])) {
            continue;
        }

        if (std.SemanticVersion.parse(item)) |_| {
            version = item;
        } else |_| {
            if (res_name == null) {
                const item_trim = try removeVersionLike(allocator, item);
                res_name = item_trim;
            }
        }
    }

    if (res_name == null) {
        res_name = name;
    }

    return ParsedModInfo{ .name = if (res_name) |res| res else name, .version = if (version) |v| try allocator.dupe(u8, v) else null };
}

fn checkJarInfo(jar_path: []const u8, allocator: std.mem.Allocator) !ModMetadata {
    const argv = [_][]const u8{
        "unzip",
        "-p",
        jar_path,
        "META-INF/mods.toml",
    };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        // .max_output_bytes = 10 * 1024 * 1024, // 允许的最大输出字节数，防止爆炸
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                return try parseModInfo(result.stdout, allocator);
            } else {
                try stderr.print("Error: unzip error, exit code = {}\n", .{code});
                try stderr.print("Error: {s}\n", .{result.stderr});
            }
        },
        else => try stderr.print("Error: unzip error: {any}\n", .{result.term}),
    }
    try stderr.flush();

    return error.FailedParseModInfo;
}

pub fn scanDirFile(dir_path: []const u8, allocator: std.mem.Allocator) ![]const JarInfo {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cwd = std.fs.cwd();
    const dir = try cwd.openDir(dir_path, .{ .iterate = true });
    var it = dir.iterate();

    var mod_infos = try std.ArrayList(JarInfo).initCapacity(allocator, 0);

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    while (try it.next()) |entry| {
        if (entry.kind != std.fs.Dir.Entry.Kind.file) continue;

        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".jar")) continue;

        var jar_parse_info: ?ModMetadata = null;

        const full_path = try dir.realpathAlloc(allocator, entry.name);

        if (checkJarInfo(full_path, arena_alloc)) |info| {
            jar_parse_info = info;
            // const cloned = try jar_info.clone(allocator);
            // try mod_infos.append(allocator, cloned);
        } else |err| {
            try stderr.print("Error Parse {s}: {}\n", .{ full_path, err });
            try stderr.flush();
        }

        const mod_info: JarInfo = JarInfo{
            .name = entry.name,
            .full_path = full_path,
            .mods = if (jar_parse_info) |info| info.mods else &[0]ModInfo{},
        };

        try mod_infos.append(allocator, mod_info);
    }

    return mod_infos.toOwnedSlice(allocator);
}

fn getRemoteDirFile(allocator: std.mem.Allocator, host: []const u8, dir_path: []const u8) ![][]const u8 {
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

fn checkRemoteJarInfo(allocator: std.mem.Allocator, host: []const u8, jar_path: []const u8) !ModMetadata {
    const result = try executeRemoteCommand(allocator, host, "unzip", &[_][]const u8{
        "-p", jar_path, "META-INF/mods.toml",
    });
    defer allocator.free(result);

    return try parseModInfo(result, allocator);
}

pub fn scanRemoteDirFile(host: []const u8, dir_path: []const u8, allocator: std.mem.Allocator) ![]const ModMetadata {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // get remote file list
    const file_names = try getRemoteDirFile(arena_alloc, host, dir_path);

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var mod_infos = try std.ArrayList(ModMetadata).initCapacity(allocator, 0);

    for (file_names) |name| {
        if (!std.mem.eql(u8, std.fs.path.extension(name), ".jar")) continue;

        const dir_path_cloned = try arena_alloc.dupe(u8, dir_path);
        const full_path = try std.mem.concat(arena_alloc, u8, &[_][]const u8{ dir_path_cloned, "/", name });
        defer arena_alloc.free(full_path);

        const host_cloned = try arena_alloc.dupe(u8, host);
        defer arena_alloc.free(host_cloned);
        if (checkRemoteJarInfo(arena_alloc, host_cloned, full_path)) |jar_info| {
            const cloned = try jar_info.clone(allocator);
            try mod_infos.append(allocator, cloned);
        } else |err| {
            try stderr.print("Error Parse {s}: {}\n", .{ full_path, err });
            try stderr.flush();
        }
    }

    return mod_infos.toOwnedSlice(allocator);
}

test "parseModInfo basic parsing" {
    const allocator = std.testing.allocator;

    const mods_toml =
        \\modLoader="javafml"
        \\loaderVersion="[47,)"
        \\license="MIT"
        \\[[mods]]
        \\modId="endermod"
        \\version="1.0.0"
        \\displayName="Enderman Balls Mod"
        \\description='''Enderman Balls Mod — cut the balls, chaos ensues.'''
        \\authors="Emre"
    ;

    _ = try parseModInfo(mods_toml, allocator);
}

test "parseModInfo more info" {
    const allocator = std.testing.allocator;

    const mods_toml =
        \\ # This is an example mods.toml file. It contains the data relating to the loading mods.
        \\ # There are several mandatory fields (#mandatory), and many more that are optional (#optional).
        \\ # The overall format is standard TOML format, v0.5.0.
        \\ # Note that there are a couple of TOML lists in this file.
        \\ # Find more information on toml format here:  https://github.com/toml-lang/toml
        \\ # The name of the mod loader type to load - for regular FML @Mod mods it should be javafml
        \\ modLoader="javafml" #mandatory
        \\ # A version range to match for said mod loader - for regular FML @Mod it will be the forge version
        \\ loaderVersion="[47,)" #mandatory This is typically bumped every Minecraft version by Forge. See our download page for lists of versions.
        \\ # The license for you mod. This is mandatory metadata and allows for easier comprehension of your redistributive properties.
        \\ # Review your options at https://choosealicense.com/. All rights reserved is the default copyright stance, and is thus the default here.
        \\ license="MIT"
        \\ # A URL to refer people to when problems occur with this mod
        \\ #issueTrackerURL="https://change.me.to.your.issue.tracker.example.invalid/" #optional
        \\ # A list of mods - how many allowed here is determined by the individual mod loader
        \\ [[mods]] #mandatory
        \\ # The modid of the mod
        \\ modId="maid_storage_manager" #mandatory
        \\ # The version number of the mod
        \\ version="1.14.5" #mandatory
        \\ # A display name for the mod
        \\ displayName="maid storage manager" #mandatory
        \\ # A URL to query for updates for this mod. See the JSON update specification https://docs.minecraftforge.net/en/latest/misc/updatechecker/
        \\ #updateJSONURL="https://change.me.example.invalid/updates.json" #optional
        \\ # A URL for the "homepage" for this mod, displayed in the mod UI
        \\ #displayURL="https://change.me.to.your.mods.homepage.example.invalid/" #optional
        \\ # A file name (in the root of the mod JAR) containing a logo for display
        \\ logoFile="assets/maid_storage_manager/logo/logo.png" #optional
        \\ # A text field displayed in the mod UI
        \\ #credits="Thanks for this example mod goes to Java" #optional
        \\ # A text field displayed in the mod UI
        \\ authors="xypp" #optional
        \\ # Display Test controls the display for your mod in the server connection screen
        \\ # MATCH_VERSION means that your mod will cause a red X if the versions on client and server differ. This is the default behaviour and should be what you choose if you have server and client elements to your mod.
        \\ # IGNORE_SERVER_VERSION means that your mod will not cause a red X if it's present on the server but not on the client. This is what you should use if you're a server only mod.
        \\ # IGNORE_ALL_VERSION means that your mod will not cause a red X if it's present on the client or the server. This is a special case and should only be used if your mod has no server component.
        \\ # NONE means that no display test is set on your mod. You need to do this yourself, see IExtensionPoint.DisplayTest for more information. You can define any scheme you wish with this value.
        \\ # IMPORTANT NOTE: this is NOT an instruction as to which environments (CLIENT or DEDICATED SERVER) your mod loads on. Your mod should load (and maybe do nothing!) whereever it finds itself.
        \\ #displayTest="MATCH_VERSION" # MATCH_VERSION is the default if nothing is specified (#optional)
        \\
        \\ # The description text for the mod (multi line!) (#mandatory)
        \\ description='''Enable maid to manage your chests!'''
        \\ # A dependency - use the . to indicate dependency for a specific modid. Dependencies are optional.
        \\ [[dependencies."maid_storage_manager"]] #optional
        \\ # the modid of the dependency
        \\ modId="forge" #mandatory
        \\ # Does this dependency have to exist - if not, ordering below must be specified
        \\ mandatory=true #mandatory
        \\ # The version range of the dependency
        \\ versionRange="[47,)" #mandatory
        \\ # An ordering relationship for the dependency - BEFORE or AFTER required if the dependency is not mandatory
        \\ # BEFORE - This mod is loaded BEFORE the dependency
        \\ # AFTER - This mod is loaded AFTER the dependency
        \\ ordering="NONE"
        \\ # Side this dependency is applied on - BOTH, CLIENT, or SERVER
        \\ side="BOTH"# Here's another dependency
        \\ [[dependencies."maid_storage_manager"]]
        \\ modId="minecraft"
        \\ mandatory=true
        \\ # This version range declares a minimum of the current minecraft version up to but not including the next major version
        \\ versionRange="[1.20.1,1.21)"
        \\ ordering="NONE"
        \\ side="BOTH"
        \\ [[dependencies."maid_storage_manager"]]
        \\ modId="touhou_little_maid"
        \\ mandatory=true
        \\ versionRange="[1.3.7,)"
        \\ ordering="AFTER"
        \\ side="BOTH"
        \\ [[dependencies."maid_storage_manager"]]
        \\ modId="emi"
        \\ mandatory=false
        \\ versionRange="[0,)"
        \\ ordering="AFTER"
        \\ side="BOTH"
        \\ [[dependencies."maid_storage_manager"]]
        \\ modId="jei"
        \\ mandatory=false
        \\ versionRange="[0,)"
        \\ ordering="AFTER"
        \\ side="BOTH"
        \\ [[dependencies."maid_storage_manager"]]
        \\ modId="create"
        \\ mandatory=false
        \\ versionRange="[0,)"
        \\ ordering="AFTER"
        \\ side="BOTH"
        \\ [[dependencies."maid_storage_manager"]]
        \\ modId="cloth_config"
        \\ mandatory=false
        \\ versionRange="[0,)"
        \\ ordering="AFTER"
        \\ side="BOTH"
    ;

    _ = try parseModInfo(mods_toml, allocator);
}

test "splitAny test" {
    const gpa = std.testing.allocator;

    const cases = [_]struct {
        input: []const u8,
        expected: []const []const u8,
    }{
        .{
            .input = "1.20.1-maid_storage_manager-1.14.5-all.jar",
            .expected = &.{
                "1.20.1",
                "maid_storage_manager",
                "1.14.5",
                "all.jar",
            },
        },
        .{
            .input = "Endermod1.3.jar",
            .expected = &.{
                "Endermod1.3.jar", // 没有分隔符 → 整个字符串
            },
        },
        .{
            .input = "kotlinforforge-4.12.0-all.jar",
            .expected = &.{
                "kotlinforforge",
                "4.12.0",
                "all.jar",
            },
        },
        .{
            .input = "modernfix-forge-5.26.2+mc1.20.1.jar",
            .expected = &.{
                "modernfix",
                "forge",
                "5.26.2",
                "mc1.20.1.jar", // + 被当作分隔符，所以 mc1.20.1.jar 作为一个独立段
            },
        },
        .{
            .input = "moonlight-1.20-2.16.27-forge.jar",
            .expected = &.{
                "moonlight",
                "1.20",
                "2.16.27",
                "forge.jar",
            },
        },
        .{
            .input = "a-b+c-d++e",
            .expected = &.{
                "a",
                "b",
                "c",
                "d",
                "", // + 之间产生空段
                "e",
            },
        },
        .{
            .input = "",
            .expected = &.{}, // 空字符串 → 一个空段
        },
    };

    for (cases, 0..) |case, index| {
        var res = try splitAny(gpa, case.input, "-+");
        defer res.deinit(gpa);

        if (case.expected.len != res.items.len) {
            std.debug.print(
                \\[FAIL] {d}
                \\  input  : {s}
                \\  length : expected {d}, got {d}
                \\
            , .{ index, case.input, case.expected.len, res.items.len });

            try std.testing.expectEqual(case.expected.len, res.items.len);
        }

        for (case.expected, res.items, 0..) |exp, act, i| {
            if (!std.mem.eql(u8, exp, act)) {
                std.debug.print(
                    \\[FAIL] {d} (index {d})
                    \\  input   : {s}
                    \\  expected: '{s}'
                    \\  actual  : '{s}'
                    \\
                , .{ index, i, case.input, exp, act });
                try std.testing.expectEqualStrings(exp, act);
            }
        }
    }
}

test "parsedModInfoFromName test" {
    const gpa = std.testing.allocator;

    const cases = [_]struct {
        input: []const u8,
        expected: ParsedModInfo,
    }{
        .{
            .input = "1.20.1-maid_storage_manager-1.14.5-all.jar",
            .expected = ParsedModInfo{
                .name = "maid_storage_manager",
                .version = "1.14.5",
            },
        },
        .{
            .input = "Endermod1.3.jar",
            .expected = ParsedModInfo{
                .name = "Endermod",
                .version = "1.3",
            },
        },
        .{
            .input = "Endermod1.3.3.jar",
            .expected = ParsedModInfo{
                .name = "Endermod",
                .version = "1.3.3",
            },
        },
        .{
            .input = "kotlinforforge-4.12.0-all.jar",
            .expected = ParsedModInfo{
                .name = "kotlinforforge",
                .version = "4.12.0",
            },
        },
        .{
            .input = "modernfix-forge-5.26.2+mc1.20.1.jar",
            .expected = ParsedModInfo{
                .name = "modernfix",
                .version = "5.26.2",
            },
        },
        .{
            .input = "moonlight-1.20-2.16.27-forge.jar",
            .expected = ParsedModInfo{
                .name = "moonlight",
                .version = "2.16.27",
            },
        },
    };

    for (cases, 0..) |case, index| {
        const res = try parsedModInfoFromName(gpa, case.input);
        defer res.deinit(gpa);

        if (!std.mem.eql(u8, res.name, case.expected.name)) {
            std.debug.print(
                \\[FAIL] {d}:
                \\  input  : {s}
                \\
            , .{ index, case.input });

            try std.testing.expectEqualStrings(res.name, case.expected.name);
        }

        if (case.expected.version) |expected_version| {
            if (res.version) |res_version| {
                if (!std.mem.eql(u8, expected_version, res_version)) {
                    std.debug.print(
                        \\[FAIL] {d}:
                        \\  input  : {s}
                        \\  expect version: {s}, return version: {s}
                        \\
                    , .{ index, case.input, expected_version, res_version });
                }
            } else {
                std.debug.print(
                    \\[FAIL] {d}:
                    \\  input  : {s}
                    \\  expect version: {s}, return version: Null
                    \\
                , .{ index, case.input, expected_version });
            }
        }
    }
}
