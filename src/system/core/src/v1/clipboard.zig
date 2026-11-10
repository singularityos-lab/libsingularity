const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const wl = @import("wayland.zig");
const i18n = @import("i18n.zig");

const max_data = 64 << 20;
const timeout_ms = 5000;

const Offer = struct {
    id: u32,
    mimes: std.ArrayList([]u8) = .empty,

    fn deinit(o: *Offer) void {
        for (o.mimes.items) |m| sys.gpa.free(m);
        o.mimes.deinit(sys.gpa);
    }

    fn has(o: *const Offer, mime: []const u8) bool {
        for (o.mimes.items) |m| if (std.mem.eql(u8, m, mime)) return true;
        return false;
    }
};

pub const Session = struct {
    conn: wl.Conn,
    manager: u32 = 0,
    seat: u32 = 0,
    device: u32 = 0,
    primary_supported: bool = false,
    offers: std.ArrayList(Offer) = .empty,
    selection: u32 = 0,
    primary: u32 = 0,
    finished: bool = false,

    pub fn open() !Session {
        return start(try wl.Conn.connect());
    }

    pub fn openPath(path: []const u8) !Session {
        return start(try wl.Conn.open(path));
    }

    fn start(conn: wl.Conn) !Session {
        var s = Session{ .conn = conn };
        errdefer s.close();
        try s.setup();
        return s;
    }

    fn setup(s: *Session) !void {
        const registry = s.conn.newId();
        var a = wl.Args{};
        defer a.deinit();
        try a.uint(registry);
        try s.conn.send(wl.display_id, 1, a.bytes(), null);
        const cb = try s.conn.sync();
        var seat_name: u32 = 0;
        var mgr_name: u32 = 0;
        var mgr_iface: []const u8 = "";
        var mgr_version: u32 = 0;
        var ext = false;
        while (true) {
            var ev = (try s.conn.next(timeout_ms)) orelse return error.Io;
            defer ev.deinit();
            if (ev.obj == cb) break;
            if (ev.obj != registry or ev.op != 0) continue;
            var r = ev.reader();
            const name = try r.uint();
            const iface = (try r.string()) orelse continue;
            const version = try r.uint();
            if (std.mem.eql(u8, iface, "wl_seat") and seat_name == 0) seat_name = name;
            if (std.mem.eql(u8, iface, "ext_data_control_manager_v1")) {
                mgr_name = name;
                mgr_iface = "ext_data_control_manager_v1";
                mgr_version = 1;
                ext = true;
            }
            if (!ext and std.mem.eql(u8, iface, "zwlr_data_control_manager_v1")) {
                mgr_name = name;
                mgr_iface = "zwlr_data_control_manager_v1";
                mgr_version = @min(version, 2);
            }
        }
        if (mgr_name == 0) return error.Unsupported;
        if (seat_name == 0) return error.NotFound;
        s.primary_supported = ext or mgr_version >= 2;
        s.seat = try s.bind(registry, seat_name, "wl_seat", 1);
        s.manager = try s.bind(registry, mgr_name, mgr_iface, mgr_version);
        s.device = s.conn.newId();
        var d = wl.Args{};
        defer d.deinit();
        try d.uint(s.device);
        try d.uint(s.seat);
        try s.conn.send(s.manager, 1, d.bytes(), null);
        try s.roundtrip();
    }

    fn bind(s: *Session, registry: u32, name: u32, iface: []const u8, version: u32) !u32 {
        const id = s.conn.newId();
        var a = wl.Args{};
        defer a.deinit();
        try a.uint(name);
        try a.string(iface);
        try a.uint(version);
        try a.uint(id);
        try s.conn.send(registry, 0, a.bytes(), null);
        return id;
    }

    pub fn close(s: *Session) void {
        for (s.offers.items) |*o| o.deinit();
        s.offers.deinit(sys.gpa);
        s.conn.close();
    }

    pub fn roundtrip(s: *Session) !void {
        const cb = try s.conn.sync();
        while (true) {
            var ev = (try s.conn.next(timeout_ms)) orelse return error.Io;
            defer ev.deinit();
            if (ev.obj == cb) return;
            try s.handle(&ev);
        }
    }

    fn findOffer(s: *Session, id: u32) ?*Offer {
        for (s.offers.items) |*o| if (o.id == id) return o;
        return null;
    }

    fn drop(s: *Session, id: u32) void {
        if (id == 0 or id == s.selection or id == s.primary) return;
        for (s.offers.items, 0..) |*o, i| if (o.id == id) {
            o.deinit();
            _ = s.offers.swapRemove(i);
            s.conn.send(id, 1, "", null) catch {};
            return;
        };
    }

    pub fn handle(s: *Session, ev: *const wl.Event) !void {
        var r = ev.reader();
        if (ev.obj == s.device) {
            switch (ev.op) {
                0 => try s.offers.append(sys.gpa, .{ .id = try r.uint() }),
                1 => {
                    const old = s.selection;
                    s.selection = try r.uint();
                    s.drop(old);
                },
                2 => s.finished = true,
                3 => {
                    const old = s.primary;
                    s.primary = try r.uint();
                    s.drop(old);
                },
                else => {},
            }
            return;
        }
        if (ev.op != 0) return;
        const o = s.findOffer(ev.obj) orelse return;
        const mime = (try r.string()) orelse return;
        try o.mimes.append(sys.gpa, try sys.gpa.dupe(u8, mime));
    }

    fn current(s: *Session, primary: bool) !*Offer {
        if (primary and !s.primary_supported) return error.Unsupported;
        const id = if (primary) s.primary else s.selection;
        if (id == 0) return error.NotFound;
        return s.findOffer(id) orelse error.NotFound;
    }

    pub fn types(s: *Session, primary: bool) !*i18n.TextList {
        const o = try s.current(primary);
        const list = try i18n.TextList.create();
        errdefer list.destroy();
        for (o.mimes.items) |m| {
            const copy = try sys.dupZ(sys.gpa, m);
            errdefer sys.gpa.free(std.mem.span(copy));
            try list.append(.{ .ptr = copy });
        }
        return list;
    }

    pub fn read(s: *Session, primary: bool, mime: []const u8) ![]u8 {
        const o = try s.current(primary);
        if (!o.has(mime)) return error.NotFound;
        var p: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&p, .{ .CLOEXEC = true }));
        defer sys.close(p[0]);
        var a = wl.Args{};
        defer a.deinit();
        a.string(mime) catch |e| {
            sys.close(p[1]);
            return e;
        };
        s.conn.send(o.id, 0, a.bytes(), p[1]) catch |e| {
            sys.close(p[1]);
            return e;
        };
        sys.close(p[1]);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(sys.gpa);
        var buf: [16384]u8 = undefined;
        var fds = [_]linux.pollfd{.{ .fd = p[0], .events = linux.POLL.IN, .revents = 0 }};
        while (true) {
            const rc = linux.poll(&fds, 1, timeout_ms);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return sys.fromErrno(e);
            if (rc == 0) return error.Again;
            const n = try sys.read(p[0], &buf);
            if (n == 0) break;
            try out.appendSlice(sys.gpa, buf[0..n]);
            if (out.items.len > max_data) return error.TooBig;
        }
        return out.toOwnedSlice(sys.gpa);
    }
};

pub fn defaultMime(text: bool) []const u8 {
    return if (text) "text/plain;charset=utf-8" else "application/octet-stream";
}

pub const Holder = struct {
    session: Session,
    source: u32 = 0,
    data: []u8,
    mimes: std.ArrayList([]u8) = .empty,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    served: std.atomic.Value(u32) = .init(0),

    pub fn create(path: ?[]const u8, data: []const u8, mimes: []const []const u8, primary: bool) !*Holder {
        if (mimes.len == 0 or data.len > max_data) return error.Invalid;
        const h = try sys.gpa.create(Holder);
        errdefer sys.gpa.destroy(h);
        h.* = .{ .session = undefined, .data = try sys.gpa.dupe(u8, data) };
        errdefer h.freeOwned();
        for (mimes) |m| {
            if (m.len == 0 or m.len > 255) return error.Invalid;
            try h.mimes.append(sys.gpa, try sys.gpa.dupe(u8, m));
        }
        h.session = if (path) |p| try Session.openPath(p) else try Session.open();
        errdefer h.session.close();
        if (primary and !h.session.primary_supported) return error.Unsupported;
        const c = &h.session.conn;
        h.source = c.newId();
        var a = wl.Args{};
        defer a.deinit();
        try a.uint(h.source);
        try c.send(h.session.manager, 0, a.bytes(), null);
        for (h.mimes.items) |m| {
            var o = wl.Args{};
            defer o.deinit();
            try o.string(m);
            try c.send(h.source, 0, o.bytes(), null);
        }
        var sel = wl.Args{};
        defer sel.deinit();
        try sel.uint(h.source);
        try c.send(h.session.device, if (primary) 1 else 0, sel.bytes(), null);
        h.thread = try std.Thread.spawn(.{}, run, .{h});
        return h;
    }

    fn freeOwned(h: *Holder) void {
        sys.gpa.free(h.data);
        for (h.mimes.items) |m| sys.gpa.free(m);
        h.mimes.deinit(sys.gpa);
    }

    pub fn active(h: *const Holder) bool {
        return !h.cancelled.load(.acquire);
    }

    pub fn destroy(h: *Holder) void {
        h.stopping.store(true, .release);
        if (h.thread) |t| t.join();
        if (!h.cancelled.load(.acquire)) h.session.conn.send(h.source, 1, "", null) catch {};
        _ = h.session.roundtrip() catch {};
        h.session.close();
        h.freeOwned();
        sys.gpa.destroy(h);
    }

    fn write(h: *Holder, fd: i32) void {
        defer sys.close(fd);
        const fl = linux.fcntl(fd, linux.F.GETFL, 0);
        _ = linux.fcntl(fd, linux.F.SETFL, fl | @as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
        var off: usize = 0;
        var waited: i64 = 0;
        while (off < h.data.len and !h.stopping.load(.acquire) and waited < timeout_ms) {
            var p = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
            const rc = linux.poll(&p, 1, 100);
            if (linux.errno(rc) == .INTR) continue;
            if (rc == 0) {
                waited += 100;
                continue;
            }
            const n = linux.write(fd, h.data[off..].ptr, h.data.len - off);
            const e = linux.errno(n);
            if (e == .AGAIN or e == .INTR) continue;
            if (e != .SUCCESS) return;
            off += n;
            waited = 0;
        }
    }

    fn run(h: *Holder) void {
        var set = linux.sigemptyset();
        linux.sigaddset(&set, linux.SIG.PIPE);
        _ = linux.sigprocmask(linux.SIG.BLOCK, &set, null);
        while (!h.stopping.load(.acquire)) {
            var ev = (h.session.conn.next(100) catch {
                h.cancelled.store(true, .release);
                return;
            }) orelse continue;
            defer ev.deinit();
            if (ev.obj == h.source) {
                switch (ev.op) {
                    0 => {
                        const fd = h.session.conn.takeFd() catch continue;
                        h.write(fd);
                        _ = h.served.fetchAdd(1, .release);
                    },
                    1 => {
                        h.cancelled.store(true, .release);
                        h.session.conn.send(h.source, 1, "", null) catch {};
                        return;
                    },
                    else => {},
                }
                continue;
            }
            h.session.handle(&ev) catch {};
        }
    }
};

const Fake = struct {
    listen: i32,
    path: [108]u8 = [_]u8{0} ** 108,
    stop: std.atomic.Value(bool) = .init(false),
    received: [64]u8 = [_]u8{0} ** 64,
    received_len: usize = 0,
    source_mimes: u32 = 0,
    destroyed_source: std.atomic.Value(bool) = .init(false),
    cancel_source: std.atomic.Value(bool) = .init(false),
    got: std.atomic.Value(bool) = .init(false),

    const seat_name = 1;
    const manager_name = 2;

    fn init(f: *Fake) !void {
        const dir = std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp");
        var buf: [108]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/wl-fake-{d}", .{ dir, linux.getpid() }) catch return error.SkipZigTest;
        if (p.len >= 100) return error.SkipZigTest;
        sys.copyName(&f.path, p);
        var pz: [109]u8 = undefined;
        _ = linux.unlink(try sys.pathZ(&pz, "{s}", .{p}));
        f.listen = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
        var addr = linux.sockaddr.un{ .path = [_]u8{0} ** 108 };
        @memcpy(addr.path[0..p.len], p);
        _ = try sys.check(linux.bind(f.listen, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
        _ = try sys.check(linux.listen(f.listen, 4));
    }

    fn deinit(f: *Fake) void {
        sys.close(f.listen);
        var pz: [109]u8 = undefined;
        if (sys.pathZ(&pz, "{s}", .{sys.cstr(&f.path)})) |z| {
            _ = linux.unlink(z);
        } else |_| {}
    }

    fn offer(c: *wl.Conn, device: u32, id: u32, mimes: []const []const u8, op: u16) !void {
        var a = wl.Args{};
        defer a.deinit();
        try a.uint(id);
        try c.send(device, 0, a.bytes(), null);
        for (mimes) |m| {
            var o = wl.Args{};
            defer o.deinit();
            try o.string(m);
            try c.send(id, 0, o.bytes(), null);
        }
        try c.send(device, op, a.bytes(), null);
    }

    fn serve(f: *Fake, c: *wl.Conn) !void {
        var registry: u32 = 0;
        var manager: u32 = 0;
        var device: u32 = 0;
        var source: u32 = 0;
        var mimes: std.ArrayList([]u8) = .empty;
        defer {
            for (mimes.items) |m| sys.gpa.free(m);
            mimes.deinit(sys.gpa);
        }
        while (!f.stop.load(.acquire)) {
            var ev = (c.next(50) catch return) orelse {
                if (source != 0 and f.cancel_source.swap(false, .acq_rel)) try c.send(source, 1, "", null);
                continue;
            };
            defer ev.deinit();
            var r = ev.reader();
            var a = wl.Args{};
            defer a.deinit();
            if (ev.obj == wl.display_id and ev.op == 1) {
                registry = try r.uint();
                for ([_]struct { u32, []const u8, u32 }{ .{ seat_name, "wl_seat", 7 }, .{ manager_name, "ext_data_control_manager_v1", 1 } }) |g| {
                    var b = wl.Args{};
                    defer b.deinit();
                    try b.uint(g[0]);
                    try b.string(g[1]);
                    try b.uint(g[2]);
                    try c.send(registry, 0, b.bytes(), null);
                }
            } else if (ev.obj == wl.display_id and ev.op == 0) {
                const cb = try r.uint();
                try a.uint(1);
                try c.send(cb, 0, a.bytes(), null);
            } else if (ev.obj == registry and ev.op == 0) {
                const name = try r.uint();
                _ = try r.string();
                _ = try r.uint();
                const id = try r.uint();
                if (name == manager_name) manager = id;
            } else if (ev.obj == manager and ev.op == 1) {
                device = try r.uint();
                try offer(c, device, 0xff000000, &.{ "text/plain;charset=utf-8", "text/html" }, 1);
                try c.send(device, 3, &[_]u8{0} ** 4, null);
            } else if (ev.obj == manager and ev.op == 0) {
                source = try r.uint();
            } else if (ev.obj == source and source != 0 and ev.op == 0) {
                try mimes.append(sys.gpa, try sys.gpa.dupe(u8, (try r.string()) orelse ""));
                f.source_mimes += 1;
            } else if (ev.obj == source and source != 0 and ev.op == 1) {
                f.destroyed_source.store(true, .release);
            } else if (ev.obj == device and ev.op == 0) {
                if (try r.uint() != source) continue;
                var p: [2]i32 = undefined;
                _ = try sys.check(linux.pipe2(&p, .{ .CLOEXEC = true }));
                defer sys.close(p[0]);
                var b = wl.Args{};
                defer b.deinit();
                try b.string(mimes.items[0]);
                c.send(source, 0, b.bytes(), p[1]) catch {};
                sys.close(p[1]);
                var pf = [_]linux.pollfd{.{ .fd = p[0], .events = linux.POLL.IN, .revents = 0 }};
                while (f.received_len < f.received.len) {
                    if (linux.poll(&pf, 1, 2000) == 0) break;
                    const n = sys.read(p[0], f.received[f.received_len..]) catch break;
                    if (n == 0) break;
                    f.received_len += n;
                }
                f.got.store(true, .release);
            } else if (ev.op == 0 and ev.obj == 0xff000000) {
                const mime = (try r.string()) orelse "";
                const fd = try c.takeFd();
                defer sys.close(fd);
                if (std.mem.eql(u8, mime, "text/html")) try sys.writeAll(fd, "<b>ciao</b>") else try sys.writeAll(fd, "ciao dagli appunti");
            }
        }
    }

    fn run(f: *Fake) void {
        while (!f.stop.load(.acquire)) {
            var p = [_]linux.pollfd{.{ .fd = f.listen, .events = linux.POLL.IN, .revents = 0 }};
            if (linux.poll(&p, 1, 50) == 0) continue;
            const rc = linux.accept4(f.listen, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) continue;
            var c = wl.Conn.adopt(@intCast(rc));
            c.server = true;
            defer c.close();
            f.serve(&c) catch {};
        }
    }
};

test "the clipboard is read and offered through data control" {
    var fake = Fake{ .listen = -1 };
    try fake.init();
    defer fake.deinit();
    const t = try std.Thread.spawn(.{}, Fake.run, .{&fake});
    defer {
        fake.stop.store(true, .release);
        t.join();
    }
    const path = sys.cstr(&fake.path);
    {
        var s = try Session.openPath(path);
        defer s.close();
        const list = try s.types(false);
        defer list.destroy();
        try std.testing.expectEqual(@as(usize, 2), list.count());
        try std.testing.expectEqualStrings("text/html", std.mem.span(list.at(1).?.ptr));
        const text = try s.read(false, "text/plain;charset=utf-8");
        defer sys.gpa.free(text);
        try std.testing.expectEqualStrings("ciao dagli appunti", text);
        const html = try s.read(false, "text/html");
        defer sys.gpa.free(html);
        try std.testing.expectEqualStrings("<b>ciao</b>", html);
        try std.testing.expectError(error.NotFound, s.read(false, "image/png"));
        try std.testing.expectError(error.NotFound, s.read(true, "text/plain"));
    }
    const h = try Holder.create(path, "copiato da Sinty", &.{ defaultMime(true), "UTF8_STRING" }, false);
    var ok = false;
    for (0..100) |_| {
        if (fake.got.load(.acquire)) {
            ok = true;
            break;
        }
        sys.sleepMs(20);
    }
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("copiato da Sinty", fake.received[0..fake.received_len]);
    try std.testing.expectEqual(@as(u32, 2), fake.source_mimes);
    try std.testing.expect(h.active());
    fake.cancel_source.store(true, .release);
    for (0..100) |_| {
        if (!h.active()) break;
        sys.sleepMs(20);
    }
    try std.testing.expect(!h.active());
    h.destroy();
    try std.testing.expect(fake.destroyed_source.load(.acquire));
    try std.testing.expectError(error.Invalid, Holder.create(path, "x", &.{}, false));
}

test "a real compositor shares its clipboard" {
    const display = std.c.getenv("SINTY_WAYLAND_SOCKET") orelse return error.SkipZigTest;
    const path = std.mem.span(display);
    const h = try Holder.create(path, "Sinty appunti veri", &.{defaultMime(true)}, false);
    defer h.destroy();
    var s = try Session.openPath(path);
    defer s.close();
    var text: []u8 = &.{};
    for (0..50) |_| {
        s.roundtrip() catch {};
        text = s.read(false, defaultMime(true)) catch {
            sys.sleepMs(50);
            continue;
        };
        break;
    }
    defer sys.gpa.free(text);
    try std.testing.expectEqualStrings("Sinty appunti veri", text);
    try std.testing.expect(h.served.load(.acquire) > 0);
}
