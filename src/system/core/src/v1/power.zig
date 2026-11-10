const std = @import("std");
const sys = @import("../sys.zig");

pub const SupplyType = enum(u32) { unknown = 0, battery = 1, mains = 2, usb = 3, ups = 4, wireless = 5 };
pub const Status = enum(u32) { unknown = 0, charging = 1, discharging = 2, not_charging = 3, full = 4 };

pub const Supply = extern struct {
    kind: u32,
    status: u32,
    online: i32,
    present: i32,
    capacity: i32,
    device_scope: i32,
    cycle_count: i32,
    charge_start_threshold: i32,
    charge_end_threshold: i32,
    pad: i32 = 0,
    energy_now: i64,
    energy_full: i64,
    energy_full_design: i64,
    power_now: i64,
    voltage_now: i64,
    time_to_empty: i64,
    time_to_full: i64,
    name: [64]u8,
    model: [64]u8,
    manufacturer: [64]u8,
    technology: [32]u8,
    serial: [64]u8,
};

pub const SupplyList = sys.List(Supply);

fn attr(dir: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const p = sys.pathZ(&buf, "{s}/{s}", .{ dir, name }) catch return null;
    return sys.readTrim(p, out);
}

fn attrInt(dir: []const u8, name: []const u8) ?i64 {
    var buf: [512]u8 = undefined;
    const p = sys.pathZ(&buf, "{s}/{s}", .{ dir, name }) catch return null;
    return sys.readInt(i64, p);
}

fn attrStr(dir: []const u8, name: []const u8, dst: []u8) void {
    var tmp: [256]u8 = undefined;
    sys.copyName(dst, attr(dir, name, &tmp) orelse "");
}

fn parseType(s: []const u8) SupplyType {
    if (std.mem.eql(u8, s, "Battery")) return .battery;
    if (std.mem.eql(u8, s, "Mains")) return .mains;
    if (std.mem.startsWith(u8, s, "USB")) return .usb;
    if (std.mem.eql(u8, s, "UPS")) return .ups;
    if (std.mem.eql(u8, s, "Wireless")) return .wireless;
    return .unknown;
}

fn parseStatus(s: []const u8) Status {
    if (std.mem.eql(u8, s, "Charging")) return .charging;
    if (std.mem.eql(u8, s, "Discharging")) return .discharging;
    if (std.mem.eql(u8, s, "Not charging")) return .not_charging;
    if (std.mem.eql(u8, s, "Full")) return .full;
    return .unknown;
}

pub fn readSupply(dir: []const u8, s: *Supply) void {
    s.* = std.mem.zeroes(Supply);
    var tmp: [64]u8 = undefined;
    s.kind = @intFromEnum(parseType(attr(dir, "type", &tmp) orelse ""));
    s.status = @intFromEnum(parseStatus(attr(dir, "status", &tmp) orelse ""));
    s.device_scope = if (std.mem.eql(u8, attr(dir, "scope", &tmp) orelse "", "Device")) 1 else 0;
    s.online = @intCast(attrInt(dir, "online") orelse -1);
    s.present = @intCast(attrInt(dir, "present") orelse -1);
    s.capacity = @intCast(attrInt(dir, "capacity") orelse -1);
    s.cycle_count = @intCast(attrInt(dir, "cycle_count") orelse -1);
    s.charge_start_threshold = @intCast(attrInt(dir, "charge_control_start_threshold") orelse -1);
    s.charge_end_threshold = @intCast(attrInt(dir, "charge_control_end_threshold") orelse -1);
    s.voltage_now = attrInt(dir, "voltage_now") orelse -1;
    const design_voltage = attrInt(dir, "voltage_min_design") orelse s.voltage_now;
    s.energy_now = attrInt(dir, "energy_now") orelse fromCharge(attrInt(dir, "charge_now"), s.voltage_now);
    s.energy_full = attrInt(dir, "energy_full") orelse fromCharge(attrInt(dir, "charge_full"), design_voltage);
    s.energy_full_design = attrInt(dir, "energy_full_design") orelse fromCharge(attrInt(dir, "charge_full_design"), design_voltage);
    const raw_power = attrInt(dir, "power_now") orelse fromCurrent(attrInt(dir, "current_now"), s.voltage_now);
    s.power_now = if (raw_power == -1) -1 else if (raw_power < 0) -raw_power else raw_power;
    s.time_to_empty = attrInt(dir, "time_to_empty_now") orelse -1;
    s.time_to_full = attrInt(dir, "time_to_full_now") orelse -1;
    if (s.capacity < 0 and s.energy_now > 0 and s.energy_full > 0)
        s.capacity = @intCast(@min(100, @divTrunc(s.energy_now * 100, s.energy_full)));
    if (s.power_now > 0 and s.time_to_empty < 0 and s.status == @intFromEnum(Status.discharging) and s.energy_now > 0)
        s.time_to_empty = @divTrunc(s.energy_now * 3600, s.power_now);
    if (s.power_now > 0 and s.time_to_full < 0 and s.status == @intFromEnum(Status.charging) and s.energy_full > s.energy_now)
        s.time_to_full = @divTrunc((s.energy_full - s.energy_now) * 3600, s.power_now);
    sys.copyName(&s.name, sys.baseName(dir));
    attrStr(dir, "model_name", &s.model);
    attrStr(dir, "manufacturer", &s.manufacturer);
    attrStr(dir, "technology", &s.technology);
    attrStr(dir, "serial_number", &s.serial);
}

fn fromCharge(charge: ?i64, voltage: i64) i64 {
    const c = charge orelse return -1;
    if (voltage <= 0) return -1;
    return @divTrunc(c * voltage, 1_000_000);
}

fn fromCurrent(current: ?i64, voltage: i64) i64 {
    const c = current orelse return -1;
    if (voltage <= 0) return -1;
    const p = @divTrunc(c * voltage, 1_000_000);
    return if (p == -1) -2 else p;
}

pub fn supplies(sysfs: []const u8) !*SupplyList {
    const result = try SupplyList.create();
    errdefer result.destroy();
    var buf: [512]u8 = undefined;
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}/class/power_supply", .{sysfs})) catch return result;
    defer d.close();
    while (try d.next()) |entry| {
        var pbuf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/class/power_supply/{s}", .{ sysfs, entry.name }) catch continue;
        var s: Supply = undefined;
        readSupply(path, &s);
        try result.append(s);
    }
    return result;
}

fn supplyAttr(buf: []u8, sysfs: []const u8, name: []const u8, file: []const u8) ![*:0]const u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, "..")) return error.Invalid;
    return sys.pathZ(buf, "{s}/class/power_supply/{s}/{s}", .{ sysfs, name, file });
}

pub fn setChargeThresholds(sysfs: []const u8, name: []const u8, start: i32, end: i32) !void {
    if (end < 1 or end > 100 or start < -1 or start >= end) return error.Invalid;
    var buf: [512]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    const endp = try supplyAttr(&buf, sysfs, name, "charge_control_end_threshold");
    if (!sys.exists(endp)) return error.Unsupported;
    var startbuf: [512]u8 = undefined;
    const startp = try supplyAttr(&startbuf, sysfs, name, "charge_control_start_threshold");
    const current_start = sys.readInt(i32, startp);
    if (start >= 0 and current_start != null and current_start.? >= end) {
        try sys.writeFile(startp, try std.fmt.bufPrint(&vbuf, "{d}", .{start}));
        try sys.writeFile(endp, try std.fmt.bufPrint(&vbuf, "{d}", .{end}));
        return;
    }
    try sys.writeFile(endp, try std.fmt.bufPrint(&vbuf, "{d}", .{end}));
    if (start >= 0 and current_start != null) try sys.writeFile(startp, try std.fmt.bufPrint(&vbuf, "{d}", .{start}));
}

pub fn platformProfile(sysfs: []const u8, current: []u8, choices: []u8) !void {
    var buf: [512]u8 = undefined;
    var tmp: [512]u8 = undefined;
    const cur = sys.readTrim(try sys.pathZ(&buf, "{s}/firmware/acpi/platform_profile", .{sysfs}), &tmp) orelse return error.Unsupported;
    sys.copyName(current, cur);
    const ch = sys.readTrim(try sys.pathZ(&buf, "{s}/firmware/acpi/platform_profile_choices", .{sysfs}), &tmp) orelse "";
    sys.copyName(choices, ch);
}

pub fn setPlatformProfile(sysfs: []const u8, profile: []const u8) !void {
    var buf: [512]u8 = undefined;
    var tmp: [512]u8 = undefined;
    const ch = sys.readTrim(try sys.pathZ(&buf, "{s}/firmware/acpi/platform_profile_choices", .{sysfs}), &tmp) orelse return error.Unsupported;
    var it = std.mem.tokenizeScalar(u8, ch, ' ');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, profile)) {
            return sys.writeFile(try sys.pathZ(&buf, "{s}/firmware/acpi/platform_profile", .{sysfs}), profile);
        }
    }
    return error.Invalid;
}

pub const CpuPolicy = extern struct {
    id: i32,
    online: i32,
    cur_khz: i64,
    min_khz: i64,
    max_khz: i64,
    hw_min_khz: i64,
    hw_max_khz: i64,
    governor: [32]u8,
    governors: [128]u8,
    epp: [32]u8,
    epps: [160]u8,
    driver: [32]u8,
    cpus: [64]u8,
};

pub const CpuPolicyList = sys.List(CpuPolicy);

pub fn cpuPolicies(sysfs: []const u8) !*CpuPolicyList {
    const result = try CpuPolicyList.create();
    errdefer result.destroy();
    var buf: [512]u8 = undefined;
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}/devices/system/cpu/cpufreq", .{sysfs})) catch return result;
    defer d.close();
    while (try d.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "policy")) continue;
        const id = std.fmt.parseInt(i32, entry.name["policy".len..], 10) catch continue;
        var pbuf: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&pbuf, "{s}/devices/system/cpu/cpufreq/{s}", .{ sysfs, entry.name }) catch continue;
        var p = std.mem.zeroes(CpuPolicy);
        p.id = id;
        p.cur_khz = attrInt(dir, "scaling_cur_freq") orelse -1;
        p.min_khz = attrInt(dir, "scaling_min_freq") orelse -1;
        p.max_khz = attrInt(dir, "scaling_max_freq") orelse -1;
        p.hw_min_khz = attrInt(dir, "cpuinfo_min_freq") orelse -1;
        p.hw_max_khz = attrInt(dir, "cpuinfo_max_freq") orelse -1;
        p.online = if (p.cur_khz >= 0) 1 else 0;
        attrStr(dir, "scaling_governor", &p.governor);
        attrStr(dir, "scaling_available_governors", &p.governors);
        attrStr(dir, "energy_performance_preference", &p.epp);
        attrStr(dir, "energy_performance_available_preferences", &p.epps);
        attrStr(dir, "scaling_driver", &p.driver);
        attrStr(dir, "affected_cpus", &p.cpus);
        try result.append(p);
    }
    std.mem.sort(CpuPolicy, result.items.items, {}, struct {
        fn lt(_: void, a: CpuPolicy, b: CpuPolicy) bool {
            return a.id < b.id;
        }
    }.lt);
    return result;
}

fn writeAllPolicies(sysfs: []const u8, file: []const u8, choices_file: []const u8, value: []const u8) !void {
    var buf: [512]u8 = undefined;
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}/devices/system/cpu/cpufreq", .{sysfs})) catch return error.Unsupported;
    defer d.close();
    var any = false;
    while (try d.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "policy")) continue;
        var pbuf: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&pbuf, "{s}/devices/system/cpu/cpufreq/{s}", .{ sysfs, entry.name }) catch continue;
        var tmp: [256]u8 = undefined;
        const choices = attr(dir, choices_file, &tmp) orelse continue;
        var ok = false;
        var it = std.mem.tokenizeScalar(u8, choices, ' ');
        while (it.next()) |c| if (std.mem.eql(u8, c, value)) {
            ok = true;
        };
        if (!ok) return error.Invalid;
        var fbuf: [512]u8 = undefined;
        try sys.writeFile(try sys.pathZ(&fbuf, "{s}/{s}", .{ dir, file }), value);
        any = true;
    }
    if (!any) return error.Unsupported;
}

pub fn setGovernor(sysfs: []const u8, governor: []const u8) !void {
    return writeAllPolicies(sysfs, "scaling_governor", "scaling_available_governors", governor);
}

pub fn setEnergyPreference(sysfs: []const u8, epp: []const u8) !void {
    return writeAllPolicies(sysfs, "energy_performance_preference", "energy_performance_available_preferences", epp);
}

test "battery from charge and current attributes" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "power");
    try sys.put(root, "class/power_supply/BAT0/type", "Battery\n");
    try sys.put(root, "class/power_supply/BAT0/status", "Discharging\n");
    try sys.put(root, "class/power_supply/BAT0/present", "1\n");
    try sys.put(root, "class/power_supply/BAT0/charge_now", "2000000\n");
    try sys.put(root, "class/power_supply/BAT0/charge_full", "4000000\n");
    try sys.put(root, "class/power_supply/BAT0/charge_full_design", "5000000\n");
    try sys.put(root, "class/power_supply/BAT0/current_now", "1000000\n");
    try sys.put(root, "class/power_supply/BAT0/voltage_now", "12000000\n");
    try sys.put(root, "class/power_supply/BAT0/model_name", "5B10W\n");
    try sys.put(root, "class/power_supply/BAT0/charge_control_end_threshold", "100\n");
    try sys.put(root, "class/power_supply/BAT0/charge_control_start_threshold", "95\n");
    try sys.put(root, "class/power_supply/AC/type", "Mains\n");
    try sys.put(root, "class/power_supply/AC/online", "0\n");
    const l = try supplies(root);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 2), l.count());
    for (l.items.items) |s| {
        if (s.kind != @intFromEnum(SupplyType.battery)) {
            try std.testing.expectEqual(@as(i32, 0), s.online);
            try std.testing.expectEqual(@as(i64, -1), s.power_now);
            continue;
        }
        try std.testing.expectEqual(@as(i64, 24_000_000), s.energy_now);
        try std.testing.expectEqual(@as(i64, 48_000_000), s.energy_full);
        try std.testing.expectEqual(@as(i64, 12_000_000), s.power_now);
        try std.testing.expectEqual(@as(i32, 50), s.capacity);
        try std.testing.expectEqual(@as(i64, 7200), s.time_to_empty);
        try std.testing.expectEqualStrings("5B10W", sys.cstr(&s.model));
    }
    try setChargeThresholds(root, "BAT0", 75, 80);
    var b: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?i64, 80), sys.readInt(i64, try sys.pathZ(&b, "{s}/class/power_supply/BAT0/charge_control_end_threshold", .{root})));
    try std.testing.expectEqual(@as(?i64, 75), sys.readInt(i64, try sys.pathZ(&b, "{s}/class/power_supply/BAT0/charge_control_start_threshold", .{root})));
    try std.testing.expectError(error.Invalid, setChargeThresholds(root, "../x", 10, 80));
    try std.testing.expectError(error.Invalid, setChargeThresholds(root, "BAT0", 90, 80));
}

test "profiles and cpu policies" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "cpufreq");
    try sys.put(root, "firmware/acpi/platform_profile", "balanced\n");
    try sys.put(root, "firmware/acpi/platform_profile_choices", "low-power balanced performance\n");
    var cur: [32]u8 = undefined;
    var choices: [128]u8 = undefined;
    try platformProfile(root, &cur, &choices);
    try std.testing.expectEqualStrings("balanced", sys.cstr(&cur));
    try setPlatformProfile(root, "performance");
    try platformProfile(root, &cur, &choices);
    try std.testing.expectEqualStrings("performance", sys.cstr(&cur));
    try std.testing.expectError(error.Invalid, setPlatformProfile(root, "turbo"));
    inline for (.{ "policy0", "policy4" }) |p| {
        try sys.put(root, "devices/system/cpu/cpufreq/" ++ p ++ "/scaling_cur_freq", "2400000\n");
        try sys.put(root, "devices/system/cpu/cpufreq/" ++ p ++ "/scaling_governor", "powersave\n");
        try sys.put(root, "devices/system/cpu/cpufreq/" ++ p ++ "/scaling_available_governors", "performance powersave\n");
        try sys.put(root, "devices/system/cpu/cpufreq/" ++ p ++ "/energy_performance_preference", "balance_performance\n");
        try sys.put(root, "devices/system/cpu/cpufreq/" ++ p ++ "/energy_performance_available_preferences", "default performance balance_performance balance_power power\n");
    }
    try setGovernor(root, "performance");
    try setEnergyPreference(root, "power");
    try std.testing.expectError(error.Invalid, setGovernor(root, "ondemand"));
    const l = try cpuPolicies(root);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 2), l.count());
    try std.testing.expectEqual(@as(i32, 0), l.items.items[0].id);
    try std.testing.expectEqual(@as(i32, 4), l.items.items[1].id);
    for (l.items.items) |p| {
        try std.testing.expectEqualStrings("performance", sys.cstr(&p.governor));
        try std.testing.expectEqualStrings("power", sys.cstr(&p.epp));
        try std.testing.expectEqual(@as(i64, 2400000), p.cur_khz);
    }
}
