const std = @import("std");
const sys = @import("../sys.zig");
const logs = @import("logs.zig");

const X25519 = std.crypto.dh.X25519;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const block_size = 4096;
const header_size = 118;
const tag_size = 16;
const kdf_info = "sinty sealed log v1";
const off_ring = 4;
const off_seq = 20;
const off_boot = 28;
const off_counter = 32;
const off_prev = 40;
const off_eph = 72;
const off_nonce = 104;
const off_ctlen = 116;

pub const default_ring = "/var/lib/sealedlog/ring";
pub const default_cold = "/var/log/sealedlog";
pub const default_dictionary = "/usr/share/sealedlog/components";

pub const Header = struct {
    ring: [16]u8,
    seq: u64,
    boot: u32,
    counter: u64,
    prev: [32]u8,
};

pub const Block = struct {
    header: Header,
    hash: [32]u8,
    raw: [block_size]u8,
};

fn le(comptime T: type, b: []const u8) T {
    return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
}

pub fn parseHeader(b: []const u8) ?Header {
    if (b.len < block_size or !std.mem.eql(u8, b[0..4], "SLG1")) return null;
    const n = le(u16, b[off_ctlen..]);
    if (n < tag_size or header_size + @as(usize, n) > block_size) return null;
    return .{
        .ring = b[off_ring..][0..16].*,
        .seq = le(u64, b[off_seq..]),
        .boot = le(u32, b[off_boot..]),
        .counter = le(u64, b[off_counter..]),
        .prev = b[off_prev..][0..32].*,
    };
}

pub fn ringOf(b: []const u8) ?[16]u8 {
    if (b.len < block_size) return null;
    if (!std.mem.eql(u8, b[0..4], "SLG1") and !std.mem.eql(u8, b[0..4], "SLG0")) return null;
    return b[off_ring..][0..16].*;
}

pub fn hash(b: []const u8) [32]u8 {
    const n = le(u16, b[off_ctlen..]);
    var out: [32]u8 = undefined;
    Sha256.hash(b[0 .. header_size + @as(usize, n)], &out, .{});
    return out;
}

fn deriveKey(shared: [32]u8, eph: [32]u8, reader: [32]u8) [32]u8 {
    var salt: [64]u8 = undefined;
    @memcpy(salt[0..32], &eph);
    @memcpy(salt[32..], &reader);
    const prk = Hkdf.extract(&salt, &shared);
    var key: [32]u8 = undefined;
    Hkdf.expand(&key, kdf_info, prk);
    return key;
}

pub const OpenError = error{ NotBlock, WrongKey };

pub fn open(secret: [32]u8, b: []const u8, out: []u8) OpenError![]u8 {
    _ = parseHeader(b) orelse return error.NotBlock;
    const eph = b[off_eph..][0..32].*;
    const reader = X25519.recoverPublicKey(secret) catch return error.WrongKey;
    const shared = X25519.scalarmult(secret, eph) catch return error.WrongKey;
    const key = deriveKey(shared, eph, reader);
    const n = le(u16, b[off_ctlen..]) - tag_size;
    if (out.len < n) return error.NotBlock;
    const ct = b[header_size..][0..n];
    const tag = b[header_size + n ..][0..tag_size].*;
    Gcm.decrypt(out[0..n], ct, tag, b[0..header_size], b[off_nonce..][0..12].*, key) catch return error.WrongKey;
    return out[0..n];
}

fn uvarint(b: []const u8, pos: *usize) ?u64 {
    var x: u64 = 0;
    var s: u7 = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (pos.* + i >= b.len) return null;
        const c = b[pos.* + i];
        if (c < 0x80) {
            if (i == 9 and c > 1) return null;
            pos.* += i + 1;
            return x | @as(u64, c) << @intCast(s);
        }
        x |= @as(u64, c & 0x7f) << @intCast(s);
        s += 7;
    }
    return null;
}

pub const code_blob = 31;
const code_local = 32;

pub const Record = struct {
    component: u8,
    code: u8,
    delta_ms: u64,
    argc: u8,
    args: [3]u64,
    blob: []const u8,
};

pub const Payload = struct {
    base_ms: u64,
    data: []const u8,
    pos: usize,

    pub fn init(b: []const u8) ?Payload {
        var pos: usize = 0;
        const base = uvarint(b, &pos) orelse return null;
        return .{ .base_ms = base, .data = b, .pos = pos };
    }

    pub fn next(p: *Payload) error{Truncated}!?Record {
        const b = p.data;
        if (p.pos >= b.len) return null;
        if (b.len - p.pos < 3) return error.Truncated;
        if (b[p.pos] == 0 and b[p.pos + 1] == 0 and b[p.pos + 2] == 0) return null;
        var r = Record{ .component = b[p.pos], .code = b[p.pos + 1], .delta_ms = 0, .argc = b[p.pos + 2] & 3, .args = .{ 0, 0, 0 }, .blob = "" };
        p.pos += 3;
        r.delta_ms = uvarint(b, &p.pos) orelse return error.Truncated;
        for (0..r.argc) |i| r.args[i] = uvarint(b, &p.pos) orelse return error.Truncated;
        if (r.code == code_blob) {
            const l = uvarint(b, &p.pos) orelse return error.Truncated;
            if (l > b.len - p.pos) return error.Truncated;
            r.blob = b[p.pos..][0..@intCast(l)];
            p.pos += @intCast(l);
        }
        return r;
    }
};

pub const Family = enum { none, loader, kernel, init, ota, session, boot };

const Component = struct { name: [32]u8 = @splat(0), family: Family = .none, set: bool = false };

pub const Dictionary = struct {
    comps: [256]Component = @splat(.{}),

    fn put(d: *Dictionary, n: u8, name: []const u8, family: Family) void {
        d.comps[n] = .{ .family = family, .set = true };
        sys.copyName(&d.comps[n].name, name);
    }

    pub fn builtin() Dictionary {
        var d = Dictionary{};
        d.put(1, "loader", .loader);
        d.put(2, "kernel-linux", .kernel);
        d.put(3, "kernel-early", .kernel);
        d.put(5, "atom-init", .boot);
        d.put(6, "atomd", .ota);
        d.put(7, "updated", .ota);
        d.put(21, "sealedlogd", .none);
        return d;
    }

    fn isBuiltin(n: u8) bool {
        return switch (n) {
            1, 2, 3, 5, 6, 7, 21 => true,
            else => false,
        };
    }

    pub fn load(d: *Dictionary, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f: [5][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, line, " \t\r");
            while (it.next()) |w| {
                if (n == f.len) break;
                f[n] = w;
                n += 1;
            }
            if (n == 0 or f[0][0] == '#') continue;
            if (n < 3 or n > 4 or (n == 4 and !std.mem.eql(u8, f[3], "user"))) continue;
            const num = std.fmt.parseInt(u8, f[0], 10) catch continue;
            if (num == 0 or isBuiltin(num)) continue;
            const fam: Family = if (std.mem.eql(u8, f[2], "-")) .none else std.meta.stringToEnum(Family, f[2]) orelse continue;
            if (fam == .none and !std.mem.eql(u8, f[2], "-")) continue;
            d.put(num, f[1], fam);
        }
    }

    pub fn componentName(d: *const Dictionary, n: u8, buf: []u8) []const u8 {
        if (d.comps[n].set) return sys.cstr(&d.comps[n].name);
        return std.fmt.bufPrint(buf, "component-{d}", .{n}) catch "component";
    }

    pub fn codeName(d: *const Dictionary, comp: u8, code: u8, buf: []u8) []const u8 {
        if (code == code_blob) return "blob";
        if (code < code_local) {
            if (code >= 1 and code <= shared_names.len) return shared_names[code - 1];
            return std.fmt.bufPrint(buf, "code-{d}", .{code}) catch "code";
        }
        const names: []const []const u8 = switch (d.comps[comp].family) {
            .loader => &loader_names,
            .kernel => &kernel_names,
            .init => &init_names,
            .ota => &ota_names,
            .session => &session_names,
            .boot => &boot_names,
            .none => &.{},
        };
        if (code - code_local < names.len) return names[code - code_local];
        return std.fmt.bufPrint(buf, "code-{d}", .{code}) catch "code";
    }
};

const shared_names = [_][]const u8{ "start", "ready", "stop", "fail", "crash", "restart", "timeout", "denied", "warn" };
const loader_names = [_][]const u8{ "boot-start", "slot-chosen", "trial", "signature-bad", "rollback-refused", "slot-missing", "chainload", "chainload-fail", "fallback", "halted", "recovery", "chooser", "measured", "unlock-armed" };
const kernel_names = [_][]const u8{ "stage", "root-mounted", "init-started", "init-exit", "panic", "oops", "watchdog", "suspend", "resume", "thermal", "tpm-launch", "driver-fail" };
const init_names = [_][]const u8{ "target", "unit-fail", "unit-restart", "shutdown" };
const ota_names = [_][]const u8{ "staged", "promoted", "rollback", "healthy", "download-fail", "verify-fail", "reboot" };
const session_names = [_][]const u8{ "login", "login-fail", "logout", "lock", "app-crash", "first-frame", "disk-error", "battery-critical" };
const boot_names = [_][]const u8{ "diagnosis", "data-check", "data-repair" };

const critical = [_][]const u8{ "panic", "oops", "watchdog", "halted", "battery-critical" };
const failing = [_][]const u8{ "fail", "crash", "timeout", "denied", "signature-bad", "rollback-refused", "slot-missing", "chainload-fail", "init-exit", "driver-fail", "unit-fail", "rollback", "download-fail", "verify-fail", "login-fail", "app-crash", "disk-error" };
const warning = [_][]const u8{ "warn", "restart", "fallback", "recovery", "unit-restart", "thermal", "data-repair" };

pub fn priorityOf(name: []const u8) u8 {
    for (critical) |n| if (std.mem.eql(u8, n, name)) return 2;
    for (failing) |n| if (std.mem.eql(u8, n, name)) return 3;
    for (warning) |n| if (std.mem.eql(u8, n, name)) return 4;
    return 6;
}

pub const Blocks = std.ArrayList(Block);

fn insertSorted(list: *Blocks, b: *const Block) !void {
    var i = list.items.len;
    while (i > 0 and list.items[i - 1].header.seq > b.header.seq) i -= 1;
    if (i > 0 and list.items[i - 1].header.seq == b.header.seq) return;
    try list.insert(sys.gpa, i, b.*);
}

pub fn readCold(dir: [*:0]const u8, list: *Blocks) !void {
    var d = sys.Dir.open(dir) catch |e| switch (e) {
        error.NotFound => return,
        else => return e,
    };
    defer d.close();
    const base = std.mem.span(dir);
    while (try d.next()) |ent| {
        if (!std.mem.endsWith(u8, ent.name, ".slog")) continue;
        var p: [1024]u8 = undefined;
        const path = sys.pathZ(&p, "{s}/{s}", .{ base, ent.name }) catch continue;
        const data = try sys.readAlloc(sys.gpa, path, 256 << 20);
        defer sys.gpa.free(data);
        var off: usize = 0;
        while (off + block_size <= data.len) : (off += block_size) {
            const raw = data[off..][0..block_size];
            const h = parseHeader(raw) orelse continue;
            const b = Block{ .header = h, .hash = hash(raw), .raw = raw.* };
            try insertSorted(list, &b);
        }
    }
}

pub fn readRing(path: [*:0]const u8, list: *Blocks) !void {
    const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |e| switch (e) {
        error.NotFound => return,
        else => return e,
    };
    defer sys.close(fd);
    var st: std.os.linux.Statx = undefined;
    _ = try sys.check(std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st));
    const blocks = st.size / block_size;
    if (blocks < 2) return error.Invalid;
    var b: Block = undefined;
    if (try sys.pread(fd, &b.raw, 0) != block_size) return error.Invalid;
    const id = ringOf(&b.raw) orelse return error.Invalid;
    var i: u64 = 0;
    while (i < blocks) : (i += 1) {
        if (try sys.pread(fd, &b.raw, i * block_size) != block_size) continue;
        const h = parseHeader(&b.raw) orelse continue;
        if (!std.mem.eql(u8, &h.ring, &id) or h.seq == 0 or (h.seq - 1) % blocks != i) continue;
        b.header = h;
        b.hash = hash(&b.raw);
        try insertSorted(list, &b);
    }
}

pub const Break = enum { repeated, prev_mismatch, boot_back, counter_back, counter_jump };

pub fn breakReason(b: Break) []const u8 {
    return switch (b) {
        .repeated => "sequence repeated",
        .prev_mismatch => "previous hash mismatch",
        .boot_back => "boot number went back",
        .counter_back => "TPM counter went back",
        .counter_jump => "boots erased: TPM counter jumped",
    };
}

pub fn verify(prev: *const Block, cur: *const Block) ?Break {
    const p = prev.header;
    const c = cur.header;
    if (c.seq == p.seq) return .repeated;
    if (c.seq == p.seq + 1 and !std.mem.eql(u8, &c.prev, &prev.hash)) return .prev_mismatch;
    if (c.boot < p.boot) return .boot_back;
    if (c.counter != 0 and p.counter != 0 and c.counter < p.counter) return .counter_back;
    if (c.counter != 0 and p.counter != 0 and c.counter > p.counter + 1) return .counter_jump;
    return null;
}

pub fn parseKey(text: []const u8) ![32]u8 {
    const t = sys.trim(text);
    var line = t;
    if (std.mem.indexOfScalar(u8, t, '\n')) |nl| line = sys.trim(t[0..nl]);
    if (line.len != 64) return error.Invalid;
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, line) catch return error.Invalid;
    return key;
}

fn entry(list: *logs.Entries, seq: u64, boot: u32, priority: u8, realtime: u64, ident: []const u8, message: []const u8) !void {
    var e = std.mem.zeroes(logs.Entry);
    e.realtime_usec = realtime;
    e.seq = seq;
    e.priority = priority;
    _ = std.fmt.bufPrint(&e.boot_id, "{d}", .{boot}) catch {};
    sys.copyName(&e.identifier, ident);
    var n = @min(e.message.len - 1, message.len);
    while (n > 0 and n < message.len and (message[n] & 0xc0) == 0x80) n -= 1;
    @memcpy(e.message[0..n], message[0..n]);
    try list.append(e);
}

pub const Options = struct {
    ring: [*:0]const u8 = default_ring,
    cold: [*:0]const u8 = default_cold,
    dictionary: [*:0]const u8 = default_dictionary,
    boots: u32 = 0,
};

pub fn read(secret: [32]u8, o: Options) !*logs.Entries {
    var dict = Dictionary.builtin();
    if (sys.readAlloc(sys.gpa, o.dictionary, 1 << 20)) |text| {
        defer sys.gpa.free(text);
        dict.load(text);
    } else |_| {}

    var blocks: Blocks = .empty;
    defer blocks.deinit(sys.gpa);
    try readCold(o.cold, &blocks);
    try readRing(o.ring, &blocks);

    const list = try logs.Entries.create();
    errdefer list.destroy();
    var msg: [512]u8 = undefined;
    for (blocks.items[@min(1, blocks.items.len)..], 1..) |*cur, i| {
        const why = verify(&blocks.items[i - 1], cur) orelse continue;
        const text = std.fmt.bufPrint(&msg, "chain: seq {d}: {s}", .{ cur.header.seq, breakReason(why) }) catch continue;
        try entry(list, cur.header.seq, cur.header.boot, 2, 0, "sealedlog", text);
    }

    const order = try sys.gpa.alloc(u32, blocks.items.len);
    defer sys.gpa.free(order);
    for (order, 0..) |*o2, i| o2.* = @intCast(i);
    std.mem.sort(u32, order, blocks.items, struct {
        fn lt(items: []const Block, a: u32, b: u32) bool {
            const x = items[a].header;
            const y = items[b].header;
            return x.boot < y.boot or (x.boot == y.boot and x.seq < y.seq);
        }
    }.lt);

    var keep_from: u32 = 0;
    if (o.boots > 0) {
        var seen: u32 = 0;
        var i = order.len;
        var last: ?u32 = null;
        while (i > 0) : (i -= 1) {
            const b = blocks.items[order[i - 1]].header.boot;
            if (last != null and last.? == b) continue;
            last = b;
            seen += 1;
            keep_from = b;
            if (seen == o.boots) break;
        }
    }

    var pt: [block_size]u8 = undefined;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(sys.gpa);
    for (order) |idx| {
        const b = &blocks.items[idx];
        if (b.header.boot < keep_from) continue;
        const plain = open(secret, &b.raw, &pt) catch {
            const t = std.fmt.bufPrint(&msg, "seq {d}: block does not open with this key", .{b.header.seq}) catch continue;
            try entry(list, b.header.seq, b.header.boot, 4, 0, "sealedlog", t);
            continue;
        };
        var p = Payload.init(plain) orelse {
            const t = std.fmt.bufPrint(&msg, "seq {d}: truncated record", .{b.header.seq}) catch continue;
            try entry(list, b.header.seq, b.header.boot, 4, 0, "sealedlog", t);
            continue;
        };
        var t = p.base_ms;
        while (true) {
            const r = (p.next() catch {
                const m = std.fmt.bufPrint(&msg, "seq {d}: truncated record", .{b.header.seq}) catch break;
                try entry(list, b.header.seq, b.header.boot, 4, 0, "sealedlog", m);
                break;
            }) orelse break;
            t +%= r.delta_ms;
            var cbuf: [32]u8 = undefined;
            var nbuf: [32]u8 = undefined;
            const comp = dict.componentName(r.component, &cbuf);
            const name = dict.codeName(r.component, r.code, &nbuf);
            text.clearRetainingCapacity();
            try text.appendSlice(sys.gpa, name);
            for (r.args[0..r.argc]) |a| try text.print(sys.gpa, " {d}", .{a});
            if (r.code == code_blob) {
                const blob = std.mem.trimEnd(u8, r.blob, "\n");
                if (blob.len > 0) {
                    try text.append(sys.gpa, '\n');
                    try text.appendSlice(sys.gpa, blob);
                }
            }
            const when: u64 = if (p.base_ms != 0) t *% 1000 else 0;
            try entry(list, b.header.seq, b.header.boot, priorityOf(name), when, comp, text.items);
        }
    }
    return list;
}

fn testSeal(reader: [32]u8, h: Header, payload: []const u8, eph_secret: [32]u8, nonce: [12]u8) [block_size]u8 {
    var b: [block_size]u8 = @splat(0);
    @memcpy(b[0..4], "SLG1");
    @memcpy(b[off_ring..][0..16], &h.ring);
    std.mem.writeInt(u64, b[off_seq..][0..8], h.seq, .little);
    std.mem.writeInt(u32, b[off_boot..][0..4], h.boot, .little);
    std.mem.writeInt(u64, b[off_counter..][0..8], h.counter, .little);
    @memcpy(b[off_prev..][0..32], &h.prev);
    const eph = X25519.recoverPublicKey(eph_secret) catch unreachable;
    @memcpy(b[off_eph..][0..32], &eph);
    @memcpy(b[off_nonce..][0..12], &nonce);
    std.mem.writeInt(u16, b[off_ctlen..][0..2], @intCast(payload.len + tag_size), .little);
    const shared = X25519.scalarmult(eph_secret, reader) catch unreachable;
    const key = deriveKey(shared, eph, reader);
    var tag: [tag_size]u8 = undefined;
    Gcm.encrypt(b[header_size..][0..payload.len], &tag, payload, b[0..header_size], nonce, key);
    @memcpy(b[header_size + payload.len ..][0..tag_size], &tag);
    return b;
}

fn putUvarint(out: *std.ArrayList(u8), v: u64) !void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) try out.append(std.testing.allocator, @as(u8, @truncate(x)) | 0x80);
    try out.append(std.testing.allocator, @truncate(x));
}

const test_secret: [32]u8 = @splat(7);
const test_ring: [16]u8 = @splat(0xab);

fn testPayload(base: u64, comp: u8, code: u8, delta: u64, args: []const u64, blob: []const u8) !std.ArrayList(u8) {
    var p: std.ArrayList(u8) = .empty;
    try putUvarint(&p, base);
    try p.appendSlice(std.testing.allocator, &.{ comp, code, @intCast(args.len) });
    try putUvarint(&p, delta);
    for (args) |a| try putUvarint(&p, a);
    if (code == code_blob) {
        try putUvarint(&p, blob.len);
        try p.appendSlice(std.testing.allocator, blob);
    }
    return p;
}

fn writeRing(path: [*:0]const u8, blocks: []const [block_size]u8, slots: usize) !void {
    var data = try std.testing.allocator.alloc(u8, slots * block_size);
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    for (0..slots) |i| {
        @memcpy(data[i * block_size ..][0..4], "SLG0");
        @memcpy(data[i * block_size + off_ring ..][0..16], &test_ring);
    }
    for (blocks) |b| {
        const h = parseHeader(&b).?;
        @memcpy(data[((h.seq - 1) % slots) * block_size ..][0..block_size], &b);
    }
    try sys.createFile(path, data);
}

test "a sealed block opens with the reader key and not with another" {
    const reader = try X25519.recoverPublicKey(test_secret);
    var p = try testPayload(1_700_000_000_000, 2, code_local + 4, 5, &.{ 1, 300 }, "");
    defer p.deinit(std.testing.allocator);
    const h = Header{ .ring = test_ring, .seq = 1, .boot = 3, .counter = 0, .prev = @splat(0) };
    var b = testSeal(reader, h, p.items, @splat(9), @splat(1));
    var out: [block_size]u8 = undefined;
    const plain = try open(test_secret, &b, &out);
    try std.testing.expectEqualSlices(u8, p.items, plain);
    try std.testing.expectError(error.WrongKey, open(@splat(8), &b, &out));
    b[off_boot] ^= 1;
    try std.testing.expectError(error.WrongKey, open(test_secret, &b, &out));
    b[0] = 'X';
    try std.testing.expectError(error.NotBlock, open(test_secret, &b, &out));
}

test "records decode with arguments and blobs and stop at padding" {
    var p = try testPayload(10, 2, code_blob, 3, &.{7}, "panic tail\n");
    defer p.deinit(std.testing.allocator);
    try p.appendSlice(std.testing.allocator, &.{ 0, 0, 0, 0 });
    var it = Payload.init(p.items).?;
    try std.testing.expectEqual(10, it.base_ms);
    const r = (try it.next()).?;
    try std.testing.expectEqual(code_blob, r.code);
    try std.testing.expectEqual(1, r.argc);
    try std.testing.expectEqual(7, r.args[0]);
    try std.testing.expectEqualStrings("panic tail\n", r.blob);
    try std.testing.expectEqual(null, try it.next());
    var bad = Payload.init(&.{ 1, 2, 1, 0, 0x80 }).?;
    try std.testing.expectError(error.Truncated, bad.next());
}

test "uvarint rejects overflow and short input" {
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, 300), uvarint(&.{ 0xac, 0x02 }, &pos));
    try std.testing.expectEqual(2, pos);
    pos = 0;
    try std.testing.expectEqual(@as(?u64, null), uvarint(&.{0x80}, &pos));
    pos = 0;
    try std.testing.expectEqual(@as(?u64, null), uvarint(&(.{0xff} ** 9 ++ .{0x02}), &pos));
}

test "the dictionary names components and codes and keeps the built-in names" {
    var d = Dictionary.builtin();
    d.load("# comment\n40 greeter session user\n2 renamed loader\n41 bad nofamily\n");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("greeter", d.componentName(40, &buf));
    try std.testing.expectEqualStrings("kernel-linux", d.componentName(2, &buf));
    try std.testing.expectEqualStrings("component-41", d.componentName(41, &buf));
    try std.testing.expectEqualStrings("login-fail", d.codeName(40, code_local + 1, &buf));
    try std.testing.expectEqualStrings("panic", d.codeName(2, code_local + 4, &buf));
    try std.testing.expectEqualStrings("fail", d.codeName(2, 4, &buf));
    try std.testing.expectEqualStrings("code-99", d.codeName(2, 99, &buf));
    try std.testing.expectEqual(2, priorityOf("panic"));
    try std.testing.expectEqual(3, priorityOf("unit-fail"));
    try std.testing.expectEqual(6, priorityOf("start"));
}

test "the reader key is one hex line" {
    const k = try parseKey("0707070707070707070707070707070707070707070707070707070707070707\n");
    try std.testing.expectEqualSlices(u8, &test_secret, &k);
    try std.testing.expectError(error.Invalid, parseKey("abcd"));
}

test "ring and archive merge into one ordered log with chain checks" {
    var dbuf: [256]u8 = undefined;
    const root = try sys.testRoot(&dbuf, "sealed");
    var pbuf: [512]u8 = undefined;
    const reader = try X25519.recoverPublicKey(test_secret);

    var p1 = try testPayload(1_000, 2, code_local + 4, 0, &.{}, "");
    defer p1.deinit(std.testing.allocator);
    var p2 = try testPayload(2_000, 5, 1, 250, &.{42}, "");
    defer p2.deinit(std.testing.allocator);
    var p3 = try testPayload(0, 99, 9, 0, &.{}, "");
    defer p3.deinit(std.testing.allocator);

    const b1 = testSeal(reader, .{ .ring = test_ring, .seq = 1, .boot = 1, .counter = 4, .prev = @splat(0) }, p1.items, @splat(3), @splat(1));
    const b2 = testSeal(reader, .{ .ring = test_ring, .seq = 2, .boot = 2, .counter = 5, .prev = hash(&b1) }, p2.items, @splat(4), @splat(2));
    const b3 = testSeal(reader, .{ .ring = test_ring, .seq = 3, .boot = 3, .counter = 6, .prev = @splat(0x55) }, p3.items, @splat(5), @splat(3));

    try sys.mkdirs(try std.fmt.bufPrint(&pbuf, "{s}/cold", .{root}));
    try sys.createFile(try sys.pathZ(&pbuf, "{s}/cold/boot-00000001.slog", .{root}), &b1);
    try writeRing(try sys.pathZ(&pbuf, "{s}/ring", .{root}), &.{ b1, b2, b3 }, 4);
    try sys.createFile(try sys.pathZ(&pbuf, "{s}/dict", .{root}), "99 greeter session\n");

    var rbuf: [512]u8 = undefined;
    var cbuf: [512]u8 = undefined;
    var dctb: [512]u8 = undefined;
    const opts = Options{
        .ring = try sys.pathZ(&rbuf, "{s}/ring", .{root}),
        .cold = try sys.pathZ(&cbuf, "{s}/cold", .{root}),
        .dictionary = try sys.pathZ(&dctb, "{s}/dict", .{root}),
    };
    const list = try read(test_secret, opts);
    defer list.destroy();
    try std.testing.expectEqual(4, list.count());
    const brk = list.at(0).?;
    try std.testing.expectEqualStrings("chain: seq 3: previous hash mismatch", sys.cstr(&brk.message));
    try std.testing.expectEqual(2, brk.priority);
    const panic = list.at(1).?;
    try std.testing.expectEqualStrings("kernel-linux", sys.cstr(&panic.identifier));
    try std.testing.expectEqualStrings("panic", sys.cstr(&panic.message));
    try std.testing.expectEqualStrings("1", sys.cstr(&panic.boot_id));
    try std.testing.expectEqual(1_000_000, panic.realtime_usec);
    try std.testing.expectEqual(2, panic.priority);
    const start = list.at(2).?;
    try std.testing.expectEqualStrings("atom-init", sys.cstr(&start.identifier));
    try std.testing.expectEqualStrings("start 42", sys.cstr(&start.message));
    try std.testing.expectEqual(2_250_000, start.realtime_usec);
    const late = list.at(3).?;
    try std.testing.expectEqualStrings("greeter", sys.cstr(&late.identifier));
    try std.testing.expectEqualStrings("warn", sys.cstr(&late.message));
    try std.testing.expectEqual(0, late.realtime_usec);
    try std.testing.expectEqual(4, late.priority);

    var only = opts;
    only.boots = 1;
    const last = try read(test_secret, only);
    defer last.destroy();
    try std.testing.expectEqual(2, last.count());
    try std.testing.expectEqualStrings("3", sys.cstr(&last.at(1).?.boot_id));

    const wrong = try read(@splat(8), only);
    defer wrong.destroy();
    try std.testing.expectEqualStrings("seq 3: block does not open with this key", sys.cstr(&wrong.at(1).?.message));

    var none = opts;
    none.ring = "/nonexistent/ring";
    none.cold = "/nonexistent/cold";
    const empty = try read(test_secret, none);
    defer empty.destroy();
    try std.testing.expectEqual(0, empty.count());
}
