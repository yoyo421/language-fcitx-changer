const std = @import("std");
const dbus = @import("sd-bus");

const PROFILE_PATH = "/home/yoav/.config/fcitx5/profile";
pub const panic = @import("std").debug.no_panic;

pub const std_options: std.Options = .{ .networking = false, .allow_stack_tracing = false };

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
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.find(u8, line, "Items") != null) {
            currentScope = .language;
        } else if (std.mem.find(u8, line, "Groups") != null) {
            currentGroup = groups.addOne(alloc) catch unreachable;
            currentGroup.?.* = .empty;
            currentScope = .group;
        }
        if (std.mem.find(u8, line, "Name") != null) {
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

const DBUS_ERROR_NULL = dbus.sd_bus_error{ .name = 0, .message = 0, ._need_free = 0 };
const DBUS_ERROR_BUFFER = @Int(.unsigned, @bitSizeOf(dbus.sd_bus_error));

// busctl --user introspect org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1
// busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 InputMethodGroupInfo s Default
const FcitxComm = struct {
    bus: ?*dbus.sd_bus = null,
    busError: dbus.sd_bus_error = DBUS_ERROR_NULL,
    pub inline fn init(self: *FcitxComm) !void {
        if (dbus.sd_bus_open_user(&self.bus) < 0) return error.FailedToConnectToDBus;
    }

    pub const CallFunctionParam = struct {
        mode: u8,
        value: []const u8,
    };

    pub const CallFunction = struct {
        name: []const u8,
        params: []const *const CallFunctionParam = &[0]*const CallFunctionParam{},
        msg: ?*dbus.sd_bus_message = null,
        reply: ?*dbus.sd_bus_message = null,
        err: dbus.sd_bus_error = @bitCast(@as(DBUS_ERROR_BUFFER, 0)),

        pub fn deinit(self: *CallFunction) void {
            if (dbus.sd_bus_message_is_empty(self.reply) > 0) _ = dbus.sd_bus_message_unref(self.reply);
            if (@as(DBUS_ERROR_BUFFER, @bitCast(self.err)) != 0) dbus.sd_bus_error_free(&self.err);
        }

        pub fn getReplyStrC(self: *CallFunction) ![*c]const u8 {
            if (self.reply == null) return error.NoReply;
            var im_name_sential: [*c]const u8 = undefined;
            if (dbus.sd_bus_message_read(self.reply, "s", &im_name_sential) < 0) return error.FailedToReadMethodResponse;
            return im_name_sential;
        }

        pub fn getReplyStr(self: *CallFunction) ![]const u8 {
            const im_name_sential = try self.getReplyStrC();
            return im_name_sential[0..std.mem.indexOfSentinel(u8, 0, im_name_sential)];
        }
    };

    pub fn callFns(self: *FcitxComm, f: *CallFunction) void {
        var r = dbus.sd_bus_message_new_method_call(
            self.bus,
            &f.msg,
            "org.fcitx.Fcitx5",
            "/controller",
            "org.fcitx.Fcitx.Controller1",
            f.name.ptr,
        );
        defer {
            _ = dbus.sd_bus_message_unref(f.msg);
            f.msg = null;
        }
        if (r < 0) {
            std.debug.print("Failed to create message for {s}: {any}; {s}\n", .{ f.name, r, f.err.message });
            return;
        }

        for (f.params) |param| {
            r = dbus.sd_bus_message_append(f.msg, (&[2]u8{ param.mode, 0 }).ptr, param.value.ptr);
            if (r < 0) {
                std.debug.print("Failed to append parameter for {s}: {any}; {s}\n", .{ f.name, r, f.err.name });
                return;
            }
        }

        if (dbus.sd_bus_call(self.bus, f.msg, 0, &f.err, &f.reply) < 0) {
            std.debug.print("Failed to call {s}: {any}; {s}\n", .{ f.name, f.err, f.err.message });
        }
    }

    pub inline fn deinit(self: *FcitxComm) void {
        _ = dbus.sd_bus_unref(self.bus);
        dbus.sd_bus_error_free(&self.busError);
    }
};

// pub fn main() !void {
//     var bus: FcitxComm = .{};
//     defer bus.deinit();
//     try bus.init();
//     var CIM = FcitxComm.CallFunction{ .name = "CurrentInputMethod" };
//     var CG = FcitxComm.CallFunction{ .name = "CurrentInputMethodGroup" };
//     defer CIM.deinit();
//     defer CG.deinit();
//     const functions: [2]*FcitxComm.CallFunction = .{ &CIM, &CG };
//     defer for (functions) |f| f.deinit();
//     bus.callFns(&functions);
//     std.debug.print("Current IM: {s}\n", .{try functions[0].getReplyStrC()});
//     std.debug.print("Current Group: {s}\n", .{try functions[1].getReplyStrC()});

//     var changeParam = FcitxComm.CallFunctionParam{ .mode = 's', .value = "keyboard-il" };
//     var change = FcitxComm.CallFunction{ .name = "SetCurrentIM", .params = &.{&changeParam} };
//     defer change.deinit();
//     bus.callFns(&.{&change});
// }

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    var thread = std.Io.Threaded.init_single_threaded;
    const io = thread.io();

    var bus: FcitxComm = .{};
    defer bus.deinit();
    try bus.init();
    var currentInputCF: FcitxComm.CallFunction = .{ .name = "CurrentInputMethod" };
    var currentGroupCF: FcitxComm.CallFunction = .{ .name = "CurrentInputMethodGroup" };
    var changeCFParam = FcitxComm.CallFunctionParam{ .mode = 's', .value = "" };
    var changeCF: FcitxComm.CallFunction = .{ .name = "SetCurrentIM", .params = &.{&changeCFParam} };
    defer currentInputCF.deinit();
    defer currentGroupCF.deinit();
    defer changeCF.deinit();
    bus.callFns(&currentInputCF);
    bus.callFns(&currentGroupCF);

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
            bus.callFns(&changeCF);
            return;
        }
    }
}
// zig build-exe ./language-changer.zig -O ReleaseSmall -fsingle-threaded -fno-error-tracing -fno-unwind-tables -fno-sanitize-c -fno-stack-protector -mcmodel=small
// zig build -Doptimize=ReleaseSmall
