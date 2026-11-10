const std = @import("std");
const sys = @import("../sys.zig");

pub fn typeEnd(sig: []const u8, i: usize) !usize {
    if (i >= sig.len) return error.Invalid;
    return switch (sig[i]) {
        'b', 'y', 'n', 'q', 'i', 'u', 'x', 't', 'h', 'd', 's', 'o', 'g', 'v' => i + 1,
        'a', 'm' => typeEnd(sig, i + 1),
        '(' => blk: {
            var j = i + 1;
            while (j < sig.len and sig[j] != ')') j = try typeEnd(sig, j);
            if (j >= sig.len) return error.Invalid;
            break :blk j + 1;
        },
        '{' => blk: {
            if (i + 1 >= sig.len or !basic(sig[i + 1])) return error.Invalid;
            const j = try typeEnd(sig, i + 2);
            if (j >= sig.len or sig[j] != '}') return error.Invalid;
            break :blk j + 1;
        },
        else => error.Invalid,
    };
}

fn basic(c: u8) bool {
    return std.mem.indexOfScalar(u8, "bynqiuxthdsog", c) != null;
}

pub fn valid(sig: []const u8) bool {
    if (sig.len == 0) return false;
    const end = typeEnd(sig, 0) catch return false;
    return end == sig.len;
}

pub fn alignment(t: []const u8) usize {
    return switch (t[0]) {
        'b', 'y', 's', 'o', 'g' => 1,
        'n', 'q' => 2,
        'i', 'u', 'h' => 4,
        'x', 't', 'd', 'v' => 8,
        'a', 'm' => alignment(t[1..]),
        '(', '{' => blk: {
            var a: usize = 1;
            var j: usize = 1;
            while (t[j] != ')' and t[j] != '}') {
                const e = typeEnd(t, j) catch return 1;
                a = @max(a, alignment(t[j..e]));
                j = e;
            }
            break :blk a;
        },
        else => 1,
    };
}

pub fn fixedSize(t: []const u8) ?usize {
    return switch (t[0]) {
        'b', 'y' => 1,
        'n', 'q' => 2,
        'i', 'u', 'h' => 4,
        'x', 't', 'd' => 8,
        '(', '{' => blk: {
            var pos: usize = 0;
            var j: usize = 1;
            while (t[j] != ')' and t[j] != '}') {
                const e = typeEnd(t, j) catch return null;
                const c = t[j..e];
                const fs = fixedSize(c) orelse return null;
                pos = alignUp(pos, alignment(c)) + fs;
                j = e;
            }
            if (pos == 0) break :blk 1;
            break :blk alignUp(pos, alignment(t));
        },
        else => null,
    };
}

fn alignUp(n: usize, a: usize) usize {
    return (n + a - 1) / a * a;
}

fn offsetSize(len: usize) usize {
    if (len == 0) return 0;
    if (len <= 0xff) return 1;
    if (len <= 0xffff) return 2;
    if (len <= 0xffffffff) return 4;
    return 8;
}

fn readOffset(data: []const u8, at: usize, size: usize) usize {
    var v: usize = 0;
    for (0..size) |k| v |= @as(usize, data[at + k]) << @intCast(8 * k);
    return v;
}

pub const Value = struct {
    sig: []const u8,
    data: []const u8,

    pub fn boolean(v: Value) !bool {
        if (v.sig.len != 1 or v.sig[0] != 'b' or v.data.len != 1) return error.Invalid;
        return v.data[0] != 0;
    }

    pub fn int(v: Value) !i64 {
        if (v.sig.len != 1) return error.Invalid;
        const d = v.data;
        return switch (v.sig[0]) {
            'y' => if (d.len == 1) d[0] else error.Invalid,
            'n' => if (d.len == 2) std.mem.readInt(i16, d[0..2], .little) else error.Invalid,
            'q' => if (d.len == 2) std.mem.readInt(u16, d[0..2], .little) else error.Invalid,
            'i', 'h' => if (d.len == 4) std.mem.readInt(i32, d[0..4], .little) else error.Invalid,
            'u' => if (d.len == 4) std.mem.readInt(u32, d[0..4], .little) else error.Invalid,
            'x' => if (d.len == 8) std.mem.readInt(i64, d[0..8], .little) else error.Invalid,
            't' => if (d.len == 8) std.math.cast(i64, std.mem.readInt(u64, d[0..8], .little)) orelse error.Invalid else error.Invalid,
            else => error.Invalid,
        };
    }

    pub fn double(v: Value) !f64 {
        if (v.sig.len != 1 or v.sig[0] != 'd' or v.data.len != 8) return error.Invalid;
        return @bitCast(std.mem.readInt(u64, v.data[0..8], .little));
    }

    pub fn string(v: Value) ![]const u8 {
        if (v.sig.len != 1 or std.mem.indexOfScalar(u8, "sog", v.sig[0]) == null) return error.Invalid;
        if (v.data.len == 0 or v.data[v.data.len - 1] != 0) return error.Invalid;
        const s = v.data[0 .. v.data.len - 1];
        if (std.mem.indexOfScalar(u8, s, 0) != null) return error.Invalid;
        return s;
    }

    pub fn variant(v: Value) !Value {
        if (v.sig.len != 1 or v.sig[0] != 'v') return error.Invalid;
        const z = std.mem.lastIndexOfScalar(u8, v.data, 0) orelse return error.Invalid;
        const sig = v.data[z + 1 ..];
        if (!valid(sig)) return error.Invalid;
        return .{ .sig = sig, .data = v.data[0..z] };
    }

    pub fn maybe(v: Value) !?Value {
        if (v.sig[0] != 'm') return error.Invalid;
        const inner = v.sig[1..];
        if (v.data.len == 0) return null;
        if (fixedSize(inner)) |fs| {
            if (v.data.len != fs) return error.Invalid;
            return .{ .sig = inner, .data = v.data };
        }
        if (v.data[v.data.len - 1] != 0) return error.Invalid;
        return .{ .sig = inner, .data = v.data[0 .. v.data.len - 1] };
    }

    pub fn len(v: Value) !usize {
        if (v.sig[0] != 'a') return error.Invalid;
        const elem = v.sig[1..];
        if (fixedSize(elem)) |fs| {
            if (v.data.len % fs != 0) return error.Invalid;
            return v.data.len / fs;
        }
        if (v.data.len == 0) return 0;
        const osz = offsetSize(v.data.len);
        const last = readOffset(v.data, v.data.len - osz, osz);
        if (last > v.data.len or (v.data.len - last) % osz != 0) return error.Invalid;
        return (v.data.len - last) / osz;
    }

    pub fn at(v: Value, i: usize) !Value {
        const n = try v.len();
        if (i >= n) return error.Invalid;
        const elem = v.sig[1..];
        if (fixedSize(elem)) |fs| return .{ .sig = elem, .data = v.data[i * fs .. (i + 1) * fs] };
        const osz = offsetSize(v.data.len);
        const table = readOffset(v.data, v.data.len - osz, osz);
        const start = if (i == 0) 0 else alignUp(readOffset(v.data, table + (i - 1) * osz, osz), alignment(elem));
        const end = readOffset(v.data, table + i * osz, osz);
        if (start > end or end > table) return error.Invalid;
        return .{ .sig = elem, .data = v.data[start..end] };
    }

    pub fn child(v: Value, index: usize) !Value {
        if (v.sig[0] != '(' and v.sig[0] != '{') return error.Invalid;
        const osz = offsetSize(v.data.len);
        var frame = v.data.len;
        var pos: usize = 0;
        var j: usize = 1;
        var k: usize = 0;
        while (v.sig[j] != ')' and v.sig[j] != '}') : (k += 1) {
            const e = try typeEnd(v.sig, j);
            const c = v.sig[j..e];
            const last = v.sig[e] == ')' or v.sig[e] == '}';
            pos = alignUp(pos, alignment(c));
            const end = if (fixedSize(c)) |fs| pos + fs else if (last) frame else blk: {
                if (frame < osz) return error.Invalid;
                frame -= osz;
                break :blk readOffset(v.data, frame, osz);
            };
            if (pos > end or end > frame) return error.Invalid;
            if (k == index) return .{ .sig = c, .data = v.data[pos..end] };
            pos = end;
            j = e;
        }
        return error.Invalid;
    }
};

pub const Encoded = struct {
    sig: []const u8,
    bytes: []u8,

    pub fn deinit(e: *Encoded) void {
        sys.gpa.free(e.bytes);
    }
};

pub fn boolean(v: bool) ![]u8 {
    return sys.gpa.dupe(u8, &.{@intFromBool(v)});
}

pub fn integer(comptime T: type, v: T) ![]u8 {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    return sys.gpa.dupe(u8, &b);
}

pub fn double(v: f64) ![]u8 {
    return integer(u64, @bitCast(v));
}

pub fn string(s: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return error.Invalid;
    const out = try sys.gpa.alloc(u8, s.len + 1);
    @memcpy(out[0..s.len], s);
    out[s.len] = 0;
    return out;
}

pub fn variant(sig: []const u8, child_bytes: []const u8) ![]u8 {
    if (!valid(sig)) return error.Invalid;
    const out = try sys.gpa.alloc(u8, child_bytes.len + 1 + sig.len);
    @memcpy(out[0..child_bytes.len], child_bytes);
    out[child_bytes.len] = 0;
    @memcpy(out[child_bytes.len + 1 ..], sig);
    return out;
}

pub fn maybe(child_sig: []const u8, child_bytes: ?[]const u8) ![]u8 {
    const c = child_bytes orelse return sys.gpa.alloc(u8, 0);
    if (fixedSize(child_sig) != null) return sys.gpa.dupe(u8, c);
    const out = try sys.gpa.alloc(u8, c.len + 1);
    @memcpy(out[0..c.len], c);
    out[c.len] = 0;
    return out;
}

fn pickOffsetSize(body: usize, n: usize) usize {
    if (n == 0) return 0;
    for ([_]usize{ 1, 2, 4, 8 }) |s| if (offsetSize(body + n * s) <= s) return s;
    return 8;
}

fn appendOffset(out: *std.ArrayList(u8), v: usize, size: usize) !void {
    for (0..size) |k| try out.append(sys.gpa, @truncate(v >> @intCast(8 * k)));
}

pub fn array(elem_sig: []const u8, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(sys.gpa);
    const a = alignment(elem_sig);
    if (fixedSize(elem_sig)) |fs| {
        for (items) |it| {
            if (it.len != fs) return error.Invalid;
            try out.appendSlice(sys.gpa, it);
        }
        return out.toOwnedSlice(sys.gpa);
    }
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(sys.gpa);
    for (items) |it| {
        while (out.items.len % a != 0) try out.append(sys.gpa, 0);
        try out.appendSlice(sys.gpa, it);
        try ends.append(sys.gpa, out.items.len);
    }
    const osz = pickOffsetSize(out.items.len, ends.items.len);
    for (ends.items) |e| try appendOffset(&out, e, osz);
    return out.toOwnedSlice(sys.gpa);
}

pub fn tuple(sig: []const u8, items: []const []const u8) ![]u8 {
    if (!valid(sig) or (sig[0] != '(' and sig[0] != '{')) return error.Invalid;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(sys.gpa);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(sys.gpa);
    var j: usize = 1;
    var k: usize = 0;
    while (sig[j] != ')' and sig[j] != '}') : (k += 1) {
        if (k >= items.len) return error.Invalid;
        const e = try typeEnd(sig, j);
        const c = sig[j..e];
        const last = sig[e] == ')' or sig[e] == '}';
        while (out.items.len % alignment(c) != 0) try out.append(sys.gpa, 0);
        if (fixedSize(c)) |fs| if (items[k].len != fs) return error.Invalid;
        try out.appendSlice(sys.gpa, items[k]);
        if (fixedSize(c) == null and !last) try ends.append(sys.gpa, out.items.len);
        j = e;
    }
    if (k != items.len) return error.Invalid;
    if (fixedSize(sig)) |fs| {
        while (out.items.len < fs) try out.append(sys.gpa, 0);
        return out.toOwnedSlice(sys.gpa);
    }
    const osz = pickOffsetSize(out.items.len, ends.items.len);
    var i = ends.items.len;
    while (i > 0) {
        i -= 1;
        try appendOffset(&out, ends.items[i], osz);
    }
    return out.toOwnedSlice(sys.gpa);
}

test "gvariant containers match the specification examples" {
    const s = try string("hello world");
    defer sys.gpa.free(s);
    try std.testing.expectEqualStrings("hello world\x00", s);

    const t = try tuple("(si)", &.{ try string("foo"), try integer(i32, -1) });
    defer sys.gpa.free(t);
    try std.testing.expectEqualSlices(u8, &.{ 'f', 'o', 'o', 0, 0xff, 0xff, 0xff, 0xff, 4 }, t);
    const tv = Value{ .sig = "(si)", .data = t };
    try std.testing.expectEqualStrings("foo", try (try tv.child(0)).string());
    try std.testing.expectEqual(@as(i64, -1), try (try tv.child(1)).int());

    const items: [2][]u8 = .{ try string("i"), try string("can") };
    defer for (items) |it| sys.gpa.free(it);
    const as = try array("s", &.{ items[0], items[1] });
    defer sys.gpa.free(as);
    try std.testing.expectEqualSlices(u8, &.{ 'i', 0, 'c', 'a', 'n', 0, 2, 6 }, as);
    const av = Value{ .sig = "as", .data = as };
    try std.testing.expectEqual(@as(usize, 2), try av.len());
    try std.testing.expectEqualStrings("can", try (try av.at(1)).string());

    const one = try integer(i32, 4);
    defer sys.gpa.free(one);
    const v = try variant("i", one);
    defer sys.gpa.free(v);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 0, 0, 0, 'i' }, v);
    const inner = try (Value{ .sig = "v", .data = v }).variant();
    try std.testing.expectEqual(@as(i64, 4), try inner.int());

    const ms = try maybe("s", "hi\x00");
    defer sys.gpa.free(ms);
    try std.testing.expectEqualSlices(u8, "hi\x00\x00", ms);
    const got = (try (Value{ .sig = "ms", .data = ms }).maybe()).?;
    try std.testing.expectEqualStrings("hi", try got.string());
    try std.testing.expect((try (Value{ .sig = "mi", .data = "" }).maybe()) == null);

    try std.testing.expectEqual(@as(?usize, 8), fixedSize("(yi)"));
    try std.testing.expectEqual(@as(?usize, 1), fixedSize("()"));
    try std.testing.expectEqual(@as(?usize, null), fixedSize("(ys)"));
    try std.testing.expect(valid("a{smv}"));
    try std.testing.expect(!valid("a{vs}"));
    try std.testing.expect(!valid("(i"));
    try std.testing.expectError(error.Invalid, (Value{ .sig = "as", .data = &.{ 'x', 0, 9 } }).at(0));
}
