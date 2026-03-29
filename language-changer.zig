const std = @import("std");

const PROFILE_PATH = "/home/yoav/.config/fcitx5/profile";
pub const panic = @import("std").debug.no_panic;

pub const std_options: std.Options = .{ .networking = false, .allow_stack_tracing = false };

const Group = struct {
    name: []const u8,
    languages: [16][]const u8,
    languages_len: u8 = 0,

    pub const empty = Group{
        .name = &[_]u8{},
        .languages = undefined,
    };

    pub fn addLanguage(self: *Group, language: []const u8) !void {
        if (self.languages_len >= 16) {
            return error.TooManyLanguages;
        }
        const index = self.languages_len;
        self.languages[index] = language;
        self.languages_len += 1;
    }
};

fn readProfile(io: std.Io, alloc: std.mem.Allocator) !struct {
    groups: []Group,
    languages: []const u8,
} {
    var buffer: [64]u8 = undefined;
    const path = try std.fs.path.resolve(alloc, &[_][]const u8{PROFILE_PATH});
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var reader = file.reader(io, &buffer);
    var groups: std.ArrayList(Group) = .empty;
    errdefer groups.deinit(alloc);
    var languages: std.ArrayList(u8) = .empty;
    errdefer languages.deinit(alloc);

    var currentGroup: ?*Group = null;
    var currentScope: enum { group, language, none } = .none;
    while (try reader.interface.takeDelimiter('\n')) |line| {
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.find(u8, line, "Items") != null) {
            currentScope = .language;
        } else if (std.mem.find(u8, line, "Groups") != null) {
            currentGroup = groups.addOne(alloc) catch unreachable;
            currentGroup.?.* = .empty;
            currentScope = .group;
        }
        if (std.mem.find(u8, line, "Name") != null) {
            const name = std.mem.trim(u8, line[std.mem.indexOfScalar(u8, line, '=').? + 1 ..], " \t");
            switch (currentScope) {
                .language => {
                    const index = languages.items.len;
                    languages.appendSlice(alloc, name) catch unreachable;
                    currentGroup.?.addLanguage(languages.items[index..]) catch unreachable;
                },
                .group => {
                    currentGroup.?.name = alloc.dupe(u8, name) catch unreachable;
                },
                else => {},
            }
        }
    }

    return .{
        .groups = try groups.toOwnedSlice(alloc),
        .languages = try languages.toOwnedSlice(alloc),
    };
}

fn getCurrentMode(io: std.Io, alloc: std.mem.Allocator, envMap: *const std.process.Environ.Map, mode: enum { group, language }) []const u8 {
    const option = switch (mode) {
        .group => "-q",
        .language => "-n",
    };
    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ "fcitx5-remote", option },
        .environ_map = envMap,
        .stdout = .pipe,
    }) catch unreachable;
    defer child.kill(io);
    var buffer: [64]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    const name = reader.interface.takeDelimiter('\n') catch buffer[0..0] orelse buffer[0..0];
    return alloc.dupe(u8, name) catch unreachable;
}

fn setCurrentMode(io: std.Io, envMap: *const std.process.Environ.Map, name: []const u8) void {
    var process = std.process.spawn(io, .{
        .argv = &[_][]const u8{ "fcitx5-remote", "-s", name },
        .environ_map = envMap,
    }) catch unreachable;
    _ = process.wait(io) catch unreachable;
}

pub fn main(args: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    var thread = std.Io.Threaded.init(alloc, .{});
    const envMap = &try args.environ.createMap(alloc);
    const io = thread.io();
    var groupFuture = std.Io.async(io, getCurrentMode, .{ io, alloc, envMap, .group });
    var languageFuture = std.Io.async(io, getCurrentMode, .{ io, alloc, envMap, .language });
    defer _ = groupFuture.cancel(io);
    defer _ = languageFuture.cancel(io);
    const currentGroup: []const u8 = groupFuture.await(io);
    const currentLanguage: []const u8 = languageFuture.await(io);
    const profile = try readProfile(io, alloc);
    for (profile.groups) |group| {
        if (!std.mem.eql(u8, group.name, currentGroup)) continue;
        for (group.languages[0..group.languages_len], 0..) |language, i| {
            if (!std.mem.eql(u8, language, currentLanguage)) continue;
            setCurrentMode(io, envMap, group.languages[(i + 1) % group.languages_len]);
            return;
        }
    }
}
