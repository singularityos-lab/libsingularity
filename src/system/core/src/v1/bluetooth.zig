const std = @import("std");
const sys = @import("../sys.zig");
const bus = @import("bus.zig");

pub const service = "org.bluez";
const if_adapter = "org.bluez.Adapter1";
const if_device = "org.bluez.Device1";
const if_battery = "org.bluez.Battery1";
const slow_ms = 60000;

pub const Adapter = extern struct {
    path: [64]u8,
    address: [24]u8,
    alias: [256]u8,
    name: [256]u8,
    powered: bool,
    discoverable: bool,
    pairable: bool,
    discovering: bool,
};

pub const Device = extern struct {
    path: [128]u8,
    adapter: [64]u8,
    address: [24]u8,
    alias: [256]u8,
    name: [256]u8,
    icon: [64]u8,
    device_class: u32,
    rssi: i16,
    battery: i16,
    paired: bool,
    trusted: bool,
    blocked: bool,
    connected: bool,
    has_rssi: bool,
    pad: [3]u8,
};

pub const State = struct {
    adapters: std.ArrayList(Adapter) = .empty,
    devices: std.ArrayList(Device) = .empty,

    pub fn destroy(s: *State) void {
        s.adapters.deinit(sys.gpa);
        s.devices.deinit(sys.gpa);
        sys.gpa.destroy(s);
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn props(r: *bus.Reader, comptime T: type, target: *T, comptime apply: fn (*T, []const u8, []const u8, *bus.Reader) anyerror!bool) !void {
    const end = try r.array('{');
    while (r.pos < end) {
        try r.structure();
        const key = try r.string();
        const sig = try r.variant();
        if (!try apply(target, key, sig, r)) try r.skip(sig);
    }
    if (r.pos != end) return error.Invalid;
}

fn text(dst: []u8, sig: []const u8, r: *bus.Reader) !bool {
    if (!eql(sig, "s") and !eql(sig, "o")) return false;
    sys.copyName(dst, try r.string());
    return true;
}

fn flag(dst: *bool, sig: []const u8, r: *bus.Reader) !bool {
    if (!eql(sig, "b")) return false;
    dst.* = try r.boolean();
    return true;
}

fn applyAdapter(a: *Adapter, key: []const u8, sig: []const u8, r: *bus.Reader) !bool {
    if (eql(key, "Address")) return text(&a.address, sig, r);
    if (eql(key, "Alias")) return text(&a.alias, sig, r);
    if (eql(key, "Name")) return text(&a.name, sig, r);
    if (eql(key, "Powered")) return flag(&a.powered, sig, r);
    if (eql(key, "Discoverable")) return flag(&a.discoverable, sig, r);
    if (eql(key, "Pairable")) return flag(&a.pairable, sig, r);
    if (eql(key, "Discovering")) return flag(&a.discovering, sig, r);
    return false;
}

fn applyDevice(d: *Device, key: []const u8, sig: []const u8, r: *bus.Reader) !bool {
    if (eql(key, "Address")) return text(&d.address, sig, r);
    if (eql(key, "Alias")) return text(&d.alias, sig, r);
    if (eql(key, "Name")) return text(&d.name, sig, r);
    if (eql(key, "Icon")) return text(&d.icon, sig, r);
    if (eql(key, "Adapter")) return text(&d.adapter, sig, r);
    if (eql(key, "Paired")) return flag(&d.paired, sig, r);
    if (eql(key, "Trusted")) return flag(&d.trusted, sig, r);
    if (eql(key, "Blocked")) return flag(&d.blocked, sig, r);
    if (eql(key, "Connected")) return flag(&d.connected, sig, r);
    if (eql(key, "Class") and eql(sig, "u")) {
        d.device_class = try r.uint32();
        return true;
    }
    if (eql(key, "RSSI") and eql(sig, "n")) {
        d.rssi = try r.int16();
        d.has_rssi = true;
        return true;
    }
    return false;
}

fn applyBattery(b: *i16, key: []const u8, sig: []const u8, r: *bus.Reader) !bool {
    if (!eql(key, "Percentage") or !eql(sig, "y")) return false;
    b.* = @min(try r.byte(), 100);
    return true;
}

fn byPath(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn less(_: void, a: T, b: T) bool {
            return std.mem.order(u8, sys.cstr(&a.path), sys.cstr(&b.path)) == .lt;
        }
    }.less;
}

pub fn snapshot(c: *bus.Conn) !*State {
    var m = try c.call(service, "/", bus.iface_objects, "GetManagedObjects", "", "", 25000);
    defer m.deinit();
    if (!eql(m.signature, "a{oa{sa{sv}}}")) return error.Invalid;
    const s = try sys.gpa.create(State);
    s.* = .{};
    errdefer s.destroy();
    var r = m.reader();
    const end = try r.array('{');
    while (r.pos < end) {
        try r.structure();
        const path = try r.string();
        var ad = std.mem.zeroes(Adapter);
        var dev = std.mem.zeroes(Device);
        var battery: i16 = -1;
        var is_adapter = false;
        var is_device = false;
        const iend = try r.array('{');
        while (r.pos < iend) {
            try r.structure();
            const iface = try r.string();
            if (eql(iface, if_adapter)) {
                is_adapter = true;
                try props(&r, Adapter, &ad, applyAdapter);
            } else if (eql(iface, if_device)) {
                is_device = true;
                try props(&r, Device, &dev, applyDevice);
            } else if (eql(iface, if_battery)) {
                try props(&r, i16, &battery, applyBattery);
            } else try r.skip("a{sv}");
        }
        if (is_adapter) {
            sys.copyName(&ad.path, path);
            try s.adapters.append(sys.gpa, ad);
        }
        if (is_device) {
            sys.copyName(&dev.path, path);
            dev.battery = battery;
            try s.devices.append(sys.gpa, dev);
        }
    }
    std.mem.sort(Adapter, s.adapters.items, {}, byPath(Adapter));
    std.mem.sort(Device, s.devices.items, {}, byPath(Device));
    return s;
}

fn ours(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/org/bluez/") and bus.validPath(path);
}

fn isDevice(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/dev_") != null;
}

pub const AdapterFlag = enum { powered, discoverable, pairable };
pub const DeviceFlag = enum { trusted, blocked };

pub fn setAdapter(c: *bus.Conn, path: []const u8, which: AdapterFlag, on: bool) !void {
    if (!ours(path) or isDevice(path)) return error.Invalid;
    const name = switch (which) {
        .powered => "Powered",
        .discoverable => "Discoverable",
        .pairable => "Pairable",
    };
    try c.setProperty(service, path, if_adapter, name, "b", on);
}

pub fn setDevice(c: *bus.Conn, path: []const u8, which: DeviceFlag, on: bool) !void {
    if (!ours(path) or !isDevice(path)) return error.Invalid;
    try c.setProperty(service, path, if_device, if (which == .trusted) "Trusted" else "Blocked", "b", on);
}

pub fn setAlias(c: *bus.Conn, path: []const u8, alias: []const u8) !void {
    if (!ours(path) or alias.len > 248) return error.Invalid;
    try c.setProperty(service, path, if (isDevice(path)) if_device else if_adapter, "Alias", "s", alias);
}

pub const Action = enum { connect, disconnect, pair, cancel_pairing };

pub fn device(c: *bus.Conn, path: []const u8, action: Action) !void {
    if (!ours(path) or !isDevice(path)) return error.Invalid;
    const member = switch (action) {
        .connect => "Connect",
        .disconnect => "Disconnect",
        .pair => "Pair",
        .cancel_pairing => "CancelPairing",
    };
    var m = try c.call(service, path, if_device, member, "", "", slow_ms);
    m.deinit();
}

pub fn remove(c: *bus.Conn, path: []const u8) !void {
    if (!ours(path) or !isDevice(path)) return error.Invalid;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
    var w = bus.Writer{};
    defer w.deinit();
    try w.objectPath(path);
    var m = try c.call(service, path[0..slash], if_adapter, "RemoveDevice", "o", w.bytes(), 25000);
    m.deinit();
}

pub fn discovery(c: *bus.Conn, adapter: []const u8, on: bool) !void {
    if (!ours(adapter) or isDevice(adapter)) return error.Invalid;
    var m = try c.call(service, adapter, if_adapter, if (on) "StartDiscovery" else "StopDiscovery", "", "", 25000);
    m.deinit();
}

const Fake = struct {
    conn: bus.Conn,
    stop: std.atomic.Value(bool) = .init(false),
    powered: bool = false,
    discovering: bool = false,
    trusted: bool = false,
    connected: bool = false,
    removed: bool = false,
    alias: [64]u8 = [_]u8{0} ** 64,

    fn entry(w: *bus.Writer, key: []const u8, sig: []const u8) !void {
        try w.beginStruct();
        try w.string(key);
        try w.variant(sig);
    }

    fn objects(f: *Fake, w: *bus.Writer) !void {
        const all = try w.beginArray('{');
        try w.beginStruct();
        try w.objectPath("/org/bluez");
        const root = try w.beginArray('{');
        try w.beginStruct();
        try w.string("org.bluez.AgentManager1");
        try w.endArray(try w.beginArray('{'));
        try w.endArray(root);

        try w.beginStruct();
        try w.objectPath("/org/bluez/hci0");
        const hci = try w.beginArray('{');
        try w.beginStruct();
        try w.string(if_adapter);
        const p1 = try w.beginArray('{');
        try entry(w, "Address", "s");
        try w.string("00:1A:7D:DA:71:13");
        try entry(w, "UUIDs", "as");
        const u = try w.beginArray('s');
        try w.string("0000110a-0000-1000-8000-00805f9b34fb");
        try w.endArray(u);
        try entry(w, "Alias", "s");
        try w.string(if (f.alias[0] != 0) sys.cstr(&f.alias) else "sinty");
        try entry(w, "Name", "s");
        try w.string("sinty");
        try entry(w, "Class", "u");
        try w.uint32(0x6c010c);
        try entry(w, "Powered", "b");
        try w.boolean(f.powered);
        try entry(w, "Discoverable", "b");
        try w.boolean(false);
        try entry(w, "Pairable", "b");
        try w.boolean(true);
        try entry(w, "Discovering", "b");
        try w.boolean(f.discovering);
        try w.endArray(p1);
        try w.endArray(hci);

        if (!f.removed) {
            try w.beginStruct();
            try w.objectPath("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01");
            const dev1 = try w.beginArray('{');
            try w.beginStruct();
            try w.string(if_battery);
            const pb = try w.beginArray('{');
            try entry(w, "Percentage", "y");
            try w.byte(80);
            try w.endArray(pb);
            try w.beginStruct();
            try w.string(if_device);
            const p2 = try w.beginArray('{');
            try entry(w, "Address", "s");
            try w.string("AA:BB:CC:DD:EE:01");
            try entry(w, "Alias", "s");
            try w.string("Cuffie");
            try entry(w, "Icon", "s");
            try w.string("audio-headset");
            try entry(w, "Adapter", "o");
            try w.objectPath("/org/bluez/hci0");
            try entry(w, "Paired", "b");
            try w.boolean(true);
            try entry(w, "Trusted", "b");
            try w.boolean(f.trusted);
            try entry(w, "Connected", "b");
            try w.boolean(f.connected);
            try entry(w, "RSSI", "n");
            try w.int16(-52);
            try entry(w, "Class", "u");
            try w.uint32(0x240404);
            try entry(w, "ServiceData", "a{sv}");
            try w.endArray(try w.beginArray('{'));
            try w.endArray(p2);
            try w.endArray(dev1);
        }

        try w.beginStruct();
        try w.objectPath("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_02");
        const dev2 = try w.beginArray('{');
        try w.beginStruct();
        try w.string(if_device);
        const p3 = try w.beginArray('{');
        try entry(w, "Address", "s");
        try w.string("AA:BB:CC:DD:EE:02");
        try entry(w, "Alias", "s");
        try w.string("Tastiera");
        try w.endArray(p3);
        try w.endArray(dev2);
        try w.endArray(all);
    }

    fn handle(f: *Fake, m: *const bus.Message) !void {
        if (eql(m.member, "GetManagedObjects")) {
            var w = bus.Writer{};
            defer w.deinit();
            try f.objects(&w);
            return f.conn.reply(m, "a{oa{sa{sv}}}", w.bytes());
        }
        if (eql(m.member, "Set")) {
            var r = m.reader();
            _ = try r.string();
            const name = try r.string();
            _ = try r.variant();
            if (eql(name, "Powered")) f.powered = try r.boolean();
            if (eql(name, "Trusted")) f.trusted = try r.boolean();
            if (eql(name, "Alias")) sys.copyName(&f.alias, try r.string());
            return f.conn.reply(m, "", "");
        }
        if (eql(m.member, "StartDiscovery")) f.discovering = true;
        if (eql(m.member, "StopDiscovery")) f.discovering = false;
        if (eql(m.member, "Connect")) f.connected = true;
        if (eql(m.member, "RemoveDevice")) {
            var r = m.reader();
            if (!eql(try r.string(), "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01") or !eql(m.path, "/org/bluez/hci0")) return f.conn.replyError(m, "org.bluez.Error.DoesNotExist", "no such device");
            f.removed = true;
        }
        if (eql(m.member, "Pair")) return f.conn.replyError(m, "org.bluez.Error.AuthenticationFailed", "the device refused");
        return f.conn.reply(m, "", "");
    }

    fn run(f: *Fake) void {
        while (!f.stop.load(.acquire)) {
            var m = (f.conn.next(50) catch return) orelse continue;
            defer m.deinit();
            if (m.kind == .call) f.handle(&m) catch {};
        }
    }
};

test "bluez objects, properties and methods through a bus" {
    const addr = std.c.getenv("SINTY_BUS_ADDRESS") orelse return error.SkipZigTest;
    var fake = Fake{ .conn = try bus.Conn.open(std.mem.span(addr)) };
    defer fake.conn.close();
    try fake.conn.requestName(service);
    const t = try std.Thread.spawn(.{}, Fake.run, .{&fake});
    defer {
        fake.stop.store(true, .release);
        t.join();
    }
    var c = try bus.Conn.open(std.mem.span(addr));
    defer c.close();

    const s = try snapshot(&c);
    defer s.destroy();
    try std.testing.expectEqual(@as(usize, 1), s.adapters.items.len);
    try std.testing.expectEqual(@as(usize, 2), s.devices.items.len);
    const a = s.adapters.items[0];
    try std.testing.expectEqualStrings("/org/bluez/hci0", sys.cstr(&a.path));
    try std.testing.expectEqualStrings("00:1A:7D:DA:71:13", sys.cstr(&a.address));
    try std.testing.expect(!a.powered and a.pairable and !a.discovering);
    const d = s.devices.items[0];
    try std.testing.expectEqualStrings("Cuffie", sys.cstr(&d.alias));
    try std.testing.expectEqualStrings("audio-headset", sys.cstr(&d.icon));
    try std.testing.expectEqualStrings("/org/bluez/hci0", sys.cstr(&d.adapter));
    try std.testing.expectEqual(@as(i16, 80), d.battery);
    try std.testing.expectEqual(@as(i16, -52), d.rssi);
    try std.testing.expectEqual(@as(u32, 0x240404), d.device_class);
    try std.testing.expect(d.paired and d.has_rssi and !d.connected);
    const k = s.devices.items[1];
    try std.testing.expectEqualStrings("Tastiera", sys.cstr(&k.alias));
    try std.testing.expectEqual(@as(i16, -1), k.battery);
    try std.testing.expect(!k.has_rssi);

    try setAdapter(&c, "/org/bluez/hci0", .powered, true);
    try setAlias(&c, "/org/bluez/hci0", "Laptop di Mirko");
    try discovery(&c, "/org/bluez/hci0", true);
    try setDevice(&c, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01", .trusted, true);
    try device(&c, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01", .connect);
    try std.testing.expectError(error.Access, device(&c, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_02", .pair));
    try std.testing.expect(std.mem.indexOf(u8, c.lastError(), "AuthenticationFailed") != null);
    try std.testing.expectError(error.Invalid, setAdapter(&c, "/org/freedesktop/DBus", .powered, true));
    try std.testing.expectError(error.Invalid, device(&c, "/org/bluez/hci0", .connect));

    const s2 = try snapshot(&c);
    defer s2.destroy();
    const a2 = s2.adapters.items[0];
    try std.testing.expect(a2.powered and a2.discovering);
    try std.testing.expectEqualStrings("Laptop di Mirko", sys.cstr(&a2.alias));
    try std.testing.expect(s2.devices.items[0].trusted and s2.devices.items[0].connected);

    try remove(&c, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01");
    const s3 = try snapshot(&c);
    defer s3.destroy();
    try std.testing.expectEqual(@as(usize, 1), s3.devices.items.len);
    try std.testing.expectEqualStrings("Tastiera", sys.cstr(&s3.devices.items[0].alias));
}
