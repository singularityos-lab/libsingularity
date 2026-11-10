const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const fs = @import("fs.zig");

const magic: u32 = 0xf2f52010;
const block = 4096;
const seg_blocks = 512;
const seg_bytes = block * seg_blocks;
const sit_per_block = 55;
const nat_per_block = 455;
const journal_size = 507;
const summary_size = 7;
const root_ino = 3;
const node_ino = 1;
const meta_ino = 2;
const cp_chksum_offset = 4092;

pub fn crc32(seed: u32, data: []const u8) u32 {
    var c = seed;
    for (data) |b| {
        c ^= b;
        for (0..8) |_| c = (c >> 1) ^ (if (c & 1 != 0) @as(u32, 0xedb88320) else 0);
    }
    return c;
}

fn divUp(a: u64, b: u64) u64 {
    return (a + b - 1) / b;
}

pub const Layout = struct {
    blocks: u64,
    segment0: u32,
    segments: u32,
    ckpt_segs: u32 = 2,
    sit_segs: u32,
    nat_segs: u32,
    ssa_segs: u32,
    main_segs: u32,
    reserved: u32,
    overprov: u32,
    user_blocks: u64,

    fn cp(l: Layout) u32 {
        return l.segment0;
    }
    fn sit(l: Layout) u32 {
        return l.cp() + l.ckpt_segs * seg_blocks;
    }
    fn nat(l: Layout) u32 {
        return l.sit() + l.sit_segs * seg_blocks;
    }
    fn ssa(l: Layout) u32 {
        return l.nat() + l.nat_segs * seg_blocks;
    }
    fn main(l: Layout) u32 {
        return l.ssa() + l.ssa_segs * seg_blocks;
    }
    fn sitBitmap(l: Layout) u32 {
        return l.sit_segs / 2 * seg_blocks / 8;
    }
    fn natBitmap(l: Layout) u32 {
        return l.nat_segs / 2 * seg_blocks / 8;
    }
};

pub fn layout(bytes: u64) !Layout {
    const blocks = bytes / block;
    const segment0: u32 = seg_blocks;
    if (blocks < segment0 + 24 * seg_blocks) return error.TooBig;
    const segments_u64 = (blocks - segment0) / seg_blocks;
    if (segments_u64 > 0xffffffff / seg_blocks) return error.TooBig;
    const segments: u32 = @intCast(segments_u64);
    const sit_segs: u32 = @intCast(divUp(divUp(segments, sit_per_block), seg_blocks) * 2);
    const avail_nat = @as(u64, segments - 2 - sit_segs) * seg_blocks;
    const sit_bitmap = sit_segs / 2 * seg_blocks / 8;
    if (193 + sit_bitmap >= cp_chksum_offset) return error.TooBig;
    const max_nat: u64 = (cp_chksum_offset - 193 + 1 - sit_bitmap) * 8 / seg_blocks;
    const nat_segs: u32 = @intCast(@min(divUp(divUp(avail_nat, nat_per_block), seg_blocks), max_nat) * 2);
    const avail_ssa = @as(u64, segments - 2 - sit_segs - nat_segs) * seg_blocks;
    const ssa_segs: u32 = @intCast(divUp(avail_ssa / seg_blocks + 1, seg_blocks));
    const meta = 2 + sit_segs + nat_segs + ssa_segs;
    if (meta >= segments) return error.TooBig;
    const main_segs = segments - meta;
    var best: ?Layout = null;
    var ovp: u32 = 1;
    while (ovp <= 50) : (ovp += 1) {
        const reserved = 2 * (100 / ovp + 1) + 6;
        if (reserved >= main_segs) continue;
        const overprov = (main_segs - reserved) * ovp / 100 + reserved;
        if (overprov >= main_segs) continue;
        const user = @as(u64, main_segs - overprov) * seg_blocks;
        if (best == null or user > best.?.user_blocks) {
            best = .{ .blocks = blocks, .segment0 = segment0, .segments = segments, .sit_segs = sit_segs, .nat_segs = nat_segs, .ssa_segs = ssa_segs, .main_segs = main_segs, .reserved = reserved, .overprov = overprov, .user_blocks = user };
        }
    }
    const l = best orelse return error.TooBig;
    if (193 + l.sitBitmap() + l.natBitmap() > cp_chksum_offset + 1) return error.TooBig;
    return l;
}

fn superblock(l: Layout, label: []const u8, uuid: [16]u8) ![block]u8 {
    var b = std.mem.zeroes([block]u8);
    const s = b[1024..];
    std.mem.writeInt(u32, s[0..4], magic, .little);
    std.mem.writeInt(u16, s[4..6], 1, .little);
    std.mem.writeInt(u16, s[6..8], 16, .little);
    std.mem.writeInt(u32, s[8..12], 9, .little);
    std.mem.writeInt(u32, s[12..16], 3, .little);
    std.mem.writeInt(u32, s[16..20], 12, .little);
    std.mem.writeInt(u32, s[20..24], 9, .little);
    std.mem.writeInt(u32, s[24..28], 1, .little);
    std.mem.writeInt(u32, s[28..32], 1, .little);
    std.mem.writeInt(u64, s[36..44], l.blocks, .little);
    std.mem.writeInt(u32, s[44..48], l.main_segs, .little);
    std.mem.writeInt(u32, s[48..52], l.segments, .little);
    std.mem.writeInt(u32, s[52..56], l.ckpt_segs, .little);
    std.mem.writeInt(u32, s[56..60], l.sit_segs, .little);
    std.mem.writeInt(u32, s[60..64], l.nat_segs, .little);
    std.mem.writeInt(u32, s[64..68], l.ssa_segs, .little);
    std.mem.writeInt(u32, s[68..72], l.main_segs, .little);
    std.mem.writeInt(u32, s[72..76], l.segment0, .little);
    std.mem.writeInt(u32, s[76..80], l.cp(), .little);
    std.mem.writeInt(u32, s[80..84], l.sit(), .little);
    std.mem.writeInt(u32, s[84..88], l.nat(), .little);
    std.mem.writeInt(u32, s[88..92], l.ssa(), .little);
    std.mem.writeInt(u32, s[92..96], l.main(), .little);
    std.mem.writeInt(u32, s[96..100], root_ino, .little);
    std.mem.writeInt(u32, s[100..104], node_ino, .little);
    std.mem.writeInt(u32, s[104..108], meta_ino, .little);
    @memcpy(s[108..124], &uuid);
    var it = std.unicode.Utf8View.init(label) catch return error.Invalid;
    var iter = it.iterator();
    var units: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        var pair: [2]u16 = undefined;
        const n: usize = if (cp >= 0x10000) blk: {
            const v = cp - 0x10000;
            pair = .{ @intCast(0xd800 + (v >> 10)), @intCast(0xdc00 + (v & 0x3ff)) };
            break :blk 2;
        } else blk: {
            pair[0] = @intCast(cp);
            break :blk 1;
        };
        if (units + n > 512) return error.TooBig;
        for (pair[0..n]) |u| {
            std.mem.writeInt(u16, s[124 + units * 2 ..][0..2], u, .little);
            units += 1;
        }
    }
    @memcpy(s[1668 .. 1668 + 9], "sinty 1.0");
    @memcpy(s[1924 .. 1924 + 9], "sinty 1.0");
    return b;
}

fn sitEntry(out: []u8, segno: u32, kind: u32, used: u16) void {
    std.mem.writeInt(u32, out[0..4], segno, .little);
    std.mem.writeInt(u16, out[4..6], @intCast((kind << 10) | used), .little);
    if (used > 0) out[6] = 0x80;
}

fn summary(out: []u8, nid: u32) void {
    std.mem.writeInt(u32, out[0..4], nid, .little);
    out[4] = 0;
    std.mem.writeInt(u16, out[5..7], 0, .little);
}

pub fn mkfs(d: fs.Dev, label: []const u8) !void {
    const l = try layout(d.size);
    var uuid: [16]u8 = undefined;
    var got: usize = 0;
    while (got < uuid.len) {
        const rc = linux.getrandom(uuid[got..].ptr, uuid.len - got, 0);
        if (linux.errno(rc) == .SUCCESS) got += rc;
    }
    uuid[6] = (uuid[6] & 0x0f) | 0x40;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    const sb = try superblock(l, label, uuid);
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const now: u64 = @intCast(ts.sec);

    try d.zero(0, @as(u64, l.main()) * block);
    const main = l.main();
    const node_seg = [3]u32{ 0, 1, 2 };
    const data_seg = [3]u32{ 3, 4, 5 };
    const root_node = main + node_seg[0] * seg_blocks;
    const root_data = main + data_seg[0] * seg_blocks;
    const cp_ver: u64 = 1;

    var nat = std.mem.zeroes([block]u8);
    for ([_]struct { nid: u32, addr: u32 }{ .{ .nid = node_ino, .addr = 1 }, .{ .nid = meta_ino, .addr = 1 }, .{ .nid = root_ino, .addr = root_node } }) |e| {
        const off = e.nid * 9;
        nat[off] = 0;
        std.mem.writeInt(u32, nat[off + 1 ..][0..4], e.nid, .little);
        std.mem.writeInt(u32, nat[off + 5 ..][0..4], e.addr, .little);
    }
    try d.writeAt(@as(u64, l.nat()) * block, &nat);

    var node = std.mem.zeroes([block]u8);
    std.mem.writeInt(u16, node[0..2], 0o40755, .little);
    std.mem.writeInt(u32, node[12..16], 2, .little);
    std.mem.writeInt(u64, node[16..24], block, .little);
    std.mem.writeInt(u64, node[24..32], 2, .little);
    for ([_]usize{ 32, 40, 48 }) |o| std.mem.writeInt(u64, node[o..][0..8], now, .little);
    std.mem.writeInt(u32, node[72..76], 1, .little);
    std.mem.writeInt(u32, node[84..88], root_ino, .little);
    std.mem.writeInt(u32, node[360..364], root_data, .little);
    std.mem.writeInt(u32, node[4072..4076], root_ino, .little);
    std.mem.writeInt(u32, node[4076..4080], root_ino, .little);
    std.mem.writeInt(u64, node[4084..4092], cp_ver, .little);
    std.mem.writeInt(u32, node[4092..4096], root_node + 1, .little);
    try d.writeAt(@as(u64, root_node) * block, &node);

    var dent = std.mem.zeroes([block]u8);
    dent[0] = 0x3;
    for ([_]struct { slot: usize, name: []const u8 }{ .{ .slot = 0, .name = "." }, .{ .slot = 1, .name = ".." } }) |e| {
        const off = 30 + e.slot * 11;
        std.mem.writeInt(u32, dent[off + 4 ..][0..4], root_ino, .little);
        std.mem.writeInt(u16, dent[off + 8 ..][0..2], @intCast(e.name.len), .little);
        dent[off + 10] = 2;
        @memcpy(dent[30 + 214 * 11 + e.slot * 8 ..][0..e.name.len], e.name);
    }
    try d.writeAt(@as(u64, root_data) * block, &dent);

    var cp = std.mem.zeroes([block]u8);
    std.mem.writeInt(u64, cp[0..8], cp_ver, .little);
    std.mem.writeInt(u64, cp[8..16], l.user_blocks, .little);
    std.mem.writeInt(u64, cp[16..24], 2, .little);
    std.mem.writeInt(u32, cp[24..28], l.reserved, .little);
    std.mem.writeInt(u32, cp[28..32], l.overprov, .little);
    std.mem.writeInt(u32, cp[32..36], l.main_segs - 6, .little);
    for (0..8) |i| {
        std.mem.writeInt(u32, cp[36 + i * 4 ..][0..4], if (i < 3) node_seg[i] else 0xffffffff, .little);
        std.mem.writeInt(u32, cp[84 + i * 4 ..][0..4], if (i < 3) data_seg[i] else 0xffffffff, .little);
    }
    std.mem.writeInt(u16, cp[68..70], 1, .little);
    std.mem.writeInt(u16, cp[116..118], 1, .little);
    std.mem.writeInt(u32, cp[132..136], 0x1 | 0x4, .little);
    std.mem.writeInt(u32, cp[136..140], 6, .little);
    std.mem.writeInt(u32, cp[140..144], 1, .little);
    std.mem.writeInt(u32, cp[144..148], 1, .little);
    std.mem.writeInt(u32, cp[148..152], 1, .little);
    std.mem.writeInt(u32, cp[152..156], root_ino + 1, .little);
    std.mem.writeInt(u32, cp[156..160], l.sitBitmap(), .little);
    std.mem.writeInt(u32, cp[160..164], l.natBitmap(), .little);
    std.mem.writeInt(u32, cp[164..168], cp_chksum_offset, .little);
    std.mem.writeInt(u32, cp[cp_chksum_offset..][0..4], crc32(magic, cp[0..cp_chksum_offset]), .little);

    var compact = std.mem.zeroes([block]u8);
    const sit_j = compact[journal_size..][0..journal_size];
    std.mem.writeInt(u16, sit_j[0..2], 6, .little);
    const kinds = [6]struct { seg: u32, kind: u32, used: u16 }{
        .{ .seg = node_seg[0], .kind = 3, .used = 1 },
        .{ .seg = node_seg[1], .kind = 4, .used = 0 },
        .{ .seg = node_seg[2], .kind = 5, .used = 0 },
        .{ .seg = data_seg[0], .kind = 0, .used = 1 },
        .{ .seg = data_seg[1], .kind = 1, .used = 0 },
        .{ .seg = data_seg[2], .kind = 2, .used = 0 },
    };
    for (kinds, 0..) |k, i| sitEntry(sit_j[2 + i * 78 ..][0..78], k.seg, k.kind, k.used);
    summary(compact[2 * journal_size ..][0..summary_size], root_ino);

    var hot_node = std.mem.zeroes([block]u8);
    summary(hot_node[0..summary_size], root_ino);
    hot_node[block - 5] = 1;
    var other_node = std.mem.zeroes([block]u8);
    other_node[block - 5] = 1;

    const cpa = @as(u64, l.cp()) * block;
    try d.writeAt(cpa, &cp);
    try d.writeAt(cpa + block, &compact);
    try d.writeAt(cpa + 2 * block, &hot_node);
    try d.writeAt(cpa + 3 * block, &other_node);
    try d.writeAt(cpa + 4 * block, &other_node);
    try d.writeAt(cpa + 5 * block, &cp);
    std.mem.writeInt(u64, cp[0..8], 0, .little);
    std.mem.writeInt(u32, cp[cp_chksum_offset..][0..4], crc32(magic, cp[0..cp_chksum_offset]), .little);
    const cpb = cpa + seg_bytes;
    try d.writeAt(cpb, &cp);
    try d.writeAt(cpb + block, &compact);
    try d.writeAt(cpb + 2 * block, &hot_node);
    try d.writeAt(cpb + 3 * block, &other_node);
    try d.writeAt(cpb + 4 * block, &other_node);
    try d.writeAt(cpb + 5 * block, &cp);

    try d.writeAt(0, &sb);
    var backup = std.mem.zeroes([block]u8);
    @memcpy(backup[1024..], sb[1024..]);
    try d.writeAt(block, &backup);
    try d.sync();
}

test "f2fs layout fits the checkpoint" {
    const l = try layout(256 << 20);
    try std.testing.expectEqual(@as(u32, 512), l.segment0);
    try std.testing.expectEqual(l.segments, l.ckpt_segs + l.sit_segs + l.nat_segs + l.ssa_segs + l.main_segs);
    try std.testing.expect(l.reserved < l.overprov and l.overprov < l.main_segs);
    try std.testing.expect(l.user_blocks > 0);
    try std.testing.expectError(error.TooBig, layout(16 << 20));
    _ = try layout(64 << 20);
    const big = try layout(64 << 30);
    try std.testing.expect(big.main_segs > 30000);
}

test "f2fs crc matches the kernel" {
    try std.testing.expectEqual(@as(u32, 0xcbf43926), crc32(0xffffffff, "123456789") ^ 0xffffffff);
}

test "f2fs volumes are formatted, probed and relabelled" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "f2fs");
    var pb: [600]u8 = undefined;
    const path = try sys.pathZ(&pb, "{s}/fs.img", .{root});
    const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    _ = linux.ftruncate(fd, 96 << 20);
    sys.close(fd);
    var d = try fs.Dev.open(path, true);
    defer d.close();
    try mkfs(d, "Dati");
    var p = try fs.probe(d);
    try std.testing.expectEqualStrings("f2fs", sys.cstr(&p.type));
    try std.testing.expectEqualStrings("Dati", sys.cstr(&p.label));
    try std.testing.expectEqual(@as(u64, 96 << 20), p.size);
    try fs.setLabel(d, "Archivio è");
    p = try fs.probe(d);
    try std.testing.expectEqualStrings("Archivio è", sys.cstr(&p.label));
    var cp: [block]u8 = undefined;
    const l = try layout(96 << 20);
    try d.readAt(@as(u64, l.cp()) * block, &cp);
    try std.testing.expectEqual(std.mem.readInt(u32, cp[cp_chksum_offset..][0..4], .little), crc32(magic, cp[0..cp_chksum_offset]));
}
