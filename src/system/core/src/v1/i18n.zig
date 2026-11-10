const std = @import("std");
const sys = @import("../sys.zig");

pub const Text = extern struct {
    ptr: [*:0]u8,

    pub fn deinit(self: *Text) void {
        sys.gpa.free(std.mem.span(self.ptr));
    }
};

pub const TextList = sys.List(Text);

const archive_magic: u32 = 0xde020109;

fn appendUnique(list: *TextList, name: []const u8) !void {
    for (list.items.items) |t| if (std.mem.eql(u8, std.mem.span(t.ptr), name)) return;
    const copy = try sys.dupZ(sys.gpa, name);
    errdefer sys.gpa.free(std.mem.span(copy));
    try list.append(.{ .ptr = copy });
}

fn u32At(data: []const u8, off: usize) ?u32 {
    if (off + 4 > data.len) return null;
    return std.mem.readInt(u32, data[off..][0..4], .native);
}

pub fn archiveNames(data: []const u8, list: *TextList) !void {
    if ((u32At(data, 0) orelse return error.Invalid) != archive_magic) return error.Invalid;
    const hash_off = u32At(data, 8) orelse return error.Invalid;
    const hash_size = u32At(data, 16) orelse return error.Invalid;
    var i: usize = 0;
    while (i < hash_size) : (i += 1) {
        const e = @as(usize, hash_off) + i * 12;
        const name_off = u32At(data, e + 4) orelse return error.Invalid;
        const rec_off = u32At(data, e + 8) orelse return error.Invalid;
        if (name_off == 0 or rec_off == 0 or name_off >= data.len) continue;
        const tail = data[name_off..];
        const name = tail[0 .. std.mem.indexOfScalar(u8, tail, 0) orelse continue];
        if (name.len == 0) continue;
        try appendUnique(list, name);
    }
}

pub fn installed(root: []const u8) !*TextList {
    const list = try TextList.create();
    errdefer list.destroy();
    var buf: [512]u8 = undefined;
    if (sys.readAlloc(sys.gpa, try sys.pathZ(&buf, "{s}/locale-archive", .{root}), 512 << 20)) |data| {
        defer sys.gpa.free(data);
        archiveNames(data, list) catch {};
    } else |_| {}
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}", .{root})) catch return list;
    defer d.close();
    while (try d.next()) |entry| {
        var pb: [512]u8 = undefined;
        if (!sys.exists(try sys.pathZ(&pb, "{s}/{s}/LC_IDENTIFICATION", .{ root, entry.name }))) continue;
        try appendUnique(list, entry.name);
    }
    std.mem.sort(Text, list.items.items, {}, struct {
        fn lt(_: void, a: Text, b: Text) bool {
            return std.mem.order(u8, std.mem.span(a.ptr), std.mem.span(b.ptr)) == .lt;
        }
    }.lt);
    return list;
}

test "names from a locale archive and locale directories" {
    var data = [_]u8{0} ** 256;
    std.mem.writeInt(u32, data[0..4], archive_magic, .native);
    std.mem.writeInt(u32, data[8..12], 64, .native);
    std.mem.writeInt(u32, data[16..20], 4, .native);
    const names_at = [_]struct { slot: usize, name: []const u8, at: usize }{
        .{ .slot = 0, .name = "it_IT.utf8", .at = 160 },
        .{ .slot = 2, .name = "en_US.utf8", .at = 180 },
        .{ .slot = 3, .name = "it_IT.utf8", .at = 200 },
    };
    for (names_at) |n| {
        const e = 64 + n.slot * 12;
        std.mem.writeInt(u32, data[e + 4 ..][0..4], @intCast(n.at), .native);
        std.mem.writeInt(u32, data[e + 8 ..][0..4], 1, .native);
        @memcpy(data[n.at..][0..n.name.len], n.name);
    }
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "locale");
    try sys.put(root, "locale-archive", &data);
    try sys.put(root, "ja_JP.utf8/LC_IDENTIFICATION", "x");
    try sys.put(root, "C.utf8/LC_IDENTIFICATION", "x");
    try sys.put(root, "notalocale/README", "x");
    const l = try installed(root);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 4), l.count());
    try std.testing.expectEqualStrings("C.utf8", std.mem.span(l.items.items[0].ptr));
    try std.testing.expectEqualStrings("en_US.utf8", std.mem.span(l.items.items[1].ptr));
    try std.testing.expectEqualStrings("it_IT.utf8", std.mem.span(l.items.items[2].ptr));
    try std.testing.expectEqualStrings("ja_JP.utf8", std.mem.span(l.items.items[3].ptr));
}

test "the system locale archive lists at least one locale when present" {
    if (!sys.exists("/usr/lib/locale/locale-archive")) return error.SkipZigTest;
    const l = try installed("/usr/lib/locale");
    defer l.destroy();
    try std.testing.expect(l.count() > 0);
}
