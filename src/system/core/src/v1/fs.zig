const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const FsInfo = extern struct {
    type: [16]u8,
    usage: [16]u8,
    uuid: [40]u8,
    label: [256]u8,
    version: [16]u8,
    block_size: u32,
    pad: u32,
    size: u64,
};

const crc32c = std.hash.crc.Crc32Iscsi;

pub const Dev = struct {
    fd: i32,
    size: u64,
    sector: u32,

    pub fn open(path: [*:0]const u8, writable: bool) !Dev {
        const fd = try sys.open(path, .{ .ACCMODE = if (writable) .RDWR else .RDONLY, .CLOEXEC = true }, 0);
        errdefer sys.close(fd);
        var size: u64 = 0;
        var sector: c_int = 512;
        if (sys.ioctl(fd, 0x80081272, @intFromPtr(&size))) |_| {
            _ = sys.ioctl(fd, 0x1268, @intFromPtr(&sector)) catch {};
        } else |_| {
            size = try sys.check(linux.lseek(fd, 0, linux.SEEK.END));
        }
        if (sector < 512 or sector > 4096) return error.Invalid;
        return .{ .fd = fd, .size = size, .sector = @intCast(sector) };
    }

    pub fn close(self: *Dev) void {
        sys.close(self.fd);
    }

    pub fn readAt(self: Dev, off: u64, buf: []u8) !void {
        if (off + buf.len > self.size) return error.Invalid;
        var n: usize = 0;
        while (n < buf.len) {
            const got = try sys.pread(self.fd, buf[n..], off + n);
            if (got == 0) return error.Io;
            n += got;
        }
    }

    pub fn writeAt(self: Dev, off: u64, buf: []const u8) !void {
        if (off + buf.len > self.size) return error.Invalid;
        try sys.pwriteAll(self.fd, buf, off);
    }

    pub fn zero(self: Dev, off: u64, len: u64) !void {
        const chunk = try sys.gpa.alloc(u8, 1 << 20);
        defer sys.gpa.free(chunk);
        @memset(chunk, 0);
        var done: u64 = 0;
        while (done < len) {
            const n: usize = @intCast(@min(len - done, chunk.len));
            try self.writeAt(off + done, chunk[0..n]);
            done += n;
        }
    }

    pub fn sync(self: Dev) !void {
        _ = try sys.check(linux.fsync(self.fd));
    }
};

fn put(dst: []u8, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(dst[0 .. dst.len - 1], fmt, args) catch return;
    dst[s.len] = 0;
}

fn setText(dst: []u8, src: []const u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

fn trimRight(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0 and (s[n - 1] == ' ' or s[n - 1] == 0)) n -= 1;
    return s[0..n];
}

fn uuidText(dst: []u8, u: []const u8) void {
    put(dst, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        u[0], u[1], u[2],  u[3],  u[4],  u[5],  u[6],  u[7],
        u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15],
    });
}

fn utf16Text(dst: []u8, raw: []const u8, units: usize) void {
    var n: usize = 0;
    var i: usize = 0;
    while (i < units and i * 2 + 1 < raw.len) : (i += 1) {
        const cu = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
        if (cu == 0) break;
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cu, &tmp) catch break;
        if (n + len + 1 > dst.len) break;
        @memcpy(dst[n .. n + len], tmp[0..len]);
        n += len;
    }
    dst[n] = 0;
}

fn utf16Encode(dst: []u8, s: []const u8) !usize {
    var it = (std.unicode.Utf8View.init(s) catch return error.Invalid).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp > 0xffff or i + 2 > dst.len) return error.Invalid;
        std.mem.writeInt(u16, dst[i..][0..2], @intCast(cp), .little);
        i += 2;
    }
    return i / 2;
}

fn random(buf: []u8) void {
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.getrandom(buf[n..].ptr, buf.len - n, 0);
        if (linux.errno(rc) == .SUCCESS) n += rc;
    }
}

fn randomUuid() [16]u8 {
    var u: [16]u8 = undefined;
    random(&u);
    u[6] = (u[6] & 0x0f) | 0x40;
    u[8] = (u[8] & 0x3f) | 0x80;
    return u;
}

const ext_magic = 0xef53;

fn extProbe(d: Dev, out: *FsInfo) !bool {
    var sb: [1024]u8 = undefined;
    d.readAt(1024, &sb) catch return false;
    if (std.mem.readInt(u16, sb[0x38..0x3a], .little) != ext_magic) return false;
    const compat = std.mem.readInt(u32, sb[0x5c..0x60], .little);
    const incompat = std.mem.readInt(u32, sb[0x60..0x64], .little);
    const ro = std.mem.readInt(u32, sb[0x64..0x68], .little);
    const ext3_incompat: u32 = 0x2 | 0x4 | 0x10;
    const ext3_ro: u32 = 0x1 | 0x2 | 0x4;
    const kind = if (incompat & ~ext3_incompat != 0 or ro & ~ext3_ro != 0) "ext4" else if (compat & 0x4 != 0) "ext3" else "ext2";
    setText(&out.type, kind);
    uuidText(&out.uuid, sb[0x68..0x78]);
    setText(&out.label, trimRight(std.mem.sliceTo(sb[0x78..0x88], 0)));
    put(&out.version, "1.{d}", .{std.mem.readInt(u16, sb[0x3e..0x40], .little)});
    out.block_size = @as(u32, 1024) << @intCast(std.mem.readInt(u32, sb[0x18..0x1c], .little));
    var blocks: u64 = std.mem.readInt(u32, sb[0x4..0x8], .little);
    if (incompat & 0x80 != 0) blocks |= @as(u64, std.mem.readInt(u32, sb[0x150..0x154], .little)) << 32;
    out.size = blocks * out.block_size;
    return true;
}

fn extChecksum(sb: *[1024]u8) void {
    const ro = std.mem.readInt(u32, sb[0x64..0x68], .little);
    if (ro & 0x400 == 0) return;
    std.mem.writeInt(u32, sb[0x3fc..0x400], ~crc32c.hash(sb[0..0x3fc]), .little);
}

fn extLabel(d: Dev, label: []const u8) !void {
    if (label.len > 16) return error.TooBig;
    var sb: [1024]u8 = undefined;
    try d.readAt(1024, &sb);
    if (std.mem.readInt(u16, sb[0x38..0x3a], .little) != ext_magic) return error.Invalid;
    @memset(sb[0x78..0x88], 0);
    @memcpy(sb[0x78 .. 0x78 + label.len], label);
    extChecksum(&sb);
    try d.writeAt(1024, &sb);
}

pub const Fat = struct {
    bps: u32,
    spc: u32,
    reserved: u32,
    nfats: u32,
    root_entries: u32,
    total: u64,
    fat_size: u32,
    root_cluster: u32,
    bits: u8,
    first_data: u64,
    clusters: u64,

    pub fn parse(b: *const [512]u8) ?Fat {
        if (b[510] != 0x55 or b[511] != 0xaa) return null;
        if (std.mem.eql(u8, b[3..11], "NTFS    ") or std.mem.eql(u8, b[3..11], "EXFAT   ")) return null;
        const bps = std.mem.readInt(u16, b[0x0b..0x0d], .little);
        const spc = b[0x0d];
        const reserved = std.mem.readInt(u16, b[0x0e..0x10], .little);
        const nfats = b[0x10];
        if (bps < 512 or bps > 4096 or !std.math.isPowerOfTwo(bps)) return null;
        if (spc == 0 or !std.math.isPowerOfTwo(spc) or reserved == 0 or nfats == 0 or nfats > 2) return null;
        if (b[0x15] < 0xf0 and b[0x15] != 0) return null;
        const root_entries = std.mem.readInt(u16, b[0x11..0x13], .little);
        var total: u64 = std.mem.readInt(u16, b[0x13..0x15], .little);
        if (total == 0) total = std.mem.readInt(u32, b[0x20..0x24], .little);
        var fat_size: u32 = std.mem.readInt(u16, b[0x16..0x18], .little);
        const fat32 = fat_size == 0;
        if (fat32) fat_size = std.mem.readInt(u32, b[0x24..0x28], .little);
        if (fat_size == 0 or total == 0) return null;
        const root_sectors = (root_entries * 32 + bps - 1) / bps;
        const first_data: u64 = reserved + @as(u64, nfats) * fat_size + root_sectors;
        if (first_data >= total) return null;
        const clusters = (total - first_data) / spc;
        const bits: u8 = if (fat32) 32 else if (clusters < 4085) 12 else 16;
        return .{ .bps = bps, .spc = spc, .reserved = reserved, .nfats = nfats, .root_entries = root_entries, .total = total, .fat_size = fat_size, .root_cluster = if (fat32) std.mem.readInt(u32, b[0x2c..0x30], .little) else 0, .bits = bits, .first_data = first_data, .clusters = clusters };
    }

    fn extOffset(self: Fat) usize {
        return if (self.bits == 32) 0x40 else 0x24;
    }

    pub fn clusterOffset(self: Fat, c: u32) u64 {
        return (self.first_data + @as(u64, c - 2) * self.spc) * self.bps;
    }

    fn next(self: Fat, d: Dev, c: u32) !u32 {
        const fat_off = @as(u64, self.reserved) * self.bps;
        switch (self.bits) {
            32 => {
                var b: [4]u8 = undefined;
                try d.readAt(fat_off + @as(u64, c) * 4, &b);
                return std.mem.readInt(u32, &b, .little) & 0x0fffffff;
            },
            16 => {
                var b: [2]u8 = undefined;
                try d.readAt(fat_off + @as(u64, c) * 2, &b);
                return std.mem.readInt(u16, &b, .little);
            },
            else => return error.Invalid,
        }
    }

    fn eoc(self: Fat, c: u32) bool {
        return switch (self.bits) {
            32 => c >= 0x0ffffff8 or c < 2,
            16 => c >= 0xfff8 or c < 2,
            else => c >= 0xff8 or c < 2,
        };
    }
};

const Span = struct { off: u64, len: u64 };

fn fatRootSpans(f: Fat, d: Dev, out: []Span) ![]Span {
    if (f.bits != 32) {
        out[0] = .{ .off = (@as(u64, f.reserved) + @as(u64, f.nfats) * f.fat_size) * f.bps, .len = @as(u64, f.root_entries) * 32 };
        return out[0..1];
    }
    var n: usize = 0;
    var c = f.root_cluster;
    while (!f.eoc(c) and n < out.len) {
        if (c >= f.clusters + 2) return error.Invalid;
        out[n] = .{ .off = f.clusterOffset(c), .len = @as(u64, f.spc) * f.bps };
        n += 1;
        c = try f.next(d, c);
    }
    return out[0..n];
}

fn fatRootLabel(f: Fat, d: Dev, out: []u8) !bool {
    var spans: [64]Span = undefined;
    for (try fatRootSpans(f, d, &spans)) |s| {
        var off: u64 = 0;
        var e: [32]u8 = undefined;
        while (off < s.len) : (off += 32) {
            try d.readAt(s.off + off, &e);
            if (e[0] == 0) return false;
            if (e[0] == 0xe5 or e[11] == 0x0f) continue;
            if (e[11] & 0x08 != 0 and e[11] & 0x10 == 0) {
                setText(out, trimRight(e[0..11]));
                return true;
            }
        }
    }
    return false;
}

fn fatProbe(d: Dev, out: *FsInfo) !bool {
    var b: [512]u8 = undefined;
    d.readAt(0, &b) catch return false;
    const f = Fat.parse(&b) orelse return false;
    const x = f.extOffset();
    setText(&out.type, "vfat");
    put(&out.version, "FAT{d}", .{f.bits});
    out.block_size = f.bps * f.spc;
    out.size = f.total * f.bps;
    if (b[x + 2] == 0x29 or b[x + 2] == 0x28) {
        const id = std.mem.readInt(u32, b[x + 3 ..][0..4], .little);
        put(&out.uuid, "{X:0>4}-{X:0>4}", .{ id >> 16, id & 0xffff });
        if (!(fatRootLabel(f, d, &out.label) catch false)) {
            const l = trimRight(b[x + 7 .. x + 18]);
            if (b[x + 2] == 0x29 and !std.mem.eql(u8, l, "NO NAME")) setText(&out.label, l);
        }
    }
    return true;
}

fn fatTimestamp() [4]u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.sec) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const year: u16 = if (yd.year < 1980) 0 else @intCast(yd.year - 1980);
    const date: u16 = (year << 9) | (@as(u16, md.month.numeric()) << 5) | (@as(u16, md.day_index) + 1);
    const time: u16 = (@as(u16, ds.getHoursIntoDay()) << 11) | (@as(u16, ds.getMinutesIntoHour()) << 5) | (ds.getSecondsIntoMinute() / 2);
    var out: [4]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], time, .little);
    std.mem.writeInt(u16, out[2..4], date, .little);
    return out;
}

fn fatName(label: []const u8) ![11]u8 {
    if (label.len > 11) return error.TooBig;
    var n = [_]u8{' '} ** 11;
    for (label, 0..) |c, i| {
        if (c < 0x20 or c >= 0x7f) return error.Invalid;
        if (std.mem.indexOfScalar(u8, "\"*+,./:;<=>?[\\]|", c) != null) return error.Invalid;
        n[i] = std.ascii.toUpper(c);
    }
    return n;
}

fn labelEntry(name: [11]u8) [32]u8 {
    var e = std.mem.zeroes([32]u8);
    @memcpy(e[0..11], &name);
    e[11] = 0x08;
    const t = fatTimestamp();
    @memcpy(e[22..26], &t);
    return e;
}

fn fatLabel(d: Dev, label: []const u8) !void {
    var b: [512]u8 = undefined;
    try d.readAt(0, &b);
    const f = Fat.parse(&b) orelse return error.Invalid;
    const name = try fatName(label);
    const x = f.extOffset();
    if (b[x + 2] == 0x29) {
        @memcpy(b[x + 7 .. x + 18], if (label.len == 0) "NO NAME    " else &name);
        try d.writeAt(0, &b);
        if (f.bits == 32) {
            var bak: [512]u8 = undefined;
            const backup = std.mem.readInt(u16, b[0x32..0x34], .little);
            if (backup != 0 and backup < f.reserved) {
                try d.readAt(@as(u64, backup) * f.bps, &bak);
                if (bak[510] == 0x55 and bak[511] == 0xaa) {
                    @memcpy(bak[x + 7 .. x + 18], b[x + 7 .. x + 18]);
                    try d.writeAt(@as(u64, backup) * f.bps, &bak);
                }
            }
        }
    }
    var spans: [64]Span = undefined;
    var free: ?u64 = null;
    var e: [32]u8 = undefined;
    outer: for (try fatRootSpans(f, d, &spans)) |s| {
        var off: u64 = 0;
        while (off < s.len) : (off += 32) {
            try d.readAt(s.off + off, &e);
            if (e[0] == 0) {
                if (free == null) free = s.off + off;
                break :outer;
            }
            if (e[0] == 0xe5) {
                if (free == null) free = s.off + off;
                continue;
            }
            if (e[11] == 0x0f) continue;
            if (e[11] & 0x08 != 0 and e[11] & 0x10 == 0) {
                if (label.len == 0) {
                    e[0] = 0xe5;
                    try d.writeAt(s.off + off, &e);
                } else {
                    @memcpy(e[0..11], &name);
                    try d.writeAt(s.off + off, &e);
                }
                return;
            }
        }
    }
    if (label.len == 0) return;
    const at = free orelse return error.TooBig;
    try d.writeAt(at, &labelEntry(name));
}

pub const FatOptions = struct {
    label: []const u8 = "",
    bits: u8 = 0,
};

pub fn mkfsVfat(d: Dev, opts: FatOptions) !void {
    const bps: u32 = d.sector;
    const total: u64 = d.size / bps;
    if (total > 0xffffffff) return error.TooBig;
    const bytes = d.size;
    const bits: u8 = if (opts.bits != 0) opts.bits else if (bytes >= 512 << 20) 32 else if (bytes >= 16 << 20) 16 else 12;
    if (bits != 12 and bits != 16 and bits != 32) return error.Invalid;
    const name = try fatName(opts.label);
    const reserved: u32 = if (bits == 32) 32 else 1;
    const root_entries: u32 = if (bits == 32) 0 else 512;
    const nfats: u32 = 2;
    const root_sectors = (root_entries * 32 + bps - 1) / bps;
    var spc: u32 = if (bits == 32) blk: {
        if (bytes <= 260 << 20) break :blk 512 / bps;
        if (bytes <= 8 << 30) break :blk 4096 / bps;
        if (bytes <= 16 << 30) break :blk 8192 / bps;
        if (bytes <= 32 << 30) break :blk 16384 / bps;
        break :blk 32768 / bps;
    } else if (bits == 16) blk: {
        if (bytes <= 16 << 20) break :blk 1024 / bps;
        if (bytes <= 128 << 20) break :blk 2048 / bps;
        if (bytes <= 256 << 20) break :blk 4096 / bps;
        if (bytes <= 512 << 20) break :blk 8192 / bps;
        if (bytes <= 1 << 30) break :blk 16384 / bps;
        break :blk 32768 / bps;
    } else 1;
    if (spc == 0) spc = 1;
    var fat_size: u32 = 0;
    var clusters: u64 = 0;
    while (true) {
        fat_size = 1;
        while (true) {
            const meta = @as(u64, reserved) + @as(u64, nfats) * fat_size + root_sectors;
            if (meta >= total) return error.TooBig;
            clusters = (total - meta) / spc;
            const need: u32 = @intCast(((clusters + 2) * bits / 8 + bps) / bps);
            if (need <= fat_size) break;
            fat_size = need;
        }
        const ok = switch (bits) {
            12 => clusters < 4085,
            16 => clusters >= 4085 and clusters < 65525,
            else => clusters >= 65525 and clusters < 0x0ffffff5,
        };
        if (ok) break;
        if (bits == 12 and clusters >= 4085 and spc < 128) {
            spc *= 2;
            continue;
        }
        if (bits == 16 and clusters >= 65525 and spc < 128) {
            spc *= 2;
            continue;
        }
        if (bits == 32 and clusters < 65525 and spc > 1) {
            spc /= 2;
            continue;
        }
        return error.Invalid;
    }
    var volid: [4]u8 = undefined;
    random(&volid);
    const bs = try sys.gpa.alloc(u8, bps);
    defer sys.gpa.free(bs);
    @memset(bs, 0);
    bs[0] = 0xeb;
    bs[1] = if (bits == 32) 0x58 else 0x3c;
    bs[2] = 0x90;
    @memcpy(bs[3..11], "MSWIN4.1");
    std.mem.writeInt(u16, bs[0x0b..0x0d], @intCast(bps), .little);
    bs[0x0d] = @intCast(spc);
    std.mem.writeInt(u16, bs[0x0e..0x10], @intCast(reserved), .little);
    bs[0x10] = @intCast(nfats);
    std.mem.writeInt(u16, bs[0x11..0x13], @intCast(root_entries), .little);
    if (total < 0x10000 and bits != 32) std.mem.writeInt(u16, bs[0x13..0x15], @intCast(total), .little) else std.mem.writeInt(u32, bs[0x20..0x24], @intCast(total), .little);
    bs[0x15] = 0xf8;
    std.mem.writeInt(u16, bs[0x18..0x1a], 32, .little);
    std.mem.writeInt(u16, bs[0x1a..0x1c], 64, .little);
    const x: usize = if (bits == 32) 0x40 else 0x24;
    if (bits == 32) {
        std.mem.writeInt(u32, bs[0x24..0x28], fat_size, .little);
        std.mem.writeInt(u32, bs[0x2c..0x30], 2, .little);
        std.mem.writeInt(u16, bs[0x30..0x32], 1, .little);
        std.mem.writeInt(u16, bs[0x32..0x34], 6, .little);
    } else std.mem.writeInt(u16, bs[0x16..0x18], @intCast(fat_size), .little);
    bs[x] = 0x80;
    bs[x + 2] = 0x29;
    @memcpy(bs[x + 3 .. x + 7], &volid);
    @memcpy(bs[x + 7 .. x + 18], if (opts.label.len == 0) "NO NAME    " else &name);
    @memcpy(bs[x + 18 .. x + 26], switch (bits) {
        12 => "FAT12   ",
        16 => "FAT16   ",
        else => "FAT32   ",
    });
    bs[510] = 0x55;
    bs[511] = 0xaa;
    const root_bytes: u64 = if (bits == 32) @as(u64, spc) * bps else @as(u64, root_sectors) * bps;
    const meta_end = (@as(u64, reserved) + @as(u64, nfats) * fat_size) * bps + root_bytes;
    try d.zero(0, meta_end);
    try d.writeAt(0, bs);
    if (bits == 32) {
        const fsinfo = try sys.gpa.alloc(u8, bps);
        defer sys.gpa.free(fsinfo);
        @memset(fsinfo, 0);
        std.mem.writeInt(u32, fsinfo[0..4], 0x41615252, .little);
        std.mem.writeInt(u32, fsinfo[484..488], 0x61417272, .little);
        std.mem.writeInt(u32, fsinfo[488..492], @intCast(clusters - 1), .little);
        std.mem.writeInt(u32, fsinfo[492..496], 3, .little);
        std.mem.writeInt(u32, fsinfo[508..512], 0xaa550000, .little);
        try d.writeAt(@as(u64, bps), fsinfo);
        try d.writeAt(6 * @as(u64, bps), bs);
        try d.writeAt(7 * @as(u64, bps), fsinfo);
    }
    var head: [12]u8 = undefined;
    const head_len: usize = switch (bits) {
        12 => blk: {
            @memcpy(head[0..3], &[_]u8{ 0xf8, 0xff, 0xff });
            break :blk 3;
        },
        16 => blk: {
            std.mem.writeInt(u16, head[0..2], 0xfff8, .little);
            std.mem.writeInt(u16, head[2..4], 0xffff, .little);
            break :blk 4;
        },
        else => blk: {
            std.mem.writeInt(u32, head[0..4], 0x0ffffff8, .little);
            std.mem.writeInt(u32, head[4..8], 0x0fffffff, .little);
            std.mem.writeInt(u32, head[8..12], 0x0fffffff, .little);
            break :blk 12;
        },
    };
    var i: u32 = 0;
    while (i < nfats) : (i += 1) try d.writeAt((@as(u64, reserved) + @as(u64, i) * fat_size) * bps, head[0..head_len]);
    if (opts.label.len > 0) {
        const root_off = (@as(u64, reserved) + @as(u64, nfats) * fat_size) * bps;
        try d.writeAt(root_off, &labelEntry(name));
    }
    try d.sync();
}

fn exfatProbe(d: Dev, out: *FsInfo) !bool {
    var b: [512]u8 = undefined;
    d.readAt(0, &b) catch return false;
    if (!std.mem.eql(u8, b[3..11], "EXFAT   ")) return false;
    const id = std.mem.readInt(u32, b[0x64..0x68], .little);
    setText(&out.type, "exfat");
    put(&out.uuid, "{X:0>4}-{X:0>4}", .{ id >> 16, id & 0xffff });
    put(&out.version, "{d}.{d}", .{ b[0x69], b[0x68] });
    const e = try Exfat.parse(&b);
    out.block_size = e.cluster;
    out.size = std.mem.readInt(u64, b[0x48..0x50], .little) << @intCast(b[0x6c]);
    var spans: [64]Span = undefined;
    for (try e.rootSpans(d, &spans)) |s| {
        var off: u64 = 0;
        var ent: [32]u8 = undefined;
        while (off < s.len) : (off += 32) {
            try d.readAt(s.off + off, &ent);
            if (ent[0] == 0) return true;
            if (ent[0] == 0x83) {
                utf16Text(&out.label, ent[2..24], @min(ent[1], 11));
                return true;
            }
        }
    }
    return true;
}

pub const Exfat = struct {
    sector: u64,
    cluster: u32,
    fat_off: u64,
    heap_off: u64,
    count: u32,
    root: u32,

    pub fn parse(b: *const [512]u8) !Exfat {
        const ss: u6 = @intCast(@min(b[0x6c], 12));
        const cs: u6 = @intCast(@min(b[0x6d], 25));
        const sector = @as(u64, 1) << ss;
        return .{
            .sector = sector,
            .cluster = @intCast(sector << cs),
            .fat_off = @as(u64, std.mem.readInt(u32, b[0x50..0x54], .little)) * sector,
            .heap_off = @as(u64, std.mem.readInt(u32, b[0x58..0x5c], .little)) * sector,
            .count = std.mem.readInt(u32, b[0x5c..0x60], .little),
            .root = std.mem.readInt(u32, b[0x60..0x64], .little),
        };
    }

    fn rootSpans(self: Exfat, d: Dev, out: []Span) ![]Span {
        var n: usize = 0;
        var c = self.root;
        while (c >= 2 and c < self.count + 2 and n < out.len) {
            out[n] = .{ .off = self.heap_off + @as(u64, c - 2) * self.cluster, .len = self.cluster };
            n += 1;
            var b: [4]u8 = undefined;
            try d.readAt(self.fat_off + @as(u64, c) * 4, &b);
            c = std.mem.readInt(u32, &b, .little);
        }
        return out[0..n];
    }
};

fn exfatLabel(d: Dev, label: []const u8) !void {
    var b: [512]u8 = undefined;
    try d.readAt(0, &b);
    if (!std.mem.eql(u8, b[3..11], "EXFAT   ")) return error.Invalid;
    const e = try Exfat.parse(&b);
    var ent = std.mem.zeroes([32]u8);
    const units = try utf16Encode(ent[2..24], label);
    ent[0] = if (units == 0) 0x03 else 0x83;
    ent[1] = @intCast(units);
    var spans: [64]Span = undefined;
    var free: ?u64 = null;
    var cur: [32]u8 = undefined;
    outer: for (try e.rootSpans(d, &spans)) |s| {
        var off: u64 = 0;
        while (off < s.len) : (off += 32) {
            try d.readAt(s.off + off, &cur);
            if (cur[0] == 0x83 or cur[0] == 0x03) {
                try d.writeAt(s.off + off, &ent);
                return;
            }
            if (cur[0] == 0) {
                if (free == null) free = s.off + off;
                break :outer;
            }
            if (cur[0] & 0x80 == 0 and free == null) free = s.off + off;
        }
    }
    if (units == 0) return;
    try d.writeAt(free orelse return error.TooBig, &ent);
}

const btrfs_offsets = [_]u64{ 0x10000, 0x4000000, 0x4000000000 };

fn btrfsProbe(d: Dev, out: *FsInfo) !bool {
    var sb: [4096]u8 = undefined;
    d.readAt(0x10000, &sb) catch return false;
    if (!std.mem.eql(u8, sb[0x40..0x48], "_BHRfS_M")) return false;
    setText(&out.type, "btrfs");
    uuidText(&out.uuid, sb[0x20..0x30]);
    setText(&out.label, std.mem.sliceTo(sb[0x12b..0x22b], 0));
    out.block_size = std.mem.readInt(u32, sb[0x90..0x94], .little);
    out.size = std.mem.readInt(u64, sb[0x70..0x78], .little);
    put(&out.version, "1", .{});
    return true;
}

fn btrfsLabel(d: Dev, label: []const u8) !void {
    if (label.len > 255) return error.TooBig;
    var written = false;
    for (btrfs_offsets) |off| {
        var sb: [4096]u8 = undefined;
        d.readAt(off, &sb) catch continue;
        if (!std.mem.eql(u8, sb[0x40..0x48], "_BHRfS_M")) continue;
        if (std.mem.readInt(u64, sb[0x30..0x38], .little) != off) continue;
        if (std.mem.readInt(u16, sb[0xc4..0xc6], .little) != 0) return error.Unsupported;
        @memset(sb[0x12b..0x22b], 0);
        @memcpy(sb[0x12b .. 0x12b + label.len], label);
        @memset(sb[0..0x20], 0);
        std.mem.writeInt(u32, sb[0..4], crc32c.hash(sb[0x20..]), .little);
        try d.writeAt(off, &sb);
        written = true;
    }
    if (!written) return error.Invalid;
}

fn xfsProbe(d: Dev, out: *FsInfo) !bool {
    var sb: [512]u8 = undefined;
    d.readAt(0, &sb) catch return false;
    if (!std.mem.eql(u8, sb[0..4], "XFSB")) return false;
    setText(&out.type, "xfs");
    uuidText(&out.uuid, sb[0x20..0x30]);
    setText(&out.label, trimRight(std.mem.sliceTo(sb[0x6c..0x78], 0)));
    out.block_size = std.mem.readInt(u32, sb[0x4..0x8], .big);
    out.size = std.mem.readInt(u64, sb[0x8..0x10], .big) * out.block_size;
    put(&out.version, "{d}", .{std.mem.readInt(u16, sb[0x64..0x66], .big) & 0xf});
    return true;
}

fn xfsLabel(d: Dev, label: []const u8) !void {
    if (label.len > 12) return error.TooBig;
    var sb0: [512]u8 = undefined;
    try d.readAt(0, &sb0);
    if (!std.mem.eql(u8, sb0[0..4], "XFSB")) return error.Invalid;
    const bsize: u64 = std.mem.readInt(u32, sb0[0x4..0x8], .big);
    const agblocks: u64 = std.mem.readInt(u32, sb0[0x54..0x58], .big);
    const agcount: u32 = std.mem.readInt(u32, sb0[0x58..0x5c], .big);
    const sect: usize = std.mem.readInt(u16, sb0[0x66..0x68], .big);
    if (sect < 512 or sect > 32768) return error.Invalid;
    const v5 = std.mem.readInt(u16, sb0[0x64..0x66], .big) & 0xf == 5;
    const buf = try sys.gpa.alloc(u8, sect);
    defer sys.gpa.free(buf);
    var ag: u32 = 0;
    while (ag < agcount) : (ag += 1) {
        const off = @as(u64, ag) * agblocks * bsize;
        try d.readAt(off, buf);
        if (!std.mem.eql(u8, buf[0..4], "XFSB")) continue;
        @memset(buf[0x6c..0x78], 0);
        @memcpy(buf[0x6c .. 0x6c + label.len], label);
        if (v5) {
            @memset(buf[0xe0..0xe4], 0);
            std.mem.writeInt(u32, buf[0xe0..0xe4], crc32c.hash(buf), .little);
        }
        try d.writeAt(off, buf);
    }
}

const swap_pages = [_]u32{ 4096, 8192, 16384, 65536 };

fn swapPage(d: Dev) ?u32 {
    for (swap_pages) |p| {
        var sig: [10]u8 = undefined;
        d.readAt(p - 10, &sig) catch continue;
        if (std.mem.eql(u8, &sig, "SWAPSPACE2") or std.mem.eql(u8, &sig, "SWAP-SPACE")) return p;
    }
    return null;
}

fn swapProbe(d: Dev, out: *FsInfo) !bool {
    const page = swapPage(d) orelse return false;
    var h: [1088]u8 = undefined;
    try d.readAt(0, &h);
    setText(&out.type, "swap");
    setText(&out.usage, "other");
    put(&out.version, "{d}", .{std.mem.readInt(u32, h[1024..1028], .little)});
    if (!isZero(h[1036..1052])) uuidText(&out.uuid, h[1036..1052]);
    setText(&out.label, std.mem.sliceTo(h[1052..1068], 0));
    out.block_size = page;
    out.size = (@as(u64, std.mem.readInt(u32, h[1028..1032], .little)) + 1) * page;
    return true;
}

fn swapLabel(d: Dev, label: []const u8) !void {
    if (label.len > 16) return error.TooBig;
    _ = swapPage(d) orelse return error.Invalid;
    var l = std.mem.zeroes([16]u8);
    @memcpy(l[0..label.len], label);
    try d.writeAt(1052, &l);
}

fn isZero(b: []const u8) bool {
    for (b) |c| if (c != 0) return false;
    return true;
}

pub fn mkswap(d: Dev, label: []const u8) !void {
    if (label.len > 16) return error.TooBig;
    const page: u32 = @intCast(std.c.sysconf(@intFromEnum(std.c._SC.PAGESIZE)));
    const pages = d.size / page;
    if (pages < 10) return error.TooBig;
    const h = try sys.gpa.alloc(u8, page);
    defer sys.gpa.free(h);
    @memset(h, 0);
    std.mem.writeInt(u32, h[1024..1028], 1, .little);
    std.mem.writeInt(u32, h[1028..1032], @intCast(@min(pages - 1, 0xffffffff)), .little);
    const u = randomUuid();
    @memcpy(h[1036..1052], &u);
    @memcpy(h[1052 .. 1052 + label.len], label);
    @memcpy(h[page - 10 ..], "SWAPSPACE2");
    try d.writeAt(0, h);
    try d.sync();
}

fn f2fsProbe(d: Dev, out: *FsInfo) !bool {
    var sb: [1024 + 124]u8 = undefined;
    d.readAt(1024, &sb) catch return false;
    if (std.mem.readInt(u32, sb[0..4], .little) != 0xf2f52010) return false;
    setText(&out.type, "f2fs");
    uuidText(&out.uuid, sb[108..124]);
    utf16Text(&out.label, sb[124..], 512);
    put(&out.version, "{d}.{d}", .{ std.mem.readInt(u16, sb[4..6], .little), std.mem.readInt(u16, sb[6..8], .little) });
    out.block_size = @as(u32, 1) << @intCast(@min(std.mem.readInt(u32, sb[16..20], .little), 16));
    out.size = std.mem.readInt(u64, sb[36..44], .little) * out.block_size;
    return true;
}

fn luksProbe(d: Dev, out: *FsInfo) !bool {
    var h: [512]u8 = undefined;
    d.readAt(0, &h) catch return false;
    if (!std.mem.eql(u8, h[0..6], "LUKS\xba\xbe")) return false;
    setText(&out.type, "crypto_LUKS");
    setText(&out.usage, "crypto");
    const ver = std.mem.readInt(u16, h[6..8], .big);
    put(&out.version, "{d}", .{ver});
    setText(&out.uuid, std.mem.sliceTo(h[0xa8..0xd0], 0));
    if (ver == 2) setText(&out.label, std.mem.sliceTo(h[0x18..0x48], 0));
    return true;
}

fn isoProbe(d: Dev, out: *FsInfo) !bool {
    var pvd: [2048]u8 = undefined;
    d.readAt(0x8000, &pvd) catch return false;
    if (!std.mem.eql(u8, pvd[1..6], "CD001")) return false;
    setText(&out.type, "iso9660");
    setText(&out.label, trimRight(pvd[40..72]));
    const t = pvd[813..829];
    put(&out.uuid, "{s}-{s}-{s}-{s}-{s}-{s}-{s}", .{ t[0..4], t[4..6], t[6..8], t[8..10], t[10..12], t[12..14], t[14..16] });
    out.block_size = std.mem.readInt(u16, pvd[128..130], .little);
    out.size = @as(u64, std.mem.readInt(u32, pvd[80..84], .little)) * out.block_size;
    return true;
}

fn ntfsProbe(d: Dev, out: *FsInfo) !bool {
    var b: [512]u8 = undefined;
    d.readAt(0, &b) catch return false;
    if (!std.mem.eql(u8, b[3..11], "NTFS    ")) return false;
    setText(&out.type, "ntfs");
    put(&out.uuid, "{X:0>16}", .{std.mem.readInt(u64, b[0x48..0x50], .little)});
    out.block_size = @as(u32, std.mem.readInt(u16, b[0x0b..0x0d], .little)) * b[0x0d];
    out.size = std.mem.readInt(u64, b[0x28..0x30], .little) * std.mem.readInt(u16, b[0x0b..0x0d], .little);
    return true;
}

pub fn probe(d: Dev) !FsInfo {
    var out = std.mem.zeroes(FsInfo);
    setText(&out.usage, "filesystem");
    const probes = [_]*const fn (Dev, *FsInfo) anyerror!bool{ luksProbe, extProbe, btrfsProbe, xfsProbe, f2fsProbe, exfatProbe, ntfsProbe, swapProbe, isoProbe, fatProbe };
    for (probes) |p| {
        if (try p(d, &out)) return out;
        const usage = out.usage;
        out = std.mem.zeroes(FsInfo);
        out.usage = usage;
    }
    return error.NotFound;
}

pub fn setLabel(d: Dev, label: []const u8) !void {
    const info = try probe(d);
    const t = sys.cstr(&info.type);
    if (std.mem.startsWith(u8, t, "ext")) try extLabel(d, label) else if (std.mem.eql(u8, t, "vfat")) try fatLabel(d, label) else if (std.mem.eql(u8, t, "exfat")) try exfatLabel(d, label) else if (std.mem.eql(u8, t, "btrfs")) try btrfsLabel(d, label) else if (std.mem.eql(u8, t, "xfs")) try xfsLabel(d, label) else if (std.mem.eql(u8, t, "swap")) try swapLabel(d, label) else return error.Unsupported;
    try d.sync();
}

const upcase = @import("upcase.zig");
pub const ext4 = @import("ext4.zig");

fn upcaseTable(out: []u16) usize {
    var up: [0x10000]u16 = undefined;
    for (&up, 0..) |*u, i| u.* = @intCast(i);
    for (upcase.pairs) |p| up[p[0]] = p[1];
    var n: usize = 0;
    var i: usize = 0;
    while (i < up.len) {
        if (up[i] != i) {
            out[n] = up[i];
            n += 1;
            i += 1;
            continue;
        }
        var j = i;
        while (j < up.len and up[j] == j) j += 1;
        if (j - i > 2 or j == up.len) {
            out[n] = 0xffff;
            out[n + 1] = @intCast(j - i);
            n += 2;
        } else {
            while (i < j) : (i += 1) {
                out[n] = @intCast(i);
                n += 1;
            }
        }
        i = j;
    }
    return n;
}

pub fn exfatSum(sum: u32, b: []const u8, skip_flags: bool) u32 {
    var c = sum;
    for (b, 0..) |x, i| {
        if (skip_flags and (i == 106 or i == 107 or i == 112)) continue;
        c = ((c & 1) << 31) +% (c >> 1) +% x;
    }
    return c;
}

pub fn mkfsExfat(d: Dev, label: []const u8) !void {
    const bps: u64 = d.sector;
    const shift: u8 = @intCast(std.math.log2_int(u64, bps));
    const vol = d.size / bps;
    if (d.size < 1 << 20) return error.TooBig;
    const cluster: u64 = if (d.size <= 256 << 20) 4096 else if (d.size <= 32 << 30) 32768 else 131072;
    const spc = @max(cluster / bps, 1);
    const boundary: u64 = (if (d.size >= 16 << 20) @as(u64, 1 << 20) else 65536) / bps;
    const fat_off = std.mem.alignForward(u64, 24, boundary);
    const fat_len = ((vol / spc + 2) * 4 + bps - 1) / bps;
    const heap_off = std.mem.alignForward(u64, fat_off + fat_len, @max(boundary, spc));
    if (heap_off >= vol) return error.TooBig;
    const count = (vol - heap_off) / spc;
    if (count < 4 or count > 0xfffffff5) return error.TooBig;
    const cbytes = spc * bps;
    var lab = std.mem.zeroes([32]u8);
    const units = try utf16Encode(lab[2..24], label);
    lab[0] = if (units == 0) 0x03 else 0x83;
    lab[1] = @intCast(units);

    const up = try sys.gpa.alloc(u16, 0x10000 + 64);
    defer sys.gpa.free(up);
    const up_units = upcaseTable(up);
    const up_bytes = std.mem.sliceAsBytes(up[0..up_units]);
    const bitmap_bytes = (count + 7) / 8;
    const bitmap_clusters = (bitmap_bytes + cbytes - 1) / cbytes;
    const up_clusters = (up_bytes.len + cbytes - 1) / cbytes;
    const bitmap_first: u32 = 2;
    const up_first: u32 = @intCast(2 + bitmap_clusters);
    const root_first: u32 = @intCast(2 + bitmap_clusters + up_clusters);
    const used = bitmap_clusters + up_clusters + 1;
    if (used >= count) return error.TooBig;

    try d.zero(0, heap_off * bps + used * cbytes);

    const boot = try sys.gpa.alloc(u8, 12 * bps);
    defer sys.gpa.free(boot);
    @memset(boot, 0);
    const b0 = boot[0..bps];
    b0[0] = 0xeb;
    b0[1] = 0x76;
    b0[2] = 0x90;
    @memcpy(b0[3..11], "EXFAT   ");
    std.mem.writeInt(u64, b0[0x48..0x50], vol, .little);
    std.mem.writeInt(u32, b0[0x50..0x54], @intCast(fat_off), .little);
    std.mem.writeInt(u32, b0[0x54..0x58], @intCast(fat_len), .little);
    std.mem.writeInt(u32, b0[0x58..0x5c], @intCast(heap_off), .little);
    std.mem.writeInt(u32, b0[0x5c..0x60], @intCast(count), .little);
    std.mem.writeInt(u32, b0[0x60..0x64], root_first, .little);
    var serial: [4]u8 = undefined;
    random(&serial);
    @memcpy(b0[0x64..0x68], &serial);
    std.mem.writeInt(u16, b0[0x68..0x6a], 0x0100, .little);
    b0[0x6c] = shift;
    b0[0x6d] = @intCast(std.math.log2_int(u64, spc));
    b0[0x6e] = 1;
    b0[0x6f] = 0x80;
    b0[510] = 0x55;
    b0[511] = 0xaa;
    var s: usize = 1;
    while (s <= 8) : (s += 1) {
        const sec = boot[s * bps .. (s + 1) * bps];
        sec[bps - 2] = 0x55;
        sec[bps - 1] = 0xaa;
    }
    var sum: u32 = exfatSum(0, b0, true);
    s = 1;
    while (s < 11) : (s += 1) sum = exfatSum(sum, boot[s * bps .. (s + 1) * bps], false);
    var w: usize = 11 * bps;
    while (w < 12 * bps) : (w += 4) std.mem.writeInt(u32, boot[w..][0..4], sum, .little);
    try d.writeAt(0, boot);
    try d.writeAt(12 * bps, boot);

    const fat_bytes: usize = @intCast((2 + used) * 4);
    const fat = try sys.gpa.alloc(u8, fat_bytes);
    defer sys.gpa.free(fat);
    std.mem.writeInt(u32, fat[0..4], 0xfffffff8, .little);
    std.mem.writeInt(u32, fat[4..8], 0xffffffff, .little);
    const chains = [_][2]u64{ .{ bitmap_first, bitmap_clusters }, .{ up_first, up_clusters }, .{ root_first, 1 } };
    for (chains) |ch| {
        var k: u64 = 0;
        while (k < ch[1]) : (k += 1) {
            const c = ch[0] + k;
            const next: u32 = if (k + 1 == ch[1]) 0xffffffff else @intCast(c + 1);
            std.mem.writeInt(u32, fat[@intCast(c * 4)..][0..4], next, .little);
        }
    }
    try d.writeAt(fat_off * bps, fat);

    const bitmap = try sys.gpa.alloc(u8, @intCast((used + 7) / 8));
    defer sys.gpa.free(bitmap);
    @memset(bitmap, 0);
    var k: u64 = 0;
    while (k < used) : (k += 1) bitmap[@intCast(k / 8)] |= @as(u8, 1) << @intCast(k % 8);
    const heap = heap_off * bps;
    try d.writeAt(heap, bitmap);
    try d.writeAt(heap + (up_first - 2) * cbytes, up_bytes);

    var root: [96]u8 = std.mem.zeroes([96]u8);
    @memcpy(root[0..32], &lab);
    root[32] = 0x81;
    std.mem.writeInt(u32, root[52..56], bitmap_first, .little);
    std.mem.writeInt(u64, root[56..64], bitmap_bytes, .little);
    root[64] = 0x82;
    std.mem.writeInt(u32, root[68..72], exfatSum(0, up_bytes, false), .little);
    std.mem.writeInt(u32, root[84..88], up_first, .little);
    std.mem.writeInt(u64, root[88..96], up_bytes.len, .little);
    try d.writeAt(heap + (root_first - 2) * cbytes, &root);
    try d.sync();
}

test "ext4 formats, probes and relabels" {
    for ([_]u64{ 32 << 20, 600 << 20, 2 << 30 }) |size| {
        var pb: [600]u8 = undefined;
        var nb: [32]u8 = undefined;
        const path = try testImage(try std.fmt.bufPrint(&nb, "ext4-{d}", .{size >> 20}), size, &pb);
        var d = try Dev.open(path, true);
        defer d.close();
        try ext4.mkfs(d, "rootfs");
        const info = try probe(d);
        try std.testing.expectEqualStrings("ext4", sys.cstr(&info.type));
        try std.testing.expectEqualStrings("rootfs", sys.cstr(&info.label));
        try std.testing.expectEqual(@as(u32, 4096), info.block_size);
    }
}

test "ext4 can be formatted for fscrypt" {
    var pb: [600]u8 = undefined;
    const path = try testImage("ext4-enc", 64 << 20, &pb);
    var d = try Dev.open(path, true);
    defer d.close();
    try ext4.mkfsWith(d, "home", .{ .encrypt = true });
    var sb: [4]u8 = undefined;
    _ = try sys.pread(d.fd, &sb, 1024 + 0x60);
    try std.testing.expect(std.mem.readInt(u32, &sb, .little) & 0x10000 != 0);
    try std.testing.expectEqualStrings("home", sys.cstr(&(try probe(d)).label));
}

test "ext4 size is read from the superblock" {
    var pb: [600]u8 = undefined;
    const path = try testImage("ext4-size", 96 << 20, &pb);
    var d = try Dev.open(path, true);
    defer d.close();
    d.size = 48 << 20;
    try ext4.mkfs(d, "grow");
    const s = try ext4.measure(d);
    try std.testing.expectEqual(@as(u64, 48 << 20), s.bytes());
    try std.testing.expectError(error.Unsupported, ext4.grow(path, 32 << 20));
    try std.testing.expectError(error.TooBig, ext4.grow(path, 200 << 20));
}

test "exfat formats, probes and relabels" {
    var pb: [600]u8 = undefined;
    const path = try testImage("exfat", 48 << 20, &pb);
    var d = try Dev.open(path, true);
    defer d.close();
    try mkfsExfat(d, "Musique");
    const info = try probe(d);
    try std.testing.expectEqualStrings("exfat", sys.cstr(&info.type));
    try std.testing.expectEqualStrings("Musique", sys.cstr(&info.label));
    try setLabel(d, "Données");
    try std.testing.expectEqualStrings("Données", sys.cstr(&(try probe(d)).label));
}

test "the up-case table maps letters and compresses identity runs" {
    var buf: [0x10000 + 64]u16 = undefined;
    const n = upcaseTable(&buf);
    try std.testing.expect(n < 8192);
    try std.testing.expectEqual(@as(u16, 0xffff), buf[0]);
    try std.testing.expectEqual(@as(u16, 0x61), buf[1]);
    try std.testing.expectEqual(@as(u16, 'A'), buf[2]);
}

fn testImage(name: []const u8, size: u64, out: []u8) ![*:0]const u8 {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, name);
    const p = try sys.pathZ(out, "{s}/fs.img", .{root});
    const fd = try sys.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    defer sys.close(fd);
    _ = try sys.check(linux.ftruncate(fd, @intCast(size)));
    return p;
}

fn expectFat(size: u64, bits: u8, label: []const u8) !void {
    var pb: [600]u8 = undefined;
    var nb: [32]u8 = undefined;
    const path = try testImage(try std.fmt.bufPrint(&nb, "fat{d}-{d}", .{ bits, size >> 20 }), size, &pb);
    var d = try Dev.open(path, true);
    defer d.close();
    try mkfsVfat(d, .{ .label = label });
    const info = try probe(d);
    try std.testing.expectEqualStrings("vfat", sys.cstr(&info.type));
    var vb: [8]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&vb, "FAT{d}", .{bits}), sys.cstr(&info.version));
    try std.testing.expectEqualStrings(label, sys.cstr(&info.label));
    try std.testing.expectEqual(@as(usize, 9), sys.cstr(&info.uuid).len);
    try setLabel(d, "OTHER");
    try std.testing.expectEqualStrings("OTHER", sys.cstr(&(try probe(d)).label));
    try setLabel(d, "");
    try std.testing.expectEqualStrings("", sys.cstr(&(try probe(d)).label));
    try setLabel(d, label);
}

test "vfat of every width formats, probes and relabels" {
    try expectFat(4 << 20, 12, "SMALL");
    try expectFat(64 << 20, 16, "MEDIUM");
    try expectFat(600 << 20, 32, "LARGE");
}

test "swap formats, probes and relabels" {
    var pb: [600]u8 = undefined;
    const path = try testImage("swap", 16 << 20, &pb);
    var d = try Dev.open(path, true);
    defer d.close();
    try mkswap(d, "swappy");
    const info = try probe(d);
    try std.testing.expectEqualStrings("swap", sys.cstr(&info.type));
    try std.testing.expectEqualStrings("swappy", sys.cstr(&info.label));
    try setLabel(d, "other");
    try std.testing.expectEqualStrings("other", sys.cstr(&(try probe(d)).label));
    try std.testing.expectError(error.TooBig, setLabel(d, "a label that is far too long"));
}

test "an empty image is not a filesystem" {
    var pb: [600]u8 = undefined;
    const path = try testImage("nofs", 1 << 20, &pb);
    var d = try Dev.open(path, false);
    defer d.close();
    try std.testing.expectError(error.NotFound, probe(d));
}

test "superblock checksums match the kernel algorithm" {
    try std.testing.expectEqual(@as(u32, 0xe3069283), crc32c.hash("123456789"));
}

test "filesystems made by the standard tools probe and relabel" {
    const dir = std.c.getenv("SINTY_FS_FIXTURES") orelse return error.SkipZigTest;
    const Case = struct { file: []const u8, kind: []const u8, label: []const u8, relabel: []const u8 };
    const cases = [_]Case{
        .{ .file = "ext4.img", .kind = "ext4", .label = "extlabel", .relabel = "renamed" },
        .{ .file = "ext2.img", .kind = "ext2", .label = "old", .relabel = "renamed" },
        .{ .file = "vfat.img", .kind = "vfat", .label = "FATLABEL", .relabel = "RENAMED" },
        .{ .file = "exfat.img", .kind = "exfat", .label = "exLabel", .relabel = "Données" },
        .{ .file = "swap.img", .kind = "swap", .label = "swaplabel", .relabel = "renamed" },
        .{ .file = "f2fs.img", .kind = "f2fs", .label = "f2label", .relabel = "" },
    };
    var pb: [600]u8 = undefined;
    for (cases) |c| {
        var d = try Dev.open(try sys.pathZ(&pb, "{s}/{s}", .{ std.mem.span(dir), c.file }), true);
        defer d.close();
        const info = try probe(d);
        try std.testing.expectEqualStrings(c.kind, sys.cstr(&info.type));
        try std.testing.expectEqualStrings(c.label, sys.cstr(&info.label));
        if (c.relabel.len == 0) continue;
        try setLabel(d, c.relabel);
        try std.testing.expectEqualStrings(c.relabel, sys.cstr(&(try probe(d)).label));
        try setLabel(d, c.label);
        try std.testing.expectEqualStrings(c.label, sys.cstr(&(try probe(d)).label));
    }
}
