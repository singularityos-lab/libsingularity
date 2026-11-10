const std = @import("std");
const sys = @import("../sys.zig");
const bus = @import("bus.zig");

pub const service = "org.freedesktop.Accounts";
const root_path = "/org/freedesktop/Accounts";
const if_user = "org.freedesktop.Accounts.User";
const hostname_service = "org.freedesktop.hostname1";
const hostname_path = "/org/freedesktop/hostname1";
const locale_service = "org.freedesktop.locale1";
const locale_path = "/org/freedesktop/locale1";

pub const User = extern struct {
    path: [96]u8,
    name: [64]u8,
    real_name: [256]u8,
    home: [256]u8,
    shell: [64]u8,
    icon: [256]u8,
    language: [64]u8,
    email: [128]u8,
    uid: u64,
    account_type: i32,
    locked: bool,
    automatic_login: bool,
    system_account: bool,
    pad: u8,
};

pub const Users = sys.List(User);

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn readUser(c: *bus.Conn, path: []const u8) !User {
    var m = try c.callWith(service, path, bus.iface_props, "GetAll", "s", .{if_user});
    defer m.deinit();
    if (!eql(m.signature, "a{sv}")) return error.Invalid;
    var u = std.mem.zeroes(User);
    sys.copyName(&u.path, path);
    var r = m.reader();
    const end = try r.array('{');
    while (r.pos < end) {
        try r.structure();
        const key = try r.string();
        const sig = try r.variant();
        const dst: ?[]u8 = if (eql(key, "UserName")) &u.name else if (eql(key, "RealName")) &u.real_name else if (eql(key, "HomeDirectory")) &u.home else if (eql(key, "Shell")) &u.shell else if (eql(key, "IconFile")) &u.icon else if (eql(key, "Language")) &u.language else if (eql(key, "Email")) &u.email else null;
        if (dst != null and eql(sig, "s")) {
            sys.copyName(dst.?, try r.string());
        } else if (eql(key, "Uid") and eql(sig, "t")) {
            u.uid = try r.uint64();
        } else if (eql(key, "AccountType") and eql(sig, "i")) {
            u.account_type = try r.int32();
        } else if (eql(key, "Locked") and eql(sig, "b")) {
            u.locked = try r.boolean();
        } else if (eql(key, "AutomaticLogin") and eql(sig, "b")) {
            u.automatic_login = try r.boolean();
        } else if (eql(key, "SystemAccount") and eql(sig, "b")) {
            u.system_account = try r.boolean();
        } else try r.skip(sig);
    }
    return u;
}

pub fn users(c: *bus.Conn) !*Users {
    var m = try c.call(service, root_path, service, "ListCachedUsers", "", "", 25000);
    defer m.deinit();
    if (!eql(m.signature, "ao")) return error.Invalid;
    const list = try Users.create();
    errdefer list.destroy();
    var r = m.reader();
    const end = try r.array('o');
    while (r.pos < end) try list.append(try readUser(c, try r.string()));
    std.mem.sort(User, list.items.items, {}, struct {
        fn less(_: void, a: User, b: User) bool {
            return a.uid < b.uid;
        }
    }.less);
    return list;
}

pub fn find(c: *bus.Conn, name: []const u8) !User {
    var m = try c.callWith(service, root_path, service, "FindUserByName", "s", .{name});
    defer m.deinit();
    var r = m.reader();
    return readUser(c, try r.string());
}

fn userPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, root_path ++ "/User") and bus.validPath(path);
}

pub const Field = enum { real_name, language, icon, email };

pub fn setText(c: *bus.Conn, path: []const u8, field: Field, value: []const u8) !void {
    if (!userPath(path)) return error.Invalid;
    const member = switch (field) {
        .real_name => "SetRealName",
        .language => "SetLanguage",
        .icon => "SetIconFile",
        .email => "SetEmail",
    };
    var m = try c.callWith(service, path, if_user, member, "s", .{value});
    m.deinit();
}

pub const Flag = enum { locked, automatic_login };

pub fn setFlag(c: *bus.Conn, path: []const u8, flag: Flag, on: bool) !void {
    if (!userPath(path)) return error.Invalid;
    var m = try c.callWith(service, path, if_user, if (flag == .locked) "SetLocked" else "SetAutomaticLogin", "b", .{on});
    m.deinit();
}

pub fn setAccountType(c: *bus.Conn, path: []const u8, administrator: bool) !void {
    if (!userPath(path)) return error.Invalid;
    var m = try c.callWith(service, path, if_user, "SetAccountType", "i", .{@as(i32, @intFromBool(administrator))});
    m.deinit();
}

pub fn create(c: *bus.Conn, name: []const u8, real_name: []const u8, administrator: bool, out: []u8) ![]const u8 {
    var m = try c.callWith(service, root_path, service, "CreateUser", "ssi", .{ name, real_name, @as(i32, @intFromBool(administrator)) });
    defer m.deinit();
    var r = m.reader();
    sys.copyName(out, try r.string());
    return sys.cstr(out);
}

pub fn delete(c: *bus.Conn, uid: u64, remove_files: bool) !void {
    var m = try c.callWith(service, root_path, service, "DeleteUser", "xb", .{ @as(i64, @intCast(uid)), remove_files });
    m.deinit();
}

fn stringProp(c: *bus.Conn, dest: []const u8, path: []const u8, iface: []const u8, name: []const u8, out: []u8) ![]const u8 {
    var m = try c.getProperty(dest, path, iface, name);
    defer m.deinit();
    var r = m.reader();
    if (!eql(try r.variant(), "s")) return error.Invalid;
    sys.copyName(out, try r.string());
    return sys.cstr(out);
}

pub const Names = extern struct {
    static_name: [64]u8,
    pretty: [256]u8,
};

pub fn hostname(c: *bus.Conn) !Names {
    var n = std.mem.zeroes(Names);
    _ = try stringProp(c, hostname_service, hostname_path, hostname_service, "StaticHostname", &n.static_name);
    _ = try stringProp(c, hostname_service, hostname_path, hostname_service, "PrettyHostname", &n.pretty);
    return n;
}

fn validHostname(name: []const u8) bool {
    if (name.len == 0 or name.len > 63 or name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    return true;
}

pub fn setHostname(c: *bus.Conn, static: []const u8, pretty: []const u8) !void {
    if (!validHostname(static)) return error.Invalid;
    var m = try c.callWith(hostname_service, hostname_path, hostname_service, "SetStaticHostname", "sb", .{ static, true });
    m.deinit();
    var p = try c.callWith(hostname_service, hostname_path, hostname_service, "SetPrettyHostname", "sb", .{ pretty, true });
    p.deinit();
}

pub fn language(c: *bus.Conn, out: []u8) ![]const u8 {
    var m = try c.getProperty(locale_service, locale_path, locale_service, "Locale");
    defer m.deinit();
    var r = m.reader();
    if (!eql(try r.variant(), "as")) return error.Invalid;
    const end = try r.array('s');
    out[0] = 0;
    while (r.pos < end) {
        const s = try r.string();
        if (std.mem.startsWith(u8, s, "LANG=")) sys.copyName(out, s[5..]);
    }
    return sys.cstr(out);
}

fn validLocale(lang: []const u8) bool {
    if (lang.len == 0 or lang.len > 48) return false;
    for (lang) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '@' and ch != '-') return false;
    return true;
}

pub fn setLanguage(c: *bus.Conn, lang: []const u8) !void {
    if (!validLocale(lang)) return error.Invalid;
    var buf: [64]u8 = undefined;
    const entry = std.fmt.bufPrint(&buf, "LANG={s}", .{lang}) catch return error.Invalid;
    var w = bus.Writer{};
    defer w.deinit();
    const a = try w.beginArray('s');
    try w.string(entry);
    try w.endArray(a);
    try w.boolean(true);
    var m = try c.call(locale_service, locale_path, locale_service, "SetLocale", "asb", w.bytes(), 25000);
    m.deinit();
}

const Fake = struct {
    conn: bus.Conn,
    stop: std.atomic.Value(bool) = .init(false),
    static: [64]u8 = [_]u8{0} ** 64,
    pretty: [64]u8 = [_]u8{0} ** 64,
    lang: [64]u8 = [_]u8{0} ** 64,
    interactive: bool = false,

    fn handle(f: *Fake, m: *const bus.Message) !void {
        var w = bus.Writer{};
        defer w.deinit();
        var r = m.reader();
        if (eql(m.member, "Get")) {
            _ = try r.string();
            const name = try r.string();
            if (eql(name, "Locale")) {
                try w.variant("as");
                const a = try w.beginArray('s');
                try w.string("LC_TIME=en_GB.UTF-8");
                var b: [80]u8 = undefined;
                try w.string(try std.fmt.bufPrint(&b, "LANG={s}", .{sys.cstr(&f.lang)}));
                try w.endArray(a);
            } else {
                try w.variant("s");
                try w.string(if (eql(name, "StaticHostname")) sys.cstr(&f.static) else sys.cstr(&f.pretty));
            }
            return f.conn.reply(m, "v", w.bytes());
        }
        if (eql(m.member, "SetStaticHostname")) sys.copyName(&f.static, try r.string());
        if (eql(m.member, "SetPrettyHostname")) sys.copyName(&f.pretty, try r.string());
        if (eql(m.member, "SetLocale")) {
            f.interactive = m.flags & 4 != 0;
            const end = try r.array('s');
            while (r.pos < end) {
                const s = try r.string();
                if (std.mem.startsWith(u8, s, "LANG=")) sys.copyName(&f.lang, s[5..]);
            }
        }
        return f.conn.reply(m, "", "");
    }

    fn run(f: *Fake) void {
        while (!f.stop.load(.acquire)) {
            var m = (f.conn.next(50) catch return) orelse continue;
            defer m.deinit();
            if (m.kind == .call) f.handle(&m) catch {};
        }
    }
};

test "host name and language through hostname1 and locale1" {
    const addr = std.c.getenv("SINTY_BUS_ADDRESS") orelse return error.SkipZigTest;
    var fake = Fake{ .conn = try bus.Conn.open(std.mem.span(addr)) };
    defer fake.conn.close();
    try fake.conn.requestName(hostname_service);
    try fake.conn.requestName(locale_service);
    sys.copyName(&fake.lang, "it_IT.UTF-8");
    const t = try std.Thread.spawn(.{}, Fake.run, .{&fake});
    defer {
        fake.stop.store(true, .release);
        t.join();
    }
    var c = try bus.Conn.open(std.mem.span(addr));
    defer c.close();
    c.interactive = true;

    try setHostname(&c, "laptop-mirko", "Laptop di Mirko");
    const n = try hostname(&c);
    try std.testing.expectEqualStrings("laptop-mirko", sys.cstr(&n.static_name));
    try std.testing.expectEqualStrings("Laptop di Mirko", sys.cstr(&n.pretty));
    try std.testing.expectError(error.Invalid, setHostname(&c, "-bad", ""));
    try std.testing.expectError(error.Invalid, setHostname(&c, "has space", ""));

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("it_IT.UTF-8", try language(&c, &buf));
    try setLanguage(&c, "de_DE.UTF-8");
    try std.testing.expect(fake.interactive);
    try std.testing.expectEqualStrings("de_DE.UTF-8", try language(&c, &buf));
    try std.testing.expectError(error.Invalid, setLanguage(&c, "de;rm -rf"));
}

test "users from a real accounts daemon" {
    const addr = std.c.getenv("SINTY_ACCOUNTS_ADDRESS") orelse return error.SkipZigTest;
    var c = try bus.Conn.open(std.mem.span(addr));
    defer c.close();
    const list = try users(&c);
    defer list.destroy();
    try std.testing.expectEqual(@as(usize, 2), list.count());
    const a = list.at(0).?;
    try std.testing.expectEqualStrings("alice", sys.cstr(&a.name));
    try std.testing.expectEqualStrings("Alice Rossi", sys.cstr(&a.real_name));
    try std.testing.expectEqual(@as(u64, std.os.linux.getuid()), a.uid);
    try std.testing.expectEqual(@as(i32, 1), a.account_type);
    const b = list.at(1).?;
    try std.testing.expectEqualStrings("bruno", sys.cstr(&b.name));
    try std.testing.expectEqual(@as(i32, 0), b.account_type);

    try setText(&c, sys.cstr(&a.path), .language, "it_IT.UTF-8");
    const again = try find(&c, "alice");
    try std.testing.expectEqualStrings("it_IT.UTF-8", sys.cstr(&again.language));
    try std.testing.expectError(error.NotFound, find(&c, "nobody"));
    try std.testing.expectError(error.Invalid, setText(&c, "/org/freedesktop/DBus", .language, "x"));
}
