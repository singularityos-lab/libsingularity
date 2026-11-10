const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

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
