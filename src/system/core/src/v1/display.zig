const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const BacklightType = enum(u32) { unknown = 0, firmware = 1, platform = 2, raw = 3 };

pub const Backlight = extern struct {
    kind: u32,
    pad: u32 = 0,
    brightness: i64,
    max_brightness: i64,
    actual_brightness: i64,
    name: [64]u8,
    connector: [64]u8,
};

pub const BacklightList = sys.List(Backlight);

fn parseType(s: []const u8) BacklightType {
    if (std.mem.eql(u8, s, "firmware")) return .firmware;
    if (std.mem.eql(u8, s, "platform")) return .platform;
    if (std.mem.eql(u8, s, "raw")) return .raw;
    return .unknown;
}

fn connectorOf(dir: []const u8, dst: []u8) void {
    var buf: [512]u8 = undefined;
    const p = sys.pathZ(&buf, "{s}/device", .{dir}) catch return sys.copyName(dst, "");
    var target: [512]u8 = undefined;
    const t = sys.readLink(p, &target) catch return sys.copyName(dst, "");
    const base = sys.baseName(t);
    if (std.mem.startsWith(u8, base, "card") and std.mem.indexOfScalar(u8, base, '-') != null) {
        const dash = std.mem.indexOfScalar(u8, base, '-').?;
        return sys.copyName(dst, base[dash + 1 ..]);
    }
    sys.copyName(dst, "");
}

pub fn backlights(sysfs: []const u8) !*BacklightList {
    const result = try BacklightList.create();
    errdefer result.destroy();
    var buf: [512]u8 = undefined;
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}/class/backlight", .{sysfs})) catch return result;
    defer d.close();
    while (try d.next()) |entry| {
        var pbuf: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&pbuf, "{s}/class/backlight/{s}", .{ sysfs, entry.name }) catch continue;
        var b = std.mem.zeroes(Backlight);
        var fb: [512]u8 = undefined;
        b.max_brightness = sys.readInt(i64, try sys.pathZ(&fb, "{s}/max_brightness", .{dir})) orelse continue;
        b.brightness = sys.readInt(i64, try sys.pathZ(&fb, "{s}/brightness", .{dir})) orelse 0;
        b.actual_brightness = sys.readInt(i64, try sys.pathZ(&fb, "{s}/actual_brightness", .{dir})) orelse b.brightness;
        var tmp: [32]u8 = undefined;
        b.kind = @intFromEnum(parseType(sys.readTrim(try sys.pathZ(&fb, "{s}/type", .{dir}), &tmp) orelse ""));
        sys.copyName(&b.name, entry.name);
        connectorOf(dir, &b.connector);
        try result.append(b);
    }
    std.mem.sort(Backlight, result.items.items, {}, struct {
        fn rank(k: u32) u32 {
            return switch (@as(BacklightType, @enumFromInt(k))) {
                .firmware => 0,
                .platform => 1,
                .raw => 2,
                .unknown => 3,
            };
        }
        fn lt(_: void, a: Backlight, b: Backlight) bool {
            return rank(a.kind) < rank(b.kind);
        }
    }.lt);
    return result;
}

pub fn setBacklight(sysfs: []const u8, name: []const u8, value: i64) !void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, "..")) return error.Invalid;
    var buf: [512]u8 = undefined;
    const max = sys.readInt(i64, try sys.pathZ(&buf, "{s}/class/backlight/{s}/max_brightness", .{ sysfs, name })) orelse return error.NotFound;
    if (value < 0 or value > max) return error.Invalid;
    var vbuf: [24]u8 = undefined;
    try sys.writeFile(try sys.pathZ(&buf, "{s}/class/backlight/{s}/brightness", .{ sysfs, name }), try std.fmt.bufPrint(&vbuf, "{d}", .{value}));
}

pub const ddc_address: u8 = 0x37;
const host_address: u8 = 0x51;
const I2C_SLAVE: u32 = 0x0703;

pub fn ddcGetRequest(vcp: u8) [5]u8 {
    var p = [5]u8{ host_address, 0x82, 0x01, vcp, 0 };
    p[4] = checksum(0x6e, p[0..4]);
    return p;
}

pub fn ddcSetRequest(vcp: u8, value: u16) [7]u8 {
    var p = [7]u8{ host_address, 0x84, 0x03, vcp, @intCast(value >> 8), @intCast(value & 0xff), 0 };
    p[6] = checksum(0x6e, p[0..6]);
    return p;
}

fn checksum(seed: u8, bytes: []const u8) u8 {
    var c = seed;
    for (bytes) |b| c ^= b;
    return c;
}

pub const VcpValue = struct { current: u16, maximum: u16 };

pub fn ddcParseReply(vcp: u8, r: []const u8) !VcpValue {
    if (r.len < 11) return error.Invalid;
    if (r[0] != 0x6e) return error.Invalid;
    const len = r[1] & 0x7f;
    if (len != 8 or r.len < 3 + len) return error.Invalid;
    if (checksum(0x50, r[0 .. 2 + len]) != r[2 + len]) return error.Io;
    if (r[2] != 0x02) return error.Invalid;
    if (r[3] != 0x00) return error.Unsupported;
    if (r[4] != vcp) return error.Invalid;
    return .{ .maximum = (@as(u16, r[6]) << 8) | r[7], .current = (@as(u16, r[8]) << 8) | r[9] };
}

fn openBus(bus: u32) !i32 {
    var buf: [64]u8 = undefined;
    const fd = try sys.open(try sys.pathZ(&buf, "/dev/i2c-{d}", .{bus}), .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    errdefer sys.close(fd);
    _ = try sys.ioctl(fd, I2C_SLAVE, ddc_address);
    return fd;
}

pub fn ddcGet(bus: u32, vcp: u8) !VcpValue {
    const fd = try openBus(bus);
    defer sys.close(fd);
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const req = ddcGetRequest(vcp);
        try sys.writeAll(fd, &req);
        sys.sleepMs(40);
        var reply: [12]u8 = undefined;
        const n = try sys.read(fd, &reply);
        if (ddcParseReply(vcp, reply[0..n])) |v| return v else |e| {
            if (attempt >= 2 or e == error.Unsupported) return e;
            sys.sleepMs(50);
        }
    }
}

pub fn ddcSet(bus: u32, vcp: u8, value: u16) !void {
    const fd = try openBus(bus);
    defer sys.close(fd);
    const req = ddcSetRequest(vcp, value);
    try sys.writeAll(fd, &req);
    sys.sleepMs(50);
}

pub const DdcDisplay = extern struct {
    bus: u32,
    pad: u32 = 0,
    connector: [64]u8,
};

pub const DdcList = sys.List(DdcDisplay);

pub fn ddcDisplays(sysfs: []const u8) !*DdcList {
    const result = try DdcList.create();
    errdefer result.destroy();
    var buf: [512]u8 = undefined;
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}/class/drm", .{sysfs})) catch return result;
    defer d.close();
    while (try d.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "card")) continue;
        const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
        const connector = entry.name[dash + 1 ..];
        if (std.mem.startsWith(u8, connector, "eDP") or std.mem.startsWith(u8, connector, "LVDS") or std.mem.startsWith(u8, connector, "DSI")) continue;
        var sb: [512]u8 = undefined;
        var status: [32]u8 = undefined;
        const st = sys.readTrim(try sys.pathZ(&sb, "{s}/class/drm/{s}/status", .{ sysfs, entry.name }), &status) orelse continue;
        if (!std.mem.eql(u8, st, "connected")) continue;
        var target: [512]u8 = undefined;
        const t = sys.readLink(try sys.pathZ(&sb, "{s}/class/drm/{s}/ddc", .{ sysfs, entry.name }), &target) catch continue;
        const base = sys.baseName(t);
        if (!std.mem.startsWith(u8, base, "i2c-")) continue;
        const bus = std.fmt.parseInt(u32, base[4..], 10) catch continue;
        var dd = std.mem.zeroes(DdcDisplay);
        dd.bus = bus;
        sys.copyName(&dd.connector, connector);
        try result.append(dd);
    }
    return result;
}

test "ddc packets carry the right checksums" {
    const get = ddcGetRequest(0x10);
    try std.testing.expectEqualSlices(u8, &.{ 0x51, 0x82, 0x01, 0x10, 0xac }, &get);
    const set = ddcSetRequest(0x10, 50);
    try std.testing.expectEqual(@as(u8, 0x6e ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32), set[6]);
    var reply = [_]u8{ 0x6e, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2a, 0, 0 };
    reply[10] = checksum(0x50, reply[0..10]);
    const v = try ddcParseReply(0x10, &reply);
    try std.testing.expectEqual(@as(u16, 100), v.maximum);
    try std.testing.expectEqual(@as(u16, 42), v.current);
    reply[3] = 0x01;
    reply[10] = checksum(0x50, reply[0..10]);
    try std.testing.expectError(error.Unsupported, ddcParseReply(0x10, &reply));
    reply[10] ^= 0xff;
    try std.testing.expectError(error.Io, ddcParseReply(0x10, &reply));
}

test "backlights ordered firmware first and bounded writes" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "backlight");
    try sys.put(root, "class/backlight/intel_backlight/max_brightness", "96000\n");
    try sys.put(root, "class/backlight/intel_backlight/brightness", "48000\n");
    try sys.put(root, "class/backlight/intel_backlight/type", "raw\n");
    try sys.put(root, "class/backlight/acpi_video0/max_brightness", "15\n");
    try sys.put(root, "class/backlight/acpi_video0/brightness", "7\n");
    try sys.put(root, "class/backlight/acpi_video0/type", "firmware\n");
    const l = try backlights(root);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 2), l.count());
    try std.testing.expectEqualStrings("acpi_video0", sys.cstr(&l.items.items[0].name));
    try std.testing.expectEqual(@as(i64, 96000), l.items.items[1].max_brightness);
    try setBacklight(root, "intel_backlight", 12000);
    var b: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?i64, 12000), sys.readInt(i64, try sys.pathZ(&b, "{s}/class/backlight/intel_backlight/brightness", .{root})));
    try std.testing.expectError(error.Invalid, setBacklight(root, "intel_backlight", 96001));
    try std.testing.expectError(error.Invalid, setBacklight(root, "../../x", 1));
}

test "external monitors with a ddc bus" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "ddc");
    try sys.put(root, "class/drm/card1-DP-2/status", "connected\n");
    try sys.put(root, "class/drm/card1-eDP-1/status", "connected\n");
    try sys.put(root, "class/drm/card1-HDMI-A-1/status", "disconnected\n");
    var lb: [512]u8 = undefined;
    try sys.symlink("../../../devices/pci0000:00/i2c-7", try sys.pathZ(&lb, "{s}/class/drm/card1-DP-2/ddc", .{root}));
    const l = try ddcDisplays(root);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 1), l.count());
    try std.testing.expectEqual(@as(u32, 7), l.items.items[0].bus);
    try std.testing.expectEqualStrings("DP-2", sys.cstr(&l.items.items[0].connector));
}
