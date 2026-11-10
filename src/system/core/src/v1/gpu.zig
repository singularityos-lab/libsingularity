const std = @import("std");
const sys = @import("../sys.zig");

pub const NvidiaGpu = extern struct {
    temperature_c: i32,
    sm_clock_mhz: i32,
    power_mw: i32,
    utilization_pct: i32,
    memory_used: i64,
    memory_total: i64,
    name: [96]u8,
};

pub const NvidiaList = sys.List(NvidiaGpu);

const Handle = ?*anyopaque;
const Ret = c_int;
const Utilization = extern struct { gpu: c_uint, memory: c_uint };
const Memory = extern struct { total: c_ulonglong, free: c_ulonglong, used: c_ulonglong };

const Api = struct {
    init: *const fn () callconv(.c) Ret,
    count: *const fn (*c_uint) callconv(.c) Ret,
    handle: *const fn (c_uint, *Handle) callconv(.c) Ret,
    name: *const fn (Handle, [*]u8, c_uint) callconv(.c) Ret,
    temperature: *const fn (Handle, c_int, *c_uint) callconv(.c) Ret,
    clock: *const fn (Handle, c_int, *c_uint) callconv(.c) Ret,
    power: *const fn (Handle, *c_uint) callconv(.c) Ret,
    utilization: *const fn (Handle, *Utilization) callconv(.c) Ret,
    memory: *const fn (Handle, *Memory) callconv(.c) Ret,
};

var api: ?Api = null;
var api_state: enum { unknown, ready, missing } = .unknown;
var api_lock: std.c.pthread_mutex_t = .{};

fn sym(lib: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    const p = std.c.dlsym(lib, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn load() ?Api {
    _ = std.c.pthread_mutex_lock(&api_lock);
    defer _ = std.c.pthread_mutex_unlock(&api_lock);
    switch (api_state) {
        .ready => return api,
        .missing => return null,
        .unknown => {},
    }
    api_state = .missing;
    if (!sys.exists("/proc/driver/nvidia")) return null;
    const lib = std.c.dlopen("libnvidia-ml.so.1", .{ .NOW = true }) orelse return null;
    const a = Api{
        .init = sym(lib, @FieldType(Api, "init"), "nvmlInit_v2") orelse return null,
        .count = sym(lib, @FieldType(Api, "count"), "nvmlDeviceGetCount_v2") orelse return null,
        .handle = sym(lib, @FieldType(Api, "handle"), "nvmlDeviceGetHandleByIndex_v2") orelse return null,
        .name = sym(lib, @FieldType(Api, "name"), "nvmlDeviceGetName") orelse return null,
        .temperature = sym(lib, @FieldType(Api, "temperature"), "nvmlDeviceGetTemperature") orelse return null,
        .clock = sym(lib, @FieldType(Api, "clock"), "nvmlDeviceGetClockInfo") orelse return null,
        .power = sym(lib, @FieldType(Api, "power"), "nvmlDeviceGetPowerUsage") orelse return null,
        .utilization = sym(lib, @FieldType(Api, "utilization"), "nvmlDeviceGetUtilizationRates") orelse return null,
        .memory = sym(lib, @FieldType(Api, "memory"), "nvmlDeviceGetMemoryInfo") orelse return null,
    };
    if (a.init() != 0) return null;
    api = a;
    api_state = .ready;
    return a;
}

pub fn nvidia() !*NvidiaList {
    const a = load() orelse return error.NotFound;
    const list = try NvidiaList.create();
    errdefer list.destroy();
    var n: c_uint = 0;
    if (a.count(&n) != 0) return error.Io;
    var i: c_uint = 0;
    while (i < n) : (i += 1) {
        var h: Handle = null;
        if (a.handle(i, &h) != 0) continue;
        var g = std.mem.zeroes(NvidiaGpu);
        g.temperature_c = -1;
        g.sm_clock_mhz = -1;
        g.power_mw = -1;
        g.utilization_pct = -1;
        g.memory_used = -1;
        g.memory_total = -1;
        if (a.name(h, &g.name, g.name.len) != 0) sys.copyName(&g.name, "NVIDIA GPU");
        g.name[g.name.len - 1] = 0;
        var v: c_uint = 0;
        if (a.temperature(h, 0, &v) == 0) g.temperature_c = @intCast(v);
        if (a.clock(h, 1, &v) == 0) g.sm_clock_mhz = @intCast(v);
        if (a.power(h, &v) == 0) g.power_mw = @intCast(v);
        var u: Utilization = undefined;
        if (a.utilization(h, &u) == 0) g.utilization_pct = @intCast(u.gpu);
        var m: Memory = undefined;
        if (a.memory(h, &m) == 0) {
            g.memory_used = @intCast(m.used);
            g.memory_total = @intCast(m.total);
        }
        try list.append(g);
    }
    return list;
}

test "no nvidia driver means not found" {
    if (sys.exists("/proc/driver/nvidia")) return error.SkipZigTest;
    try std.testing.expectError(error.NotFound, nvidia());
}
