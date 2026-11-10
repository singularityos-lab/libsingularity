const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const Entry = extern struct {
    id: u32,
    parent: u32,
    major: u32,
    minor: u32,
    root: [256]u8,
    target: [256]u8,
    fstype: [32]u8,
    source: [256]u8,
    options: [256]u8,
    super_options: [256]u8,
};

pub const Table = sys.List(Entry);

fn unescape(dst: []u8, src: []const u8) void {
    @memset(dst, 0);
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o + 1 < dst.len) : (o += 1) {
        if (src[i] == '\\' and i + 4 <= src.len) {
            if (std.fmt.parseInt(u8, src[i + 1 .. i + 4], 8)) |c| {
                dst[o] = c;
                i += 4;
                continue;
            } else |_| {}
        }
        dst[o] = src[i];
        i += 1;
    }
}

pub fn parseLine(line: []const u8) ?Entry {
    var e = std.mem.zeroes(Entry);
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    e.id = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    e.parent = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const dev = it.next() orelse return null;
    const colon = std.mem.indexOfScalar(u8, dev, ':') orelse return null;
    e.major = std.fmt.parseInt(u32, dev[0..colon], 10) catch return null;
    e.minor = std.fmt.parseInt(u32, dev[colon + 1 ..], 10) catch return null;
    unescape(&e.root, it.next() orelse return null);
    unescape(&e.target, it.next() orelse return null);
    unescape(&e.options, it.next() orelse return null);
    while (it.next()) |f| {
        if (std.mem.eql(u8, f, "-")) break;
    } else return null;
    unescape(&e.fstype, it.next() orelse return null);
    unescape(&e.source, it.next() orelse return null);
    unescape(&e.super_options, it.next() orelse "");
    return e;
}

pub fn parse(text: []const u8) !*Table {
    const t = try Table.create();
    errdefer t.destroy();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (parseLine(line)) |e| try t.append(e);
    }
    return t;
}

pub fn table() !*Table {
    const text = try sys.readAlloc(sys.gpa, "/proc/self/mountinfo", 16 << 20);
    defer sys.gpa.free(text);
    return parse(text);
}

pub fn devNumber(path: [*:0]const u8) !struct { major: u32, minor: u32 } {
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return sys.fromErrno(linux.errno(rc));
    if (st.mode & linux.S.IFMT != linux.S.IFBLK) return error.Invalid;
    return .{ .major = st.rdev_major, .minor = st.rdev_minor };
}

pub fn findDevice(t: *const Table, major: u32, minor: u32) ?*const Entry {
    for (t.items.items) |*e| {
        if (e.major == major and e.minor == minor and std.mem.eql(u8, sys.cstr(&e.root), "/")) return e;
    }
    for (t.items.items) |*e| {
        if (e.major == major and e.minor == minor) return e;
    }
    return null;
}

pub fn findTarget(t: *const Table, target: []const u8) ?*const Entry {
    var found: ?*const Entry = null;
    for (t.items.items) |*e| {
        if (std.mem.eql(u8, sys.cstr(&e.target), target)) found = e;
    }
    return found;
}

pub const Flags = struct {
    flags: u32 = 0,
    data: [256]u8 = std.mem.zeroes([256]u8),
};

const flag_names = [_]struct { name: []const u8, set: u32, clear: bool = false }{
    .{ .name = "ro", .set = linux.MS.RDONLY },
    .{ .name = "rw", .set = linux.MS.RDONLY, .clear = true },
    .{ .name = "nosuid", .set = linux.MS.NOSUID },
    .{ .name = "suid", .set = linux.MS.NOSUID, .clear = true },
    .{ .name = "nodev", .set = linux.MS.NODEV },
    .{ .name = "dev", .set = linux.MS.NODEV, .clear = true },
    .{ .name = "noexec", .set = linux.MS.NOEXEC },
    .{ .name = "exec", .set = linux.MS.NOEXEC, .clear = true },
    .{ .name = "sync", .set = linux.MS.SYNCHRONOUS },
    .{ .name = "async", .set = linux.MS.SYNCHRONOUS, .clear = true },
    .{ .name = "dirsync", .set = linux.MS.DIRSYNC },
    .{ .name = "noatime", .set = linux.MS.NOATIME },
    .{ .name = "nodiratime", .set = linux.MS.NODIRATIME },
    .{ .name = "relatime", .set = linux.MS.RELATIME },
    .{ .name = "strictatime", .set = linux.MS.STRICTATIME },
    .{ .name = "lazytime", .set = 1 << 25 },
    .{ .name = "silent", .set = linux.MS.SILENT },
    .{ .name = "defaults", .set = 0 },
};

pub fn parseOptions(options: []const u8) !Flags {
    var f = Flags{};
    var o: usize = 0;
    var it = std.mem.tokenizeScalar(u8, options, ',');
    outer: while (it.next()) |opt| {
        for (flag_names) |n| {
            if (std.mem.eql(u8, opt, n.name)) {
                if (n.clear) f.flags &= ~n.set else f.flags |= n.set;
                continue :outer;
            }
        }
        const need = opt.len + @as(usize, if (o > 0) 1 else 0);
        if (o + need >= f.data.len) return error.TooBig;
        if (o > 0) {
            f.data[o] = ',';
            o += 1;
        }
        @memcpy(f.data[o .. o + opt.len], opt);
        o += opt.len;
    }
    return f;
}

pub fn mount(source: [*:0]const u8, target: [*:0]const u8, fstype: [*:0]const u8, options: []const u8) !void {
    var f = try parseOptions(options);
    const data: usize = if (f.data[0] != 0) @intFromPtr(&f.data) else 0;
    const rc = linux.mount(source, target, fstype, f.flags, data);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NODEV => return error.Unsupported,
        .PERM => return error.Access,
        else => |e| return sys.fromErrno(e),
    }
}

pub const Overlay = struct {
    lower: []const []const u8,
    upper: ?[]const u8 = null,
    work: ?[]const u8 = null,
    options: []const u8 = "",
};

fn escapePath(out: []u8, pos: *usize, path: []const u8) !void {
    for (path) |c| {
        if (c == ':' or c == ',' or c == '\\') {
            if (pos.* + 1 >= out.len) return error.TooBig;
            out[pos.*] = '\\';
            pos.* += 1;
        }
        if (pos.* + 1 >= out.len) return error.TooBig;
        out[pos.*] = c;
        pos.* += 1;
    }
}

fn append(out: []u8, pos: *usize, s: []const u8) !void {
    if (pos.* + s.len >= out.len) return error.TooBig;
    @memcpy(out[pos.* .. pos.* + s.len], s);
    pos.* += s.len;
}

pub fn overlayData(out: []u8, o: Overlay) ![:0]const u8 {
    if (o.lower.len == 0) return error.Invalid;
    if ((o.upper == null) != (o.work == null)) return error.Invalid;
    var pos: usize = 0;
    try append(out, &pos, "lowerdir=");
    for (o.lower, 0..) |l, i| {
        if (l.len == 0) return error.Invalid;
        if (i > 0) try append(out, &pos, ":");
        try escapePath(out, &pos, l);
    }
    if (o.upper) |u| {
        try append(out, &pos, ",upperdir=");
        try escapePath(out, &pos, u);
        try append(out, &pos, ",workdir=");
        try escapePath(out, &pos, o.work.?);
    }
    if (o.options.len > 0) {
        try append(out, &pos, ",");
        try append(out, &pos, o.options);
    }
    out[pos] = 0;
    return out[0..pos :0];
}

pub fn overlay(target: [*:0]const u8, o: Overlay, flags: u32) !void {
    var buf: [4096]u8 = undefined;
    const data = try overlayData(&buf, o);
    const rc = linux.mount("overlay", target, "overlay", flags, @intFromPtr(data.ptr));
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NODEV => return error.Unsupported,
        .PERM => return error.Access,
        else => |e| return sys.fromErrno(e),
    }
}

pub fn unmount(target: [*:0]const u8, lazy: bool) !void {
    while (true) {
        const rc = linux.umount2(target, if (lazy) linux.MNT.DETACH else 0);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .PERM => return error.Access,
            .INVAL => return error.Invalid,
            else => |e| return sys.fromErrno(e),
        }
    }
}

pub const Temp = struct {
    path: [128]u8,
    owned: bool,

    pub fn target(t: *const Temp) [*:0]const u8 {
        return @ptrCast(&t.path);
    }

    pub fn release(t: *Temp) void {
        if (!t.owned) return;
        unmount(t.target(), false) catch unmount(t.target(), true) catch {};
        _ = linux.rmdir(t.target());
        t.owned = false;
    }
};

fn tempBase() []const u8 {
    if (std.c.getenv("SINTY_MOUNT_TMP")) |p| return std.mem.span(p);
    if (linux.geteuid() == 0) return "/run";
    if (std.c.getenv("XDG_RUNTIME_DIR")) |p| return std.mem.span(p);
    return "/tmp";
}

pub fn ensure(dev: [*:0]const u8, fstype: [*:0]const u8, options: []const u8) !Temp {
    const num = try devNumber(dev);
    const t = try table();
    defer t.destroy();
    var out = Temp{ .path = std.mem.zeroes([128]u8), .owned = false };
    if (findDevice(t, num.major, num.minor)) |e| {
        const s = sys.cstr(&e.target);
        if (s.len >= out.path.len) return error.TooBig;
        @memcpy(out.path[0..s.len], s);
        return out;
    }
    var rnd: [6]u8 = undefined;
    var n: usize = 0;
    while (n < rnd.len) {
        const rc = linux.getrandom(rnd[n..].ptr, rnd.len - n, 0);
        if (linux.errno(rc) == .SUCCESS) n += rc;
    }
    const hex = std.fmt.bytesToHex(rnd, .lower);
    _ = std.fmt.bufPrint(&out.path, "{s}/sinty-mount-{s}", .{ tempBase(), hex }) catch return error.TooBig;
    const rc = linux.mkdir(out.target(), 0o700);
    if (linux.errno(rc) != .SUCCESS) return sys.fromErrno(linux.errno(rc));
    mount(dev, out.target(), fstype, options) catch |e| {
        _ = linux.rmdir(out.target());
        return e;
    };
    out.owned = true;
    return out;
}

test "mountinfo lines are parsed with escapes" {
    const text =
        \\22 1 0:21 / /proc rw,nosuid,nodev,noexec,relatime shared:12 - proc proc rw
        \\95 30 8:3 /home /var/home/a\040b rw,relatime shared:1 master:2 - ext4 /dev/sda3 rw,seclabel
        \\96 30 8:3 / /mnt rw - ext4 /dev/sda3 rw
        \\bad line
    ;
    const t = try parse(text);
    defer t.destroy();
    try std.testing.expectEqual(@as(usize, 3), t.count());
    const e = t.at(1).?;
    try std.testing.expectEqualStrings("/var/home/a b", sys.cstr(&e.target));
    try std.testing.expectEqualStrings("ext4", sys.cstr(&e.fstype));
    try std.testing.expectEqualStrings("/dev/sda3", sys.cstr(&e.source));
    try std.testing.expectEqualStrings("rw,seclabel", sys.cstr(&e.super_options));
    try std.testing.expectEqualStrings("/mnt", sys.cstr(&findDevice(t, 8, 3).?.target));
    try std.testing.expect(findDevice(t, 9, 9) == null);
    try std.testing.expectEqual(@as(u32, 22), findTarget(t, "/proc").?.id);
}

test "mount options split into flags and data" {
    const f = try parseOptions("ro,nosuid,uid=1000,nodev,errors=remount-ro,defaults");
    try std.testing.expectEqual(linux.MS.RDONLY | linux.MS.NOSUID | linux.MS.NODEV, f.flags);
    try std.testing.expectEqualStrings("uid=1000,errors=remount-ro", sys.cstr(&f.data));
    const g = try parseOptions("ro,rw");
    try std.testing.expectEqual(@as(u32, 0), g.flags);
    try std.testing.expectError(error.TooBig, parseOptions("x=" ++ "a" ** 300));
}

test "the live mount table includes the root" {
    const t = try table();
    defer t.destroy();
    try std.testing.expect(findTarget(t, "/") != null);
    try std.testing.expectError(error.Invalid, devNumber("/proc"));
}

test "overlay options escape separators" {
    var buf: [4096]u8 = undefined;
    const d = try overlayData(&buf, .{ .lower = &.{ "/a", "/b:c", "/d,e" }, .upper = "/u\\x", .work = "/w", .options = "index=off" });
    try std.testing.expectEqualStrings("lowerdir=/a:/b\\:c:/d\\,e,upperdir=/u\\\\x,workdir=/w,index=off", d);
    const r = try overlayData(&buf, .{ .lower = &.{"/ro"} });
    try std.testing.expectEqualStrings("lowerdir=/ro", r);
    try std.testing.expectError(error.Invalid, overlayData(&buf, .{ .lower = &.{} }));
    try std.testing.expectError(error.Invalid, overlayData(&buf, .{ .lower = &.{"/a"}, .upper = "/u" }));
    var small: [16]u8 = undefined;
    try std.testing.expectError(error.TooBig, overlayData(&small, .{ .lower = &.{"/a/very/long/path"} }));
}
