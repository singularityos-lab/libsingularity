const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const Kind = enum(u32) { none = 0, gpt = 1, dos = 2 };

pub const Partition = extern struct {
    number: u32,
    bootable: u32,
    start: u64,
    size: u64,
    attrs: u64,
    type: [40]u8,
    uuid: [40]u8,
    name: [80]u8,
};

pub const TableInfo = extern struct {
    kind: u32,
    sector_size: u32,
    size: u64,
    first_usable: u64,
    last_usable: u64,
    guid: [40]u8,
};

pub const PartitionList = sys.List(Partition);

const blk_getsize64: u32 = 0x80081272;
const blk_sszget: u32 = 0x1268;
const blk_rrpart: u32 = 0x125f;
const blk_pg: u32 = 0x1269;
const blk_flsbuf: u32 = 0x1261;

const gpt_sig = "EFI PART";
const entry_size = 128;
const default_entries = 128;
const header_size = 92;
const mib: u64 = 1 << 20;

pub const Disk = struct {
    fd: i32,
    sector: u32,
    size: u64,

    pub fn open(path: [*:0]const u8, writable: bool) !Disk {
        const fd = try sys.open(path, .{ .ACCMODE = if (writable) .RDWR else .RDONLY, .CLOEXEC = true }, 0);
        errdefer sys.close(fd);
        var size: u64 = 0;
        var sector: c_int = 512;
        if (sys.ioctl(fd, blk_getsize64, @intFromPtr(&size))) |_| {
            _ = sys.ioctl(fd, blk_sszget, @intFromPtr(&sector)) catch {};
        } else |_| {
            const end = linux.lseek(fd, 0, linux.SEEK.END);
            size = try sys.check(end);
        }
        if (sector < 512 or sector > 4096) return error.Invalid;
        if (size < 64 * 512) return error.Invalid;
        return .{ .fd = fd, .sector = @intCast(sector), .size = size };
    }

    pub fn close(self: *Disk) void {
        sys.close(self.fd);
    }

    pub fn sectors(self: Disk) u64 {
        return self.size / self.sector;
    }

    fn readAt(self: Disk, lba: u64, buf: []u8) !void {
        var n: usize = 0;
        while (n < buf.len) {
            const got = try sys.pread(self.fd, buf[n..], lba * self.sector + n);
            if (got == 0) return error.Io;
            n += got;
        }
    }

    fn writeAt(self: Disk, lba: u64, buf: []const u8) !void {
        try sys.pwriteAll(self.fd, buf, lba * self.sector);
    }

    fn sync(self: Disk) !void {
        _ = try sys.check(linux.fsync(self.fd));
    }
};

const Entry = extern struct {
    type: [16]u8,
    uuid: [16]u8,
    first: u64 align(1),
    last: u64 align(1),
    attrs: u64 align(1),
    name: [72]u8,
};

const MbrEntry = extern struct {
    status: u8,
    chs_first: [3]u8,
    type: u8,
    chs_last: [3]u8,
    lba: u32 align(1),
    count: u32 align(1),
};

pub const Table = struct {
    kind: Kind = .none,
    disk_guid: [16]u8 = std.mem.zeroes([16]u8),
    entries_lba: u64 = 2,
    first_usable: u64 = 0,
    last_usable: u64 = 0,
    entries: []Entry = &.{},
    mbr: [4]MbrEntry = std.mem.zeroes([4]MbrEntry),
    mbr_id: u32 = 0,
    logical: [64]MbrEntry = std.mem.zeroes([64]MbrEntry),
    logical_start: [64]u64 = std.mem.zeroes([64]u64),
    n_logical: usize = 0,

    pub fn deinit(self: *Table) void {
        if (self.entries.len > 0) sys.gpa.free(self.entries);
        self.entries = &.{};
    }
};

fn isZero(b: []const u8) bool {
    for (b) |c| if (c != 0) return false;
    return true;
}

pub fn guidString(g: [16]u8, out: []u8) []const u8 {
    const s = std.fmt.bufPrint(out, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        std.mem.readInt(u32, g[0..4], .little), std.mem.readInt(u16, g[4..6], .little), std.mem.readInt(u16, g[6..8], .little),
        g[8],                                   g[9],                                   g[10],
        g[11],                                  g[12],                                  g[13],
        g[14],                                  g[15],
    }) catch return "";
    if (s.len < out.len) out[s.len] = 0;
    return s;
}

pub fn parseGuid(s: []const u8) ?[16]u8 {
    if (s.len != 36 or s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return null;
    var hex: [32]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        hex[n] = c;
        n += 1;
    }
    var raw: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, &hex) catch return null;
    var g: [16]u8 = undefined;
    g[0] = raw[3];
    g[1] = raw[2];
    g[2] = raw[1];
    g[3] = raw[0];
    g[4] = raw[5];
    g[5] = raw[4];
    g[6] = raw[7];
    g[7] = raw[6];
    @memcpy(g[8..16], raw[8..16]);
    return g;
}

fn randomGuid() [16]u8 {
    var g: [16]u8 = undefined;
    var n: usize = 0;
    while (n < g.len) {
        const rc = linux.getrandom(g[n..].ptr, g.len - n, 0);
        if (linux.errno(rc) == .SUCCESS) n += rc;
    }
    g[7] = (g[7] & 0x0f) | 0x40;
    g[8] = (g[8] & 0x3f) | 0x80;
    return g;
}

fn crc(b: []const u8) u32 {
    return std.hash.Crc32.hash(b);
}

fn readGpt(d: Disk, lba: u64, t: *Table) !bool {
    const buf = try sys.gpa.alloc(u8, d.sector);
    defer sys.gpa.free(buf);
    try d.readAt(lba, buf);
    if (!std.mem.eql(u8, buf[0..8], gpt_sig)) return false;
    const hsize = std.mem.readInt(u32, buf[12..16], .little);
    if (hsize < header_size or hsize > d.sector) return false;
    const want = std.mem.readInt(u32, buf[16..20], .little);
    @memset(buf[16..20], 0);
    if (crc(buf[0..hsize]) != want) return false;
    if (std.mem.readInt(u64, buf[24..32], .little) != lba) return false;
    const n = std.mem.readInt(u32, buf[80..84], .little);
    const esize = std.mem.readInt(u32, buf[84..88], .little);
    if (esize != entry_size or n == 0 or n > 4096) return false;
    const elba = std.mem.readInt(u64, buf[72..80], .little);
    const raw_len = std.mem.alignForward(usize, n * entry_size, d.sector);
    const raw = try sys.gpa.alloc(u8, raw_len);
    defer sys.gpa.free(raw);
    d.readAt(elba, raw) catch return false;
    if (crc(raw[0 .. n * entry_size]) != std.mem.readInt(u32, buf[88..92], .little)) return false;
    const entries = try sys.gpa.alloc(Entry, n);
    @memcpy(std.mem.sliceAsBytes(entries), raw[0 .. n * entry_size]);
    t.kind = .gpt;
    @memcpy(&t.disk_guid, buf[56..72]);
    t.first_usable = std.mem.readInt(u64, buf[40..48], .little);
    t.last_usable = std.mem.readInt(u64, buf[48..56], .little);
    t.entries_lba = if (lba == 1) elba else 2;
    t.entries = entries;
    return true;
}

fn extended(kind: u8) bool {
    return kind == 0x05 or kind == 0x0f or kind == 0x85;
}

pub fn read(d: Disk) !Table {
    var t = Table{};
    var mbr: [512]u8 = undefined;
    try d.readAt(0, &mbr);
    const signed = mbr[510] == 0x55 and mbr[511] == 0xaa;
    if (try readGpt(d, 1, &t)) return t;
    if (try readGpt(d, d.sectors() - 1, &t)) return t;
    if (!signed) return t;
    const parts = std.mem.bytesAsSlice(MbrEntry, mbr[446..510]);
    var protective = false;
    for (parts) |p| if (p.type == 0xee) {
        protective = true;
    };
    if (protective) return t;
    for (parts, 0..) |p, i| t.mbr[i] = p;
    t.kind = .dos;
    t.mbr_id = std.mem.readInt(u32, mbr[440..444], .little);
    t.first_usable = 1;
    t.last_usable = d.sectors() - 1;
    for (t.mbr) |p| {
        if (!extended(p.type) or p.lba == 0) continue;
        const base: u64 = p.lba;
        var next: u64 = base;
        var guard: usize = 0;
        while (guard < 64 and t.n_logical < t.logical.len) : (guard += 1) {
            var ebr: [512]u8 = undefined;
            d.readAt(next, &ebr) catch break;
            if (ebr[510] != 0x55 or ebr[511] != 0xaa) break;
            const e = std.mem.bytesAsSlice(MbrEntry, ebr[446..478]);
            if (e[0].count > 0) {
                t.logical[t.n_logical] = e[0];
                t.logical_start[t.n_logical] = next + e[0].lba;
                t.n_logical += 1;
            }
            if (e[1].lba == 0 or !extended(e[1].type)) break;
            next = base + e[1].lba;
        }
        break;
    }
    return t;
}

fn utf16Name(raw: [72]u8, out: []u8) void {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 2) {
        const cu = std.mem.readInt(u16, raw[i..][0..2], .little);
        if (cu == 0) break;
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cu, &tmp) catch 1;
        if (n + len + 1 > out.len) break;
        @memcpy(out[n .. n + len], tmp[0..len]);
        n += len;
    }
    out[n] = 0;
}

fn encodeName(name: []const u8) ![72]u8 {
    var out = std.mem.zeroes([72]u8);
    var it = (std.unicode.Utf8View.init(name) catch return error.Invalid).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp > 0xffff or i + 2 > out.len) return error.Invalid;
        std.mem.writeInt(u16, out[i..][0..2], @intCast(cp), .little);
        i += 2;
    }
    return out;
}

pub fn info(d: Disk, t: Table) TableInfo {
    var out = std.mem.zeroes(TableInfo);
    out.kind = @intFromEnum(t.kind);
    out.sector_size = d.sector;
    out.size = d.size;
    out.first_usable = t.first_usable * d.sector;
    out.last_usable = (t.last_usable + 1) * d.sector;
    if (t.kind == .gpt) _ = guidString(t.disk_guid, &out.guid) else if (t.kind == .dos) {
        _ = std.fmt.bufPrint(&out.guid, "{x:0>8}\x00", .{t.mbr_id}) catch {};
    }
    return out;
}

pub fn list(d: Disk, t: Table) !*PartitionList {
    const l = try PartitionList.create();
    errdefer l.destroy();
    switch (t.kind) {
        .none => {},
        .gpt => for (t.entries, 0..) |e, i| {
            if (isZero(&e.type)) continue;
            var p = std.mem.zeroes(Partition);
            p.number = @intCast(i + 1);
            p.start = e.first * d.sector;
            p.size = (e.last - e.first + 1) * d.sector;
            p.attrs = e.attrs;
            p.bootable = @intFromBool(e.attrs & 0x4 != 0);
            _ = guidString(e.type, &p.type);
            _ = guidString(e.uuid, &p.uuid);
            utf16Name(e.name, &p.name);
            try l.append(p);
        },
        .dos => {
            for (t.mbr, 0..) |e, i| {
                if (e.type == 0 or e.count == 0) continue;
                try l.append(dosPartition(d, t, e, @intCast(i + 1), e.lba));
            }
            for (t.logical[0..t.n_logical], 0..) |e, i| {
                try l.append(dosPartition(d, t, e, @intCast(i + 5), t.logical_start[i]));
            }
        },
    }
    return l;
}

fn dosPartition(d: Disk, t: Table, e: MbrEntry, number: u32, lba: u64) Partition {
    var p = std.mem.zeroes(Partition);
    p.number = number;
    p.start = lba * d.sector;
    p.size = @as(u64, e.count) * d.sector;
    p.bootable = @intFromBool(e.status == 0x80);
    p.attrs = if (e.status == 0x80) 0x80 else 0;
    _ = std.fmt.bufPrint(&p.type, "0x{x:0>2}\x00", .{e.type}) catch {};
    _ = std.fmt.bufPrint(&p.uuid, "{x:0>8}-{x:0>2}\x00", .{ t.mbr_id, number }) catch {};
    return p;
}

fn writeGptCopy(d: Disk, t: Table, raw: []const u8, entries_crc: u32, primary: bool) !void {
    const last = d.sectors() - 1;
    const entry_sectors = raw.len / d.sector;
    const hdr = try sys.gpa.alloc(u8, d.sector);
    defer sys.gpa.free(hdr);
    @memset(hdr, 0);
    @memcpy(hdr[0..8], gpt_sig);
    std.mem.writeInt(u32, hdr[8..12], 0x00010000, .little);
    std.mem.writeInt(u32, hdr[12..16], header_size, .little);
    const my: u64 = if (primary) 1 else last;
    const elba: u64 = if (primary) t.entries_lba else last - entry_sectors;
    std.mem.writeInt(u64, hdr[24..32], my, .little);
    std.mem.writeInt(u64, hdr[32..40], if (primary) last else 1, .little);
    std.mem.writeInt(u64, hdr[40..48], t.first_usable, .little);
    std.mem.writeInt(u64, hdr[48..56], t.last_usable, .little);
    @memcpy(hdr[56..72], &t.disk_guid);
    std.mem.writeInt(u64, hdr[72..80], elba, .little);
    std.mem.writeInt(u32, hdr[80..84], @intCast(t.entries.len), .little);
    std.mem.writeInt(u32, hdr[84..88], entry_size, .little);
    std.mem.writeInt(u32, hdr[88..92], entries_crc, .little);
    std.mem.writeInt(u32, hdr[16..20], crc(hdr[0..header_size]), .little);
    try d.writeAt(elba, raw);
    try d.writeAt(my, hdr);
}

fn protectiveMbr(d: Disk) [512]u8 {
    var mbr = std.mem.zeroes([512]u8);
    const e = std.mem.bytesAsSlice(MbrEntry, mbr[446..462]);
    e[0].type = 0xee;
    e[0].chs_first = .{ 0x00, 0x02, 0x00 };
    e[0].chs_last = .{ 0xff, 0xff, 0xff };
    e[0].lba = 1;
    const total = d.sectors() - 1;
    e[0].count = if (total > 0xffffffff) 0xffffffff else @intCast(total);
    mbr[510] = 0x55;
    mbr[511] = 0xaa;
    return mbr;
}

pub fn write(d: Disk, t: *Table) !void {
    switch (t.kind) {
        .none => return error.Invalid,
        .gpt => {
            const entry_sectors = std.mem.alignForward(usize, t.entries.len * entry_size, d.sector) / d.sector;
            const last = d.sectors() - 1;
            t.last_usable = @min(t.last_usable, last - entry_sectors - 1);
            const raw = try sys.gpa.alloc(u8, entry_sectors * d.sector);
            defer sys.gpa.free(raw);
            @memset(raw, 0);
            @memcpy(raw[0 .. t.entries.len * entry_size], std.mem.sliceAsBytes(t.entries));
            const ecrc = crc(raw[0 .. t.entries.len * entry_size]);
            var mbr: [512]u8 = undefined;
            try d.readAt(0, &mbr);
            const keep_boot = mbr[0..440].*;
            mbr = protectiveMbr(d);
            @memcpy(mbr[0..440], &keep_boot);
            if (d.sector > 512) {
                const first = try sys.gpa.alloc(u8, d.sector);
                defer sys.gpa.free(first);
                @memset(first, 0);
                @memcpy(first[0..512], &mbr);
                try d.writeAt(0, first);
            } else try d.writeAt(0, &mbr);
            try writeGptCopy(d, t.*, raw, ecrc, false);
            try writeGptCopy(d, t.*, raw, ecrc, true);
        },
        .dos => {
            var mbr: [512]u8 = undefined;
            try d.readAt(0, &mbr);
            std.mem.writeInt(u32, mbr[440..444], t.mbr_id, .little);
            @memcpy(mbr[446..510], std.mem.sliceAsBytes(&t.mbr));
            mbr[510] = 0x55;
            mbr[511] = 0xaa;
            if (d.sector > 512) {
                const first = try sys.gpa.alloc(u8, d.sector);
                defer sys.gpa.free(first);
                try d.readAt(0, first);
                @memcpy(first[0..512], &mbr);
                try d.writeAt(0, first);
            } else try d.writeAt(0, &mbr);
        },
    }
    try d.sync();
}

pub fn create(d: Disk, kind: Kind) !Table {
    var t = Table{ .kind = kind };
    switch (kind) {
        .none => return error.Invalid,
        .gpt => {
            t.disk_guid = randomGuid();
            t.entries = try sys.gpa.alloc(Entry, default_entries);
            @memset(std.mem.sliceAsBytes(t.entries), 0);
            const entry_sectors = default_entries * entry_size / d.sector;
            t.entries_lba = 2;
            t.first_usable = 2 + entry_sectors;
            t.last_usable = d.sectors() - 2 - entry_sectors;
        },
        .dos => {
            var id: [4]u8 = undefined;
            _ = linux.getrandom(&id, 4, 0);
            t.mbr_id = std.mem.readInt(u32, &id, .little);
            t.first_usable = 1;
            t.last_usable = d.sectors() - 1;
        },
    }
    const wipe_len: usize = @intCast(@min(mib, d.size));
    const zero = try sys.gpa.alloc(u8, wipe_len);
    defer sys.gpa.free(zero);
    @memset(zero, 0);
    try sys.pwriteAll(d.fd, zero, 0);
    try sys.pwriteAll(d.fd, zero, d.size - wipe_len);
    try write(d, &t);
    return t;
}

const Span = struct { first: u64, last: u64, number: u32 };

fn spans(t: Table, buf: []Span) []Span {
    var n: usize = 0;
    switch (t.kind) {
        .gpt => for (t.entries, 0..) |e, i| {
            if (isZero(&e.type) or n == buf.len) continue;
            buf[n] = .{ .first = e.first, .last = e.last, .number = @intCast(i + 1) };
            n += 1;
        },
        .dos => {
            for (t.mbr, 0..) |e, i| {
                if (e.type == 0 or e.count == 0 or n == buf.len) continue;
                buf[n] = .{ .first = e.lba, .last = @as(u64, e.lba) + e.count - 1, .number = @intCast(i + 1) };
                n += 1;
            }
        },
        .none => {},
    }
    return buf[0..n];
}

fn overlaps(t: Table, first: u64, last: u64, skip: u32) bool {
    var buf: [256]Span = undefined;
    for (spans(t, &buf)) |s| {
        if (s.number == skip) continue;
        if (first <= s.last and s.first <= last) return true;
    }
    return false;
}

fn nextStart(t: Table, after: u64, skip: u32) u64 {
    var buf: [256]Span = undefined;
    var best: u64 = t.last_usable + 1;
    for (spans(t, &buf)) |s| {
        if (s.number == skip) continue;
        if (s.first > after and s.first < best) best = s.first;
    }
    return best;
}

fn freeStart(t: Table, from: u64, need: u64, align_sectors: u64) ?u64 {
    var buf: [256]Span = undefined;
    const all = spans(t, &buf);
    var candidate = from;
    while (candidate <= t.last_usable) {
        const end = if (need == 0) candidate else candidate + need - 1;
        var moved = false;
        for (all) |s| {
            if (candidate <= s.last and s.first <= end) {
                candidate = std.mem.alignForward(u64, s.last + 1, align_sectors);
                moved = true;
            }
        }
        if (!moved) return if (end <= t.last_usable) candidate else null;
    }
    return null;
}

fn dosType(s: []const u8) ?u8 {
    const hex = if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
    if (hex.len == 0 or hex.len > 2) return null;
    return std.fmt.parseInt(u8, hex, 16) catch null;
}

pub const linux_data = "0fc63daf-8483-4772-8e79-3d69d8477de4";

pub fn add(d: Disk, t: *Table, start_bytes: u64, size_bytes: u64, type_s: []const u8, name: []const u8) !u32 {
    if (t.kind == .dos and name.len > 0) return error.Unsupported;
    const align_sectors = mib / d.sector;
    var first = std.mem.alignForward(u64, (start_bytes + d.sector - 1) / d.sector, align_sectors);
    if (first < t.first_usable) first = std.mem.alignForward(u64, t.first_usable, align_sectors);
    if (start_bytes == 0) first = freeStart(t.*, first, size_bytes / d.sector, align_sectors) orelse return error.TooBig;
    const limit = nextStart(t.*, first, 0) - 1;
    var last: u64 = if (size_bytes == 0) limit else first + (size_bytes / d.sector) - 1;
    if (size_bytes == 0 and last > t.last_usable) last = t.last_usable;
    if (last < first or last > t.last_usable or overlaps(t.*, first, last, 0)) return error.Invalid;
    switch (t.kind) {
        .gpt => {
            const ty = parseGuid(if (type_s.len == 0) linux_data else type_s) orelse return error.Invalid;
            if (isZero(&ty)) return error.Invalid;
            const enc = try encodeName(name);
            for (t.entries, 0..) |*e, i| {
                if (!isZero(&e.type)) continue;
                e.* = .{ .type = ty, .uuid = randomGuid(), .first = first, .last = last, .attrs = 0, .name = enc };
                try write(d, t);
                return @intCast(i + 1);
            }
            return error.Busy;
        },
        .dos => {
            const ty = dosType(if (type_s.len == 0) "0x83" else type_s) orelse return error.Invalid;
            if (ty == 0 or extended(ty)) return error.Invalid;
            if (first > 0xffffffff or last - first + 1 > 0xffffffff) return error.TooBig;
            for (&t.mbr, 0..) |*e, i| {
                if (e.type != 0) continue;
                e.* = .{ .status = 0, .chs_first = .{ 0xfe, 0xff, 0xff }, .type = ty, .chs_last = .{ 0xfe, 0xff, 0xff }, .lba = @intCast(first), .count = @intCast(last - first + 1) };
                try write(d, t);
                return @intCast(i + 1);
            }
            return error.Busy;
        },
        .none => return error.Invalid,
    }
}

fn gptEntry(t: *Table, number: u32) !*Entry {
    if (t.kind != .gpt or number == 0 or number > t.entries.len) return error.NotFound;
    const e = &t.entries[number - 1];
    if (isZero(&e.type)) return error.NotFound;
    return e;
}

fn dosEntry(t: *Table, number: u32) !*MbrEntry {
    if (t.kind != .dos or number == 0) return error.NotFound;
    if (number > 4) return error.Unsupported;
    const e = &t.mbr[number - 1];
    if (e.type == 0) return error.NotFound;
    return e;
}

pub fn remove(d: Disk, t: *Table, number: u32) !void {
    switch (t.kind) {
        .gpt => (try gptEntry(t, number)).* = std.mem.zeroes(Entry),
        .dos => {
            const e = try dosEntry(t, number);
            if (extended(e.type) and t.n_logical > 0) return error.Busy;
            e.* = std.mem.zeroes(MbrEntry);
        },
        .none => return error.NotFound,
    }
    try write(d, t);
}

pub fn setType(d: Disk, t: *Table, number: u32, type_s: []const u8) !void {
    switch (t.kind) {
        .gpt => {
            const ty = parseGuid(type_s) orelse return error.Invalid;
            if (isZero(&ty)) return error.Invalid;
            (try gptEntry(t, number)).type = ty;
        },
        .dos => {
            const ty = dosType(type_s) orelse return error.Invalid;
            if (ty == 0) return error.Invalid;
            (try dosEntry(t, number)).type = ty;
        },
        .none => return error.NotFound,
    }
    try write(d, t);
}

pub fn setName(d: Disk, t: *Table, number: u32, name: []const u8) !void {
    if (t.kind != .gpt) return error.Unsupported;
    (try gptEntry(t, number)).name = try encodeName(name);
    try write(d, t);
}

pub fn setAttrs(d: Disk, t: *Table, number: u32, attrs: u64) !void {
    switch (t.kind) {
        .gpt => (try gptEntry(t, number)).attrs = attrs,
        .dos => {
            const target = try dosEntry(t, number);
            for (&t.mbr) |*e| if (e.type != 0) {
                e.status = 0;
            };
            if (attrs & 0x80 != 0) target.status = 0x80;
        },
        .none => return error.NotFound,
    }
    try write(d, t);
}

pub fn resize(d: Disk, t: *Table, number: u32, size_bytes: u64) !void {
    switch (t.kind) {
        .gpt => {
            const e = try gptEntry(t, number);
            const limit = nextStart(t.*, e.first, @intCast(number)) - 1;
            const last = if (size_bytes == 0) limit else e.first + size_bytes / d.sector - 1;
            if (last < e.first or last > limit) return error.Invalid;
            e.last = last;
        },
        .dos => {
            const e = try dosEntry(t, number);
            const limit = nextStart(t.*, e.lba, @intCast(number)) - 1;
            const last = if (size_bytes == 0) limit else @as(u64, e.lba) + size_bytes / d.sector - 1;
            if (last < e.lba or last > limit or last - e.lba + 1 > 0xffffffff) return error.Invalid;
            e.count = @intCast(last - e.lba + 1);
        },
        .none => return error.NotFound,
    }
    try write(d, t);
}

const BlkpgPartition = extern struct {
    start: c_longlong,
    length: c_longlong,
    pno: c_int,
    devname: [64]u8,
    volname: [64]u8,
};

const BlkpgArg = extern struct {
    op: c_int,
    flags: c_int,
    datalen: c_int,
    data: ?*anyopaque,
};

fn blkpg(fd: i32, op: c_int, number: u32, start: u64, length: u64) !void {
    var p = std.mem.zeroes(BlkpgPartition);
    p.start = @intCast(start);
    p.length = @intCast(length);
    p.pno = @intCast(number);
    var a = BlkpgArg{ .op = op, .flags = 0, .datalen = @sizeOf(BlkpgPartition), .data = &p };
    _ = try sys.ioctl(fd, blk_pg, @intFromPtr(&a));
}

pub const KernelPart = struct { number: u32, start: u64, size: u64 };

pub fn kernelParts(sysfs: []const u8, disk: []const u8, out: []KernelPart) ![]KernelPart {
    var buf: [512]u8 = undefined;
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}/class/block/{s}", .{ sysfs, disk })) catch return out[0..0];
    defer d.close();
    var n: usize = 0;
    while (try d.next()) |e| {
        if (!std.mem.startsWith(u8, e.name, disk) or n == out.len) continue;
        var pb: [600]u8 = undefined;
        const num = sys.readInt(u32, try sys.pathZ(&pb, "{s}/class/block/{s}/{s}/partition", .{ sysfs, disk, e.name })) orelse continue;
        const start = sys.readInt(u64, try sys.pathZ(&pb, "{s}/class/block/{s}/{s}/start", .{ sysfs, disk, e.name })) orelse continue;
        const size = sys.readInt(u64, try sys.pathZ(&pb, "{s}/class/block/{s}/{s}/size", .{ sysfs, disk, e.name })) orelse continue;
        out[n] = .{ .number = num, .start = start * 512, .size = size * 512 };
        n += 1;
    }
    return out[0..n];
}

pub fn syncKernel(d: Disk, sysfs: []const u8, disk: []const u8) !void {
    _ = sys.ioctl(d.fd, blk_flsbuf, 0) catch {};
    if (sys.ioctl(d.fd, blk_rrpart, 0)) |_| return else |e| if (e != error.Busy) return e;
    var t = try read(d);
    defer t.deinit();
    const want = try list(d, t);
    defer want.destroy();
    var kb: [256]KernelPart = undefined;
    const have = try kernelParts(sysfs, disk, &kb);
    var failed = false;
    for (have) |k| {
        var keep = false;
        for (want.items.items) |p| if (p.number == k.number and p.start == k.start) {
            keep = true;
        };
        if (!keep) blkpg(d.fd, 2, k.number, 0, 0) catch {
            failed = true;
        };
    }
    for (want.items.items) |p| {
        var found: ?KernelPart = null;
        for (have) |k| if (k.number == p.number and k.start == p.start) {
            found = k;
        };
        if (found) |k| {
            if (k.size != p.size) blkpg(d.fd, 3, p.number, p.start, p.size) catch {
                failed = true;
            };
        } else blkpg(d.fd, 1, p.number, p.start, p.size) catch {
            failed = true;
        };
    }
    if (failed) return error.Busy;
}

pub fn uevent(sysfs: []const u8, name: []const u8, action: []const u8) !void {
    if (!std.mem.eql(u8, action, "change") and !std.mem.eql(u8, action, "add")) return error.Invalid;
    var buf: [512]u8 = undefined;
    try sys.writeFile(try sys.pathZ(&buf, "{s}/class/block/{s}/uevent", .{ sysfs, name }), action);
}

pub fn settle(sysfs: []const u8, dev: []const u8, disk: []const u8, timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (waited <= timeout_ms) : (waited += 50) {
        var ready = !sys.exists("/run/udev/queue");
        var nb: [512]u8 = undefined;
        var db: [512]u8 = undefined;
        var d = sys.Dir.open(sys.pathZ(&db, "{s}/class/block/{s}", .{ sysfs, disk }) catch return false) catch return ready;
        defer d.close();
        while (d.next() catch null) |e| {
            if (!std.mem.startsWith(u8, e.name, disk)) continue;
            const node = sys.pathZ(&nb, "{s}/{s}", .{ dev, e.name }) catch continue;
            if (!sys.exists(node)) ready = false;
        }
        if (ready) return true;
        sys.sleepMs(50);
    }
    return false;
}

pub fn wipe(path: [*:0]const u8) !void {
    var d = try Disk.open(path, true);
    defer d.close();
    const len: usize = @intCast(@min(mib, d.size));
    const zero = try sys.gpa.alloc(u8, len);
    defer sys.gpa.free(zero);
    @memset(zero, 0);
    try sys.pwriteAll(d.fd, zero, 0);
    try sys.pwriteAll(d.fd, zero, d.size - len);
    try d.sync();
}

pub fn swap(path: [*:0]const u8, on: bool) !void {
    const rc = if (on) linux.syscall2(.swapon, @intFromPtr(path), 0) else linux.syscall1(.swapoff, @intFromPtr(path));
    _ = try sys.check(rc);
}

const SgIo = extern struct {
    interface_id: c_int,
    dxfer_direction: c_int,
    cmd_len: u8,
    mx_sb_len: u8,
    iovec_count: c_ushort,
    dxfer_len: c_uint,
    dxferp: ?*anyopaque,
    cmdp: [*]const u8,
    sbp: [*]u8,
    timeout: c_uint,
    flags: c_uint,
    pack_id: c_int,
    usr_ptr: ?*anyopaque,
    status: u8,
    masked_status: u8,
    msg_status: u8,
    sb_len_wr: u8,
    host_status: c_ushort,
    driver_status: c_ushort,
    resid: c_int,
    duration: c_uint,
    info: c_uint,
};

fn scsi(fd: i32, cdb: []const u8) !void {
    var sense: [32]u8 = undefined;
    var io = std.mem.zeroes(SgIo);
    io.interface_id = 'S';
    io.dxfer_direction = -1;
    io.cmd_len = @intCast(cdb.len);
    io.mx_sb_len = sense.len;
    io.cmdp = cdb.ptr;
    io.sbp = &sense;
    io.timeout = 10000;
    _ = try sys.ioctl(fd, 0x2285, @intFromPtr(&io));
    if (io.status != 0 or io.host_status != 0 or (io.driver_status & 0xf) != 0) return error.Io;
}

pub fn eject(path: [*:0]const u8) !void {
    const fd = try sys.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    defer sys.close(fd);
    _ = linux.fsync(fd);
    _ = sys.ioctl(fd, blk_flsbuf, 0) catch {};
    if (sys.ioctl(fd, 0x5309, 0)) |_| return else |_| {}
    try scsi(fd, &.{ 0x1e, 0, 0, 0, 0, 0 });
    try scsi(fd, &.{ 0x1b, 0, 0, 0, 0x01, 0 });
    try scsi(fd, &.{ 0x1b, 0, 0, 0, 0x02, 0 });
}


pub const Opened = struct {
    disk: Disk,
    table: Table,

    pub fn open(path: [*:0]const u8, writable: bool) !Opened {
        var d = try Disk.open(path, writable);
        errdefer d.close();
        return .{ .disk = d, .table = try read(d) };
    }

    pub fn close(self: *Opened) void {
        self.table.deinit();
        self.disk.close();
    }
};

pub fn diskName(path: []const u8, buf: []u8) []const u8 {
    var tmp: [4096]u8 = undefined;
    if (path.len < tmp.len) {
        @memcpy(tmp[0..path.len], path);
        tmp[path.len] = 0;
        if (sys.readLink(@ptrCast(&tmp), buf)) |target| return sys.baseName(target) else |_| {}
    }
    return sys.baseName(path);
}

fn testImage(name: []const u8, size: u64, out: []u8) ![*:0]const u8 {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, name);
    const p = try sys.pathZ(out, "{s}/disk.img", .{root});
    const fd = try sys.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    defer sys.close(fd);
    _ = try sys.check(linux.ftruncate(fd, @intCast(size)));
    return p;
}

test "guid text round trip and layout" {
    const g = parseGuid("0FC63DAF-8483-4772-8E79-3D69D8477DE4").?;
    try std.testing.expectEqualSlices(u8, &.{ 0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47, 0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4 }, &g);
    var out: [40]u8 = undefined;
    try std.testing.expectEqualStrings(linux_data, guidString(g, &out));
    try std.testing.expect(parseGuid("nope") == null);
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Entry));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(MbrEntry));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(SgIo));
}

test "gpt table life cycle on an image" {
    var pb: [600]u8 = undefined;
    const path = try testImage("gpt", 64 * mib, &pb);
    var d = try Disk.open(path, true);
    defer d.close();
    var t = try create(d, .gpt);
    defer t.deinit();
    const a = try add(d, &t, 0, 16 * mib, "c12a7328-f81f-11d2-ba4b-00a0c93ec93b", "EFI system");
    const b = try add(d, &t, 0, 0, "", "Données");
    try std.testing.expectEqual(@as(u32, 1), a);
    try std.testing.expectEqual(@as(u32, 2), b);
    try std.testing.expectError(error.Invalid, add(d, &t, mib, mib, "", "overlap"));
    var again = try read(d);
    defer again.deinit();
    const l = try list(d, again);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 2), l.count());
    const p1 = l.items.items[0];
    const p2 = l.items.items[1];
    try std.testing.expectEqual(mib, p1.start);
    try std.testing.expectEqual(16 * mib, p1.size);
    try std.testing.expectEqualStrings("EFI system", sys.cstr(&p1.name));
    try std.testing.expectEqualStrings("Données", sys.cstr(&p2.name));
    try std.testing.expectEqual(17 * mib, p2.start);
    try std.testing.expectEqual((again.last_usable + 1) * 512 - 17 * mib, p2.size);
    try setAttrs(d, &again, 1, 0x4);
    try setName(d, &again, 2, "data");
    try setType(d, &again, 2, "933ac7e1-2eb4-4f13-b844-0e14e2aef915");
    try resize(d, &again, 1, 8 * mib);
    try remove(d, &again, 2);
    var last = try read(d);
    defer last.deinit();
    const l2 = try list(d, last);
    defer l2.destroy();
    try std.testing.expectEqual(@as(usize, 1), l2.count());
    try std.testing.expectEqual(@as(u64, 0x4), l2.items.items[0].attrs);
    try std.testing.expectEqual(8 * mib, l2.items.items[0].size);
    try std.testing.expectError(error.NotFound, remove(d, &last, 2));
}

test "a damaged primary gpt is read from the backup" {
    var pb: [600]u8 = undefined;
    const path = try testImage("gptbackup", 16 * mib, &pb);
    var d = try Disk.open(path, true);
    defer d.close();
    var t = try create(d, .gpt);
    defer t.deinit();
    _ = try add(d, &t, 0, 0, "", "only");
    var junk = [_]u8{0xff} ** 512;
    try d.writeAt(1, &junk);
    var r = try read(d);
    defer r.deinit();
    try std.testing.expectEqual(Kind.gpt, r.kind);
    const l = try list(d, r);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 1), l.count());
}

test "dos table life cycle on an image" {
    var pb: [600]u8 = undefined;
    const path = try testImage("dos", 32 * mib, &pb);
    var d = try Disk.open(path, true);
    defer d.close();
    var t = try create(d, .dos);
    defer t.deinit();
    _ = try add(d, &t, 0, 8 * mib, "0x0c", "");
    _ = try add(d, &t, 0, 0, "", "");
    try std.testing.expectError(error.Unsupported, add(d, &t, 0, 0, "", "named"));
    try setAttrs(d, &t, 2, 0x80);
    var r = try read(d);
    defer r.deinit();
    try std.testing.expectEqual(Kind.dos, r.kind);
    const l = try list(d, r);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 2), l.count());
    try std.testing.expectEqualStrings("0x0c", sys.cstr(&l.items.items[0].type));
    try std.testing.expectEqualStrings("0x83", sys.cstr(&l.items.items[1].type));
    try std.testing.expectEqual(@as(u32, 1), l.items.items[1].bootable);
    try std.testing.expectEqual(@as(u32, 0), l.items.items[0].bootable);
    try std.testing.expectEqual(32 * mib - 9 * mib, l.items.items[1].size);
}

test "an empty image has no table" {
    var pb: [600]u8 = undefined;
    const path = try testImage("none", 8 * mib, &pb);
    var d = try Disk.open(path, false);
    defer d.close();
    var t = try read(d);
    defer t.deinit();
    try std.testing.expectEqual(Kind.none, t.kind);
}

test "tables written by sfdisk read back the same" {
    const dir = std.c.getenv("SINTY_DISK_FIXTURES") orelse return error.SkipZigTest;
    var pb: [600]u8 = undefined;
    {
        var d = try Disk.open(try sys.pathZ(&pb, "{s}/g.img", .{std.mem.span(dir)}), false);
        defer d.close();
        var t = try read(d);
        defer t.deinit();
        const l = try list(d, t);
        defer l.destroy();
        try std.testing.expectEqual(@as(usize, 3), l.count());
        const p = l.items.items;
        try std.testing.expectEqual(@as(u64, 2048 * 512), p[0].start);
        try std.testing.expectEqualStrings("ESP", sys.cstr(&p[0].name));
        try std.testing.expectEqualStrings("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", sys.cstr(&p[0].type));
        try std.testing.expectEqual(@as(u64, 32768 * 512), p[1].size);
        try std.testing.expectEqual(@as(u64, 1), p[1].attrs);
        try std.testing.expectEqual(@as(u64, 77824 * 512), p[2].size);
    }
    {
        var d = try Disk.open(try sys.pathZ(&pb, "{s}/d.img", .{std.mem.span(dir)}), false);
        defer d.close();
        var t = try read(d);
        defer t.deinit();
        const l = try list(d, t);
        defer l.destroy();
        try std.testing.expectEqual(@as(usize, 5), l.count());
        const p = l.items.items;
        try std.testing.expectEqual(@as(u32, 1), p[0].bootable);
        try std.testing.expectEqualStrings("0x05", sys.cstr(&p[2].type));
        try std.testing.expectEqual(@as(u32, 5), p[3].number);
        try std.testing.expectEqual(@as(u64, 36864 * 512), p[3].start);
        try std.testing.expectEqual(@as(u64, 20480 * 512), p[3].size);
        try std.testing.expectEqual(@as(u32, 6), p[4].number);
        try std.testing.expectEqual(@as(u64, 59392 * 512), p[4].start);
        try std.testing.expectEqualStrings("0x82", sys.cstr(&p[4].type));
    }
}
