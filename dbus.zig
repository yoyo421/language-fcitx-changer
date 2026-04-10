const std = @import("std");
const dbus = @import("sd-bus");
const DBus = @This();

const DBUS_ERROR_NULL = dbus.sd_bus_error{ .name = 0, .message = 0, ._need_free = 0 };
const DBUS_ERROR_BUFFER = @Int(.unsigned, @bitSizeOf(dbus.sd_bus_error));

// busctl --user introspect org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1
// busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 InputMethodGroupInfo s Default

bus: ?*dbus.sd_bus,
busError: dbus.sd_bus_error,
pub const empty = DBus{ .bus = null, .busError = DBUS_ERROR_NULL };
pub inline fn init(self: *DBus) !void {
    if (dbus.sd_bus_open_user(&self.bus) < 0) return error.FailedToConnectToDBus;
}

pub const DBusDestination = struct {
    destination: [:0]const u8,
    path: [:0]const u8,
    interface: [:0]const u8,
};

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

pub fn callFn(self: *DBus, f: *CallFunction, dest: DBusDestination) void {
    var r = dbus.sd_bus_message_new_method_call(
        self.bus,
        &f.msg,
        dest.destination.ptr,
        dest.path.ptr,
        dest.interface.ptr,
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

pub inline fn deinit(self: *DBus) void {
    _ = dbus.sd_bus_unref(self.bus);
    dbus.sd_bus_error_free(&self.busError);
}
