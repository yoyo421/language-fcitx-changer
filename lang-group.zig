const std = @import("std");

pub const Group = struct {
    pub const Pos = struct {
        start: u16,
        length: u16,
        pub const zero = Pos{ .start = 0, .length = 0 };
        pub inline fn end(self: Pos) error{OutofBounds}!u16 {
            if (self.length == 0) return self.start;
            const value: u16, const overflow: u1 = @addWithOverflow(self.start, self.length);
            if (overflow == 1) return error.OutofBounds;
            return value;
        }
        pub inline fn slice(self: Pos, bytes: []const u8) []const u8 {
            return bytes[self.start..][0..self.length];
        }
    };

    bytes: std.ArrayList(u8),
    pos: std.ArrayList(Pos),
    namePos: Pos,

    pub const empty = Group{ .bytes = .empty, .pos = .empty, .namePos = .zero };
    pub fn deinit(self: Group, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes.allocatedSlice());
        alloc.free(self.pos.allocatedSlice());
    }

    pub inline fn name(self: Group) []const u8 {
        return self.namePos.slice(self.bytes.items);
    }
    pub inline fn langCount(self: Group) usize {
        return self.pos.items.len;
    }
    pub inline fn langAt(self: Group, index: usize) []const u8 {
        const i = index % self.langCount();
        if (self.langCount() == 0) return self.bytes.items[0..0];
        return self.pos.items[i].slice(self.bytes.items);
    }
    inline fn last(self: Group) Pos {
        if (self.langCount() == 0) return self.namePos;
        return self.pos.items[self.langCount() - 1];
    }

    fn addLanguage(self: *Group, alloc: std.mem.Allocator, language: []const u8) error{ OutofBounds, OutOfMemory }!void {
        const end = try self.last().end();
        const newPos: Pos = .{ .start = end, .length = @intCast(language.len) };
        _ = try newPos.end(); // Check for overflow
        try self.bytes.appendSlice(alloc, language);
        try self.pos.append(alloc, newPos);
    }
};

pub const Profile = struct {
    groups: []Group,

    pub fn deinit(self: Profile, alloc: std.mem.Allocator) void {
        for (self.groups) |group| group.deinit(alloc);
        alloc.free(self.groups);
    }
};

const ReadProfileScope = enum {
    group,
    language,
    none,
};
pub fn readProfile(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Profile {
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
            try g.addLanguage(alloc, name);
            if (currentScope == .group) g.namePos = g.pos.pop() orelse unreachable;
        }
    }

    return .{
        .groups = try groups.toOwnedSlice(alloc),
    };
}

test "Pos.end calculates correct end position" {
    const pos: Group.Pos = .{ .start = 10, .length = 5 };
    const result = try pos.end();
    try std.testing.expectEqual(result, 15);
}

test "Pos.end detects overflow" {
    const pos: Group.Pos = .{ .start = 65535, .length = 1 };
    const result = pos.end();
    try std.testing.expectError(error.OutofBounds, result);
}

test "Pos.slice extracts correct substring" {
    const bytes = "hello world";
    const pos: Group.Pos = .{ .start = 0, .length = 5 };
    const result = pos.slice(bytes);
    try std.testing.expectEqualStrings(result, "hello");
}

test "Group.name returns group name" {
    const allocator = std.testing.allocator;

    var group = Group.empty;
    try group.bytes.appendSlice(allocator, "TestGroup");
    try group.pos.append(allocator, .{ .start = 0, .length = 9 });
    group.namePos = .{ .start = 0, .length = 9 };
    defer group.deinit(allocator);

    try std.testing.expectEqualStrings(group.name(), "TestGroup");
}

test "Group.addLanguage adds language correctly" {
    const allocator = std.testing.allocator;

    var group = Group.empty;
    try group.pos.append(allocator, .{ .start = 0, .length = 0 });
    defer group.deinit(allocator);

    try group.addLanguage(allocator, "en");
    try group.addLanguage(allocator, "zh");

    try std.testing.expectEqual(group.pos.items.len, 3);
    try std.testing.expectEqualStrings(group.pos.items[1].slice(group.bytes.items), "en");
    try std.testing.expectEqualStrings(group.pos.items[2].slice(group.bytes.items), "zh");
}

test "readProfile parses groups correctly" {
    const allocator = std.testing.allocator;
    const input = "# Comment\nGroups\nName=GroupA\nItems\nName=en\nName=zh\n";
    var fbs = std.Io.Reader.fixed(input);

    const profile = try readProfile(allocator, &fbs);
    defer profile.deinit(allocator);

    try std.testing.expectEqual(profile.groups.len, 1);
    try std.testing.expectEqualStrings(profile.groups[0].name(), "GroupA");
}

test "readProfile parses multiple groups" {
    const allocator = std.testing.allocator;
    const input = "Groups\nName=Group1\nItems\nName=en\nGroups\nName=Group2\nItems\nName=fr\n";
    var fbs = std.Io.Reader.fixed(input);

    const profile = try readProfile(allocator, &fbs);
    defer profile.deinit(allocator);

    try std.testing.expectEqual(profile.groups.len, 2);
    try std.testing.expectEqualStrings(profile.groups[0].name(), "Group1");
    try std.testing.expectEqualStrings(profile.groups[1].name(), "Group2");
}

test "readProfile ignores comments and empty lines" {
    const allocator = std.testing.allocator;
    const input = "# This is a comment\n\nGroups\n# Another comment\nName=GroupA\n\nItems\nName=en\n";
    var fbs = std.Io.Reader.fixed(input);

    const profile = try readProfile(allocator, &fbs);
    defer profile.deinit(allocator);

    try std.testing.expectEqual(profile.groups.len, 1);
    try std.testing.expectEqualStrings(profile.groups[0].name(), "GroupA");
}
