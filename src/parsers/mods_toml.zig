const std = @import("std");

const toml = @import("toml");

pub const ModInfo = struct {
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

pub const ModMetadata = struct {
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

pub fn parseModInfo(mod_info: []const u8, allocator: std.mem.Allocator) !ModMetadata {
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
