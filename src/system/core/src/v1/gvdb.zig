const std = @import("std");
const sys = @import("../sys.zig");
const gv = @import("gvariant.zig");

const item_size = 24;

pub const Table = struct {
    data: []const u8,
    items: usize = 0,
    items_at: usize = 0,

    pub fn root(data: []const u8) !Table {
        if (data.len < 24) return error.Invalid;
        if (!std.mem.eql(u8, data[0..8], "GVariant")) return error.Invalid;
        if (std.mem.readInt(u32, data[8..12], .little) != 0) return error.Unsupported;
        return at(data, std.mem.readInt(u32, data[16..20], .little), std.mem.readInt(u32, data[20..24], .little));
    }

    fn at(data: []const u8, start: u32, end: u32) !Table {
        if (start > end or end > data.len or end - start < 8 or start % 4 != 0) return error.Invalid;
        const head = data[start..end];
        const bloom: usize = std.mem.readInt(u32, head[0..4], .little) & ((1 << 27) - 1);
        const buckets: usize = std.mem.readInt(u32, head[4..8], .little);
        const items_at = 8 + 4 * (bloom + buckets);
        if (items_at > head.len or (head.len - items_at) % item_size != 0) return error.Invalid;
        return .{ .data = data, .items = (head.len - items_at) / item_size, .items_at = start + items_at };
    }

    fn item(t: Table, i: usize) []const u8 {
        const off = t.items_at + i * item_size;
        return t.data[off .. off + item_size];
    }

    fn keyPart(t: Table, i: usize) ![]const u8 {
        const it = t.item(i);
        const start = std.mem.readInt(u32, it[8..12], .little);
        const size = std.mem.readInt(u16, it[12..14], .little);
        if (@as(usize, start) + size > t.data.len) return error.Invalid;
        return t.data[start .. start + size];
    }

    fn matches(t: Table, i: usize, key: []const u8, depth: usize) !bool {
        if (depth > 64) return error.Invalid;
        const part = try t.keyPart(i);
        if (!std.mem.endsWith(u8, key, part)) return false;
        const head = key[0 .. key.len - part.len];
        const parent = std.mem.readInt(u32, t.item(i)[4..8], .little);
        if (parent == 0xffffffff) return head.len == 0;
        if (parent >= t.items) return error.Invalid;
        return t.matches(parent, head, depth + 1);
    }

    fn find(t: Table, key: []const u8) !?usize {
        for (0..t.items) |i| if (try t.matches(i, key, 0)) return i;
        return null;
    }

    fn pointer(t: Table, i: usize) ![]const u8 {
        const it = t.item(i);
        const start = std.mem.readInt(u32, it[16..20], .little);
        const end = std.mem.readInt(u32, it[20..24], .little);
        if (start > end or end > t.data.len) return error.Invalid;
        return t.data[start..end];
    }

    pub fn value(t: Table, key: []const u8) !?gv.Value {
        const i = (try t.find(key)) orelse return null;
        if (t.item(i)[14] != 'v') return null;
        return try (gv.Value{ .sig = "v", .data = try t.pointer(i) }).variant();
    }

    pub fn table(t: Table, key: []const u8) !?Table {
        const i = (try t.find(key)) orelse return null;
        if (t.item(i)[14] != 'H') return null;
        const it = t.item(i);
        return try at(t.data, std.mem.readInt(u32, it[16..20], .little), std.mem.readInt(u32, it[20..24], .little));
    }

    pub fn has(t: Table, key: []const u8) !bool {
        return (try t.find(key)) != null;
    }
};

test "a schema file compiled by glib is read" {
    const path = std.c.getenv("SINTY_GVDB_FIXTURE") orelse return error.SkipZigTest;
    const data = try sys.readAlloc(sys.gpa, path, 64 << 20);
    defer sys.gpa.free(data);
    const root = try Table.root(data);
    const schema = (try root.table("dev.sinty.Test")) orelse return error.TestUnexpectedResult;
    const path_v = (try schema.value(".path")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/dev/sinty/test/", try path_v.string());
    const key = (try schema.value("enabled")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(try (try key.child(0)).boolean());
    try std.testing.expect((try schema.value("missing")) == null);
    try std.testing.expect((try root.table("no.such.Schema")) == null);
    try std.testing.expectError(error.Invalid, Table.root("GVariant"));
}
