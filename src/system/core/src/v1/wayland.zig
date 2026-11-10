const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const display_id: u32 = 1;
const max_message = 4096;
const max_fds = 28;

pub const Args = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(a: *Args) void {
        a.buf.deinit(sys.gpa);
    }

    pub fn uint(a: *Args, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .native);
        try a.buf.appendSlice(sys.gpa, &b);
    }

    pub fn int(a: *Args, v: i32) !void {
        try a.uint(@bitCast(v));
    }

    pub fn string(a: *Args, s: ?[]const u8) !void {
        const v = s orelse return a.uint(0);
        if (std.mem.indexOfScalar(u8, v, 0) != null) return error.Invalid;
        try a.uint(@intCast(v.len + 1));
        try a.buf.appendSlice(sys.gpa, v);
        try a.buf.append(sys.gpa, 0);
        while (a.buf.items.len % 4 != 0) try a.buf.append(sys.gpa, 0);
    }

    pub fn bytes(a: *const Args) []const u8 {
        return a.buf.items;
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn uint(r: *Reader) !u32 {
        if (r.pos + 4 > r.data.len) return error.Invalid;
        const v = std.mem.readInt(u32, r.data[r.pos..][0..4], .native);
        r.pos += 4;
        return v;
    }

    pub fn int(r: *Reader) !i32 {
        return @bitCast(try r.uint());
    }

    pub fn string(r: *Reader) !?[]const u8 {
        const n = try r.uint();
        if (n == 0) return null;
        const padded = (@as(usize, n) + 3) & ~@as(usize, 3);
        if (r.pos + padded > r.data.len or r.data[r.pos + n - 1] != 0) return error.Invalid;
        const s = r.data[r.pos .. r.pos + n - 1];
        r.pos += padded;
        return s;
    }
};

pub const Event = struct {
    obj: u32,
    op: u16,
    data: []u8,

    pub fn deinit(e: *Event) void {
        sys.gpa.free(e.data);
    }

    pub fn reader(e: *const Event) Reader {
        return .{ .data = e.data };
    }
};

pub fn socketPath(buf: []u8) ![]const u8 {
    const name = if (std.c.getenv("WAYLAND_DISPLAY")) |d| std.mem.span(d) else "wayland-0";
    if (name.len > 0 and name[0] == '/') return std.fmt.bufPrint(buf, "{s}", .{name}) catch error.TooBig;
    const dir = std.c.getenv("XDG_RUNTIME_DIR") orelse return error.NotFound;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.span(dir), name }) catch error.TooBig;
}

pub const Conn = struct {
    fd: i32,
    next_id: u32 = 2,
    in: std.ArrayList(u8) = .empty,
    fds: std.ArrayList(i32) = .empty,
    error_text: [256]u8 = [_]u8{0} ** 256,
    server: bool = false,

    pub fn connect() !Conn {
        var buf: [256]u8 = undefined;
        return open(try socketPath(&buf));
    }

    pub fn open(path: []const u8) !Conn {
        var addr = linux.sockaddr.un{ .path = [_]u8{0} ** 108 };
        if (path.len == 0 or path.len >= addr.path.len) return error.Invalid;
        @memcpy(addr.path[0..path.len], path);
        const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
        errdefer sys.close(fd);
        _ = try sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
        return .{ .fd = fd };
    }

    pub fn adopt(fd: i32) Conn {
        return .{ .fd = fd };
    }

    pub fn close(c: *Conn) void {
        if (c.fd >= 0) sys.close(c.fd);
        for (c.fds.items) |f| sys.close(f);
        c.fds.deinit(sys.gpa);
        c.in.deinit(sys.gpa);
        c.fd = -1;
    }

    pub fn newId(c: *Conn) u32 {
        const id = c.next_id;
        c.next_id += 1;
        return id;
    }

    pub fn errorText(c: *const Conn) []const u8 {
        return sys.cstr(&c.error_text);
    }

    pub fn send(c: *Conn, obj: u32, op: u16, args: []const u8, fd: ?i32) !void {
        const size = 8 + args.len;
        if (size > max_message) return error.TooBig;
        var buf: [max_message]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], obj, .native);
        std.mem.writeInt(u32, buf[4..8], (@as(u32, @intCast(size)) << 16) | op, .native);
        @memcpy(buf[8..size], args);
        var iov = [_]std.posix.iovec_const{.{ .base = &buf, .len = size }};
        var control: [24]u8 align(8) = [_]u8{0} ** 24;
        var msg = linux.msghdr_const{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
        if (fd) |f| {
            std.mem.writeInt(usize, control[0..8], 20, .native);
            std.mem.writeInt(i32, control[8..12], linux.SOL.SOCKET, .native);
            std.mem.writeInt(i32, control[12..16], 1, .native);
            std.mem.writeInt(i32, control[16..20], f, .native);
            msg.control = &control;
            msg.controllen = control.len;
        }
        while (true) {
            const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return sys.fromErrno(e);
            if (rc != size) return error.Io;
            return;
        }
    }

    fn fill(c: *Conn, timeout_ms: i64) !bool {
        var p = [_]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 }};
        while (true) {
            const rc = linux.poll(&p, 1, @intCast(@max(timeout_ms, 0)));
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return sys.fromErrno(e);
            if (rc == 0) return false;
            break;
        }
        var buf: [16384]u8 = undefined;
        var iov = [_]std.posix.iovec{.{ .base = &buf, .len = buf.len }};
        var control: [16 + 4 * max_fds]u8 align(8) = undefined;
        var msg = linux.msghdr{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
        const n = while (true) {
            const rc = linux.recvmsg(c.fd, &msg, linux.MSG.CMSG_CLOEXEC);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return sys.fromErrno(e);
            break rc;
        };
        try c.takeControl(control[0..msg.controllen]);
        if (n == 0) return error.Io;
        try c.in.appendSlice(sys.gpa, buf[0..n]);
        return true;
    }

    fn takeControl(c: *Conn, control: []const u8) !void {
        var off: usize = 0;
        while (off + 16 <= control.len) {
            const len = std.mem.readInt(usize, control[off..][0..8], .native);
            const level = std.mem.readInt(i32, control[off + 8 ..][0..4], .native);
            const ty = std.mem.readInt(i32, control[off + 12 ..][0..4], .native);
            if (len < 16 or off + len > control.len) return;
            if (level == linux.SOL.SOCKET and ty == 1) {
                var i: usize = off + 16;
                while (i + 4 <= off + len) : (i += 4) try c.fds.append(sys.gpa, std.mem.readInt(i32, control[i..][0..4], .native));
            }
            off += (len + 7) & ~@as(usize, 7);
        }
    }

    pub fn next(c: *Conn, timeout_ms: i64) !?Event {
        const deadline = @import("bus.zig").nowMs() + timeout_ms;
        while (true) {
            if (c.in.items.len >= 8) {
                const word = std.mem.readInt(u32, c.in.items[4..8], .native);
                const size: usize = word >> 16;
                if (size < 8 or size % 4 != 0) return error.Invalid;
                if (c.in.items.len >= size) {
                    const ev = Event{
                        .obj = std.mem.readInt(u32, c.in.items[0..4], .native),
                        .op = @truncate(word),
                        .data = try sys.gpa.dupe(u8, c.in.items[8..size]),
                    };
                    const rest = c.in.items.len - size;
                    std.mem.copyForwards(u8, c.in.items[0..rest], c.in.items[size..]);
                    c.in.shrinkRetainingCapacity(rest);
                    if (ev.obj == display_id and !c.server) {
                        var e = ev;
                        defer e.deinit();
                        if (e.op == 0) {
                            var r = e.reader();
                            _ = try r.uint();
                            _ = try r.uint();
                            sys.copyName(&c.error_text, (try r.string()) orelse "");
                            return error.Io;
                        }
                        continue;
                    }
                    return ev;
                }
            }
            const left = deadline - @import("bus.zig").nowMs();
            if (left < 0 or !try c.fill(left)) return null;
        }
    }

    pub fn takeFd(c: *Conn) !i32 {
        if (c.fds.items.len == 0) return error.Invalid;
        return c.fds.orderedRemove(0);
    }

    pub fn sync(c: *Conn) !u32 {
        const cb = c.newId();
        var a = Args{};
        defer a.deinit();
        try a.uint(cb);
        try c.send(display_id, 0, a.bytes(), null);
        return cb;
    }
};

test "wayland arguments round trip with padding" {
    var a = Args{};
    defer a.deinit();
    try a.uint(7);
    try a.string("text/plain");
    try a.string(null);
    try a.int(-3);
    try std.testing.expectEqual(@as(usize, 4 + 4 + 12 + 4 + 4), a.bytes().len);
    var r = Reader{ .data = a.bytes() };
    try std.testing.expectEqual(@as(u32, 7), try r.uint());
    try std.testing.expectEqualStrings("text/plain", (try r.string()).?);
    try std.testing.expect((try r.string()) == null);
    try std.testing.expectEqual(@as(i32, -3), try r.int());
    try std.testing.expectError(error.Invalid, r.uint());
    try std.testing.expectError(error.Invalid, a.string("a\x00b"));
}

test "messages and descriptors cross a socket pair" {
    var sv: [2]i32 = undefined;
    _ = try sys.check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv));
    var a = Conn.adopt(sv[0]);
    defer a.close();
    var b = Conn.adopt(sv[1]);
    defer b.close();
    var p: [2]i32 = undefined;
    _ = try sys.check(linux.pipe2(&p, .{ .CLOEXEC = true }));
    defer sys.close(p[0]);
    var args = Args{};
    defer args.deinit();
    try args.string("receive");
    try a.send(5, 2, args.bytes(), p[1]);
    sys.close(p[1]);
    try a.send(6, 0, "", null);
    var ev = (try b.next(1000)) orelse return error.TestUnexpectedResult;
    defer ev.deinit();
    try std.testing.expectEqual(@as(u32, 5), ev.obj);
    try std.testing.expectEqual(@as(u16, 2), ev.op);
    var r = ev.reader();
    try std.testing.expectEqualStrings("receive", (try r.string()).?);
    const fd = try b.takeFd();
    try sys.writeAll(fd, "ok");
    sys.close(fd);
    var got: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try sys.read(p[0], &got));
    var ev2 = (try b.next(1000)) orelse return error.TestUnexpectedResult;
    defer ev2.deinit();
    try std.testing.expectEqual(@as(u32, 6), ev2.obj);
    try std.testing.expect((try b.next(10)) == null);
    var err = Args{};
    defer err.deinit();
    try err.uint(3);
    try err.uint(1);
    try err.string("bad object");
    try a.send(display_id, 0, err.bytes(), null);
    try std.testing.expectError(error.Io, b.next(1000));
    try std.testing.expectEqualStrings("bad object", b.errorText());
}
