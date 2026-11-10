const std = @import("std");
const sys = @import("../sys.zig");

pub const Kind = enum(u32) { temperature = 0, fan = 1, voltage = 2, power = 3, current = 4, energy = 5, humidity = 6 };

pub const Reading = extern struct {
    kind: u32,
    has_max: u8,
    has_crit: u8,
    has_min: u8,
    pad: u8 = 0,
    value: i64,
    min: i64,
    max: i64,
    crit: i64,
    chip: [64]u8,
    label: [64]u8,
    device: [128]u8,
};

pub const ReadingList = sys.List(Reading);

const prefixes = [_]struct { name: []const u8, kind: Kind }{
    .{ .name = "temp", .kind = .temperature },
    .{ .name = "fan", .kind = .fan },
    .{ .name = "in", .kind = .voltage },
    .{ .name = "power", .kind = .power },
    .{ .name = "curr", .kind = .current },
    .{ .name = "energy", .kind = .energy },
    .{ .name = "humidity", .kind = .humidity },
};

fn classify(file: []const u8) ?struct { kind: Kind, index: []const u8 } {
    if (!std.mem.endsWith(u8, file, "_input")) return null;
    const stem = file[0 .. file.len - "_input".len];
    for (prefixes) |p| {
        if (!std.mem.startsWith(u8, stem, p.name)) continue;
        const idx = stem[p.name.len..];
        if (idx.len == 0) continue;
        for (idx) |c| if (!std.ascii.isDigit(c)) return null;
        return .{ .kind = p.kind, .index = idx };
    }
    return null;
}

fn readAttr(dir: []const u8, stem: []const u8, attr: []const u8) ?i64 {
    var buf: [512]u8 = undefined;
    const p = sys.pathZ(&buf, "{s}/{s}_{s}", .{ dir, stem, attr }) catch return null;
    return sys.readInt(i64, p);
}

fn readName(path: [*:0]const u8, dst: []u8) bool {
    var buf: [256]u8 = undefined;
    const s = sys.readTrim(path, &buf) orelse return false;
    sys.copyName(dst, s);
    return true;
}

fn chipDevice(dir: []const u8, dst: []u8) void {
    var buf: [512]u8 = undefined;
    const p = sys.pathZ(&buf, "{s}/device", .{dir}) catch return;
    var target: [512]u8 = undefined;
    const t = sys.readLink(p, &target) catch {
        sys.copyName(dst, "");
        return;
    };
    sys.copyName(dst, sys.baseName(t));
}

fn hwmonChip(result: *ReadingList, dir: []const u8) !void {
    var chip: [64]u8 = undefined;
    var buf: [512]u8 = undefined;
    if (!readName(try sys.pathZ(&buf, "{s}/name", .{dir}), &chip)) sys.copyName(&chip, sys.baseName(dir));
    var device: [128]u8 = undefined;
    chipDevice(dir, &device);
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}", .{dir})) catch return;
    defer d.close();
    while (try d.next()) |entry| {
        const c = classify(entry.name) orelse continue;
        const stem = entry.name[0 .. entry.name.len - "_input".len];
        const value = readAttr(dir, stem, "input") orelse continue;
        var r = std.mem.zeroes(Reading);
        r.kind = @intFromEnum(c.kind);
        r.value = value;
        r.chip = chip;
        r.device = device;
        if (readAttr(dir, stem, "max")) |v| {
            r.max = v;
            r.has_max = 1;
        }
        if (readAttr(dir, stem, "crit")) |v| {
            r.crit = v;
            r.has_crit = 1;
        }
        if (readAttr(dir, stem, "min")) |v| {
            r.min = v;
            r.has_min = 1;
        }
        var lbuf: [512]u8 = undefined;
        if (!readName(try sys.pathZ(&lbuf, "{s}/{s}_label", .{ dir, stem }), &r.label)) sys.copyName(&r.label, stem);
        try result.append(r);
    }
}

fn thermalZone(result: *ReadingList, dir: []const u8) !void {
    var buf: [512]u8 = undefined;
    const value = sys.readInt(i64, try sys.pathZ(&buf, "{s}/temp", .{dir})) orelse return;
    var r = std.mem.zeroes(Reading);
    r.kind = @intFromEnum(Kind.temperature);
    r.value = value;
    if (!readName(try sys.pathZ(&buf, "{s}/type", .{dir}), &r.chip)) sys.copyName(&r.chip, sys.baseName(dir));
    sys.copyName(&r.label, sys.baseName(dir));
    sys.copyName(&r.device, "thermal");
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        var tbuf: [64]u8 = undefined;
        const kind = sys.readTrim(try sys.pathZ(&buf, "{s}/trip_point_{d}_type", .{ dir, i }), &tbuf) orelse break;
        const temp = sys.readInt(i64, try sys.pathZ(&buf, "{s}/trip_point_{d}_temp", .{ dir, i })) orelse continue;
        if (std.mem.eql(u8, kind, "critical")) {
            r.crit = temp;
            r.has_crit = 1;
        } else if (std.mem.eql(u8, kind, "hot") or (std.mem.eql(u8, kind, "passive") and r.has_max == 0)) {
            r.max = temp;
            r.has_max = 1;
        }
    }
    try result.append(r);
}

fn eachDir(root: []const u8, sub: []const u8, prefix: []const u8, result: *ReadingList, f: fn (*ReadingList, []const u8) anyerror!void) !void {
    var buf: [512]u8 = undefined;
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}/{s}", .{ root, sub })) catch return;
    defer d.close();
    while (try d.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        var pbuf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}", .{ root, sub, entry.name }) catch continue;
        try f(result, path);
    }
}

pub fn list(sysfs: []const u8, thermal: bool) !*ReadingList {
    const result = try ReadingList.create();
    errdefer result.destroy();
    try eachDir(sysfs, "class/hwmon", "hwmon", result, hwmonChip);
    if (thermal) try eachDir(sysfs, "class/thermal", "thermal_zone", result, thermalZone);
    return result;
}

fn sysctlPath(buf: []u8, procfs: []const u8, name: []const u8) ![*:0]const u8 {
    if (name.len == 0 or name.len > 200) return error.Invalid;
    if (std.mem.indexOf(u8, name, "..") != null or name[0] == '.' or name[0] == '/') return error.Invalid;
    var tmp: [256]u8 = undefined;
    @memcpy(tmp[0..name.len], name);
    for (tmp[0..name.len]) |*c| {
        if (c.* == '.') c.* = '/' else if (c.* == '/') return error.Invalid;
    }
    return sys.pathZ(buf, "{s}/sys/{s}", .{ procfs, tmp[0..name.len] });
}

pub fn sysctlGet(procfs: []const u8, name: []const u8, out: []u8) !usize {
    var buf: [512]u8 = undefined;
    const p = try sysctlPath(&buf, procfs, name);
    var data: [4096]u8 = undefined;
    const s = sys.trim(try sys.readFile(p, &data));
    if (s.len + 1 > out.len) return error.TooBig;
    @memcpy(out[0..s.len], s);
    out[s.len] = 0;
    return s.len;
}

pub fn sysctlSet(procfs: []const u8, name: []const u8, value: []const u8) !void {
    var buf: [512]u8 = undefined;
    try sys.writeFile(try sysctlPath(&buf, procfs, name), value);
}

test "hwmon and thermal zones from a fake sysfs" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "sensors");
    try sys.put(root, "class/hwmon/hwmon0/name", "k10temp\n");
    try sys.put(root, "class/hwmon/hwmon0/temp1_input", "48250\n");
    try sys.put(root, "class/hwmon/hwmon0/temp1_label", "Tctl\n");
    try sys.put(root, "class/hwmon/hwmon0/temp1_crit", "100000\n");
    try sys.put(root, "class/hwmon/hwmon1/name", "thinkpad\n");
    try sys.put(root, "class/hwmon/hwmon1/fan1_input", "2900\n");
    try sys.put(root, "class/hwmon/hwmon1/temp12_input", "39000\n");
    try sys.put(root, "class/hwmon/hwmon1/pwm1", "128\n");
    try sys.put(root, "class/thermal/thermal_zone0/type", "x86_pkg_temp\n");
    try sys.put(root, "class/thermal/thermal_zone0/temp", "51000\n");
    try sys.put(root, "class/thermal/thermal_zone0/trip_point_0_type", "passive\n");
    try sys.put(root, "class/thermal/thermal_zone0/trip_point_0_temp", "95000\n");
    try sys.put(root, "class/thermal/thermal_zone0/trip_point_1_type", "critical\n");
    try sys.put(root, "class/thermal/thermal_zone0/trip_point_1_temp", "105000\n");
    const l = try list(root, true);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 4), l.count());
    var seen: u32 = 0;
    for (l.items.items) |r| {
        const label = sys.cstr(&r.label);
        if (std.mem.eql(u8, label, "Tctl")) {
            try std.testing.expectEqual(@as(i64, 48250), r.value);
            try std.testing.expectEqual(@as(i64, 100000), r.crit);
            try std.testing.expectEqualStrings("k10temp", sys.cstr(&r.chip));
            seen |= 1;
        } else if (std.mem.eql(u8, label, "fan1")) {
            try std.testing.expectEqual(@as(u32, @intFromEnum(Kind.fan)), r.kind);
            try std.testing.expectEqual(@as(i64, 2900), r.value);
            seen |= 2;
        } else if (std.mem.eql(u8, label, "temp12")) {
            seen |= 4;
        } else if (std.mem.eql(u8, label, "thermal_zone0")) {
            try std.testing.expectEqualStrings("x86_pkg_temp", sys.cstr(&r.chip));
            try std.testing.expectEqual(@as(i64, 95000), r.max);
            try std.testing.expectEqual(@as(i64, 105000), r.crit);
            seen |= 8;
        }
    }
    try std.testing.expectEqual(@as(u32, 15), seen);
}

test "sysctl names map onto procfs and reject traversal" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "sysctl");
    try sys.put(root, "sys/vm/swappiness", "60\n");
    var out: [32]u8 = undefined;
    const n = try sysctlGet(root, "vm.swappiness", &out);
    try std.testing.expectEqualStrings("60", out[0..n]);
    try sysctlSet(root, "vm.swappiness", "10");
    _ = try sysctlGet(root, "vm.swappiness", &out);
    try std.testing.expectEqualStrings("10", sys.cstr(&out));
    try std.testing.expectError(error.Invalid, sysctlGet(root, "vm/../../etc", &out));
    try std.testing.expectError(error.Invalid, sysctlGet(root, "..vm", &out));
}
