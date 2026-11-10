const std = @import("std");
const sys = @import("../sys.zig");
const fs = @import("fs.zig");
const ext4 = @import("ext4.zig");
const Report = @import("fsck.zig").Report;

const crc16_table = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u16 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u16 = i;
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ 0xa001 else c >> 1;
        e.* = c;
    }
    break :blk t;
};

fn crc16(seed: u16, data: []const u8) u16 {
    var c = seed;
    for (data) |b| c = (c >> 8) ^ crc16_table[(c ^ b) & 0xff];
    return c;
}

fn le32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

const incompat_recover = 0x4;
const incompat_meta_bg = 0x10;
const incompat_64bit = 0x80;
const incompat_flex_bg = 0x200;
const incompat_csum_seed = 0x2000;
const ro_sparse_super = 0x1;
const ro_gdt_csum = 0x10;
const ro_metadata_csum = 0x400;
const ro_sparse_super2 = 0x200;

const Group = struct {
    raw: []u8,
    block_bitmap: u64,
    inode_bitmap: u64,
    inode_table: u64,
    free_blocks: u32,
    free_inodes: u32,
    used_dirs: u32,
    flags: u16,
};

const Ext4Check = struct {
    d: fs.Dev,
    repair: bool,
    r: *Report,
    sb: [1024]u8,
    bs: u32,
    blocks: u64,
    first_data: u32,
    bpg: u32,
    ipg: u32,
    inode_size: u32,
    first_ino: u32,
    groups: u32,
    desc_size: u32,
    incompat: u32,
    ro: u32,
    seed: u32,
    gdt: []u8,
    used: std.DynamicBitSetUnmanaged,
    inodes_used: std.DynamicBitSetUnmanaged,
    dirs_per_group: []u32,
    sb_changed: bool = false,
    structural: u32 = 0,

    fn hasSuper(self: *const Ext4Check, g: u32) bool {
        if (g <= 1) return true;
        if (self.ro & ro_sparse_super2 != 0) {
            return g == std.mem.readInt(u32, self.sb[0x24c..0x250], .little) or g == std.mem.readInt(u32, self.sb[0x250..0x254], .little);
        }
        if (self.ro & ro_sparse_super == 0) return true;
        for ([_]u32{ 3, 5, 7 }) |base| {
            var p: u32 = base;
            while (p < g) p *= base;
            if (p == g) return true;
        }
        return false;
    }

    fn desc(self: *const Ext4Check, g: u32) []u8 {
        return self.gdt[g * self.desc_size ..][0..self.desc_size];
    }

    fn field(self: *const Ext4Check, b: []const u8, lo: usize, hi: usize, comptime T: type) u64 {
        var v: u64 = std.mem.readInt(T, b[lo..][0..@sizeOf(T)], .little);
        if (self.desc_size >= 64) v |= @as(u64, std.mem.readInt(T, b[hi..][0..@sizeOf(T)], .little)) << (@sizeOf(T) * 8);
        return v;
    }

    fn setField(self: *const Ext4Check, b: []u8, lo: usize, hi: usize, comptime T: type, v: u64) void {
        std.mem.writeInt(T, b[lo..][0..@sizeOf(T)], @truncate(v), .little);
        if (self.desc_size >= 64) std.mem.writeInt(T, b[hi..][0..@sizeOf(T)], @truncate(v >> (@sizeOf(T) * 8)), .little);
    }

    fn group(self: *const Ext4Check, g: u32) Group {
        const b = self.desc(g);
        return .{
            .raw = b,
            .block_bitmap = self.field(b, 0x00, 0x20, u32),
            .inode_bitmap = self.field(b, 0x04, 0x24, u32),
            .inode_table = self.field(b, 0x08, 0x28, u32),
            .free_blocks = @intCast(self.field(b, 0x0c, 0x2c, u16)),
            .free_inodes = @intCast(self.field(b, 0x0e, 0x2e, u16)),
            .used_dirs = @intCast(self.field(b, 0x10, 0x30, u16)),
            .flags = std.mem.readInt(u16, b[0x12..0x14], .little),
        };
    }

    fn descSum(self: *const Ext4Check, g: u32) u16 {
        const b = self.desc(g);
        if (self.ro & ro_metadata_csum != 0) {
            var c = ext4.crc32c(self.seed, &le32(g));
            c = ext4.crc32c(c, b[0..0x1e]);
            c = ext4.crc32c(c, &[_]u8{ 0, 0 });
            if (b.len > 0x20) c = ext4.crc32c(c, b[0x20..]);
            return @truncate(c);
        }
        var c = crc16(0xffff, self.sb[0x68..0x78]);
        c = crc16(c, &le32(g));
        c = crc16(c, b[0..0x1e]);
        if (b.len > 0x20) c = crc16(c, b[0x20..]);
        return c;
    }

    fn checksums(self: *const Ext4Check) bool {
        return self.ro & (ro_metadata_csum | ro_gdt_csum) != 0;
    }

    fn groupBlocks(self: *const Ext4Check, g: u32) u32 {
        const start = @as(u64, g) * self.bpg + self.first_data;
        return @intCast(@min(@as(u64, self.bpg), self.blocks - start));
    }

    fn mark(self: *Ext4Check, b: u64, what: []const u8, ino: u32) bool {
        if (b < self.first_data or b >= self.blocks) {
            self.r.bad_chains += 1;
            self.structural += 1;
            self.r.fatal("inode {d}: {s} block {d} is outside the filesystem", .{ ino, what, b });
            return false;
        }
        if (self.used.isSet(@intCast(b))) {
            self.r.cross_links += 1;
            self.structural += 1;
            self.r.fatal("inode {d}: {s} block {d} is claimed twice", .{ ino, what, b });
            return false;
        }
        self.used.set(@intCast(b));
        return true;
    }

    fn markRange(self: *Ext4Check, start: u64, n: u64, what: []const u8, ino: u32) void {
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            if (!self.mark(start + i, what, ino)) return;
        }
    }

    fn metadata(self: *Ext4Check) !void {
        const gdt_blocks = (@as(u64, self.groups) * self.desc_size + self.bs - 1) / self.bs;
        const reserved_gdt = std.mem.readInt(u16, self.sb[0xce..0xd0], .little);
        var g: u32 = 0;
        while (g < self.groups) : (g += 1) {
            const start = @as(u64, g) * self.bpg + self.first_data;
            if (self.hasSuper(g)) self.markRange(start, 1 + gdt_blocks + reserved_gdt, "superblock", 0);
            const gr = self.group(g);
            _ = self.mark(gr.block_bitmap, "block bitmap", 0);
            _ = self.mark(gr.inode_bitmap, "inode bitmap", 0);
            self.markRange(gr.inode_table, (@as(u64, self.ipg) * self.inode_size + self.bs - 1) / self.bs, "inode table", 0);
        }
    }

    fn indirect(self: *Ext4Check, blk: u64, level: u32, ino: u32) anyerror!void {
        if (blk == 0) return;
        if (!self.mark(blk, "indirect", ino)) return;
        if (level == 0) return;
        const buf = try sys.gpa.alloc(u8, self.bs);
        defer sys.gpa.free(buf);
        try self.d.readAt(blk * self.bs, buf);
        var i: usize = 0;
        while (i < buf.len) : (i += 4) {
            const p = std.mem.readInt(u32, buf[i..][0..4], .little);
            if (p == 0) continue;
            if (level == 1) {
                _ = self.mark(p, "data", ino);
            } else {
                try self.indirect(p, level - 1, ino);
            }
        }
    }

    fn extents(self: *Ext4Check, node: []const u8, depth_left: u32, ino: u32) anyerror!void {
        if (node.len < 12 or std.mem.readInt(u16, node[0..2], .little) != 0xf30a) {
            self.r.bad_chains += 1;
            self.structural += 1;
            self.r.fatal("inode {d}: damaged extent tree", .{ino});
            return;
        }
        const entries = std.mem.readInt(u16, node[2..4], .little);
        const depth = std.mem.readInt(u16, node[6..8], .little);
        if (depth > depth_left or 12 + @as(usize, entries) * 12 > node.len) {
            self.r.bad_chains += 1;
            self.structural += 1;
            self.r.fatal("inode {d}: damaged extent tree", .{ino});
            return;
        }
        for (0..entries) |k| {
            const e = node[12 + k * 12 ..][0..12];
            if (depth == 0) {
                var len: u64 = std.mem.readInt(u16, e[4..6], .little);
                if (len > 32768) len -= 32768;
                const start = (@as(u64, std.mem.readInt(u16, e[6..8], .little)) << 32) | std.mem.readInt(u32, e[8..12], .little);
                self.markRange(start, len, "data", ino);
            } else {
                const leaf = (@as(u64, std.mem.readInt(u16, e[8..10], .little)) << 32) | std.mem.readInt(u32, e[4..8], .little);
                if (!self.mark(leaf, "extent index", ino)) continue;
                const buf = try sys.gpa.alloc(u8, self.bs);
                defer sys.gpa.free(buf);
                try self.d.readAt(leaf * self.bs, buf);
                try self.extents(buf, depth - 1, ino);
            }
        }
    }

    fn inodes(self: *Ext4Check) !void {
        const table_bytes = @as(usize, self.ipg) * self.inode_size;
        const table = try sys.gpa.alloc(u8, table_bytes);
        defer sys.gpa.free(table);
        var g: u32 = 0;
        while (g < self.groups) : (g += 1) {
            const gr = self.group(g);
            if (self.checksums() and gr.flags & 1 != 0) continue;
            try self.d.readAt(gr.inode_table * self.bs, table);
            var i: u32 = 0;
            while (i < self.ipg) : (i += 1) {
                const ino = g * self.ipg + i + 1;
                const raw = table[@as(usize, i) * self.inode_size ..][0..self.inode_size];
                const mode = std.mem.readInt(u16, raw[0..2], .little);
                const links = std.mem.readInt(u16, raw[0x1a..0x1c], .little);
                const reserved = ino < self.first_ino;
                if (!reserved and (links == 0 or mode == 0)) continue;
                self.inodes_used.set(ino - 1);
                if (reserved and mode == 0 and ino != 1) continue;
                if (mode & 0xf000 == 0x4000) {
                    self.dirs_per_group[g] += 1;
                    self.r.dirs += 1;
                } else if (mode & 0xf000 == 0x8000 and !reserved) {
                    self.r.files += 1;
                }
                const flags = std.mem.readInt(u32, raw[0x20..0x24], .little);
                const acl = @as(u64, std.mem.readInt(u32, raw[0x68..0x6c], .little)) | (@as(u64, std.mem.readInt(u16, raw[0x76..0x78], .little)) << 32);
                if (acl != 0) _ = self.mark(acl, "attribute", ino);
                if (flags & 0x10000000 != 0) continue;
                const kind = mode & 0xf000;
                const nblocks = std.mem.readInt(u32, raw[0x1c..0x20], .little);
                const iblock = raw[0x28..0x64];
                if (ino == 7) {
                    const dind = std.mem.readInt(u32, iblock[52..56], .little);
                    if (dind != 0) _ = self.mark(dind, "resize", ino);
                    continue;
                }
                if (flags & 0x80000 != 0) {
                    try self.extents(iblock, 5, ino);
                    continue;
                }
                if (kind == 0xa000 and nblocks == 0) continue;
                if (kind != 0x8000 and kind != 0x4000 and kind != 0xa000 and !reserved) continue;
                for (0..12) |k| {
                    const p = std.mem.readInt(u32, iblock[k * 4 ..][0..4], .little);
                    if (p != 0) _ = self.mark(p, "data", ino);
                }
                try self.indirect(std.mem.readInt(u32, iblock[48..52], .little), 1, ino);
                try self.indirect(std.mem.readInt(u32, iblock[52..56], .little), 2, ino);
                try self.indirect(std.mem.readInt(u32, iblock[56..60], .little), 3, ino);
            }
        }
    }

    fn writeDesc(self: *Ext4Check, g: u32) void {
        const b = self.desc(g);
        if (self.checksums()) std.mem.writeInt(u16, b[0x1e..0x20], self.descSum(g), .little);
    }

    fn bitmaps(self: *Ext4Check) !void {
        const buf = try sys.gpa.alloc(u8, self.bs);
        defer sys.gpa.free(buf);
        var total_free: u64 = 0;
        var total_free_inodes: u64 = 0;
        var lost: u32 = 0;
        var unmarked: u32 = 0;
        var lost_inodes: u32 = 0;
        var unmarked_inodes: u32 = 0;
        var gdt_changed = false;
        var g: u32 = 0;
        while (g < self.groups) : (g += 1) {
            const gr = self.group(g);
            if (self.checksums() and self.descSum(g) != std.mem.readInt(u16, gr.raw[0x1e..0x20], .little)) {
                self.r.counters += 1;
                self.r.problem(self.repair, "group {d}: descriptor checksum is wrong", .{g});
                gdt_changed = true;
            }
            const start = @as(u64, g) * self.bpg + self.first_data;
            const n = self.groupBlocks(g);
            var free: u32 = 0;
            var changed = false;
            const uninit_blocks = self.checksums() and gr.flags & 2 != 0;
            if (!uninit_blocks) try self.d.readAt(gr.block_bitmap * self.bs, buf) else @memset(buf, 0);
            var b: u32 = 0;
            while (b < n) : (b += 1) {
                const u = self.used.isSet(@intCast(start + b));
                if (!u) free += 1;
                if (uninit_blocks) continue;
                const bit = buf[b / 8] >> @intCast(b % 8) & 1 != 0;
                if (bit and !u) lost += 1;
                if (!bit and u) unmarked += 1;
                if (bit != u) {
                    changed = true;
                    if (u) buf[b / 8] |= @as(u8, 1) << @intCast(b % 8) else buf[b / 8] &= ~(@as(u8, 1) << @intCast(b % 8));
                }
            }
            if (!uninit_blocks and self.ro & ro_metadata_csum != 0) {
                const want = ext4.crc32c(self.seed, buf[0 .. self.bpg / 8]);
                const have = self.field(gr.raw, 0x18, 0x38, u16);
                const mask: u64 = if (self.desc_size >= 64) 0xffffffff else 0xffff;
                if (have != want & mask) {
                    if (!changed) {
                        self.r.counters += 1;
                        self.r.problem(self.repair, "group {d}: block bitmap checksum is wrong", .{g});
                    }
                    changed = true;
                }
                if (changed) {
                    self.setField(gr.raw, 0x18, 0x38, u16, want);
                    gdt_changed = true;
                }
            }
            if (changed and self.repair and !uninit_blocks) try self.d.writeAt(gr.block_bitmap * self.bs, buf);
            total_free += free;
            if (gr.free_blocks != free) {
                self.r.counters += 1;
                self.r.problem(self.repair, "group {d}: {d} free blocks recorded, {d} counted", .{ g, gr.free_blocks, free });
                self.setField(gr.raw, 0x0c, 0x2c, u16, free);
                gdt_changed = true;
            }

            var ifree: u32 = 0;
            var ichanged = false;
            const uninit_inodes = self.checksums() and gr.flags & 1 != 0;
            if (!uninit_inodes) try self.d.readAt(gr.inode_bitmap * self.bs, buf) else @memset(buf, 0);
            var i: u32 = 0;
            while (i < self.ipg) : (i += 1) {
                const u = self.inodes_used.isSet(g * self.ipg + i);
                if (!u) ifree += 1;
                if (uninit_inodes) continue;
                const bit = buf[i / 8] >> @intCast(i % 8) & 1 != 0;
                if (bit and !u) lost_inodes += 1;
                if (!bit and u) unmarked_inodes += 1;
                if (bit != u) {
                    ichanged = true;
                    if (u) buf[i / 8] |= @as(u8, 1) << @intCast(i % 8) else buf[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
                }
            }
            if (!uninit_inodes and self.ro & ro_metadata_csum != 0) {
                const want = ext4.crc32c(self.seed, buf[0 .. self.ipg / 8]);
                const have = self.field(gr.raw, 0x1a, 0x3a, u16);
                const mask: u64 = if (self.desc_size >= 64) 0xffffffff else 0xffff;
                if (have != want & mask) {
                    if (!ichanged) {
                        self.r.counters += 1;
                        self.r.problem(self.repair, "group {d}: inode bitmap checksum is wrong", .{g});
                    }
                    ichanged = true;
                }
                if (ichanged) {
                    self.setField(gr.raw, 0x1a, 0x3a, u16, want);
                    gdt_changed = true;
                }
            }
            if (ichanged and self.repair and !uninit_inodes) try self.d.writeAt(gr.inode_bitmap * self.bs, buf);
            total_free_inodes += ifree;
            if (gr.free_inodes != ifree) {
                self.r.counters += 1;
                self.r.problem(self.repair, "group {d}: {d} free inodes recorded, {d} counted", .{ g, gr.free_inodes, ifree });
                self.setField(gr.raw, 0x0e, 0x2e, u16, ifree);
                gdt_changed = true;
            }
            if (gr.used_dirs != self.dirs_per_group[g]) {
                self.r.counters += 1;
                self.r.problem(self.repair, "group {d}: {d} directories recorded, {d} counted", .{ g, gr.used_dirs, self.dirs_per_group[g] });
                self.setField(gr.raw, 0x10, 0x30, u16, self.dirs_per_group[g]);
                gdt_changed = true;
            }
            self.writeDesc(g);
        }
        if (lost > 0) {
            self.r.lost_clusters += lost;
            self.r.problem(self.repair, "{d} blocks are marked used but belong to nothing", .{lost});
        }
        if (unmarked > 0) {
            self.r.bad_chains += 1;
            self.r.problem(self.repair, "{d} blocks in use are marked free", .{unmarked});
        }
        if (lost_inodes > 0) {
            self.r.lost_clusters += lost_inodes;
            self.r.problem(self.repair, "{d} inodes are marked used but are free", .{lost_inodes});
        }
        if (unmarked_inodes > 0) {
            self.r.bad_chains += 1;
            self.r.problem(self.repair, "{d} inodes in use are marked free", .{unmarked_inodes});
        }
        if (self.repair and gdt_changed) {
            const gdt_off = (@as(u64, self.first_data) + 1) * self.bs;
            try self.d.writeAt(gdt_off, self.gdt);
        }
        var sb_free: u64 = std.mem.readInt(u32, self.sb[0x0c..0x10], .little);
        if (self.incompat & incompat_64bit != 0) sb_free |= @as(u64, std.mem.readInt(u32, self.sb[0x158..0x15c], .little)) << 32;
        if (sb_free != total_free) {
            std.mem.writeInt(u32, self.sb[0x0c..0x10], @truncate(total_free), .little);
            if (self.incompat & incompat_64bit != 0) std.mem.writeInt(u32, self.sb[0x158..0x15c], @intCast(total_free >> 32), .little);
            self.sb_changed = true;
        }
        if (std.mem.readInt(u32, self.sb[0x10..0x14], .little) != total_free_inodes) {
            std.mem.writeInt(u32, self.sb[0x10..0x14], @intCast(total_free_inodes), .little);
            self.sb_changed = true;
        }
    }

    fn run(self: *Ext4Check) !void {
        if (self.incompat & incompat_recover != 0) {
            self.r.dirty = 1;
            self.structural += 1;
            self.r.fatal("the journal must be replayed by mounting the filesystem first", .{});
            return;
        }
        if (self.incompat & incompat_meta_bg != 0) {
            self.structural += 1;
            self.r.fatal("meta_bg filesystems are not supported by the checker", .{});
            return;
        }
        if (self.ro & ro_metadata_csum != 0) {
            const want = ext4.crc32c(0xffffffff, self.sb[0..0x3fc]);
            if (std.mem.readInt(u32, self.sb[0x3fc..0x400], .little) != want) {
                self.r.counters += 1;
                self.r.problem(self.repair, "the superblock checksum is wrong", .{});
                self.sb_changed = true;
            }
        }
        try self.metadata();
        try self.inodes();
        try self.bitmaps();
        const state = std.mem.readInt(u16, self.sb[0x3a..0x3c], .little);
        if (state & 1 == 0 or state & 2 != 0) {
            self.r.dirty = 1;
            if (self.structural == 0) {
                self.r.problem(self.repair, "the filesystem was not unmounted cleanly", .{});
                std.mem.writeInt(u16, self.sb[0x3a..0x3c], (state | 1) & ~@as(u16, 2), .little);
                self.sb_changed = true;
            } else {
                self.r.fatal("the filesystem has errors that need a full check", .{});
            }
        }
        if (self.repair and self.sb_changed) {
            if (self.ro & ro_metadata_csum != 0) std.mem.writeInt(u32, self.sb[0x3fc..0x400], ext4.crc32c(0xffffffff, self.sb[0..0x3fc]), .little);
            try self.d.writeAt(1024, &self.sb);
        }
        if (self.repair) try self.d.sync();
    }
};

pub fn check(d: fs.Dev, repair: bool) !Report {
    var r = Report{};
    var c: Ext4Check = undefined;
    c.d = d;
    c.repair = repair;
    c.r = &r;
    c.sb_changed = false;
    c.structural = 0;
    try d.readAt(1024, &c.sb);
    const sb = &c.sb;
    if (std.mem.readInt(u16, sb[0x38..0x3a], .little) != 0xef53) return error.Invalid;
    const log = std.mem.readInt(u32, sb[0x18..0x1c], .little);
    if (log > 6) return error.Invalid;
    c.bs = @as(u32, 1024) << @intCast(log);
    c.incompat = std.mem.readInt(u32, sb[0x60..0x64], .little);
    c.ro = std.mem.readInt(u32, sb[0x64..0x68], .little);
    c.blocks = std.mem.readInt(u32, sb[0x04..0x08], .little);
    if (c.incompat & incompat_64bit != 0) c.blocks |= @as(u64, std.mem.readInt(u32, sb[0x150..0x154], .little)) << 32;
    c.first_data = std.mem.readInt(u32, sb[0x14..0x18], .little);
    c.bpg = std.mem.readInt(u32, sb[0x20..0x24], .little);
    c.ipg = std.mem.readInt(u32, sb[0x28..0x2c], .little);
    const rev = std.mem.readInt(u32, sb[0x4c..0x50], .little);
    c.inode_size = if (rev == 0) 128 else std.mem.readInt(u16, sb[0x58..0x5a], .little);
    c.first_ino = if (rev == 0) 11 else std.mem.readInt(u32, sb[0x54..0x58], .little);
    c.desc_size = if (c.incompat & incompat_64bit != 0) std.mem.readInt(u16, sb[0xfe..0x100], .little) else 32;
    if (c.bpg == 0 or c.ipg == 0 or c.bpg > c.bs * 8 or c.ipg > c.bs * 8 or c.inode_size < 128 or c.desc_size < 32 or c.blocks <= c.first_data) return error.Invalid;
    if (c.blocks * c.bs > d.size) return error.Invalid;
    c.groups = @intCast((c.blocks - c.first_data + c.bpg - 1) / c.bpg);
    c.seed = if (c.incompat & incompat_csum_seed != 0) std.mem.readInt(u32, sb[0x270..0x274], .little) else ext4.crc32c(0xffffffff, sb[0x68..0x78]);
    const gdt_len = @as(usize, c.groups) * c.desc_size;
    c.gdt = try sys.gpa.alloc(u8, gdt_len);
    defer sys.gpa.free(c.gdt);
    try d.readAt((@as(u64, c.first_data) + 1) * c.bs, c.gdt);
    c.used = try std.DynamicBitSetUnmanaged.initEmpty(sys.gpa, @intCast(c.blocks));
    defer c.used.deinit(sys.gpa);
    c.inodes_used = try std.DynamicBitSetUnmanaged.initEmpty(sys.gpa, @as(usize, c.groups) * c.ipg);
    defer c.inodes_used.deinit(sys.gpa);
    c.dirs_per_group = try sys.gpa.alloc(u32, c.groups);
    defer sys.gpa.free(c.dirs_per_group);
    @memset(c.dirs_per_group, 0);
    try c.run();
    return r;
}
