const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const ROUTE: u32 = 0;
pub const GENERIC: u32 = 16;

pub const F_REQUEST: u16 = 0x1;
pub const F_MULTI: u16 = 0x2;
pub const F_ACK: u16 = 0x4;
pub const F_REPLACE: u16 = 0x100;
pub const F_EXCL: u16 = 0x200;
pub const F_CREATE: u16 = 0x400;
pub const F_DUMP: u16 = 0x300;
pub const NESTED: u16 = 0x8000;

const MSG_ERROR: u16 = 2;
const MSG_DONE: u16 = 3;
const SOL_NETLINK: i32 = 270;
const ADD_MEMBERSHIP: u32 = 1;
const EXT_ACK: u32 = 11;

pub const header = 16;

pub const Builder = struct {
    buf: std.ArrayList(u8) = .empty,
    nests: [8]usize = undefined,
    depth: usize = 0,

    pub fn deinit(self: *Builder) void {
        self.buf.deinit(sys.gpa);
    }

    fn pad(self: *Builder) !void {
        while (self.buf.items.len % 4 != 0) try self.buf.append(sys.gpa, 0);
    }

    pub fn begin(self: *Builder, kind: u16, flags: u16, fixed: []const u8) !void {
        self.buf.clearRetainingCapacity();
        self.depth = 0;
        var h = [_]u8{0} ** header;
        std.mem.writeInt(u16, h[4..6], kind, .little);
        std.mem.writeInt(u16, h[6..8], flags | F_REQUEST, .little);
        try self.buf.appendSlice(sys.gpa, &h);
        try self.buf.appendSlice(sys.gpa, fixed);
        try self.pad();
    }

    pub fn genl(self: *Builder, fam: u16, flags: u16, cmd: u8, version: u8) !void {
        try self.begin(fam, flags, &.{ cmd, version, 0, 0 });
    }

    pub fn finish(self: *Builder, seq: u32) []u8 {
        std.mem.writeInt(u32, self.buf.items[0..4], @intCast(self.buf.items.len), .little);
        std.mem.writeInt(u32, self.buf.items[8..12], seq, .little);
        return self.buf.items;
    }

    pub fn attr(self: *Builder, kind: u16, bytes: []const u8) !void {
        try self.pad();
        if (4 + bytes.len > 0xffff) return error.TooBig;
        var h: [4]u8 = undefined;
        std.mem.writeInt(u16, h[0..2], @intCast(4 + bytes.len), .little);
        std.mem.writeInt(u16, h[2..4], kind, .little);
        try self.buf.appendSlice(sys.gpa, &h);
        try self.buf.appendSlice(sys.gpa, bytes);
    }

    pub fn int(self: *Builder, kind: u16, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try self.attr(kind, &b);
    }

    pub fn str(self: *Builder, kind: u16, s: []const u8) !void {
        try self.pad();
        var h: [4]u8 = undefined;
        std.mem.writeInt(u16, h[0..2], @intCast(4 + s.len + 1), .little);
        std.mem.writeInt(u16, h[2..4], kind, .little);
        try self.buf.appendSlice(sys.gpa, &h);
        try self.buf.appendSlice(sys.gpa, s);
        try self.buf.append(sys.gpa, 0);
    }

    pub fn open(self: *Builder, kind: u16) !void {
        if (self.depth == self.nests.len) return error.TooBig;
        try self.pad();
        self.nests[self.depth] = self.buf.items.len;
        self.depth += 1;
        try self.attr(kind | NESTED, &.{});
    }

    pub fn close(self: *Builder) !void {
        self.depth -= 1;
        const at = self.nests[self.depth];
        const len = self.buf.items.len - at;
        if (len > 0xffff) return error.TooBig;
        std.mem.writeInt(u16, self.buf.items[at..][0..2], @intCast(len), .little);
    }
};

pub const Attr = struct { kind: u16, data: []const u8 };

pub const Attrs = struct {
    data: []const u8,
    off: usize = 0,

    pub fn next(self: *Attrs) ?Attr {
        if (self.off + 4 > self.data.len) return null;
        const len = std.mem.readInt(u16, self.data[self.off..][0..2], .little);
        const kind = std.mem.readInt(u16, self.data[self.off + 2 ..][0..2], .little) & 0x3fff;
        if (len < 4 or self.off + len > self.data.len) return null;
        const a = Attr{ .kind = kind, .data = self.data[self.off + 4 .. self.off + len] };
        self.off += std.mem.alignForward(usize, len, 4);
        return a;
    }
};

pub fn find(data: []const u8, kind: u16) ?[]const u8 {
    var it = Attrs{ .data = data };
    while (it.next()) |a| if (a.kind == kind) return a.data;
    return null;
}

pub fn int(comptime T: type, data: ?[]const u8) ?T {
    const d = data orelse return null;
    if (d.len < @sizeOf(T)) return null;
    return std.mem.readInt(T, d[0..@sizeOf(T)], .little);
}

pub fn text(data: ?[]const u8) []const u8 {
    const d = data orelse return "";
    return std.mem.sliceTo(d, 0);
}

fn errnoOf(v: i32) anyerror {
    if (v >= 0) return error.Io;
    const e: u16 = @intCast(@min(-@as(i64, v), 4095));
    return sys.fromErrno(@enumFromInt(e));
}

pub const Socket = struct {
    fd: i32,
    seq: u32,
    buf: []align(4) u8,

    pub fn open(proto: u32) !Socket {
        const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, proto)));
        errdefer sys.close(fd);
        var addr = linux.sockaddr.nl{ .pid = 0, .groups = 0 };
        _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)));
        var one: u32 = 1;
        _ = linux.setsockopt(fd, SOL_NETLINK, EXT_ACK, @ptrCast(&one), 4);
        const buf = try sys.gpa.alignedAlloc(u8, .@"4", 1 << 16);
        var r: [4]u8 = undefined;
        _ = linux.getrandom(&r, 4, 0);
        return .{ .fd = fd, .seq = std.mem.readInt(u32, &r, .little) | 1, .buf = buf };
    }

    pub fn close(self: *Socket) void {
        sys.gpa.free(self.buf);
        sys.close(self.fd);
    }

    pub fn join(self: *Socket, group: u32) !void {
        var g = group;
        _ = try sys.check(linux.setsockopt(self.fd, SOL_NETLINK, ADD_MEMBERSHIP, @ptrCast(&g), 4));
    }

    fn send(self: *Socket, b: *Builder) !u32 {
        self.seq +%= 1;
        const msg = b.finish(self.seq);
        var addr = linux.sockaddr.nl{ .pid = 0, .groups = 0 };
        while (true) {
            const rc = linux.sendto(self.fd, msg.ptr, msg.len, 0, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl));
            if (linux.errno(rc) == .INTR) continue;
            if (try sys.check(rc) != msg.len) return error.Io;
            return self.seq;
        }
    }

    fn recv(self: *Socket) !usize {
        while (true) {
            const rc = linux.recvfrom(self.fd, self.buf.ptr, self.buf.len, 0, null, null);
            if (linux.errno(rc) == .INTR) continue;
            const n = try sys.check(rc);
            if (n == 0) return error.Io;
            return n;
        }
    }

    pub fn call(self: *Socket, b: *Builder, ctx: anytype, comptime onMsg: fn (@TypeOf(ctx), u16, []const u8) anyerror!void) !void {
        const flags = std.mem.readInt(u16, b.buf.items[6..8], .little);
        const dump = flags & F_DUMP == F_DUMP;
        if (!dump) std.mem.writeInt(u16, b.buf.items[6..8], flags | F_ACK, .little);
        const seq = try self.send(b);
        var failure: ?anyerror = null;
        while (true) {
            const n = try self.recv();
            var off: usize = 0;
            while (off + header <= n) {
                const len = std.mem.readInt(u32, self.buf[off..][0..4], .little);
                const kind = std.mem.readInt(u16, self.buf[off + 4 ..][0..2], .little);
                const s = std.mem.readInt(u32, self.buf[off + 8 ..][0..4], .little);
                if (len < header or off + len > n) return error.Io;
                const body = self.buf[off + header .. off + len];
                off += std.mem.alignForward(usize, len, 4);
                if (s != seq) continue;
                if (kind == MSG_ERROR) {
                    const v = int(i32, body) orelse return error.Io;
                    if (v != 0) return errnoOf(v);
                    if (!dump) return failure orelse {};
                    continue;
                }
                if (kind == MSG_DONE) {
                    const v = int(i32, body) orelse 0;
                    if (v < 0) return errnoOf(v);
                    return failure orelse {};
                }
                if (failure == null) onMsg(ctx, kind, body) catch |e| {
                    failure = e;
                };
            }
        }
    }

    pub fn exec(self: *Socket, b: *Builder) !void {
        const Ignore = struct {
            fn f(_: void, _: u16, _: []const u8) anyerror!void {}
        };
        try self.call(b, {}, Ignore.f);
    }

    pub fn wait(self: *Socket, timeout_ms: i32, ctx: anytype, comptime onMsg: fn (@TypeOf(ctx), u16, []const u8) anyerror!bool) !void {
        var left = timeout_ms;
        while (true) {
            var pfd = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
            const t0 = monoMs();
            const rc = linux.poll(&pfd, 1, left);
            if (linux.errno(rc) == .INTR) continue;
            if (try sys.check(rc) == 0) return error.Again;
            const n = try self.recv();
            var off: usize = 0;
            while (off + header <= n) {
                const len = std.mem.readInt(u32, self.buf[off..][0..4], .little);
                const kind = std.mem.readInt(u16, self.buf[off + 4 ..][0..2], .little);
                if (len < header or off + len > n) return error.Io;
                const body = self.buf[off + header .. off + len];
                off += std.mem.alignForward(usize, len, 4);
                if (try onMsg(ctx, kind, body)) return;
            }
            left -= @intCast(@min(monoMs() - t0, @as(i64, left)));
            if (left <= 0) return error.Again;
        }
    }
};

fn monoMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub const Group = struct { name: [32]u8 = [_]u8{0} ** 32, id: u32 = 0 };

pub const Family = struct {
    id: u16,
    version: u32,
    groups: [8]Group = [_]Group{.{}} ** 8,
    group_count: usize = 0,

    pub fn group(self: *const Family, name: []const u8) ?u32 {
        for (self.groups[0..self.group_count]) |g| if (std.mem.eql(u8, sys.cstr(&g.name), name)) return g.id;
        return null;
    }
};

const CTRL_ID: u16 = 0x10;
const CTRL_CMD_GETFAMILY: u8 = 3;
const CTRL_ATTR_FAMILY_ID: u16 = 1;
const CTRL_ATTR_FAMILY_NAME: u16 = 2;
const CTRL_ATTR_VERSION: u16 = 3;
const CTRL_ATTR_MCAST_GROUPS: u16 = 7;

pub fn parseFamily(body: []const u8, out: *Family) !void {
    if (body.len < 4) return error.Io;
    const a = body[4..];
    out.* = .{ .id = int(u16, find(a, CTRL_ATTR_FAMILY_ID)) orelse return error.Io, .version = int(u32, find(a, CTRL_ATTR_VERSION)) orelse 1 };
    var groups = Attrs{ .data = find(a, CTRL_ATTR_MCAST_GROUPS) orelse return };
    while (groups.next()) |g| {
        if (out.group_count == out.groups.len) break;
        const name = text(find(g.data, 1));
        const id = int(u32, find(g.data, 2)) orelse continue;
        var e = Group{ .id = id };
        const n = @min(name.len, e.name.len - 1);
        @memcpy(e.name[0..n], name[0..n]);
        out.groups[out.group_count] = e;
        out.group_count += 1;
    }
}

pub fn family(s: *Socket, name: []const u8) !Family {
    var b = Builder{};
    defer b.deinit();
    try b.genl(CTRL_ID, 0, CTRL_CMD_GETFAMILY, 1);
    try b.str(CTRL_ATTR_FAMILY_NAME, name);
    var out: ?Family = null;
    const H = struct {
        fn f(o: *?Family, kind: u16, body: []const u8) anyerror!void {
            if (kind != CTRL_ID) return;
            var fam: Family = undefined;
            try parseFamily(body, &fam);
            o.* = fam;
        }
    };
    s.call(&b, &out, H.f) catch |e| return if (e == error.NotFound) error.Unsupported else e;
    return out orelse error.Unsupported;
}

test "attributes round trip through the builder" {
    var b = Builder{};
    defer b.deinit();
    try b.begin(18, F_DUMP, &[_]u8{0} ** 16);
    try b.str(3, "wg0");
    try b.open(18);
    try b.str(1, "wireguard");
    try b.int(2, u16, 51820);
    try b.close();
    try b.int(4, u32, 1420);
    const msg = b.finish(7);
    try std.testing.expectEqual(@as(u32, @intCast(msg.len)), std.mem.readInt(u32, msg[0..4], .little));
    try std.testing.expectEqual(@as(u16, F_DUMP | F_REQUEST), std.mem.readInt(u16, msg[6..8], .little));
    const attrs = msg[header + 16 ..];
    try std.testing.expectEqualStrings("wg0", text(find(attrs, 3)));
    try std.testing.expectEqual(@as(?u32, 1420), int(u32, find(attrs, 4)));
    const nest = find(attrs, 18).?;
    try std.testing.expectEqualStrings("wireguard", text(find(nest, 1)));
    try std.testing.expectEqual(@as(?u16, 51820), int(u16, find(nest, 2)));
    try std.testing.expectEqual(@as(?u16, null), int(u16, find(nest, 9)));
}

test "generic netlink resolves its own controller" {
    var s = try Socket.open(GENERIC);
    defer s.close();
    const f = try family(&s, "nlctrl");
    try std.testing.expectEqual(CTRL_ID, f.id);
    try std.testing.expect(f.group("notify") != null);
    try std.testing.expectError(error.Unsupported, family(&s, "no-such-family"));
}
