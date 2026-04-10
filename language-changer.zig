const std = @import("std");
const DBus = @import("dbus.zig");
pub const panic = @import("std").debug.no_panic;

pub const std_options: std.Options = .{ .networking = false, .allow_stack_tracing = false };
const PROFILE_PATH = "/home/yoav/.config/fcitx5/profile";
const fcitx5Dest = DBus.DBusDestination{
    .destination = "org.fcitx.Fcitx5",
    .path = "/controller",
    .interface = "org.fcitx.Fcitx.Controller1",
};

const Group = struct {
    name: []const u8,
    languages: [16][:0]const u8,
    languages_len: u8 = 0,

    pub const empty = Group{
        .name = &[_]u8{},
        .languages = undefined,
    };

    pub fn addLanguage(self: *Group, language: [:0]const u8) !void {
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
    const path = try std.fs.path.resolve(alloc, &[_][]const u8{PROFILE_PATH});
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const fcitxMap = try std.posix.mmap(null, try file.length(io), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(fcitxMap);
    var reader = std.Io.Reader.fixed(fcitxMap);
    var groups: std.ArrayList(Group) = .empty;
    errdefer groups.deinit(alloc);
    var languages: std.ArrayList(u8) = .empty;
    errdefer languages.deinit(alloc);

    var currentGroup: ?*Group = null;
    var currentScope: enum { group, language, none } = .none;
    while (try reader.takeDelimiter('\n')) |line| {
        // Comment or empty line
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
        // Scope change -> group or item in group
        if (std.mem.find(u8, line, "Items") != null) {
            currentScope = .language;
        } else if (std.mem.find(u8, line, "Groups") != null) {
            currentGroup = groups.addOne(alloc) catch unreachable;
            currentGroup.?.* = .empty;
            currentScope = .group;
        }
        if (std.mem.find(u8, line, "Name") != null and currentGroup != null) {
            const exqualIndex = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const name = std.mem.trim(u8, line[exqualIndex + 1 ..], " \t");
            switch (currentScope) {
                .language => {
                    const index = languages.items.len;
                    languages.appendSlice(alloc, name) catch unreachable;
                    languages.append(alloc, 0) catch unreachable;
                    currentGroup.?.addLanguage(@ptrCast(languages.items[index..])) catch unreachable;
                },
                .group => {
                    currentGroup.?.name = alloc.dupe(u8, name) catch unreachable;
                },
                else => {},
            }
        }
    }

    return .{
        .groups = groups.items,
        .languages = languages.items,
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    var thread = std.Io.Threaded.init_single_threaded;
    const io = thread.io();

    var bus: DBus = .empty;
    defer bus.deinit();
    try bus.init();
    var currentInputCF: DBus.CallFunction = .{ .name = "CurrentInputMethod" };
    var currentGroupCF: DBus.CallFunction = .{ .name = "CurrentInputMethodGroup" };
    var changeCFParam = DBus.CallFunctionParam{ .mode = 's', .value = "" };
    var changeCF: DBus.CallFunction = .{ .name = "SetCurrentIM", .params = &.{&changeCFParam} };
    defer currentInputCF.deinit();
    defer currentGroupCF.deinit();
    defer changeCF.deinit();
    bus.callFn(&currentInputCF, fcitx5Dest);
    bus.callFn(&currentGroupCF, fcitx5Dest);

    const currentGroup = try currentGroupCF.getReplyStr();
    const currentLanguage = try currentInputCF.getReplyStr();
    const profile = try readProfile(io, alloc);
    defer {
        alloc.free(profile.groups);
        alloc.free(profile.languages);
    }
    for (profile.groups) |group| {
        if (!std.mem.eql(u8, group.name, currentGroup)) continue;
        for (group.languages[0..group.languages_len], 0..) |language, i| {
            if (!std.mem.eql(u8, language[0 .. language.len - 1], currentLanguage)) continue;
            changeCFParam.value = group.languages[(i + 1) % group.languages_len];
            bus.callFn(&changeCF, fcitx5Dest);
            return;
        }
    }
}
// zig build-exe ./language-changer.zig -O ReleaseSmall -fsingle-threaded -fno-error-tracing -fno-unwind-tables -fno-sanitize-c -fno-stack-protector -mcmodel=small
// zig build -Doptimize=ReleaseSmall
