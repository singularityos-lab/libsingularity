const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const EsrtEntry = extern struct {
    fw_class: [40]u8,
    fw_type: u32,
    fw_version: u32,
    lowest_supported_version: u32,
    capsule_flags: u32,
    last_attempt_version: u32,
    last_attempt_status: u32,
};

pub const EsrtList = sys.List(EsrtEntry);

pub const global_guid = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
const file_capsule_delivery: u64 = 0x4;
const var_attrs: u32 = 0x7;
const fs_ioc_getflags: u32 = 0x80086601;
const fs_ioc_setflags: u32 = 0x40086602;
const fs_immutable_fl: c_long = 0x10;

fn entryInt(dir: []const u8, name: []const u8) u32 {
    var buf: [512]u8 = undefined;
    const p = sys.pathZ(&buf, "{s}/{s}", .{ dir, name }) catch return 0;
    var vb: [32]u8 = undefined;
    const s = sys.readTrim(p, &vb) orelse return 0;
    if (std.mem.startsWith(u8, s, "0x")) return std.fmt.parseInt(u32, s[2..], 16) catch 0;
    return std.fmt.parseInt(u32, s, 10) catch 0;
}

pub fn esrt(root: []const u8) !*EsrtList {
    const list = try EsrtList.create();
    errdefer list.destroy();
    var buf: [512]u8 = undefined;
    var d = sys.Dir.open(try sys.pathZ(&buf, "{s}/entries", .{root})) catch return list;
    defer d.close();
    var denied = false;
    while (try d.next()) |e| {
        if (!std.mem.startsWith(u8, e.name, "entry")) continue;
        var db: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&db, "{s}/entries/{s}", .{ root, e.name }) catch continue;
        var entry = std.mem.zeroes(EsrtEntry);
        var cb: [512]u8 = undefined;
        var vb: [64]u8 = undefined;
        const raw = sys.readFile(try sys.pathZ(&cb, "{s}/fw_class", .{dir}), &vb) catch |err| {
            if (err == error.Access) denied = true;
            continue;
        };
        sys.copyName(&entry.fw_class, sys.trim(raw));
        entry.fw_type = entryInt(dir, "fw_type");
        entry.fw_version = entryInt(dir, "fw_version");
        entry.lowest_supported_version = entryInt(dir, "lowest_supported_fw_version");
        entry.capsule_flags = entryInt(dir, "capsule_flags");
        entry.last_attempt_version = entryInt(dir, "last_attempt_version");
        entry.last_attempt_status = entryInt(dir, "last_attempt_status");
        try list.append(entry);
    }
    if (denied and list.count() == 0) return error.Access;
    std.mem.sort(EsrtEntry, list.items.items, {}, struct {
        fn lt(_: void, a: EsrtEntry, b: EsrtEntry) bool {
            return std.mem.order(u8, sys.cstr(&a.fw_class), sys.cstr(&b.fw_class)) == .lt;
        }
    }.lt);
    return list;
}

fn readVar(efivars: []const u8, name: []const u8) !u64 {
    var buf: [512]u8 = undefined;
    var data: [16]u8 = undefined;
    const got = try sys.readFile(try sys.pathZ(&buf, "{s}/{s}-{s}", .{ efivars, name, global_guid }), &data);
    if (got.len < 5) return error.Invalid;
    var v: [8]u8 = std.mem.zeroes([8]u8);
    const n = @min(got.len - 4, 8);
    @memcpy(v[0..n], got[4 .. 4 + n]);
    return std.mem.readInt(u64, &v, .little);
}

pub fn capsuleSupported(efivars: []const u8) bool {
    const v = readVar(efivars, "OsIndicationsSupported") catch return false;
    return v & file_capsule_delivery != 0;
}

fn mutable(path: [*:0]const u8) void {
    const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return;
    defer sys.close(fd);
    var flags: c_long = 0;
    _ = sys.ioctl(fd, fs_ioc_getflags, @intFromPtr(&flags)) catch return;
    if (flags & fs_immutable_fl == 0) return;
    flags &= ~fs_immutable_fl;
    _ = sys.ioctl(fd, fs_ioc_setflags, @intFromPtr(&flags)) catch {};
}

pub fn requestCapsuleDelivery(efivars: []const u8) !void {
    if (!capsuleSupported(efivars)) return error.Unsupported;
    const current = readVar(efivars, "OsIndications") catch 0;
    if (current & file_capsule_delivery != 0) return;
    var buf: [512]u8 = undefined;
    const path = try sys.pathZ(&buf, "{s}/OsIndications-{s}", .{ efivars, global_guid });
    mutable(path);
    var out: [12]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], var_attrs, .little);
    std.mem.writeInt(u64, out[4..12], current | file_capsule_delivery, .little);
    const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
    defer sys.close(fd);
    const n = try sys.write(fd, &out);
    if (n != out.len) return error.Io;
}

pub fn validName(name: []const u8) bool {
    if (name.len < 5 or name.len > 64) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return name[0] != '.' and (std.ascii.endsWithIgnoreCase(name, ".cap") or std.ascii.endsWithIgnoreCase(name, ".bin"));
}

pub fn validCapsule(data: []const u8) bool {
    if (data.len < 28) return false;
    const header_size = std.mem.readInt(u32, data[16..20], .little);
    const image_size = std.mem.readInt(u32, data[24..28], .little);
    return header_size >= 28 and header_size <= data.len and image_size == data.len;
}

pub fn stageCapsule(esp: []const u8, efivars: []const u8, name: []const u8, data: []const u8) !void {
    if (!validName(name) or !validCapsule(data)) return error.Invalid;
    if (!capsuleSupported(efivars)) return error.Unsupported;
    var db: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&db, "{s}/EFI/UpdateCapsule", .{esp}) catch return error.TooBig;
    try sys.mkdirs(dir);
    var tb: [600]u8 = undefined;
    const tmp = try sys.pathZ(&tb, "{s}/.{s}.part", .{ dir, name });
    var fb: [600]u8 = undefined;
    const final = try sys.pathZ(&fb, "{s}/{s}", .{ dir, name });
    {
        const fd = try sys.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        defer sys.close(fd);
        try sys.writeAll(fd, data);
        _ = try sys.check(linux.fsync(fd));
    }
    _ = sys.check(linux.renameat(linux.AT.FDCWD, tmp, linux.AT.FDCWD, final)) catch |e| {
        _ = linux.unlinkat(linux.AT.FDCWD, tmp, 0);
        return e;
    };
    try requestCapsuleDelivery(efivars);
}

fn fakeVar(root: []const u8, name: []const u8, value: u64) !void {
    var data: [12]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0x6, .little);
    std.mem.writeInt(u64, data[4..12], value, .little);
    var nb: [128]u8 = undefined;
    try sys.put(root, try std.fmt.bufPrint(&nb, "{s}-{s}", .{ name, global_guid }), &data);
}

fn capsule(buf: []u8) []u8 {
    @memset(buf, 0xab);
    std.mem.writeInt(u32, buf[16..20], 28, .little);
    std.mem.writeInt(u32, buf[20..24], 0x50000, .little);
    std.mem.writeInt(u32, buf[24..28], @intCast(buf.len), .little);
    return buf;
}

test "esrt entries from sysfs" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "esrt");
    try sys.put(root, "entries/entry1/fw_class", "ddc0ee61-e7f0-4e7d-acc5-c070a398838e\n");
    try sys.put(root, "entries/entry1/fw_type", "1\n");
    try sys.put(root, "entries/entry1/fw_version", "65586\n");
    try sys.put(root, "entries/entry1/lowest_supported_fw_version", "1\n");
    try sys.put(root, "entries/entry1/capsule_flags", "0x8010\n");
    try sys.put(root, "entries/entry1/last_attempt_status", "0\n");
    try sys.put(root, "entries/entry0/fw_class", "3c2f2dd0-0c3d-4bd4-a26f-a1e8d5f8b1b4\n");
    try sys.put(root, "entries/entry0/fw_type", "2\n");
    const l = try esrt(root);
    defer l.destroy();
    try std.testing.expectEqual(@as(usize, 2), l.count());
    const e = l.items.items[1];
    try std.testing.expectEqualStrings("ddc0ee61-e7f0-4e7d-acc5-c070a398838e", sys.cstr(&e.fw_class));
    try std.testing.expectEqual(@as(u32, 65586), e.fw_version);
    try std.testing.expectEqual(@as(u32, 0x8010), e.capsule_flags);
}

test "the esrt of this machine reads when present" {
    if (!sys.exists("/sys/firmware/efi/esrt/entries")) return error.SkipZigTest;
    const l = esrt("/sys/firmware/efi/esrt") catch |e| {
        if (e == error.Access and linux.geteuid() != 0) return error.SkipZigTest;
        return e;
    };
    defer l.destroy();
    try std.testing.expect(l.count() > 0);
    for (l.items.items) |e| try std.testing.expectEqual(@as(usize, 36), sys.cstr(&e.fw_class).len);
}

test "staging a capsule writes it and asks the firmware for it" {
    var rb: [512]u8 = undefined;
    const root = try sys.testRoot(&rb, "capsule");
    var eb: [600]u8 = undefined;
    const efivars = try std.fmt.bufPrint(&eb, "{s}/efivars", .{root});
    var pb: [600]u8 = undefined;
    const esp = try std.fmt.bufPrint(&pb, "{s}/esp", .{root});
    var raw: [256]u8 = undefined;
    const cap = capsule(&raw);
    try std.testing.expectError(error.Unsupported, stageCapsule(esp, efivars, "fw.cap", cap));
    try fakeVar(efivars, "OsIndicationsSupported", 0x1 | 0x4);
    try fakeVar(efivars, "OsIndications", 0x1);
    try std.testing.expectError(error.Invalid, stageCapsule(esp, efivars, "../x.cap", cap));
    try std.testing.expectError(error.Invalid, stageCapsule(esp, efivars, "fw.cap", cap[0..100]));
    try stageCapsule(esp, efivars, "fw.cap", cap);
    var sb: [700]u8 = undefined;
    const staged = try sys.readAlloc(sys.gpa, try sys.pathZ(&sb, "{s}/EFI/UpdateCapsule/fw.cap", .{esp}), 4096);
    defer sys.gpa.free(staged);
    try std.testing.expectEqualSlices(u8, cap, staged);
    try std.testing.expectEqual(@as(u64, 0x5), try readVar(efivars, "OsIndications"));
    var vb: [700]u8 = undefined;
    var attr: [16]u8 = undefined;
    const written = try sys.readFile(try sys.pathZ(&vb, "{s}/OsIndications-{s}", .{ efivars, global_guid }), &attr);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, written[0..4], .little));
}
