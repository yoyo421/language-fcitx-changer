const std = @import("std");
const lang_group = @import("./lang-group.zig");

const isProd = @import("builtin").mode != .Debug;
const DBus = @import("dbus.zig");

pub const std_options: std.Options = .{ .networking = false, .allow_stack_tracing = false };
const fcitx5Dest = DBus.DBusDestination{
    .destination = "org.fcitx.Fcitx5",
    .path = "/controller",
    .interface = "org.fcitx.Fcitx.Controller1",
};

fn getProfilePath(alloc: std.mem.Allocator, map: std.process.Environ.Map) ![]const u8 {
    if (!map.contains("HOME")) return error.HomeNotSet;
    const home = map.get("HOME").?;
    const path = try std.mem.concat(alloc, u8, &[_][]const u8{ home, "/.config/fcitx5/profile" });
    return path;
}

fn getProfile(alloc: std.mem.Allocator, io: std.Io, map: std.process.Environ.Map) !std.Io.File {
    const path = try getProfilePath(alloc, map);
    defer alloc.free(path);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    return file;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var debug = std.heap.DebugAllocator(.{}).init;
    defer _ = if (isProd) arena.deinit() else debug.deinit();
    const alloc = if (isProd) arena.allocator() else debug.allocator();
    var thread = std.Io.Threaded.init_single_threaded;
    const io = thread.io();
    var map = try init.environ.createMap(alloc);
    defer map.deinit();

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

    const file = try getProfile(alloc, io, map);
    defer file.close(io);
    var fcitxMap = try std.Io.File.MemoryMap.create(io, file, .{ .offset = 0, .protection = .{ .read = true, .execute = false, .write = false }, .len = try file.length(io) });
    defer fcitxMap.destroy(io);
    var reader = std.Io.Reader.fixed(fcitxMap.memory);

    const profile = try lang_group.readProfile(alloc, &reader);
    defer profile.deinit(alloc);

    const currentGroup = try currentGroupCF.getReplyStr();
    const currentLanguage = try currentInputCF.getReplyStr();

    for (profile.groups) |group| {
        if (!std.mem.eql(u8, group.name(), currentGroup)) continue;
        for (0..group.langCount()) |i| {
            const language = group.langAt(i);
            if (!std.mem.eql(u8, language, currentLanguage)) continue;
            changeCFParam.value = try std.mem.concat(alloc, u8, &[_][]const u8{ group.langAt(i + 1), "" });
            defer alloc.free(changeCFParam.value);
            bus.callFn(&changeCF, fcitx5Dest);
            return;
        }
    }
}
// zig build-exe ./language-changer.zig -O ReleaseSmall -fsingle-threaded -fno-error-tracing -fno-unwind-tables -fno-sanitize-c -fno-stack-protector -mcmodel=small
// zig build -Doptimize=ReleaseSmall

test {
    _ = std.testing.refAllDecls(lang_group);
}
