const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const fs = @import("fs.zig");

const crc_table = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u32 = i;
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ 0x82f63b78 else c >> 1;
        e.* = c;
    }
    break :blk t;
};

pub fn crc32c(seed: u32, data: []const u8) u32 {
    var c = seed;
    for (data) |b| c = crc_table[(c ^ b) & 0xff] ^ (c >> 8);
    return c;
}

fn le32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

const inode_size = 256;
const desc_size = 64;
const first_ino = 11;
const root_ino = 2;
const journal_ino = 8;
const lpf_ino = 11;
const lpf_blocks = 4;

const Geometry = struct {
    bs: u32,
    blocks: u64,
    bpg: u32,
    groups: u32,
    ipg: u32,
    itb: u32,
    gdt: u32,
    journal: u32,

    fn groupBlocks(self: Geometry, g: u32) u32 {
        if (g + 1 < self.groups) return self.bpg;
        return @intCast(self.blocks - @as(u64, g) * self.bpg);
    }

    fn start(self: Geometry, g: u32) u64 {
        return @as(u64, g) * self.bpg;
    }

    fn backup(self: Geometry, g: u32) bool {
        _ = self;
        if (g <= 1) return true;
        for ([_]u32{ 3, 5, 7 }) |base| {
            var p: u64 = base;
            while (p < g) p *= base;
            if (p == g) return true;
        }
        return false;
    }

    fn overhead(self: Geometry, g: u32) u32 {
        return (if (self.backup(g)) 1 + self.gdt else 0) + 2 + self.itb;
    }

    fn blockBitmap(self: Geometry, g: u32) u64 {
        return self.start(g) + (if (self.backup(g)) 1 + self.gdt else 0);
    }

    fn dataStart(self: Geometry, g: u32) u64 {
        return self.start(g) + self.overhead(g);
    }
};

fn journalBlocks(blocks: u64) u32 {
    if (blocks < 2048) return 0;
    if (blocks < 32768) return 1024;
    if (blocks < 256 * 1024) return 4096;
    if (blocks < 512 * 1024) return 8192;
    if (blocks < 4096 * 1024) return 16384;
    if (blocks < 8192 * 1024) return 32768;
    return 65536;
}

fn geometry(size: u64) !Geometry {
    return plan(size, 4096);
}

fn plan(size: u64, bs: u32) !Geometry {
    var blocks = size / bs;
    if (blocks < 1024) return error.TooBig;
    const bpg: u32 = bs * 8;
    var g = Geometry{ .bs = bs, .blocks = blocks, .bpg = bpg, .groups = 0, .ipg = 0, .itb = 0, .gdt = 0, .journal = 0 };
    while (true) {
        g.blocks = blocks;
        g.groups = @intCast((blocks + bpg - 1) / bpg);
        const per_block = bs / inode_size;
        const want: u64 = @max(size / 16384, 64);
        var ipg: u64 = (want + g.groups - 1) / g.groups;
        ipg = std.mem.alignForward(u64, @max(ipg, per_block), @max(per_block, 8));
        if (ipg > bs * 8) ipg = bs * 8;
        g.ipg = @intCast(ipg);
        g.itb = @intCast(ipg * inode_size / bs);
        g.gdt = @intCast((@as(u64, g.groups) * desc_size + bs - 1) / bs);
        const last = g.groups - 1;
        if (g.groups > 1 and g.groupBlocks(last) < g.overhead(last) + 50) {
            blocks = @as(u64, last) * bpg;
            continue;
        }
        if (g.groupBlocks(0) <= g.overhead(0) + 1 + lpf_blocks + 16) return error.TooBig;
        break;
    }
    g.journal = journalBlocks(g.blocks);
    return g;
}

const Extent = struct { logical: u32, start: u64, len: u32 };

const Alloc = struct {
    geo: Geometry,
    group: u32 = 0,
    next: u64,
    used: []u32,

    fn take(self: *Alloc, want: u32) !Extent {
        while (self.group < self.geo.groups) {
            const end = self.geo.start(self.group) + self.geo.groupBlocks(self.group);
            if (self.next < end) {
                const n: u32 = @intCast(@min(@as(u64, want), end - self.next, 32768));
                const e = Extent{ .logical = 0, .start = self.next, .len = n };
                self.next += n;
                self.used[self.group] += n;
                return e;
            }
            self.group += 1;
            if (self.group < self.geo.groups) self.next = self.geo.dataStart(self.group);
        }
        return error.TooBig;
    }
};

const Ctx = struct {
    d: fs.Dev,
    geo: Geometry,
    seed: u32,
    now: u32,

    fn blockOffset(self: Ctx, b: u64) u64 {
        return b * self.geo.bs;
    }

    fn inodeOffset(self: Ctx, ino: u32) u64 {
        const idx = ino - 1;
        const g = idx / self.geo.ipg;
        const table = self.geo.blockBitmap(g) + 2;
        return self.blockOffset(table) + @as(u64, idx % self.geo.ipg) * inode_size;
    }

    fn writeInode(self: Ctx, ino: u32, raw: *[inode_size]u8) !void {
        @memset(raw[0x7c..0x7e], 0);
        @memset(raw[0x82..0x84], 0);
        var c = crc32c(self.seed, &le32(ino));
        c = crc32c(c, raw[0x64..0x68]);
        c = crc32c(c, raw);
        std.mem.writeInt(u16, raw[0x7c..0x7e], @truncate(c), .little);
        std.mem.writeInt(u16, raw[0x82..0x84], @truncate(c >> 16), .little);
        try self.d.writeAt(self.inodeOffset(ino), raw);
    }

    fn dirBlock(self: Ctx, ino: u32, block: []u8) void {
        const tail = block.len - 12;
        @memset(block[tail..], 0);
        std.mem.writeInt(u16, block[tail + 4 ..][0..2], 12, .little);
        block[tail + 7] = 0xde;
        var c = crc32c(self.seed, &le32(ino));
        c = crc32c(c, &le32(0));
        c = crc32c(c, block[0..tail]);
        std.mem.writeInt(u32, block[tail + 8 ..][0..4], c, .little);
    }
};

fn dirent(buf: []u8, ino: u32, rec_len: usize, name: []const u8, kind: u8) void {
    std.mem.writeInt(u32, buf[0..4], ino, .little);
    std.mem.writeInt(u16, buf[4..6], @intCast(rec_len), .little);
    buf[6] = @intCast(name.len);
    buf[7] = kind;
    @memcpy(buf[8 .. 8 + name.len], name);
}

fn fileInode(raw: *[inode_size]u8, mode: u16, links: u16, size: u64, bs: u32, extents: []const Extent, now: u32) void {
    @memset(raw, 0);
    std.mem.writeInt(u16, raw[0..2], mode, .little);
    std.mem.writeInt(u32, raw[0x04..0x08], @truncate(size), .little);
    std.mem.writeInt(u32, raw[0x6c..0x70], @intCast(size >> 32), .little);
    for ([_]usize{ 0x08, 0x0c, 0x10, 0x90 }) |o| std.mem.writeInt(u32, raw[o..][0..4], now, .little);
    std.mem.writeInt(u16, raw[0x1a..0x1c], links, .little);
    var nblocks: u64 = 0;
    for (extents) |e| nblocks += e.len;
    const sectors = nblocks * (bs / 512);
    std.mem.writeInt(u32, raw[0x1c..0x20], @truncate(sectors), .little);
    std.mem.writeInt(u16, raw[0x74..0x76], @intCast(sectors >> 32), .little);
    std.mem.writeInt(u32, raw[0x20..0x24], 0x80000, .little);
    std.mem.writeInt(u16, raw[0x80..0x82], 32, .little);
    const ib = raw[0x28..0x64];
    std.mem.writeInt(u16, ib[0..2], 0xf30a, .little);
    std.mem.writeInt(u16, ib[2..4], @intCast(extents.len), .little);
    std.mem.writeInt(u16, ib[4..6], 4, .little);
    for (extents, 0..) |e, i| {
        const x = ib[12 + i * 12 ..][0..12];
        std.mem.writeInt(u32, x[0..4], e.logical, .little);
        std.mem.writeInt(u16, x[4..6], @intCast(e.len), .little);
        std.mem.writeInt(u16, x[6..8], @intCast(e.start >> 32), .little);
        std.mem.writeInt(u32, x[8..12], @truncate(e.start), .little);
    }
}

pub const Options = struct {
    encrypt: bool = false,
};

pub fn mkfs(d: fs.Dev, label: []const u8) !void {
    return mkfsWith(d, label, .{});
}

pub fn mkfsWith(d: fs.Dev, label: []const u8, opts: Options) !void {
    if (label.len > 16) return error.TooBig;
    const geo = try geometry(d.size);
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const now: u32 = @intCast(ts.sec);
    var uuid: [16]u8 = undefined;
    var hash_seed: [16]u8 = undefined;
    fsRandom(&uuid);
    fsRandom(&hash_seed);
    uuid[6] = (uuid[6] & 0x0f) | 0x40;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    hash_seed[6] = (hash_seed[6] & 0x0f) | 0x40;
    hash_seed[8] = (hash_seed[8] & 0x3f) | 0x80;
    const ctx = Ctx{ .d = d, .geo = geo, .seed = crc32c(0xffffffff, &uuid), .now = now };
    const bs = geo.bs;

    const used = try sys.gpa.alloc(u32, geo.groups);
    defer sys.gpa.free(used);
    @memset(used, 0);
    var alloc = Alloc{ .geo = geo, .next = geo.dataStart(0), .used = used };
    const root_ext = try alloc.take(1);
    var lpf_ext = try alloc.take(lpf_blocks);
    if (lpf_ext.len != lpf_blocks) return error.TooBig;
    var jext: [4]Extent = undefined;
    var nj: usize = 0;
    var jleft = geo.journal;
    var logical: u32 = 0;
    while (jleft > 0) {
        if (nj == jext.len) return error.TooBig;
        var e = try alloc.take(jleft);
        e.logical = logical;
        logical += e.len;
        jleft -= e.len;
        jext[nj] = e;
        nj += 1;
    }

    try d.zero(0, ctx.blockOffset(geo.dataStart(0)));
    const block = try sys.gpa.alloc(u8, bs);
    defer sys.gpa.free(block);

    var raw: [inode_size]u8 = undefined;
    @memset(block, 0);
    dirent(block[0..], root_ino, 12, ".", 2);
    dirent(block[12..], root_ino, 12, "..", 2);
    dirent(block[24..], lpf_ino, bs - 24 - 12, "lost+found", 2);
    ctx.dirBlock(root_ino, block);
    try d.writeAt(ctx.blockOffset(root_ext.start), block);
    fileInode(&raw, 0o40755, 3, bs, bs, &.{root_ext}, now);
    try ctx.writeInode(root_ino, &raw);

    var k: u32 = 0;
    while (k < lpf_blocks) : (k += 1) {
        @memset(block, 0);
        if (k == 0) {
            dirent(block[0..], lpf_ino, 12, ".", 2);
            dirent(block[12..], root_ino, bs - 12 - 12, "..", 2);
        } else dirent(block[0..], 0, bs - 12, "", 0);
        ctx.dirBlock(lpf_ino, block);
        try d.writeAt(ctx.blockOffset(lpf_ext.start + k), block);
    }
    lpf_ext.logical = 0;
    fileInode(&raw, 0o40700, 2, @as(u64, lpf_blocks) * bs, bs, &.{lpf_ext}, now);
    try ctx.writeInode(lpf_ino, &raw);

    if (geo.journal > 0) {
        @memset(block, 0);
        std.mem.writeInt(u32, block[0..4], 0xc03b3998, .big);
        std.mem.writeInt(u32, block[4..8], 4, .big);
        std.mem.writeInt(u32, block[12..16], bs, .big);
        std.mem.writeInt(u32, block[16..20], geo.journal, .big);
        std.mem.writeInt(u32, block[20..24], 1, .big);
        std.mem.writeInt(u32, block[24..28], 1, .big);
        @memcpy(block[48..64], &uuid);
        std.mem.writeInt(u32, block[64..68], 1, .big);
        @memcpy(block[256..272], &uuid);
        try d.writeAt(ctx.blockOffset(jext[0].start), block);
        fileInode(&raw, 0o100600, 1, @as(u64, geo.journal) * bs, bs, jext[0..nj], now);
        try ctx.writeInode(journal_ino, &raw);
    }

    var sb = std.mem.zeroes([1024]u8);
    const inodes: u64 = @as(u64, geo.ipg) * geo.groups;
    var free_blocks: u64 = 0;
    const gdt = try sys.gpa.alloc(u8, @as(usize, geo.gdt) * bs);
    defer sys.gpa.free(gdt);
    @memset(gdt, 0);
    var g: u32 = 0;
    while (g < geo.groups) : (g += 1) {
        const gb = geo.groupBlocks(g);
        const fb = gb - geo.overhead(g) - used[g];
        free_blocks += fb;
        @memset(block, 0);
        var b: u32 = 0;
        while (b < geo.overhead(g) + used[g]) : (b += 1) block[b / 8] |= @as(u8, 1) << @intCast(b % 8);
        b = gb;
        while (b < geo.bpg) : (b += 1) block[b / 8] |= @as(u8, 1) << @intCast(b % 8);
        const bb_csum = crc32c(ctx.seed, block[0 .. geo.bpg / 8]);
        try d.writeAt(ctx.blockOffset(geo.blockBitmap(g)), block);
        @memset(block, 0);
        const used_inodes: u32 = if (g == 0) first_ino else 0;
        var i: u32 = 0;
        while (i < used_inodes) : (i += 1) block[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        i = geo.ipg;
        while (i < bs * 8) : (i += 1) block[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        const ib_csum = crc32c(ctx.seed, block[0 .. geo.ipg / 8]);
        try d.writeAt(ctx.blockOffset(geo.blockBitmap(g) + 1), block);

        const desc = gdt[@as(usize, g) * desc_size ..][0..desc_size];
        const bbm = geo.blockBitmap(g);
        const fields = [_][2]u64{ .{ 0x00, bbm }, .{ 0x04, bbm + 1 }, .{ 0x08, bbm + 2 } };
        for (fields) |f| {
            std.mem.writeInt(u32, desc[f[0]..][0..4], @truncate(f[1]), .little);
            std.mem.writeInt(u32, desc[f[0] + 0x20 ..][0..4], @intCast(f[1] >> 32), .little);
        }
        std.mem.writeInt(u16, desc[0x0c..0x0e], @truncate(fb), .little);
        std.mem.writeInt(u16, desc[0x2c..0x2e], @intCast(fb >> 16), .little);
        const free_inodes = geo.ipg - used_inodes;
        std.mem.writeInt(u16, desc[0x0e..0x10], @truncate(free_inodes), .little);
        std.mem.writeInt(u16, desc[0x2e..0x30], @intCast(free_inodes >> 16), .little);
        if (g == 0) std.mem.writeInt(u16, desc[0x10..0x12], 2, .little);
        std.mem.writeInt(u16, desc[0x12..0x14], if (g == 0) 0x4 else 0x1, .little);
        const unused = geo.ipg - used_inodes;
        std.mem.writeInt(u16, desc[0x1c..0x1e], @truncate(unused), .little);
        std.mem.writeInt(u16, desc[0x32..0x34], @intCast(unused >> 16), .little);
        std.mem.writeInt(u16, desc[0x18..0x1a], @truncate(bb_csum), .little);
        std.mem.writeInt(u16, desc[0x38..0x3a], @truncate(bb_csum >> 16), .little);
        std.mem.writeInt(u16, desc[0x1a..0x1c], @truncate(ib_csum), .little);
        std.mem.writeInt(u16, desc[0x3a..0x3c], @truncate(ib_csum >> 16), .little);
        var c = crc32c(ctx.seed, &le32(g));
        c = crc32c(c, desc);
        std.mem.writeInt(u16, desc[0x1e..0x20], @truncate(c), .little);
    }

    const free_inodes: u64 = inodes - first_ino;
    std.mem.writeInt(u32, sb[0x00..0x04], @intCast(inodes), .little);
    std.mem.writeInt(u32, sb[0x04..0x08], @truncate(geo.blocks), .little);
    std.mem.writeInt(u32, sb[0x150..0x154], @intCast(geo.blocks >> 32), .little);
    const reserved = geo.blocks / 20;
    std.mem.writeInt(u32, sb[0x08..0x0c], @truncate(reserved), .little);
    std.mem.writeInt(u32, sb[0x154..0x158], @intCast(reserved >> 32), .little);
    std.mem.writeInt(u32, sb[0x0c..0x10], @truncate(free_blocks), .little);
    std.mem.writeInt(u32, sb[0x158..0x15c], @intCast(free_blocks >> 32), .little);
    std.mem.writeInt(u32, sb[0x10..0x14], @intCast(free_inodes), .little);
    const log: u32 = std.math.log2_int(u32, bs) - 10;
    std.mem.writeInt(u32, sb[0x18..0x1c], log, .little);
    std.mem.writeInt(u32, sb[0x1c..0x20], log, .little);
    std.mem.writeInt(u32, sb[0x20..0x24], geo.bpg, .little);
    std.mem.writeInt(u32, sb[0x24..0x28], geo.bpg, .little);
    std.mem.writeInt(u32, sb[0x28..0x2c], geo.ipg, .little);
    std.mem.writeInt(u32, sb[0x30..0x34], now, .little);
    std.mem.writeInt(u16, sb[0x36..0x38], 0xffff, .little);
    std.mem.writeInt(u16, sb[0x38..0x3a], 0xef53, .little);
    std.mem.writeInt(u16, sb[0x3a..0x3c], 1, .little);
    std.mem.writeInt(u16, sb[0x3c..0x3e], 1, .little);
    std.mem.writeInt(u32, sb[0x40..0x44], now, .little);
    std.mem.writeInt(u32, sb[0x4c..0x50], 1, .little);
    std.mem.writeInt(u32, sb[0x54..0x58], first_ino, .little);
    std.mem.writeInt(u16, sb[0x58..0x5a], inode_size, .little);
    const has_journal: u32 = if (geo.journal > 0) 0x4 else 0;
    std.mem.writeInt(u32, sb[0x5c..0x60], has_journal | 0x8 | 0x20, .little);
    const encrypt: u32 = if (opts.encrypt) 0x10000 else 0;
    std.mem.writeInt(u32, sb[0x60..0x64], 0x2 | 0x40 | 0x80 | encrypt, .little);
    std.mem.writeInt(u32, sb[0x64..0x68], 0x1 | 0x2 | 0x8 | 0x20 | 0x40 | 0x400, .little);
    @memcpy(sb[0x68..0x78], &uuid);
    @memcpy(sb[0x78 .. 0x78 + label.len], label);
    if (geo.journal > 0) std.mem.writeInt(u32, sb[0xe0..0xe4], journal_ino, .little);
    @memcpy(sb[0xec..0xfc], &hash_seed);
    sb[0xfc] = 1;
    std.mem.writeInt(u16, sb[0xfe..0x100], desc_size, .little);
    std.mem.writeInt(u32, sb[0x100..0x104], 0x000c, .little);
    std.mem.writeInt(u32, sb[0x108..0x10c], now, .little);
    if (geo.journal > 0) {
        sb[0xfd] = 1;
        fileInode(&raw, 0o100600, 1, @as(u64, geo.journal) * bs, bs, jext[0..nj], now);
        @memcpy(sb[0x10c .. 0x10c + 60], raw[0x28..0x64]);
        std.mem.writeInt(u32, sb[0x148..0x14c], 0, .little);
        std.mem.writeInt(u32, sb[0x14c..0x150], geo.journal * bs, .little);
    }
    std.mem.writeInt(u16, sb[0x15c..0x15e], 32, .little);
    std.mem.writeInt(u16, sb[0x15e..0x160], 32, .little);
    std.mem.writeInt(u32, sb[0x160..0x164], 2, .little);
    sb[0x175] = 1;

    g = 0;
    while (g < geo.groups) : (g += 1) {
        if (!geo.backup(g)) continue;
        std.mem.writeInt(u16, sb[0x5a..0x5c], @intCast(g), .little);
        std.mem.writeInt(u32, sb[0x3fc..0x400], crc32c(0xffffffff, sb[0..0x3fc]), .little);
        const base = ctx.blockOffset(geo.start(g));
        if (g == 0) {
            try d.writeAt(1024, &sb);
        } else {
            @memset(block, 0);
            @memcpy(block[0..1024], &sb);
            try d.writeAt(base, block);
        }
        try d.writeAt(base + bs, gdt);
    }
    try d.sync();
}

fn fsRandom(buf: []u8) void {
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.getrandom(buf[n..].ptr, buf.len - n, 0);
        if (linux.errno(rc) == .SUCCESS) n += rc;
    }
}

test "raw crc32c matches the standard check value" {
    try std.testing.expectEqual(@as(u32, 0xe3069283), ~crc32c(0xffffffff, "123456789"));
}

test "sparse superblock groups" {
    const g = Geometry{ .bs = 4096, .blocks = 0, .bpg = 32768, .groups = 100, .ipg = 0, .itb = 0, .gdt = 0, .journal = 0 };
    var have: [16]u32 = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) if (g.backup(i)) {
        have[n] = i;
        n += 1;
    };
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 3, 5, 7, 9, 25, 27, 49, 81 }, have[0..n]);
}
