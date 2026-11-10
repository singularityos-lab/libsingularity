const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const Kind = enum(u8) { call = 1, reply = 2, err = 3, signal = 4, _ };

pub const no_reply: u8 = 1;
const max_message = 64 << 20;
const max_array = 64 << 20;
const max_depth = 64;

fn alignOf(c: u8) usize {
    return switch (c) {
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

pub fn typeEnd(sig: []const u8, start: usize) !usize {
    return typeEndDepth(sig, start, 0);
}

fn typeEndDepth(sig: []const u8, start: usize, depth: usize) !usize {
    if (start >= sig.len or depth > max_depth) return error.Invalid;
    switch (sig[start]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g', 'v' => return start + 1,
        'a' => return typeEndDepth(sig, start + 1, depth + 1),
        '(' => {
            var i = start + 1;
            if (i < sig.len and sig[i] == ')') return error.Invalid;
            while (i < sig.len and sig[i] != ')') i = try typeEndDepth(sig, i, depth + 1);
            if (i >= sig.len) return error.Invalid;
            return i + 1;
        },
        '{' => {
            if (start == 0 or sig[start - 1] != 'a') return error.Invalid;
            switch (if (start + 1 < sig.len) sig[start + 1] else 0) {
                'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g' => {},
                else => return error.Invalid,
            }
            const i = try typeEndDepth(sig, try typeEndDepth(sig, start + 1, depth + 1), depth + 1);
            if (i >= sig.len or sig[i] != '}') return error.Invalid;
            return i + 1;
        },
        else => return error.Invalid,
    }
}

pub fn validSignature(sig: []const u8) bool {
    if (sig.len > 255) return false;
    var i: usize = 0;
    while (i < sig.len) i = typeEnd(sig, i) catch return false;
    return true;
}

pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,

    pub const Mark = struct { at: usize, start: usize };

    pub fn deinit(w: *Writer) void {
        w.buf.deinit(sys.gpa);
    }

    pub fn bytes(w: *const Writer) []const u8 {
        return w.buf.items;
    }

    fn pad(w: *Writer, n: usize) !void {
        while (w.buf.items.len % n != 0) try w.buf.append(sys.gpa, 0);
    }

    fn int(w: *Writer, comptime T: type, v: T) !void {
        try w.pad(@sizeOf(T));
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try w.buf.appendSlice(sys.gpa, &b);
    }

    pub fn byte(w: *Writer, v: u8) !void {
        try w.buf.append(sys.gpa, v);
    }

    pub fn boolean(w: *Writer, v: bool) !void {
        try w.int(u32, @intFromBool(v));
    }

    pub fn int16(w: *Writer, v: i16) !void {
        try w.int(i16, v);
    }

    pub fn uint16(w: *Writer, v: u16) !void {
        try w.int(u16, v);
    }

    pub fn int32(w: *Writer, v: i32) !void {
        try w.int(i32, v);
    }

    pub fn uint32(w: *Writer, v: u32) !void {
        try w.int(u32, v);
    }

    pub fn int64(w: *Writer, v: i64) !void {
        try w.int(i64, v);
    }

    pub fn uint64(w: *Writer, v: u64) !void {
        try w.int(u64, v);
    }

    pub fn double(w: *Writer, v: f64) !void {
        try w.int(u64, @bitCast(v));
    }

    pub fn string(w: *Writer, s: []const u8) !void {
        if (std.mem.indexOfScalar(u8, s, 0) != null or !std.unicode.utf8ValidateSlice(s)) return error.Invalid;
        try w.int(u32, @intCast(s.len));
        try w.buf.appendSlice(sys.gpa, s);
        try w.buf.append(sys.gpa, 0);
    }

    pub fn objectPath(w: *Writer, s: []const u8) !void {
        if (!validPath(s)) return error.Invalid;
        try w.string(s);
    }

    pub fn signature(w: *Writer, s: []const u8) !void {
        if (!validSignature(s)) return error.Invalid;
        try w.byte(@intCast(s.len));
        try w.buf.appendSlice(sys.gpa, s);
        try w.buf.append(sys.gpa, 0);
    }

    pub fn beginArray(w: *Writer, elem: u8) !Mark {
        try w.int(u32, 0);
        const at = w.buf.items.len - 4;
        try w.pad(alignOf(elem));
        return .{ .at = at, .start = w.buf.items.len };
    }

    pub fn endArray(w: *Writer, m: Mark) !void {
        const n = w.buf.items.len - m.start;
        if (n > max_array) return error.TooBig;
        std.mem.writeInt(u32, w.buf.items[m.at..][0..4], @intCast(n), .little);
    }

    pub fn beginStruct(w: *Writer) !void {
        try w.pad(8);
    }

    pub fn variant(w: *Writer, sig: []const u8) !void {
        if (typeEnd(sig, 0) catch 0 != sig.len) return error.Invalid;
        try w.signature(sig);
    }
};

pub fn pack(w: *Writer, comptime sig: []const u8, values: anytype) !void {
    const fields = @typeInfo(@TypeOf(values)).@"struct".fields;
    comptime if (fields.len != sig.len) @compileError("one basic type per value");
    inline for (fields, 0..) |f, i| {
        const v = @field(values, f.name);
        switch (sig[i]) {
            's' => try w.string(v),
            'o' => try w.objectPath(v),
            'g' => try w.signature(v),
            'b' => try w.boolean(v),
            'y' => try w.byte(v),
            'n' => try w.int16(v),
            'q' => try w.uint16(v),
            'i' => try w.int32(v),
            'u' => try w.uint32(v),
            'x' => try w.int64(v),
            't' => try w.uint64(v),
            'd' => try w.double(v),
            else => @compileError("pack takes basic types only"),
        }
    }
}

pub fn validPath(p: []const u8) bool {
    if (p.len == 0 or p[0] != '/') return false;
    if (p.len == 1) return true;
    if (p[p.len - 1] == '/') return false;
    var prev: u8 = '/';
    for (p[1..]) |c| {
        if (c == '/' and prev == '/') return false;
        if (c != '/' and !std.ascii.isAlphanumeric(c) and c != '_') return false;
        prev = c;
    }
    return true;
}

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    big: bool = false,

    fn pad(r: *Reader, n: usize) !void {
        const p = std.mem.alignForward(usize, r.pos, n);
        if (p > r.data.len) return error.Invalid;
        r.pos = p;
    }

    fn int(r: *Reader, comptime T: type) !T {
        try r.pad(@sizeOf(T));
        if (r.pos + @sizeOf(T) > r.data.len) return error.Invalid;
        const v = std.mem.readInt(T, r.data[r.pos..][0..@sizeOf(T)], if (r.big) .big else .little);
        r.pos += @sizeOf(T);
        return v;
    }

    pub fn done(r: *const Reader) bool {
        return r.pos >= r.data.len;
    }

    pub fn byte(r: *Reader) !u8 {
        if (r.pos >= r.data.len) return error.Invalid;
        r.pos += 1;
        return r.data[r.pos - 1];
    }

    pub fn boolean(r: *Reader) !bool {
        const v = try r.int(u32);
        if (v > 1) return error.Invalid;
        return v == 1;
    }

    pub fn int16(r: *Reader) !i16 {
        return r.int(i16);
    }

    pub fn uint16(r: *Reader) !u16 {
        return r.int(u16);
    }

    pub fn int32(r: *Reader) !i32 {
        return r.int(i32);
    }

    pub fn uint32(r: *Reader) !u32 {
        return r.int(u32);
    }

    pub fn int64(r: *Reader) !i64 {
        return r.int(i64);
    }

    pub fn uint64(r: *Reader) !u64 {
        return r.int(u64);
    }

    pub fn double(r: *Reader) !f64 {
        return @bitCast(try r.int(u64));
    }

    pub fn string(r: *Reader) ![]const u8 {
        const n = try r.int(u32);
        if (n > r.data.len or r.pos + n + 1 > r.data.len or r.data[r.pos + n] != 0) return error.Invalid;
        const s = r.data[r.pos .. r.pos + n];
        r.pos += n + 1;
        return s;
    }

    pub fn signature(r: *Reader) ![]const u8 {
        const n = try r.byte();
        if (r.pos + n + 1 > r.data.len or r.data[r.pos + n] != 0) return error.Invalid;
        const s = r.data[r.pos .. r.pos + n];
        r.pos += n + 1;
        if (!validSignature(s)) return error.Invalid;
        return s;
    }

    pub fn array(r: *Reader, elem: u8) !usize {
        const n = try r.int(u32);
        if (n > max_array) return error.TooBig;
        try r.pad(alignOf(elem));
        const end = r.pos + n;
        if (end > r.data.len) return error.Invalid;
        return end;
    }

    pub fn structure(r: *Reader) !void {
        try r.pad(8);
    }

    pub fn variant(r: *Reader) ![]const u8 {
        const s = try r.signature();
        if (typeEnd(s, 0) catch 0 != s.len) return error.Invalid;
        return s;
    }

    pub fn skip(r: *Reader, sig: []const u8) !void {
        var i: usize = 0;
        while (i < sig.len) i = try r.skipOne(sig, i, 0);
    }

    fn skipOne(r: *Reader, sig: []const u8, i: usize, depth: usize) !usize {
        if (depth > max_depth or i >= sig.len) return error.Invalid;
        switch (sig[i]) {
            'y' => _ = try r.byte(),
            'b', 'i', 'u', 'h' => _ = try r.int(u32),
            'n', 'q' => _ = try r.int(u16),
            'x', 't', 'd' => _ = try r.int(u64),
            's', 'o' => _ = try r.string(),
            'g' => _ = try r.signature(),
            'v' => {
                const s = try r.variant();
                var j: usize = 0;
                while (j < s.len) j = try r.skipOne(s, j, depth + 1);
            },
            'a' => {
                const e = try typeEnd(sig, i + 1);
                const end = try r.array(sig[i + 1]);
                while (r.pos < end) {
                    const before = r.pos;
                    _ = try r.skipOne(sig[0..e], i + 1, depth + 1);
                    if (r.pos == before) return error.Invalid;
                }
                if (r.pos != end) return error.Invalid;
                return e;
            },
            '(' => {
                try r.pad(8);
                var j = i + 1;
                while (j < sig.len and sig[j] != ')') j = try r.skipOne(sig, j, depth + 1);
                return j + 1;
            },
            '{' => {
                try r.pad(8);
                var j = try r.skipOne(sig, i + 1, depth + 1);
                j = try r.skipOne(sig, j, depth + 1);
                return j + 1;
            },
            else => return error.Invalid,
        }
        return i + 1;
    }
};

pub const Message = struct {
    raw: []u8,
    kind: Kind,
    flags: u8,
    serial: u32,
    reply_serial: u32 = 0,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    destination: []const u8 = "",
    sender: []const u8 = "",
    signature: []const u8 = "",
    body_at: usize = 0,
    big: bool = false,

    pub fn deinit(m: *Message) void {
        sys.gpa.free(m.raw);
    }

    pub fn reader(m: *const Message) Reader {
        return .{ .data = m.raw[m.body_at..], .big = m.big };
    }

    pub fn text(m: *const Message) []const u8 {
        if (m.signature.len == 0 or m.signature[0] != 's') return "";
        var r = m.reader();
        return r.string() catch "";
    }
};

fn frameLen(head: []const u8) !usize {
    const big = switch (head[0]) {
        'l' => false,
        'B' => true,
        else => return error.Invalid,
    };
    if (head[3] != 1) return error.Unsupported;
    const order: std.builtin.Endian = if (big) .big else .little;
    const body = std.mem.readInt(u32, head[4..8], order);
    const fields = std.mem.readInt(u32, head[12..16], order);
    if (body > max_message or fields > max_message) return error.TooBig;
    const total = 16 + std.mem.alignForward(usize, fields, 8) + body;
    if (total > max_message) return error.TooBig;
    return total;
}

pub fn parse(raw: []u8) !Message {
    if (raw.len < 16 or try frameLen(raw[0..16]) != raw.len) return error.Invalid;
    const big = raw[0] == 'B';
    var m = Message{
        .raw = raw,
        .kind = @enumFromInt(raw[1]),
        .flags = raw[2],
        .serial = std.mem.readInt(u32, raw[8..12], if (big) .big else .little),
        .big = big,
    };
    if (m.serial == 0) return error.Invalid;
    var r = Reader{ .data = raw, .pos = 12, .big = big };
    const end = try r.array('(');
    while (r.pos < end) {
        try r.structure();
        const code = try r.byte();
        const sig = try r.variant();
        const want: []const u8 = switch (code) {
            1 => "o",
            2, 3, 4, 6, 7 => "s",
            5 => "u",
            8 => "g",
            else => {
                try r.skip(sig);
                continue;
            },
        };
        if (!std.mem.eql(u8, sig, want)) return error.Invalid;
        switch (code) {
            1 => m.path = try r.string(),
            2 => m.interface = try r.string(),
            3 => m.member = try r.string(),
            4 => m.error_name = try r.string(),
            5 => m.reply_serial = try r.uint32(),
            6 => m.destination = try r.string(),
            7 => m.sender = try r.string(),
            8 => m.signature = try r.signature(),
            else => unreachable,
        }
    }
    if (r.pos != end) return error.Invalid;
    m.body_at = std.mem.alignForward(usize, end, 8);
    if (m.body_at > raw.len) return error.Invalid;
    switch (m.kind) {
        .call => if (m.path.len == 0 or m.member.len == 0) return error.Invalid,
        .signal => if (m.path.len == 0 or m.member.len == 0 or m.interface.len == 0) return error.Invalid,
        .reply => if (m.reply_serial == 0) return error.Invalid,
        .err => if (m.reply_serial == 0 or m.error_name.len == 0) return error.Invalid,
        _ => {},
    }
    if (m.signature.len == 0 and m.body_at != raw.len) return error.Invalid;
    return m;
}

pub const Header = struct {
    kind: Kind,
    flags: u8 = 0,
    serial: u32,
    reply_serial: u32 = 0,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    destination: []const u8 = "",
    signature: []const u8 = "",
};

fn field(w: *Writer, code: u8, sig: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try w.beginStruct();
    try w.byte(code);
    try w.signature(sig);
    switch (sig[0]) {
        'o' => try w.objectPath(value),
        'g' => try w.signature(value),
        else => try w.string(value),
    }
}

pub fn build(h: Header, body: []const u8) ![]u8 {
    if (body.len > 0 and h.signature.len == 0) return error.Invalid;
    var w = Writer{};
    errdefer w.deinit();
    try w.byte('l');
    try w.byte(@intFromEnum(h.kind));
    try w.byte(h.flags);
    try w.byte(1);
    try w.uint32(@intCast(body.len));
    try w.uint32(h.serial);
    const m = try w.beginArray('(');
    try field(&w, 1, "o", h.path);
    try field(&w, 2, "s", h.interface);
    try field(&w, 3, "s", h.member);
    try field(&w, 4, "s", h.error_name);
    if (h.reply_serial != 0) {
        try w.beginStruct();
        try w.byte(5);
        try w.signature("u");
        try w.uint32(h.reply_serial);
    }
    try field(&w, 6, "s", h.destination);
    try field(&w, 8, "g", h.signature);
    try w.endArray(m);
    try w.pad(8);
    try w.buf.appendSlice(sys.gpa, body);
    if (w.buf.items.len > max_message) return error.TooBig;
    return w.buf.toOwnedSlice(sys.gpa);
}

pub fn remoteError(name: []const u8) sys.Error {
    const last = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| name[i + 1 ..] else name;
    const table = [_]struct { []const u8, sys.Error }{
        .{ "ServiceUnknown", error.NotFound },
        .{ "NameHasNoOwner", error.NotFound },
        .{ "UnknownMethod", error.NotFound },
        .{ "UnknownObject", error.NotFound },
        .{ "UnknownInterface", error.NotFound },
        .{ "UnknownProperty", error.NotFound },
        .{ "FileNotFound", error.NotFound },
        .{ "DoesNotExist", error.NotFound },
        .{ "NotAvailable", error.NotFound },
        .{ "AccessDenied", error.Access },
        .{ "AuthFailed", error.Access },
        .{ "NotAuthorized", error.Access },
        .{ "AuthenticationFailed", error.Access },
        .{ "AuthenticationRejected", error.Access },
        .{ "AuthenticationCanceled", error.Access },
        .{ "InteractiveAuthorizationRequired", error.Access },
        .{ "NotSupported", error.Unsupported },
        .{ "InvalidArgs", error.Invalid },
        .{ "InvalidArguments", error.Invalid },
        .{ "InvalidSignature", error.Invalid },
        .{ "PropertyReadOnly", error.Access },
        .{ "NoReply", error.Again },
        .{ "Timeout", error.Again },
        .{ "TimedOut", error.Again },
        .{ "NotReady", error.Again },
        .{ "InProgress", error.Busy },
        .{ "Busy", error.Busy },
        .{ "AlreadyExists", error.Exists },
        .{ "AlreadyConnected", error.Exists },
        .{ "LimitsExceeded", error.NoMemory },
        .{ "NoMemory", error.NoMemory },
    };
    for (table) |t| if (std.mem.eql(u8, last, t[0])) return t[1];
    return error.Io;
}

pub fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn unescape(out: []u8, s: []const u8) ![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (n >= out.len) return error.TooBig;
        if (s[i] == '%') {
            if (i + 3 > s.len) return error.Invalid;
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.Invalid;
            i += 3;
        } else {
            out[n] = s[i];
            i += 1;
        }
    }
    return out[0..n];
}

fn connectOne(address: []const u8) !i32 {
    if (!std.mem.startsWith(u8, address, "unix:")) return error.Unsupported;
    var addr = linux.sockaddr.un{ .path = [_]u8{0} ** 108 };
    var len: ?usize = null;
    var it = std.mem.splitScalar(u8, address[5..], ',');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.Invalid;
        const key = kv[0..eq];
        const abstract = std.mem.eql(u8, key, "abstract");
        if (!abstract and !std.mem.eql(u8, key, "path")) continue;
        const start: usize = @intFromBool(abstract);
        const name = try unescape(addr.path[start .. addr.path.len - 1], kv[eq + 1 ..]);
        if (name.len == 0) return error.Invalid;
        len = @offsetOf(linux.sockaddr.un, "path") + start + name.len + @intFromBool(!abstract);
    }
    const addr_len = len orelse return error.Unsupported;
    const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer sys.close(fd);
    while (true) {
        const rc = linux.connect(fd, @ptrCast(&addr), @intCast(addr_len));
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return sys.fromErrno(e);
        break;
    }
    return fd;
}

pub const Conn = struct {
    fd: i32,
    serial: u32 = 0,
    unique: [96]u8 = [_]u8{0} ** 96,
    last_error: [256]u8 = [_]u8{0} ** 256,
    rbuf: std.ArrayList(u8) = .empty,
    queue: std.ArrayList(Message) = .empty,

    pub fn system() !Conn {
        if (std.c.getenv("DBUS_SYSTEM_BUS_ADDRESS")) |a| return open(std.mem.span(a));
        return open("unix:path=/run/dbus/system_bus_socket");
    }

    pub fn session() !Conn {
        if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS")) |a| return open(std.mem.span(a));
        const dir = std.c.getenv("XDG_RUNTIME_DIR") orelse return error.NotFound;
        var b: [300]u8 = undefined;
        const addr = std.fmt.bufPrint(&b, "unix:path={s}/bus", .{std.mem.span(dir)}) catch return error.TooBig;
        return open(addr);
    }

    pub fn open(address: []const u8) !Conn {
        var last: anyerror = error.NotFound;
        var it = std.mem.splitScalar(u8, address, ';');
        while (it.next()) |one| {
            if (one.len == 0) continue;
            const fd = connectOne(one) catch |e| {
                last = e;
                continue;
            };
            var c = Conn{ .fd = fd };
            c.handshake() catch |e| {
                c.close();
                return e;
            };
            return c;
        }
        return last;
    }

    pub fn close(c: *Conn) void {
        sys.close(c.fd);
        for (c.queue.items) |*m| m.deinit();
        c.queue.deinit(sys.gpa);
        c.rbuf.deinit(sys.gpa);
        c.fd = -1;
    }

    pub fn uniqueName(c: *const Conn) []const u8 {
        return sys.cstr(&c.unique);
    }

    pub fn lastError(c: *const Conn) []const u8 {
        return sys.cstr(&c.last_error);
    }

    fn wait(c: *Conn, timeout_ms: i64) !bool {
        var p = [_]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 }};
        while (true) {
            const rc = linux.poll(&p, 1, @intCast(@max(timeout_ms, 0)));
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return sys.fromErrno(e);
            return rc > 0;
        }
    }

    fn fill(c: *Conn, timeout_ms: i64) !bool {
        if (!try c.wait(timeout_ms)) return false;
        var tmp: [65536]u8 = undefined;
        const n = try sys.read(c.fd, &tmp);
        if (n == 0) return error.Io;
        try c.rbuf.appendSlice(sys.gpa, tmp[0..n]);
        return true;
    }

    fn handshake(c: *Conn) !void {
        var dec: [16]u8 = undefined;
        const uid = std.fmt.bufPrint(&dec, "{d}", .{linux.getuid()}) catch unreachable;
        var line: [64]u8 = undefined;
        var n: usize = 0;
        const head = "\x00AUTH EXTERNAL ";
        @memcpy(line[0..head.len], head);
        n = head.len;
        for (uid) |ch| {
            _ = std.fmt.bufPrint(line[n..][0..2], "{x:0>2}", .{ch}) catch unreachable;
            n += 2;
        }
        @memcpy(line[n..][0..2], "\r\n");
        n += 2;
        try sys.writeAll(c.fd, line[0..n]);
        const deadline = nowMs() + 5000;
        while (std.mem.indexOf(u8, c.rbuf.items, "\r\n") == null) {
            if (c.rbuf.items.len > 512) return error.Invalid;
            if (!try c.fill(deadline - nowMs())) return error.Again;
        }
        const end = std.mem.indexOf(u8, c.rbuf.items, "\r\n").?;
        const ok = std.mem.startsWith(u8, c.rbuf.items[0..end], "OK ");
        c.rbuf.replaceRange(sys.gpa, 0, end + 2, &.{}) catch unreachable;
        if (!ok) return error.Access;
        try sys.writeAll(c.fd, "BEGIN\r\n");
        var hello = try c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", "", 5000);
        defer hello.deinit();
        var r = hello.reader();
        sys.copyName(&c.unique, try r.string());
    }

    pub fn send(c: *Conn, h: Header, body: []const u8) !u32 {
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        var hh = h;
        hh.serial = c.serial;
        const raw = try build(hh, body);
        defer sys.gpa.free(raw);
        try sys.writeAll(c.fd, raw);
        return c.serial;
    }

    fn receive(c: *Conn, timeout_ms: i64) !?Message {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (c.rbuf.items.len >= 16) {
                const total = try frameLen(c.rbuf.items[0..16]);
                if (c.rbuf.items.len >= total) {
                    const raw = try sys.gpa.dupe(u8, c.rbuf.items[0..total]);
                    c.rbuf.replaceRange(sys.gpa, 0, total, &.{}) catch unreachable;
                    return parse(raw) catch |e| {
                        sys.gpa.free(raw);
                        return e;
                    };
                }
            }
            if (!try c.fill(deadline - nowMs())) return null;
        }
    }

    pub fn next(c: *Conn, timeout_ms: i64) !?Message {
        if (c.queue.items.len > 0) return c.queue.orderedRemove(0);
        return c.receive(timeout_ms);
    }

    pub fn waitSignal(c: *Conn, iface: []const u8, member: []const u8, timeout_ms: i64) !?Message {
        for (c.queue.items, 0..) |m, i| {
            if (m.kind == .signal and std.mem.eql(u8, m.interface, iface) and std.mem.eql(u8, m.member, member)) return c.queue.orderedRemove(i);
        }
        const deadline = nowMs() + timeout_ms;
        while (true) {
            var m = (try c.receive(deadline - nowMs())) orelse return null;
            if (m.kind == .signal and std.mem.eql(u8, m.interface, iface) and std.mem.eql(u8, m.member, member)) return m;
            c.queue.append(sys.gpa, m) catch |e| {
                m.deinit();
                return e;
            };
        }
    }

    pub fn call(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8, timeout_ms: i64) !Message {
        const serial = try c.send(.{ .kind = .call, .serial = 0, .destination = dest, .path = path, .interface = iface, .member = member, .signature = sig }, body);
        const deadline = nowMs() + timeout_ms;
        while (true) {
            var m = (try c.receive(deadline - nowMs())) orelse return error.Again;
            if ((m.kind == .reply or m.kind == .err) and m.reply_serial == serial) {
                if (m.kind == .reply) return m;
                defer m.deinit();
                var b: [256]u8 = undefined;
                const t = m.text();
                const msg = std.fmt.bufPrint(&b, "{s}: {s}", .{ m.error_name, t[0..@min(t.len, 160)] }) catch m.error_name;
                sys.copyName(&c.last_error, msg);
                return remoteError(m.error_name);
            }
            c.queue.append(sys.gpa, m) catch |e| {
                m.deinit();
                return e;
            };
        }
    }

    pub fn callWith(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, comptime sig: []const u8, values: anytype) !Message {
        var w = Writer{};
        defer w.deinit();
        try pack(&w, sig, values);
        return c.call(dest, path, iface, member, sig, w.bytes(), 25000);
    }

    pub fn emit(c: *Conn, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !void {
        _ = try c.send(.{ .kind = .signal, .serial = 0, .path = path, .interface = iface, .member = member, .signature = sig }, body);
    }

    pub fn addMatch(c: *Conn, rule: []const u8) !void {
        var m = try c.callWith("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", .{rule});
        m.deinit();
    }

    pub fn getProperty(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, name: []const u8) !Message {
        return c.callWith(dest, path, iface_props, "Get", "ss", .{ iface, name });
    }

    pub fn setProperty(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, name: []const u8, comptime sig: []const u8, value: anytype) !void {
        var w = Writer{};
        defer w.deinit();
        try w.string(iface);
        try w.string(name);
        try w.variant(sig);
        try pack(&w, sig, .{value});
        var m = try c.call(dest, path, iface_props, "Set", "ssv", w.bytes(), 25000);
        m.deinit();
    }

    pub fn nameHasOwner(c: *Conn, name: []const u8) !bool {
        var m = try c.callWith("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", .{name});
        defer m.deinit();
        var r = m.reader();
        return r.boolean();
    }

    pub fn requestName(c: *Conn, name: []const u8) !void {
        var m = try c.callWith("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su", .{ name, @as(u32, 4) });
        defer m.deinit();
        var r = m.reader();
        const v = try r.uint32();
        if (v != 1 and v != 4) return error.Exists;
    }

    pub fn reply(c: *Conn, to: *const Message, sig: []const u8, body: []const u8) !void {
        if (to.flags & no_reply != 0) return;
        _ = try c.send(.{ .kind = .reply, .serial = 0, .reply_serial = to.serial, .destination = to.sender, .signature = sig }, body);
    }

    pub fn replyError(c: *Conn, to: *const Message, name: []const u8, text: []const u8) !void {
        if (to.flags & no_reply != 0) return;
        var w = Writer{};
        defer w.deinit();
        try w.string(text);
        _ = try c.send(.{ .kind = .err, .serial = 0, .reply_serial = to.serial, .destination = to.sender, .error_name = name, .signature = "s" }, w.bytes());
    }
};

pub const iface_props = "org.freedesktop.DBus.Properties";
pub const iface_objects = "org.freedesktop.DBus.ObjectManager";

test "signatures split into complete types" {
    try std.testing.expectEqual(@as(usize, 5), try typeEnd("a{sv}", 0));
    try std.testing.expectEqual(@as(usize, 7), try typeEnd("(ia(s))x", 0));
    try std.testing.expect(validSignature("sa{sv}x(ib)dao"));
    for ([_][]const u8{ "a", "(i", "a{ss", "{ss}", "a{vs}", "()", "z", "a{s}" }) |bad| try std.testing.expect(!validSignature(bad));
}

test "bodies round trip through the reader" {
    var w = Writer{};
    defer w.deinit();
    try w.byte(7);
    try w.string("héllo");
    const m = try w.beginArray('{');
    try w.beginStruct();
    try w.string("count");
    try w.variant("x");
    try w.int64(-5);
    try w.beginStruct();
    try w.string("pair");
    try w.variant("(ib)");
    try w.beginStruct();
    try w.int32(42);
    try w.boolean(true);
    try w.beginStruct();
    try w.string("list");
    try w.variant("as");
    const inner = try w.beginArray('s');
    try w.string("a");
    try w.string("bc");
    try w.endArray(inner);
    try w.endArray(m);
    try w.double(2.5);
    try w.objectPath("/org/bluez/hci0");
    try std.testing.expectError(error.Invalid, w.objectPath("/bad//path"));
    try std.testing.expectError(error.Invalid, w.string("nul\x00inside"));

    var r = Reader{ .data = w.bytes() };
    try std.testing.expectEqual(@as(u8, 7), try r.byte());
    try std.testing.expectEqualStrings("héllo", try r.string());
    const end = try r.array('{');
    var seen: usize = 0;
    while (r.pos < end) : (seen += 1) {
        try r.structure();
        const key = try r.string();
        const sig = try r.variant();
        if (std.mem.eql(u8, key, "count")) {
            try std.testing.expectEqualStrings("x", sig);
            try std.testing.expectEqual(@as(i64, -5), try r.int64());
        } else if (std.mem.eql(u8, key, "pair")) {
            try r.structure();
            try std.testing.expectEqual(@as(i32, 42), try r.int32());
            try std.testing.expect(try r.boolean());
        } else {
            try r.skip(sig);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqual(@as(f64, 2.5), try r.double());
    try std.testing.expectEqualStrings("/org/bluez/hci0", try r.string());
    try std.testing.expect(r.done());

    var s = Reader{ .data = w.bytes() };
    try s.skip("ysa{sv}do");
    try std.testing.expect(s.done());
    var short = Reader{ .data = w.bytes()[0 .. w.bytes().len - 3] };
    try std.testing.expectError(error.Invalid, short.skip("ysa{sv}do"));
}

test "headers parse what build writes" {
    var w = Writer{};
    defer w.deinit();
    try pack(&w, "su", .{ "org.example.Name", @as(u32, 4) });
    const raw = try build(.{ .kind = .call, .serial = 9, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "RequestName", .signature = "su" }, w.bytes());
    var m = try parse(raw);
    defer m.deinit();
    try std.testing.expectEqual(Kind.call, m.kind);
    try std.testing.expectEqual(@as(u32, 9), m.serial);
    try std.testing.expectEqualStrings("RequestName", m.member);
    try std.testing.expectEqualStrings("/org/freedesktop/DBus", m.path);
    try std.testing.expectEqualStrings("su", m.signature);
    try std.testing.expectEqual(@as(usize, 0), m.body_at % 8);
    var r = m.reader();
    try std.testing.expectEqualStrings("org.example.Name", try r.string());
    try std.testing.expectEqual(@as(u32, 4), try r.uint32());
    const bad = try sys.gpa.dupe(u8, raw[0 .. raw.len - 1]);
    defer sys.gpa.free(bad);
    try std.testing.expectError(error.Invalid, parse(bad));
}

test "remote error names map to core errors" {
    try std.testing.expectEqual(error.NotFound, remoteError("org.freedesktop.DBus.Error.ServiceUnknown"));
    try std.testing.expectEqual(error.Busy, remoteError("org.bluez.Error.InProgress"));
    try std.testing.expectEqual(error.Access, remoteError("org.freedesktop.DBus.Error.AccessDenied"));
    try std.testing.expectEqual(error.Io, remoteError("org.bluez.Error.Failed"));
}

test "a real bus daemon accepts our messages" {
    const addr = std.c.getenv("SINTY_BUS_ADDRESS") orelse return error.SkipZigTest;
    var a = try Conn.open(std.mem.span(addr));
    defer a.close();
    var b = try Conn.open(std.mem.span(addr));
    defer b.close();
    try std.testing.expect(std.mem.startsWith(u8, a.uniqueName(), ":"));
    try std.testing.expect(!std.mem.eql(u8, a.uniqueName(), b.uniqueName()));

    var id = try a.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId", "", "", 5000);
    defer id.deinit();
    var ir = id.reader();
    try std.testing.expectEqual(@as(usize, 32), (try ir.string()).len);

    var names = try a.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", "", "", 5000);
    defer names.deinit();
    var nr = names.reader();
    const end = try nr.array('s');
    var found: usize = 0;
    while (nr.pos < end) {
        const n = try nr.string();
        if (std.mem.eql(u8, n, "org.freedesktop.DBus") or std.mem.eql(u8, n, b.uniqueName())) found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found);

    var cred = try a.callWith("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionCredentials", "s", .{b.uniqueName()});
    defer cred.deinit();
    try std.testing.expectEqualStrings("a{sv}", cred.signature);
    var cr = cred.reader();
    const cend = try cr.array('{');
    var pid: ?u32 = null;
    var uid: ?u32 = null;
    while (cr.pos < cend) {
        try cr.structure();
        const key = try cr.string();
        const sig = try cr.variant();
        if (std.mem.eql(u8, key, "ProcessID")) {
            pid = try cr.uint32();
        } else if (std.mem.eql(u8, key, "UnixUserID")) {
            uid = try cr.uint32();
        } else try cr.skip(sig);
    }
    try std.testing.expect(cr.done());
    try std.testing.expectEqual(@as(?u32, @intCast(linux.getpid())), pid);
    try std.testing.expectEqual(@as(?u32, linux.getuid()), uid);

    try std.testing.expect(!try a.nameHasOwner("org.sinty.Nobody"));
    try std.testing.expectError(error.NotFound, a.callWith("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", .{"org.sinty.Nobody"}));
    try std.testing.expect(std.mem.indexOf(u8, a.lastError(), "NameHasNoOwner") != null);
    try std.testing.expectError(error.NotFound, a.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NoSuchMethod", "", "", 5000));

    var rule: [256]u8 = undefined;
    try a.addMatch(try std.fmt.bufPrint(&rule, "type='signal',sender='{s}',interface='org.sinty.Test'", .{b.uniqueName()}));
    var w = Writer{};
    defer w.deinit();
    try w.string("ping");
    const m = try w.beginArray('{');
    try w.beginStruct();
    try w.string("level");
    try w.variant("d");
    try w.double(0.75);
    try w.beginStruct();
    try w.string("tags");
    try w.variant("as");
    const t = try w.beginArray('s');
    try w.string("x");
    try w.endArray(t);
    try w.endArray(m);
    try w.int64(-9);
    try w.beginStruct();
    try w.int32(3);
    try w.boolean(false);
    try b.emit("/org/sinty/Test", "org.sinty.Test", "Changed", "sa{sv}x(ib)", w.bytes());

    var got = (try a.waitSignal("org.sinty.Test", "Changed", 5000)) orelse return error.TestUnexpectedResult;
    defer got.deinit();
    try std.testing.expectEqual(Kind.signal, got.kind);
    try std.testing.expectEqualStrings("Changed", got.member);
    try std.testing.expectEqualStrings(b.uniqueName(), got.sender);
    try std.testing.expectEqualStrings("sa{sv}x(ib)", got.signature);
    var gr = got.reader();
    try std.testing.expectEqualStrings("ping", try gr.string());
    try gr.skip("a{sv}");
    try std.testing.expectEqual(@as(i64, -9), try gr.int64());
    try gr.structure();
    try std.testing.expectEqual(@as(i32, 3), try gr.int32());
    try std.testing.expect(!try gr.boolean());
    try std.testing.expect(gr.done());

    try std.testing.expectError(error.Invalid, Conn.open("unix:path="));
    try std.testing.expectError(error.Unsupported, Conn.open("tcp:host=localhost,port=1"));
}
