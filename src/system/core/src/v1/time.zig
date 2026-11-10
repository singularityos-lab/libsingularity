const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const RtcTime = extern struct {
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
};

pub const ClockState = extern struct {
    synchronized: i32,
    state: i32,
    status: u32,
    pad: u32 = 0,
    offset_ns: i64,
    max_error_us: i64,
    est_error_us: i64,
};

const KernelRtc = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
};

const Timex = extern struct {
    modes: c_uint,
    offset: c_long,
    freq: c_long,
    maxerror: c_long,
    esterror: c_long,
    status: c_int,
    constant: c_long,
    precision: c_long,
    tolerance: c_long,
    time_sec: c_long,
    time_usec: c_long,
    tick: c_long,
    ppsfreq: c_long,
    jitter: c_long,
    shift: c_int,
    stabil: c_long,
    jitcnt: c_long,
    calcnt: c_long,
    errcnt: c_long,
    stbcnt: c_long,
    tai: c_int,
    reserved: [11]c_int,
};

const sta_unsync: c_int = 0x0040;
const sta_nano: c_int = 0x2000;
const time_error: usize = 5;

fn ior(nr: u8, size: usize) u32 {
    return (2 << 30) | (@as(u32, @intCast(size)) << 16) | (@as(u32, 'p') << 8) | nr;
}

fn iow(nr: u8, size: usize) u32 {
    return (1 << 30) | (@as(u32, @intCast(size)) << 16) | (@as(u32, 'p') << 8) | nr;
}

const rtc_rd_time = ior(0x09, @sizeOf(KernelRtc));
const rtc_set_time = iow(0x0a, @sizeOf(KernelRtc));

const rtc_devices = [_][*:0]const u8{ "/dev/rtc0", "/dev/rtc" };

fn daysBefore(year: i32, month: i32) i32 {
    const cum = [_]i32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    var d = cum[@intCast(month - 1)];
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    if (leap and month > 2) d += 1;
    return d;
}

fn weekday(year: i32, month: i32, day: i32) i32 {
    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const y = if (month < 3) year - 1 else year;
    return @mod(y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + t[@intCast(month - 1)] + day, 7);
}

pub fn valid(t: RtcTime) bool {
    if (t.year < 1970 or t.year > 2199 or t.month < 1 or t.month > 12) return false;
    if (t.hour < 0 or t.hour > 23 or t.minute < 0 or t.minute > 59 or t.second < 0 or t.second > 59) return false;
    const len = daysBefore(t.year, if (t.month == 12) 12 else t.month + 1) - daysBefore(t.year, t.month);
    const days = if (t.month == 12) 31 else len;
    return t.day >= 1 and t.day <= days;
}

pub fn toKernel(t: RtcTime) KernelRtc {
    return .{
        .sec = t.second,
        .min = t.minute,
        .hour = t.hour,
        .mday = t.day,
        .mon = t.month - 1,
        .year = t.year - 1900,
        .wday = weekday(t.year, t.month, t.day),
        .yday = daysBefore(t.year, t.month) + t.day - 1,
        .isdst = 0,
    };
}

pub fn fromKernel(k: KernelRtc) RtcTime {
    return .{ .year = k.year + 1900, .month = k.mon + 1, .day = k.mday, .hour = k.hour, .minute = k.min, .second = k.sec };
}

pub fn rtcReadFrom(dev: [*:0]const u8) !RtcTime {
    const fd = try sys.open(dev, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer sys.close(fd);
    var k = std.mem.zeroes(KernelRtc);
    _ = try sys.ioctl(fd, rtc_rd_time, @intFromPtr(&k));
    return fromKernel(k);
}

pub fn rtcRead() !RtcTime {
    var last: anyerror = error.NotFound;
    for (rtc_devices) |dev| {
        if (rtcReadFrom(dev)) |t| return t else |e| last = e;
    }
    return last;
}

pub fn rtcWrite(t: RtcTime) !void {
    if (!valid(t)) return error.Invalid;
    var k = toKernel(t);
    var last: anyerror = error.NotFound;
    for (rtc_devices) |dev| {
        const fd = sys.open(dev, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |e| {
            last = e;
            continue;
        };
        defer sys.close(fd);
        if (sys.ioctl(fd, rtc_set_time, @intFromPtr(&k))) |_| return else |e| last = e;
    }
    return last;
}

pub fn clock() !ClockState {
    var tx = std.mem.zeroes(Timex);
    const rc = linux.syscall1(.adjtimex, @intFromPtr(&tx));
    const state = try sys.check(rc);
    const nano = tx.status & sta_nano != 0;
    return .{
        .synchronized = @intFromBool(state != time_error and tx.status & sta_unsync == 0),
        .state = @intCast(state),
        .status = @bitCast(tx.status),
        .offset_ns = if (nano) tx.offset else tx.offset * 1000,
        .max_error_us = tx.maxerror,
        .est_error_us = tx.esterror,
    };
}

pub fn zoneFromLink(target: []const u8) ?[]const u8 {
    const marker = "zoneinfo/";
    const i = std.mem.lastIndexOf(u8, target, marker) orelse return null;
    const name = target[i + marker.len ..];
    if (name.len == 0 or name[0] == '/') return null;
    return name;
}

pub fn zone(localtime: [*:0]const u8, buf: []u8) ![]const u8 {
    var link: [512]u8 = undefined;
    const target = try sys.readLink(localtime, &link);
    const name = zoneFromLink(target) orelse return error.NotFound;
    if (name.len >= buf.len) return error.TooBig;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len];
}

test "rtc fields round trip through the kernel layout" {
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(KernelRtc));
    try std.testing.expectEqual(@as(u32, 0x80247009), rtc_rd_time);
    try std.testing.expectEqual(@as(u32, 0x4024700a), rtc_set_time);
    const t = RtcTime{ .year = 2026, .month = 11, .day = 10, .hour = 9, .minute = 15, .second = 3 };
    const k = toKernel(t);
    try std.testing.expectEqual(@as(c_int, 126), k.year);
    try std.testing.expectEqual(@as(c_int, 10), k.mon);
    try std.testing.expectEqual(@as(c_int, 2), k.wday);
    try std.testing.expectEqual(@as(c_int, 313), k.yday);
    try std.testing.expectEqual(t, fromKernel(k));
    try std.testing.expect(!valid(.{ .year = 2026, .month = 2, .day = 29, .hour = 0, .minute = 0, .second = 0 }));
    try std.testing.expect(valid(.{ .year = 2028, .month = 2, .day = 29, .hour = 0, .minute = 0, .second = 0 }));
    try std.testing.expect(valid(.{ .year = 2026, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 }));
    try std.testing.expectError(error.Invalid, rtcWrite(.{ .year = 2026, .month = 13, .day = 1, .hour = 0, .minute = 0, .second = 0 }));
}

test "timex matches the kernel size" {
    if (@sizeOf(c_long) == 8) try std.testing.expectEqual(@as(usize, 208), @sizeOf(Timex));
}

test "clock state is readable without privileges" {
    const c = try clock();
    try std.testing.expect(c.state >= 0 and c.state <= 5);
    try std.testing.expect(c.max_error_us >= 0);
}

test "zone name from the localtime link" {
    try std.testing.expectEqualStrings("Europe/Rome", zoneFromLink("../usr/share/zoneinfo/Europe/Rome").?);
    try std.testing.expectEqualStrings("UTC", zoneFromLink("/usr/share/zoneinfo/UTC").?);
    try std.testing.expect(zoneFromLink("/etc/foo") == null);
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "zone");
    var lb: [600]u8 = undefined;
    const link = try sys.pathZ(&lb, "{s}/localtime", .{root});
    _ = linux.unlinkat(linux.AT.FDCWD, link, 0);
    try sys.symlink("../usr/share/zoneinfo/America/New_York", link);
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("America/New_York", try zone(link, &out));
}
