const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

extern fn fnmatch(pattern: [*:0]const u8, string: [*:0]const u8, flags: c_int) c_int;

pub const hwdb_paths = [_][*:0]const u8{ "/etc/udev/hwdb.bin", "/usr/lib/udev/hwdb.bin", "/lib/udev/hwdb.bin" };

const signature = "KSLPHHRH";

pub const Hwdb = struct {
    data: []align(std.heap.page_size_min) const u8,
    node_size: u64,
    child_size: u64,
    value_size: u64,
    root: u64,

    pub fn open(path: [*:0]const u8) !Hwdb {
        const fd = try sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        defer sys.close(fd);
        const size: usize = try sys.check(linux.lseek(fd, 0, linux.SEEK.END));
        if (size < 80) return error.Invalid;
        const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        const addr = try sys.check(rc);
        const data: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(addr);
        var self = Hwdb{ .data = data[0..size], .node_size = 0, .child_size = 0, .value_size = 0, .root = 0 };
        errdefer self.close();
        if (!std.mem.eql(u8, self.data[0..8], signature)) return error.Invalid;
        if (self.u64At(16) != size) return error.Invalid;
        self.node_size = self.u64At(32);
        self.child_size = self.u64At(40);
        self.value_size = self.u64At(48);
        self.root = self.u64At(56);
        if (self.node_size < 24 or self.child_size < 16 or self.value_size < 16 or self.root >= size) return error.Invalid;
        return self;
    }

    pub fn openDefault() !Hwdb {
        for (hwdb_paths) |p| {
            if (Hwdb.open(p)) |h| return h else |_| {}
        }
        return error.NotFound;
    }

    pub fn close(self: *Hwdb) void {
        _ = linux.munmap(self.data.ptr, self.data.len);
    }

    fn u64At(self: *const Hwdb, off: u64) u64 {
        if (off + 8 > self.data.len) return 0;
        return std.mem.readInt(u64, self.data[@intCast(off)..][0..8], .little);
    }

    fn str(self: *const Hwdb, off: u64) []const u8 {
        if (off == 0 or off >= self.data.len) return "";
        const tail = self.data[@intCast(off)..];
        return tail[0 .. std.mem.indexOfScalar(u8, tail, 0) orelse tail.len];
    }

    const Node = struct { off: u64, prefix: []const u8, children: u8, values: u64 };

    fn node(self: *const Hwdb, off: u64) ?Node {
        if (off + self.node_size > self.data.len) return null;
        return .{
            .off = off,
            .prefix = self.str(self.u64At(off)),
            .children = self.data[@intCast(off + 8)],
            .values = self.u64At(off + 16),
        };
    }

    fn child(self: *const Hwdb, n: Node, i: usize) struct { c: u8, off: u64 } {
        const base = n.off + self.node_size + @as(u64, i) * self.child_size;
        if (base + 16 > self.data.len) return .{ .c = 0, .off = 0 };
        return .{ .c = self.data[@intCast(base)], .off = self.u64At(base + 8) };
    }

    fn findChild(self: *const Hwdb, n: Node, c: u8) ?Node {
        var lo: usize = 0;
        var hi: usize = n.children;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const ch = self.child(n, mid);
            if (ch.c == c) return self.node(ch.off);
            if (ch.c < c) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    const Value = struct { key: []const u8, value: []const u8, priority: u16 };

    fn value(self: *const Hwdb, n: Node, i: u64) Value {
        const base = n.off + self.node_size + @as(u64, n.children) * self.child_size + i * self.value_size;
        var priority: u16 = 0;
        if (self.value_size >= 32 and base + 30 <= self.data.len) priority = std.mem.readInt(u16, self.data[@intCast(base + 28)..][0..2], .little);
        return .{ .key = self.str(self.u64At(base)), .value = self.str(self.u64At(base + 8)), .priority = priority };
    }

    pub const Match = struct {
        key: []const u8,
        out: []u8,
        len: usize = 0,
        found: bool = false,
        priority: u16 = 0,

        fn offer(self: *Match, v: Value) void {
            if (!std.mem.eql(u8, v.key[if (v.key.len > 0 and v.key[0] == ' ') 1 else 0..], self.key)) return;
            if (self.found and v.priority < self.priority) return;
            const n = @min(v.value.len, self.out.len - 1);
            @memcpy(self.out[0..n], v.value[0..n]);
            self.out[n] = 0;
            self.len = n;
            self.found = true;
            self.priority = v.priority;
        }
    };

    fn takeValues(self: *const Hwdb, n: Node, m: *Match) void {
        var i: u64 = 0;
        while (i < n.values) : (i += 1) m.offer(self.value(n, i));
    }

    fn globWalk(self: *const Hwdb, n: Node, pattern: *std.ArrayList(u8), search: [*:0]const u8, m: *Match, depth: u32) void {
        if (depth > 4096) return;
        const before = pattern.items.len;
        pattern.appendSlice(sys.gpa, n.prefix) catch return;
        defer pattern.shrinkRetainingCapacity(before);
        var i: usize = 0;
        while (i < n.children) : (i += 1) {
            const ch = self.child(n, i);
            const next = self.node(ch.off) orelse continue;
            pattern.append(sys.gpa, ch.c) catch return;
            self.globWalk(next, pattern, search, m, depth + 1);
            pattern.shrinkRetainingCapacity(pattern.items.len - 1);
        }
        if (n.values == 0) return;
        pattern.append(sys.gpa, 0) catch return;
        defer pattern.shrinkRetainingCapacity(pattern.items.len - 1);
        const pz: [*:0]const u8 = @ptrCast(pattern.items.ptr);
        if (fnmatch(pz, search, 0) == 0) self.takeValues(n, m);
    }

    pub fn lookup(self: *const Hwdb, modalias: []const u8, key: []const u8, out: []u8) !usize {
        if (out.len == 0) return error.TooBig;
        var sbuf: [512]u8 = undefined;
        if (modalias.len >= sbuf.len) return error.TooBig;
        @memcpy(sbuf[0..modalias.len], modalias);
        sbuf[modalias.len] = 0;
        const search: [*:0]const u8 = @ptrCast(&sbuf);
        var m = Match{ .key = key, .out = out };
        var pattern: std.ArrayList(u8) = .empty;
        defer pattern.deinit(sys.gpa);
        var cur = self.node(self.root);
        var i: usize = 0;
        while (cur) |n| {
            var p: usize = 0;
            var wild = false;
            while (p < n.prefix.len) : (p += 1) {
                const c = n.prefix[p];
                if (c == '*' or c == '?' or c == '[') {
                    wild = true;
                    break;
                }
                if (i + p >= modalias.len or c != modalias[i + p]) break;
            }
            if (wild) {
                self.globWalk(n, &pattern, search, &m, 0);
                break;
            }
            if (p < n.prefix.len) break;
            try pattern.appendSlice(sys.gpa, n.prefix);
            i += p;
            for ("*?[") |w| {
                if (self.findChild(n, w)) |wn| {
                    try pattern.append(sys.gpa, w);
                    self.globWalk(wn, &pattern, search, &m, 0);
                    pattern.shrinkRetainingCapacity(pattern.items.len - 1);
                }
            }
            if (i == modalias.len) {
                self.takeValues(n, &m);
                break;
            }
            cur = self.findChild(n, modalias[i]);
            try pattern.append(sys.gpa, modalias[i]);
            i += 1;
        }
        if (!m.found) return error.NotFound;
        return m.len;
    }
};

pub fn hwdbLookup(modalias: []const u8, key: []const u8, out: []u8) !usize {
    var h = try Hwdb.openDefault();
    defer h.close();
    return h.lookup(modalias, key, out);
}

fn hex(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
}

pub fn pciModalias(sysfs_dev: []const u8, out: []u8) ![]const u8 {
    var buf: [512]u8 = undefined;
    var vb: [32]u8 = undefined;
    var db: [32]u8 = undefined;
    const vendor = sys.readTrim(try sys.pathZ(&buf, "{s}/vendor", .{sysfs_dev}), &vb) orelse return error.NotFound;
    const device = sys.readTrim(try sys.pathZ(&buf, "{s}/device", .{sysfs_dev}), &db) orelse return error.NotFound;
    const v = std.fmt.parseInt(u32, hex(vendor), 16) catch return error.Invalid;
    const d = std.fmt.parseInt(u32, hex(device), 16) catch return error.Invalid;
    return std.fmt.bufPrint(out, "pci:v{X:0>8}d{X:0>8}", .{ v, d }) catch error.TooBig;
}

pub const DeviceNames = extern struct {
    vendor: [128]u8,
    model: [128]u8,
};

pub fn names(sysfs_dev: []const u8, out: *DeviceNames) !void {
    out.* = std.mem.zeroes(DeviceNames);
    var mbuf: [128]u8 = undefined;
    var abuf: [512]u8 = undefined;
    const modalias = blk: {
        var tmp: [512]u8 = undefined;
        if (sys.readTrim(try sys.pathZ(&abuf, "{s}/modalias", .{sysfs_dev}), &tmp)) |m| {
            if (std.mem.startsWith(u8, m, "pci:")) break :blk try pciModalias(sysfs_dev, &mbuf);
            if (m.len > mbuf.len) return error.TooBig;
            @memcpy(mbuf[0..m.len], m);
            break :blk mbuf[0..m.len];
        }
        break :blk try pciModalias(sysfs_dev, &mbuf);
    };
    var h = try Hwdb.openDefault();
    defer h.close();
    _ = h.lookup(modalias, "ID_VENDOR_FROM_DATABASE", &out.vendor) catch {};
    _ = h.lookup(modalias, "ID_MODEL_FROM_DATABASE", &out.model) catch {};
    if (out.vendor[0] == 0 and out.model[0] == 0) return error.NotFound;
}

pub const Property = struct { key: []const u8, value: []const u8 };

pub fn ueventGet(path: [*:0]const u8, key: []const u8, out: []u8) !usize {
    var buf: [8192]u8 = undefined;
    const data = try sys.readFile(path, &buf);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, line[0..eq], key)) continue;
        const v = line[eq + 1 ..];
        if (v.len + 1 > out.len) return error.TooBig;
        @memcpy(out[0..v.len], v);
        out[v.len] = 0;
        return v.len;
    }
    return error.NotFound;
}

fn buildHwdb(alloc: std.mem.Allocator, entries: []const [3][]const u8) ![]u8 {
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(alloc);
    try strings.append(alloc, 0);
    const Builder = struct {
        const TNode = struct {
            prefix: std.ArrayList(u8) = .empty,
            kids: std.ArrayList(struct { c: u8, n: *TNode }) = .empty,
            vals: std.ArrayList([2][]const u8) = .empty,
        };
    };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try a.create(Builder.TNode);
    root.* = .{};
    for (entries) |e| {
        var n = root;
        var rest = e[0];
        while (rest.len > 0) {
            var found: ?*Builder.TNode = null;
            for (n.kids.items) |k| if (k.c == rest[0]) {
                found = k.n;
            };
            if (found == null) {
                const nn = try a.create(Builder.TNode);
                nn.* = .{};
                try n.kids.append(a, .{ .c = rest[0], .n = nn });
                std.mem.sort(@TypeOf(n.kids.items[0]), n.kids.items, {}, struct {
                    fn lt(_: void, x: @TypeOf(n.kids.items[0]), y: @TypeOf(n.kids.items[0])) bool {
                        return x.c < y.c;
                    }
                }.lt);
                found = nn;
            }
            n = found.?;
            rest = rest[1..];
        }
        try n.vals.append(a, .{ e[1], e[2] });
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendNTimes(alloc, 0, 80);
    const Emit = struct {
        fn str(al: std.mem.Allocator, s: *std.ArrayList(u8), v: []const u8) !u64 {
            const off = s.items.len;
            try s.appendSlice(al, v);
            try s.append(al, 0);
            return off;
        }
        fn emit(al: std.mem.Allocator, o: *std.ArrayList(u8), s: *std.ArrayList(u8), n: *Builder.TNode) !u64 {
            var kid_offs: [256]u64 = undefined;
            for (n.kids.items, 0..) |k, i| kid_offs[i] = try emit(al, o, s, k.n);
            const off = o.items.len;
            var w: [8]u8 = undefined;
            std.mem.writeInt(u64, &w, 0, .little);
            try o.appendSlice(al, &w);
            try o.append(al, @intCast(n.kids.items.len));
            try o.appendNTimes(al, 0, 7);
            std.mem.writeInt(u64, &w, n.vals.items.len, .little);
            try o.appendSlice(al, &w);
            for (n.kids.items, 0..) |k, i| {
                try o.append(al, k.c);
                try o.appendNTimes(al, 0, 7);
                std.mem.writeInt(u64, &w, kid_offs[i], .little);
                try o.appendSlice(al, &w);
            }
            for (n.vals.items) |v| {
                std.mem.writeInt(u64, &w, try str(al, s, v[0]), .little);
                try o.appendSlice(al, &w);
                std.mem.writeInt(u64, &w, try str(al, s, v[1]), .little);
                try o.appendSlice(al, &w);
            }
            return off;
        }
    };
    const root_off = try Emit.emit(alloc, &out, &strings, root);
    const strings_base = out.items.len;
    try out.appendSlice(alloc, strings.items);
    var i: usize = 80;
    while (i < strings_base) {
        const children = out.items[i + 8];
        const values = std.mem.readInt(u64, out.items[i + 16 ..][0..8], .little);
        i += 24 + @as(usize, children) * 16;
        var v: u64 = 0;
        while (v < values) : (v += 1) {
            for ([_]usize{ 0, 8 }) |f| {
                const so = std.mem.readInt(u64, out.items[i + f ..][0..8], .little);
                std.mem.writeInt(u64, out.items[i + f ..][0..8], so + strings_base, .little);
            }
            i += 16;
        }
    }
    @memcpy(out.items[0..8], signature);
    const hdr = [_]u64{ 3, out.items.len, 80, 24, 16, 16, root_off, strings_base - 80, strings.items.len };
    for (hdr, 0..) |h, k| std.mem.writeInt(u64, out.items[8 + k * 8 ..][0..8], h, .little);
    return out.toOwnedSlice(alloc);
}

test "hwdb exact and glob lookups" {
    const entries = [_][3][]const u8{
        .{ "pci:v000010ECd00008125*", " ID_MODEL_FROM_DATABASE", "RTL8125 2.5GbE Controller" },
        .{ "pci:v000010EC*", " ID_VENDOR_FROM_DATABASE", "Realtek Semiconductor Co., Ltd." },
        .{ "pci:v00008086d000015F3*", " ID_MODEL_FROM_DATABASE", "Ethernet Controller I225-V" },
        .{ "usb:v1D6Bp0002*", " ID_MODEL_FROM_DATABASE", "2.0 root hub" },
        .{ "evdev:input:b0003v046Dp*", " KEYBOARD_KEY_70039", "esc" },
        .{ "dmi:bvn*:svnLENOVO:pn20*", " ID_CHASSIS", "laptop" },
    };
    const blob = try buildHwdb(std.testing.allocator, &entries);
    defer std.testing.allocator.free(blob);
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "hwdb");
    try sys.put(root, "hwdb.bin", blob);
    var pb: [512]u8 = undefined;
    var h = try Hwdb.open(try sys.pathZ(&pb, "{s}/hwdb.bin", .{root}));
    defer h.close();
    var out: [128]u8 = undefined;
    var n = try h.lookup("pci:v000010ECd00008125sv000010ECsd00000123bc02sc00i00", "ID_MODEL_FROM_DATABASE", &out);
    try std.testing.expectEqualStrings("RTL8125 2.5GbE Controller", out[0..n]);
    n = try h.lookup("pci:v000010ECd00008168", "ID_VENDOR_FROM_DATABASE", &out);
    try std.testing.expectEqualStrings("Realtek Semiconductor Co., Ltd.", out[0..n]);
    n = try h.lookup("pci:v00008086d000015F3", "ID_MODEL_FROM_DATABASE", &out);
    try std.testing.expectEqualStrings("Ethernet Controller I225-V", out[0..n]);
    n = try h.lookup("dmi:bvnLENOVO:bvrN32ET:svnLENOVO:pn20XWCTO1WW:", "ID_CHASSIS", &out);
    try std.testing.expectEqualStrings("laptop", out[0..n]);
    try std.testing.expectError(error.NotFound, h.lookup("pci:v000010ECd00008168", "ID_MODEL_FROM_DATABASE", &out));
    try std.testing.expectError(error.NotFound, h.lookup("pci:v00001234d00005678", "ID_VENDOR_FROM_DATABASE", &out));
}

test "the system hwdb names a known pci vendor" {
    var h = Hwdb.openDefault() catch return error.SkipZigTest;
    defer h.close();
    var out: [128]u8 = undefined;
    const n = try h.lookup("pci:v00008086d00001234", "ID_VENDOR_FROM_DATABASE", &out);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "Intel") != null);
}

test "uevent keys" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "uevent");
    try sys.put(root, "uevent", "DRIVER=r8169\nPCI_CLASS=20000\nMODALIAS=pci:v000010ECd00008125\n");
    var pb: [512]u8 = undefined;
    var out: [64]u8 = undefined;
    const n = try ueventGet(try sys.pathZ(&pb, "{s}/uevent", .{root}), "DRIVER", &out);
    try std.testing.expectEqualStrings("r8169", out[0..n]);
    try std.testing.expectError(error.NotFound, ueventGet(try sys.pathZ(&pb, "{s}/uevent", .{root}), "DEVNAME", &out));
}
