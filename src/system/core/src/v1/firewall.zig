const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

const NETLINK_NETFILTER = 12;
const NFNL_SUBSYS_NFTABLES: u16 = 10;
const NFNL_MSG_BATCH_BEGIN: u16 = 0x10;
const NFNL_MSG_BATCH_END: u16 = 0x11;
const NFT_MSG_NEWTABLE: u16 = 0;
const NFT_MSG_GETTABLE: u16 = 1;
const NFT_MSG_DELTABLE: u16 = 2;
const NFT_MSG_NEWCHAIN: u16 = 3;
const NFT_MSG_GETCHAIN: u16 = 4;
const NFT_MSG_NEWRULE: u16 = 6;
const NFT_MSG_GETRULE: u16 = 7;
const NFPROTO_INET: u8 = 1;

const F_REQUEST: u16 = 0x1;
const F_ACK: u16 = 0x4;
const F_EXCL: u16 = 0x200;
const F_CREATE: u16 = 0x400;
const F_APPEND: u16 = 0x800;
const F_DUMP: u16 = 0x300;
const NLMSG_ERROR: u16 = 2;
const NLMSG_DONE: u16 = 3;
const NLA_F_NESTED: u16 = 0x8000;

const NF_DROP: u32 = 0;
const NF_ACCEPT: u32 = 1;
const NF_INET_LOCAL_IN: u32 = 1;
const REG_VERDICT: u32 = 0;
const REG_1: u32 = 1;

const CMP_EQ: u32 = 0;
const CMP_NEQ: u32 = 1;
const CMP_LTE: u32 = 3;
const CMP_GTE: u32 = 5;

const CT_STATE_INVALID: u32 = 1;
const CT_STATE_ESTABLISHED: u32 = 2;
const CT_STATE_RELATED: u32 = 4;

pub const table_name = "singularity_firewall";
pub const chain_name = "input";

pub const Protocol = enum(u8) { tcp = 6, udp = 17 };

pub const Port = struct { protocol: Protocol, first: u16, last: u16, comment: []const u8 };

pub const Ruleset = struct {
    enabled: bool,
    public_profile: bool,
    ports: []const Port,
};

const Builder = struct {
    buf: std.ArrayList(u8) = .empty,
    seq: u32 = 1,
    msg_start: usize = 0,
    nests: [8]usize = undefined,
    depth: usize = 0,
    acked: u32 = 0,

    fn deinit(self: *Builder) void {
        self.buf.deinit(sys.gpa);
    }

    fn align4(self: *Builder) !void {
        while (self.buf.items.len % 4 != 0) try self.buf.append(sys.gpa, 0);
    }

    fn begin(self: *Builder, kind: u16, flags: u16, family: u8, res_id: u16) !void {
        try self.align4();
        self.msg_start = self.buf.items.len;
        var hdr: [16]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 0, .little);
        std.mem.writeInt(u16, hdr[4..6], kind, .little);
        std.mem.writeInt(u16, hdr[6..8], flags, .little);
        std.mem.writeInt(u32, hdr[8..12], self.seq, .little);
        std.mem.writeInt(u32, hdr[12..16], 0, .little);
        self.seq += 1;
        if (flags & F_ACK != 0) self.acked += 1;
        try self.buf.appendSlice(sys.gpa, &hdr);
        try self.buf.appendSlice(sys.gpa, &.{ family, 0 });
        var r: [2]u8 = undefined;
        std.mem.writeInt(u16, &r, res_id, .big);
        try self.buf.appendSlice(sys.gpa, &r);
    }

    fn end(self: *Builder) void {
        const len: u32 = @intCast(self.buf.items.len - self.msg_start);
        std.mem.writeInt(u32, self.buf.items[self.msg_start..][0..4], len, .little);
    }

    fn nft(self: *Builder, msg: u16, flags: u16) !void {
        try self.begin((NFNL_SUBSYS_NFTABLES << 8) | msg, F_REQUEST | flags, NFPROTO_INET, 0);
    }

    fn attr(self: *Builder, kind: u16, bytes: []const u8) !void {
        try self.align4();
        var h: [4]u8 = undefined;
        std.mem.writeInt(u16, h[0..2], @intCast(4 + bytes.len), .little);
        std.mem.writeInt(u16, h[2..4], kind, .little);
        try self.buf.appendSlice(sys.gpa, &h);
        try self.buf.appendSlice(sys.gpa, bytes);
    }

    fn str(self: *Builder, kind: u16, s: []const u8) !void {
        try self.align4();
        var h: [4]u8 = undefined;
        std.mem.writeInt(u16, h[0..2], @intCast(4 + s.len + 1), .little);
        std.mem.writeInt(u16, h[2..4], kind, .little);
        try self.buf.appendSlice(sys.gpa, &h);
        try self.buf.appendSlice(sys.gpa, s);
        try self.buf.append(sys.gpa, 0);
    }

    fn be32(self: *Builder, kind: u16, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try self.attr(kind, &b);
    }

    fn open(self: *Builder, kind: u16) !void {
        try self.align4();
        self.nests[self.depth] = self.buf.items.len;
        self.depth += 1;
        try self.attr(kind | NLA_F_NESTED, &.{});
    }

    fn close(self: *Builder) void {
        self.depth -= 1;
        const at = self.nests[self.depth];
        std.mem.writeInt(u16, self.buf.items[at..][0..2], @intCast(self.buf.items.len - at), .little);
    }

    fn expr(self: *Builder, name: []const u8) !void {
        try self.open(1);
        try self.str(1, name);
        try self.open(2);
    }

    fn exprEnd(self: *Builder) void {
        self.close();
        self.close();
    }

    fn data(self: *Builder, kind: u16, value: []const u8) !void {
        try self.open(kind);
        try self.attr(1, value);
        self.close();
    }

    fn ctState(self: *Builder) !void {
        try self.expr("ct");
        try self.be32(1, REG_1);
        try self.be32(2, 0);
        self.exprEnd();
    }

    fn bitwise(self: *Builder, mask: u32) !void {
        try self.expr("bitwise");
        try self.be32(1, REG_1);
        try self.be32(2, REG_1);
        try self.be32(3, 4);
        var m: [4]u8 = undefined;
        std.mem.writeInt(u32, &m, mask, .native);
        try self.data(4, &m);
        try self.data(5, &.{ 0, 0, 0, 0 });
        self.exprEnd();
    }

    fn cmp(self: *Builder, op: u32, value: []const u8) !void {
        try self.expr("cmp");
        try self.be32(1, REG_1);
        try self.be32(2, op);
        try self.data(3, value);
        self.exprEnd();
    }

    fn meta(self: *Builder, key: u32) !void {
        try self.expr("meta");
        try self.be32(1, REG_1);
        try self.be32(2, key);
        self.exprEnd();
    }

    fn payload(self: *Builder, base: u32, offset: u32, len: u32) !void {
        try self.expr("payload");
        try self.be32(1, REG_1);
        try self.be32(2, base);
        try self.be32(3, offset);
        try self.be32(4, len);
        self.exprEnd();
    }

    fn verdict(self: *Builder, code: u32) !void {
        try self.expr("immediate");
        try self.be32(1, REG_VERDICT);
        try self.open(2);
        try self.open(2);
        try self.be32(1, code);
        self.close();
        self.close();
        self.exprEnd();
    }

    fn ruleBegin(self: *Builder) !void {
        try self.nft(NFT_MSG_NEWRULE, F_CREATE | F_APPEND | F_ACK);
        try self.str(1, table_name);
        try self.str(2, chain_name);
        try self.open(4);
    }

    fn ruleEnd(self: *Builder, comment: []const u8) !void {
        self.close();
        if (comment.len > 0) {
            var ud: [260]u8 = undefined;
            const n = @min(comment.len, 250);
            ud[0] = 0;
            ud[1] = @intCast(n + 1);
            @memcpy(ud[2..][0..n], comment[0..n]);
            ud[2 + n] = 0;
            try self.attr(7, ud[0 .. 3 + n]);
        }
        self.end();
    }
};

const META_IIFNAME: u32 = 6;
const META_L4PROTO: u32 = 16;
const PAYLOAD_TRANSPORT: u32 = 2;

fn l4(b: *Builder, proto: u8) !void {
    try b.meta(META_L4PROTO);
    try b.cmp(CMP_EQ, &.{proto});
}

fn dport(b: *Builder, first: u16, last: u16) !void {
    try b.payload(PAYLOAD_TRANSPORT, 2, 2);
    var f: [2]u8 = undefined;
    std.mem.writeInt(u16, &f, first, .big);
    if (first == last) return b.cmp(CMP_EQ, &f);
    var l: [2]u8 = undefined;
    std.mem.writeInt(u16, &l, last, .big);
    try b.cmp(CMP_GTE, &f);
    try b.cmp(CMP_LTE, &l);
}

pub fn build(b: *Builder, rs: Ruleset) !void {
    try b.begin(NFNL_MSG_BATCH_BEGIN, F_REQUEST, 0, NFNL_SUBSYS_NFTABLES);
    b.end();
    try b.nft(NFT_MSG_NEWTABLE, F_CREATE | F_ACK);
    try b.str(1, table_name);
    b.end();
    try b.nft(NFT_MSG_DELTABLE, F_ACK);
    try b.str(1, table_name);
    b.end();
    if (rs.enabled) {
        try b.nft(NFT_MSG_NEWTABLE, F_CREATE | F_EXCL | F_ACK);
        try b.str(1, table_name);
        b.end();
        try b.nft(NFT_MSG_NEWCHAIN, F_CREATE | F_ACK);
        try b.str(1, table_name);
        try b.str(3, chain_name);
        try b.open(4);
        try b.be32(1, NF_INET_LOCAL_IN);
        try b.be32(2, 0);
        b.close();
        try b.be32(5, NF_DROP);
        try b.str(7, "filter");
        b.end();

        try b.ruleBegin();
        try b.ctState();
        try b.bitwise(CT_STATE_ESTABLISHED | CT_STATE_RELATED);
        try b.cmp(CMP_NEQ, &.{ 0, 0, 0, 0 });
        try b.verdict(NF_ACCEPT);
        try b.ruleEnd("");

        try b.ruleBegin();
        try b.ctState();
        try b.bitwise(CT_STATE_INVALID);
        try b.cmp(CMP_NEQ, &.{ 0, 0, 0, 0 });
        try b.verdict(NF_DROP);
        try b.ruleEnd("");

        try b.ruleBegin();
        try b.meta(META_IIFNAME);
        var lo = [_]u8{0} ** 16;
        lo[0] = 'l';
        lo[1] = 'o';
        try b.cmp(CMP_EQ, &lo);
        try b.verdict(NF_ACCEPT);
        try b.ruleEnd("");

        for ([_]u8{ 1, 58 }) |icmp| {
            try b.ruleBegin();
            try l4(b, icmp);
            try b.verdict(NF_ACCEPT);
            try b.ruleEnd("");
        }

        for ([_]u16{ 68, 546 }) |p| {
            try b.ruleBegin();
            try l4(b, 17);
            try dport(b, p, p);
            try b.verdict(NF_ACCEPT);
            try b.ruleEnd("");
        }

        if (!rs.public_profile) {
            try b.ruleBegin();
            try l4(b, 17);
            try dport(b, 5353, 5353);
            try b.verdict(NF_ACCEPT);
            try b.ruleEnd("mDNS");
        }

        for (rs.ports) |p| {
            if (p.first == 0 or p.last < p.first) return error.Invalid;
            try b.ruleBegin();
            try l4(b, @intFromEnum(p.protocol));
            try dport(b, p.first, p.last);
            try b.verdict(NF_ACCEPT);
            try b.ruleEnd(p.comment);
        }
    }
    try b.begin(NFNL_MSG_BATCH_END, F_REQUEST, 0, NFNL_SUBSYS_NFTABLES);
    b.end();
}

fn openSocket() !i32 {
    const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, NETLINK_NETFILTER)));
    errdefer sys.close(fd);
    var addr = linux.sockaddr.nl{ .pid = 0, .groups = 0 };
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)));
    return fd;
}

fn send(fd: i32, bytes: []const u8) !void {
    var addr = linux.sockaddr.nl{ .pid = 0, .groups = 0 };
    const rc = linux.sendto(fd, bytes.ptr, bytes.len, 0, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl));
    const n = try sys.check(rc);
    if (n != bytes.len) return error.Io;
}

pub fn apply(rs: Ruleset) !void {
    var b = Builder{};
    defer b.deinit();
    try build(&b, rs);
    const fd = try openSocket();
    defer sys.close(fd);
    try send(fd, b.buf.items);
    var pending = b.acked;
    var buf: [16384]u8 align(4) = undefined;
    var failure: ?anyerror = null;
    while (pending > 0) {
        const n = try sys.read(fd, &buf);
        if (n == 0) return error.Io;
        var off: usize = 0;
        while (off + 16 <= n) {
            const len = std.mem.readInt(u32, buf[off..][0..4], .little);
            const kind = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
            if (len < 16 or off + len > n) break;
            if (kind == NLMSG_ERROR and len >= 20) {
                const err = std.mem.readInt(i32, buf[off + 16 ..][0..4], .little);
                if (err != 0 and failure == null) failure = sys.fromErrno(@enumFromInt(@as(u16, @intCast(-err))));
                pending -= 1;
                if (err != 0) pending = 0;
            }
            off += std.mem.alignForward(usize, len, 4);
        }
    }
    if (failure) |e| return e;
}

pub const Summary = extern struct {
    table_present: u8,
    chain_present: u8,
    chain_policy_drop: u8,
    pad: u8 = 0,
    rules: u32,
    comments: [16][64]u8,
};

fn dump(fd: i32, msg: u16, with_table: bool, ctx: anytype, comptime onMsg: fn (@TypeOf(ctx), []const u8) void) !void {
    var b = Builder{};
    defer b.deinit();
    try b.begin((NFNL_SUBSYS_NFTABLES << 8) | msg, F_REQUEST | F_DUMP | F_ACK, NFPROTO_INET, 0);
    if (with_table) try b.str(1, table_name);
    b.end();
    try send(fd, b.buf.items);
    var buf: [65536]u8 align(4) = undefined;
    while (true) {
        const n = try sys.read(fd, &buf);
        if (n == 0) return error.Io;
        var off: usize = 0;
        while (off + 16 <= n) {
            const len = std.mem.readInt(u32, buf[off..][0..4], .little);
            const kind = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
            if (len < 16 or off + len > n) return error.Io;
            if (kind == NLMSG_DONE) return;
            if (kind == NLMSG_ERROR) {
                const err = std.mem.readInt(i32, buf[off + 16 ..][0..4], .little);
                if (err != 0) return sys.fromErrno(@enumFromInt(@as(u16, @intCast(-err))));
                return;
            }
            if (len > 20) onMsg(ctx, buf[off + 20 .. off + len]);
            off += std.mem.alignForward(usize, len, 4);
        }
    }
}

const Attr = struct { kind: u16, data: []const u8 };

fn attrs(payload: []const u8, kind: u16) ?[]const u8 {
    var off: usize = 0;
    while (off + 4 <= payload.len) {
        const len = std.mem.readInt(u16, payload[off..][0..2], .little);
        const k = std.mem.readInt(u16, payload[off + 2 ..][0..2], .little) & 0x3fff;
        if (len < 4 or off + len > payload.len) return null;
        if (k == kind) return payload[off + 4 .. off + len];
        off += std.mem.alignForward(usize, len, 4);
    }
    return null;
}

fn isOurs(payload: []const u8) bool {
    const t = attrs(payload, 1) orelse return false;
    return std.mem.eql(u8, std.mem.sliceTo(t, 0), table_name);
}

pub fn summary(out: *Summary) !void {
    out.* = std.mem.zeroes(Summary);
    const fd = try openSocket();
    defer sys.close(fd);
    try dump(fd, NFT_MSG_GETTABLE, false, out, struct {
        fn f(s: *Summary, p: []const u8) void {
            if (isOurs(p)) s.table_present = 1;
        }
    }.f);
    if (out.table_present == 0) return;
    try dump(fd, NFT_MSG_GETCHAIN, false, out, struct {
        fn f(s: *Summary, p: []const u8) void {
            if (!isOurs(p)) return;
            const name = attrs(p, 3) orelse return;
            if (!std.mem.eql(u8, std.mem.sliceTo(name, 0), chain_name)) return;
            s.chain_present = 1;
            if (attrs(p, 5)) |pol| {
                if (pol.len >= 4 and std.mem.readInt(u32, pol[0..4], .big) == NF_DROP) s.chain_policy_drop = 1;
            }
        }
    }.f);
    try dump(fd, NFT_MSG_GETRULE, true, out, struct {
        fn f(s: *Summary, p: []const u8) void {
            if (!isOurs(p)) return;
            if (s.rules < s.comments.len) {
                if (attrs(p, 7)) |ud| {
                    if (ud.len > 2 and ud[0] == 0) {
                        const n = @min(@as(usize, ud[1]), ud.len - 2);
                        sys.copyName(&s.comments[s.rules], std.mem.sliceTo(ud[2 .. 2 + n], 0));
                    }
                }
            }
            s.rules += 1;
        }
    }.f);
}

pub fn parsePorts(spec: []const u8, comment: []const u8, out: []Port) !usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |item| {
        if (n == out.len) return error.TooBig;
        const slash = std.mem.indexOfScalar(u8, item, '/') orelse return error.Invalid;
        const proto: Protocol = if (std.mem.eql(u8, item[slash + 1 ..], "tcp")) .tcp else if (std.mem.eql(u8, item[slash + 1 ..], "udp")) .udp else return error.Invalid;
        const range = item[0..slash];
        var first: u16 = 0;
        var last: u16 = 0;
        if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
            first = std.fmt.parseInt(u16, range[0..dash], 10) catch return error.Invalid;
            last = std.fmt.parseInt(u16, range[dash + 1 ..], 10) catch return error.Invalid;
        } else {
            first = std.fmt.parseInt(u16, range, 10) catch return error.Invalid;
            last = first;
        }
        if (first == 0 or last < first) return error.Invalid;
        out[n] = .{ .protocol = proto, .first = first, .last = last, .comment = comment };
        n += 1;
    }
    if (n == 0) return error.Invalid;
    return n;
}

test "port specs" {
    var ports: [8]Port = undefined;
    const n = try parsePorts("22/tcp,8000-8010/tcp,5353/udp", "Test", &ports);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u16, 8010), ports[1].last);
    try std.testing.expectEqual(Protocol.udp, ports[2].protocol);
    try std.testing.expectError(error.Invalid, parsePorts("0/tcp", "", &ports));
    try std.testing.expectError(error.Invalid, parsePorts("80", "", &ports));
    try std.testing.expectError(error.Invalid, parsePorts("90-80/tcp", "", &ports));
    try std.testing.expectError(error.Invalid, parsePorts("80/sctp", "", &ports));
}

test "the batch is well formed" {
    var b = Builder{};
    defer b.deinit();
    const ports = [_]Port{.{ .protocol = .tcp, .first = 22, .last = 22, .comment = "SSH" }};
    try build(&b, .{ .enabled = true, .public_profile = false, .ports = &ports });
    var off: usize = 0;
    var count: usize = 0;
    while (off < b.buf.items.len) {
        const len = std.mem.readInt(u32, b.buf.items[off..][0..4], .little);
        try std.testing.expect(len >= 20);
        off += std.mem.alignForward(usize, len, 4);
        count += 1;
    }
    try std.testing.expectEqual(b.buf.items.len, off);
    try std.testing.expectEqual(@as(usize, 2 + 4 + 7 + 1 + 1), count);
}

test "apply and read back in a private network namespace" {
    if (std.c.getenv("SINTY_SYSTEM_NETNS_TEST") == null) return error.SkipZigTest;
    const ports = [_]Port{
        .{ .protocol = .tcp, .first = 22, .last = 22, .comment = "SSH" },
        .{ .protocol = .tcp, .first = 8000, .last = 8010, .comment = "Web Preview" },
    };
    try apply(.{ .enabled = true, .public_profile = false, .ports = &ports });
    var s: Summary = undefined;
    try summary(&s);
    try std.testing.expectEqual(@as(u8, 1), s.table_present);
    try std.testing.expectEqual(@as(u8, 1), s.chain_present);
    try std.testing.expectEqual(@as(u8, 1), s.chain_policy_drop);
    try std.testing.expectEqual(@as(u32, 10), s.rules);
    try std.testing.expectEqualStrings("mDNS", sys.cstr(&s.comments[7]));
    try std.testing.expectEqualStrings("SSH", sys.cstr(&s.comments[8]));
    try std.testing.expectEqualStrings("Web Preview", sys.cstr(&s.comments[9]));
    try apply(.{ .enabled = true, .public_profile = true, .ports = ports[0..1] });
    try summary(&s);
    try std.testing.expectEqual(@as(u32, 8), s.rules);
    try apply(.{ .enabled = false, .public_profile = false, .ports = &.{} });
    try summary(&s);
    try std.testing.expectEqual(@as(u8, 0), s.table_present);
}
