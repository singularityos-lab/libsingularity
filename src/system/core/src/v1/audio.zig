const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const Kind = enum(i32) { node = 1, client = 2, link = 3 };

pub const Object = extern struct {
    id: u32,
    kind: i32,
    output_node: u32,
    input_node: u32,
    n_props: usize,
    keys: ?[*][*:0]u8,
    values: ?[*][*:0]u8,

    pub fn deinit(self: *Object) void {
        if (self.keys) |k| {
            for (k[0..self.n_props]) |s| sys.gpa.free(std.mem.span(s));
            sys.gpa.free(k[0..self.n_props]);
        }
        if (self.values) |v| {
            for (v[0..self.n_props]) |s| sys.gpa.free(std.mem.span(s));
            sys.gpa.free(v[0..self.n_props]);
        }
        self.keys = null;
        self.values = null;
        self.n_props = 0;
    }

    pub fn prop(self: *const Object, key: []const u8) ?[]const u8 {
        const k = self.keys orelse return null;
        const v = self.values orelse return null;
        for (0..self.n_props) |i| if (std.mem.eql(u8, std.mem.span(k[i]), key)) return std.mem.span(v[i]);
        return null;
    }
};

pub const Graph = sys.List(Object);

const T = struct {
    const none: u32 = 1;
    const id: u32 = 3;
    const int: u32 = 4;
    const float: u32 = 6;
    const long: u32 = 5;
    const string: u32 = 8;
    const @"struct": u32 = 14;
};

pub const Pod = struct { ty: u32, body: []const u8 };

fn u32At(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .native);
}

fn pad8(n: usize) usize {
    return (n + 7) & ~@as(usize, 7);
}

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(r: *Reader) ?Pod {
        if (r.pos + 8 > r.data.len) return null;
        const size = u32At(r.data, r.pos);
        const ty = u32At(r.data, r.pos + 4);
        if (r.pos + 8 + size > r.data.len) return null;
        const p = Pod{ .ty = ty, .body = r.data[r.pos + 8 ..][0..size] };
        r.pos += 8 + pad8(size);
        return p;
    }
};

pub fn podInt(p: Pod) ?i32 {
    if (p.ty != T.int or p.body.len < 4) return null;
    return @bitCast(u32At(p.body, 0));
}

pub fn podString(p: Pod) ?[]const u8 {
    if (p.ty == T.none) return "";
    if (p.ty != T.string) return null;
    return p.body[0 .. std.mem.indexOfScalar(u8, p.body, 0) orelse p.body.len];
}

pub const Builder = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    stack: [8]usize = undefined,
    depth: usize = 0,

    fn put(b: *Builder, bytes: []const u8) !void {
        if (b.len + pad8(bytes.len) > b.buf.len) return error.TooBig;
        @memcpy(b.buf[b.len..][0..bytes.len], bytes);
        @memset(b.buf[b.len + bytes.len .. b.len + pad8(bytes.len)], 0);
        b.len += pad8(bytes.len);
    }

    fn header(b: *Builder, size: u32, ty: u32) !void {
        var h: [8]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], size, .native);
        std.mem.writeInt(u32, h[4..8], ty, .native);
        if (b.len + 8 > b.buf.len) return error.TooBig;
        @memcpy(b.buf[b.len..][0..8], &h);
        b.len += 8;
    }

    pub fn int(b: *Builder, v: i32) !void {
        try b.header(4, T.int);
        var x: [4]u8 = undefined;
        std.mem.writeInt(i32, &x, v, .native);
        try b.put(&x);
    }

    pub fn string(b: *Builder, s: []const u8) !void {
        if (s.len + 1 > b.buf.len) return error.TooBig;
        try b.header(@intCast(s.len + 1), T.string);
        const start = b.len;
        if (start + pad8(s.len + 1) > b.buf.len) return error.TooBig;
        @memcpy(b.buf[start..][0..s.len], s);
        @memset(b.buf[start + s.len .. start + pad8(s.len + 1)], 0);
        b.len += pad8(s.len + 1);
    }

    pub fn id(b: *Builder, v: u32) !void {
        try b.header(4, T.id);
        var x: [4]u8 = undefined;
        std.mem.writeInt(u32, &x, v, .native);
        try b.put(&x);
    }

    pub fn float(b: *Builder, v: f32) !void {
        try b.header(4, T.float);
        var x: [4]u8 = undefined;
        std.mem.writeInt(u32, &x, @bitCast(v), .native);
        try b.put(&x);
    }

    pub fn raw(b: *Builder, v: u32) !void {
        if (b.len + 4 > b.buf.len) return error.TooBig;
        std.mem.writeInt(u32, b.buf[b.len..][0..4], v, .native);
        b.len += 4;
    }

    pub fn pushObject(b: *Builder, object_type: u32, object_id: u32) !void {
        if (b.depth == b.stack.len) return error.TooBig;
        b.stack[b.depth] = b.len;
        b.depth += 1;
        try b.header(0, 15);
        try b.raw(object_type);
        try b.raw(object_id);
    }

    pub fn push(b: *Builder) !void {
        if (b.depth == b.stack.len) return error.TooBig;
        b.stack[b.depth] = b.len;
        b.depth += 1;
        try b.header(0, T.@"struct");
    }

    pub fn pop(b: *Builder) void {
        b.depth -= 1;
        const at = b.stack[b.depth];
        std.mem.writeInt(u32, b.buf[at..][0..4], @intCast(b.len - at - 8), .native);
    }
};

const Pending = struct { global: u32, kind: Kind, proxy: u32 };

const registry_id: u32 = 2;

const Conn = struct {
    fd: i32,
    seq: u32 = 0,
    in: std.ArrayList(u8) = .empty,

    fn send(c: *Conn, id: u32, opcode: u8, body: []const u8) !void {
        var h: [16]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], id, .native);
        std.mem.writeInt(u32, h[4..8], (@as(u32, opcode) << 24) | @as(u32, @intCast(body.len)), .native);
        std.mem.writeInt(u32, h[8..12], c.seq, .native);
        std.mem.writeInt(u32, h[12..16], 0, .native);
        c.seq += 1;
        try sys.writeAll(c.fd, &h);
        try sys.writeAll(c.fd, body);
    }

    fn fill(c: *Conn) !void {
        var buf: [65536]u8 = undefined;
        var iov = [_]std.posix.iovec{.{ .base = &buf, .len = buf.len }};
        var control: [256]u8 align(8) = undefined;
        var msg = linux.msghdr{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
        const n = try sys.check(linux.recvmsg(c.fd, &msg, linux.MSG.CMSG_CLOEXEC));
        if (n == 0) return error.Io;
        closeFds(control[0..msg.controllen]);
        try c.in.appendSlice(sys.gpa, buf[0..n]);
    }

    const Message = struct { id: u32, opcode: u8, body: []const u8 };

    fn next(c: *Conn, scratch: *std.ArrayList(u8)) !Message {
        while (true) {
            if (c.in.items.len >= 16) {
                const p = u32At(c.in.items, 4);
                const size: usize = p & 0xffffff;
                if (size > 16 << 20) return error.TooBig;
                if (c.in.items.len >= 16 + size) {
                    scratch.clearRetainingCapacity();
                    try scratch.appendSlice(sys.gpa, c.in.items[16 .. 16 + size]);
                    const m = Message{ .id = u32At(c.in.items, 0), .opcode = @intCast(p >> 24), .body = scratch.items };
                    const rest = c.in.items.len - 16 - size;
                    std.mem.copyForwards(u8, c.in.items[0..rest], c.in.items[16 + size ..]);
                    c.in.shrinkRetainingCapacity(rest);
                    return m;
                }
            }
            try c.fill();
        }
    }
};

fn closeFds(control: []const u8) void {
    var off: usize = 0;
    while (off + 16 <= control.len) {
        const len = std.mem.readInt(usize, control[off..][0..8], .native);
        const level = std.mem.readInt(i32, control[off + 8 ..][0..4], .native);
        const ty = std.mem.readInt(i32, control[off + 12 ..][0..4], .native);
        if (len < 16 or off + len > control.len) return;
        if (level == linux.SOL.SOCKET and ty == 1) {
            var i: usize = off + 16;
            while (i + 4 <= off + len) : (i += 4) sys.close(std.mem.readInt(i32, control[i..][0..4], .native));
        }
        off += pad8(len);
    }
}

fn kindOf(ty: []const u8) ?Kind {
    if (std.mem.eql(u8, ty, "PipeWire:Interface:Node")) return .node;
    if (std.mem.eql(u8, ty, "PipeWire:Interface:Client")) return .client;
    if (std.mem.eql(u8, ty, "PipeWire:Interface:Link")) return .link;
    return null;
}

fn typeName(k: Kind) []const u8 {
    return switch (k) {
        .node => "PipeWire:Interface:Node",
        .client => "PipeWire:Interface:Client",
        .link => "PipeWire:Interface:Link",
    };
}

pub fn socketPath(buf: []u8) ![*:0]const u8 {
    const remote: []const u8 = if (std.c.getenv("PIPEWIRE_REMOTE")) |r| std.mem.span(r) else "pipewire-0";
    if (remote.len > 0 and remote[0] == '/') return sys.pathZ(buf, "{s}", .{remote});
    for ([_][*:0]const u8{ "PIPEWIRE_RUNTIME_DIR", "XDG_RUNTIME_DIR" }) |name| {
        if (std.c.getenv(name)) |dir| return sys.pathZ(buf, "{s}/{s}", .{ std.mem.span(dir), remote });
    }
    return error.NotFound;
}

fn connect(path: [*:0]const u8) !i32 {
    const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer sys.close(fd);
    var addr = linux.sockaddr.un{ .path = [_]u8{0} ** 108 };
    const p = std.mem.span(path);
    if (p.len >= addr.path.len) return error.TooBig;
    @memcpy(addr.path[0..p.len], p);
    _ = try sys.check(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un)));
    const tv = linux.timeval{ .sec = 3, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    return fd;
}

pub fn dictInto(o: *Object, dict: Pod) !void {
    if (dict.ty != T.@"struct") return error.Invalid;
    var r = Reader{ .data = dict.body };
    const n_raw = podInt(r.next() orelse return error.Invalid) orelse return error.Invalid;
    if (n_raw < 0 or n_raw > 4096) return error.Invalid;
    const n: usize = @intCast(n_raw);
    o.deinit();
    const keys = try sys.gpa.alloc([*:0]u8, n);
    errdefer sys.gpa.free(keys);
    const values = try sys.gpa.alloc([*:0]u8, n);
    errdefer sys.gpa.free(values);
    var done: usize = 0;
    errdefer for (0..done) |i| {
        sys.gpa.free(std.mem.span(keys[i]));
        sys.gpa.free(std.mem.span(values[i]));
    };
    while (done < n) : (done += 1) {
        const k = podString(r.next() orelse return error.Invalid) orelse return error.Invalid;
        const v = podString(r.next() orelse return error.Invalid) orelse return error.Invalid;
        keys[done] = try sys.dupZ(sys.gpa, k);
        values[done] = sys.dupZ(sys.gpa, v) catch |e| {
            sys.gpa.free(std.mem.span(keys[done]));
            return e;
        };
    }
    o.keys = keys.ptr;
    o.values = values.ptr;
    o.n_props = n;
}

pub fn applyInfo(o: *Object, body: []const u8) !void {
    var top = Reader{ .data = body };
    const info = top.next() orelse return error.Invalid;
    if (info.ty != T.@"struct") return error.Invalid;
    var r = Reader{ .data = info.body };
    var ints: [8]i32 = undefined;
    var n_ints: usize = 0;
    while (r.next()) |p| {
        if (p.ty == T.int and n_ints < ints.len) {
            ints[n_ints] = podInt(p).?;
            n_ints += 1;
        } else if (p.ty == T.@"struct") {
            try dictInto(o, p);
            break;
        }
    }
    if (o.kind == @intFromEnum(Kind.link) and n_ints >= 4) {
        o.output_node = @bitCast(ints[1]);
        o.input_node = @bitCast(ints[3]);
    }
}

const Watch = struct { name: []const u8, found: ?u32 = null, failed: ?u32 = null };

fn sync(c: *Conn, scratch: *std.ArrayList(u8), seq: i32, graph: ?*Graph, pending: []const Pending, globals: ?*std.ArrayList(Pending)) !void {
    return syncWatch(c, scratch, seq, graph, pending, globals, null);
}

fn syncWatch(c: *Conn, scratch: *std.ArrayList(u8), seq: i32, graph: ?*Graph, pending: []const Pending, globals: ?*std.ArrayList(Pending), watch: ?*Watch) !void {
    var b = Builder{};
    try b.push();
    try b.int(0);
    try b.int(seq);
    b.pop();
    try c.send(0, 2, b.buf[0..b.len]);
    while (true) {
        const m = try c.next(scratch);
        if (m.id == 0) {
            var top = Reader{ .data = m.body };
            const s = top.next() orelse continue;
            var r = Reader{ .data = s.body };
            switch (m.opcode) {
                1 => {
                    _ = r.next();
                    const got = podInt(r.next() orelse continue) orelse continue;
                    if (got == seq) return;
                },
                2 => {
                    const id = podInt(r.next() orelse continue) orelse continue;
                    const ps = podInt(r.next() orelse continue) orelse continue;
                    var pong = Builder{};
                    try pong.push();
                    try pong.int(id);
                    try pong.int(ps);
                    pong.pop();
                    try c.send(0, 3, pong.buf[0..pong.len]);
                },
                3 => {
                    const id = podInt(r.next() orelse continue) orelse continue;
                    if (id == 0) return error.Io;
                    if (watch) |w| w.failed = @bitCast(id);
                },
                else => {},
            }
        } else if (m.id == registry_id and m.opcode == 0) {
            var top = Reader{ .data = m.body };
            const s = top.next() orelse continue;
            var r = Reader{ .data = s.body };
            const id = podInt(r.next() orelse continue) orelse continue;
            _ = r.next();
            const ty = podString(r.next() orelse continue) orelse continue;
            const k = kindOf(ty) orelse continue;
            if (watch) |w| {
                if (k != .node) continue;
                _ = r.next();
                const dict = r.next() orelse continue;
                var probe = std.mem.zeroes(Object);
                defer probe.deinit();
                dictInto(&probe, dict) catch continue;
                const name = probe.prop("node.name") orelse continue;
                if (std.mem.eql(u8, name, w.name)) w.found = @bitCast(id);
                continue;
            }
            const list = globals orelse continue;
            try list.append(sys.gpa, .{ .global = @bitCast(id), .kind = k, .proxy = 0 });
        } else if (m.opcode == 0) {
            const g = graph orelse continue;
            for (pending, 0..) |p, i| {
                if (p.proxy != m.id) continue;
                applyInfo(&g.items.items[i], m.body) catch {};
                break;
            }
        }
    }
}

fn hello(c: *Conn) !void {
    var b = Builder{};
    try b.push();
    try b.int(4);
    b.pop();
    try c.send(0, 1, b.buf[0..b.len]);

    b = Builder{};
    try b.push();
    try b.push();
    try b.int(1);
    try b.string("application.name");
    try b.string("sinty-system");
    b.pop();
    b.pop();
    try c.send(1, 2, b.buf[0..b.len]);

    b = Builder{};
    try b.push();
    try b.int(3);
    try b.int(@intCast(registry_id));
    b.pop();
    try c.send(0, 5, b.buf[0..b.len]);
}

pub fn snapshotAt(path: [*:0]const u8) !*Graph {
    const fd = try connect(path);
    defer sys.close(fd);
    var c = Conn{ .fd = fd };
    defer c.in.deinit(sys.gpa);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(sys.gpa);
    try hello(&c);
    var b = Builder{};

    const graph = try Graph.create();
    errdefer graph.destroy();
    var globals: std.ArrayList(Pending) = .empty;
    defer globals.deinit(sys.gpa);
    try sync(&c, &scratch, 1, graph, &.{}, &globals);

    var next_proxy: u32 = 3;
    for (globals.items) |*g| {
        g.proxy = next_proxy;
        next_proxy += 1;
        try graph.append(.{ .id = g.global, .kind = @intFromEnum(g.kind), .output_node = 0, .input_node = 0, .n_props = 0, .keys = null, .values = null });
        b = Builder{};
        try b.push();
        try b.int(@bitCast(g.global));
        try b.string(typeName(g.kind));
        try b.int(3);
        try b.int(@bitCast(g.proxy));
        b.pop();
        try c.send(registry_id, 1, b.buf[0..b.len]);
    }
    try sync(&c, &scratch, 2, graph, globals.items, null);
    return graph;
}

pub const Control = struct { name: []const u8, value: f32 };

const prop_params: u32 = 0x80001;
const object_props: u32 = 0x40002;
const param_props: u32 = 2;

pub fn controlsBody(b: *Builder, controls: []const Control) !void {
    try b.push();
    try b.id(param_props);
    try b.int(0);
    try b.pushObject(object_props, param_props);
    try b.raw(prop_params);
    try b.raw(0);
    try b.push();
    for (controls) |ctl| {
        try b.string(ctl.name);
        try b.float(ctl.value);
    }
    b.pop();
    b.pop();
    b.pop();
}

pub fn setControlsAt(path: [*:0]const u8, node_name: []const u8, controls: []const Control) !void {
    if (controls.len == 0 or controls.len > 64) return error.Invalid;
    const fd = try connect(path);
    defer sys.close(fd);
    var c = Conn{ .fd = fd };
    defer c.in.deinit(sys.gpa);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(sys.gpa);
    try hello(&c);
    var w = Watch{ .name = node_name };
    try syncWatch(&c, &scratch, 1, null, &.{}, null, &w);
    const global = w.found orelse return error.NotFound;
    const proxy: u32 = 3;
    var b = Builder{};
    try b.push();
    try b.int(@bitCast(global));
    try b.string("PipeWire:Interface:Node");
    try b.int(3);
    try b.int(@bitCast(proxy));
    b.pop();
    try c.send(registry_id, 1, b.buf[0..b.len]);
    b = Builder{};
    try controlsBody(&b, controls);
    try c.send(proxy, 3, b.buf[0..b.len]);
    w.failed = null;
    try syncWatch(&c, &scratch, 2, null, &.{}, null, &w);
    if (w.failed) |id| if (id == proxy) return error.Access;
}

pub fn setControls(node_name: []const u8, controls: []const Control) !void {
    var buf: [512]u8 = undefined;
    return setControlsAt(try socketPath(&buf), node_name, controls);
}

pub fn snapshot() !*Graph {
    var buf: [512]u8 = undefined;
    return snapshotAt(try socketPath(&buf));
}

test "pod builder and reader agree" {
    var b = Builder{};
    try b.push();
    try b.int(7);
    try b.string("media.class");
    try b.push();
    try b.int(1);
    try b.string("k");
    try b.string("v");
    b.pop();
    b.pop();
    var top = Reader{ .data = b.buf[0..b.len] };
    const s = top.next().?;
    try std.testing.expectEqual(T.@"struct", s.ty);
    var r = Reader{ .data = s.body };
    try std.testing.expectEqual(@as(i32, 7), podInt(r.next().?).?);
    try std.testing.expectEqualStrings("media.class", podString(r.next().?).?);
    var o = std.mem.zeroes(Object);
    try dictInto(&o, r.next().?);
    defer o.deinit();
    try std.testing.expectEqualStrings("v", o.prop("k").?);
    try std.testing.expect(top.next() == null);
}

test "link info gives the two node ids and its props" {
    var b = Builder{};
    try b.push();
    try b.int(40);
    try b.int(31);
    try b.int(50);
    try b.int(32);
    try b.int(51);
    try b.header(8, T.long);
    try b.put(&[_]u8{0} ** 8);
    try b.push();
    try b.int(1);
    try b.string("link.output.node");
    try b.string("31");
    b.pop();
    b.pop();
    var o = std.mem.zeroes(Object);
    o.kind = @intFromEnum(Kind.link);
    try applyInfo(&o, b.buf[0..b.len]);
    defer o.deinit();
    try std.testing.expectEqual(@as(u32, 31), o.output_node);
    try std.testing.expectEqual(@as(u32, 32), o.input_node);
    try std.testing.expectEqualStrings("31", o.prop("link.output.node").?);
}

test "a Props param carries the control names and values" {
    var b = Builder{};
    try controlsBody(&b, &.{ .{ .name = "eq_band_1:Gain", .value = 3.5 }, .{ .name = "eq_band_2:Gain", .value = -2 } });
    var top = Reader{ .data = b.buf[0..b.len] };
    const s = top.next().?;
    var r = Reader{ .data = s.body };
    const pid = r.next().?;
    try std.testing.expectEqual(T.id, pid.ty);
    try std.testing.expectEqual(param_props, u32At(pid.body, 0));
    try std.testing.expectEqual(@as(i32, 0), podInt(r.next().?).?);
    const obj = r.next().?;
    try std.testing.expectEqual(@as(u32, 15), obj.ty);
    try std.testing.expectEqual(object_props, u32At(obj.body, 0));
    try std.testing.expectEqual(param_props, u32At(obj.body, 4));
    try std.testing.expectEqual(prop_params, u32At(obj.body, 8));
    var inner = Reader{ .data = obj.body[16..] };
    const list = inner.next().?;
    try std.testing.expectEqual(T.@"struct", list.ty);
    var lr = Reader{ .data = list.body };
    try std.testing.expectEqualStrings("eq_band_1:Gain", podString(lr.next().?).?);
    const v = lr.next().?;
    try std.testing.expectEqual(T.float, v.ty);
    try std.testing.expectEqual(@as(f32, 3.5), @as(f32, @bitCast(u32At(v.body, 0))));
    try std.testing.expect(r.next() == null);
}

test "a truncated dict is refused" {
    var b = Builder{};
    try b.push();
    try b.int(2);
    try b.string("only-key");
    b.pop();
    var top = Reader{ .data = b.buf[0..b.len] };
    var o = std.mem.zeroes(Object);
    defer o.deinit();
    try std.testing.expectError(error.Invalid, dictInto(&o, top.next().?));
    try std.testing.expectEqual(@as(usize, 0), o.n_props);
}

test "no socket means not found or refused" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "pw");
    var pb: [512]u8 = undefined;
    const r = snapshotAt(try sys.pathZ(&pb, "{s}/missing-0", .{root}));
    try std.testing.expect(std.meta.isError(r));
}
