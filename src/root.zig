//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const parsers = @import("parsers");
const jarname = parsers.jarname;
const mods_toml = parsers.mods_toml;

const remote = @import("remote.zig");

const SimpleModInfo = jarname.SimpleModInfo;
const ModInfo = mods_toml.ModInfo;
const ModMetadata = mods_toml.ModMetadata;

const JarInfo = struct {
    name: []const u8,
    full_path: []const u8,

    mods: []const ModInfo = &[0]ModInfo{},

    parsed_mod_info: ?SimpleModInfo = null,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, full_path: []const u8) !JarInfo {
        const name_c = try allocator.dupe(u8, name);
        const path_c = try allocator.dupe(u8, full_path);
        return JarInfo{ .name = name_c, .full_path = path_c };
    }

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
            .parsed_mod_info = if (self.parsed_mod_info) |parsed_mod_info| try parsed_mod_info.clone(allocator) else null,
            .mods = mods_copy,
        };
    }
};

const MatchRes = struct {
    local_jar: *const JarInfo,
    remote_jar: *const JarInfo,
    similarity: f32 = 0.0,
};

const CompareResult = struct {
    match_res: []const MatchRes,
    local: []*const JarInfo,
    remote: []*const JarInfo,

    pub fn deinit(self: CompareResult, allocator: std.mem.Allocator) void {
        allocator.free(self.match_res);
        allocator.free(self.local);
        allocator.free(self.remote);
    }
};

const ModParseError = error{FailedParseModInfo};

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
                return try mods_toml.parseModInfo(result.stdout, allocator);
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

pub fn scanDirFile(dir_path: []const u8, allocator: std.mem.Allocator) !std.ArrayList(JarInfo) {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cwd = std.fs.cwd();
    const dir = try cwd.openDir(dir_path, .{ .iterate = true });
    var it = dir.iterate();

    var jar_infos = try std.ArrayList(JarInfo).initCapacity(allocator, 0);
    errdefer {
        for (jar_infos.items) |item| item.deinit(allocator);
        jar_infos.deinit(allocator);
    }

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    while (try it.next()) |entry| {
        if (entry.kind != std.fs.Dir.Entry.Kind.file) continue;

        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".jar")) continue;

        var jar_parse_info: ?ModMetadata = null;
        var parsed_mod_info: ?SimpleModInfo = null;

        const full_path = try dir.realpathAlloc(allocator, entry.name);
        defer allocator.free(full_path);

        if (checkJarInfo(full_path, arena_alloc)) |info| {
            jar_parse_info = info;
        } else |err| {
            try stderr.print("Error Parse {s}: {}\n", .{ full_path, err });
            try stderr.flush();

            if (jarname.parsedModInfoFromName(allocator, entry.name)) |parsed_info| {
                parsed_mod_info = parsed_info;
            } else |err_2| {
                try stderr.print("Error Parse {s}: {}\n", .{ entry.name, err_2 });
                try stderr.flush();
            }
        }

        var jar_info = try JarInfo.init(allocator, entry.name, full_path);
        if (jar_parse_info) |info| {
            const mods_copy = try allocator.alloc(ModInfo, info.mods.len);
            errdefer allocator.free(mods_copy);
            for (info.mods, 0..) |mod, i| {
                mods_copy[i] = try mod.clone(allocator);
            }

            jar_info.mods = mods_copy;
        }
        jar_info.parsed_mod_info = parsed_mod_info;

        try jar_infos.append(allocator, jar_info);
    }

    return jar_infos;
}

fn checkRemoteJarInfo(allocator: std.mem.Allocator, host: []const u8, jar_path: []const u8) !ModMetadata {
    const result = try remote.executeRemoteCommand(allocator, host, "unzip", &[_][]const u8{
        "-p", jar_path, "META-INF/mods.toml",
    });
    defer allocator.free(result);

    return try mods_toml.parseModInfo(result, allocator);
}

pub fn scanRemoteDirFile(host: []const u8, dir_path: []const u8, allocator: std.mem.Allocator) !std.ArrayList(JarInfo) {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // get remote file list
    const file_names = try remote.getRemoteDirFile(arena_alloc, host, dir_path);

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var jar_infos = try std.ArrayList(JarInfo).initCapacity(allocator, 0);
    errdefer {
        for (jar_infos.items) |item| item.deinit(allocator);
        jar_infos.deinit(allocator);
    }

    for (file_names) |name| {
        if (!std.mem.eql(u8, std.fs.path.extension(name), ".jar")) continue;

        const dir_path_cloned = try arena_alloc.dupe(u8, dir_path);
        const full_path = try std.mem.concat(arena_alloc, u8, &[_][]const u8{ dir_path_cloned, "/", name });

        var jar_parse_info: ?ModMetadata = null;
        var parsed_mod_info: ?SimpleModInfo = null;

        const host_cloned = try arena_alloc.dupe(u8, host);
        defer arena_alloc.free(host_cloned);

        if (checkRemoteJarInfo(arena_alloc, host_cloned, full_path)) |info| {
            jar_parse_info = info;
        } else |err| {
            try stderr.print("Error Parse {s}: {}\n", .{ full_path, err });
            try stderr.flush();

            if (jarname.parsedModInfoFromName(allocator, name)) |parsed_info| {
                parsed_mod_info = parsed_info;
            } else |err_2| {
                try stderr.print("Error Parse {s}: {}\n", .{ name, err_2 });
                try stderr.flush();
            }
        }

        var jar_info = try JarInfo.init(allocator, name, full_path);

        if (jar_parse_info) |info| {
            const mods_copy = try allocator.alloc(ModInfo, info.mods.len);
            errdefer allocator.free(mods_copy);
            for (info.mods, 0..) |mod, i| {
                mods_copy[i] = try mod.clone(allocator);
            }

            jar_info.mods = mods_copy;
        }
        jar_info.parsed_mod_info = parsed_mod_info;

        try jar_infos.append(allocator, jar_info);
    }

    return jar_infos;
}

fn calcNameScore(allocator: std.mem.Allocator, jarname1: []const u8, jarname2: []const u8) !f32 {
    const n = jarname1.len;
    const m = jarname2.len;

    if (n == 0 and m == 0) return 100;
    if (n == 0 or m == 0) return 0;

    if (std.mem.eql(u8, jarname1, jarname2)) return 100;

    var s1: []const u8 = undefined;
    var s2: []const u8 = undefined;

    if (n < m) {
        s1 = jarname1;
        s2 = jarname2;
    } else {
        s1 = jarname2;
        s2 = jarname1;
    }

    const len1 = s1.len;
    const len2 = s2.len;

    var prev_row = try allocator.alloc(usize, len2 + 1);
    defer allocator.free(prev_row);
    var curr_row = try allocator.alloc(usize, len2 + 1);
    defer allocator.free(curr_row);

    for (prev_row, 0..) |_, i| {
        prev_row[i] = i;
    }

    for (s1, 0..) |c1, i| {
        curr_row[0] = i + 1;
        for (s2, 0..) |c2, j| {
            const cost: usize = if (c1 == c2) 0 else 1;
            curr_row[j + 1] = @min(curr_row[j] + 1, // 插入
                @min(prev_row[j + 1] + 1, // 删除
                    prev_row[j] + cost // 替换
                    ));
        }
        @memcpy(prev_row, curr_row);
    }

    const distance = prev_row[len2];
    const max_len = @max(len1, len2);

    const ratio = 1.0 - (@as(f32, @floatFromInt(distance)) / @as(f32, @floatFromInt(max_len)));
    return ratio;
}

pub fn fuzzyMatchJars(allocator: std.mem.Allocator, local_jars: []const JarInfo, remote_jars: []const JarInfo) !CompareResult {
    var match_res = try std.ArrayList(MatchRes).initCapacity(allocator, 0);
    var remaining_local_jar = try std.ArrayList(*const JarInfo).initCapacity(allocator, 0);
    var remaining_remote_jar = try std.ArrayList(*const JarInfo).initCapacity(allocator, 0);

    defer match_res.deinit(allocator);
    defer remaining_local_jar.deinit(allocator);
    defer remaining_remote_jar.deinit(allocator);

    var remote_mods_map = std.StringHashMap(struct { jar_info: *const JarInfo, index: usize }).init(allocator);
    defer remote_mods_map.deinit();

    var remote_mods_findp = try std.ArrayList(bool).initCapacity(allocator, remote_jars.len);
    defer remote_mods_findp.deinit(allocator);

    for (remote_jars, 0..) |*remote_jar, i| {
        for (remote_jar.mods) |remote_mod| {
            try remote_mods_map.put(remote_mod.modId, .{ .jar_info = remote_jar, .index = i });
        }
        if (remote_jar.parsed_mod_info) |info| {
            try remote_mods_map.put(info.name, .{ .jar_info = remote_jar, .index = i });
        }
        try remote_mods_findp.append(allocator, false);
    }

    var find_localp = false;

    for (local_jars) |*local_jar| {
        find_localp = false;
        for (local_jar.mods) |local_mod| {
            if (remote_mods_map.get(local_mod.modId)) |remote_jar| {
                if (!remote_mods_findp.items[remote_jar.index]) {
                    try match_res.append(allocator, MatchRes{
                        .local_jar = local_jar,
                        .remote_jar = remote_jar.jar_info,
                        .similarity = 1.0,
                    });
                    remote_mods_findp.items[remote_jar.index] = true;
                    find_localp = true;
                }
            }
        }
        if (local_jar.parsed_mod_info) |info| {
            if (remote_mods_map.get(info.name)) |remote_jar| {
                if (!remote_mods_findp.items[remote_jar.index]) {
                    try match_res.append(allocator, MatchRes{
                        .local_jar = local_jar,
                        .remote_jar = remote_jar.jar_info,
                        .similarity = 1.0,
                    });
                    remote_mods_findp.items[remote_jar.index] = true;
                }
                find_localp = true;
            }
        }
        if (!find_localp) {
            try remaining_local_jar.append(allocator, local_jar);
        }
    }

    for (remote_mods_findp.items, 0..) |findp, i| {
        if (!findp) {
            try remaining_remote_jar.append(allocator, &remote_jars[i]);
        }
    }

    var i: usize = remaining_local_jar.items.len;
    while (i > 0) {
        i -= 1;
        const r_local_jar = remaining_local_jar.items[i];
        var max_score: f32 = 0;
        var max_score_index: ?usize = null;
        var max_score_remote_jar: ?*const JarInfo = null;

        for (remaining_remote_jar.items, 0..) |r_remote_jar, j| {
            const score = try calcNameScore(allocator, r_local_jar.name, r_remote_jar.name);
            if (score > max_score) {
                max_score = score;
                max_score_index = j;
                max_score_remote_jar = r_remote_jar;
            }
        }

        if (max_score_remote_jar) |m_remote_jar| {
            if (max_score >= 0.5) {
                try match_res.append(allocator, MatchRes{
                    .local_jar = r_local_jar,
                    .remote_jar = m_remote_jar,
                    .similarity = max_score,
                });

                _ = remaining_local_jar.orderedRemove(i);
                _ = remaining_remote_jar.orderedRemove(max_score_index.?);
            }
        }
    }

    return CompareResult{
        .match_res = try match_res.toOwnedSlice(allocator),
        .local = try remaining_local_jar.toOwnedSlice(allocator),
        .remote = try remaining_remote_jar.toOwnedSlice(allocator),
    };
}
