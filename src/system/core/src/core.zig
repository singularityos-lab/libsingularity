const std = @import("std");
const sys = @import("sys.zig");
pub const proc = @import("v1/proc.zig");
pub const sensors = @import("v1/sensors.zig");
pub const power = @import("v1/power.zig");
pub const display = @import("v1/display.zig");
pub const device = @import("v1/device.zig");
pub const net = @import("v1/net.zig");
pub const i18n = @import("v1/i18n.zig");
pub const gpu = @import("v1/gpu.zig");
pub const firewall = @import("v1/firewall.zig");
pub const audio = @import("v1/audio.zig");
pub const time = @import("v1/time.zig");
pub const session = @import("v1/session.zig");

const sysfs = "/sys";
const procfs = "/proc";

pub const version_major: u32 = 1;
pub const version_minor: u32 = 0;

export fn sinty_system_version(major: ?*u32, minor: ?*u32) void {
    if (major) |m| m.* = version_major;
    if (minor) |m| m.* = version_minor;
}

export fn sinty_string_free(s: ?[*:0]u8) void {
    if (s) |p| sys.gpa.free(std.mem.span(p));
}

export fn sinty_proc_list(out: *?*proc.ProcessList) c_int {
    out.* = proc.list("/proc") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_proc_list_count(l: *const proc.ProcessList) usize {
    return l.items.items.len;
}

export fn sinty_proc_list_at(l: *const proc.ProcessList, i: usize) ?*const proc.Process {
    if (i >= l.items.items.len) return null;
    return &l.items.items[i];
}

export fn sinty_proc_list_free(l: ?*proc.ProcessList) void {
    if (l) |p| {
        p.deinit();
        sys.gpa.destroy(p);
    }
}

export fn sinty_proc_get(pid: i32, out: *proc.Process) c_int {
    proc.read(pid, out, false) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_proc_signal(pid: i32, sig: i32) c_int {
    proc.signal(pid, sig) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_proc_get_nice(pid: i32, out: *i32) c_int {
    out.* = proc.getNice(pid) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_proc_set_nice(pid: i32, nice: i32) c_int {
    proc.setNice(pid, nice) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_proc_set_io_priority(pid: i32, class: u32, level: u32) c_int {
    proc.setIoPriority(pid, class, level) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_proc_get_io_priority(pid: i32, class: *u32, level: *u32) c_int {
    proc.getIoPriority(pid, class, level) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_proc_sockets(flags: u32, out: *?*proc.SocketList) c_int {
    out.* = proc.sockets("/proc", flags & 1 != 0, flags & 2 != 0) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_proc_socket_list_count(l: *const proc.SocketList) usize {
    return l.items.items.len;
}

export fn sinty_proc_socket_list_at(l: *const proc.SocketList, i: usize) ?*const proc.Socket {
    if (i >= l.items.items.len) return null;
    return &l.items.items[i];
}

export fn sinty_proc_socket_list_free(l: ?*proc.SocketList) void {
    if (l) |p| {
        p.deinit();
        sys.gpa.destroy(p);
    }
}

fn span(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}

export fn sinty_sensors_list(flags: u32, out: *?*sensors.ReadingList) c_int {
    out.* = sensors.list(sysfs, flags & 1 != 0) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_sensors_list_count(l: *const sensors.ReadingList) usize {
    return l.count();
}

export fn sinty_sensors_list_at(l: *const sensors.ReadingList, i: usize) ?*const sensors.Reading {
    return l.at(i);
}

export fn sinty_sensors_list_free(l: ?*sensors.ReadingList) void {
    if (l) |p| p.destroy();
}

export fn sinty_sysctl_get(name: [*:0]const u8, out: [*]u8, len: usize) c_int {
    const n = sensors.sysctlGet(procfs, span(name), out[0..len]) catch |e| return sys.code(e);
    return @intCast(n);
}

export fn sinty_sysctl_set(name: [*:0]const u8, value: [*:0]const u8) c_int {
    sensors.sysctlSet(procfs, span(name), span(value)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_power_supplies(out: *?*power.SupplyList) c_int {
    out.* = power.supplies(sysfs) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_power_supply_list_count(l: *const power.SupplyList) usize {
    return l.count();
}

export fn sinty_power_supply_list_at(l: *const power.SupplyList, i: usize) ?*const power.Supply {
    return l.at(i);
}

export fn sinty_power_supply_list_free(l: ?*power.SupplyList) void {
    if (l) |p| p.destroy();
}

export fn sinty_power_set_charge_thresholds(name: [*:0]const u8, start: i32, end: i32) c_int {
    power.setChargeThresholds(sysfs, span(name), start, end) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_power_profile(current: [*]u8, current_len: usize, choices: [*]u8, choices_len: usize) c_int {
    power.platformProfile(sysfs, current[0..current_len], choices[0..choices_len]) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_power_set_profile(profile: [*:0]const u8) c_int {
    power.setPlatformProfile(sysfs, span(profile)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_power_cpu_policies(out: *?*power.CpuPolicyList) c_int {
    out.* = power.cpuPolicies(sysfs) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_power_cpu_policy_list_count(l: *const power.CpuPolicyList) usize {
    return l.count();
}

export fn sinty_power_cpu_policy_list_at(l: *const power.CpuPolicyList, i: usize) ?*const power.CpuPolicy {
    return l.at(i);
}

export fn sinty_power_cpu_policy_list_free(l: ?*power.CpuPolicyList) void {
    if (l) |p| p.destroy();
}

export fn sinty_power_set_governor(governor: [*:0]const u8) c_int {
    power.setGovernor(sysfs, span(governor)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_power_set_energy_preference(epp: [*:0]const u8) c_int {
    power.setEnergyPreference(sysfs, span(epp)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_display_backlights(out: *?*display.BacklightList) c_int {
    out.* = display.backlights(sysfs) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_display_backlight_list_count(l: *const display.BacklightList) usize {
    return l.count();
}

export fn sinty_display_backlight_list_at(l: *const display.BacklightList, i: usize) ?*const display.Backlight {
    return l.at(i);
}

export fn sinty_display_backlight_list_free(l: ?*display.BacklightList) void {
    if (l) |p| p.destroy();
}

export fn sinty_display_set_backlight(name: [*:0]const u8, value: i64) c_int {
    display.setBacklight(sysfs, span(name), value) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_display_ddc_list(out: *?*display.DdcList) c_int {
    out.* = display.ddcDisplays(sysfs) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_display_ddc_list_count(l: *const display.DdcList) usize {
    return l.count();
}

export fn sinty_display_ddc_list_at(l: *const display.DdcList, i: usize) ?*const display.DdcDisplay {
    return l.at(i);
}

export fn sinty_display_ddc_list_free(l: ?*display.DdcList) void {
    if (l) |p| p.destroy();
}

export fn sinty_display_ddc_get(bus: u32, vcp: u8, current: *u16, maximum: *u16) c_int {
    const v = display.ddcGet(bus, vcp) catch |e| return sys.code(e);
    current.* = v.current;
    maximum.* = v.maximum;
    return 0;
}

export fn sinty_display_ddc_set(bus: u32, vcp: u8, value: u16) c_int {
    display.ddcSet(bus, vcp, value) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_device_hwdb_get(modalias: [*:0]const u8, key: [*:0]const u8, out: [*]u8, len: usize) c_int {
    const n = device.hwdbLookup(span(modalias), span(key), out[0..len]) catch |e| return sys.code(e);
    return @intCast(n);
}

export fn sinty_device_names(syspath: [*:0]const u8, out: *device.DeviceNames) c_int {
    device.names(span(syspath), out) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_device_uevent_get(syspath: [*:0]const u8, key: [*:0]const u8, out: [*]u8, len: usize) c_int {
    var buf: [512]u8 = undefined;
    const p = sys.pathZ(&buf, "{s}/uevent", .{span(syspath)}) catch |e| return sys.code(e);
    const n = device.ueventGet(p, span(key), out[0..len]) catch |e| return sys.code(e);
    return @intCast(n);
}

export fn sinty_net_link_info(iface: [*:0]const u8, out: *net.LinkInfo) c_int {
    net.linkInfo(span(iface), out) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_text_list_count(l: *const i18n.TextList) usize {
    return l.count();
}

export fn sinty_text_list_at(l: *const i18n.TextList, i: usize) ?[*:0]const u8 {
    const t = l.at(i) orelse return null;
    return t.ptr;
}

export fn sinty_text_list_free(l: ?*i18n.TextList) void {
    if (l) |p| p.destroy();
}

export fn sinty_i18n_installed_locales(out: *?*i18n.TextList) c_int {
    out.* = i18n.installed("/usr/lib/locale") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_gpu_nvidia(out: *?*gpu.NvidiaList) c_int {
    out.* = gpu.nvidia() catch |e| return sys.code(e);
    return 0;
}

export fn sinty_gpu_nvidia_list_count(l: *const gpu.NvidiaList) usize {
    return l.count();
}

export fn sinty_gpu_nvidia_list_at(l: *const gpu.NvidiaList, i: usize) ?*const gpu.NvidiaGpu {
    return l.at(i);
}

export fn sinty_gpu_nvidia_list_free(l: ?*gpu.NvidiaList) void {
    if (l) |p| p.destroy();
}

export fn sinty_firewall_apply(enabled: bool, public_profile: bool, specs: ?[*]const ?[*:0]const u8, comments: ?[*]const ?[*:0]const u8, count: usize) c_int {
    var ports: [256]firewall.Port = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const spec = (specs orelse return sys.code(error.Invalid))[i] orelse return sys.code(error.Invalid);
        const comment: []const u8 = if (comments) |c| (if (c[i]) |p| span(p) else "") else "";
        n += firewall.parsePorts(span(spec), comment, ports[n..]) catch |e| return sys.code(e);
    }
    firewall.apply(.{ .enabled = enabled, .public_profile = public_profile, .ports = ports[0..n] }) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_firewall_summary(out: *firewall.Summary) c_int {
    firewall.summary(out) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_audio_graph(out: *?*audio.Graph) c_int {
    out.* = audio.snapshot() catch |e| return sys.code(e);
    return 0;
}

export fn sinty_audio_graph_count(g: *const audio.Graph) usize {
    return g.count();
}

export fn sinty_audio_graph_at(g: *const audio.Graph, i: usize) ?*const audio.Object {
    return g.at(i);
}

export fn sinty_audio_graph_free(g: ?*audio.Graph) void {
    if (g) |p| p.destroy();
}

export fn sinty_audio_set_controls(node_name: [*:0]const u8, names: ?[*]const ?[*:0]const u8, values: ?[*]const f32, count: usize) c_int {
    var controls: [64]audio.Control = undefined;
    if (count == 0 or count > controls.len) return sys.code(error.Invalid);
    const ns = names orelse return sys.code(error.Invalid);
    const vs = values orelse return sys.code(error.Invalid);
    for (0..count) |i| controls[i] = .{ .name = span(ns[i] orelse return sys.code(error.Invalid)), .value = vs[i] };
    audio.setControls(span(node_name), controls[0..count]) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_audio_object_prop(o: *const audio.Object, key: [*:0]const u8) ?[*:0]const u8 {
    const k = o.keys orelse return null;
    const v = o.values orelse return null;
    for (0..o.n_props) |i| if (std.mem.eql(u8, std.mem.span(k[i]), span(key))) return v[i];
    return null;
}

export fn sinty_time_rtc_read(out: *time.RtcTime) c_int {
    out.* = time.rtcRead() catch |e| return sys.code(e);
    return 0;
}

export fn sinty_time_rtc_write(t: *const time.RtcTime) c_int {
    time.rtcWrite(t.*) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_time_clock(out: *time.ClockState) c_int {
    out.* = time.clock() catch |e| return sys.code(e);
    return 0;
}

export fn sinty_time_zone(buf: [*]u8, len: usize) c_int {
    if (len == 0) return sys.code(error.Invalid);
    _ = time.zone("/etc/localtime", buf[0..len]) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_service_control(action: [*:0]const u8, unit: [*:0]const u8) c_int {
    session.control(session.default_socket, span(action), span(unit)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_service_state(unit: [*:0]const u8, buf: [*]u8, len: usize) c_int {
    if (len == 0) return sys.code(error.Invalid);
    const r = session.send(session.default_socket, "status", span(unit)) catch |e| return sys.code(e);
    if (!r.ok) return sys.code(error.NotFound);
    sys.copyName(buf[0..len], sys.cstr(&r.state));
    return 0;
}

test {
    std.testing.refAllDecls(@This());
    _ = proc;
    _ = sensors;
    _ = power;
    _ = display;
    _ = device;
    _ = net;
    _ = i18n;
    _ = gpu;
    _ = firewall;
    _ = audio;
    _ = time;
    _ = session;
}

test "a tcp connection shows up with its owner and counters" {
    const linux = std.os.linux;
    const lfd: i32 = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer sys.close(lfd);
    var addr = linux.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    _ = try sys.check(linux.bind(lfd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
    _ = try sys.check(linux.listen(lfd, 1));
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = try sys.check(linux.getsockname(lfd, @ptrCast(&addr), &len));
    const cfd: i32 = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer sys.close(cfd);
    _ = try sys.check(linux.connect(cfd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
    const afd: i32 = @intCast(try sys.check(linux.accept(lfd, null, null)));
    defer sys.close(afd);
    const payload = [_]u8{'x'} ** 5000;
    try sys.writeAll(cfd, &payload);
    var sink: [8192]u8 = undefined;
    var got: usize = 0;
    while (got < payload.len) got += try sys.read(afd, sink[0..]);
    var list: ?*proc.SocketList = null;
    try std.testing.expectEqual(@as(c_int, 0), sinty_proc_sockets(1, &list));
    defer sinty_proc_socket_list_free(list);
    const me: i32 = @intCast(linux.getpid());
    const port = std.mem.bigToNative(u16, addr.port);
    var client_found = false;
    var server_found = false;
    for (list.?.items.items) |s| {
        if (s.pid != me) continue;
        if (s.remote_port == port and s.bytes_sent >= 5000) client_found = true;
        if (s.local_port == port and s.remote_port != 0 and s.bytes_received >= 5000) server_found = true;
    }
    try std.testing.expect(client_found);
    try std.testing.expect(server_found);
}
