const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const nl = @import("nl.zig");

const SIOCETHTOOL: u32 = 0x8946;
const ETHTOOL_GLINKSETTINGS: u32 = 0x4c;
const header_size = 48;
const max_words = 32;

pub const LinkInfo = extern struct {
    speed_mbps: i32,
    max_supported_mbps: i32,
    duplex: i32,
    autoneg: i32,
    port: i32,
    pad: i32 = 0,
    supported: [max_words]u32,
    words: u32,
    pad2: u32 = 0,
};

const base_t_modes = [_]struct { bit: u16, mbps: i32 }{
    .{ .bit = 0, .mbps = 10 },
    .{ .bit = 1, .mbps = 10 },
    .{ .bit = 2, .mbps = 100 },
    .{ .bit = 3, .mbps = 100 },
    .{ .bit = 4, .mbps = 1000 },
    .{ .bit = 5, .mbps = 1000 },
    .{ .bit = 12, .mbps = 10000 },
    .{ .bit = 47, .mbps = 2500 },
    .{ .bit = 48, .mbps = 5000 },
    .{ .bit = 67, .mbps = 100 },
    .{ .bit = 68, .mbps = 1000 },
};

pub fn maxBaseT(words: []const u32) i32 {
    var best: i32 = -1;
    for (base_t_modes) |m| {
        const w = m.bit / 32;
        if (w >= words.len) continue;
        if (words[w] & (@as(u32, 1) << @intCast(m.bit % 32)) != 0 and m.mbps > best) best = m.mbps;
    }
    return best;
}

const IfReq = extern struct {
    name: [16]u8,
    data: usize,
    pad: [16]u8 = [_]u8{0} ** 16,
};

fn ethtool(fd: i32, iface: []const u8, buf: []u8) !void {
    var req = IfReq{ .name = [_]u8{0} ** 16, .data = @intFromPtr(buf.ptr) };
    if (iface.len == 0 or iface.len >= req.name.len) return error.Invalid;
    @memcpy(req.name[0..iface.len], iface);
    _ = try sys.ioctl(fd, SIOCETHTOOL, @intFromPtr(&req));
}

pub fn decode(buf: []const u8, info: *LinkInfo) !void {
    const words_raw: i8 = @bitCast(buf[15]);
    if (words_raw <= 0) return error.Invalid;
    const words: usize = @intCast(words_raw);
    if (words > max_words or header_size + words * 4 > buf.len) return error.TooBig;
    info.* = std.mem.zeroes(LinkInfo);
    const speed = std.mem.readInt(u32, buf[4..8], .little);
    info.speed_mbps = if (speed == 0xffffffff or speed == 0) -1 else @intCast(speed);
    info.duplex = if (buf[8] == 0xff) -1 else buf[8];
    info.port = buf[9];
    info.autoneg = buf[11];
    info.words = @intCast(words);
    for (0..words) |i| info.supported[i] = std.mem.readInt(u32, buf[header_size + i * 4 ..][0..4], .little);
    info.max_supported_mbps = maxBaseT(info.supported[0..words]);
}

pub fn linkInfo(iface: []const u8, info: *LinkInfo) !void {
    const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)));
    defer sys.close(fd);
    var buf: [header_size + 3 * max_words * 4]u8 align(8) = [_]u8{0} ** (header_size + 3 * max_words * 4);
    std.mem.writeInt(u32, buf[0..4], ETHTOOL_GLINKSETTINGS, .little);
    try ethtool(fd, iface, &buf);
    const neg: i8 = @bitCast(buf[15]);
    if (neg >= 0) return error.Unsupported;
    const words: i8 = -neg;
    if (@as(usize, @intCast(words)) > max_words) return error.TooBig;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], ETHTOOL_GLINKSETTINGS, .little);
    buf[15] = @bitCast(words);
    try ethtool(fd, iface, &buf);
    try decode(&buf, info);
}

test "highest base-T mode wins" {
    var words = [_]u32{ 0, 0, 0 };
    words[0] = (1 << 3) | (1 << 5);
    try std.testing.expectEqual(@as(i32, 1000), maxBaseT(&words));
    words[1] = 1 << (47 - 32);
    try std.testing.expectEqual(@as(i32, 2500), maxBaseT(&words));
    words[0] |= 1 << 12;
    try std.testing.expectEqual(@as(i32, 10000), maxBaseT(&words));
    try std.testing.expectEqual(@as(i32, -1), maxBaseT(&[_]u32{ 1 << 15, 0 }));
}

test "decode a link settings reply" {
    var buf = [_]u8{0} ** (header_size + 12);
    std.mem.writeInt(u32, buf[4..8], 2500, .little);
    buf[8] = 1;
    buf[11] = 1;
    buf[15] = 3;
    std.mem.writeInt(u32, buf[header_size..][0..4], (1 << 5), .little);
    std.mem.writeInt(u32, buf[header_size + 4 ..][0..4], 1 << (47 - 32), .little);
    var info: LinkInfo = undefined;
    try decode(&buf, &info);
    try std.testing.expectEqual(@as(i32, 2500), info.speed_mbps);
    try std.testing.expectEqual(@as(i32, 2500), info.max_supported_mbps);
    try std.testing.expectEqual(@as(u32, 3), info.words);
    try std.testing.expectEqual(@as(i32, 1), info.autoneg);
}

test "loopback has no ethtool link settings" {
    var info: LinkInfo = undefined;
    if (linkInfo("lo", &info)) |_| {} else |e| try std.testing.expect(e == error.Unsupported or e == error.Invalid);
}

pub const Ip = struct {
    family: u8,
    bytes: [16]u8 = [_]u8{0} ** 16,

    pub fn len(self: Ip) usize {
        return if (self.family == linux.AF.INET) 4 else 16;
    }

    pub fn slice(self: *const Ip) []const u8 {
        return self.bytes[0..self.len()];
    }
};

pub const Cidr = struct { ip: Ip, prefix: u8 };

fn parse4(t: []const u8, out: *[16]u8) bool {
    var it = std.mem.splitScalar(u8, t, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == 4 or part.len == 0 or part.len > 3) return false;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return i == 4;
}

fn parse6(t: []const u8, out: *[16]u8) bool {
    var words: [8]u16 = undefined;
    var head: usize = 0;
    var tail: [8]u16 = undefined;
    var tail_n: usize = 0;
    var gap = false;
    const dbl = std.mem.indexOf(u8, t, "::");
    const parts = [2][]const u8{ if (dbl) |d| t[0..d] else t, if (dbl) |d| t[d + 2 ..] else "" };
    if (dbl) |d| {
        gap = true;
        if (std.mem.indexOf(u8, t[d + 2 ..], "::") != null) return false;
    }
    for (parts, 0..) |part, pi| {
        if (part.len == 0) continue;
        var it = std.mem.splitScalar(u8, part, ':');
        while (it.next()) |g| {
            const dst: *[8]u16 = if (pi == 0) &words else &tail;
            const n: *usize = if (pi == 0) &head else &tail_n;
            if (std.mem.indexOfScalar(u8, g, '.') != null) {
                if (it.peek() != null) return false;
                var v4: [16]u8 = undefined;
                if (!parse4(g, &v4) or n.* + 2 > 8) return false;
                dst[n.*] = @as(u16, v4[0]) << 8 | v4[1];
                dst[n.* + 1] = @as(u16, v4[2]) << 8 | v4[3];
                n.* += 2;
                continue;
            }
            if (g.len == 0 or g.len > 4 or n.* == 8) return false;
            dst[n.*] = std.fmt.parseInt(u16, g, 16) catch return false;
            n.* += 1;
        }
    }
    if (gap) {
        if (head + tail_n > 7) return false;
    } else if (head != 8) return false;
    var all = [_]u16{0} ** 8;
    @memcpy(all[0..head], words[0..head]);
    @memcpy(all[8 - tail_n ..], tail[0..tail_n]);
    for (all, 0..) |w, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], w, .big);
    return true;
}

pub fn parseIp(t: []const u8) !Ip {
    var ip = Ip{ .family = linux.AF.INET };
    if (parse4(t, &ip.bytes)) return ip;
    ip = .{ .family = linux.AF.INET6 };
    if (parse6(t, &ip.bytes)) return ip;
    return error.Invalid;
}

pub fn parseCidr(t: []const u8) !Cidr {
    const slash = std.mem.indexOfScalar(u8, t, '/');
    const ip = try parseIp(std.mem.trim(u8, if (slash) |s| t[0..s] else t, " "));
    const max: u8 = @intCast(ip.len() * 8);
    const prefix = if (slash) |s| std.fmt.parseInt(u8, std.mem.trim(u8, t[s + 1 ..], " "), 10) catch return error.Invalid else max;
    if (prefix > max) return error.Invalid;
    return .{ .ip = ip, .prefix = prefix };
}

pub fn formatIp(buf: []u8, family: u8, bytes: []const u8) ![]const u8 {
    if (family == linux.AF.INET) {
        if (bytes.len < 4) return error.Invalid;
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }
    if (bytes.len < 16) return error.Invalid;
    var w: [8]u16 = undefined;
    for (&w, 0..) |*x, i| x.* = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .big);
    var best: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (w[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and w[j] == 0) j += 1;
        if (j - i > best_len) {
            best = i;
            best_len = j - i;
        }
        i = j;
    }
    if (best_len < 2) best_len = 0;
    var n: usize = 0;
    if (best_len > 0 and best == 0 and best_len == 5 and w[5] == 0xffff) {
        n += (try std.fmt.bufPrint(buf, "::ffff:{d}.{d}.{d}.{d}", .{ bytes[12], bytes[13], bytes[14], bytes[15] })).len;
        return buf[0..n];
    }
    i = 0;
    while (i < 8) {
        if (best_len > 0 and i == best) {
            n += (try std.fmt.bufPrint(buf[n..], "{s}", .{if (i == 0) "::" else ":"})).len;
            i += best_len;
            continue;
        }
        n += (try std.fmt.bufPrint(buf[n..], "{x}{s}", .{ w[i], if (i < 7) ":" else "" })).len;
        i += 1;
    }
    return buf[0..n];
}

fn putText(dst: []u8, s: []const u8) void {
    @memset(dst, 0);
    const n = @min(s.len, dst.len - 1);
    @memcpy(dst[0..n], s[0..n]);
}

const RTM_NEWLINK: u16 = 16;
const RTM_DELLINK: u16 = 17;
const RTM_GETLINK: u16 = 18;
const RTM_NEWADDR: u16 = 20;
const RTM_DELADDR: u16 = 21;
const RTM_GETADDR: u16 = 22;
const RTM_NEWROUTE: u16 = 24;
const RTM_DELROUTE: u16 = 25;
const RTM_GETROUTE: u16 = 26;

const IFLA_ADDRESS: u16 = 1;
const IFLA_IFNAME: u16 = 3;
const IFLA_MTU: u16 = 4;
const IFLA_OPERSTATE: u16 = 16;
const IFLA_LINKINFO: u16 = 18;
const IFLA_INFO_KIND: u16 = 1;
const IFLA_STATS64: u16 = 23;

const IFA_ADDRESS: u16 = 1;
const IFA_LOCAL: u16 = 2;

const RTA_DST: u16 = 1;
const RTA_OIF: u16 = 4;
const RTA_GATEWAY: u16 = 5;
const RTA_PRIORITY: u16 = 6;
const RTA_TABLE: u16 = 15;

pub const IFF_UP: u32 = 0x1;
pub const IFF_LOOPBACK: u32 = 0x8;
pub const IFF_RUNNING: u32 = 0x40;
pub const IFF_LOWER_UP: u32 = 0x10000;

pub const Link = extern struct {
    index: i32,
    flags: u32,
    mtu: u32,
    operstate: u8,
    wireless: u8,
    pad: [2]u8 = .{ 0, 0 },
    name: [16]u8,
    kind: [16]u8,
    mac: [24]u8,
    rx_bytes: u64,
    tx_bytes: u64,
};

pub const Address = extern struct {
    index: i32,
    family: u8,
    prefix: u8,
    scope: u8,
    flags: u8,
    address: [48]u8,
};

pub const Route = extern struct {
    oif: i32,
    family: u8,
    prefix: u8,
    table: u8,
    protocol: u8,
    scope: u8,
    kind: u8,
    pad: [2]u8 = .{ 0, 0 },
    priority: u32,
    destination: [48]u8,
    gateway: [48]u8,
};

fn macText(dst: []u8, b: []const u8) void {
    @memset(dst, 0);
    var n: usize = 0;
    for (b, 0..) |x, i| {
        if (n + 3 > dst.len) break;
        _ = std.fmt.bufPrint(dst[n..], "{x:0>2}", .{x}) catch break;
        n += 2;
        if (i + 1 < b.len) {
            dst[n] = ':';
            n += 1;
        }
    }
}

fn isWireless(name: []const u8) bool {
    var pb: [96]u8 = undefined;
    const p = sys.pathZ(&pb, "/sys/class/net/{s}/phy80211", .{name}) catch return false;
    return linux.faccessat(linux.AT.FDCWD, p, linux.F_OK, 0) == 0;
}

pub fn decodeLink(body: []const u8, out: *Link) !void {
    if (body.len < 16) return error.Io;
    out.* = std.mem.zeroes(Link);
    out.index = std.mem.readInt(i32, body[4..8], .little);
    out.flags = std.mem.readInt(u32, body[8..12], .little);
    const a = body[16..];
    putText(&out.name, nl.text(nl.find(a, IFLA_IFNAME)));
    out.mtu = nl.int(u32, nl.find(a, IFLA_MTU)) orelse 0;
    out.operstate = if (nl.find(a, IFLA_OPERSTATE)) |o| (if (o.len > 0) o[0] else 0) else 0;
    if (nl.find(a, IFLA_ADDRESS)) |m| macText(&out.mac, m[0..@min(m.len, 8)]);
    if (nl.find(a, IFLA_LINKINFO)) |li| putText(&out.kind, nl.text(nl.find(li, IFLA_INFO_KIND)));
    if (nl.find(a, IFLA_STATS64)) |st| if (st.len >= 32) {
        out.rx_bytes = std.mem.readInt(u64, st[16..24], .little);
        out.tx_bytes = std.mem.readInt(u64, st[24..32], .little);
    };
}

fn Collect(comptime T: type, comptime kind: u16, comptime decodeFn: fn ([]const u8, *T) anyerror!void) type {
    return struct {
        out: []T,
        n: usize = 0,
        fn f(self: *@This(), k: u16, body: []const u8) anyerror!void {
            if (k != kind) return;
            if (self.n == self.out.len) return error.TooBig;
            try decodeFn(body, &self.out[self.n]);
            self.n += 1;
        }
    };
}

pub fn links(out: []Link) !usize {
    var s = try nl.Socket.open(nl.ROUTE);
    defer s.close();
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(RTM_GETLINK, nl.F_DUMP, &[_]u8{0} ** 16);
    var c = Collect(Link, RTM_NEWLINK, decodeLink){ .out = out };
    try s.call(&b, &c, @TypeOf(c).f);
    for (out[0..c.n]) |*l| l.wireless = @intFromBool(isWireless(sys.cstr(&l.name)));
    return c.n;
}

pub fn link(name: []const u8, out: *Link) !void {
    if (name.len == 0 or name.len > 15) return error.Invalid;
    var s = try nl.Socket.open(nl.ROUTE);
    defer s.close();
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(RTM_GETLINK, 0, &[_]u8{0} ** 16);
    try b.str(IFLA_IFNAME, name);
    var one: [1]Link = undefined;
    var c = Collect(Link, RTM_NEWLINK, decodeLink){ .out = &one };
    try s.call(&b, &c, @TypeOf(c).f);
    if (c.n == 0) return error.NotFound;
    out.* = one[0];
    out.wireless = @intFromBool(isWireless(name));
}

pub fn index(name: []const u8) !i32 {
    var l: Link = undefined;
    try link(name, &l);
    return l.index;
}

fn ifinfo(idx: i32, flags: u32, change: u32) [16]u8 {
    var h = [_]u8{0} ** 16;
    std.mem.writeInt(i32, h[4..8], idx, .little);
    std.mem.writeInt(u32, h[8..12], flags, .little);
    std.mem.writeInt(u32, h[12..16], change, .little);
    return h;
}

fn route(b: *nl.Builder) !void {
    var s = try nl.Socket.open(nl.ROUTE);
    defer s.close();
    try s.exec(b);
}

pub fn setUp(name: []const u8, up: bool) !void {
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(RTM_NEWLINK, 0, &ifinfo(try index(name), if (up) IFF_UP else 0, IFF_UP));
    try route(&b);
}

pub fn setMtu(name: []const u8, mtu: u32) !void {
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(RTM_NEWLINK, 0, &ifinfo(try index(name), 0, 0));
    try b.int(IFLA_MTU, u32, mtu);
    try route(&b);
}

pub fn createLink(name: []const u8, kind: []const u8) !void {
    if (name.len == 0 or name.len > 15 or kind.len == 0) return error.Invalid;
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(RTM_NEWLINK, nl.F_CREATE | nl.F_EXCL, &ifinfo(0, 0, 0));
    try b.str(IFLA_IFNAME, name);
    try b.open(IFLA_LINKINFO);
    try b.str(IFLA_INFO_KIND, kind);
    try b.close();
    try route(&b);
}

pub fn deleteLink(name: []const u8) !void {
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(RTM_DELLINK, 0, &ifinfo(try index(name), 0, 0));
    try route(&b);
}

pub fn decodeAddress(body: []const u8, out: *Address) !void {
    if (body.len < 8) return error.Io;
    out.* = std.mem.zeroes(Address);
    out.family = body[0];
    out.prefix = body[1];
    out.flags = body[2];
    out.scope = body[3];
    out.index = std.mem.readInt(i32, body[4..8], .little);
    const a = body[8..];
    const ip = nl.find(a, IFA_LOCAL) orelse nl.find(a, IFA_ADDRESS) orelse return;
    _ = formatIp(&out.address, out.family, ip) catch {};
}

pub fn addresses(out: []Address) !usize {
    var s = try nl.Socket.open(nl.ROUTE);
    defer s.close();
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(RTM_GETADDR, nl.F_DUMP, &[_]u8{0} ** 8);
    var c = Collect(Address, RTM_NEWADDR, decodeAddress){ .out = out };
    try s.call(&b, &c, @TypeOf(c).f);
    return c.n;
}

fn changeAddress(name: []const u8, cidr: []const u8, kind: u16, flags: u16) !void {
    const c = try parseCidr(cidr);
    var h = [_]u8{0} ** 8;
    h[0] = c.ip.family;
    h[1] = c.prefix;
    std.mem.writeInt(i32, h[4..8], try index(name), .little);
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(kind, flags, &h);
    try b.attr(IFA_LOCAL, c.ip.slice());
    try b.attr(IFA_ADDRESS, c.ip.slice());
    try route(&b);
}

pub fn addAddress(name: []const u8, cidr: []const u8) !void {
    try changeAddress(name, cidr, RTM_NEWADDR, nl.F_CREATE | nl.F_REPLACE);
}

pub fn deleteAddress(name: []const u8, cidr: []const u8) !void {
    try changeAddress(name, cidr, RTM_DELADDR, 0);
}

pub fn decodeRoute(body: []const u8, out: *Route) !void {
    if (body.len < 12) return error.Io;
    out.* = std.mem.zeroes(Route);
    out.family = body[0];
    out.prefix = body[1];
    out.table = body[4];
    out.protocol = body[5];
    out.scope = body[6];
    out.kind = body[7];
    const a = body[12..];
    if (nl.int(u32, nl.find(a, RTA_TABLE))) |t| out.table = @intCast(@min(t, 255));
    out.oif = nl.int(i32, nl.find(a, RTA_OIF)) orelse 0;
    out.priority = nl.int(u32, nl.find(a, RTA_PRIORITY)) orelse 0;
    if (nl.find(a, RTA_DST)) |d| {
        _ = formatIp(&out.destination, out.family, d) catch {};
    } else putText(&out.destination, "default");
    if (nl.find(a, RTA_GATEWAY)) |g| _ = formatIp(&out.gateway, out.family, g) catch {};
}

pub fn routes(out: []Route) !usize {
    var s = try nl.Socket.open(nl.ROUTE);
    defer s.close();
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(RTM_GETROUTE, nl.F_DUMP, &[_]u8{0} ** 12);
    var c = Collect(Route, RTM_NEWROUTE, decodeRoute){ .out = out };
    try s.call(&b, &c, @TypeOf(c).f);
    return c.n;
}

fn changeRoute(dst: []const u8, gateway: []const u8, dev: []const u8, metric: u32, kind: u16, flags: u16) !void {
    const is_default = std.mem.eql(u8, dst, "default");
    const gw = if (gateway.len > 0) try parseIp(gateway) else null;
    const c: Cidr = if (is_default) .{ .ip = .{ .family = if (gw) |g| g.family else linux.AF.INET }, .prefix = 0 } else try parseCidr(dst);
    if (gw) |g| if (g.family != c.ip.family) return error.Invalid;
    if (gw == null and dev.len == 0) return error.Invalid;
    var h = [_]u8{0} ** 12;
    h[0] = c.ip.family;
    h[1] = c.prefix;
    h[4] = 254;
    h[5] = 4;
    h[6] = if (gw == null) 253 else 0;
    h[7] = 1;
    var b = nl.Builder{};
    defer b.deinit();
    try b.begin(kind, flags, &h);
    if (c.prefix > 0) try b.attr(RTA_DST, c.ip.slice());
    if (gw) |g| try b.attr(RTA_GATEWAY, g.slice());
    if (dev.len > 0) try b.int(RTA_OIF, i32, try index(dev));
    if (metric > 0) try b.int(RTA_PRIORITY, u32, metric);
    try route(&b);
}

pub fn addRoute(dst: []const u8, gateway: []const u8, dev: []const u8, metric: u32) !void {
    try changeRoute(dst, gateway, dev, metric, RTM_NEWROUTE, nl.F_CREATE | nl.F_REPLACE);
}

pub fn deleteRoute(dst: []const u8, gateway: []const u8, dev: []const u8, metric: u32) !void {
    try changeRoute(dst, gateway, dev, metric, RTM_DELROUTE, 0);
}

pub fn isolated(comptime body: fn () anyerror!void) !void {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return sys.fromErrno(linux.errno(pid));
    if (pid == 0) {
        const rc = linux.unshare(linux.CLONE.NEWUSER | linux.CLONE.NEWNET);
        if (linux.errno(rc) != .SUCCESS) linux.exit_group(77);
        body() catch |e| {
            std.debug.print("isolated: {s}\n", .{@errorName(e)});
            linux.exit_group(1);
        };
        linux.exit_group(0);
    }
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(@intCast(pid), &status, 0);
        if (linux.errno(rc) == .INTR) continue;
        _ = try sys.check(rc);
        break;
    }
    if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 77) return error.SkipZigTest;
    if (!linux.W.IFEXITED(status) or linux.W.EXITSTATUS(status) != 0) return error.Io;
}

test "addresses parse and print like the kernel tools" {
    var buf: [64]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "10.9.0.1", "10.9.0.1" },
        .{ "fd00::1", "fd00::1" },
        .{ "2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1" },
        .{ "::", "::" },
        .{ "::1", "::1" },
        .{ "fe80::", "fe80::" },
        .{ "1:0:2:0:3:0:4:0", "1:0:2:0:3:0:4:0" },
        .{ "::ffff:192.0.2.1", "::ffff:192.0.2.1" },
        .{ "2001:DB8::A:B", "2001:db8::a:b" },
    };
    for (cases) |c| {
        const ip = try parseIp(c[0]);
        try std.testing.expectEqualStrings(c[1], try formatIp(&buf, ip.family, ip.slice()));
    }
    for ([_][]const u8{ "1.2.3", "1.2.3.256", "1::2::3", "12345::", "1:2:3:4:5:6:7:8:9", "", "a.b.c.d" }) |bad|
        try std.testing.expectError(error.Invalid, parseIp(bad));
    const c = try parseCidr("fd00::/64");
    try std.testing.expectEqual(@as(u8, 64), c.prefix);
    try std.testing.expectEqual(@as(u8, 32), (try parseCidr("10.0.0.1")).prefix);
    try std.testing.expectError(error.Invalid, parseCidr("10.0.0.0/33"));
}

test "the loopback link is listed with its flags" {
    var all: [64]Link = undefined;
    const n = try links(&all);
    var found = false;
    for (all[0..n]) |l| {
        if (!std.mem.eql(u8, sys.cstr(&l.name), "lo")) continue;
        found = true;
        try std.testing.expect(l.flags & IFF_LOOPBACK != 0);
        try std.testing.expectEqualStrings("00:00:00:00:00:00", sys.cstr(&l.mac));
    }
    try std.testing.expect(found);
    var lo: Link = undefined;
    try link("lo", &lo);
    try std.testing.expectEqual(@as(i32, 1), lo.index);
    try std.testing.expectError(error.NotFound, link("nonesiste0", &lo));
}

fn netnsScenario() !void {
    try setUp("lo", true);
    try createLink("sintytest0", "wireguard");
    try std.testing.expectError(error.Exists, createLink("sintytest0", "wireguard"));
    try setMtu("sintytest0", 1380);
    try addAddress("sintytest0", "10.77.0.1/24");
    try addAddress("sintytest0", "fd77::1/64");
    try setUp("sintytest0", true);
    try addRoute("10.78.0.0/16", "", "sintytest0", 50);
    try addRoute("default", "", "sintytest0", 900);
    var l: Link = undefined;
    try link("sintytest0", &l);
    try std.testing.expectEqualStrings("wireguard", sys.cstr(&l.kind));
    try std.testing.expectEqual(@as(u32, 1380), l.mtu);
    try std.testing.expect(l.flags & IFF_UP != 0);
    var addrs: [16]Address = undefined;
    const na = try addresses(&addrs);
    var v4 = false;
    var v6 = false;
    for (addrs[0..na]) |a| {
        if (a.index != l.index) continue;
        if (std.mem.eql(u8, sys.cstr(&a.address), "10.77.0.1") and a.prefix == 24) v4 = true;
        if (std.mem.eql(u8, sys.cstr(&a.address), "fd77::1") and a.prefix == 64) v6 = true;
    }
    try std.testing.expect(v4 and v6);
    var rs: [32]Route = undefined;
    const nr = try routes(&rs);
    var net16 = false;
    var dflt = false;
    for (rs[0..nr]) |r| {
        if (r.oif != l.index or r.table != 254) continue;
        if (std.mem.eql(u8, sys.cstr(&r.destination), "10.78.0.0") and r.prefix == 16 and r.priority == 50) net16 = true;
        if (std.mem.eql(u8, sys.cstr(&r.destination), "default") and r.priority == 900) dflt = true;
    }
    try std.testing.expect(net16 and dflt);
    try deleteRoute("10.78.0.0/16", "", "sintytest0", 50);
    try deleteAddress("sintytest0", "10.77.0.1/24");
    const nr2 = try routes(&rs);
    for (rs[0..nr2]) |r| try std.testing.expect(!(r.oif == l.index and std.mem.eql(u8, sys.cstr(&r.destination), "10.78.0.0")));
    try deleteLink("sintytest0");
    try std.testing.expectError(error.NotFound, index("sintytest0"));
}

test "links, addresses and routes change in a private network namespace" {
    try isolated(netnsScenario);
}
