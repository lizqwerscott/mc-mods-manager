const std = @import("std");

pub const SimpleModInfo = struct {
    name: []const u8,
    version: ?[]const u8 = null,

    pub fn deinit(self: SimpleModInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.version) |version| {
            allocator.free(version);
        }
    }

    pub fn clone(self: SimpleModInfo, allocator: std.mem.Allocator) !SimpleModInfo {
        return SimpleModInfo{
            .name = try allocator.dupe(u8, self.name),
            .version = if (self.version) |version| try allocator.dupe(u8, version) else null,
        };
    }
};

fn splitAny(allocator: std.mem.Allocator, text: []const u8, delimiters: []const u8) !std.ArrayList([]const u8) {
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

fn removeVersionLike(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
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

pub fn parsedModInfoFromName(allocator: std.mem.Allocator, jar_name: []const u8) !SimpleModInfo {
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

    return SimpleModInfo{ .name = if (res_name) |res| res else name, .version = if (version) |v| try allocator.dupe(u8, v) else null };
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
        expected: SimpleModInfo,
    }{
        .{
            .input = "1.20.1-maid_storage_manager-1.14.5-all.jar",
            .expected = SimpleModInfo{
                .name = "maid_storage_manager",
                .version = "1.14.5",
            },
        },
        .{
            .input = "Endermod1.3.jar",
            .expected = SimpleModInfo{
                .name = "Endermod",
                .version = "1.3",
            },
        },
        .{
            .input = "Endermod1.3.3.jar",
            .expected = SimpleModInfo{
                .name = "Endermod",
                .version = "1.3.3",
            },
        },
        .{
            .input = "kotlinforforge-4.12.0-all.jar",
            .expected = SimpleModInfo{
                .name = "kotlinforforge",
                .version = "4.12.0",
            },
        },
        .{
            .input = "modernfix-forge-5.26.2+mc1.20.1.jar",
            .expected = SimpleModInfo{
                .name = "modernfix",
                .version = "5.26.2",
            },
        },
        .{
            .input = "moonlight-1.20-2.16.27-forge.jar",
            .expected = SimpleModInfo{
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
