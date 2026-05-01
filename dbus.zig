const std = @import("std");

const dbus = @import("sd-bus");

const DBus = @This();

const DBUS_ERROR_NULL = dbus.sd_bus_error{ .name = 0, .message = 0, ._need_free = 0 };

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
    err: dbus.sd_bus_error = DBUS_ERROR_NULL,

    pub fn deinit(self: *CallFunction) void {
        _ = dbus.sd_bus_message_unref(self.reply);
        _ = dbus.sd_bus_error_free(&self.err);
        self.reply = null;
        self.err = DBUS_ERROR_NULL;
    }

    /// Reads the reply as a C string. The caller is responsible for ensuring that the reply is valid and that the string is null-terminated.
    pub fn getReplyStrC(self: *CallFunction) ![*c]const u8 {
        if (self.reply == null) return error.NoReply;
        var im_name_sential: [*c]const u8 = undefined;
        if (dbus.sd_bus_message_read(self.reply, "s", &im_name_sential) < 0) return error.FailedToReadMethodResponse;
        return im_name_sential;
    }

    /// Reads the reply as a Zig string. The caller is responsible for ensuring that the reply is valid and that the string is null-terminated.
    pub fn getReplyStr(self: *CallFunction) ![]const u8 {
        const im_name_sential = try self.getReplyStrC();
        return im_name_sential[0..std.mem.len(im_name_sential)];
    }
};

/// Calls a method on the D-Bus.
/// The caller is responsible for ensuring that the parameters are valid and that the reply is handled properly
///
/// (e.g., by calling `getReplyStr` or `getReplyStrC`)
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
