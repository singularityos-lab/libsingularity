const std = @import("std");
const sys = @import("../sys.zig");
const bus = @import("bus.zig");

pub const service = "org.freedesktop.Notifications";
const path = "/org/freedesktop/Notifications";

pub const Urgency = enum(u8) { low = 0, normal = 1, critical = 2 };

pub const Notification = struct {
    app_name: []const u8 = "",
    icon: []const u8 = "",
    summary: []const u8,
    body: []const u8 = "",
    category: []const u8 = "",
    desktop_entry: []const u8 = "",
    replaces_id: u32 = 0,
    timeout_ms: i32 = -1,
    urgency: Urgency = .normal,
    transient: bool = false,
    actions: []const []const u8 = &.{},
};

pub const Request = extern struct {
    app_name: ?[*:0]const u8,
    icon: ?[*:0]const u8,
    summary: ?[*:0]const u8,
    body: ?[*:0]const u8,
    category: ?[*:0]const u8,
    desktop_entry: ?[*:0]const u8,
    actions: ?[*]const ?[*:0]const u8,
    n_actions: usize,
    replaces_id: u32,
    timeout_ms: i32,
    urgency: u8,
    transient: bool,
    pad: [6]u8,
};

fn opt(s: ?[*:0]const u8) []const u8 {
    return if (s) |p| std.mem.span(p) else "";
}

pub fn fromRequest(q: *const Request, actions: *[32][]const u8) !Notification {
    if (q.n_actions > actions.len or q.urgency > 2) return error.Invalid;
    if (q.n_actions > 0) {
        const list = q.actions orelse return error.Invalid;
        for (0..q.n_actions) |i| actions[i] = std.mem.span(list[i] orelse return error.Invalid);
    }
    return .{
        .app_name = opt(q.app_name),
        .icon = opt(q.icon),
        .summary = opt(q.summary),
        .body = opt(q.body),
        .category = opt(q.category),
        .desktop_entry = opt(q.desktop_entry),
        .replaces_id = q.replaces_id,
        .timeout_ms = q.timeout_ms,
        .urgency = @enumFromInt(q.urgency),
        .transient = q.transient,
        .actions = actions[0..q.n_actions],
    };
}

pub fn encode(w: *bus.Writer, n: Notification) !void {
    if (n.actions.len % 2 != 0) return error.Invalid;
    try bus.pack(w, "susss", .{ n.app_name, n.replaces_id, n.icon, n.summary, n.body });
    const acts = try w.beginArray('s');
    for (n.actions) |a| try w.string(a);
    try w.endArray(acts);
    const hints = try w.beginArray('{');
    try w.beginStruct();
    try w.string("urgency");
    try w.variant("y");
    try w.byte(@intFromEnum(n.urgency));
    if (n.category.len > 0) {
        try w.beginStruct();
        try w.string("category");
        try w.variant("s");
        try w.string(n.category);
    }
    if (n.desktop_entry.len > 0) {
        try w.beginStruct();
        try w.string("desktop-entry");
        try w.variant("s");
        try w.string(n.desktop_entry);
    }
    if (n.transient) {
        try w.beginStruct();
        try w.string("transient");
        try w.variant("b");
        try w.boolean(true);
    }
    try w.endArray(hints);
    try w.int32(n.timeout_ms);
}

pub fn send(c: *bus.Conn, n: Notification) !u32 {
    if (n.summary.len == 0) return error.Invalid;
    var w = bus.Writer{};
    defer w.deinit();
    try encode(&w, n);
    var m = try c.call(service, path, service, "Notify", "susssasa{sv}i", w.bytes(), 25000);
    defer m.deinit();
    if (!std.mem.eql(u8, m.signature, "u")) return error.Invalid;
    var r = m.reader();
    return r.uint32();
}

pub fn close(c: *bus.Conn, id: u32) !void {
    var m = try c.callWith(service, path, service, "CloseNotification", "u", .{id});
    m.deinit();
}

pub fn hasCapability(c: *bus.Conn, name: []const u8) !bool {
    var m = try c.call(service, path, service, "GetCapabilities", "", "", 25000);
    defer m.deinit();
    if (!std.mem.eql(u8, m.signature, "as")) return error.Invalid;
    var r = m.reader();
    const end = try r.array('s');
    while (r.pos < end) if (std.mem.eql(u8, try r.string(), name)) return true;
    return false;
}

pub const Outcome = extern struct {
    id: u32,
    reason: u32,
    action: [64]u8,
};

pub fn watch(c: *bus.Conn) !void {
    try c.addMatch("type='signal',interface='org.freedesktop.Notifications',path='/org/freedesktop/Notifications'");
}

pub fn wait(c: *bus.Conn, id: u32, timeout_ms: i64) !?Outcome {
    var out = std.mem.zeroes(Outcome);
    out.id = id;
    const deadline = bus.nowMs() + timeout_ms;
    while (true) {
        const left = deadline - bus.nowMs();
        var m = (try c.next(@max(left, 0))) orelse return null;
        defer m.deinit();
        if (m.kind != .signal or !std.mem.eql(u8, m.interface, service)) continue;
        var r = m.reader();
        if (std.mem.eql(u8, m.member, "ActionInvoked") and std.mem.eql(u8, m.signature, "us")) {
            if (try r.uint32() != id) continue;
            sys.copyName(&out.action, try r.string());
            return out;
        }
        if (std.mem.eql(u8, m.member, "NotificationClosed") and std.mem.eql(u8, m.signature, "uu")) {
            if (try r.uint32() != id) continue;
            out.reason = try r.uint32();
            return out;
        }
    }
}

const Fake = struct {
    conn: bus.Conn,
    stop: std.atomic.Value(bool) = .init(false),
    next_id: u32 = 41,
    summary: [64]u8 = [_]u8{0} ** 64,
    category: [32]u8 = [_]u8{0} ** 32,
    urgency: u8 = 255,
    transient: bool = false,
    actions: u32 = 0,
    timeout: i32 = 0,
    replaces: u32 = 0,

    fn handle(f: *Fake, m: *const bus.Message) !void {
        if (std.mem.eql(u8, m.member, "GetCapabilities")) {
            var w = bus.Writer{};
            defer w.deinit();
            const a = try w.beginArray('s');
            try w.string("body");
            try w.string("actions");
            try w.endArray(a);
            return f.conn.reply(m, "as", w.bytes());
        }
        if (std.mem.eql(u8, m.member, "Notify")) {
            if (!std.mem.eql(u8, m.signature, "susssasa{sv}i")) return f.conn.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "signature");
            var r = m.reader();
            _ = try r.string();
            f.replaces = try r.uint32();
            _ = try r.string();
            sys.copyName(&f.summary, try r.string());
            _ = try r.string();
            const ae = try r.array('s');
            while (r.pos < ae) : (f.actions += 1) _ = try r.string();
            const he = try r.array('{');
            while (r.pos < he) {
                try r.structure();
                const key = try r.string();
                const sig = try r.variant();
                if (std.mem.eql(u8, key, "urgency")) {
                    f.urgency = try r.byte();
                } else if (std.mem.eql(u8, key, "category")) {
                    sys.copyName(&f.category, try r.string());
                } else if (std.mem.eql(u8, key, "transient")) {
                    f.transient = try r.boolean();
                } else try r.skip(sig);
            }
            f.timeout = try r.int32();
            const id = if (f.replaces != 0) f.replaces else blk: {
                f.next_id += 1;
                break :blk f.next_id;
            };
            var w = bus.Writer{};
            defer w.deinit();
            try w.uint32(id);
            try f.conn.reply(m, "u", w.bytes());
            var s = bus.Writer{};
            defer s.deinit();
            try bus.pack(&s, "us", .{ id, "open" });
            return f.conn.emit(path, service, "ActionInvoked", "us", s.bytes());
        }
        if (std.mem.eql(u8, m.member, "CloseNotification")) {
            var r = m.reader();
            const id = try r.uint32();
            try f.conn.reply(m, "", "");
            var s = bus.Writer{};
            defer s.deinit();
            try bus.pack(&s, "uu", .{ id, @as(u32, 3) });
            return f.conn.emit(path, service, "NotificationClosed", "uu", s.bytes());
        }
        return f.conn.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", "no");
    }

    fn run(f: *Fake) void {
        while (!f.stop.load(.acquire)) {
            var m = (f.conn.next(50) catch return) orelse continue;
            defer m.deinit();
            if (m.kind == .call) f.handle(&m) catch {};
        }
    }
};

test "notifications reach a server and come back as signals" {
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
    try watch(&c);

    try std.testing.expect(try hasCapability(&c, "actions"));
    try std.testing.expect(!try hasCapability(&c, "persistence"));
    const id = try send(&c, .{
        .app_name = "Impostazioni",
        .summary = "Aggiornamento pronto",
        .body = "Riavvia per installarlo",
        .category = "system",
        .urgency = .critical,
        .transient = true,
        .timeout_ms = 5000,
        .actions = &.{ "open", "Apri", "later", "Più tardi" },
    });
    try std.testing.expectEqual(@as(u32, 42), id);
    try std.testing.expectEqualStrings("Aggiornamento pronto", sys.cstr(&fake.summary));
    try std.testing.expectEqualStrings("system", sys.cstr(&fake.category));
    try std.testing.expectEqual(@as(u8, 2), fake.urgency);
    try std.testing.expect(fake.transient);
    try std.testing.expectEqual(@as(u32, 4), fake.actions);
    try std.testing.expectEqual(@as(i32, 5000), fake.timeout);
    const acted = (try wait(&c, id, 5000)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("open", sys.cstr(&acted.action));

    try std.testing.expectEqual(id, try send(&c, .{ .summary = "Di nuovo", .replaces_id = id }));
    _ = try wait(&c, id, 5000);
    try close(&c, id);
    const closed = (try wait(&c, id, 5000)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), closed.reason);
    try std.testing.expectError(error.Invalid, send(&c, .{ .summary = "" }));
    try std.testing.expectError(error.Invalid, send(&c, .{ .summary = "x", .actions = &.{"odd"} }));
}
