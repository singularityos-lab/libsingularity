const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const nl = @import("nl.zig");
const net = @import("net.zig");

const X25519 = std.crypto.dh.X25519;
const b64 = std.base64.standard;

const CMD_GET_DEVICE: u8 = 0;
const CMD_SET_DEVICE: u8 = 1;

const DEV_IFNAME: u16 = 2;
const DEV_PRIVATE_KEY: u16 = 3;
const DEV_PUBLIC_KEY: u16 = 4;
const DEV_FLAGS: u16 = 5;
const DEV_LISTEN_PORT: u16 = 6;
const DEV_FWMARK: u16 = 7;
const DEV_PEERS: u16 = 8;
const DEV_REPLACE_PEERS: u32 = 1;

const PEER_PUBLIC_KEY: u16 = 1;
const PEER_PRESHARED_KEY: u16 = 2;
const PEER_FLAGS: u16 = 3;
const PEER_ENDPOINT: u16 = 4;
const PEER_KEEPALIVE: u16 = 5;
const PEER_LAST_HANDSHAKE: u16 = 6;
const PEER_RX_BYTES: u16 = 7;
const PEER_TX_BYTES: u16 = 8;
const PEER_ALLOWEDIPS: u16 = 9;
const PEER_REPLACE_ALLOWEDIPS: u32 = 2;

const AIP_FAMILY: u16 = 1;
const AIP_IPADDR: u16 = 2;
const AIP_CIDR: u16 = 3;

pub const key_len = 32;
pub const key_text = 45;

pub const Key = [key_len]u8;

pub fn generateKey() !Key {
    var k: Key = undefined;
    var off: usize = 0;
    while (off < k.len) {
        const rc = linux.getrandom(k[off..].ptr, k.len - off, 0);
        if (linux.errno(rc) == .INTR) continue;
        off += try sys.check(rc);
    }
    k[0] &= 248;
    k[31] = (k[31] & 127) | 64;
    return k;
}

pub fn publicKey(private: Key) !Key {
    return X25519.recoverPublicKey(private) catch error.Invalid;
}

pub fn encodeKey(out: *[key_text]u8, k: Key) void {
    _ = b64.Encoder.encode(out[0..44], &k);
    out[44] = 0;
}

pub fn decodeKey(t: []const u8) !Key {
    const s = std.mem.trim(u8, t, " \t\r");
    if (s.len != 44 or s[43] != '=') return error.Invalid;
    var k: Key = undefined;
    b64.Decoder.decode(&k, s) catch return error.Invalid;
    return k;
}

pub const Device = extern struct {
    ifindex: i32,
    listen_port: u16,
    has_private_key: u8,
    pad: u8 = 0,
    fwmark: u32,
    peers: u32,
    public_key: [key_text]u8,
    pad2: [3]u8 = .{ 0, 0, 0 },
};

pub const Peer = extern struct {
    public_key: [key_text]u8,
    has_preshared_key: u8,
    keepalive: u16,
    endpoint: [64]u8,
    allowed_ips: [512]u8,
    allowed_count: u32,
    pad: u32 = 0,
    last_handshake: i64,
    rx_bytes: u64,
    tx_bytes: u64,
};

pub const Endpoint = struct {
    ip: net.Ip,
    port: u16,

    pub fn sockaddr(self: Endpoint, out: []u8) []const u8 {
        @memset(out[0..28], 0);
        std.mem.writeInt(u16, out[0..2], self.ip.family, .little);
        std.mem.writeInt(u16, out[2..4], self.port, .big);
        if (self.ip.family == linux.AF.INET) {
            @memcpy(out[4..8], self.ip.bytes[0..4]);
            return out[0..16];
        }
        @memcpy(out[8..24], &self.ip.bytes);
        return out[0..28];
    }
};

pub fn parseEndpoint(t: []const u8) !Endpoint {
    const s = std.mem.trim(u8, t, " \t\r");
    var host: []const u8 = undefined;
    var port: []const u8 = undefined;
    if (s.len > 0 and s[0] == '[') {
        const close = std.mem.indexOfScalar(u8, s, ']') orelse return error.Invalid;
        if (close + 1 >= s.len or s[close + 1] != ':') return error.Invalid;
        host = s[1..close];
        port = s[close + 2 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.Invalid;
        host = s[0..colon];
        port = s[colon + 1 ..];
    }
    const ip = net.parseIp(host) catch return error.Unsupported;
    return .{ .ip = ip, .port = std.fmt.parseInt(u16, port, 10) catch return error.Invalid };
}

fn endpointText(out: []u8, sa: []const u8) void {
    @memset(out, 0);
    if (sa.len < 2) return;
    const fam = std.mem.readInt(u16, sa[0..2], .little);
    if (sa.len < 4) return;
    const port = std.mem.readInt(u16, sa[2..4], .big);
    var ib: [48]u8 = undefined;
    if (fam == linux.AF.INET and sa.len >= 8) {
        const ip = net.formatIp(&ib, linux.AF.INET, sa[4..8]) catch return;
        _ = std.fmt.bufPrint(out, "{s}:{d}", .{ ip, port }) catch {};
    } else if (fam == linux.AF.INET6 and sa.len >= 24) {
        const ip = net.formatIp(&ib, linux.AF.INET6, sa[8..24]) catch return;
        _ = std.fmt.bufPrint(out, "[{s}]:{d}", .{ ip, port }) catch {};
    }
}

pub const PeerConfig = struct {
    public_key: Key,
    preshared_key: ?Key = null,
    endpoint: ?Endpoint = null,
    keepalive: u16 = 0,
    allowed: []const net.Cidr = &.{},
};

pub const Config = struct {
    private_key: ?Key = null,
    listen_port: ?u16 = null,
    fwmark: ?u32 = null,
    replace_peers: bool = true,
    peers: []const PeerConfig = &.{},
    addresses: []const net.Cidr = &.{},
    mtu: u32 = 0,
};

pub const Parsed = struct {
    config: Config = .{},
    peers: std.ArrayList(PeerConfig) = .empty,
    allowed: std.ArrayList(std.ArrayList(net.Cidr)) = .empty,
    addresses: std.ArrayList(net.Cidr) = .empty,

    pub fn deinit(self: *Parsed) void {
        for (self.allowed.items) |*a| a.deinit(sys.gpa);
        self.allowed.deinit(sys.gpa);
        self.peers.deinit(sys.gpa);
        self.addresses.deinit(sys.gpa);
    }
};

fn cidrList(list: *std.ArrayList(net.Cidr), v: []const u8) !void {
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t\r");
        if (t.len == 0) continue;
        try list.append(sys.gpa, try net.parseCidr(t));
    }
}

pub fn parseConfig(text: []const u8, out: *Parsed) !void {
    out.* = .{};
    errdefer out.deinit();
    const Section = enum { none, interface, peer };
    var section = Section.none;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const hash = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const line = std.mem.trim(u8, raw[0..hash], " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (std.ascii.eqlIgnoreCase(line, "[Interface]")) {
                section = .interface;
            } else if (std.ascii.eqlIgnoreCase(line, "[Peer]")) {
                section = .peer;
                try out.peers.append(sys.gpa, .{ .public_key = [_]u8{0} ** key_len });
                try out.allowed.append(sys.gpa, .empty);
            } else return error.Invalid;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Invalid;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        switch (section) {
            .none => return error.Invalid,
            .interface => {
                if (std.ascii.eqlIgnoreCase(k, "PrivateKey")) {
                    out.config.private_key = try decodeKey(v);
                } else if (std.ascii.eqlIgnoreCase(k, "ListenPort")) {
                    out.config.listen_port = std.fmt.parseInt(u16, v, 10) catch return error.Invalid;
                } else if (std.ascii.eqlIgnoreCase(k, "FwMark")) {
                    out.config.fwmark = if (std.ascii.eqlIgnoreCase(v, "off")) 0 else std.fmt.parseInt(u32, v, 0) catch return error.Invalid;
                } else if (std.ascii.eqlIgnoreCase(k, "Address")) {
                    try cidrList(&out.addresses, v);
                } else if (std.ascii.eqlIgnoreCase(k, "MTU")) {
                    out.config.mtu = std.fmt.parseInt(u32, v, 10) catch return error.Invalid;
                }
            },
            .peer => {
                const p = &out.peers.items[out.peers.items.len - 1];
                if (std.ascii.eqlIgnoreCase(k, "PublicKey")) {
                    p.public_key = try decodeKey(v);
                } else if (std.ascii.eqlIgnoreCase(k, "PresharedKey")) {
                    p.preshared_key = try decodeKey(v);
                } else if (std.ascii.eqlIgnoreCase(k, "Endpoint")) {
                    p.endpoint = try parseEndpoint(v);
                } else if (std.ascii.eqlIgnoreCase(k, "PersistentKeepalive")) {
                    p.keepalive = if (std.ascii.eqlIgnoreCase(v, "off")) 0 else std.fmt.parseInt(u16, v, 10) catch return error.Invalid;
                } else if (std.ascii.eqlIgnoreCase(k, "AllowedIPs")) {
                    try cidrList(&out.allowed.items[out.allowed.items.len - 1], v);
                } else return error.Invalid;
            },
        }
    }
    for (out.peers.items, out.allowed.items) |*p, a| {
        if (std.mem.allEqual(u8, &p.public_key, 0)) return error.Invalid;
        p.allowed = a.items;
    }
    out.config.peers = out.peers.items;
    out.config.addresses = out.addresses.items;
}

fn family(s: *nl.Socket) !u16 {
    return (try nl.family(s, "wireguard")).id;
}

pub fn build(b: *nl.Builder, fam: u16, ifname: []const u8, c: Config) !void {
    try b.genl(fam, 0, CMD_SET_DEVICE, 1);
    try b.str(DEV_IFNAME, ifname);
    if (c.private_key) |k| try b.attr(DEV_PRIVATE_KEY, &k);
    if (c.listen_port) |p| try b.int(DEV_LISTEN_PORT, u16, p);
    if (c.fwmark) |m| try b.int(DEV_FWMARK, u32, m);
    if (c.replace_peers) try b.int(DEV_FLAGS, u32, DEV_REPLACE_PEERS);
    if (c.peers.len == 0) return;
    try b.open(DEV_PEERS);
    for (c.peers) |p| {
        try b.open(0);
        try b.attr(PEER_PUBLIC_KEY, &p.public_key);
        try b.int(PEER_FLAGS, u32, PEER_REPLACE_ALLOWEDIPS);
        if (p.preshared_key) |k| try b.attr(PEER_PRESHARED_KEY, &k);
        if (p.endpoint) |e| {
            var sa: [28]u8 = undefined;
            try b.attr(PEER_ENDPOINT, e.sockaddr(&sa));
        }
        try b.int(PEER_KEEPALIVE, u16, p.keepalive);
        if (p.allowed.len > 0) {
            try b.open(PEER_ALLOWEDIPS);
            for (p.allowed) |a| {
                try b.open(0);
                try b.int(AIP_FAMILY, u16, a.ip.family);
                try b.attr(AIP_IPADDR, a.ip.slice());
                try b.attr(AIP_CIDR, &.{a.prefix});
                try b.close();
            }
            try b.close();
        }
        try b.close();
    }
    try b.close();
}

pub fn set(ifname: []const u8, c: Config) !void {
    var s = try nl.Socket.open(nl.GENERIC);
    defer s.close();
    var b = nl.Builder{};
    defer b.deinit();
    try build(&b, try family(&s), ifname, c);
    try s.exec(&b);
}

const Reader = struct {
    dev: *Device,
    peers: []Peer,
    n: usize = 0,
    total: usize = 0,
    last: Key = [_]u8{0} ** key_len,
    full: bool = false,
    fam: u16,

    fn addAllowed(p: *Peer, full: *bool, list: []const u8) void {
        var it = nl.Attrs{ .data = list };
        while (it.next()) |a| {
            const fam = nl.int(u16, nl.find(a.data, AIP_FAMILY)) orelse continue;
            const ip = nl.find(a.data, AIP_IPADDR) orelse continue;
            const cidr = (nl.find(a.data, AIP_CIDR) orelse continue)[0];
            p.allowed_count += 1;
            if (full.*) continue;
            var ib: [48]u8 = undefined;
            const t = net.formatIp(&ib, @intCast(fam), ip) catch continue;
            const used = std.mem.indexOfScalar(u8, &p.allowed_ips, 0) orelse p.allowed_ips.len;
            const sep = if (used > 0) ", " else "";
            _ = std.fmt.bufPrint(p.allowed_ips[used .. p.allowed_ips.len - 1], "{s}{s}/{d}", .{ sep, t, cidr }) catch {
                full.* = true;
            };
        }
    }

    fn f(self: *Reader, kind: u16, body: []const u8) anyerror!void {
        if (kind != self.fam or body.len < 4) return;
        const a = body[4..];
        if (nl.int(u32, nl.find(a, 1))) |i| self.dev.ifindex = @intCast(i);
        if (nl.int(u16, nl.find(a, DEV_LISTEN_PORT))) |p| self.dev.listen_port = p;
        if (nl.int(u32, nl.find(a, DEV_FWMARK))) |m| self.dev.fwmark = m;
        if (nl.find(a, DEV_PRIVATE_KEY)) |k| self.dev.has_private_key = @intFromBool(k.len == key_len and !std.mem.allEqual(u8, k, 0));
        if (nl.find(a, DEV_PUBLIC_KEY)) |k| if (k.len == key_len and !std.mem.allEqual(u8, k, 0)) encodeKey(&self.dev.public_key, k[0..key_len].*);
        var peers = nl.Attrs{ .data = nl.find(a, DEV_PEERS) orelse return };
        while (peers.next()) |pa| {
            const pk = nl.find(pa.data, PEER_PUBLIC_KEY) orelse continue;
            if (pk.len != key_len) continue;
            const same = self.total > 0 and std.mem.eql(u8, pk, &self.last);
            if (!same) {
                self.total += 1;
                self.last = pk[0..key_len].*;
                if (self.n == self.peers.len) continue;
                const p = &self.peers[self.n];
                self.n += 1;
                self.full = false;
                p.* = std.mem.zeroes(Peer);
                encodeKey(&p.public_key, self.last);
                if (nl.find(pa.data, PEER_PRESHARED_KEY)) |k| p.has_preshared_key = @intFromBool(!std.mem.allEqual(u8, k, 0));
                p.keepalive = nl.int(u16, nl.find(pa.data, PEER_KEEPALIVE)) orelse 0;
                if (nl.find(pa.data, PEER_ENDPOINT)) |e| endpointText(&p.endpoint, e);
                if (nl.find(pa.data, PEER_LAST_HANDSHAKE)) |t| if (t.len >= 8) {
                    p.last_handshake = std.mem.readInt(i64, t[0..8], .little);
                };
                p.rx_bytes = nl.int(u64, nl.find(pa.data, PEER_RX_BYTES)) orelse 0;
                p.tx_bytes = nl.int(u64, nl.find(pa.data, PEER_TX_BYTES)) orelse 0;
            } else if (self.n == 0 or self.total > self.n) continue;
            if (nl.find(pa.data, PEER_ALLOWEDIPS)) |l| addAllowed(&self.peers[self.n - 1], &self.full, l);
        }
    }
};

pub fn get(ifname: []const u8, dev: *Device, peers: []Peer) !usize {
    var s = try nl.Socket.open(nl.GENERIC);
    defer s.close();
    const fam = try family(&s);
    var b = nl.Builder{};
    defer b.deinit();
    try b.genl(fam, nl.F_DUMP, CMD_GET_DEVICE, 1);
    try b.str(DEV_IFNAME, ifname);
    dev.* = std.mem.zeroes(Device);
    var r = Reader{ .dev = dev, .peers = peers, .fam = fam };
    try s.call(&b, &r, Reader.f);
    dev.peers = @intCast(r.total);
    return r.n;
}

pub fn configure(ifname: []const u8, text: []const u8) !void {
    var p: Parsed = undefined;
    try parseConfig(text, &p);
    defer p.deinit();
    net.createLink(ifname, "wireguard") catch |e| if (e != error.Exists) return e;
    try set(ifname, p.config);
    if (p.config.mtu > 0) try net.setMtu(ifname, p.config.mtu);
    for (p.config.addresses) |a| {
        var ib: [64]u8 = undefined;
        var cb: [72]u8 = undefined;
        const ip = try net.formatIp(&ib, a.ip.family, a.ip.slice());
        try net.addAddress(ifname, try std.fmt.bufPrint(&cb, "{s}/{d}", .{ ip, a.prefix }));
    }
    try net.setUp(ifname, true);
    for (p.config.peers) |peer| for (peer.allowed) |a| {
        if (a.prefix == 0) continue;
        var ib: [64]u8 = undefined;
        var cb: [72]u8 = undefined;
        const ip = try net.formatIp(&ib, a.ip.family, a.ip.slice());
        try net.addRoute(try std.fmt.bufPrint(&cb, "{s}/{d}", .{ ip, a.prefix }), "", ifname, 0);
    };
}

test "keys follow the curve25519 test vector" {
    var private: Key = undefined;
    _ = try std.fmt.hexToBytes(&private, "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    var t: [key_text]u8 = undefined;
    encodeKey(&t, private);
    try std.testing.expectEqualSlices(u8, &private, &(try decodeKey(sys.cstr(&t))));
    var expected: Key = undefined;
    _ = try std.fmt.hexToBytes(&expected, "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    try std.testing.expectEqualSlices(u8, &expected, &(try publicKey(private)));
    const g = try generateKey();
    try std.testing.expectEqual(@as(u8, 0), g[0] & 7);
    try std.testing.expectEqual(@as(u8, 64), g[31] & 0xc0);
    try std.testing.expectError(error.Invalid, decodeKey("corta"));
}

test "configuration files parse like wg setconf" {
    const text =
        \\[Interface]
        \\PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
        \\ListenPort = 51820
        \\Address = 10.200.0.1/24, fd20::1/64
        \\MTU = 1380
        \\
        \\[Peer]
        \\# un commento
        \\PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
        \\Endpoint = 192.95.5.67:1234
        \\AllowedIPs = 10.192.122.3/32, 10.192.124.1/24
        \\PersistentKeepalive = 25
        \\
        \\[Peer]
        \\PublicKey = TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0=
        \\Endpoint = [2607:5300:60:6b0::c05f:543]:2468
        \\AllowedIPs = 0.0.0.0/0, ::/0
    ;
    var p: Parsed = undefined;
    try parseConfig(text, &p);
    defer p.deinit();
    try std.testing.expectEqual(@as(?u16, 51820), p.config.listen_port);
    try std.testing.expectEqual(@as(u32, 1380), p.config.mtu);
    try std.testing.expectEqual(@as(usize, 2), p.config.addresses.len);
    try std.testing.expectEqual(@as(usize, 2), p.config.peers.len);
    try std.testing.expectEqual(@as(u16, 25), p.config.peers[0].keepalive);
    try std.testing.expectEqual(@as(u16, 1234), p.config.peers[0].endpoint.?.port);
    try std.testing.expectEqual(@as(usize, 2), p.config.peers[0].allowed.len);
    try std.testing.expectEqual(@as(u8, 24), p.config.peers[0].allowed[1].prefix);
    try std.testing.expectEqual(@as(u8, linux.AF.INET6), p.config.peers[1].endpoint.?.ip.family);
    try std.testing.expectEqual(@as(u16, 2468), p.config.peers[1].endpoint.?.port);
    try std.testing.expectEqual(@as(u8, 0), p.config.peers[1].allowed[1].prefix);
    var bad: Parsed = undefined;
    try std.testing.expectError(error.Invalid, parseConfig("[Peer]\nAllowedIPs = 10.0.0.0/8\n", &bad));
    try std.testing.expectError(error.Invalid, parseConfig("PrivateKey = x\n", &bad));
    try std.testing.expectError(error.Unsupported, parseConfig("[Peer]\nPublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\nEndpoint = vpn.example.com:51820\n", &bad));
}

fn wgScenario() !void {
    try net.setUp("lo", true);
    const a_priv = try generateKey();
    const b_priv = try generateKey();
    var a_pub: [key_text]u8 = undefined;
    var b_pub: [key_text]u8 = undefined;
    var a_key: [key_text]u8 = undefined;
    var b_key: [key_text]u8 = undefined;
    encodeKey(&a_pub, try publicKey(a_priv));
    encodeKey(&b_pub, try publicKey(b_priv));
    encodeKey(&a_key, a_priv);
    encodeKey(&b_key, b_priv);
    var ca: [1024]u8 = undefined;
    var cb: [1024]u8 = undefined;
    const conf_a = try std.fmt.bufPrint(&ca, "[Interface]\nPrivateKey = {s}\nListenPort = 51901\nAddress = 10.123.0.1/24\nMTU = 1400\n[Peer]\nPublicKey = {s}\nEndpoint = 127.0.0.1:51902\nAllowedIPs = 10.123.0.2/32, 10.124.0.0/16, fd12::/64\nPersistentKeepalive = 1\n", .{ sys.cstr(&a_key), sys.cstr(&b_pub) });
    const conf_b = try std.fmt.bufPrint(&cb, "[Interface]\nPrivateKey = {s}\nListenPort = 51902\nAddress = 10.123.0.2/24\n[Peer]\nPublicKey = {s}\nEndpoint = 127.0.0.1:51901\nAllowedIPs = 10.123.0.1/32\nPersistentKeepalive = 1\n", .{ sys.cstr(&b_key), sys.cstr(&a_pub) });
    try configure("wga", conf_a);
    try configure("wgb", conf_b);
    var dev: Device = undefined;
    var peers: [4]Peer = undefined;
    var n = try get("wga", &dev, &peers);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 1), dev.peers);
    try std.testing.expectEqual(@as(u16, 51901), dev.listen_port);
    try std.testing.expectEqual(@as(u8, 1), dev.has_private_key);
    try std.testing.expectEqualStrings(sys.cstr(&a_pub), sys.cstr(&dev.public_key));
    try std.testing.expectEqualStrings(sys.cstr(&b_pub), sys.cstr(&peers[0].public_key));
    try std.testing.expectEqualStrings("127.0.0.1:51902", sys.cstr(&peers[0].endpoint));
    try std.testing.expectEqualStrings("10.123.0.2/32, 10.124.0.0/16, fd12::/64", sys.cstr(&peers[0].allowed_ips));
    try std.testing.expectEqual(@as(u16, 1), peers[0].keepalive);
    try std.testing.expectEqual(@as(u32, 3), peers[0].allowed_count);
    var l: net.Link = undefined;
    try net.link("wga", &l);
    try std.testing.expectEqual(@as(u32, 1400), l.mtu);
    var rs: [32]net.Route = undefined;
    const nr = try net.routes(&rs);
    var routed = false;
    for (rs[0..nr]) |r| if (r.oif == l.index and std.mem.eql(u8, sys.cstr(&r.destination), "10.124.0.0")) {
        routed = true;
    };
    try std.testing.expect(routed);
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        n = try get("wga", &dev, &peers);
        if (peers[0].last_handshake != 0 and peers[0].rx_bytes > 0) break;
        var ts = linux.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    try std.testing.expect(peers[0].last_handshake != 0);
    try std.testing.expect(peers[0].rx_bytes > 0 and peers[0].tx_bytes > 0);
    try set("wga", .{ .replace_peers = true });
    n = try get("wga", &dev, &peers);
    try std.testing.expectEqual(@as(usize, 0), n);
    try net.deleteLink("wga");
    try net.deleteLink("wgb");
}

test "two wireguard peers shake hands in a private network namespace" {
    try net.isolated(wgScenario);
}
