const std = @import("std");
const sys = @import("../sys.zig");
const gv = @import("gvariant.zig");
const gvdb = @import("gvdb.zig");
const bus = @import("bus.zig");

pub const writer_service = "ca.desrt.dconf";
const writer_iface = "ca.desrt.dconf.Writer";

const Db = struct {
    data: []u8,
    table: gvdb.Table,
    system: bool,
};

pub const Options = struct {
    schema_dirs: []const []const u8,
    profile: []const u8,
    config_dir: []const u8,
    system_dir: []const u8 = "/etc/dconf/db",
};

pub const Key = struct {
    full_buf: [512]u8 = undefined,
    full_len: usize = 0,
    sig: []const u8,
    default: gv.Value,
    range: ?[2]i64 = null,

    pub fn full(k: *const Key) []const u8 {
        return k.full_buf[0..k.full_len];
    }
};

pub const Change = struct {
    key: []const u8,
    sig: []const u8 = "",
    value: ?[]const u8,
};

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.mem.span(std.c.getenv(name) orelse return null);
    return if (v.len > 0) v else null;
}

pub const Store = struct {
    files: std.ArrayList([]u8) = .empty,
    schemas: std.ArrayList(gvdb.Table) = .empty,
    dbs: std.ArrayList(Db) = .empty,
    user_db: [64]u8 = [_]u8{0} ** 64,

    pub fn load() !Store {
        var dirs: std.ArrayList([]const u8) = .empty;
        defer {
            for (dirs.items) |d| sys.gpa.free(d);
            dirs.deinit(sys.gpa);
        }
        if (env("GSETTINGS_SCHEMA_DIR")) |list| {
            var it = std.mem.splitScalar(u8, list, ':');
            while (it.next()) |d| if (d.len > 0) try dirs.append(sys.gpa, try sys.gpa.dupe(u8, d));
        }
        const home = env("HOME") orelse "/";
        if (env("XDG_DATA_HOME")) |d| {
            try dirs.append(sys.gpa, try std.fmt.allocPrint(sys.gpa, "{s}/glib-2.0/schemas", .{d}));
        } else try dirs.append(sys.gpa, try std.fmt.allocPrint(sys.gpa, "{s}/.local/share/glib-2.0/schemas", .{home}));
        var it = std.mem.splitScalar(u8, env("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share", ':');
        while (it.next()) |d| if (d.len > 0) try dirs.append(sys.gpa, try std.fmt.allocPrint(sys.gpa, "{s}/glib-2.0/schemas", .{d}));

        var cbuf: [512]u8 = undefined;
        const config = if (env("XDG_CONFIG_HOME")) |c| c else std.fmt.bufPrint(&cbuf, "{s}/.config", .{home}) catch return error.TooBig;
        var profile: ?[]u8 = null;
        defer if (profile) |p| sys.gpa.free(p);
        var pbuf: [512]u8 = undefined;
        if (env("DCONF_PROFILE")) |name| {
            const p = if (name[0] == '/') sys.pathZ(&pbuf, "{s}", .{name}) else sys.pathZ(&pbuf, "/etc/dconf/profile/{s}", .{name});
            profile = sys.readAlloc(sys.gpa, try p, 1 << 20) catch null;
        } else {
            profile = sys.readAlloc(sys.gpa, "/etc/dconf/profile/user", 1 << 20) catch null;
        }
        return open(.{ .schema_dirs = dirs.items, .profile = profile orelse "user-db:user", .config_dir = config });
    }

    pub fn open(o: Options) !Store {
        var s = Store{};
        errdefer s.deinit();
        for (o.schema_dirs) |d| {
            var buf: [512]u8 = undefined;
            const path = sys.pathZ(&buf, "{s}/gschemas.compiled", .{d}) catch continue;
            const data = sys.readAlloc(sys.gpa, path, 64 << 20) catch continue;
            const t = gvdb.Table.root(data) catch {
                sys.gpa.free(data);
                continue;
            };
            try s.files.append(sys.gpa, data);
            try s.schemas.append(sys.gpa, t);
        }
        var first = true;
        var lines = std.mem.splitScalar(u8, o.profile, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const kind = line[0..colon];
            const name = line[colon + 1 ..];
            if (name.len == 0 or name.len > 63) continue;
            var buf: [512]u8 = undefined;
            if (std.mem.eql(u8, kind, "user-db")) {
                if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
                if (first) sys.copyName(&s.user_db, name);
                try s.addDb(sys.pathZ(&buf, "{s}/dconf/{s}", .{ o.config_dir, name }) catch continue, false);
            } else if (std.mem.eql(u8, kind, "system-db")) {
                if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
                try s.addDb(sys.pathZ(&buf, "{s}/{s}", .{ o.system_dir, name }) catch continue, true);
            } else if (std.mem.eql(u8, kind, "file-db")) {
                try s.addDb(sys.pathZ(&buf, "{s}", .{name}) catch continue, true);
            }
            first = false;
        }
        return s;
    }

    fn addDb(s: *Store, path: [*:0]const u8, system: bool) !void {
        const data = sys.readAlloc(sys.gpa, path, 64 << 20) catch return;
        const t = gvdb.Table.root(data) catch {
            sys.gpa.free(data);
            return;
        };
        try s.files.append(sys.gpa, data);
        try s.dbs.append(sys.gpa, .{ .data = data, .table = t, .system = system });
    }

    pub fn deinit(s: *Store) void {
        for (s.files.items) |f| sys.gpa.free(f);
        s.files.deinit(sys.gpa);
        s.schemas.deinit(sys.gpa);
        s.dbs.deinit(sys.gpa);
    }

    pub fn key(s: *const Store, id: []const u8, path: ?[]const u8, name: []const u8) !Key {
        if (name.len == 0 or name[0] == '.' or std.mem.indexOfScalar(u8, name, '/') != null) return error.Invalid;
        const schema = for (s.schemas.items) |t| {
            if (try t.table(id)) |found| break found;
        } else return error.NotFound;
        const info = (try schema.value(name)) orelse return error.NotFound;
        if (info.sig.len == 0 or info.sig[0] != '(') return error.Invalid;
        const fixed: ?[]const u8 = if (try schema.value(".path")) |p| try p.string() else null;
        const base = path orelse fixed orelse return error.Invalid;
        if (fixed) |f| if (!std.mem.eql(u8, f, base)) return error.Invalid;
        if (base.len < 1 or base[0] != '/' or base[base.len - 1] != '/' or std.mem.indexOf(u8, base, "//") != null) return error.Invalid;
        var k = Key{ .sig = undefined, .default = try info.child(0) };
        k.sig = k.default.sig;
        const full = std.fmt.bufPrint(&k.full_buf, "{s}{s}", .{ base, name }) catch return error.TooBig;
        k.full_len = full.len;
        var i: usize = 1;
        while (info.child(i)) |opt| : (i += 1) {
            const tag = (opt.child(0) catch continue).data;
            if (tag.len != 1 or tag[0] != 'r') continue;
            const pair = opt.child(1) catch continue;
            k.range = .{ (pair.child(0) catch continue).int() catch continue, (pair.child(1) catch continue).int() catch continue };
        } else |_| {}
        return k;
    }

    fn start(s: *const Store, k: *const Key) !usize {
        var from: usize = 0;
        for (s.dbs.items, 0..) |db, i| {
            if (!db.system) continue;
            const locks = (try db.table.table(".locks")) orelse continue;
            if (try locks.has(k.full())) from = i;
        }
        return from;
    }

    pub fn get(s: *const Store, k: *const Key) !gv.Value {
        for (s.dbs.items[try s.start(k)..]) |db| {
            const v = (try db.table.value(k.full())) orelse continue;
            if (std.mem.eql(u8, v.sig, k.sig)) return v;
        }
        return k.default;
    }

    pub fn writable(s: *const Store, k: *const Key) !bool {
        if (s.user_db[0] == 0) return false;
        for (s.dbs.items) |db| {
            if (!db.system) continue;
            const locks = (try db.table.table(".locks")) orelse continue;
            if (try locks.has(k.full())) return false;
        }
        return true;
    }

    pub fn validate(s: *const Store, k: *const Key, value: ?[]const u8) !void {
        if (value) |v| {
            const parsed = gv.Value{ .sig = k.sig, .data = v };
            if (k.range) |r| {
                const n = parsed.int() catch return error.Invalid;
                if (n < r[0] or n > r[1]) return error.Invalid;
            }
        }
        if (!try s.writable(k)) return error.Access;
    }

    pub fn set(s: *const Store, c: *bus.Conn, k: *const Key, value: ?[]const u8) !void {
        try s.validate(k, value);
        try write(c, sys.cstr(&s.user_db), &.{.{ .key = k.full(), .sig = k.sig, .value = value }});
    }
};

pub fn changeset(entries: []const Change) ![]u8 {
    var parts: std.ArrayList([]u8) = .empty;
    defer {
        for (parts.items) |p| sys.gpa.free(p);
        parts.deinit(sys.gpa);
    }
    for (entries) |e| {
        if (e.key.len == 0 or e.key[0] != '/') return error.Invalid;
        const k = try gv.string(e.key);
        defer sys.gpa.free(k);
        var inner: ?[]u8 = null;
        defer if (inner) |b| sys.gpa.free(b);
        if (e.value) |v| inner = try gv.variant(e.sig, v);
        const mv = try gv.maybe("v", inner);
        defer sys.gpa.free(mv);
        try parts.append(sys.gpa, try gv.tuple("{smv}", &.{ k, mv }));
    }
    var views: std.ArrayList([]const u8) = .empty;
    defer views.deinit(sys.gpa);
    for (parts.items) |p| try views.append(sys.gpa, p);
    return gv.array("{smv}", views.items);
}

pub fn write(c: *bus.Conn, db: []const u8, entries: []const Change) !void {
    if (db.len == 0) return error.Access;
    const data = try changeset(entries);
    defer sys.gpa.free(data);
    var w = bus.Writer{};
    defer w.deinit();
    const a = try w.beginArray('y');
    for (data) |b| try w.byte(b);
    try w.endArray(a);
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/ca/desrt/dconf/Writer/{s}", .{db}) catch return error.TooBig;
    var m = try c.call(writer_service, p, writer_iface, "Change", "ay", w.bytes(), 25000);
    m.deinit();
}

pub fn encodeInt(sig: []const u8, v: i64) ![]u8 {
    if (sig.len != 1) return error.Invalid;
    return switch (sig[0]) {
        'y' => gv.integer(u8, std.math.cast(u8, v) orelse return error.Invalid),
        'n' => gv.integer(i16, std.math.cast(i16, v) orelse return error.Invalid),
        'q' => gv.integer(u16, std.math.cast(u16, v) orelse return error.Invalid),
        'i', 'h' => gv.integer(i32, std.math.cast(i32, v) orelse return error.Invalid),
        'u' => gv.integer(u32, std.math.cast(u32, v) orelse return error.Invalid),
        'x' => gv.integer(i64, v),
        't' => gv.integer(u64, std.math.cast(u64, v) orelse return error.Invalid),
        else => error.Invalid,
    };
}

pub fn encodeStrv(items: []const []const u8) ![]u8 {
    var parts: std.ArrayList([]u8) = .empty;
    defer {
        for (parts.items) |p| sys.gpa.free(p);
        parts.deinit(sys.gpa);
    }
    for (items) |it| try parts.append(sys.gpa, try gv.string(it));
    var views: std.ArrayList([]const u8) = .empty;
    defer views.deinit(sys.gpa);
    for (parts.items) |p| try views.append(sys.gpa, p);
    return gv.array("s", views.items);
}

fn testDb(entries: []const struct { []const u8, []const u8, []const u8 }, locks: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(sys.gpa);
    const n_root = entries.len + @intFromBool(locks.len > 0);
    const root_size = 12 + 24 * n_root;
    const locks_at = 24 + root_size;
    const locks_size = if (locks.len > 0) 12 + 24 * locks.len else 0;
    try out.appendNTimes(sys.gpa, 0, locks_at + locks_size);
    @memcpy(out.items[0..8], "GVariant");
    std.mem.writeInt(u32, out.items[16..20], 24, .little);
    std.mem.writeInt(u32, out.items[20..24], @intCast(24 + root_size), .little);
    std.mem.writeInt(u32, out.items[28..32], 1, .little);
    const Fill = struct {
        fn item(o: *std.ArrayList(u8), at: usize, k: []const u8, ty: u8, vs: usize, ve: usize) !void {
            const ks = o.items.len;
            try o.appendSlice(sys.gpa, k);
            const it = o.items[at .. at + 24];
            std.mem.writeInt(u32, it[4..8], 0xffffffff, .little);
            std.mem.writeInt(u32, it[8..12], @intCast(ks), .little);
            std.mem.writeInt(u16, it[12..14], @intCast(k.len), .little);
            it[14] = ty;
            std.mem.writeInt(u32, it[16..20], @intCast(vs), .little);
            std.mem.writeInt(u32, it[20..24], @intCast(ve), .little);
        }
        fn value(o: *std.ArrayList(u8), sig: []const u8, data: []const u8) ![2]usize {
            while (o.items.len % 8 != 0) try o.append(sys.gpa, 0);
            const vs = o.items.len;
            const v = try gv.variant(sig, data);
            defer sys.gpa.free(v);
            try o.appendSlice(sys.gpa, v);
            return .{ vs, o.items.len };
        }
    };
    for (entries, 0..) |e, i| {
        const r = try Fill.value(&out, e[1], e[2]);
        try Fill.item(&out, 24 + 12 + 24 * i, e[0], 'v', r[0], r[1]);
    }
    if (locks.len > 0) {
        std.mem.writeInt(u32, out.items[locks_at + 4 ..][0..4], 1, .little);
        try Fill.item(&out, 24 + 12 + 24 * entries.len, ".locks", 'H', locks_at, locks_at + locks_size);
        for (locks, 0..) |l, i| {
            const r = try Fill.value(&out, "b", &.{1});
            try Fill.item(&out, locks_at + 12 + 24 * i, l, 'v', r[0], r[1]);
        }
    }
    return out.toOwnedSlice(sys.gpa);
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const linux = std.os.linux;
    const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    defer sys.close(fd);
    try sys.writeAll(fd, data);
    _ = linux.fsync(fd);
}

const Fake = struct {
    conn: bus.Conn,
    stop: std.atomic.Value(bool) = .init(false),
    keys: [8][96]u8 = undefined,
    nothing: [8]bool = undefined,
    count: usize = 0,
    path: [96]u8 = [_]u8{0} ** 96,

    fn handle(f: *Fake, m: *const bus.Message) !void {
        if (!std.mem.eql(u8, m.member, "Change") or !std.mem.eql(u8, m.signature, "ay")) return f.conn.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", "no");
        sys.copyName(&f.path, m.path);
        var r = m.reader();
        const end = try r.array('y');
        const cs = gv.Value{ .sig = "a{smv}", .data = r.data[r.pos..end] };
        f.count = 0;
        for (0..try cs.len()) |i| {
            const e = try cs.at(i);
            sys.copyName(&f.keys[i], try (try e.child(0)).string());
            f.nothing[i] = (try (try e.child(1)).maybe()) == null;
            f.count += 1;
        }
        var w = bus.Writer{};
        defer w.deinit();
        try w.string("tag-1");
        return f.conn.reply(m, "s", w.bytes());
    }

    fn run(f: *Fake) void {
        while (!f.stop.load(.acquire)) {
            var m = (f.conn.next(50) catch return) orelse continue;
            defer m.deinit();
            if (m.kind == .call) f.handle(&m) catch {};
        }
    }
};

test "settings resolve through dconf databases and schema defaults" {
    const fixture = std.c.getenv("SINTY_GVDB_FIXTURE") orelse return error.SkipZigTest;
    const schema_dir = sys.baseName(std.mem.span(fixture));
    const dir = std.mem.span(fixture)[0 .. std.mem.span(fixture).len - schema_dir.len - 1];
    const tmp = std.mem.span(std.c.getenv("TMPDIR") orelse return error.SkipZigTest);
    var b1: [512]u8 = undefined;
    const conf = try std.fmt.bufPrint(&b1, "{s}/dconf-test", .{tmp});
    var b2: [512]u8 = undefined;
    _ = std.os.linux.mkdir(try sys.pathZ(&b2, "{s}", .{conf}), 0o700);
    _ = std.os.linux.mkdir(try sys.pathZ(&b2, "{s}/dconf", .{conf}), 0o700);

    const f = try gv.boolean(false);
    defer sys.gpa.free(f);
    const five = try gv.integer(i32, 5);
    defer sys.gpa.free(five);
    const nine = try gv.integer(i32, 9);
    defer sys.gpa.free(nine);
    const wrong = try gv.string("wrong type");
    defer sys.gpa.free(wrong);
    const sito = try gv.string("Sito");
    defer sys.gpa.free(sito);
    const user = try testDb(&.{ .{ "/dev/sinty/test/enabled", "b", f }, .{ "/dev/sinty/test/count", "i", five }, .{ "/dev/sinty/test/ratio", "s", wrong } }, &.{});
    defer sys.gpa.free(user);
    try writeFile(try sys.pathZ(&b2, "{s}/dconf/user", .{conf}), user);
    const site = try testDb(&.{ .{ "/dev/sinty/test/title", "s", sito }, .{ "/dev/sinty/test/count", "i", nine } }, &.{"/dev/sinty/test/count"});
    defer sys.gpa.free(site);
    try writeFile(try sys.pathZ(&b2, "{s}/site", .{conf}), site);

    var store = try Store.open(.{ .schema_dirs = &.{dir}, .profile = "# test\nuser-db:user\nsystem-db:site\nsystem-db:missing\n", .config_dir = conf, .system_dir = conf });
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 2), store.dbs.items.len);

    const enabled = try store.key("dev.sinty.Test", null, "enabled");
    try std.testing.expect(!try (try store.get(&enabled)).boolean());
    const count = try store.key("dev.sinty.Test", null, "count");
    try std.testing.expectEqual(@as(i64, 9), try (try store.get(&count)).int());
    try std.testing.expectEqual([2]i64{ -100, 100 }, count.range.?);
    try std.testing.expect(!try store.writable(&count));
    const title = try store.key("dev.sinty.Test", null, "title");
    try std.testing.expectEqualStrings("Sito", try (try store.get(&title)).string());
    try std.testing.expect(try store.writable(&title));
    const ratio = try store.key("dev.sinty.Test", null, "ratio");
    try std.testing.expectEqual(@as(f64, 0.75), try (try store.get(&ratio)).double());
    const big = try store.key("dev.sinty.Test", null, "big");
    try std.testing.expectEqual(@as(i64, 9000000000), try (try store.get(&big)).int());
    const mode = try store.key("dev.sinty.Test", null, "mode");
    try std.testing.expectEqualStrings("dark", try (try store.get(&mode)).string());
    const apps = try store.key("dev.sinty.Test", null, "apps");
    const list = try store.get(&apps);
    try std.testing.expectEqual(@as(usize, 3), try list.len());
    try std.testing.expectEqualStrings("terminal", try (try list.at(2)).string());
    const size = try store.key("dev.sinty.Test.Child", "/dev/sinty/child/", "size");
    try std.testing.expectEqualStrings("/dev/sinty/child/size", size.full());
    try std.testing.expectError(error.Invalid, store.key("dev.sinty.Test.Child", null, "size"));
    try std.testing.expectError(error.Invalid, store.key("dev.sinty.Test", "/other/", "enabled"));
    try std.testing.expectError(error.NotFound, store.key("dev.sinty.Test", null, "nope"));
    try std.testing.expectError(error.Invalid, store.key("dev.sinty.Test", null, ".path"));

    const changes = try store.key("dev.sinty.Test", null, "changes");
    const strv = try encodeStrv(&.{ "a", "bc" });
    defer sys.gpa.free(strv);
    const ours = try changeset(&.{
        .{ .key = "/dev/sinty/test/enabled", .sig = "b", .value = f },
        .{ .key = "/dev/sinty/test/title", .value = null },
        .{ .key = "/dev/sinty/test/apps", .sig = "as", .value = strv },
    });
    defer sys.gpa.free(ours);
    try std.testing.expectEqualSlices(u8, changes.default.data, ours);

    const addr = std.c.getenv("SINTY_BUS_ADDRESS") orelse return;
    var fake = Fake{ .conn = try bus.Conn.open(std.mem.span(addr)) };
    defer fake.conn.close();
    try fake.conn.requestName(writer_service);
    const t = try std.Thread.spawn(.{}, Fake.run, .{&fake});
    defer {
        fake.stop.store(true, .release);
        t.join();
    }
    var c = try bus.Conn.open(std.mem.span(addr));
    defer c.close();
    const hello = try gv.string("Ciao a tutti");
    defer sys.gpa.free(hello);
    try store.set(&c, &title, hello);
    try std.testing.expectEqualStrings("/ca/desrt/dconf/Writer/user", sys.cstr(&fake.path));
    try std.testing.expectEqual(@as(usize, 1), fake.count);
    try std.testing.expectEqualStrings("/dev/sinty/test/title", sys.cstr(&fake.keys[0]));
    try std.testing.expect(!fake.nothing[0]);
    try store.set(&c, &title, null);
    try std.testing.expect(fake.nothing[0]);
    try std.testing.expectError(error.Access, store.set(&c, &count, five));
    const too_big = try gv.integer(i32, 500);
    defer sys.gpa.free(too_big);
    var no_locks = try Store.open(.{ .schema_dirs = &.{dir}, .profile = "user-db:user", .config_dir = conf });
    defer no_locks.deinit();
    const free_count = try no_locks.key("dev.sinty.Test", null, "count");
    try std.testing.expectError(error.Invalid, no_locks.set(&c, &free_count, too_big));
    try no_locks.set(&c, &free_count, five);
}
