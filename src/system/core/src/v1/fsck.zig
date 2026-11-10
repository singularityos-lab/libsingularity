const std = @import("std");
const sys = @import("../sys.zig");
const fs = @import("fs.zig");

pub const Report = extern struct {
    errors: u32 = 0,
    fixed: u32 = 0,
    lost_clusters: u32 = 0,
    cross_links: u32 = 0,
    bad_chains: u32 = 0,
    size_mismatches: u32 = 0,
    fat_mismatches: u32 = 0,
    dirty: u32 = 0,
    counters: u32 = 0,
    files: u32 = 0,
    dirs: u32 = 0,
    message: [256]u8 = std.mem.zeroes([256]u8),

    pub fn clean(r: Report) bool {
        return r.errors == r.fixed;
    }

    pub fn problem(r: *Report, repair: bool, comptime fmt: []const u8, args: anytype) void {
        if (r.errors == 0) _ = std.fmt.bufPrint(r.message[0 .. r.message.len - 1], fmt, args) catch {};
        r.errors += 1;
        if (repair) r.fixed += 1;
    }

    pub fn fatal(r: *Report, comptime fmt: []const u8, args: anytype) void {
        if (r.errors == r.fixed) {
            @memset(&r.message, 0);
            _ = std.fmt.bufPrint(r.message[0 .. r.message.len - 1], fmt, args) catch {};
        }
        r.errors += 1;
    }
};

const max_depth = 64;

const FatCheck = struct {
    d: fs.Dev,
    f: fs.Fat,
    repair: bool,
    r: *Report,
    table: []u32,
    used: std.DynamicBitSetUnmanaged,
    cs: u32,
    changed: bool = false,
    eoc: u32,
    bad: u32,

    fn limit(self: *const FatCheck) u64 {
        return self.f.clusters + 2;
    }

    fn isEoc(self: *const FatCheck, v: u32) bool {
        return v >= self.eoc;
    }

    fn set(self: *FatCheck, c: u32, v: u32) void {
        if (!self.repair) return;
        self.table[c] = v;
        self.changed = true;
    }

    fn load(self: *FatCheck, raw: []const u8) void {
        for (self.table, 0..) |*e, n| {
            e.* = switch (self.f.bits) {
                32 => std.mem.readInt(u32, raw[n * 4 ..][0..4], .little) & 0x0fffffff,
                16 => std.mem.readInt(u16, raw[n * 2 ..][0..2], .little),
                else => blk: {
                    const off = n * 3 / 2;
                    const v = std.mem.readInt(u16, raw[off..][0..2], .little);
                    break :blk if (n & 1 != 0) v >> 4 else v & 0xfff;
                },
            };
        }
    }

    fn store(self: *const FatCheck, raw: []u8) void {
        for (self.table, 0..) |e, n| switch (self.f.bits) {
            32 => {
                const p = raw[n * 4 ..][0..4];
                const top = std.mem.readInt(u32, p, .little) & 0xf0000000;
                std.mem.writeInt(u32, p, top | e, .little);
            },
            16 => std.mem.writeInt(u16, raw[n * 2 ..][0..2], @intCast(e), .little),
            else => {
                const off = n * 3 / 2;
                const p = raw[off..][0..2];
                var v = std.mem.readInt(u16, p, .little);
                if (n & 1 != 0) {
                    v = (v & 0x000f) | @as(u16, @intCast(e << 4));
                } else {
                    v = (v & 0xf000) | @as(u16, @intCast(e));
                }
                std.mem.writeInt(u16, p, v, .little);
            },
        };
    }

    const Chain = struct { n: u32, start_ok: bool };

    fn chain(self: *FatCheck, start: u32, path: []const u8) Chain {
        var c = start;
        var prev: u32 = 0;
        var n: u32 = 0;
        while (true) {
            if (c < 2 or c >= self.limit()) {
                self.r.bad_chains += 1;
                self.r.problem(self.repair, "{s}: cluster {d} out of range", .{ path, c });
                if (prev != 0) self.set(prev, self.eoc | 0xf);
                return .{ .n = n, .start_ok = prev != 0 };
            }
            if (self.used.isSet(c)) {
                self.r.cross_links += 1;
                self.r.problem(self.repair, "{s}: cluster {d} is shared with another file", .{ path, c });
                if (prev != 0) self.set(prev, self.eoc | 0xf);
                return .{ .n = n, .start_ok = prev != 0 };
            }
            self.used.set(c);
            n += 1;
            const v = self.table[c];
            if (self.isEoc(v)) return .{ .n = n, .start_ok = true };
            if (v == 0 or v == 1 or v == self.bad or v >= self.limit()) {
                self.r.bad_chains += 1;
                self.r.problem(self.repair, "{s}: broken chain after cluster {d}", .{ path, c });
                self.set(c, self.eoc | 0xf);
                return .{ .n = n, .start_ok = true };
            }
            prev = c;
            c = v;
        }
    }

    fn release(self: *FatCheck, start: u32, keep: u32) void {
        var c = start;
        var i: u32 = 0;
        while (c >= 2 and c < self.limit() and !self.isEoc(c)) : (i += 1) {
            const next = self.table[c];
            if (i + 1 == keep) {
                self.set(c, self.eoc | 0xf);
            } else if (i + 1 > keep) {
                self.used.unset(c);
                self.set(c, 0);
            }
            if (i > self.f.clusters) break;
            c = next;
        }
    }

    fn writeEntry(self: *FatCheck, off: u64, e: *const [32]u8) !void {
        if (self.repair) try self.d.writeAt(off, e);
    }

    fn entries(self: *FatCheck, off: u64, len: u64, depth: u32, path: []const u8) !bool {
        const buf = try sys.gpa.alloc(u8, @intCast(len));
        defer sys.gpa.free(buf);
        try self.d.readAt(off, buf);
        var i: usize = 0;
        while (i + 32 <= buf.len) : (i += 32) {
            const e: *[32]u8 = buf[i..][0..32];
            if (e[0] == 0) return false;
            if (e[0] == 0xe5) continue;
            const attr = e[11];
            if (attr & 0x3f == 0x0f or attr & 0x08 != 0) continue;
            if (e[0] == '.') continue;
            var hi: u32 = 0;
            if (self.f.bits == 32) hi = std.mem.readInt(u16, e[0x14..0x16], .little);
            const first = (hi << 16) | std.mem.readInt(u16, e[0x1a..0x1c], .little);
            const size = std.mem.readInt(u32, e[0x1c..0x20], .little);
            var nb: [300]u8 = undefined;
            const name = std.fmt.bufPrint(&nb, "{s}/{s}", .{ path, std.mem.trimEnd(u8, e[0..11], " ") }) catch path;
            if (attr & 0x10 != 0) {
                self.r.dirs += 1;
                if (first == 0 or depth >= max_depth) {
                    self.r.bad_chains += 1;
                    self.r.problem(self.repair, "{s}: directory without clusters", .{name});
                    e[0] = 0xe5;
                    try self.writeEntry(off + i, e);
                    continue;
                }
                const ch = self.chain(first, name);
                if (!ch.start_ok) {
                    e[0] = 0xe5;
                    try self.writeEntry(off + i, e);
                    continue;
                }
                try self.walk(first, depth + 1, name);
                continue;
            }
            self.r.files += 1;
            if (first == 0) {
                if (size != 0) {
                    self.r.size_mismatches += 1;
                    self.r.problem(self.repair, "{s}: size {d} without clusters", .{ name, size });
                    std.mem.writeInt(u32, e[0x1c..0x20], 0, .little);
                    try self.writeEntry(off + i, e);
                }
                continue;
            }
            const ch = self.chain(first, name);
            if (!ch.start_ok) {
                std.mem.writeInt(u16, e[0x14..0x16], 0, .little);
                std.mem.writeInt(u16, e[0x1a..0x1c], 0, .little);
                std.mem.writeInt(u32, e[0x1c..0x20], 0, .little);
                try self.writeEntry(off + i, e);
                continue;
            }
            const needed: u64 = (@as(u64, size) + self.cs - 1) / self.cs;
            if (ch.n > needed) {
                self.r.size_mismatches += 1;
                self.r.problem(self.repair, "{s}: chain of {d} clusters for {d} bytes", .{ name, ch.n, size });
                if (self.repair) {
                    self.release(first, @intCast(needed));
                    if (needed == 0) {
                        self.used.unset(first);
                        self.set(first, 0);
                        std.mem.writeInt(u16, e[0x14..0x16], 0, .little);
                        std.mem.writeInt(u16, e[0x1a..0x1c], 0, .little);
                        try self.writeEntry(off + i, e);
                    }
                }
            } else if (ch.n < needed) {
                self.r.size_mismatches += 1;
                self.r.problem(self.repair, "{s}: {d} bytes but only {d} clusters", .{ name, size, ch.n });
                std.mem.writeInt(u32, e[0x1c..0x20], ch.n * self.cs, .little);
                try self.writeEntry(off + i, e);
            }
        }
        return true;
    }

    fn walk(self: *FatCheck, start: u32, depth: u32, path: []const u8) anyerror!void {
        var c = start;
        var guard: u64 = 0;
        while (c >= 2 and c < self.limit() and guard <= self.f.clusters) : (guard += 1) {
            if (!try self.entries(self.f.clusterOffset(c), self.cs, depth, path)) return;
            const next = self.table[c];
            if (self.isEoc(next) or next < 2) return;
            c = next;
        }
    }

    fn run(self: *FatCheck) !void {
        const fat_bytes = @as(usize, self.f.fat_size) * self.f.bps;
        const fat_off = @as(u64, self.f.reserved) * self.f.bps;
        const raw = try sys.gpa.alloc(u8, fat_bytes);
        defer sys.gpa.free(raw);
        try self.d.readAt(fat_off, raw);
        const need: usize = switch (self.f.bits) {
            32 => self.table.len * 4,
            16 => self.table.len * 2,
            else => (self.table.len * 3 + 1) / 2 + 1,
        };
        if (need > fat_bytes) {
            self.r.fatal("the allocation table is smaller than the volume", .{});
            return;
        }
        self.load(raw);
        var mismatch = false;
        if (self.f.nfats > 1) {
            const other = try sys.gpa.alloc(u8, fat_bytes);
            defer sys.gpa.free(other);
            var k: u32 = 1;
            while (k < self.f.nfats) : (k += 1) {
                try self.d.readAt(fat_off + @as(u64, k) * fat_bytes, other);
                if (!std.mem.eql(u8, raw, other)) mismatch = true;
            }
        }
        if (mismatch) {
            self.r.fat_mismatches += 1;
            self.r.problem(self.repair, "the copies of the allocation table differ", .{});
            if (self.repair) self.changed = true;
        }
        var boot: [512]u8 = undefined;
        try self.d.readAt(0, &boot);
        const flag_at = (if (self.f.bits == 32) @as(usize, 0x40) else 0x24) + 1;
        const clean_bit: u32 = switch (self.f.bits) {
            32 => 0x08000000,
            16 => 0x8000,
            else => 0,
        };
        const fat_dirty = clean_bit != 0 and self.table[1] & clean_bit == 0;
        const boot_dirty = boot[flag_at] & 1 != 0;
        if (fat_dirty or boot_dirty) {
            self.r.dirty = 1;
            self.r.problem(self.repair, "the volume was not unmounted cleanly", .{});
            if (self.repair) {
                if (fat_dirty) self.set(1, self.table[1] | clean_bit);
                if (boot_dirty) {
                    boot[flag_at] &= 0xfe;
                    try self.d.writeAt(0, &boot);
                    if (self.f.bits == 32) {
                        const backup = std.mem.readInt(u16, boot[0x32..0x34], .little);
                        if (backup != 0 and backup < self.f.reserved) try self.d.writeAt(@as(u64, backup) * self.f.bps, &boot);
                    }
                }
            }
        }
        if (self.f.bits == 32) {
            const rc = self.chain(self.f.root_cluster, "");
            if (!rc.start_ok) {
                self.r.fatal("the root directory is unreadable", .{});
                return;
            }
            try self.walk(self.f.root_cluster, 0, "");
        } else {
            const root_off = (@as(u64, self.f.reserved) + @as(u64, self.f.nfats) * self.f.fat_size) * self.f.bps;
            _ = try self.entries(root_off, @as(u64, self.f.root_entries) * 32, 0, "");
        }
        var lost: u32 = 0;
        var free: u32 = 0;
        var c: u32 = 2;
        while (c < self.limit()) : (c += 1) {
            const v = self.table[c];
            if (v == 0) {
                free += 1;
            } else if (v != self.bad and !self.used.isSet(c)) {
                lost += 1;
                if (self.repair) {
                    self.table[c] = 0;
                    self.changed = true;
                    free += 1;
                }
            }
        }
        if (lost > 0) {
            self.r.lost_clusters = lost;
            self.r.problem(self.repair, "{d} clusters are allocated but not used by any file", .{lost});
        }
        if (self.repair and self.changed) {
            self.store(raw);
            var k: u32 = 0;
            while (k < self.f.nfats) : (k += 1) try self.d.writeAt(fat_off + @as(u64, k) * fat_bytes, raw);
        }
        if (self.f.bits == 32) try self.fsinfo(&boot, free);
        if (self.repair) try self.d.sync();
    }

    fn fsinfo(self: *FatCheck, boot: *const [512]u8, free: u32) !void {
        const sector = std.mem.readInt(u16, boot[0x30..0x32], .little);
        if (sector == 0 or sector >= self.f.reserved) return;
        var b: [512]u8 = undefined;
        const off = @as(u64, sector) * self.f.bps;
        try self.d.readAt(off, &b);
        if (std.mem.readInt(u32, b[0..4], .little) != 0x41615252 or std.mem.readInt(u32, b[484..488], .little) != 0x61417272) return;
        const stored = std.mem.readInt(u32, b[488..492], .little);
        if (stored == 0xffffffff or stored == free) return;
        self.r.counters += 1;
        self.r.problem(self.repair, "free cluster count is {d}, should be {d}", .{ stored, free });
        if (self.repair) {
            std.mem.writeInt(u32, b[488..492], free, .little);
            try self.d.writeAt(off, &b);
        }
    }
};

pub fn checkFat(d: fs.Dev, repair: bool) !Report {
    var boot: [512]u8 = undefined;
    try d.readAt(0, &boot);
    const f = fs.Fat.parse(&boot) orelse return error.Invalid;
    if (f.total * f.bps > d.size) return error.Invalid;
    var r = Report{};
    const n: usize = @intCast(f.clusters + 2);
    const table = try sys.gpa.alloc(u32, n);
    defer sys.gpa.free(table);
    var used = try std.DynamicBitSetUnmanaged.initEmpty(sys.gpa, n);
    defer used.deinit(sys.gpa);
    const eoc: u32 = switch (f.bits) {
        32 => 0x0ffffff8,
        16 => 0xfff8,
        else => 0xff8,
    };
    var c = FatCheck{ .d = d, .f = f, .repair = repair, .r = &r, .table = table, .used = used, .cs = f.spc * f.bps, .eoc = eoc, .bad = eoc - 1 };
    try c.run();
    c.used.deinit(sys.gpa);
    used = .{};
    return r;
}

fn setSum(set: []const u8) u16 {
    var c: u16 = 0;
    for (set, 0..) |b, i| {
        if (i == 2 or i == 3) continue;
        c = ((c << 15) | (c >> 1)) +% b;
    }
    return c;
}

const ExfatCheck = struct {
    d: fs.Dev,
    e: fs.Exfat,
    repair: bool,
    r: *Report,
    fat: []u32,
    used: std.DynamicBitSetUnmanaged,
    fat_changed: bool = false,
    bitmap_first: u32 = 0,
    bitmap_len: u64 = 0,

    fn limit(self: *const ExfatCheck) u64 {
        return @as(u64, self.e.count) + 2;
    }

    fn offset(self: *const ExfatCheck, c: u32) u64 {
        return self.e.heap_off + @as(u64, c - 2) * self.e.cluster;
    }

    fn set(self: *ExfatCheck, c: u32, v: u32) void {
        if (!self.repair) return;
        self.fat[c] = v;
        self.fat_changed = true;
    }

    const Chain = struct { n: u64, start_ok: bool };

    fn chain(self: *ExfatCheck, start: u32, nofat: bool, bytes: u64, path: []const u8) Chain {
        const needed = (bytes + self.e.cluster - 1) / self.e.cluster;
        if (nofat) {
            if (start < 2 or start + needed > self.limit()) {
                self.r.bad_chains += 1;
                self.r.problem(self.repair, "{s}: clusters out of range", .{path});
                return .{ .n = 0, .start_ok = false };
            }
            var i: u64 = 0;
            while (i < needed) : (i += 1) {
                const c: u32 = @intCast(start + i);
                if (self.used.isSet(c)) {
                    self.r.cross_links += 1;
                    self.r.problem(self.repair, "{s}: cluster {d} is shared with another file", .{ path, c });
                    return .{ .n = i, .start_ok = i > 0 };
                }
                self.used.set(c);
            }
            return .{ .n = needed, .start_ok = true };
        }
        var c = start;
        var prev: u32 = 0;
        var n: u64 = 0;
        while (true) {
            if (c < 2 or c >= self.limit()) {
                self.r.bad_chains += 1;
                self.r.problem(self.repair, "{s}: cluster {d} out of range", .{ path, c });
                if (prev != 0) self.set(prev, 0xffffffff);
                return .{ .n = n, .start_ok = prev != 0 };
            }
            if (self.used.isSet(c)) {
                self.r.cross_links += 1;
                self.r.problem(self.repair, "{s}: cluster {d} is shared with another file", .{ path, c });
                if (prev != 0) self.set(prev, 0xffffffff);
                return .{ .n = n, .start_ok = prev != 0 };
            }
            self.used.set(c);
            n += 1;
            const v = self.fat[c];
            if (v == 0xffffffff) return .{ .n = n, .start_ok = true };
            if (n >= needed and needed > 0) {
                self.r.size_mismatches += 1;
                self.r.problem(self.repair, "{s}: chain longer than the file", .{path});
                self.set(c, 0xffffffff);
                return .{ .n = n, .start_ok = true };
            }
            if (v < 2 or v >= self.limit()) {
                self.r.bad_chains += 1;
                self.r.problem(self.repair, "{s}: broken chain after cluster {d}", .{ path, c });
                self.set(c, 0xffffffff);
                return .{ .n = n, .start_ok = true };
            }
            prev = c;
            c = v;
        }
    }

    fn clusters(self: *ExfatCheck, start: u32, nofat: bool, bytes: u64, out: *std.ArrayList(u64)) !void {
        const needed = (bytes + self.e.cluster - 1) / self.e.cluster;
        var c = start;
        var i: u64 = 0;
        while (i < needed and c >= 2 and c < self.limit()) : (i += 1) {
            try out.append(sys.gpa, self.offset(c));
            if (nofat) {
                c += 1;
            } else {
                const v = self.fat[c];
                if (v == 0xffffffff) break;
                c = v;
            }
        }
    }

    fn put(self: *ExfatCheck, offs: []const u64, pos: usize, b: []const u8) !void {
        if (!self.repair) return;
        const cs = self.e.cluster;
        var done: usize = 0;
        while (done < b.len) {
            const p = pos + done;
            const in = p % cs;
            const n = @min(b.len - done, cs - in);
            try self.d.writeAt(offs[p / cs] + in, b[done .. done + n]);
            done += n;
        }
    }

    fn dir(self: *ExfatCheck, start: u32, nofat: bool, bytes: u64, depth: u32, path: []const u8, root: bool) anyerror!void {
        var offs: std.ArrayList(u64) = .empty;
        defer offs.deinit(sys.gpa);
        try self.clusters(start, nofat, bytes, &offs);
        const cs = self.e.cluster;
        const buf = try sys.gpa.alloc(u8, offs.items.len * cs);
        defer sys.gpa.free(buf);
        for (offs.items, 0..) |o, k| try self.d.readAt(o, buf[k * cs ..][0..cs]);
        var i: usize = 0;
        while (i + 32 <= buf.len) {
            const t = buf[i];
            if (t == 0) return;
            if (t & 0x80 == 0) {
                i += 32;
                continue;
            }
            switch (t) {
                0x81, 0x82 => {
                    if (!root) {
                        i += 32;
                        continue;
                    }
                    const first = std.mem.readInt(u32, buf[i + 20 ..][0..4], .little);
                    const len = std.mem.readInt(u64, buf[i + 24 ..][0..8], .little);
                    _ = self.chain(first, false, len, if (t == 0x81) "allocation bitmap" else "up-case table");
                    if (t == 0x81 and self.bitmap_first == 0) {
                        self.bitmap_first = first;
                        self.bitmap_len = len;
                    }
                    i += 32;
                },
                0x85 => {
                    const sc: usize = buf[i + 1];
                    if (sc < 2 or i + (sc + 1) * 32 > buf.len or buf[i + 32] != 0xc0) {
                        self.r.fatal("{s}: damaged directory entry set", .{path});
                        i += 32;
                        continue;
                    }
                    const set_bytes = buf[i .. i + (sc + 1) * 32];
                    var nb: [300]u8 = undefined;
                    var name_len: usize = 0;
                    var k: usize = 2;
                    while (k <= sc) : (k += 1) {
                        const ne = set_bytes[k * 32 ..][0..32];
                        if (ne[0] != 0xc1) break;
                        var u: usize = 2;
                        while (u < 32) : (u += 2) {
                            const ch = std.mem.readInt(u16, ne[u..][0..2], .little);
                            if (ch == 0) break;
                            if (name_len < 200) {
                                nb[name_len] = if (ch < 0x80) @intCast(ch) else '?';
                                name_len += 1;
                            }
                        }
                    }
                    var pb: [300]u8 = undefined;
                    const name = std.fmt.bufPrint(&pb, "{s}/{s}", .{ path, nb[0..name_len] }) catch path;
                    const stream = set_bytes[32..64];
                    const attr = std.mem.readInt(u16, set_bytes[4..6], .little);
                    const nofat_f = stream[1] & 2 != 0;
                    const first = std.mem.readInt(u32, stream[20..24], .little);
                    const len = std.mem.readInt(u64, stream[24..32], .little);
                    var modified = false;
                    if (len > 0 and first != 0) {
                        const ch = self.chain(first, nofat_f, len, name);
                        const needed = (len + cs - 1) / cs;
                        if (!ch.start_ok) {
                            std.mem.writeInt(u32, stream[20..24], 0, .little);
                            std.mem.writeInt(u64, stream[24..32], 0, .little);
                            std.mem.writeInt(u64, stream[8..16], 0, .little);
                            stream[1] &= 0xfd;
                            modified = true;
                        } else if (ch.n < needed) {
                            self.r.size_mismatches += 1;
                            self.r.problem(self.repair, "{s}: {d} bytes but only {d} clusters", .{ name, len, ch.n });
                            const nl = ch.n * cs;
                            std.mem.writeInt(u64, stream[24..32], nl, .little);
                            const valid = std.mem.readInt(u64, stream[8..16], .little);
                            if (valid > nl) std.mem.writeInt(u64, stream[8..16], nl, .little);
                            modified = true;
                        }
                        if (attr & 0x10 != 0 and ch.start_ok) {
                            self.r.dirs += 1;
                            if (depth < max_depth) try self.dir(first, nofat_f, std.mem.readInt(u64, stream[24..32], .little), depth + 1, name, false);
                        } else {
                            self.r.files += 1;
                        }
                    } else if (attr & 0x10 != 0) {
                        self.r.dirs += 1;
                    } else {
                        self.r.files += 1;
                    }
                    const want = setSum(set_bytes);
                    const have = std.mem.readInt(u16, set_bytes[2..4], .little);
                    if (modified or want != have) {
                        if (!modified) {
                            self.r.counters += 1;
                            self.r.problem(self.repair, "{s}: wrong entry set checksum", .{name});
                        }
                        std.mem.writeInt(u16, set_bytes[2..4], want, .little);
                        try self.put(offs.items, i, set_bytes);
                    }
                    i += (sc + 1) * 32;
                },
                else => i += 32,
            }
        }
    }

    fn run(self: *ExfatCheck) !void {
        var region: [12 * 512]u8 = undefined;
        const ss: usize = @intCast(self.e.sector);
        if (ss != 512) {
            self.r.fatal("sector size {d} is not supported by the checker", .{ss});
            return;
        }
        try self.d.readAt(0, &region);
        var sum: u32 = 0;
        for (0..11) |k| sum = fs.exfatSum(sum, region[k * 512 ..][0..512], k == 0);
        var bad_sum = false;
        var w: usize = 0;
        while (w < 512) : (w += 4) {
            if (std.mem.readInt(u32, region[11 * 512 + w ..][0..4], .little) != sum) bad_sum = true;
        }
        if (bad_sum) {
            self.r.counters += 1;
            self.r.problem(self.repair, "the boot region checksum is wrong", .{});
            if (self.repair) {
                w = 0;
                while (w < 512) : (w += 4) std.mem.writeInt(u32, region[11 * 512 + w ..][0..4], sum, .little);
                try self.d.writeAt(11 * 512, region[11 * 512 ..][0..512]);
            }
        }
        const flags = std.mem.readInt(u16, region[0x6a..0x6c], .little);
        if (flags & 2 != 0) {
            self.r.dirty = 1;
            self.r.problem(self.repair, "the volume was not unmounted cleanly", .{});
            if (self.repair) {
                std.mem.writeInt(u16, region[0x6a..0x6c], flags & ~@as(u16, 2), .little);
                try self.d.writeAt(0, region[0..512]);
            }
        }
        const raw = try sys.gpa.alloc(u8, self.fat.len * 4);
        defer sys.gpa.free(raw);
        try self.d.readAt(self.e.fat_off, raw);
        for (self.fat, 0..) |*v, n| v.* = std.mem.readInt(u32, raw[n * 4 ..][0..4], .little);
        const rc = self.chain(self.e.root, false, 0, "");
        if (!rc.start_ok) {
            self.r.fatal("the root directory is unreadable", .{});
            return;
        }
        var root_len: u64 = 0;
        var c = self.e.root;
        while (c >= 2 and c < self.limit() and root_len <= @as(u64, self.e.count) * self.e.cluster) {
            root_len += self.e.cluster;
            const v = self.fat[c];
            if (v == 0xffffffff) break;
            c = v;
        }
        try self.dir(self.e.root, false, root_len, 0, "", true);
        if (self.bitmap_first == 0) {
            self.r.fatal("the allocation bitmap is missing", .{});
            return;
        }
        if (self.bitmap_len * 8 < self.e.count) {
            self.r.fatal("the allocation bitmap is too small", .{});
            return;
        }
        var offs: std.ArrayList(u64) = .empty;
        defer offs.deinit(sys.gpa);
        try self.clusters(self.bitmap_first, false, self.bitmap_len, &offs);
        const cs = self.e.cluster;
        const bm = try sys.gpa.alloc(u8, offs.items.len * cs);
        defer sys.gpa.free(bm);
        for (offs.items, 0..) |o, k| try self.d.readAt(o, bm[k * cs ..][0..cs]);
        var lost: u32 = 0;
        var unmarked: u32 = 0;
        var n: u32 = 0;
        while (n < self.e.count) : (n += 1) {
            const bit = bm[n / 8] >> @intCast(n % 8) & 1 != 0;
            const u = self.used.isSet(n + 2);
            if (bit and !u) lost += 1;
            if (!bit and u) unmarked += 1;
            if (bit != u) {
                if (u) bm[n / 8] |= @as(u8, 1) << @intCast(n % 8) else bm[n / 8] &= ~(@as(u8, 1) << @intCast(n % 8));
            }
        }
        if (lost > 0) {
            self.r.lost_clusters = lost;
            self.r.problem(self.repair, "{d} clusters are marked used but belong to no file", .{lost});
        }
        if (unmarked > 0) {
            self.r.bad_chains += 1;
            self.r.problem(self.repair, "{d} clusters in use are marked free", .{unmarked});
        }
        if (self.repair and (lost > 0 or unmarked > 0)) {
            for (offs.items, 0..) |o, k| try self.d.writeAt(o, bm[k * cs ..][0..cs]);
        }
        if (self.repair and self.fat_changed) {
            for (self.fat, 0..) |v, i| std.mem.writeInt(u32, raw[i * 4 ..][0..4], v, .little);
            try self.d.writeAt(self.e.fat_off, raw);
        }
        if (self.repair) try self.d.sync();
    }
};

pub fn checkExfat(d: fs.Dev, repair: bool) !Report {
    var boot: [512]u8 = undefined;
    try d.readAt(0, &boot);
    if (!std.mem.eql(u8, boot[3..11], "EXFAT   ")) return error.Invalid;
    const e = try fs.Exfat.parse(&boot);
    if (e.count == 0 or e.heap_off + @as(u64, e.count) * e.cluster > d.size) return error.Invalid;
    var r = Report{};
    const n: usize = @as(usize, e.count) + 2;
    const fat = try sys.gpa.alloc(u32, n);
    defer sys.gpa.free(fat);
    var c = ExfatCheck{ .d = d, .e = e, .repair = repair, .r = &r, .fat = fat, .used = try std.DynamicBitSetUnmanaged.initEmpty(sys.gpa, n) };
    defer c.used.deinit(sys.gpa);
    try c.run();
    return r;
}

pub fn check(d: fs.Dev, repair: bool) !Report {
    const info = try fs.probe(d);
    const t = sys.cstr(&info.type);
    if (std.mem.eql(u8, t, "vfat")) return checkFat(d, repair);
    if (std.mem.eql(u8, t, "exfat")) return checkExfat(d, repair);
    if (std.mem.startsWith(u8, t, "ext")) return @import("ext4check.zig").check(d, repair);
    return error.Unsupported;
}

fn testFat(d: fs.Dev, f: fs.Fat, c: u32, v: u32) !void {
    const fat_bytes = @as(u64, f.fat_size) * f.bps;
    var k: u32 = 0;
    while (k < f.nfats) : (k += 1) {
        const base = @as(u64, f.reserved) * f.bps + k * fat_bytes;
        switch (f.bits) {
            32 => {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, v, .little);
                try d.writeAt(base + @as(u64, c) * 4, &b);
            },
            16 => {
                var b: [2]u8 = undefined;
                std.mem.writeInt(u16, &b, @intCast(v), .little);
                try d.writeAt(base + @as(u64, c) * 2, &b);
            },
            else => {
                const off = base + c * 3 / 2;
                var b: [2]u8 = undefined;
                try d.readAt(off, &b);
                var x = std.mem.readInt(u16, &b, .little);
                x = if (c & 1 != 0) (x & 0x000f) | @as(u16, @intCast(v << 4)) else (x & 0xf000) | @as(u16, @intCast(v));
                std.mem.writeInt(u16, &b, x, .little);
                try d.writeAt(off, &b);
            },
        }
    }
}

fn expectFatRepairs(size: u64, bits: u8) !void {
    var rb: [512]u8 = undefined;
    var nb: [32]u8 = undefined;
    const root = try sys.testRoot(&rb, try std.fmt.bufPrint(&nb, "fsck-fat{d}", .{bits}));
    var pb: [600]u8 = undefined;
    const path = try sys.pathZ(&pb, "{s}/fs.img", .{root});
    const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    _ = std.os.linux.ftruncate(fd, @intCast(size));
    sys.close(fd);
    var d = try fs.Dev.open(path, true);
    defer d.close();
    try fs.mkfsVfat(d, .{ .label = "CHECK", .bits = bits });
    var boot: [512]u8 = undefined;
    try d.readAt(0, &boot);
    const f = fs.Fat.parse(&boot).?;
    try std.testing.expectEqual(bits, f.bits);
    try std.testing.expect((try check(d, false)).clean());
    const cs = f.spc * f.bps;
    const dir_off = if (bits == 32) f.clusterOffset(f.root_cluster) else (@as(u64, f.reserved) + @as(u64, f.nfats) * f.fat_size) * f.bps;
    var e = std.mem.zeroes([32]u8);
    @memcpy(e[0..11], "A       TXT");
    e[11] = 0x20;
    std.mem.writeInt(u16, e[0x1a..0x1c], 5, .little);
    std.mem.writeInt(u32, e[0x1c..0x20], 2 * cs, .little);
    var slot: u64 = dir_off;
    while (true) : (slot += 32) {
        var b: [1]u8 = undefined;
        try d.readAt(slot, &b);
        if (b[0] == 0) break;
    }
    try d.writeAt(slot, &e);
    const eoc: u32 = if (bits == 32) 0x0fffffff else if (bits == 16) 0xffff else 0xfff;
    try testFat(d, f, 5, 6);
    try testFat(d, f, 6, eoc);
    var r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 1), r.files);
    if (bits == 32) {
        try std.testing.expectEqual(@as(u32, 1), r.counters);
        try std.testing.expect((try check(d, true)).clean());
        r = try check(d, false);
    }
    try std.testing.expectEqual(@as(u32, 0), r.errors);

    try testFat(d, f, 20, eoc);
    try testFat(d, f, 21, 22);
    try testFat(d, f, 22, eoc);
    r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 3), r.lost_clusters);
    try std.testing.expect(!r.clean());
    try std.testing.expect((try check(d, true)).clean());
    try std.testing.expect((try check(d, false)).errors == 0);

    try testFat(d, f, 6, 0);
    r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 1), r.bad_chains);
    try std.testing.expect((try check(d, true)).clean());
    r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 0), r.errors);

    std.mem.writeInt(u32, e[0x1c..0x20], 9 * cs, .little);
    try d.writeAt(slot, &e);
    r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 1), r.size_mismatches);
    try std.testing.expect((try check(d, true)).clean());
    var back: [32]u8 = undefined;
    try d.readAt(slot, &back);
    try std.testing.expectEqual(2 * cs, std.mem.readInt(u32, back[0x1c..0x20], .little));
    try std.testing.expectEqual(@as(u32, 0), (try check(d, false)).errors);
}

test "fat12 problems are found and repaired" {
    try expectFatRepairs(8 << 20, 12);
}

test "fat16 problems are found and repaired" {
    try expectFatRepairs(32 << 20, 16);
}

test "fat32 problems are found and repaired" {
    try expectFatRepairs(96 << 20, 32);
}

test "exfat problems are found and repaired" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "fsck-exfat");
    var pb: [600]u8 = undefined;
    const path = try sys.pathZ(&pb, "{s}/fs.img", .{root});
    const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    _ = std.os.linux.ftruncate(fd, 48 << 20);
    sys.close(fd);
    var d = try fs.Dev.open(path, true);
    defer d.close();
    try fs.mkfsExfat(d, "Prova");
    try std.testing.expectEqual(@as(u32, 0), (try check(d, false)).errors);

    var flags: [2]u8 = undefined;
    try d.readAt(0x6a, &flags);
    flags[0] |= 2;
    try d.writeAt(0x6a, &flags);
    var r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 1), r.dirty);
    try std.testing.expect((try check(d, true)).clean());
    try std.testing.expectEqual(@as(u32, 0), (try check(d, false)).errors);

    var boot: [512]u8 = undefined;
    try d.readAt(0, &boot);
    const e = try fs.Exfat.parse(&boot);
    var dir: [512]u8 = undefined;
    try d.readAt(e.heap_off + @as(u64, e.root - 2) * e.cluster, &dir);
    var bm_first: u32 = 0;
    var i: usize = 0;
    while (i < dir.len) : (i += 32) {
        if (dir[i] == 0x81) bm_first = std.mem.readInt(u32, dir[i + 20 ..][0..4], .little);
    }
    try std.testing.expect(bm_first >= 2);
    const bm_off = e.heap_off + @as(u64, bm_first - 2) * e.cluster;
    var byte: [1]u8 = undefined;
    try d.readAt(bm_off + 100, &byte);
    byte[0] |= 0x10;
    try d.writeAt(bm_off + 100, &byte);
    r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 1), r.lost_clusters);
    try std.testing.expect((try check(d, true)).clean());
    try std.testing.expectEqual(@as(u32, 0), (try check(d, false)).errors);

    var sum: [4]u8 = .{ 1, 2, 3, 4 };
    try d.writeAt(11 * 512 + 64, &sum);
    r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 1), r.counters);
    try std.testing.expect((try check(d, true)).clean());
    try std.testing.expectEqual(@as(u32, 0), (try check(d, false)).errors);
}

test "unknown filesystems are not checked" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "fsck-none");
    var pb: [600]u8 = undefined;
    const path = try sys.pathZ(&pb, "{s}/fs.img", .{root});
    const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    _ = std.os.linux.ftruncate(fd, 4 << 20);
    sys.close(fd);
    var d = try fs.Dev.open(path, false);
    defer d.close();
    try std.testing.expectError(error.NotFound, check(d, false));
}

test "ext4 problems are found and repaired" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "fsck-ext4");
    var pb: [600]u8 = undefined;
    const path = try sys.pathZ(&pb, "{s}/fs.img", .{root});
    const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    _ = std.os.linux.ftruncate(fd, 64 << 20);
    sys.close(fd);
    var d = try fs.Dev.open(path, true);
    defer d.close();
    try fs.ext4.mkfs(d, "check");
    var r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 0), r.errors);
    try std.testing.expect(r.dirs >= 2);

    var sb: [1024]u8 = undefined;
    try d.readAt(1024, &sb);
    std.mem.writeInt(u16, sb[0x3a..0x3c], 0, .little);
    try d.writeAt(1024, &sb);
    r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 1), r.dirty);
    try std.testing.expect(r.counters >= 1);
    try std.testing.expect((try check(d, true)).clean());
    try std.testing.expectEqual(@as(u32, 0), (try check(d, false)).errors);

    var desc: [64]u8 = undefined;
    try d.readAt(4096, &desc);
    const bitmap = std.mem.readInt(u32, desc[0..4], .little);
    var byte: [1]u8 = undefined;
    try d.readAt(@as(u64, bitmap) * 4096 + 2000, &byte);
    try std.testing.expectEqual(@as(u8, 0), byte[0]);
    byte[0] = 0x01;
    try d.writeAt(@as(u64, bitmap) * 4096 + 2000, &byte);
    r = try check(d, false);
    try std.testing.expectEqual(@as(u32, 1), r.lost_clusters);
    try std.testing.expect((try check(d, true)).clean());
    try std.testing.expectEqual(@as(u32, 0), (try check(d, false)).errors);

    try d.readAt(4096, &desc);
    desc[0x0c] +%= 3;
    try d.writeAt(4096, &desc);
    r = try check(d, false);
    try std.testing.expect(r.counters >= 1);
    try std.testing.expect((try check(d, true)).clean());
    try std.testing.expectEqual(@as(u32, 0), (try check(d, false)).errors);
}
