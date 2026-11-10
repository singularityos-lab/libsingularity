const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const nl = @import("nl.zig");
const net = @import("net.zig");

const CMD_GET_INTERFACE: u8 = 5;
const CMD_GET_STATION: u8 = 17;
const CMD_GET_SCAN: u8 = 32;
const CMD_TRIGGER_SCAN: u8 = 33;
const CMD_NEW_SCAN_RESULTS: u8 = 34;
const CMD_SCAN_ABORTED: u8 = 35;

const ATTR_WIPHY: u16 = 1;
const ATTR_IFINDEX: u16 = 3;
const ATTR_IFNAME: u16 = 4;
const ATTR_IFTYPE: u16 = 5;
const ATTR_MAC: u16 = 6;
const ATTR_STA_INFO: u16 = 21;
const ATTR_WIPHY_FREQ: u16 = 38;
const ATTR_SCAN_SSIDS: u16 = 45;
const ATTR_BSS: u16 = 47;
const ATTR_SSID: u16 = 52;

const BSS_BSSID: u16 = 1;
const BSS_FREQUENCY: u16 = 2;
const BSS_CAPABILITY: u16 = 5;
const BSS_INFORMATION_ELEMENTS: u16 = 6;
const BSS_SIGNAL_MBM: u16 = 7;
const BSS_STATUS: u16 = 9;
const BSS_SEEN_MS_AGO: u16 = 10;
const BSS_BEACON_IES: u16 = 11;

const STA_INACTIVE_TIME: u16 = 1;
const STA_RX_BYTES: u16 = 2;
const STA_TX_BYTES: u16 = 3;
const STA_SIGNAL: u16 = 7;
const STA_TX_BITRATE: u16 = 8;
const STA_RX_BITRATE: u16 = 14;
const STA_CONNECTED_TIME: u16 = 16;
const STA_RX_BYTES64: u16 = 23;
const STA_TX_BYTES64: u16 = 24;
const RATE_BITRATE: u16 = 1;
const RATE_BITRATE32: u16 = 5;

pub const SEC_PRIVACY: u32 = 1;
pub const SEC_WPA: u32 = 2;
pub const SEC_PSK: u32 = 4;
pub const SEC_SAE: u32 = 8;
pub const SEC_8021X: u32 = 16;
pub const SEC_OWE: u32 = 32;

pub const Interface = extern struct {
    index: i32,
    wiphy: u32,
    iftype: u32,
    frequency: u32,
    name: [16]u8,
    mac: [24]u8,
    ssid: [33]u8,
    pad: [3]u8 = .{ 0, 0, 0 },
};

pub const Bss = extern struct {
    bssid: [24]u8,
    ssid: [33]u8,
    pad: [3]u8 = .{ 0, 0, 0 },
    frequency: u32,
    signal_mbm: i32,
    seen_ms_ago: u32,
    security: u32,
    status: i32,
};

pub const Station = extern struct {
    mac: [24]u8,
    signal_dbm: i32,
    tx_bitrate_100k: u32,
    rx_bitrate_100k: u32,
    connected_s: u32,
    inactive_ms: u32,
    pad: u32 = 0,
    rx_bytes: u64,
    tx_bytes: u64,
};

fn putText(dst: []u8, s: []const u8) void {
    @memset(dst, 0);
    const n = @min(s.len, dst.len - 1);
    @memcpy(dst[0..n], s[0..n]);
}

fn macText(dst: []u8, b: []const u8) void {
    @memset(dst, 0);
    if (b.len < 6) return;
    _ = std.fmt.bufPrint(dst, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ b[0], b[1], b[2], b[3], b[4], b[5] }) catch {};
}

fn akmBits(oui: []const u8, kind: u8) u32 {
    if (!std.mem.eql(u8, oui, &.{ 0x00, 0x0f, 0xac })) return 0;
    return switch (kind) {
        1, 3, 5, 11, 12, 13 => SEC_8021X,
        2, 4, 6 => SEC_PSK,
        8, 9, 24, 25 => SEC_SAE,
        18 => SEC_OWE,
        else => 0,
    };
}

pub fn security(ies: []const u8, capability: u16) u32 {
    var bits: u32 = if (capability & 0x10 != 0) SEC_PRIVACY else 0;
    var off: usize = 0;
    while (off + 2 <= ies.len) {
        const id = ies[off];
        const len = ies[off + 1];
        if (off + 2 + len > ies.len) break;
        const e = ies[off + 2 .. off + 2 + len];
        off += 2 + len;
        if (id == 48 and e.len >= 8) {
            bits |= SEC_PRIVACY;
            var p: usize = 6;
            const pairwise = std.mem.readInt(u16, e[p..][0..2], .little);
            p += 2 + @as(usize, pairwise) * 4;
            if (p + 2 > e.len) continue;
            const akms = std.mem.readInt(u16, e[p..][0..2], .little);
            p += 2;
            var i: usize = 0;
            while (i < akms and p + 4 <= e.len) : (i += 1) {
                bits |= akmBits(e[p .. p + 3], e[p + 3]);
                p += 4;
            }
        } else if (id == 221 and e.len >= 4 and std.mem.eql(u8, e[0..4], &.{ 0x00, 0x50, 0xf2, 0x01 })) {
            bits |= SEC_WPA | SEC_PRIVACY;
        }
    }
    return bits;
}

pub fn ssidOf(ies: []const u8) ?[]const u8 {
    var off: usize = 0;
    while (off + 2 <= ies.len) {
        const len = ies[off + 1];
        if (off + 2 + len > ies.len) return null;
        if (ies[off] == 0) return ies[off + 2 .. off + 2 + len];
        off += 2 + len;
    }
    return null;
}

pub fn decodeBss(body: []const u8, out: *Bss) !void {
    if (body.len < 4) return error.Io;
    const bss = nl.find(body[4..], ATTR_BSS) orelse return error.Io;
    out.* = std.mem.zeroes(Bss);
    out.status = -1;
    if (nl.find(bss, BSS_BSSID)) |m| macText(&out.bssid, m);
    out.frequency = nl.int(u32, nl.find(bss, BSS_FREQUENCY)) orelse 0;
    out.signal_mbm = nl.int(i32, nl.find(bss, BSS_SIGNAL_MBM)) orelse 0;
    out.seen_ms_ago = nl.int(u32, nl.find(bss, BSS_SEEN_MS_AGO)) orelse 0;
    if (nl.int(u32, nl.find(bss, BSS_STATUS))) |st| out.status = @intCast(st);
    const ies = nl.find(bss, BSS_INFORMATION_ELEMENTS) orelse nl.find(bss, BSS_BEACON_IES) orelse &.{};
    if (ssidOf(ies)) |s| putText(&out.ssid, s);
    out.security = security(ies, nl.int(u16, nl.find(bss, BSS_CAPABILITY)) orelse 0);
}

pub fn decodeInterface(body: []const u8, out: *Interface) !void {
    if (body.len < 4) return error.Io;
    const a = body[4..];
    out.* = std.mem.zeroes(Interface);
    out.index = @intCast(nl.int(u32, nl.find(a, ATTR_IFINDEX)) orelse return error.NotFound);
    out.wiphy = nl.int(u32, nl.find(a, ATTR_WIPHY)) orelse 0;
    out.iftype = nl.int(u32, nl.find(a, ATTR_IFTYPE)) orelse 0;
    out.frequency = nl.int(u32, nl.find(a, ATTR_WIPHY_FREQ)) orelse 0;
    putText(&out.name, nl.text(nl.find(a, ATTR_IFNAME)));
    if (nl.find(a, ATTR_MAC)) |m| macText(&out.mac, m);
    if (nl.find(a, ATTR_SSID)) |s| putText(&out.ssid, s);
}

fn rate(nest: ?[]const u8) u32 {
    const n = nest orelse return 0;
    if (nl.int(u32, nl.find(n, RATE_BITRATE32))) |r| return r;
    return nl.int(u16, nl.find(n, RATE_BITRATE)) orelse 0;
}

pub fn decodeStation(body: []const u8, out: *Station) !void {
    if (body.len < 4) return error.Io;
    const a = body[4..];
    out.* = std.mem.zeroes(Station);
    if (nl.find(a, ATTR_MAC)) |m| macText(&out.mac, m);
    const info = nl.find(a, ATTR_STA_INFO) orelse return;
    if (nl.find(info, STA_SIGNAL)) |s| if (s.len > 0) {
        out.signal_dbm = @as(i8, @bitCast(s[0]));
    };
    out.tx_bitrate_100k = rate(nl.find(info, STA_TX_BITRATE));
    out.rx_bitrate_100k = rate(nl.find(info, STA_RX_BITRATE));
    out.connected_s = nl.int(u32, nl.find(info, STA_CONNECTED_TIME)) orelse 0;
    out.inactive_ms = nl.int(u32, nl.find(info, STA_INACTIVE_TIME)) orelse 0;
    out.rx_bytes = nl.int(u64, nl.find(info, STA_RX_BYTES64)) orelse @as(u64, nl.int(u32, nl.find(info, STA_RX_BYTES)) orelse 0);
    out.tx_bytes = nl.int(u64, nl.find(info, STA_TX_BYTES64)) orelse @as(u64, nl.int(u32, nl.find(info, STA_TX_BYTES)) orelse 0);
}

const Session = struct {
    s: nl.Socket,
    fam: nl.Family,
    b: nl.Builder = .{},

    fn open() !Session {
        var s = try nl.Socket.open(nl.GENERIC);
        errdefer s.close();
        return .{ .s = s, .fam = try nl.family(&s, "nl80211") };
    }

    fn close(self: *Session) void {
        self.b.deinit();
        self.s.close();
    }
};

fn Collect(comptime T: type, comptime decodeFn: fn ([]const u8, *T) anyerror!void) type {
    return struct {
        out: []T,
        fam: u16,
        n: usize = 0,
        fn f(self: *@This(), kind: u16, body: []const u8) anyerror!void {
            if (kind != self.fam) return;
            if (self.n == self.out.len) return error.TooBig;
            decodeFn(body, &self.out[self.n]) catch |e| {
                if (e == error.NotFound) return;
                return e;
            };
            self.n += 1;
        }
    };
}

pub fn interfaces(out: []Interface) !usize {
    var se = try Session.open();
    defer se.close();
    try se.b.genl(se.fam.id, nl.F_DUMP, CMD_GET_INTERFACE, 0);
    var c = Collect(Interface, decodeInterface){ .out = out, .fam = se.fam.id };
    try se.s.call(&se.b, &c, @TypeOf(c).f);
    return c.n;
}

pub fn scanResults(ifname: []const u8, out: []Bss) !usize {
    const idx = try net.index(ifname);
    var se = try Session.open();
    defer se.close();
    try se.b.genl(se.fam.id, nl.F_DUMP, CMD_GET_SCAN, 0);
    try se.b.int(ATTR_IFINDEX, u32, @intCast(idx));
    var c = Collect(Bss, decodeBss){ .out = out, .fam = se.fam.id };
    try se.s.call(&se.b, &c, @TypeOf(c).f);
    return c.n;
}

pub fn stations(ifname: []const u8, out: []Station) !usize {
    const idx = try net.index(ifname);
    var se = try Session.open();
    defer se.close();
    try se.b.genl(se.fam.id, nl.F_DUMP, CMD_GET_STATION, 0);
    try se.b.int(ATTR_IFINDEX, u32, @intCast(idx));
    var c = Collect(Station, decodeStation){ .out = out, .fam = se.fam.id };
    try se.s.call(&se.b, &c, @TypeOf(c).f);
    return c.n;
}

pub fn scan(ifname: []const u8, ssid: []const u8, timeout_ms: i32) !void {
    if (ssid.len > 32) return error.TooBig;
    const idx = try net.index(ifname);
    var se = try Session.open();
    defer se.close();
    const group = se.fam.group("scan") orelse return error.Unsupported;
    var ev = try nl.Socket.open(nl.GENERIC);
    defer ev.close();
    try ev.join(group);
    try se.b.genl(se.fam.id, 0, CMD_TRIGGER_SCAN, 0);
    try se.b.int(ATTR_IFINDEX, u32, @intCast(idx));
    try se.b.open(ATTR_SCAN_SSIDS);
    try se.b.attr(1, ssid);
    try se.b.close();
    try se.s.exec(&se.b);
    const W = struct {
        fam: u16,
        idx: u32,
        aborted: bool = false,
        fn f(self: *@This(), kind: u16, body: []const u8) anyerror!bool {
            if (kind != self.fam or body.len < 4) return false;
            if (body[0] != CMD_NEW_SCAN_RESULTS and body[0] != CMD_SCAN_ABORTED) return false;
            if (nl.int(u32, nl.find(body[4..], ATTR_IFINDEX)) != self.idx) return false;
            self.aborted = body[0] == CMD_SCAN_ABORTED;
            return true;
        }
    };
    var w = W{ .fam = se.fam.id, .idx = @intCast(idx) };
    try ev.wait(timeout_ms, &w, W.f);
    if (w.aborted) return error.Busy;
}

fn ie(b: *std.ArrayList(u8), id: u8, data: []const u8) !void {
    try b.append(sys.gpa, id);
    try b.append(sys.gpa, @intCast(data.len));
    try b.appendSlice(sys.gpa, data);
}

test "security is read from the RSN and WPA elements" {
    var ies: std.ArrayList(u8) = .empty;
    defer ies.deinit(sys.gpa);
    try ie(&ies, 0, "Casa");
    try ie(&ies, 48, &.{ 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 4, 2, 0, 0x00, 0x0f, 0xac, 2, 0x00, 0x0f, 0xac, 8, 0, 0 });
    try std.testing.expectEqual(SEC_PRIVACY | SEC_PSK | SEC_SAE, security(ies.items, 0x11));
    try std.testing.expectEqualStrings("Casa", ssidOf(ies.items).?);
    ies.clearRetainingCapacity();
    try ie(&ies, 221, &.{ 0x00, 0x50, 0xf2, 0x01, 1, 0 });
    try std.testing.expectEqual(SEC_PRIVACY | SEC_WPA, security(ies.items, 0x11));
    try std.testing.expectEqual(SEC_PRIVACY, security(&.{}, 0x10));
    try std.testing.expectEqual(@as(u32, 0), security(&.{}, 0x01));
    ies.clearRetainingCapacity();
    try ie(&ies, 48, &.{ 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 18 });
    try std.testing.expectEqual(SEC_PRIVACY | SEC_OWE, security(ies.items, 0x11));
    ies.clearRetainingCapacity();
    try ie(&ies, 48, &.{ 1, 0, 0x00, 0x0f, 0xac, 4, 9, 0 });
    try std.testing.expectEqual(SEC_PRIVACY, security(ies.items, 0));
}

test "scan results decode from an nl80211 message" {
    var b = nl.Builder{};
    defer b.deinit();
    try b.genl(28, 0, CMD_NEW_SCAN_RESULTS, 1);
    try b.int(ATTR_IFINDEX, u32, 3);
    try b.open(ATTR_BSS);
    try b.attr(BSS_BSSID, &.{ 0x02, 0x00, 0x00, 0xab, 0xcd, 0xef });
    try b.int(BSS_FREQUENCY, u32, 5180);
    try b.int(BSS_CAPABILITY, u16, 0x0411);
    try b.int(BSS_SIGNAL_MBM, i32, -5400);
    try b.int(BSS_SEEN_MS_AGO, u32, 120);
    try b.int(BSS_STATUS, u32, 1);
    try b.attr(BSS_INFORMATION_ELEMENTS, &.{ 0, 6, 'U', 'f', 'f', 'i', 'c', 'i', 48, 20, 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 1, 0, 0 });
    try b.close();
    const msg = b.finish(1);
    var bss: Bss = undefined;
    try decodeBss(msg[nl.header..], &bss);
    try std.testing.expectEqualStrings("02:00:00:ab:cd:ef", sys.cstr(&bss.bssid));
    try std.testing.expectEqualStrings("Uffici", sys.cstr(&bss.ssid));
    try std.testing.expectEqual(@as(u32, 5180), bss.frequency);
    try std.testing.expectEqual(@as(i32, -5400), bss.signal_mbm);
    try std.testing.expectEqual(@as(i32, 1), bss.status);
    try std.testing.expectEqual(SEC_PRIVACY | SEC_8021X, bss.security);
}

test "station info decodes signal, rates and counters" {
    var b = nl.Builder{};
    defer b.deinit();
    try b.genl(28, 0, 19, 1);
    try b.attr(ATTR_MAC, &.{ 0x02, 0, 0, 0, 1, 0 });
    try b.open(ATTR_STA_INFO);
    try b.attr(STA_SIGNAL, &.{@bitCast(@as(i8, -61))});
    try b.open(STA_TX_BITRATE);
    try b.int(RATE_BITRATE32, u32, 8667);
    try b.close();
    try b.open(STA_RX_BITRATE);
    try b.int(RATE_BITRATE, u16, 540);
    try b.close();
    try b.int(STA_RX_BYTES64, u64, 1 << 33);
    try b.int(STA_TX_BYTES, u32, 4096);
    try b.int(STA_CONNECTED_TIME, u32, 77);
    try b.close();
    const msg = b.finish(1);
    var st: Station = undefined;
    try decodeStation(msg[nl.header..], &st);
    try std.testing.expectEqual(@as(i32, -61), st.signal_dbm);
    try std.testing.expectEqual(@as(u32, 8667), st.tx_bitrate_100k);
    try std.testing.expectEqual(@as(u32, 540), st.rx_bitrate_100k);
    try std.testing.expectEqual(@as(u64, 1 << 33), st.rx_bytes);
    try std.testing.expectEqual(@as(u64, 4096), st.tx_bytes);
    try std.testing.expectEqualStrings("02:00:00:00:01:00", sys.cstr(&st.mac));
}

test "wireless interfaces of this machine match sysfs" {
    var all: [8]Interface = undefined;
    const n = interfaces(&all) catch |e| {
        if (e == error.Unsupported) return error.SkipZigTest;
        return e;
    };
    var d = sys.Dir.open("/sys/class/ieee80211") catch return error.SkipZigTest;
    defer d.close();
    var phys: usize = 0;
    while (try d.next()) |e| {
        if (e.name[0] != '.') phys += 1;
    }
    if (phys == 0) return error.SkipZigTest;
    try std.testing.expect(n >= 1);
    for (all[0..n]) |i| {
        var pb: [96]u8 = undefined;
        const p = try sys.pathZ(&pb, "/sys/class/net/{s}/phy80211", .{sys.cstr(&i.name)});
        try std.testing.expectEqual(@as(usize, 0), linux.faccessat(linux.AT.FDCWD, p, linux.F_OK, 0));
        var res: [128]Bss = undefined;
        const m = try scanResults(sys.cstr(&i.name), &res);
        for (res[0..m]) |r| try std.testing.expect(r.frequency >= 2400);
    }
}
