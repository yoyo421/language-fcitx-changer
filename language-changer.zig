const std = @import("std");

const isProd = @import("builtin").mode != .Debug;
const DBus = @import("dbus.zig");

pub const std_options: std.Options = .{ .networking = false, .allow_stack_tracing = false };
const PROFILE_PATH = "/home/yoav/.config/fcitx5/profile";
const fcitx5Dest = DBus.DBusDestination{
    .destination = "org.fcitx.Fcitx5",
    .path = "/controller",
    .interface = "org.fcitx.Fcitx.Controller1",
};

const Group = struct {
    name: []const u8,
    languages: [16][]const u8,
    languages_len: u8 = 0,

    pub const empty = Group{
        .name = &[_]u8{},
        .languages = undefined,
    };

    pub fn addLanguage(self: *Group, language: []const u8) error{TooManyLanguages}!void {
        if (self.languages_len >= 16) return error.TooManyLanguages;
        self.languages[self.languages_len] = language;
        self.languages_len += 1;
    }
};

const ReadProfileScope = enum {
    group,
    language,
    none,
};
fn readProfile(io: std.Io, alloc: std.mem.Allocator) !struct {
    groups: []Group,
    mmapbuffer: []align(std.heap.pageSize()) const u8,
} {
    const path = try std.fs.path.resolve(alloc, &[_][]const u8{PROFILE_PATH});
    defer alloc.free(path);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const fcitxMap: []align(std.heap.pageSize()) u8 = try std.posix.mmap(null, try file.length(io), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    errdefer std.posix.munmap(fcitxMap);
    var reader = std.Io.Reader.fixed(fcitxMap);
    var groups: std.ArrayList(Group) = .empty;
    errdefer groups.deinit(alloc);

    var currentGroup: ?*Group = null;
    var currentScope: ReadProfileScope = .none;
    while (try reader.takeDelimiter('\n')) |line| {
        // Comment or empty line
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
        // Scope change -> group or item in group
        if (std.mem.find(u8, line, "Items") != null) {
            currentScope = .language;
            continue;
        } else if (std.mem.find(u8, line, "Groups") != null) {
            currentGroup = groups.addOne(alloc) catch unreachable;
            currentGroup.?.* = .empty;
            currentScope = .group;
            continue;
        }
        if (currentGroup) |g| {
            const nameIndex = std.mem.find(u8, line, "Name") orelse continue;
            const equalIndex = std.mem.findScalarPos(u8, line, nameIndex + 4, '=') orelse continue;
            const name = std.mem.trim(u8, line[equalIndex + 1 ..], " \t");
            switch (currentScope) {
                .language => try g.addLanguage(name),
                .group => g.name = name,
                else => {},
            }
        }
    }

    return .{
        .groups = try groups.toOwnedSlice(alloc),
        .mmapbuffer = fcitxMap,
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var debug = std.heap.DebugAllocator(.{}).init;
    defer _ = if (isProd) arena.deinit() else debug.deinit();
    const alloc = if (isProd) arena.allocator() else debug.allocator();
    var thread = std.Io.Threaded.init_single_threaded;
    const io = thread.io();

    var bus: DBus = .empty;
    defer bus.deinit();
    try bus.init();

    var currentInputCF: DBus.CallFunction = .{ .name = "CurrentInputMethod" };
    var currentGroupCF: DBus.CallFunction = .{ .name = "CurrentInputMethodGroup" };
    var changeCFParam: DBus.CallFunctionParam = .{ .mode = 's', .value = "" };
    var changeCF: DBus.CallFunction = .{ .name = "SetCurrentIM", .params = &.{&changeCFParam} };
    defer currentInputCF.deinit();
    defer currentGroupCF.deinit();
    defer changeCF.deinit();
    bus.callFn(&currentInputCF, fcitx5Dest);
    bus.callFn(&currentGroupCF, fcitx5Dest);

    const profile = try readProfile(io, alloc);
    const currentGroup = try currentGroupCF.getReplyStr();
    const currentLanguage = try currentInputCF.getReplyStr();
    defer {
        alloc.free(profile.groups);
        std.posix.munmap(profile.mmapbuffer);
    }
    for (profile.groups) |group| {
        if (!std.mem.eql(u8, group.name, currentGroup)) continue;
        for (group.languages[0..group.languages_len], 0..) |language, i| {
            if (!std.mem.eql(u8, language, currentLanguage)) continue;
            changeCFParam.value = try std.mem.concat(alloc, u8, &[_][]const u8{ group.languages[(i + 1) % group.languages_len], "" });
            defer alloc.free(changeCFParam.value);
            bus.callFn(&changeCF, fcitx5Dest);
            return;
        }
    }
}
// zig build-exe ./language-changer.zig -O ReleaseSmall -fsingle-threaded -fno-error-tracing -fno-unwind-tables -fno-sanitize-c -fno-stack-protector -mcmodel=small
// zig build -Doptimize=ReleaseSmall
