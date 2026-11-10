const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const Entry = extern struct {
    realtime_usec: u64,
    monotonic_usec: u64,
    seq: u64,
    pid: i32,
    priority: u8,
    pad: [3]u8,
    boot_id: [40]u8,
    identifier: [64]u8,
    unit: [128]u8,
    message: [2048]u8,
};

pub const Boot = extern struct {
    id: [40]u8,
    first_usec: u64,
    last_usec: u64,
    entries: u64,
};

pub const Entries = sys.List(Entry);
pub const Boots = sys.List(Boot);

fn clockUsec(id: linux.CLOCK) u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(id, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

fn bootRealtime() u64 {
    return clockUsec(.REALTIME) -| clockUsec(.MONOTONIC);
}

fn copyText(dst: []u8, src: []const u8) void {
    var n = @min(dst.len - 1, src.len);
    while (n > 0 and n < src.len and (src[n] & 0xc0) == 0x80) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

pub fn parseKmsg(rec: []const u8, e: *Entry) bool {
    const semi = std.mem.indexOfScalar(u8, rec, ';') orelse return false;
    var it = std.mem.splitScalar(u8, rec[0..semi], ',');
    const pri = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    const seq = std.fmt.parseInt(u64, it.next() orelse return false, 10) catch return false;
    const usec = std.fmt.parseInt(u64, it.next() orelse return false, 10) catch return false;
    const body = rec[semi + 1 ..];
    const nl = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    e.* = std.mem.zeroes(Entry);
    e.priority = @intCast(pri & 7);
    e.seq = seq;
    e.monotonic_usec = usec;
    e.pid = -1;
    sys.copyName(&e.identifier, "kernel");
    copyText(&e.message, body[0..nl]);
    return true;
}

pub fn parseDmesgLine(line: []const u8, e: *Entry) bool {
    var rest = std.mem.trimEnd(u8, line, "\r\n");
    if (rest.len == 0) return false;
    e.* = std.mem.zeroes(Entry);
    e.priority = 6;
    e.pid = -1;
    if (rest[0] == '<') {
        const close = std.mem.indexOfScalar(u8, rest, '>') orelse return false;
        const raw = std.fmt.parseInt(u32, rest[1..close], 10) catch return false;
        e.priority = @intCast(raw & 7);
        rest = rest[close + 1 ..];
    }
    if (rest.len > 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return false;
        const stamp = std.mem.trim(u8, rest[1..close], " ");
        const dot = std.mem.indexOfScalar(u8, stamp, '.') orelse stamp.len;
        const secs = std.fmt.parseInt(u64, stamp[0..dot], 10) catch return false;
        var frac: u64 = 0;
        if (dot < stamp.len) {
            const digits = stamp[dot + 1 ..];
            frac = std.fmt.parseInt(u64, digits, 10) catch return false;
            var k = digits.len;
            while (k < 6) : (k += 1) frac *= 10;
            while (k > 6) : (k -= 1) frac /= 10;
        }
        e.monotonic_usec = secs * 1_000_000 + frac;
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " ");
    }
    sys.copyName(&e.identifier, "kernel");
    copyText(&e.message, rest);
    return true;
}

pub fn kernel(mirror: [*:0]const u8) !*Entries {
    const list = try Entries.create();
    errdefer list.destroy();
    const base = bootRealtime();
    if (sys.open("/dev/kmsg", .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0)) |fd| {
        defer sys.close(fd);
        var buf: [8192]u8 = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => break,
                .PIPE, .INTR => continue,
                .PERM, .ACCES => return kernelMirror(list, mirror, base),
                else => |e| return sys.fromErrno(e),
            }
            if (rc == 0) break;
            var e: Entry = undefined;
            if (!parseKmsg(buf[0..rc], &e)) continue;
            e.realtime_usec = base + e.monotonic_usec;
            try list.append(e);
        }
        return list;
    } else |err| switch (err) {
        error.Access, error.NotFound => return kernelMirror(list, mirror, base),
        else => return err,
    }
}

fn kernelMirror(list: *Entries, path: [*:0]const u8, base: u64) !*Entries {
    const data = try sys.readAlloc(sys.gpa, path, 64 << 20);
    defer sys.gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    var seq: u64 = 0;
    while (it.next()) |line| {
        var e: Entry = undefined;
        if (!parseDmesgLine(line, &e)) continue;
        e.realtime_usec = base + e.monotonic_usec;
        e.seq = seq;
        seq += 1;
        try list.append(e);
    }
    return list;
}

const flag_xz = 1;
const flag_lz4 = 2;
const flag_zstd = 4;
const incompat_known: u32 = 0x1f;
const incompat_compact: u32 = 16;

pub const Journal = struct {
    map: []align(std.heap.page_size_min) const u8,
    compact: bool,
    end: usize,

    pub fn open(path: [*:0]const u8) !Journal {
        const fd = try sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        defer sys.close(fd);
        const size_rc = linux.lseek(fd, 0, linux.SEEK.END);
        const size = try sys.check(size_rc);
        if (size < 240) return error.Invalid;
        if (size > 4 << 30) return error.TooBig;
        const addr = try sys.check(linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0));
        const map: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(addr);
        var j = Journal{ .map = map[0..size], .compact = false, .end = size };
        errdefer j.close();
        if (!std.mem.eql(u8, j.map[0..8], "LPKSHHRH")) return error.Invalid;
        const incompat = std.mem.readInt(u32, j.map[12..16], .little);
        if (incompat & ~incompat_known != 0) return error.Unsupported;
        j.compact = incompat & incompat_compact != 0;
        const header = try j.u64At(88);
        const arena = try j.u64At(96);
        if (header < 208 or header > size) return error.Invalid;
        j.end = @intCast(@min(size, header +| arena));
        return j;
    }

    pub fn close(j: *Journal) void {
        _ = linux.munmap(j.map.ptr, j.map.len);
    }

    fn u64At(j: *const Journal, off: u64) !u64 {
        if (off > j.map.len or j.map.len - off < 8) return error.Invalid;
        const o: usize = @intCast(off);
        return std.mem.readInt(u64, j.map[o..][0..8], .little);
    }

    fn u32At(j: *const Journal, off: u64) !u32 {
        if (off > j.map.len or j.map.len - off < 4) return error.Invalid;
        const o: usize = @intCast(off);
        return std.mem.readInt(u32, j.map[o..][0..4], .little);
    }

    const Object = struct { flags: u8, bytes: []const u8 };

    fn object(j: *const Journal, off: u64, kind: u8) !Object {
        if (off == 0 or off % 8 != 0 or off > j.end or j.end - off < 16) return error.Invalid;
        const o: usize = @intCast(off);
        if (j.map[o] != kind) return error.Invalid;
        const size = try j.u64At(off + 8);
        if (size < 16 or size > j.end - o) return error.Invalid;
        return .{ .flags = j.map[o + 1], .bytes = j.map[o .. o + @as(usize, @intCast(size))] };
    }

    pub const Iterator = struct {
        j: *const Journal,
        array: u64,
        index: usize = 0,
        hops: usize = 0,

        pub fn next(it: *Iterator) !?u64 {
            while (it.array != 0) {
                const a = try it.j.object(it.array, 6);
                const item: usize = if (it.j.compact) 4 else 8;
                const n = (a.bytes.len - 24) / item;
                if (it.index < n) {
                    const at = 24 + it.index * item;
                    it.index += 1;
                    const v: u64 = if (it.j.compact) std.mem.readInt(u32, a.bytes[at..][0..4], .little) else std.mem.readInt(u64, a.bytes[at..][0..8], .little);
                    if (v == 0) {
                        it.array = 0;
                        return null;
                    }
                    return v;
                }
                it.hops += 1;
                if (it.hops > 1 << 24) return error.Invalid;
                it.array = std.mem.readInt(u64, a.bytes[16..24], .little);
                it.index = 0;
            }
            return null;
        }
    };

    pub fn iterator(j: *const Journal) !Iterator {
        return .{ .j = j, .array = try j.u64At(176) };
    }

    pub fn entries(j: *const Journal) !u64 {
        return j.u64At(152);
    }

    pub const Head = struct { seq: u64, realtime: u64, monotonic: u64, boot: [16]u8 };

    pub fn head(j: *const Journal, off: u64) !Head {
        const e = try j.object(off, 3);
        if (e.bytes.len < 64) return error.Invalid;
        return .{
            .seq = std.mem.readInt(u64, e.bytes[16..24], .little),
            .realtime = std.mem.readInt(u64, e.bytes[24..32], .little),
            .monotonic = std.mem.readInt(u64, e.bytes[32..40], .little),
            .boot = e.bytes[40..56].*,
        };
    }

    pub fn fill(j: *const Journal, off: u64, out: *Entry, scratch: *std.ArrayList(u8)) !void {
        const h = try j.head(off);
        const e = try j.object(off, 3);
        out.* = std.mem.zeroes(Entry);
        out.seq = h.seq;
        out.realtime_usec = h.realtime;
        out.monotonic_usec = h.monotonic;
        out.priority = 6;
        out.pid = -1;
        hex(&out.boot_id, &h.boot);
        const item: usize = if (j.compact) 4 else 16;
        const n = (e.bytes.len - 64) / item;
        var has_ident = false;
        var has_user_unit = false;
        for (0..n) |i| {
            const at = 64 + i * item;
            const doff: u64 = if (j.compact) std.mem.readInt(u32, e.bytes[at..][0..4], .little) else std.mem.readInt(u64, e.bytes[at..][0..8], .little);
            const d = j.object(doff, 1) catch continue;
            const payload_at: usize = if (j.compact) 72 else 64;
            if (d.bytes.len < payload_at) continue;
            var payload = d.bytes[payload_at..];
            if (d.flags & (flag_xz | flag_lz4 | flag_zstd) != 0) {
                scratch.clearRetainingCapacity();
                decompress(d.flags, payload, scratch) catch continue;
                payload = scratch.items;
            }
            const eq = std.mem.indexOfScalar(u8, payload, '=') orelse continue;
            const name = payload[0..eq];
            const value = payload[eq + 1 ..];
            if (std.mem.eql(u8, name, "MESSAGE")) {
                copyText(&out.message, value);
            } else if (std.mem.eql(u8, name, "PRIORITY")) {
                out.priority = @intCast((std.fmt.parseInt(u8, value, 10) catch 6) & 7);
            } else if (std.mem.eql(u8, name, "_PID")) {
                out.pid = std.fmt.parseInt(i32, value, 10) catch -1;
            } else if (std.mem.eql(u8, name, "SYSLOG_IDENTIFIER")) {
                sys.copyName(&out.identifier, value);
                has_ident = true;
            } else if (std.mem.eql(u8, name, "_COMM")) {
                if (!has_ident) sys.copyName(&out.identifier, value);
            } else if (std.mem.eql(u8, name, "_SYSTEMD_USER_UNIT")) {
                sys.copyName(&out.unit, value);
                has_user_unit = true;
            } else if (std.mem.eql(u8, name, "_SYSTEMD_UNIT")) {
                if (!has_user_unit) sys.copyName(&out.unit, value);
            }
        }
    }
};

fn hex(out: *[40]u8, id: *const [16]u8) void {
    const digits = "0123456789abcdef";
    for (id, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 15];
    }
    out[32] = 0;
}

const max_field = 64 << 20;

fn decompress(flags: u8, src: []const u8, out: *std.ArrayList(u8)) !void {
    if (flags & flag_lz4 != 0) return lz4(src, out);
    var in: std.Io.Reader = .fixed(src);
    var w: std.Io.Writer.Allocating = .init(sys.gpa);
    defer w.deinit();
    if (flags & flag_zstd != 0) {
        var z: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
        _ = z.reader.streamRemaining(&w.writer) catch return error.Invalid;
    } else {
        var x = std.compress.xz.Decompress.init(&in, sys.gpa, &.{}) catch return error.Invalid;
        defer x.deinit();
        _ = x.reader.streamRemaining(&w.writer) catch return error.Invalid;
    }
    if (w.written().len > max_field) return error.TooBig;
    try out.appendSlice(sys.gpa, w.written());
}

pub fn lz4(src: []const u8, out: *std.ArrayList(u8)) !void {
    if (src.len < 8) return error.Invalid;
    const want = std.mem.readInt(u64, src[0..8], .little);
    if (want > max_field) return error.TooBig;
    const start = out.items.len;
    var i: usize = 8;
    while (i < src.len) {
        const token = src[i];
        i += 1;
        var lit: usize = token >> 4;
        if (lit == 15) while (true) {
            if (i >= src.len) return error.Invalid;
            const b = src[i];
            i += 1;
            lit += b;
            if (b != 255) break;
        };
        if (lit > src.len - i) return error.Invalid;
        try out.appendSlice(sys.gpa, src[i .. i + lit]);
        i += lit;
        if (i >= src.len) break;
        if (src.len - i < 2) return error.Invalid;
        const offset = std.mem.readInt(u16, src[i..][0..2], .little);
        i += 2;
        if (offset == 0 or offset > out.items.len - start) return error.Invalid;
        var ml: usize = token & 15;
        if (ml == 15) while (true) {
            if (i >= src.len) return error.Invalid;
            const b = src[i];
            i += 1;
            ml += b;
            if (b != 255) break;
        };
        ml += 4;
        if (out.items.len - start + ml > want) return error.Invalid;
        for (0..ml) |_| try out.append(sys.gpa, out.items[out.items.len - offset]);
    }
    if (out.items.len - start != want) return error.Invalid;
}

pub fn currentBoot(out: *[40]u8) !void {
    var buf: [64]u8 = undefined;
    const raw = sys.readTrim("/proc/sys/kernel/random/boot_id", &buf) orelse return error.NotFound;
    var n: usize = 0;
    for (raw) |c| {
        if (c == '-') continue;
        if (n >= 32 or !std.ascii.isHex(c)) return error.Invalid;
        out[n] = std.ascii.toLower(c);
        n += 1;
    }
    if (n != 32) return error.Invalid;
    out[32] = 0;
}

pub const Filter = struct {
    boot: ?[32]u8 = null,
    max_priority: u8 = 7,
    unit: []const u8 = "",
    limit: usize = 1000,
};

pub const Files = struct {
    paths: std.ArrayList([:0]u8) = .empty,
    denied: usize = 0,

    pub fn deinit(f: *Files) void {
        for (f.paths.items) |p| sys.gpa.free(p);
        f.paths.deinit(sys.gpa);
    }

    pub fn add(f: *Files, path: []const u8) !void {
        try f.paths.append(sys.gpa, try sys.gpa.dupeZ(u8, path));
    }

    fn scan(f: *Files, dir: []const u8) !void {
        var buf: [512]u8 = undefined;
        var d = sys.Dir.open(sys.pathZ(&buf, "{s}", .{dir}) catch return) catch |e| {
            if (e == error.Access) f.denied += 1;
            return;
        };
        defer d.close();
        while (try d.next()) |ent| {
            const name = ent.name;
            if (!std.mem.endsWith(u8, name, ".journal") and !std.mem.endsWith(u8, name, ".journal~")) continue;
            var p: [768]u8 = undefined;
            const full = std.fmt.bufPrint(&p, "{s}/{s}", .{ dir, name }) catch continue;
            try f.add(full);
        }
    }

    pub fn system(f: *Files) !void {
        for ([_][]const u8{ "/var/log/journal", "/run/log/journal" }) |root| try f.under(root);
    }

    pub fn under(f: *Files, root: []const u8) !void {
        var buf: [512]u8 = undefined;
        var d = sys.Dir.open(sys.pathZ(&buf, "{s}", .{root}) catch return) catch |e| {
            if (e == error.Access) f.denied += 1;
            return;
        };
        defer d.close();
        while (try d.next()) |ent| {
            if (ent.name.len != 32) continue;
            var p: [512]u8 = undefined;
            try f.scan(std.fmt.bufPrint(&p, "{s}/{s}", .{ root, ent.name }) catch continue);
        }
        try f.scan(root);
    }
};

const Ref = struct { realtime: u64, seq: u64, file: u32, off: u64 };

fn lessRef(_: void, a: Ref, b: Ref) bool {
    if (a.realtime != b.realtime) return a.realtime < b.realtime;
    return a.seq < b.seq;
}

fn openAll(files: *const Files, out: *std.ArrayList(Journal)) !void {
    var denied = files.denied;
    for (files.paths.items) |p| {
        const j = Journal.open(p.ptr) catch |e| {
            if (e == error.Access) denied += 1;
            continue;
        };
        try out.append(sys.gpa, j);
    }
    if (out.items.len == 0 and denied > 0) return error.Access;
}

pub fn query(files: *const Files, f: Filter) !*Entries {
    var journals: std.ArrayList(Journal) = .empty;
    defer {
        for (journals.items) |*j| j.close();
        journals.deinit(sys.gpa);
    }
    try openAll(files, &journals);
    var refs: std.ArrayList(Ref) = .empty;
    defer refs.deinit(sys.gpa);
    for (journals.items, 0..) |*j, fi| {
        var it = j.iterator() catch continue;
        while (it.next() catch null) |off| {
            const h = j.head(off) catch continue;
            if (f.boot) |b| {
                var id: [40]u8 = undefined;
                hex(&id, &h.boot);
                if (!std.mem.eql(u8, id[0..32], &b)) continue;
            }
            try refs.append(sys.gpa, .{ .realtime = h.realtime, .seq = h.seq, .file = @intCast(fi), .off = off });
        }
    }
    std.mem.sort(Ref, refs.items, {}, lessRef);
    const list = try Entries.create();
    errdefer list.destroy();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(sys.gpa);
    var i = refs.items.len;
    while (i > 0 and list.count() < f.limit) {
        i -= 1;
        const r = refs.items[i];
        var e: Entry = undefined;
        journals.items[r.file].fill(r.off, &e, &scratch) catch continue;
        if (e.priority > f.max_priority) continue;
        if (f.unit.len > 0 and !std.mem.eql(u8, sys.cstr(&e.unit), f.unit)) continue;
        try list.append(e);
    }
    std.mem.reverse(Entry, list.items.items);
    return list;
}

pub fn boots(files: *const Files) !*Boots {
    var journals: std.ArrayList(Journal) = .empty;
    defer {
        for (journals.items) |*j| j.close();
        journals.deinit(sys.gpa);
    }
    try openAll(files, &journals);
    const list = try Boots.create();
    errdefer list.destroy();
    for (journals.items) |*j| {
        var it = j.iterator() catch continue;
        while (it.next() catch null) |off| {
            const h = j.head(off) catch continue;
            var id: [40]u8 = undefined;
            hex(&id, &h.boot);
            const b = for (list.items.items) |*b| {
                if (std.mem.eql(u8, b.id[0..32], id[0..32])) break b;
            } else blk: {
                try list.append(.{ .id = id, .first_usec = h.realtime, .last_usec = h.realtime, .entries = 0 });
                break :blk &list.items.items[list.items.items.len - 1];
            };
            b.first_usec = @min(b.first_usec, h.realtime);
            b.last_usec = @max(b.last_usec, h.realtime);
            b.entries += 1;
        }
    }
    const Sort = struct {
        fn less(_: void, a: Boot, b: Boot) bool {
            return a.first_usec < b.first_usec;
        }
    };
    std.mem.sort(Boot, list.items.items, {}, Sort.less);
    return list;
}

pub fn parseBoot(text: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '-') continue;
        if (n >= 32 or !std.ascii.isHex(c)) return error.Invalid;
        out[n] = std.ascii.toLower(c);
        n += 1;
    }
    if (n != 32) return error.Invalid;
    return out;
}

test "kernel records parse from kmsg and the dmesg mirror" {
    var e: Entry = undefined;
    try std.testing.expect(parseKmsg("3,1042,5123456,-;usb 1-1: device descriptor read/64, error -71\n SUBSYSTEM=usb\n", &e));
    try std.testing.expectEqual(@as(u8, 3), e.priority);
    try std.testing.expectEqual(@as(u64, 1042), e.seq);
    try std.testing.expectEqual(@as(u64, 5123456), e.monotonic_usec);
    try std.testing.expectEqualStrings("usb 1-1: device descriptor read/64, error -71", sys.cstr(&e.message));
    try std.testing.expect(!parseKmsg("garbage", &e));
    try std.testing.expect(parseDmesgLine("<12>[   17.500000] audit: rate limit", &e));
    try std.testing.expectEqual(@as(u8, 4), e.priority);
    try std.testing.expectEqual(@as(u64, 17_500_000), e.monotonic_usec);
    try std.testing.expectEqualStrings("audit: rate limit", sys.cstr(&e.message));
    try std.testing.expect(parseDmesgLine("[    0.5] Linux version", &e));
    try std.testing.expectEqual(@as(u64, 500_000), e.monotonic_usec);
    try std.testing.expect(!parseDmesgLine("", &e));
    var long: [3000]u8 = undefined;
    @memset(&long, 'x');
    @memcpy(long[2046..2048], "\xc3\xa8");
    try std.testing.expect(parseDmesgLine(&long, &e));
    try std.testing.expectEqual(@as(usize, 2046), sys.cstr(&e.message).len);

    const tmp = std.mem.span(std.c.getenv("TMPDIR") orelse return);
    var b: [512]u8 = undefined;
    const path = try sys.pathZ(&b, "{s}/kernel-mirror.log", .{tmp});
    try sys.createFile(path, "<6>[    1.000000] first\n<3>[    2.250000] second\n");
    const mirror = try kernelMirror(try Entries.create(), path, 1000);
    defer mirror.destroy();
    try std.testing.expectEqual(@as(usize, 2), mirror.count());
    try std.testing.expectEqual(@as(u64, 2_251_000), mirror.at(1).?.realtime_usec);
    try std.testing.expectEqual(@as(u8, 3), mirror.at(1).?.priority);
    const live = try kernel(path);
    defer live.destroy();
    try std.testing.expect(live.count() >= 2);
}

test "lz4 blocks decode as systemd stores them" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(sys.gpa);
    const block = [_]u8{ 27, 0, 0, 0, 0, 0, 0, 0, 0xb8, 'M', 'E', 'S', 'S', 'A', 'G', 'E', '=', 'a', 'b', 'c', 0x03, 0x00, 0x40, 'd', 'e', 'f', 'g' };
    try lz4(&block, &out);
    try std.testing.expectEqualStrings("MESSAGE=abcabcabcabcabcdefg", out.items);
    out.clearRetainingCapacity();
    try std.testing.expectError(error.Invalid, lz4(&[_]u8{ 4, 0, 0, 0, 0, 0, 0, 0, 0x10, 'a', 9, 0 }, &out));
}

test "real systemd journal files are read" {
    const dir = std.c.getenv("SINTY_JOURNAL_FIXTURES") orelse return error.SkipZigTest;
    var b: [512]u8 = undefined;
    var j = try Journal.open(try sys.pathZ(&b, "{s}/system.journal", .{std.mem.span(dir)}));
    defer j.close();
    var it = try j.iterator();
    var n: u64 = 0;
    var last_seq: u64 = 0;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(sys.gpa);
    var with_message: u64 = 0;
    var compressed_seen = false;
    while (try it.next()) |off| {
        const h = try j.head(off);
        try std.testing.expect(h.seq > last_seq);
        last_seq = h.seq;
        var e: Entry = undefined;
        try j.fill(off, &e, &scratch);
        if (e.message[0] != 0) with_message += 1;
        if (scratch.items.len > 0) compressed_seen = true;
        n += 1;
    }
    try std.testing.expectEqual(try j.entries(), n);
    try std.testing.expect(n > 100);
    try std.testing.expect(with_message * 10 > n * 9);
    try std.testing.expect(compressed_seen);

    const raw = j.map[0..j.end];
    const at = std.mem.indexOf(u8, raw, "MESSAGE=Started ") orelse return error.TestUnexpectedResult;
    const stop = std.mem.indexOfScalarPos(u8, raw, at, 0) orelse return error.TestUnexpectedResult;
    const want = raw[at + 8 .. stop];

    var files = Files{};
    defer files.deinit();
    try files.under(std.mem.span(dir));
    try std.testing.expectEqual(@as(usize, 2), files.paths.items.len);
    const all = try query(&files, .{ .limit = 1 << 30 });
    defer all.destroy();
    var found = false;
    for (all.items.items) |e| {
        if (std.mem.eql(u8, sys.cstr(&e.message), want)) found = true;
    }
    try std.testing.expect(found);
    for (1..all.items.items.len) |i| try std.testing.expect(all.items.items[i - 1].realtime_usec <= all.items.items[i].realtime_usec);

    const bl = try boots(&files);
    defer bl.destroy();
    try std.testing.expect(bl.count() >= 1);
    var total: u64 = 0;
    for (bl.items.items) |bt| total += bt.entries;
    try std.testing.expectEqual(@as(u64, all.count()), total);

    const last = bl.at(bl.count() - 1).?;
    const errs = try query(&files, .{ .boot = try parseBoot(last.id[0..32]), .max_priority = 3, .limit = 5 });
    defer errs.destroy();
    try std.testing.expect(errs.count() <= 5);
    for (errs.items.items) |e| {
        try std.testing.expect(e.priority <= 3);
        try std.testing.expectEqualStrings(last.id[0..32], e.boot_id[0..32]);
    }

    var cbuf: [512]u8 = undefined;
    for ([_][]const u8{ "a", "b" }) |name| {
        const p = try sys.pathZ(&cbuf, "{s}/corrupted/{s}", .{ std.mem.span(dir), name });
        var cj = Journal.open(p) catch continue;
        defer cj.close();
        var cit = cj.iterator() catch continue;
        var guard: usize = 0;
        while (cit.next() catch null) |off| : (guard += 1) {
            if (guard > 100000) break;
            var e: Entry = undefined;
            cj.fill(off, &e, &scratch) catch {};
        }
    }
}
