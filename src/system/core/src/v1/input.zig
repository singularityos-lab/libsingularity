const std = @import("std");
const sys = @import("../sys.zig");
const bus = @import("bus.zig");

pub const service = "dev.sinty.Input1";
const path = "/dev/sinty/Input1";

pub const Engine = extern struct {
    name: [64]u8,
    label: [128]u8,
    symbol: [16]u8,
    language: [32]u8,
};

pub const Engines = sys.List(Engine);

pub fn engines(c: *bus.Conn) !*Engines {
    var m = try c.call(service, path, service, "ListEngines", "", "", 25000);
    defer m.deinit();
    if (!std.mem.eql(u8, m.signature, "aas")) return error.Invalid;
    const list = try Engines.create();
    errdefer list.destroy();
    var r = m.reader();
    const end = try r.array('a');
    while (r.pos < end) {
        var e = std.mem.zeroes(Engine);
        const inner = try r.array('s');
        var i: usize = 0;
        while (r.pos < inner) : (i += 1) {
            const s = try r.string();
            switch (i) {
                0 => sys.copyName(&e.name, s),
                1 => sys.copyName(&e.label, s),
                2 => sys.copyName(&e.symbol, s),
                3 => sys.copyName(&e.language, s),
                else => {},
            }
        }
        if (e.name[0] != 0) try list.append(e);
    }
    return list;
}

fn validName(name: []const u8) bool {
    if (name.len > 63) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

pub fn select(c: *bus.Conn, name: []const u8) !void {
    if (!validName(name)) return error.Invalid;
    var m = try c.callWith(service, path, service, "SelectEngine", "s", .{name});
    m.deinit();
}

pub fn active(c: *bus.Conn, out: []u8) ![]const u8 {
    var m = try c.getProperty(service, path, service, "Engine");
    defer m.deinit();
    var r = m.reader();
    if (!std.mem.eql(u8, try r.variant(), "s")) return error.Invalid;
    const s = try r.string();
    sys.copyName(out, s);
    return sys.cstr(out);
}

pub const Conversion = enum { none, simplified, traditional, taiwan, hongkong };
pub const Option = union(enum) {
    conversion: Conversion,
    fullwidth: bool,
    learn: bool,
};

pub fn configure(c: *bus.Conn, name: []const u8, opt: Option) !void {
    if (!validName(name) or name.len == 0) return error.Invalid;
    var w = bus.Writer{};
    defer w.deinit();
    try w.string(name);
    const a = try w.beginArray('{');
    try w.beginStruct();
    switch (opt) {
        .conversion => |v| {
            try w.string("conversion");
            try w.variant("s");
            try w.string(@tagName(v));
        },
        .fullwidth => |v| {
            try w.string("fullwidth");
            try w.variant("b");
            try w.boolean(v);
        },
        .learn => |v| {
            try w.string("learn");
            try w.variant("b");
            try w.boolean(v);
        },
    }
    try w.endArray(a);
    var m = try c.call(service, path, service, "Configure", "sa{sv}", w.bytes(), 25000);
    m.deinit();
}

const Fake = struct {
    conn: bus.Conn,
    stop: std.atomic.Value(bool) = .init(false),
    engine: [64]u8 = [_]u8{0} ** 64,
    conversion: [16]u8 = [_]u8{0} ** 16,
    fullwidth: bool = true,

    fn handle(f: *Fake, m: *const bus.Message) !void {
        var w = bus.Writer{};
        defer w.deinit();
        if (std.mem.eql(u8, m.member, "ListEngines")) {
            const all = try w.beginArray('a');
            for ([_][4][]const u8{ .{ "pinyin", "Pinyin", "拼", "zh_CN" }, .{ "hangul", "Hangul", "한", "ko" }, .{ "broken", "", "", "" } }) |e| {
                const one = try w.beginArray('s');
                const n: usize = if (std.mem.eql(u8, e[0], "broken")) 1 else 4;
                for (e[0..n]) |s| try w.string(s);
                try w.endArray(one);
            }
            try w.endArray(all);
            return f.conn.reply(m, "aas", w.bytes());
        }
        if (std.mem.eql(u8, m.member, "SelectEngine")) {
            var r = m.reader();
            const name = try r.string();
            if (name.len > 0 and !std.mem.eql(u8, name, "pinyin") and !std.mem.eql(u8, name, "hangul")) return f.conn.replyError(m, "dev.sinty.Input1.Error.UnknownEngine", name);
            sys.copyName(&f.engine, name);
            return f.conn.reply(m, "", "");
        }
        if (std.mem.eql(u8, m.member, "Get")) {
            try w.variant("s");
            try w.string(sys.cstr(&f.engine));
            return f.conn.reply(m, "v", w.bytes());
        }
        if (std.mem.eql(u8, m.member, "Configure")) {
            var r = m.reader();
            _ = try r.string();
            const end = try r.array('{');
            while (r.pos < end) {
                try r.structure();
                const key = try r.string();
                const sig = try r.variant();
                if (std.mem.eql(u8, key, "conversion")) {
                    sys.copyName(&f.conversion, try r.string());
                } else if (std.mem.eql(u8, key, "fullwidth")) {
                    f.fullwidth = try r.boolean();
                } else try r.skip(sig);
            }
            return f.conn.reply(m, "", "");
        }
        return f.conn.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", m.member);
    }

    fn run(f: *Fake) void {
        while (!f.stop.load(.acquire)) {
            var m = (f.conn.next(50) catch return) orelse continue;
            defer m.deinit();
            if (m.kind == .call) f.handle(&m) catch {};
        }
    }
};

test "input engines are listed, selected and configured over the bus" {
    const addr = std.c.getenv("SINTY_BUS_ADDRESS") orelse return error.SkipZigTest;
    var fake = Fake{ .conn = try bus.Conn.open(std.mem.span(addr)) };
    defer fake.conn.close();
    try fake.conn.requestName(service);
    const t = try std.Thread.spawn(.{}, Fake.run, .{&fake});
    defer {
        fake.stop.store(true, .release);
        t.join();
    }
    var c = try bus.Conn.open(std.mem.span(addr));
    defer c.close();

    const list = try engines(&c);
    defer list.destroy();
    try std.testing.expectEqual(@as(usize, 3), list.count());
    try std.testing.expectEqualStrings("拼", sys.cstr(&list.at(0).?.symbol));
    try std.testing.expectEqualStrings("ko", sys.cstr(&list.at(1).?.language));
    try std.testing.expectEqualStrings("", sys.cstr(&list.at(2).?.label));

    try select(&c, "hangul");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hangul", try active(&c, &buf));
    try std.testing.expectError(error.Io, select(&c, "klingon"));
    try std.testing.expect(std.mem.indexOf(u8, c.lastError(), "UnknownEngine") != null);
    try std.testing.expectError(error.Invalid, select(&c, "bad name"));
    try select(&c, "");
    try std.testing.expectEqualStrings("", try active(&c, &buf));

    try configure(&c, "pinyin", .{ .conversion = .taiwan });
    try configure(&c, "pinyin", .{ .fullwidth = false });
    try std.testing.expectEqualStrings("taiwan", sys.cstr(&fake.conversion));
    try std.testing.expect(!fake.fullwidth);
}

test "the sinty-input service answers the core client" {
    const addr = std.c.getenv("SINTY_INPUT_ADDRESS") orelse return error.SkipZigTest;
    var c = try bus.Conn.open(std.mem.span(addr));
    defer c.close();
    const list = try engines(&c);
    defer list.destroy();
    var hangul: ?*const Engine = null;
    for (list.items.items) |*e| {
        if (std.mem.eql(u8, sys.cstr(&e.name), "hangul")) hangul = e;
    }
    try std.testing.expectEqualStrings("한", sys.cstr(&(hangul orelse return error.TestUnexpectedResult).symbol));
    try select(&c, "hangul");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hangul", try active(&c, &buf));
    try std.testing.expectError(error.Invalid, configure(&c, "hangul", .{ .fullwidth = false }));
    try std.testing.expect(std.mem.indexOf(u8, c.lastError(), "InvalidArgs") != null);
    try std.testing.expectError(error.Io, select(&c, "klingon"));
    try select(&c, "");
    try std.testing.expectEqualStrings("", try active(&c, &buf));
}
