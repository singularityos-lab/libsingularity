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
pub const firmware = @import("v1/firmware.zig");
pub const disk = @import("v1/disk.zig");
pub const fs = @import("v1/fs.zig");
pub const crypt = @import("v1/crypt.zig");
pub const dbus = @import("v1/bus.zig");
pub const bluetooth = @import("v1/bluetooth.zig");
pub const notify = @import("v1/notify.zig");
pub const input = @import("v1/input.zig");
pub const accounts = @import("v1/accounts.zig");
pub const print = @import("v1/print.zig");
pub const wayland = @import("v1/wayland.zig");
pub const clipboard = @import("v1/clipboard.zig");
pub const gvariant = @import("v1/gvariant.zig");
pub const gvdb = @import("v1/gvdb.zig");
pub const settings = @import("v1/settings.zig");
pub const logs = @import("v1/logs.zig");
pub const conf = @import("v1/conf.zig");
pub const fscrypt = @import("v1/fscrypt.zig");
pub const mounts = @import("v1/mount.zig");
pub const fsck = @import("v1/fsck.zig");
pub const erofs = @import("v1/erofs.zig");
pub const f2fs = @import("v1/f2fs.zig");

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

export fn sinty_firmware_esrt(out: *?*firmware.EsrtList) c_int {
    out.* = firmware.esrt(sysfs ++ "/firmware/efi/esrt") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_firmware_esrt_count(l: *const firmware.EsrtList) usize {
    return l.count();
}

export fn sinty_firmware_esrt_at(l: *const firmware.EsrtList, i: usize) ?*const firmware.EsrtEntry {
    return l.at(i);
}

export fn sinty_firmware_esrt_free(l: ?*firmware.EsrtList) void {
    if (l) |p| p.destroy();
}

export fn sinty_firmware_capsule_supported() bool {
    return firmware.capsuleSupported(sysfs ++ "/firmware/efi/efivars");
}

export fn sinty_firmware_stage_capsule(esp: [*:0]const u8, name: [*:0]const u8, data: [*]const u8, len: usize) c_int {
    firmware.stageCapsule(span(esp), sysfs ++ "/firmware/efi/efivars", span(name), data[0..len]) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_table(path: [*:0]const u8, info: *disk.TableInfo, out: *?*disk.PartitionList) c_int {
    var o = disk.Opened.open(path, false) catch |e| return sys.code(e);
    defer o.close();
    info.* = disk.info(o.disk, o.table);
    out.* = disk.list(o.disk, o.table) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_partitions_count(l: *const disk.PartitionList) usize {
    return l.count();
}

export fn sinty_disk_partitions_at(l: *const disk.PartitionList, i: usize) ?*const disk.Partition {
    return l.at(i);
}

export fn sinty_disk_partitions_free(l: ?*disk.PartitionList) void {
    if (l) |p| p.destroy();
}

export fn sinty_disk_create_table(path: [*:0]const u8, kind: u32) c_int {
    const k = std.enums.fromInt(disk.Kind, kind) orelse return sys.code(error.Invalid);
    var d = disk.Disk.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    var t = disk.create(d, k) catch |e| return sys.code(e);
    t.deinit();
    return 0;
}

export fn sinty_disk_add(path: [*:0]const u8, start: u64, size: u64, kind: [*:0]const u8, name: [*:0]const u8, number: ?*u32) c_int {
    var o = disk.Opened.open(path, true) catch |e| return sys.code(e);
    defer o.close();
    const n = disk.add(o.disk, &o.table, start, size, span(kind), span(name)) catch |e| return sys.code(e);
    if (number) |p| p.* = n;
    return 0;
}

export fn sinty_disk_remove(path: [*:0]const u8, number: u32) c_int {
    var o = disk.Opened.open(path, true) catch |e| return sys.code(e);
    defer o.close();
    disk.remove(o.disk, &o.table, number) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_set_type(path: [*:0]const u8, number: u32, kind: [*:0]const u8) c_int {
    var o = disk.Opened.open(path, true) catch |e| return sys.code(e);
    defer o.close();
    disk.setType(o.disk, &o.table, number, span(kind)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_set_name(path: [*:0]const u8, number: u32, name: [*:0]const u8) c_int {
    var o = disk.Opened.open(path, true) catch |e| return sys.code(e);
    defer o.close();
    disk.setName(o.disk, &o.table, number, span(name)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_set_attrs(path: [*:0]const u8, number: u32, attrs: u64) c_int {
    var o = disk.Opened.open(path, true) catch |e| return sys.code(e);
    defer o.close();
    disk.setAttrs(o.disk, &o.table, number, attrs) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_resize(path: [*:0]const u8, number: u32, size: u64) c_int {
    var o = disk.Opened.open(path, true) catch |e| return sys.code(e);
    defer o.close();
    disk.resize(o.disk, &o.table, number, size) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_sync_kernel(path: [*:0]const u8) c_int {
    var d = disk.Disk.open(path, false) catch |e| return sys.code(e);
    defer d.close();
    var nb: [256]u8 = undefined;
    disk.syncKernel(d, sysfs, disk.diskName(span(path), &nb)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_uevent(name: [*:0]const u8, action: [*:0]const u8) c_int {
    disk.uevent(sysfs, span(name), span(action)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_settle(name: [*:0]const u8, timeout_ms: u32) bool {
    return disk.settle(sysfs, "/dev", span(name), timeout_ms);
}

export fn sinty_disk_wipe(path: [*:0]const u8) c_int {
    disk.wipe(path) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_swap(path: [*:0]const u8, on: bool) c_int {
    disk.swap(path, on) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_disk_eject(path: [*:0]const u8) c_int {
    disk.eject(path) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_probe(path: [*:0]const u8, out: *fs.FsInfo) c_int {
    var d = fs.Dev.open(path, false) catch |e| return sys.code(e);
    defer d.close();
    out.* = fs.probe(d) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_set_label(path: [*:0]const u8, label: [*:0]const u8) c_int {
    var d = fs.Dev.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    fs.setLabel(d, span(label)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_mkswap(path: [*:0]const u8, label: [*:0]const u8) c_int {
    var d = fs.Dev.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    fs.mkswap(d, span(label)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_mkfs_vfat(path: [*:0]const u8, label: [*:0]const u8, bits: u8) c_int {
    var d = fs.Dev.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    fs.mkfsVfat(d, .{ .label = span(label), .bits = bits }) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_mkfs_exfat(path: [*:0]const u8, label: [*:0]const u8) c_int {
    var d = fs.Dev.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    fs.mkfsExfat(d, span(label)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_mkfs_ext4(path: [*:0]const u8, label: [*:0]const u8) c_int {
    var d = fs.Dev.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    fs.ext4.mkfs(d, span(label)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_swapfile(path: [*:0]const u8, bytes: u64, label: [*:0]const u8) c_int {
    fs.swapfile(span(path), bytes, span(label)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_mkfs_f2fs(path: [*:0]const u8, label: [*:0]const u8) c_int {
    var d = fs.Dev.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    f2fs.mkfs(d, span(label)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_mkfs_ext4_encrypted(path: [*:0]const u8, label: [*:0]const u8) c_int {
    var d = fs.Dev.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    fs.ext4.mkfsWith(d, span(label), .{ .encrypt = true }) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fs_ext4_grow(path: [*:0]const u8, bytes: u64, out: ?*u64) c_int {
    const r = fs.ext4.grow(path, bytes) catch |e| return sys.code(e);
    if (out) |o| o.* = r.bytes();
    return 0;
}

export fn sinty_mount(source: [*:0]const u8, target: [*:0]const u8, fstype: [*:0]const u8, options: ?[*:0]const u8) c_int {
    mounts.mount(source, target, fstype, if (options) |o| span(o) else "") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_mount_overlay(target: [*:0]const u8, lowers: [*]const [*:0]const u8, n: usize, upper: ?[*:0]const u8, work: ?[*:0]const u8, options: ?[*:0]const u8, readonly: bool) c_int {
    if (n == 0 or n > 64) return sys.code(error.Invalid);
    var list: [64][]const u8 = undefined;
    for (0..n) |i| list[i] = span(lowers[i]);
    const o = mounts.Overlay{
        .lower = list[0..n],
        .upper = if (upper) |u| span(u) else null,
        .work = if (work) |w| span(w) else null,
        .options = if (options) |p| span(p) else "",
    };
    mounts.overlay(target, o, if (readonly) std.os.linux.MS.RDONLY else 0) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_unmount(target: [*:0]const u8, lazy: bool) c_int {
    mounts.unmount(target, lazy) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_mount_find(dev: [*:0]const u8, target: [*]u8, len: usize) c_int {
    const num = mounts.devNumber(dev) catch |e| return sys.code(e);
    const t = mounts.table() catch |e| return sys.code(e);
    defer t.destroy();
    const e = mounts.findDevice(t, num.major, num.minor) orelse return 0;
    const s = sys.cstr(&e.target);
    if (s.len + 1 > len) return sys.code(error.TooBig);
    @memcpy(target[0..s.len], s);
    target[s.len] = 0;
    return 1;
}

export fn sinty_erofs_build(source: [*:0]const u8, out: [*:0]const u8, label: ?[*:0]const u8, blocks: ?*u32) c_int {
    const info = erofs.build(source, out, .{ .label = if (label) |l| span(l) else "" }) catch |e| return sys.code(e);
    if (blocks) |b| b.* = info.blocks;
    return 0;
}

export fn sinty_fs_check(path: [*:0]const u8, repair: bool, out: *fsck.Report) c_int {
    var d = fs.Dev.open(path, repair) catch |e| return sys.code(e);
    defer d.close();
    out.* = fsck.check(d, repair) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fscrypt_identifier(raw: [*]const u8, len: usize, id: *fscrypt.Id) void {
    id.* = fscrypt.identifier(raw[0..len]);
}

export fn sinty_fscrypt_add_key(mount: [*:0]const u8, raw: [*]const u8, len: usize, id: *fscrypt.Id) c_int {
    id.* = fscrypt.addKey(mount, raw[0..len]) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fscrypt_remove_key(mount: [*:0]const u8, id: *const fscrypt.Id, all_users: bool, flags: ?*u32) c_int {
    const r = fscrypt.removeKey(mount, id.*, all_users) catch |e| return sys.code(e);
    if (flags) |f| f.* = @as(u32, @intFromBool(r.files_busy)) | (@as(u32, @intFromBool(r.other_users)) << 1);
    return 0;
}

export fn sinty_fscrypt_key_status(mount: [*:0]const u8, id: *const fscrypt.Id, out: *fscrypt.KeyStatus) c_int {
    out.* = fscrypt.keyStatus(mount, id.*) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fscrypt_set_policy(dir: [*:0]const u8, policy: *const fscrypt.Policy) c_int {
    fscrypt.setPolicy(dir, policy.*) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_fscrypt_get_policy(path: [*:0]const u8, out: *fscrypt.Policy) c_int {
    const p = fscrypt.getPolicy(path) catch |e| return sys.code(e);
    out.* = p orelse return -@as(c_int, @intFromEnum(std.os.linux.E.NODATA));
    return 0;
}

export fn sinty_crypt_info(path: [*:0]const u8, out: *crypt.Info) c_int {
    var d = fs.Dev.open(path, false) catch |e| return sys.code(e);
    defer d.close();
    out.* = crypt.info(d) catch |e| return cryptCode(e);
    return 0;
}

fn cryptCode(e: anyerror) c_int {
    return if (e == error.WrongPassphrase) -@as(c_int, @intFromEnum(std.os.linux.E.KEYREJECTED)) else sys.code(e);
}

export fn sinty_crypt_format(path: [*:0]const u8, pass: [*]const u8, len: usize, label: [*:0]const u8) c_int {
    var d = fs.Dev.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    var o = crypt.defaults();
    o.label = span(label);
    crypt.format(d, pass[0..len], o) catch |e| return cryptCode(e);
    return 0;
}

export fn sinty_crypt_change_passphrase(path: [*:0]const u8, old: [*]const u8, old_len: usize, new: [*]const u8, new_len: usize) c_int {
    var d = fs.Dev.open(path, true) catch |e| return sys.code(e);
    defer d.close();
    crypt.changePassphrase(d, old[0..old_len], new[0..new_len], crypt.defaults()) catch |e| return cryptCode(e);
    return 0;
}

export fn sinty_crypt_open(path: [*:0]const u8, pass: [*]const u8, len: usize, name: [*:0]const u8, read_only: bool) c_int {
    crypt.open(path, pass[0..len], span(name), read_only) catch |e| return cryptCode(e);
    return 0;
}

export fn sinty_crypt_close(name: [*:0]const u8) c_int {
    crypt.close(span(name)) catch |e| return sys.code(e);
    return 0;
}

fn withBt(s: ?*dbus.Conn, comptime f: anytype, args: anytype) c_int {
    var tmp: dbus.Conn = undefined;
    const c = if (s) |p| p else blk: {
        tmp = dbus.Conn.system() catch |e| return sys.code(e);
        break :blk &tmp;
    };
    defer if (s == null) tmp.close();
    @call(.auto, f, .{c} ++ args) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_bt_session_open(out: *?*dbus.Conn) c_int {
    const c = sys.gpa.create(dbus.Conn) catch return sys.code(error.NoMemory);
    c.* = dbus.Conn.system() catch |e| {
        sys.gpa.destroy(c);
        return sys.code(e);
    };
    out.* = c;
    return 0;
}

export fn sinty_bt_session_close(s: ?*dbus.Conn) void {
    if (s) |c| {
        c.close();
        sys.gpa.destroy(c);
    }
}

export fn sinty_bt_snapshot(s: ?*dbus.Conn, out: *?*bluetooth.State) c_int {
    var tmp: dbus.Conn = undefined;
    const c = if (s) |p| p else blk: {
        tmp = dbus.Conn.system() catch |e| return sys.code(e);
        break :blk &tmp;
    };
    defer if (s == null) tmp.close();
    out.* = bluetooth.snapshot(c) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_bt_adapter_count(st: *const bluetooth.State) usize {
    return st.adapters.items.len;
}

export fn sinty_bt_adapter_at(st: *const bluetooth.State, i: usize) ?*const bluetooth.Adapter {
    return if (i < st.adapters.items.len) &st.adapters.items[i] else null;
}

export fn sinty_bt_device_count(st: *const bluetooth.State) usize {
    return st.devices.items.len;
}

export fn sinty_bt_device_at(st: *const bluetooth.State, i: usize) ?*const bluetooth.Device {
    return if (i < st.devices.items.len) &st.devices.items[i] else null;
}

export fn sinty_bt_free(st: ?*bluetooth.State) void {
    if (st) |p| p.destroy();
}

export fn sinty_bt_set_adapter(s: ?*dbus.Conn, path: [*:0]const u8, which: c_int, on: bool) c_int {
    const w = std.enums.fromInt(bluetooth.AdapterFlag, which) orelse return sys.code(error.Invalid);
    return withBt(s, bluetooth.setAdapter, .{ span(path), w, on });
}

export fn sinty_bt_set_device(s: ?*dbus.Conn, path: [*:0]const u8, which: c_int, on: bool) c_int {
    const w = std.enums.fromInt(bluetooth.DeviceFlag, which) orelse return sys.code(error.Invalid);
    return withBt(s, bluetooth.setDevice, .{ span(path), w, on });
}

export fn sinty_bt_set_alias(s: ?*dbus.Conn, path: [*:0]const u8, alias: [*:0]const u8) c_int {
    return withBt(s, bluetooth.setAlias, .{ span(path), span(alias) });
}

export fn sinty_bt_device_action(s: ?*dbus.Conn, path: [*:0]const u8, action: c_int) c_int {
    const a = std.enums.fromInt(bluetooth.Action, action) orelse return sys.code(error.Invalid);
    return withBt(s, bluetooth.device, .{ span(path), a });
}

export fn sinty_bt_remove(s: ?*dbus.Conn, path: [*:0]const u8) c_int {
    return withBt(s, bluetooth.remove, .{span(path)});
}

export fn sinty_bt_discovery(s: ?*dbus.Conn, adapter: [*:0]const u8, on: bool) c_int {
    return withBt(s, bluetooth.discovery, .{ span(adapter), on });
}

export fn sinty_notify_send(q: *const notify.Request, id: *u32) c_int {
    var actions: [32][]const u8 = undefined;
    const n = notify.fromRequest(q, &actions) catch |e| return sys.code(e);
    var c = dbus.Conn.session() catch |e| return sys.code(e);
    defer c.close();
    id.* = notify.send(&c, n) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_notify_close(id: u32) c_int {
    var c = dbus.Conn.session() catch |e| return sys.code(e);
    defer c.close();
    notify.close(&c, id) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_input_engines(out: *?*input.Engines) c_int {
    var c = dbus.Conn.session() catch |e| return sys.code(e);
    defer c.close();
    out.* = input.engines(&c) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_input_engines_count(l: *const input.Engines) usize {
    return l.count();
}

export fn sinty_input_engines_at(l: *const input.Engines, i: usize) ?*const input.Engine {
    return l.at(i);
}

export fn sinty_input_engines_free(l: ?*input.Engines) void {
    if (l) |p| p.destroy();
}

export fn sinty_input_select(name: [*:0]const u8) c_int {
    var c = dbus.Conn.session() catch |e| return sys.code(e);
    defer c.close();
    input.select(&c, span(name)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_input_active(buf: [*]u8, len: usize) c_int {
    if (len == 0) return sys.code(error.Invalid);
    var c = dbus.Conn.session() catch |e| return sys.code(e);
    defer c.close();
    const s = input.active(&c, buf[0..len]) catch |e| return sys.code(e);
    return @intCast(s.len);
}

export fn sinty_input_configure(name: [*:0]const u8, option: c_int, value: c_int) c_int {
    const opt: input.Option = switch (option) {
        0 => .{ .conversion = std.enums.fromInt(input.Conversion, value) orelse return sys.code(error.Invalid) },
        1 => .{ .fullwidth = value != 0 },
        2 => .{ .learn = value != 0 },
        else => return sys.code(error.Invalid),
    };
    var c = dbus.Conn.session() catch |e| return sys.code(e);
    defer c.close();
    input.configure(&c, span(name), opt) catch |e| return sys.code(e);
    return 0;
}

fn systemBus() !dbus.Conn {
    var c = try dbus.Conn.system();
    c.interactive = true;
    return c;
}

export fn sinty_accounts_users(out: *?*accounts.Users) c_int {
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    out.* = accounts.users(&c) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_accounts_users_count(l: *const accounts.Users) usize {
    return l.count();
}

export fn sinty_accounts_users_at(l: *const accounts.Users, i: usize) ?*const accounts.User {
    return l.at(i);
}

export fn sinty_accounts_users_free(l: ?*accounts.Users) void {
    if (l) |p| p.destroy();
}

export fn sinty_accounts_find(name: [*:0]const u8, out: *accounts.User) c_int {
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    out.* = accounts.find(&c, span(name)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_accounts_set_text(path: [*:0]const u8, field: c_int, value: [*:0]const u8) c_int {
    const f = std.enums.fromInt(accounts.Field, field) orelse return sys.code(error.Invalid);
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    accounts.setText(&c, span(path), f, span(value)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_accounts_set_flag(path: [*:0]const u8, flag: c_int, on: bool) c_int {
    const f = std.enums.fromInt(accounts.Flag, flag) orelse return sys.code(error.Invalid);
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    accounts.setFlag(&c, span(path), f, on) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_accounts_set_administrator(path: [*:0]const u8, on: bool) c_int {
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    accounts.setAccountType(&c, span(path), on) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_accounts_create(name: [*:0]const u8, real_name: [*:0]const u8, administrator: bool, path: [*]u8, len: usize) c_int {
    if (len == 0) return sys.code(error.Invalid);
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    const p = accounts.create(&c, span(name), span(real_name), administrator, path[0..len]) catch |e| return sys.code(e);
    return @intCast(p.len);
}

export fn sinty_accounts_delete(uid: u64, remove_files: bool) c_int {
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    accounts.delete(&c, uid, remove_files) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_hostname_get(out: *accounts.Names) c_int {
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    out.* = accounts.hostname(&c) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_hostname_set(static: [*:0]const u8, pretty: [*:0]const u8) c_int {
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    accounts.setHostname(&c, span(static), span(pretty)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_language_get(buf: [*]u8, len: usize) c_int {
    if (len == 0) return sys.code(error.Invalid);
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    const s = accounts.language(&c, buf[0..len]) catch |e| return sys.code(e);
    return @intCast(s.len);
}

export fn sinty_language_set(lang: [*:0]const u8) c_int {
    var c = systemBus() catch |e| return sys.code(e);
    defer c.close();
    accounts.setLanguage(&c, span(lang)) catch |e| return sys.code(e);
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
    _ = firmware;
    _ = disk;
    _ = fs;
    _ = crypt;
    _ = print;
    _ = wayland;
    _ = clipboard;
    _ = gvariant;
    _ = gvdb;
    _ = settings;
    _ = logs;
    _ = conf;
    _ = fscrypt;
    _ = mounts;
    _ = fsck;
    _ = erofs;
    _ = f2fs;
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

fn printServer(addr: ?[*:0]const u8) !print.Server {
    if (addr) |a| return print.Server.parse(span(a));
    return print.Server.default();
}

export fn sinty_print_printers(server: ?[*:0]const u8, out: *?*print.Printers) c_int {
    const s = printServer(server) catch |e| return sys.code(e);
    out.* = print.printers(&s) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_print_printers_count(l: *const print.Printers) usize {
    return l.count();
}

export fn sinty_print_printers_at(l: *const print.Printers, i: usize) ?*const print.Printer {
    return l.at(i);
}

export fn sinty_print_printers_free(l: ?*print.Printers) void {
    if (l) |p| p.destroy();
}

export fn sinty_print_default(server: ?[*:0]const u8, name: [*]u8, len: usize) c_int {
    if (len == 0) return sys.code(error.Invalid);
    const s = printServer(server) catch |e| return sys.code(e);
    _ = print.defaultPrinter(&s, name[0..len]) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_print_printer(server: ?[*:0]const u8, queue: [*:0]const u8, out: *print.Printer) c_int {
    const s = printServer(server) catch |e| return sys.code(e);
    var q = print.Queue{};
    q.init(&s, span(queue)) catch |e| return sys.code(e);
    out.* = print.printer(&s, q.uri, q.resource) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_print_jobs(server: ?[*:0]const u8, queue: [*:0]const u8, completed: bool, out: *?*print.Jobs) c_int {
    const s = printServer(server) catch |e| return sys.code(e);
    var q = print.Queue{};
    q.init(&s, span(queue)) catch |e| return sys.code(e);
    out.* = print.jobs(&s, q.uri, q.resource, completed) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_print_jobs_count(l: *const print.Jobs) usize {
    return l.count();
}

export fn sinty_print_jobs_at(l: *const print.Jobs, i: usize) ?*const print.Job {
    return l.at(i);
}

export fn sinty_print_jobs_free(l: ?*print.Jobs) void {
    if (l) |p| p.destroy();
}

export fn sinty_print_file(server: ?[*:0]const u8, queue: [*:0]const u8, path: [*:0]const u8, title: ?[*:0]const u8, copies: c_int, job: *u32) c_int {
    const s = printServer(server) catch |e| return sys.code(e);
    var q = print.Queue{};
    q.init(&s, span(queue)) catch |e| return sys.code(e);
    job.* = print.printFile(&s, q.uri, q.resource, path, if (title) |t| span(t) else "", copies) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_print_cancel(server: ?[*:0]const u8, queue: [*:0]const u8, job: u32) c_int {
    const s = printServer(server) catch |e| return sys.code(e);
    var q = print.Queue{};
    q.init(&s, span(queue)) catch |e| return sys.code(e);
    print.cancel(&s, q.uri, q.resource, job) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_bytes_free(data: ?[*]u8, len: usize) void {
    if (data) |d| if (len > 0) sys.gpa.free(d[0..len]);
}

export fn sinty_clipboard_types(primary: bool, out: *?*i18n.TextList) c_int {
    var s = clipboard.Session.open() catch |e| return sys.code(e);
    defer s.close();
    out.* = s.types(primary) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_clipboard_read(primary: bool, mime: [*:0]const u8, data: *?[*]u8, len: *usize) c_int {
    var s = clipboard.Session.open() catch |e| return sys.code(e);
    defer s.close();
    const got = s.read(primary, span(mime)) catch |e| return sys.code(e);
    len.* = got.len;
    data.* = if (got.len > 0) got.ptr else null;
    return 0;
}

export fn sinty_clipboard_set(data: ?[*]const u8, len: usize, mimes: [*]const ?[*:0]const u8, n_mimes: usize, primary: bool, out: *?*clipboard.Holder) c_int {
    if (n_mimes == 0 or n_mimes > 16 or (data == null and len > 0)) return sys.code(error.Invalid);
    var list: [16][]const u8 = undefined;
    for (0..n_mimes) |i| list[i] = span(mimes[i] orelse return sys.code(error.Invalid));
    const bytes: []const u8 = if (data) |d| d[0..len] else "";
    out.* = clipboard.Holder.create(null, bytes, list[0..n_mimes], primary) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_clipboard_holder_active(h: *const clipboard.Holder) bool {
    return h.active();
}

export fn sinty_clipboard_holder_free(h: ?*clipboard.Holder) void {
    if (h) |p| p.destroy();
}

fn settingsKey(store: *const settings.Store, schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8) !settings.Key {
    return store.key(span(schema), if (path) |p| span(p) else null, span(key));
}

fn settingsGet(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, comptime T: type, comptime read: fn (gvariant.Value) anyerror!T) !T {
    var store = try settings.Store.load();
    defer store.deinit();
    const k = try settingsKey(&store, schema, path, key);
    return read(try store.get(&k));
}

fn settingsSet(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, value: ?[]const u8, want: []const u8) !void {
    var store = try settings.Store.load();
    defer store.deinit();
    const k = try settingsKey(&store, schema, path, key);
    if (value != null) {
        const ok = if (std.mem.eql(u8, want, "as")) std.mem.eql(u8, k.sig, "as") else k.sig.len == 1 and std.mem.indexOfScalar(u8, want, k.sig[0]) != null;
        if (!ok) return error.Invalid;
    }
    try store.validate(&k, value);
    var c = try dbus.Conn.session();
    defer c.close();
    try store.set(&c, &k, value);
}

fn readBool(v: gvariant.Value) anyerror!bool {
    return v.boolean();
}

fn readInt(v: gvariant.Value) anyerror!i64 {
    return v.int();
}

fn readDouble(v: gvariant.Value) anyerror!f64 {
    return v.double();
}

export fn sinty_settings_get_bool(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, out: *bool) c_int {
    out.* = settingsGet(schema, path, key, bool, readBool) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_get_int(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, out: *i64) c_int {
    out.* = settingsGet(schema, path, key, i64, readInt) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_get_double(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, out: *f64) c_int {
    out.* = settingsGet(schema, path, key, f64, readDouble) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_get_string(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, out: *?[*:0]u8) c_int {
    var store = settings.Store.load() catch |e| return sys.code(e);
    defer store.deinit();
    const k = settingsKey(&store, schema, path, key) catch |e| return sys.code(e);
    const v = store.get(&k) catch |e| return sys.code(e);
    const s = v.string() catch |e| return sys.code(e);
    out.* = sys.dupZ(sys.gpa, s) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_get_strv(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, out: *?*i18n.TextList) c_int {
    var store = settings.Store.load() catch |e| return sys.code(e);
    defer store.deinit();
    const k = settingsKey(&store, schema, path, key) catch |e| return sys.code(e);
    if (!std.mem.eql(u8, k.sig, "as")) return sys.code(error.Invalid);
    const v = store.get(&k) catch |e| return sys.code(e);
    const list = i18n.TextList.create() catch |e| return sys.code(e);
    const n = v.len() catch |e| {
        list.destroy();
        return sys.code(e);
    };
    for (0..n) |i| {
        const item = (v.at(i) catch |e| {
            list.destroy();
            return sys.code(e);
        }).string() catch |e| {
            list.destroy();
            return sys.code(e);
        };
        const copy = sys.dupZ(sys.gpa, item) catch |e| {
            list.destroy();
            return sys.code(e);
        };
        list.append(.{ .ptr = copy }) catch |e| {
            sys.gpa.free(std.mem.span(copy));
            list.destroy();
            return sys.code(e);
        };
    }
    out.* = list;
    return 0;
}

export fn sinty_settings_set_bool(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, value: bool) c_int {
    const b = gvariant.boolean(value) catch |e| return sys.code(e);
    defer sys.gpa.free(b);
    settingsSet(schema, path, key, b, "b") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_set_int(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, value: i64) c_int {
    var store = settings.Store.load() catch |e| return sys.code(e);
    defer store.deinit();
    const k = settingsKey(&store, schema, path, key) catch |e| return sys.code(e);
    const b = settings.encodeInt(k.sig, value) catch |e| return sys.code(e);
    defer sys.gpa.free(b);
    store.validate(&k, b) catch |e| return sys.code(e);
    var c = dbus.Conn.session() catch |e| return sys.code(e);
    defer c.close();
    store.set(&c, &k, b) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_set_double(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, value: f64) c_int {
    const b = gvariant.double(value) catch |e| return sys.code(e);
    defer sys.gpa.free(b);
    settingsSet(schema, path, key, b, "d") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_set_string(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) c_int {
    const b = gvariant.string(span(value)) catch |e| return sys.code(e);
    defer sys.gpa.free(b);
    settingsSet(schema, path, key, b, "sog") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_set_strv(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, values: ?[*]const ?[*:0]const u8, n: usize) c_int {
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(sys.gpa);
    if (n > 0) {
        const list = values orelse return sys.code(error.Invalid);
        for (0..n) |i| items.append(sys.gpa, span(list[i] orelse return sys.code(error.Invalid))) catch |e| return sys.code(e);
    }
    const b = settings.encodeStrv(items.items) catch |e| return sys.code(e);
    defer sys.gpa.free(b);
    settingsSet(schema, path, key, b, "as") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_reset(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8) c_int {
    settingsSet(schema, path, key, null, "") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_settings_writable(schema: [*:0]const u8, path: ?[*:0]const u8, key: [*:0]const u8, out: *bool) c_int {
    var store = settings.Store.load() catch |e| return sys.code(e);
    defer store.deinit();
    const k = settingsKey(&store, schema, path, key) catch |e| return sys.code(e);
    out.* = store.writable(&k) catch |e| return sys.code(e);
    return 0;
}

fn journalFiles(files: *logs.Files, dir: ?[*:0]const u8) !void {
    if (dir) |d| return files.under(span(d));
    try files.system();
}

fn journalFilter(boot: ?[*:0]const u8, max_priority: c_int, unit: ?[*:0]const u8, limit: usize) !logs.Filter {
    var f = logs.Filter{ .max_priority = @intCast(std.math.clamp(max_priority, 0, 7)), .limit = if (limit == 0) 1000 else limit };
    if (unit) |u| f.unit = span(u);
    if (boot) |b| {
        if (std.mem.eql(u8, span(b), "current")) {
            var id: [40]u8 = undefined;
            try logs.currentBoot(&id);
            f.boot = id[0..32].*;
        } else f.boot = try logs.parseBoot(span(b));
    }
    return f;
}

export fn sinty_logs_kernel(out: *?*logs.Entries) c_int {
    out.* = logs.kernel("/run/log/kernel.log") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_logs_journal(dir: ?[*:0]const u8, boot: ?[*:0]const u8, max_priority: c_int, unit: ?[*:0]const u8, limit: usize, out: *?*logs.Entries) c_int {
    const f = journalFilter(boot, max_priority, unit, limit) catch |e| return sys.code(e);
    var files = logs.Files{};
    defer files.deinit();
    journalFiles(&files, dir) catch |e| return sys.code(e);
    out.* = logs.query(&files, f) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_logs_entries_count(l: *const logs.Entries) usize {
    return l.count();
}

export fn sinty_logs_entries_at(l: *const logs.Entries, i: usize) ?*const logs.Entry {
    return l.at(i);
}

export fn sinty_logs_entries_free(l: ?*logs.Entries) void {
    if (l) |p| p.destroy();
}

export fn sinty_logs_boots(dir: ?[*:0]const u8, out: *?*logs.Boots) c_int {
    var files = logs.Files{};
    defer files.deinit();
    journalFiles(&files, dir) catch |e| return sys.code(e);
    out.* = logs.boots(&files) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_logs_boots_count(l: *const logs.Boots) usize {
    return l.count();
}

export fn sinty_logs_boots_at(l: *const logs.Boots, i: usize) ?*const logs.Boot {
    return l.at(i);
}

export fn sinty_logs_boots_free(l: ?*logs.Boots) void {
    if (l) |p| p.destroy();
}

export fn sinty_logs_journal_available(dir: ?[*:0]const u8) bool {
    var files = logs.Files{};
    defer files.deinit();
    journalFiles(&files, dir) catch return false;
    return files.paths.items.len > 0;
}

fn confNew(kf: conf.KeyFile, out: *?*conf.KeyFile) c_int {
    const p = sys.gpa.create(conf.KeyFile) catch {
        var k = kf;
        k.deinit();
        return sys.code(error.NoMemory);
    };
    p.* = kf;
    out.* = p;
    return 0;
}

export fn sinty_conf_open(path: [*:0]const u8, out: *?*conf.KeyFile) c_int {
    const kf = conf.load(path) catch |e| return sys.code(e);
    return confNew(kf, out);
}

export fn sinty_conf_parse(text: [*]const u8, len: usize, out: *?*conf.KeyFile) c_int {
    const kf = conf.KeyFile.parse(text[0..len]) catch |e| return sys.code(e);
    return confNew(kf, out);
}

export fn sinty_conf_free(kf: ?*conf.KeyFile) void {
    if (kf) |p| {
        p.deinit();
        sys.gpa.destroy(p);
    }
}

export fn sinty_conf_find(name: [*:0]const u8, path: [*]u8, len: usize) c_int {
    if (len == 0) return sys.code(error.Invalid);
    const found = conf.find(span(name), path[0 .. len - 1]) catch |e| return sys.code(e);
    path[found.len] = 0;
    return 0;
}

fn confText(kf: *const conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, locale: ?[*:0]const u8, out: *?[*:0]u8) c_int {
    const v = (if (locale) |l| kf.localeString(span(group), span(key), span(l)) else kf.string(span(group), span(key))) catch |e| return sys.code(e);
    defer sys.gpa.free(v);
    if (std.mem.indexOfScalar(u8, v, 0) != null) return sys.code(error.Invalid);
    out.* = sys.dupZ(sys.gpa, v) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_get_string(kf: *const conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, out: *?[*:0]u8) c_int {
    return confText(kf, group, key, null, out);
}

export fn sinty_conf_get_locale_string(kf: *const conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, locale: [*:0]const u8, out: *?[*:0]u8) c_int {
    return confText(kf, group, key, locale, out);
}

export fn sinty_conf_get_bool(kf: *const conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, out: *bool) c_int {
    out.* = kf.boolean(span(group), span(key)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_get_int(kf: *const conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, out: *i64) c_int {
    out.* = kf.integer(span(group), span(key)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_get_list(kf: *const conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, out: *?*i18n.TextList) c_int {
    out.* = kf.list(span(group), span(key)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_set_string(kf: *conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) c_int {
    kf.setString(span(group), span(key), span(value)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_set_bool(kf: *conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, value: bool) c_int {
    kf.setRaw(span(group), span(key), if (value) "true" else "false") catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_set_int(kf: *conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, value: i64) c_int {
    var b: [24]u8 = undefined;
    kf.setRaw(span(group), span(key), std.fmt.bufPrint(&b, "{d}", .{value}) catch unreachable) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_set_list(kf: *conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8, values: ?[*]const ?[*:0]const u8, n: usize) c_int {
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(sys.gpa);
    if (n > 0) {
        const list = values orelse return sys.code(error.Invalid);
        for (0..n) |i| items.append(sys.gpa, span(list[i] orelse return sys.code(error.Invalid))) catch |e| return sys.code(e);
    }
    kf.setList(span(group), span(key), items.items) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_remove(kf: *conf.KeyFile, group: [*:0]const u8, key: [*:0]const u8) c_int {
    kf.remove(span(group), span(key)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_groups(kf: *const conf.KeyFile, out: *?*i18n.TextList) c_int {
    out.* = kf.groups() catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_keys(kf: *const conf.KeyFile, group: [*:0]const u8, out: *?*i18n.TextList) c_int {
    out.* = kf.keys(span(group)) catch |e| return sys.code(e);
    return 0;
}

export fn sinty_conf_save(kf: *const conf.KeyFile, path: [*:0]const u8) c_int {
    kf.save(span(path)) catch |e| return sys.code(e);
    return 0;
}
