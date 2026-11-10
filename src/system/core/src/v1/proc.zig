const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const Process = extern struct {
    pid: i32,
    ppid: i32,
    uid: u32,
    state: u8,
    pad: [3]u8 = .{ 0, 0, 0 },
    nice: i32,
    threads: u32,
    rss_bytes: u64,
    vsize_bytes: u64,
    utime_ticks: u64,
    stime_ticks: u64,
    start_ticks: u64,
    name: [64]u8,
    cmdline: ?[*:0]u8,
};

pub const ProcessList = struct {
    items: std.ArrayList(Process) = .empty,

    pub fn deinit(self: *ProcessList) void {
        for (self.items.items) |p| if (p.cmdline) |c| sys.gpa.free(std.mem.span(c));
        self.items.deinit(sys.gpa);
    }
};

pub fn pageSize() u64 {
    return std.heap.pageSize();
}

pub fn parseStat(text: []const u8, out: *Process) bool {
    const open_paren = std.mem.indexOfScalar(u8, text, '(') orelse return false;
    const close_paren = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
    if (close_paren < open_paren) return false;
    sys.copyName(&out.name, text[open_paren + 1 .. close_paren]);
    out.pid = std.fmt.parseInt(i32, sys.trim(text[0..open_paren]), 10) catch return false;
    var it = std.mem.tokenizeScalar(u8, text[close_paren + 1 ..], ' ');
    var field: usize = 3;
    while (it.next()) |tok| : (field += 1) {
        switch (field) {
            3 => out.state = tok[0],
            4 => out.ppid = std.fmt.parseInt(i32, tok, 10) catch 0,
            14 => out.utime_ticks = std.fmt.parseInt(u64, tok, 10) catch 0,
            15 => out.stime_ticks = std.fmt.parseInt(u64, tok, 10) catch 0,
            19 => out.nice = std.fmt.parseInt(i32, tok, 10) catch 0,
            20 => out.threads = std.fmt.parseInt(u32, tok, 10) catch 0,
            22 => out.start_ticks = std.fmt.parseInt(u64, tok, 10) catch 0,
            23 => out.vsize_bytes = std.fmt.parseInt(u64, tok, 10) catch 0,
            24 => out.rss_bytes = (std.fmt.parseInt(u64, tok, 10) catch 0) * pageSize(),
            else => {},
        }
        if (field > 24) break;
    }
    return true;
}

fn uidOf(pid: i32) u32 {
    var path: [64]u8 = undefined;
    const p = sys.pathZ(&path, "/proc/{d}/status", .{pid}) catch return 0;
    var buf: [4096]u8 = undefined;
    const data = sys.readFile(p, &buf) catch return 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Uid:")) {
            var it = std.mem.tokenizeAny(u8, line[4..], " \t");
            if (it.next()) |tok| return std.fmt.parseInt(u32, tok, 10) catch 0;
        }
    }
    return 0;
}

fn cmdlineOf(pid: i32) ?[*:0]u8 {
    var path: [64]u8 = undefined;
    const p = sys.pathZ(&path, "/proc/{d}/cmdline", .{pid}) catch return null;
    const data = sys.readAlloc(sys.gpa, p, 1 << 20) catch return null;
    defer sys.gpa.free(data);
    const trimmed = std.mem.trimEnd(u8, data, "\x00");
    const out = sys.gpa.allocSentinel(u8, trimmed.len, 0) catch return null;
    for (trimmed, 0..) |c, i| out[i] = if (c == 0) ' ' else c;
    return out.ptr;
}

pub fn read(pid: i32, out: *Process, with_cmdline: bool) sys.Error!void {
    var path: [64]u8 = undefined;
    const p = try sys.pathZ(&path, "/proc/{d}/stat", .{pid});
    var buf: [1024]u8 = undefined;
    const data = try sys.readFile(p, &buf);
    out.* = std.mem.zeroes(Process);
    if (!parseStat(data, out)) return error.Invalid;
    out.uid = uidOf(pid);
    out.cmdline = if (with_cmdline) cmdlineOf(pid) else null;
}

pub fn list(root: [*:0]const u8) !*ProcessList {
    const result = try sys.gpa.create(ProcessList);
    result.* = .{};
    errdefer {
        result.deinit();
        sys.gpa.destroy(result);
    }
    var dir = try sys.Dir.open(root);
    defer dir.close();
    while (try dir.next()) |entry| {
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        var p: Process = undefined;
        read(pid, &p, true) catch continue;
        try result.items.append(sys.gpa, p);
    }
    return result;
}

pub fn signal(pid: i32, sig: i32) sys.Error!void {
    if (pid <= 0) return error.Invalid;
    _ = try sys.check(linux.syscall2(.kill, @as(usize, @bitCast(@as(isize, pid))), @as(usize, @bitCast(@as(isize, sig)))));
}

const PRIO_PROCESS = 0;

pub fn getNice(pid: i32) sys.Error!i32 {
    const rc = linux.syscall2(.getpriority, PRIO_PROCESS, @as(usize, @bitCast(@as(isize, pid))));
    _ = try sys.check(rc);
    return 20 - @as(i32, @intCast(rc));
}

pub fn setNice(pid: i32, nice: i32) sys.Error!void {
    if (nice < -20 or nice > 19) return error.Invalid;
    _ = try sys.check(linux.syscall3(.setpriority, PRIO_PROCESS, @as(usize, @bitCast(@as(isize, pid))), @as(usize, @bitCast(@as(isize, nice)))));
}

pub const IoClass = enum(u32) { none = 0, realtime = 1, best_effort = 2, idle = 3 };

pub fn setIoPriority(pid: i32, class: u32, level: u32) sys.Error!void {
    if (class > 3 or level > 7) return error.Invalid;
    const value: usize = (@as(usize, class) << 13) | level;
    _ = try sys.check(linux.syscall3(.ioprio_set, 1, @as(usize, @bitCast(@as(isize, pid))), value));
}

pub fn getIoPriority(pid: i32, class: *u32, level: *u32) sys.Error!void {
    const rc = try sys.check(linux.syscall2(.ioprio_get, 1, @as(usize, @bitCast(@as(isize, pid)))));
    class.* = @intCast((rc >> 13) & 7);
    level.* = @intCast(rc & 0x1fff);
}

pub const Socket = extern struct {
    family: u8,
    protocol: u8,
    state: u8,
    pad: u8 = 0,
    local_port: u16,
    remote_port: u16,
    local: [46]u8,
    remote: [46]u8,
    uid: u32,
    pid: i32,
    inode: u64,
    bytes_sent: u64,
    bytes_received: u64,
    bytes_acked: u64,
};

pub const SocketList = struct {
    items: std.ArrayList(Socket) = .empty,

    pub fn deinit(self: *SocketList) void {
        self.items.deinit(sys.gpa);
    }
};

const NETLINK_SOCK_DIAG = 4;
const SOCK_DIAG_BY_FAMILY = 20;
const INET_DIAG_INFO = 2;
const NLMSG_DONE = 3;
const NLMSG_ERROR = 2;

const DiagRequest = extern struct {
    len: u32,
    kind: u16,
    flags: u16,
    seq: u32,
    pid: u32,
    family: u8,
    protocol: u8,
    ext: u8,
    pad: u8,
    states: u32,
    sport: u16,
    dport: u16,
    src: [4]u32,
    dst: [4]u32,
    iface: u32,
    cookie: [2]u32,
};

fn formatAddr(out: *[46]u8, family: u8, raw: []const u8) void {
    @memset(out, 0);
    if (family == linux.AF.INET) {
        _ = std.fmt.bufPrint(out[0..45], "{d}.{d}.{d}.{d}", .{ raw[0], raw[1], raw[2], raw[3] }) catch {};
        return;
    }
    var w: usize = 0;
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        const word = (@as(u16, raw[i]) << 8) | raw[i + 1];
        const s = std.fmt.bufPrint(out[w..45], "{s}{x}", .{ if (i == 0) "" else ":", word }) catch return;
        w += s.len;
    }
}

fn query(result: *SocketList, family: u8, protocol: u8) !void {
    const fd_rc = linux.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, NETLINK_SOCK_DIAG);
    const fd: i32 = @intCast(try sys.check(fd_rc));
    defer sys.close(fd);
    var req = std.mem.zeroes(DiagRequest);
    req.len = @sizeOf(DiagRequest);
    req.kind = SOCK_DIAG_BY_FAMILY;
    req.flags = linux.NLM_F_REQUEST | linux.NLM_F_DUMP;
    req.seq = 1;
    req.family = family;
    req.protocol = protocol;
    req.ext = 1 << (INET_DIAG_INFO - 1);
    req.states = 0xffffffff;
    _ = try sys.write(fd, std.mem.asBytes(&req));
    var buf: [32768]u8 align(4) = undefined;
    while (true) {
        const n = try sys.read(fd, &buf);
        if (n == 0) return;
        var off: usize = 0;
        while (off + 16 <= n) {
            const len = std.mem.readInt(u32, buf[off..][0..4], .little);
            const kind = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
            if (len < 16 or off + len > n) return;
            if (kind == NLMSG_DONE) return;
            if (kind == NLMSG_ERROR) return error.Io;
            parseDiag(result, buf[off + 16 .. off + len], protocol) catch {};
            off += std.mem.alignForward(usize, len, 4);
        }
    }
}

fn parseDiag(result: *SocketList, msg: []const u8, protocol: u8) !void {
    if (msg.len < 72) return;
    var s = std.mem.zeroes(Socket);
    s.family = msg[0];
    s.state = msg[1];
    s.protocol = protocol;
    s.local_port = std.mem.readInt(u16, msg[4..6], .big);
    s.remote_port = std.mem.readInt(u16, msg[6..8], .big);
    formatAddr(&s.local, s.family, msg[8..24]);
    formatAddr(&s.remote, s.family, msg[24..40]);
    s.uid = std.mem.readInt(u32, msg[64..68], .little);
    s.inode = std.mem.readInt(u32, msg[68..72], .little);
    s.pid = -1;
    var off: usize = 72;
    while (off + 4 <= msg.len) {
        const alen = std.mem.readInt(u16, msg[off..][0..2], .little);
        const atype = std.mem.readInt(u16, msg[off + 2 ..][0..2], .little);
        if (alen < 4 or off + alen > msg.len) break;
        const payload = msg[off + 4 .. off + alen];
        if (atype == INET_DIAG_INFO) {
            if (payload.len >= 136) {
                s.bytes_acked = std.mem.readInt(u64, payload[120..128], .little);
                s.bytes_received = std.mem.readInt(u64, payload[128..136], .little);
            }
            s.bytes_sent = if (payload.len >= 208) std.mem.readInt(u64, payload[200..208], .little) else s.bytes_acked;
        }
        off += std.mem.alignForward(usize, alen, 4);
    }
    try result.items.append(sys.gpa, s);
}

fn mapOwners(result: *SocketList, root: [*:0]const u8) void {
    if (result.items.items.len == 0) return;
    var procs = sys.Dir.open(root) catch return;
    defer procs.close();
    while (procs.next() catch null) |entry| {
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        var path: [96]u8 = undefined;
        const p = sys.pathZ(&path, "{s}/{d}/fd", .{ std.mem.span(root), pid }) catch continue;
        var fds = sys.Dir.open(p) catch continue;
        defer fds.close();
        while (fds.next() catch null) |fdent| {
            var link_path: [128]u8 = undefined;
            const lp = sys.pathZ(&link_path, "{s}/{s}", .{ std.mem.span(p), fdent.name }) catch continue;
            var target: [64]u8 = undefined;
            const rc = linux.readlink(lp, &target, target.len);
            if (linux.errno(rc) != .SUCCESS) continue;
            const t = target[0..rc];
            if (!std.mem.startsWith(u8, t, "socket:[")) continue;
            const inode = std.fmt.parseInt(u64, t[8 .. t.len - 1], 10) catch continue;
            for (result.items.items) |*s| {
                if (s.inode == inode and s.pid < 0) s.pid = pid;
            }
        }
    }
}

pub fn sockets(root: [*:0]const u8, tcp: bool, udp: bool) !*SocketList {
    const result = try sys.gpa.create(SocketList);
    result.* = .{};
    errdefer {
        result.deinit();
        sys.gpa.destroy(result);
    }
    if (tcp) {
        try query(result, linux.AF.INET, linux.IPPROTO.TCP);
        query(result, linux.AF.INET6, linux.IPPROTO.TCP) catch {};
    }
    if (udp) {
        try query(result, linux.AF.INET, linux.IPPROTO.UDP);
        query(result, linux.AF.INET6, linux.IPPROTO.UDP) catch {};
    }
    mapOwners(result, root);
    return result;
}

test "stat with spaces and parens in the name" {
    var p = std.mem.zeroes(Process);
    const line = "4242 (a (b) c) S 1 4242 4242 0 -1 4194560 100 0 0 0 7 3 0 0 20 5 9 0 1234 10485760 300 18446744073709551615";
    try std.testing.expect(parseStat(line, &p));
    try std.testing.expectEqual(@as(i32, 4242), p.pid);
    try std.testing.expectEqualStrings("a (b) c", std.mem.sliceTo(&p.name, 0));
    try std.testing.expectEqual(@as(u8, 'S'), p.state);
    try std.testing.expectEqual(@as(i32, 1), p.ppid);
    try std.testing.expectEqual(@as(u64, 7), p.utime_ticks);
    try std.testing.expectEqual(@as(u64, 3), p.stime_ticks);
    try std.testing.expectEqual(@as(i32, 5), p.nice);
    try std.testing.expectEqual(@as(u32, 9), p.threads);
    try std.testing.expectEqual(@as(u64, 1234), p.start_ticks);
    try std.testing.expectEqual(@as(u64, 300 * pageSize()), p.rss_bytes);
}

test "own process and priority" {
    const self_pid: i32 = @intCast(linux.getpid());
    var p: Process = undefined;
    try read(self_pid, &p, true);
    defer if (p.cmdline) |c| sys.gpa.free(std.mem.span(c));
    try std.testing.expectEqual(self_pid, p.pid);
    try std.testing.expect(p.threads >= 1);
    const before = try getNice(0);
    try setNice(0, @min(before + 1, 19));
    try std.testing.expectEqual(@min(before + 1, 19), try getNice(0));
    var class: u32 = 0;
    var level: u32 = 0;
    try setIoPriority(0, 3, 0);
    try getIoPriority(0, &class, &level);
    try std.testing.expectEqual(@as(u32, 3), class);
    try std.testing.expectError(error.Invalid, setNice(0, 40));
    try std.testing.expectError(error.Invalid, signal(0, 0));
}

test "address formatting" {
    var out: [46]u8 = undefined;
    formatAddr(&out, linux.AF.INET, &[_]u8{ 127, 0, 0, 1 } ++ [_]u8{0} ** 12);
    try std.testing.expectEqualStrings("127.0.0.1", std.mem.sliceTo(&out, 0));
    formatAddr(&out, linux.AF.INET6, &[_]u8{ 0x20, 0x01, 0x0d, 0xb8 } ++ [_]u8{0} ** 11 ++ [_]u8{1});
    try std.testing.expectEqualStrings("2001:db8:0:0:0:0:0:1", std.mem.sliceTo(&out, 0));
}
