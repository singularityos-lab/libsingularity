const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const magic: u32 = 0xe0f5e1e2;
const block_bits = 12;
const block = 1 << block_bits;
const slot = 32;
const inode_bytes = 64;

pub const Info = struct {
    blocks: u32,
    inodes: u64,
    root_nid: u16,
    label: [16]u8,
    uuid: [16]u8,
    block_size: u32,
};

pub fn parseSuper(b: []const u8) !Info {
    if (b.len < 1024 + 128) return error.Invalid;
    const sb = b[1024..][0..128];
    if (std.mem.readInt(u32, sb[0..4], .little) != magic) return error.Invalid;
    const bits = sb[12];
    if (bits < 9 or bits > 16) return error.Invalid;
    return .{
        .blocks = std.mem.readInt(u32, sb[36..40], .little),
        .inodes = std.mem.readInt(u64, sb[16..24], .little),
        .root_nid = std.mem.readInt(u16, sb[14..16], .little),
        .label = sb[64..80].*,
        .uuid = sb[48..64].*,
        .block_size = @as(u32, 1) << @intCast(bits),
    };
}

const Kind = enum(u8) { unknown = 0, file = 1, dir = 2, chr = 3, blk = 4, fifo = 5, sock = 6, link = 7 };

const Node = struct {
    path: [:0]u8,
    name: []const u8,
    kind: Kind,
    mode: u16,
    uid: u32,
    gid: u32,
    mtime: u64,
    mtime_ns: u32,
    size: u64,
    rdev: u32,
    nlink: u32 = 1,
    nid: u64 = 0,
    blkaddr: u32 = 0,
    children: std.ArrayList(u32) = .empty,
    parent: u32 = 0,
    alias: ?u32 = null,
    dev: u64 = 0,
    ino: u64 = 0,
};

fn kindOf(mode: u32) Kind {
    return switch (mode & linux.S.IFMT) {
        linux.S.IFREG => .file,
        linux.S.IFDIR => .dir,
        linux.S.IFCHR => .chr,
        linux.S.IFBLK => .blk,
        linux.S.IFIFO => .fifo,
        linux.S.IFSOCK => .sock,
        linux.S.IFLNK => .link,
        else => .unknown,
    };
}

pub const Options = struct {
    label: []const u8 = "",
    uuid: ?[16]u8 = null,
    time: ?u64 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
};

const Builder = struct {
    alloc: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    names: std.ArrayList(u8) = .empty,
    opts: Options,

    fn deinit(b: *Builder) void {
        for (b.nodes.items) |*n| {
            b.alloc.free(n.path);
            n.children.deinit(b.alloc);
        }
        b.nodes.deinit(b.alloc);
    }

    fn stat(b: *Builder, path: [:0]const u8, name: []const u8, parent: u32) !u32 {
        var st: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true, .GID = true, .MTIME = true, .SIZE = true, .NLINK = true, .INO = true }, &st);
        if (linux.errno(rc) != .SUCCESS) return sys.fromErrno(linux.errno(rc));
        const kind = kindOf(st.mode);
        if (kind == .unknown) return error.Unsupported;
        const idx: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.alloc, .{
            .path = try b.alloc.dupeZ(u8, path),
            .name = name,
            .kind = kind,
            .mode = st.mode,
            .uid = b.opts.uid orelse st.uid,
            .gid = b.opts.gid orelse st.gid,
            .mtime = b.opts.time orelse @intCast(@max(st.mtime.sec, 0)),
            .mtime_ns = if (b.opts.time != null) 0 else st.mtime.nsec,
            .size = if (kind == .file or kind == .link) st.size else 0,
            .rdev = if (kind == .chr or kind == .blk) (st.rdev_major << 8) | (st.rdev_minor & 0xff) | ((st.rdev_minor & ~@as(u32, 0xff)) << 12) else 0,
            .parent = parent,
            .dev = (@as(u64, st.dev_major) << 32) | st.dev_minor,
            .ino = st.ino,
        });
        const n = &b.nodes.items[idx];
        n.name = n.path[n.path.len - name.len ..];
        return idx;
    }

    fn walk(b: *Builder, idx: u32) !void {
        var dir = try sys.Dir.open(b.nodes.items[idx].path);
        defer dir.close();
        var pending: std.ArrayList([]u8) = .empty;
        defer {
            for (pending.items) |p| b.alloc.free(p);
            pending.deinit(b.alloc);
        }
        while (try dir.next()) |e| {
            if (e.name.len > 255) return error.TooBig;
            try pending.append(b.alloc, try b.alloc.dupe(u8, e.name));
        }
        std.mem.sort([]u8, pending.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        for (pending.items) |name| {
            const base = b.nodes.items[idx].path;
            const full = try std.fmt.allocPrintSentinel(b.alloc, "{s}/{s}", .{ base, name }, 0);
            defer b.alloc.free(full);
            const child = try b.stat(full, name, idx);
            try b.nodes.items[idx].children.append(b.alloc, child);
            if (b.nodes.items[child].kind == .dir) try b.walk(child);
        }
    }

    fn links(b: *Builder) void {
        for (b.nodes.items, 0..) |*n, i| {
            if (n.kind == .dir) {
                n.nlink = 2;
                continue;
            }
            for (b.nodes.items[0..i], 0..) |*o, j| {
                if (o.kind != .dir and o.alias == null and o.dev == n.dev and o.ino == n.ino) {
                    n.alias = @intCast(j);
                    o.nlink += 1;
                    break;
                }
            }
        }
        for (b.nodes.items[1..]) |n| {
            if (n.kind == .dir) b.nodes.items[n.parent].nlink += 1;
        }
    }

    fn target(b: *const Builder, i: u32) *const Node {
        const n = &b.nodes.items[i];
        return if (n.alias) |a| &b.nodes.items[a] else n;
    }

    const Entry = struct { name: []const u8, node: u32, kind: Kind };

    fn entries(b: *Builder, idx: u32, out: *std.ArrayList(Entry)) !void {
        out.clearRetainingCapacity();
        const n = &b.nodes.items[idx];
        try out.append(b.alloc, .{ .name = ".", .node = idx, .kind = .dir });
        try out.append(b.alloc, .{ .name = "..", .node = n.parent, .kind = .dir });
        for (n.children.items) |c| try out.append(b.alloc, .{ .name = b.nodes.items[c].name, .node = c, .kind = b.target(c).kind });
        std.mem.sort(Entry, out.items, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
    }

    fn dirSize(b: *Builder, idx: u32, list: *std.ArrayList(Entry)) !u64 {
        try b.entries(idx, list);
        var blocks: u64 = 0;
        var used: usize = 0;
        for (list.items) |e| {
            const need = 12 + e.name.len;
            if (used + need > block) {
                blocks += 1;
                used = 0;
            }
            used += need;
        }
        return blocks * block + used;
    }

    fn encodeDir(b: *Builder, idx: u32, list: *std.ArrayList(Entry), out: []u8) !void {
        try b.entries(idx, list);
        @memset(out, 0);
        var start: usize = 0;
        var blk: usize = 0;
        while (start < list.items.len) : (blk += 1) {
            var end = start;
            var used: usize = 0;
            while (end < list.items.len and used + 12 + list.items[end].name.len <= block) : (end += 1) used += 12 + list.items[end].name.len;
            const page = out[blk * block ..][0..block];
            var nameoff: usize = (end - start) * 12;
            for (list.items[start..end], 0..) |e, k| {
                const d = page[k * 12 ..][0..12];
                std.mem.writeInt(u64, d[0..8], b.target(e.node).nid, .little);
                std.mem.writeInt(u16, d[8..10], @intCast(nameoff), .little);
                d[10] = @intFromEnum(e.kind);
                @memcpy(page[nameoff .. nameoff + e.name.len], e.name);
                nameoff += e.name.len;
            }
            start = end;
        }
    }
};

fn writeInode(out: []u8, n: *const Node) void {
    @memset(out, 0);
    std.mem.writeInt(u16, out[0..2], 1, .little);
    std.mem.writeInt(u16, out[4..6], n.mode, .little);
    std.mem.writeInt(u64, out[8..16], n.size, .little);
    const u: u32 = if (n.kind == .chr or n.kind == .blk) n.rdev else n.blkaddr;
    std.mem.writeInt(u32, out[16..20], u, .little);
    std.mem.writeInt(u32, out[20..24], @truncate(n.nid + 1), .little);
    std.mem.writeInt(u32, out[24..28], n.uid, .little);
    std.mem.writeInt(u32, out[28..32], n.gid, .little);
    std.mem.writeInt(u64, out[32..40], n.mtime, .little);
    std.mem.writeInt(u32, out[40..44], n.mtime_ns, .little);
    std.mem.writeInt(u32, out[44..48], n.nlink, .little);
}

fn copyFile(src: [*:0]const u8, out_fd: i32, off: u64, size: u64) !void {
    const fd = try sys.open(src, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer sys.close(fd);
    var buf: [1 << 16]u8 = undefined;
    var done: u64 = 0;
    while (done < size) {
        const want: usize = @intCast(@min(buf.len, size - done));
        const n = try sys.read(fd, buf[0..want]);
        if (n == 0) return error.Io;
        try sys.pwriteAll(out_fd, buf[0..n], off + done);
        done += n;
    }
}

pub fn build(source: [*:0]const u8, out_path: [*:0]const u8, opts: Options) !Info {
    if (opts.label.len > 16) return error.TooBig;
    var b = Builder{ .alloc = sys.gpa, .opts = opts };
    defer b.deinit();
    const root = try b.stat(std.mem.span(source), "", 0);
    if (b.nodes.items[root].kind != .dir) return error.Invalid;
    try b.walk(root);
    b.links();

    var slots: u64 = 0;
    for (b.nodes.items) |*n| {
        if (n.alias != null) continue;
        n.nid = slots;
        slots += inode_bytes / slot;
    }
    if (b.nodes.items[0].nid > 0xffff) return error.TooBig;
    const meta_blkaddr: u32 = 1;
    const meta_blocks = (slots * slot + block - 1) / block;
    var next: u64 = meta_blkaddr + meta_blocks;
    var list: std.ArrayList(Builder.Entry) = .empty;
    defer list.deinit(sys.gpa);
    for (b.nodes.items, 0..) |*n, i| {
        if (n.alias != null) continue;
        if (n.kind == .dir) n.size = try b.dirSize(@intCast(i), &list);
        if ((n.kind == .file or n.kind == .link or n.kind == .dir) and n.size > 0) {
            if (next > 0xffffffff) return error.TooBig;
            n.blkaddr = @intCast(next);
            next += (n.size + block - 1) / block;
        }
    }
    if (next > 0xffffffff) return error.TooBig;
    const total: u32 = @intCast(next);

    const fd = try sys.open(out_path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    defer sys.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(@as(u64, total) * block))) != .SUCCESS) return error.Io;

    const meta = try sys.gpa.alloc(u8, @intCast(meta_blocks * block));
    defer sys.gpa.free(meta);
    @memset(meta, 0);
    for (b.nodes.items) |*n| {
        if (n.alias != null) continue;
        writeInode(meta[@intCast(n.nid * slot)..][0..inode_bytes], n);
    }
    try sys.pwriteAll(fd, meta, @as(u64, meta_blkaddr) * block);

    for (b.nodes.items, 0..) |*n, i| {
        if (n.alias != null or n.size == 0) continue;
        const off = @as(u64, n.blkaddr) * block;
        switch (n.kind) {
            .file => try copyFile(n.path, fd, off, n.size),
            .link => {
                var buf: [4096]u8 = undefined;
                const t = try sys.readLink(n.path, &buf);
                if (t.len != n.size) return error.Invalid;
                try sys.pwriteAll(fd, t, off);
            },
            .dir => {
                const data = try sys.gpa.alloc(u8, @intCast((n.size + block - 1) / block * block));
                defer sys.gpa.free(data);
                try b.encodeDir(@intCast(i), &list, data);
                try sys.pwriteAll(fd, data[0..@intCast(n.size)], off);
            },
            else => {},
        }
    }

    var head = std.mem.zeroes([block]u8);
    const sb = head[1024..][0..128];
    std.mem.writeInt(u32, sb[0..4], magic, .little);
    sb[12] = block_bits;
    std.mem.writeInt(u16, sb[14..16], @intCast(b.nodes.items[0].nid), .little);
    var inodes: u64 = 0;
    for (b.nodes.items) |n| {
        if (n.alias == null) inodes += 1;
    }
    std.mem.writeInt(u64, sb[16..24], inodes, .little);
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    std.mem.writeInt(u64, sb[24..32], opts.time orelse @intCast(ts.sec), .little);
    std.mem.writeInt(u32, sb[36..40], total, .little);
    std.mem.writeInt(u32, sb[40..44], meta_blkaddr, .little);
    var uuid: [16]u8 = undefined;
    if (opts.uuid) |u| uuid = u else {
        var got: usize = 0;
        while (got < uuid.len) {
            const rc = linux.getrandom(uuid[got..].ptr, uuid.len - got, 0);
            if (linux.errno(rc) == .SUCCESS) got += rc;
        }
        uuid[6] = (uuid[6] & 0x0f) | 0x40;
        uuid[8] = (uuid[8] & 0x3f) | 0x80;
    }
    @memcpy(sb[48..64], &uuid);
    @memcpy(sb[64 .. 64 + opts.label.len], opts.label);
    try sys.pwriteAll(fd, &head, 0);
    _ = linux.fsync(fd);
    return parseSuper(&head);
}

test "an erofs image round-trips through the superblock" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "erofs");
    try sys.put(root, "src/a.txt", "ciao");
    try sys.put(root, "src/sub/b.bin", "x" ** 5000);
    try sys.put(root, "src/empty", "");
    var lb: [600]u8 = undefined;
    var tb: [600]u8 = undefined;
    _ = try sys.symlink("a.txt", try sys.pathZ(&lb, "{s}/src/link", .{root}));
    _ = linux.link(try sys.pathZ(&lb, "{s}/src/a.txt", .{root}), try sys.pathZ(&tb, "{s}/src/hard", .{root}));
    var sb: [600]u8 = undefined;
    var ob: [600]u8 = undefined;
    const info = try build(try sys.pathZ(&sb, "{s}/src", .{root}), try sys.pathZ(&ob, "{s}/out.img", .{root}), .{ .label = "sinty", .time = 1, .uid = 0, .gid = 0 });
    try std.testing.expectEqual(@as(u64, 6), info.inodes);
    try std.testing.expectEqual(@as(u32, 4096), info.block_size);
    try std.testing.expectEqualStrings("sinty", sys.cstr(&info.label));
    var head: [8192]u8 = undefined;
    const img = try sys.readFile(try sys.pathZ(&ob, "{s}/out.img", .{root}), &head);
    const again = try parseSuper(img);
    try std.testing.expectEqual(info.blocks, again.blocks);
    try std.testing.expectError(error.Invalid, parseSuper(head[0..100]));
    var d = try @import("fs.zig").Dev.open(try sys.pathZ(&ob, "{s}/out.img", .{root}), false);
    defer d.close();
    const p = try @import("fs.zig").probe(d);
    try std.testing.expectEqualStrings("erofs", sys.cstr(&p.type));
    try std.testing.expectEqualStrings("sinty", sys.cstr(&p.label));
}
