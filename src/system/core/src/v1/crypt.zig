const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const fs = @import("fs.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Sha1 = std.crypto.hash.Sha1;
const Aes256 = std.crypto.core.aes.Aes256;
const Aes128 = std.crypto.core.aes.Aes128;
const b64 = std.base64.standard;

pub const Error = error{ WrongPassphrase, Unsupported, Invalid, NoMemory, Io, NotFound, Access, Busy, TooBig, Exists, Again };

const bin_size = 4096;
const magic1 = "LUKS\xba\xbe";
const magic2 = "SKUL\xba\xbe";

pub const Info = extern struct {
    version: u32,
    keyslots: u32,
    sector_size: u32,
    pad: u32,
    payload_offset: u64,
    uuid: [40]u8,
    label: [48]u8,
    cipher: [64]u8,
};

const Hash = enum { sha1, sha256, sha512 };

fn parseHash(s: []const u8) !Hash {
    if (std.mem.eql(u8, s, "sha1")) return .sha1;
    if (std.mem.eql(u8, s, "sha256")) return .sha256;
    if (std.mem.eql(u8, s, "sha512")) return .sha512;
    return error.Unsupported;
}

fn digestLen(h: Hash) usize {
    return switch (h) {
        .sha1 => 20,
        .sha256 => 32,
        .sha512 => 64,
    };
}

fn hashParts(h: Hash, a: []const u8, b: []const u8, out: []u8) void {
    switch (h) {
        inline else => |t| {
            const H = switch (t) {
                .sha1 => Sha1,
                .sha256 => Sha256,
                .sha512 => Sha512,
            };
            var st = H.init(.{});
            st.update(a);
            st.update(b);
            var d: [H.digest_length]u8 = undefined;
            st.final(&d);
            @memcpy(out[0..@min(out.len, d.len)], d[0..@min(out.len, d.len)]);
        },
    }
}

fn pbkdf2(h: Hash, out: []u8, pass: []const u8, salt: []const u8, iter: u32) !void {
    const hm = std.crypto.auth.hmac;
    switch (h) {
        .sha1 => try std.crypto.pwhash.pbkdf2(out, pass, salt, iter, hm.HmacSha1),
        .sha256 => try std.crypto.pwhash.pbkdf2(out, pass, salt, iter, hm.sha2.HmacSha256),
        .sha512 => try std.crypto.pwhash.pbkdf2(out, pass, salt, iter, hm.sha2.HmacSha512),
    }
}

fn diffuse(h: Hash, buf: []u8) void {
    const ds = digestLen(h);
    var i: usize = 0;
    var tmp: [64]u8 = undefined;
    while (i * ds < buf.len) : (i += 1) {
        const chunk = buf[i * ds .. @min(buf.len, (i + 1) * ds)];
        var iv: [4]u8 = undefined;
        std.mem.writeInt(u32, &iv, @intCast(i), .big);
        hashParts(h, &iv, chunk, tmp[0..ds]);
        @memcpy(chunk, tmp[0..chunk.len]);
    }
}

pub fn afMerge(h: Hash, src: []const u8, out: []u8, stripes: usize) void {
    const n = out.len;
    @memset(out, 0);
    var i: usize = 0;
    while (i + 1 < stripes) : (i += 1) {
        for (out, src[i * n .. (i + 1) * n]) |*o, s| o.* ^= s;
        diffuse(h, out);
    }
    for (out, src[(stripes - 1) * n .. stripes * n]) |*o, s| o.* ^= s;
}

fn afSplit(h: Hash, key: []const u8, out: []u8, stripes: usize) void {
    const n = key.len;
    random(out[0 .. (stripes - 1) * n]);
    const acc = out[(stripes - 1) * n .. stripes * n];
    @memset(acc, 0);
    var i: usize = 0;
    while (i + 1 < stripes) : (i += 1) {
        for (acc, out[i * n .. (i + 1) * n]) |*o, s| o.* ^= s;
        diffuse(h, acc);
    }
    for (acc, key) |*o, k| o.* ^= k;
}

fn random(buf: []u8) void {
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.getrandom(buf[n..].ptr, buf.len - n, 0);
        if (linux.errno(rc) == .SUCCESS) n += rc;
    }
}

fn mulAlpha(t: *[16]u8) void {
    var carry: u8 = 0;
    for (t) |*b| {
        const next = b.* >> 7;
        b.* = (b.* << 1) | carry;
        carry = next;
    }
    if (carry != 0) t[0] ^= 0x87;
}

fn xts(comptime Aes: type, key: []const u8, data: []u8, sector: u64, sector_size: usize, encrypt: bool) void {
    const half = key.len / 2;
    const k1 = key[0..half][0..Aes.key_bits / 8].*;
    const k2 = key[half..][0..Aes.key_bits / 8].*;
    const tweak_ctx = Aes.initEnc(k2);
    const enc = Aes.initEnc(k1);
    const dec = Aes.initDec(k1);
    var s: usize = 0;
    var sec_num = sector;
    while (s < data.len) : (s += sector_size) {
        var iv = std.mem.zeroes([16]u8);
        std.mem.writeInt(u64, iv[0..8], sec_num, .little);
        var t: [16]u8 = undefined;
        tweak_ctx.encrypt(&t, &iv);
        var b: usize = s;
        while (b < s + sector_size) : (b += 16) {
            var blk: [16]u8 = undefined;
            for (&blk, data[b .. b + 16], t) |*o, x, y| o.* = x ^ y;
            var res: [16]u8 = undefined;
            if (encrypt) enc.encrypt(&res, &blk) else dec.decrypt(&res, &blk);
            for (data[b .. b + 16], res, t) |*o, x, y| o.* = x ^ y;
            mulAlpha(&t);
        }
        sec_num += 1;
    }
}

fn cipherData(cipher: []const u8, key: []const u8, data: []u8, sector: u64, sector_size: usize, encrypt: bool) !void {
    if (!std.mem.eql(u8, cipher, "aes-xts-plain64")) return error.Unsupported;
    if (data.len % sector_size != 0) return error.Invalid;
    switch (key.len) {
        64 => xts(Aes256, key, data, sector, sector_size, encrypt),
        32 => xts(Aes128, key, data, sector, sector_size, encrypt),
        else => return error.Unsupported,
    }
}

const Kdf = union(enum) {
    pbkdf2: struct { hash: Hash, iterations: u32 },
    argon2: struct { mode: std.crypto.pwhash.argon2.Mode, time: u32, memory: u32, cpus: u24 },
};

fn derive(kdf: Kdf, out: []u8, pass: []const u8, salt: []const u8) !void {
    switch (kdf) {
        .pbkdf2 => |p| try pbkdf2(p.hash, out, pass, salt, p.iterations),
        .argon2 => |a| {
            var threaded: std.Io.Threaded = .init_single_threaded;
            threaded.allocator = sys.gpa;
            const cpus = std.Thread.getCpuCount() catch 1;
            if (cpus > 1 and a.cpus > 1) threaded.async_limit = .limited(@min(cpus, a.cpus) - 1);
            defer threaded.deinit();
            std.crypto.pwhash.argon2.kdf(sys.gpa, out, pass, salt, .{ .t = a.time, .m = a.memory, .p = a.cpus }, a.mode, threaded.io()) catch |e| return switch (e) {
                error.OutOfMemory => error.NoMemory,
                else => error.Invalid,
            };
        },
    }
}

const Keyslot = struct {
    id: u32,
    key_size: usize,
    stripes: usize,
    af_hash: Hash,
    offset: u64,
    size: u64,
    cipher: []const u8,
    area_key: usize,
    kdf: Kdf,
    salt: []const u8,
};

const Digest = struct {
    hash: Hash,
    iterations: u32,
    salt: []const u8,
    digest: []const u8,
    keyslots: u64,
};

const Header = struct {
    arena: std.heap.ArenaAllocator,
    hdr_size: u64,
    seqid: u64,
    uuid: [40]u8,
    label: [48]u8,
    keyslots: []Keyslot,
    digests: []Digest,
    segment_offset: u64,
    segment_cipher: []const u8,
    sector_size: u32,
    json_size: u64,
    keyslots_size: u64,

    fn deinit(self: *Header) void {
        self.arena.deinit();
    }
};

fn csumOk(buf: []u8) bool {
    var want: [32]u8 = undefined;
    @memcpy(&want, buf[448..480]);
    var saved: [64]u8 = undefined;
    @memcpy(&saved, buf[448..512]);
    @memset(buf[448..512], 0);
    var got: [32]u8 = undefined;
    Sha256.hash(buf, &got, .{});
    @memcpy(buf[448..512], &saved);
    return std.mem.eql(u8, &want, &got);
}

fn setCsum(buf: []u8) void {
    @memset(buf[448..512], 0);
    var got: [32]u8 = undefined;
    Sha256.hash(buf, &got, .{});
    @memcpy(buf[448..480], &got);
}

fn str(v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.Invalid,
    };
}

fn num(v: std.json.Value) !u64 {
    return switch (v) {
        .integer => |i| if (i < 0) error.Invalid else @intCast(i),
        .string => |s| std.fmt.parseInt(u64, s, 10) catch error.Invalid,
        else => error.Invalid,
    };
}

fn field(o: std.json.ObjectMap, k: []const u8) !std.json.Value {
    return o.get(k) orelse error.Invalid;
}

fn obj(v: std.json.Value) !std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.Invalid,
    };
}

fn decode64(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const n = b64.Decoder.calcSizeForSlice(s) catch return error.Invalid;
    const out = try a.alloc(u8, n);
    b64.Decoder.decode(out, s) catch return error.Invalid;
    return out;
}

fn readCopy(d: fs.Dev, off: u64) !?Header {
    var bin: [bin_size]u8 = undefined;
    d.readAt(off, &bin) catch return null;
    if (!std.mem.eql(u8, bin[0..6], if (off == 0) magic1 else magic2)) return null;
    if (std.mem.readInt(u16, bin[6..8], .big) != 2) return error.Unsupported;
    const hdr_size = std.mem.readInt(u64, bin[8..16], .big);
    if (hdr_size < 16384 or hdr_size > 4 << 20) return null;
    if (std.mem.readInt(u64, bin[256..264], .big) != off) return null;
    var arena = std.heap.ArenaAllocator.init(sys.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const all = try a.alloc(u8, hdr_size);
    try d.readAt(off, all);
    if (!std.mem.eql(u8, std.mem.sliceTo(all[72..104], 0), "sha256")) return error.Unsupported;
    if (!csumOk(all)) return null;
    var h = Header{ .arena = undefined, .hdr_size = hdr_size, .seqid = std.mem.readInt(u64, bin[16..24], .big), .uuid = undefined, .label = undefined, .keyslots = &.{}, .digests = &.{}, .segment_offset = 0, .segment_cipher = "", .sector_size = 512, .json_size = hdr_size - bin_size, .keyslots_size = 0 };
    @memcpy(&h.uuid, all[168..208]);
    @memcpy(&h.label, all[24..72]);
    const text = std.mem.sliceTo(all[bin_size..], 0);
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.Invalid;
    const top = try obj(root);
    var slots: std.ArrayList(Keyslot) = .empty;
    var it = (try obj(try field(top, "keyslots"))).iterator();
    while (it.next()) |e| {
        const k = try obj(e.value_ptr.*);
        if (!std.mem.eql(u8, try str(try field(k, "type")), "luks2")) continue;
        const af = try obj(try field(k, "af"));
        const area = try obj(try field(k, "area"));
        const kdf = try obj(try field(k, "kdf"));
        const kt = try str(try field(kdf, "type"));
        const parsed: Kdf = if (std.mem.eql(u8, kt, "pbkdf2"))
            .{ .pbkdf2 = .{ .hash = try parseHash(try str(try field(kdf, "hash"))), .iterations = @intCast(try num(try field(kdf, "iterations"))) } }
        else if (std.mem.eql(u8, kt, "argon2id") or std.mem.eql(u8, kt, "argon2i"))
            .{ .argon2 = .{ .mode = if (kt[6] == 'i' and kt.len == 8) .argon2id else .argon2i, .time = @intCast(try num(try field(kdf, "time"))), .memory = @intCast(try num(try field(kdf, "memory"))), .cpus = @intCast(try num(try field(kdf, "cpus"))) } }
        else
            continue;
        try slots.append(a, .{
            .id = std.fmt.parseInt(u32, e.key_ptr.*, 10) catch continue,
            .key_size = @intCast(try num(try field(k, "key_size"))),
            .stripes = @intCast(try num(try field(af, "stripes"))),
            .af_hash = try parseHash(try str(try field(af, "hash"))),
            .offset = try num(try field(area, "offset")),
            .size = try num(try field(area, "size")),
            .cipher = try str(try field(area, "encryption")),
            .area_key = @intCast(try num(try field(area, "key_size"))),
            .kdf = parsed,
            .salt = try decode64(a, try str(try field(kdf, "salt"))),
        });
    }
    h.keyslots = slots.items;
    var digests: std.ArrayList(Digest) = .empty;
    var dit = (try obj(try field(top, "digests"))).iterator();
    while (dit.next()) |e| {
        const dg = try obj(e.value_ptr.*);
        if (!std.mem.eql(u8, try str(try field(dg, "type")), "pbkdf2")) continue;
        var mask: u64 = 0;
        const ks = try field(dg, "keyslots");
        if (ks == .array) for (ks.array.items) |x| {
            const id = std.fmt.parseInt(u6, try str(x), 10) catch continue;
            mask |= @as(u64, 1) << id;
        };
        try digests.append(a, .{
            .hash = try parseHash(try str(try field(dg, "hash"))),
            .iterations = @intCast(try num(try field(dg, "iterations"))),
            .salt = try decode64(a, try str(try field(dg, "salt"))),
            .digest = try decode64(a, try str(try field(dg, "digest"))),
            .keyslots = mask,
        });
    }
    h.digests = digests.items;
    var sit = (try obj(try field(top, "segments"))).iterator();
    while (sit.next()) |e| {
        const sg = try obj(e.value_ptr.*);
        if (!std.mem.eql(u8, try str(try field(sg, "type")), "crypt")) continue;
        h.segment_offset = try num(try field(sg, "offset"));
        h.segment_cipher = try str(try field(sg, "encryption"));
        if (sg.get("sector_size")) |v| h.sector_size = @intCast(try num(v));
        break;
    }
    if (top.get("config")) |c| {
        const co = try obj(c);
        if (co.get("keyslots_size")) |v| h.keyslots_size = try num(v);
    }
    h.arena = arena;
    return h;
}

fn readHeader(d: fs.Dev) !Header {
    var primary = try readCopy(d, 0);
    if (primary) |*p| {
        const second = readCopy(d, p.hdr_size) catch null;
        if (second) |s| {
            var sc = s;
            if (sc.seqid > p.seqid) {
                p.deinit();
                return sc;
            }
            sc.deinit();
        }
        return p.*;
    }
    for ([_]u64{ 16384, 32768, 65536, 131072, 262144, 524288, 1 << 20, 2 << 20, 4 << 20 }) |off| {
        if (try readCopy(d, off)) |s| return s;
    }
    return error.NotFound;
}

pub fn info(d: fs.Dev) !Info {
    var h = try readHeader(d);
    defer h.deinit();
    var out = std.mem.zeroes(Info);
    out.version = 2;
    out.keyslots = @intCast(h.keyslots.len);
    out.sector_size = h.sector_size;
    out.payload_offset = h.segment_offset;
    @memcpy(out.uuid[0..39], h.uuid[0..39]);
    @memcpy(out.label[0..47], h.label[0..47]);
    const n = @min(h.segment_cipher.len, out.cipher.len - 1);
    @memcpy(out.cipher[0..n], h.segment_cipher[0..n]);
    return out;
}

fn trySlot(d: fs.Dev, h: Header, ks: Keyslot, pass: []const u8, out: []u8) !bool {
    var dg: ?Digest = null;
    for (h.digests) |x| if (x.keyslots & (@as(u64, 1) << @intCast(ks.id)) != 0) {
        dg = x;
    };
    const digest = dg orelse return false;
    if (ks.key_size > 128 or ks.area_key > 128) return error.Unsupported;
    const area_len = ks.key_size * ks.stripes;
    const padded = std.mem.alignForward(usize, area_len, 512);
    if (padded > ks.size) return error.Invalid;
    var akey: [128]u8 = undefined;
    try derive(ks.kdf, akey[0..ks.area_key], pass, ks.salt);
    defer std.crypto.secureZero(u8, &akey);
    const area = try sys.gpa.alloc(u8, padded);
    defer {
        std.crypto.secureZero(u8, area);
        sys.gpa.free(area);
    }
    try d.readAt(ks.offset, area);
    try cipherData(ks.cipher, akey[0..ks.area_key], area, 0, 512, false);
    afMerge(ks.af_hash, area[0..area_len], out[0..ks.key_size], ks.stripes);
    var check: [64]u8 = undefined;
    if (digest.digest.len > check.len) return error.Unsupported;
    try pbkdf2(digest.hash, check[0..digest.digest.len], out[0..ks.key_size], digest.salt, digest.iterations);
    var diff: u8 = 0;
    for (check[0..digest.digest.len], digest.digest) |x, y| diff |= x ^ y;
    std.crypto.secureZero(u8, &check);
    return diff == 0;
}

pub const Unlocked = struct {
    key: [128]u8,
    len: usize,
    slot: u32,

    pub fn wipe(self: *Unlocked) void {
        std.crypto.secureZero(u8, &self.key);
    }
};

pub fn unlock(d: fs.Dev, pass: []const u8) !Unlocked {
    var h = try readHeader(d);
    defer h.deinit();
    var u = Unlocked{ .key = undefined, .len = 0, .slot = 0 };
    for (h.keyslots) |ks| {
        if (try trySlot(d, h, ks, pass, &u.key)) {
            u.len = ks.key_size;
            u.slot = ks.id;
            return u;
        }
    }
    u.wipe();
    return error.WrongPassphrase;
}

pub const FormatOptions = struct {
    label: []const u8 = "",
    time: u32 = 4,
    memory: u32 = 1048576,
    cpus: u24 = 4,
    digest_iterations: u32 = 200000,
};

const luks_hdr: u64 = 16384;
const area_offset: u64 = 2 * luks_hdr;
const data_offset: u64 = 16 << 20;
const af_stripes = 4000;

fn hexUuid(u: [16]u8, out: *[40]u8) void {
    @memset(out, 0);
    _ = std.fmt.bufPrint(out, "{x}-{x}-{x}-{x}-{x}", .{ u[0..4], u[4..6], u[6..8], u[8..10], u[10..16] }) catch {};
}

fn encode64(a: std.mem.Allocator, b: []const u8) ![]u8 {
    const out = try a.alloc(u8, b64.Encoder.calcSize(b.len));
    _ = b64.Encoder.encode(out, b);
    return out;
}

const SlotWrite = struct { salt: [32]u8, time: u32, memory: u32, cpus: u24 };

fn writeSlot(d: fs.Dev, key: []const u8, pass: []const u8, opts: FormatOptions) !SlotWrite {
    var w = SlotWrite{ .salt = undefined, .time = opts.time, .memory = opts.memory, .cpus = opts.cpus };
    random(&w.salt);
    var akey: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &akey);
    try derive(.{ .argon2 = .{ .mode = .argon2id, .time = opts.time, .memory = opts.memory, .cpus = opts.cpus } }, &akey, pass, &w.salt);
    const area_len = key.len * af_stripes;
    const padded = std.mem.alignForward(usize, area_len, 4096);
    const area = try sys.gpa.alloc(u8, padded);
    defer {
        std.crypto.secureZero(u8, area);
        sys.gpa.free(area);
    }
    @memset(area, 0);
    afSplit(.sha256, key, area[0..area_len], af_stripes);
    try cipherData("aes-xts-plain64", &akey, area, 0, 512, true);
    try d.writeAt(area_offset, area);
    return w;
}

fn writeHeaders(d: fs.Dev, uuid: *const [40]u8, label: []const u8, seqid: u64, key_len: usize, slot: SlotWrite, dsalt: []const u8, digest: []const u8, iter: u32, sector: u32) !void {
    var arena = std.heap.ArenaAllocator.init(sys.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const area_size = std.mem.alignForward(u64, key_len * af_stripes, 4096);
    const json = try std.fmt.allocPrint(a,
        \\{{"keyslots":{{"0":{{"type":"luks2","key_size":{d},"af":{{"type":"luks1","stripes":{d},"hash":"sha256"}},"area":{{"type":"raw","offset":"{d}","size":"{d}","encryption":"aes-xts-plain64","key_size":64}},"kdf":{{"type":"argon2id","time":{d},"memory":{d},"cpus":{d},"salt":"{s}"}}}}}},"tokens":{{}},"segments":{{"0":{{"type":"crypt","offset":"{d}","size":"dynamic","iv_tweak":"0","encryption":"aes-xts-plain64","sector_size":{d}}}}},"digests":{{"0":{{"type":"pbkdf2","keyslots":["0"],"segments":["0"],"hash":"sha256","iterations":{d},"salt":"{s}","digest":"{s}"}}}},"config":{{"json_size":"{d}","keyslots_size":"{d}"}}}}
    , .{ key_len, af_stripes, area_offset, area_size, slot.time, slot.memory, slot.cpus, try encode64(a, &slot.salt), data_offset, sector, iter, try encode64(a, dsalt), try encode64(a, digest), luks_hdr - bin_size, data_offset - area_offset });
    if (json.len >= luks_hdr - bin_size) return error.TooBig;
    const buf = try a.alloc(u8, luks_hdr);
    for ([_]u64{ 0, luks_hdr }) |off| {
        @memset(buf, 0);
        @memcpy(buf[0..6], if (off == 0) magic1 else magic2);
        std.mem.writeInt(u16, buf[6..8], 2, .big);
        std.mem.writeInt(u64, buf[8..16], luks_hdr, .big);
        std.mem.writeInt(u64, buf[16..24], seqid, .big);
        @memcpy(buf[24 .. 24 + label.len], label);
        @memcpy(buf[72..78], "sha256");
        random(buf[104..168]);
        @memcpy(buf[168..208], uuid);
        std.mem.writeInt(u64, buf[256..264], off, .big);
        @memcpy(buf[bin_size .. bin_size + json.len], json);
        setCsum(buf);
        try d.writeAt(off, buf);
    }
}

pub fn defaults() FormatOptions {
    var o = FormatOptions{};
    var buf: [256]u8 = undefined;
    const text = sys.readFile("/proc/meminfo", &buf) catch return o;
    if (std.mem.startsWith(u8, text, "MemTotal:")) {
        var it = std.mem.tokenizeScalar(u8, text[9..], ' ');
        if (it.next()) |n| {
            const kib = std.fmt.parseInt(u64, n, 10) catch return o;
            o.memory = @intCast(@max(65536, @min(@as(u64, o.memory), kib / 4)));
        }
    }
    calibrate(&o, 2000);
    return o;
}

fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn calibrate(o: *FormatOptions, target_ms: u64) void {
    var out: [64]u8 = undefined;
    const salt = [_]u8{0} ** 32;
    const start = nowMs();
    derive(.{ .argon2 = .{ .mode = .argon2id, .time = 1, .memory = 65536, .cpus = o.cpus } }, &out, "calibrate", &salt) catch return;
    const pass = @max(nowMs() - start, 1);
    while (o.memory > 65536 and pass * (o.memory / 65536) * o.time > target_ms) o.memory /= 2;
    if (o.memory < 65536) o.memory = 65536;
}

pub fn format(d: fs.Dev, pass: []const u8, opts: FormatOptions) !void {
    if (opts.label.len > 47 or pass.len == 0) return error.Invalid;
    if (d.size <= data_offset + (1 << 20)) return error.TooBig;
    var key: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    random(&key);
    var u: [16]u8 = undefined;
    random(&u);
    u[6] = (u[6] & 0x0f) | 0x40;
    u[8] = (u[8] & 0x3f) | 0x80;
    var uuid: [40]u8 = undefined;
    hexUuid(u, &uuid);
    try d.zero(0, data_offset);
    const slot = try writeSlot(d, &key, pass, opts);
    var dsalt: [32]u8 = undefined;
    random(&dsalt);
    var digest: [32]u8 = undefined;
    try pbkdf2(.sha256, &digest, &key, &dsalt, opts.digest_iterations);
    try writeHeaders(d, &uuid, opts.label, 1, key.len, slot, &dsalt, &digest, opts.digest_iterations, if (d.sector >= 4096) 4096 else 512);
    try d.sync();
}

pub fn changePassphrase(d: fs.Dev, old: []const u8, new: []const u8, opts: FormatOptions) !void {
    if (new.len == 0) return error.Invalid;
    var h = try readHeader(d);
    defer h.deinit();
    if (h.keyslots.len != 1 or h.keyslots[0].offset != area_offset or h.segment_offset != data_offset or h.hdr_size != luks_hdr) return error.Unsupported;
    var u = try unlock(d, old);
    defer u.wipe();
    if (u.len != 64) return error.Unsupported;
    var dg: ?Digest = null;
    for (h.digests) |x| if (x.keyslots & 1 != 0) {
        dg = x;
    };
    const digest = dg orelse return error.Invalid;
    const slot = try writeSlot(d, u.key[0..64], new, opts);
    const label = std.mem.sliceTo(&h.label, 0);
    try writeHeaders(d, &h.uuid, label, h.seqid + 1, 64, slot, digest.salt, digest.digest, digest.iterations, h.sector_size);
    try d.sync();
}

const DmIoctl = extern struct {
    version: [3]u32,
    data_size: u32,
    data_start: u32,
    target_count: u32,
    open_count: i32,
    flags: u32,
    event_nr: u32,
    padding: u32,
    dev: u64,
    name: [128]u8,
    uuid: [129]u8,
    data: [7]u8,
};

const DmTarget = extern struct {
    sector_start: u64,
    length: u64,
    status: i32,
    next: u32,
    target_type: [16]u8,
};

fn dmCmd(nr: u32) u32 {
    return 0xc0000000 | (@as(u32, @sizeOf(DmIoctl)) << 16) | (0xfd << 8) | nr;
}

fn dmHeader(buf: []u8, name: []const u8, uuid: []const u8, flags: u32) *DmIoctl {
    @memset(buf, 0);
    const h: *DmIoctl = @ptrCast(@alignCast(buf.ptr));
    h.version = .{ 4, 0, 0 };
    h.data_size = @intCast(buf.len);
    h.data_start = @sizeOf(DmIoctl);
    h.flags = flags;
    @memcpy(h.name[0..name.len], name);
    @memcpy(h.uuid[0..uuid.len], uuid);
    return h;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 127) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

pub fn open(path: [*:0]const u8, pass: []const u8, name: []const u8, read_only: bool) !void {
    if (!validName(name)) return error.Invalid;
    var d = try fs.Dev.open(path, false);
    defer d.close();
    var h = try readHeader(d);
    defer h.deinit();
    var u = try unlock(d, pass);
    defer u.wipe();
    var st: linux.Statx = undefined;
    _ = try sys.check(linux.statx(d.fd, "", 0x1000, .{ .TYPE = true }, &st));
    if (st.mode & linux.S.IFMT != linux.S.IFBLK) return error.Invalid;
    if (d.size <= h.segment_offset) return error.Invalid;
    const major = st.rdev_major;
    const minor = st.rdev_minor;
    var uuid_buf: [129]u8 = undefined;
    var compact: [32]u8 = undefined;
    var n: usize = 0;
    for (std.mem.sliceTo(&h.uuid, 0)) |c| if (c != '-' and n < compact.len) {
        compact[n] = c;
        n += 1;
    };
    const uuid = std.fmt.bufPrint(&uuid_buf, "CRYPT-LUKS2-{s}-{s}", .{ compact[0..n], name }) catch return error.Invalid;
    const ctl = try sys.open("/dev/mapper/control", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    defer sys.close(ctl);
    var buf: [16384]u8 align(8) = undefined;
    defer std.crypto.secureZero(u8, &buf);
    _ = dmHeader(&buf, name, uuid, 0);
    _ = try sys.ioctl(ctl, dmCmd(3), @intFromPtr(&buf));
    errdefer {
        _ = dmHeader(&buf, name, "", 0);
        _ = sys.ioctl(ctl, dmCmd(4), @intFromPtr(&buf)) catch {};
    }
    const secure: u32 = 1 << 15;
    const hdr = dmHeader(&buf, name, "", secure | (if (read_only) @as(u32, 1) else 0));
    hdr.target_count = 1;
    const spec: *DmTarget = @ptrCast(@alignCast(buf[@sizeOf(DmIoctl)..].ptr));
    const start = @sizeOf(DmIoctl) + @sizeOf(DmTarget);
    spec.sector_start = 0;
    spec.length = (d.size - h.segment_offset) / 512;
    @memcpy(spec.target_type[0..5], "crypt");
    var hex: [256]u8 = undefined;
    const hexkey = std.fmt.bufPrint(&hex, "{x}", .{u.key[0..u.len]}) catch return error.Invalid;
    defer std.crypto.secureZero(u8, &hex);
    const extra: []const u8 = if (h.sector_size != 512) " 1 sector_size:4096" else "";
    const params = std.fmt.bufPrint(buf[start..], "{s} {s} 0 {d}:{d} {d}{s}\x00", .{ h.segment_cipher, hexkey, major, minor, h.segment_offset / 512, extra }) catch return error.TooBig;
    spec.next = @intCast(std.mem.alignForward(usize, @sizeOf(DmTarget) + params.len, 8));
    _ = try sys.ioctl(ctl, dmCmd(9), @intFromPtr(&buf));
    const res = dmHeader(&buf, name, "", secure);
    _ = try sys.ioctl(ctl, dmCmd(6), @intFromPtr(&buf));
    const dev = res.dev;
    var pb: [256]u8 = undefined;
    const node = try sys.pathZ(&pb, "/dev/mapper/{s}", .{name});
    if (!sys.exists(node)) {
        _ = linux.mknodat(linux.AT.FDCWD, node, linux.S.IFBLK | 0o600, @intCast(dev));
    }
}

pub fn close(name: []const u8) !void {
    if (!validName(name)) return error.Invalid;
    const ctl = try sys.open("/dev/mapper/control", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    defer sys.close(ctl);
    var buf: [4096]u8 align(8) = undefined;
    _ = dmHeader(&buf, name, "", 0);
    _ = try sys.ioctl(ctl, dmCmd(4), @intFromPtr(&buf));
    var pb: [256]u8 = undefined;
    const node = try sys.pathZ(&pb, "/dev/mapper/{s}", .{name});
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, node, 0x100, .{ .TYPE = true }, &st)) == .SUCCESS and st.mode & linux.S.IFMT == linux.S.IFBLK) _ = linux.unlinkat(linux.AT.FDCWD, node, 0);
}

fn testImage(name: []const u8, size: u64, out: []u8) ![*:0]const u8 {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, name);
    const p = try sys.pathZ(out, "{s}/luks.img", .{root});
    const fd = try sys.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    defer sys.close(fd);
    _ = try sys.check(linux.ftruncate(fd, @intCast(size)));
    return p;
}

test "dm ioctl layout and numbers" {
    try std.testing.expectEqual(@as(usize, 312), @sizeOf(DmIoctl));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(DmTarget));
    try std.testing.expectEqual(@as(u32, 0xc138fd03), dmCmd(3));
}

test "xts round trips a sector" {
    var key: [64]u8 = undefined;
    for (key[0..32], 0..) |*k, i| k.* = @intCast(i);
    for (key[32..64], 0..) |*k, i| k.* = @intCast(i + 0x20);
    var data: [512]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    var copy = data;
    try cipherData("aes-xts-plain64", &key, &copy, 7, 512, true);
    try std.testing.expect(!std.mem.eql(u8, &copy, &data));
    try cipherData("aes-xts-plain64", &key, &copy, 7, 512, false);
    try std.testing.expectEqualSlices(u8, &data, &copy);
}

test "anti-forensic split merges back" {
    var key: [64]u8 = undefined;
    random(&key);
    const buf = try std.testing.allocator.alloc(u8, 64 * 10);
    defer std.testing.allocator.free(buf);
    afSplit(.sha256, &key, buf, 10);
    var out: [64]u8 = undefined;
    afMerge(.sha256, buf, &out, 10);
    try std.testing.expectEqualSlices(u8, &key, &out);
}

test "format, unlock and change the passphrase on an image" {
    var pb: [600]u8 = undefined;
    const path = try testImage("luks", 24 << 20, &pb);
    var d = try fs.Dev.open(path, true);
    defer d.close();
    const fast = FormatOptions{ .time = 1, .memory = 8192, .cpus = 1, .digest_iterations = 1000, .label = "vault" };
    try format(d, "correct horse", fast);
    const i = try info(d);
    try std.testing.expectEqual(@as(u64, 16 << 20), i.payload_offset);
    try std.testing.expectEqualStrings("vault", sys.cstr(&i.label));
    try std.testing.expectEqualStrings("aes-xts-plain64", sys.cstr(&i.cipher));
    var u = try unlock(d, "correct horse");
    const first = u.key;
    u.wipe();
    try std.testing.expectError(error.WrongPassphrase, unlock(d, "wrong"));
    try changePassphrase(d, "correct horse", "battery staple", fast);
    try std.testing.expectError(error.WrongPassphrase, unlock(d, "correct horse"));
    var v = try unlock(d, "battery staple");
    defer v.wipe();
    try std.testing.expectEqualSlices(u8, first[0..64], v.key[0..64]);
    const probe = try fs.probe(d);
    try std.testing.expectEqualStrings("crypto_LUKS", sys.cstr(&probe.type));
}

test "volumes made by cryptsetup unlock" {
    const dir = std.c.getenv("SINTY_LUKS_FIXTURES") orelse return error.SkipZigTest;
    var pb: [600]u8 = undefined;
    for ([_][]const u8{ "argon.img", "pbkdf.img" }) |f| {
        var d = try fs.Dev.open(try sys.pathZ(&pb, "{s}/{s}", .{ std.mem.span(dir), f }), false);
        defer d.close();
        var u = try unlock(d, "sinty test pass");
        defer u.wipe();
        var kb: [600]u8 = undefined;
        const want = try sys.readFile(try sys.pathZ(&kb, "{s}/{s}.key", .{ std.mem.span(dir), f }), &kb);
        try std.testing.expectEqualSlices(u8, want, u.key[0..u.len]);
        try std.testing.expectError(error.WrongPassphrase, unlock(d, "nope"));
    }
}
