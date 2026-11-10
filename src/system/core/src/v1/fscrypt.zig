const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;
const Hkdf = std.crypto.kdf.hkdf.Hkdf(HmacSha512);

pub const key_size = 64;
pub const id_size = 16;
pub const Id = [id_size]u8;

pub const mode_aes_256_xts: u8 = 1;
pub const mode_aes_256_cts: u8 = 4;
pub const mode_aes_128_cbc: u8 = 5;
pub const mode_aes_128_cts: u8 = 6;
pub const mode_adiantum: u8 = 9;
pub const mode_aes_256_hctr2: u8 = 10;

pub const flag_pad_4: u8 = 0;
pub const flag_pad_8: u8 = 1;
pub const flag_pad_16: u8 = 2;
pub const flag_pad_32: u8 = 3;
pub const flag_direct_key: u8 = 4;
pub const flag_iv_ino_lblk_64: u8 = 8;
pub const flag_iv_ino_lblk_32: u8 = 16;

pub const Status = enum(u32) { absent = 1, present = 2, incompletely_removed = 3, _ };

pub const KeyStatus = extern struct {
    status: Status,
    user_count: u32,
    added_by_self: bool,
};

pub const Removal = struct {
    files_busy: bool,
    other_users: bool,
};

pub const Policy = extern struct {
    version: u8 = 2,
    contents: u8 = mode_aes_256_xts,
    filenames: u8 = mode_aes_256_cts,
    flags: u8 = flag_pad_16,
    log2_data_unit_size: u8 = 0,
    reserved: [3]u8 = .{ 0, 0, 0 },
    id: Id,

    pub fn init(id: Id) Policy {
        return .{ .id = id };
    }
};

fn iowr(nr: u8, size: u14) u32 {
    return (@as(u32, 3) << 30) | (@as(u32, size) << 16) | (@as(u32, 'f') << 8) | nr;
}

fn ior(nr: u8, size: u14) u32 {
    return (@as(u32, 2) << 30) | (@as(u32, size) << 16) | (@as(u32, 'f') << 8) | nr;
}

const spec_size = 40;
const add_size = spec_size + 4 + 4 + 32;
const remove_size = spec_size + 4 + 20;
const status_size = spec_size + 24 + 4 + 4 + 4 + 52;

const ioc_set_policy = ior(19, 12);
const ioc_get_policy_ex = iowr(22, 9);
const ioc_add_key = iowr(23, add_size);
const ioc_remove_key = iowr(24, remove_size);
const ioc_remove_key_all = iowr(25, remove_size);
const ioc_key_status = iowr(26, status_size);

const spec_identifier: u32 = 2;

pub fn identifier(raw: []const u8) Id {
    const prk = Hkdf.extract(&[_]u8{}, raw);
    var out: Id = undefined;
    Hkdf.expand(&out, "fscrypt\x00\x01", prk);
    return out;
}

pub fn hex(id: Id) [id_size * 2]u8 {
    return std.fmt.bytesToHex(id, .lower);
}

pub fn parseHex(s: []const u8) !Id {
    if (s.len != id_size * 2) return error.Invalid;
    var id: Id = undefined;
    _ = std.fmt.hexToBytes(&id, s) catch return error.Invalid;
    return id;
}

fn openDir(path: [*:0]const u8) !i32 {
    return sys.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
}

fn keyIoctl(fd: i32, request: u32, arg: usize) !void {
    while (true) {
        const rc = linux.ioctl(fd, request, arg);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .NOKEY => return error.NotFound,
            .OPNOTSUPP, .NOTTY => return error.Unsupported,
            else => |e| return sys.fromErrno(e),
        }
    }
}

fn putSpec(buf: []u8, id: Id) void {
    std.mem.writeInt(u32, buf[0..4], spec_identifier, .little);
    @memcpy(buf[8 .. 8 + id_size], &id);
}

pub fn addKey(mount: [*:0]const u8, raw: []const u8) !Id {
    if (raw.len != key_size) return error.Invalid;
    const fd = try openDir(mount);
    defer sys.close(fd);
    var buf: [add_size + key_size]u8 align(8) = std.mem.zeroes([add_size + key_size]u8);
    defer std.crypto.secureZero(u8, &buf);
    std.mem.writeInt(u32, buf[0..4], spec_identifier, .little);
    std.mem.writeInt(u32, buf[spec_size..][0..4], key_size, .little);
    @memcpy(buf[add_size..], raw);
    try keyIoctl(fd, ioc_add_key, @intFromPtr(&buf));
    return buf[8 .. 8 + id_size].*;
}

pub fn removeKey(mount: [*:0]const u8, id: Id, all_users: bool) !Removal {
    const fd = try openDir(mount);
    defer sys.close(fd);
    var buf: [remove_size]u8 align(8) = std.mem.zeroes([remove_size]u8);
    putSpec(&buf, id);
    try keyIoctl(fd, if (all_users) ioc_remove_key_all else ioc_remove_key, @intFromPtr(&buf));
    const flags = std.mem.readInt(u32, buf[spec_size..][0..4], .little);
    return .{ .files_busy = flags & 1 != 0, .other_users = flags & 2 != 0 };
}

pub fn keyStatus(mount: [*:0]const u8, id: Id) !KeyStatus {
    const fd = try openDir(mount);
    defer sys.close(fd);
    var buf: [status_size]u8 align(8) = std.mem.zeroes([status_size]u8);
    putSpec(&buf, id);
    try keyIoctl(fd, ioc_key_status, @intFromPtr(&buf));
    const out = buf[spec_size + 24 ..];
    return .{
        .status = @enumFromInt(std.mem.readInt(u32, out[0..4], .little)),
        .added_by_self = std.mem.readInt(u32, out[4..8], .little) & 1 != 0,
        .user_count = std.mem.readInt(u32, out[8..12], .little),
    };
}

pub fn setPolicy(dir: [*:0]const u8, policy: Policy) !void {
    const fd = try openDir(dir);
    defer sys.close(fd);
    var p = policy;
    try keyIoctl(fd, ioc_set_policy, @intFromPtr(&p));
}

pub fn getPolicy(path: [*:0]const u8) !?Policy {
    const fd = try sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0);
    defer sys.close(fd);
    var buf: [8 + @sizeOf(Policy)]u8 align(8) = std.mem.zeroes([8 + @sizeOf(Policy)]u8);
    std.mem.writeInt(u64, buf[0..8], @sizeOf(Policy), .little);
    const rc = linux.ioctl(fd, ioc_get_policy_ex, @intFromPtr(&buf));
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NODATA => return null,
        .OPNOTSUPP, .NOTTY => return error.Unsupported,
        .OVERFLOW => return error.Unsupported,
        else => |e| return sys.fromErrno(e),
    }
    if (buf[8] != 2) return error.Unsupported;
    return std.mem.bytesToValue(Policy, buf[8..]);
}

test "ioctl numbers match the kernel uapi" {
    try std.testing.expectEqual(@as(u32, 0x800c6613), ioc_set_policy);
    try std.testing.expectEqual(@as(u32, 0xc0096616), ioc_get_policy_ex);
    try std.testing.expectEqual(@as(u32, 0xc0506617), ioc_add_key);
    try std.testing.expectEqual(@as(u32, 0xc0406618), ioc_remove_key);
    try std.testing.expectEqual(@as(u32, 0xc0406619), ioc_remove_key_all);
    try std.testing.expectEqual(@as(u32, 0xc080661a), ioc_key_status);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Policy));
}

test "identifier follows the kernel hkdf derivation" {
    var raw: [key_size]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @intCast(i);
    const id = identifier(&raw);
    try std.testing.expectEqualStrings(expected_id, &hex(id));
    try std.testing.expectEqualSlices(u8, &id, &(try parseHex(expected_id)));
    try std.testing.expectError(error.Invalid, parseHex("abc"));
    try std.testing.expectError(error.Invalid, parseHex("zz" ** 16));
}

test "policy layout" {
    const p = Policy.init(.{0xaa} ** id_size);
    const b = std.mem.asBytes(&p);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 4, 2, 0, 0, 0, 0 }, b[0..8]);
    try std.testing.expectEqualSlices(u8, &(.{0xaa} ** id_size), b[8..]);
}

test "unsupported filesystems are reported" {
    try std.testing.expectError(error.Invalid, addKey("/", "short"));
    var buf: [256]u8 = undefined;
    const dir = try sys.testRoot(&buf, "fscrypt");
    var zbuf: [272]u8 = undefined;
    const z = try sys.pathZ(&zbuf, "{s}", .{dir});
    const p = getPolicy(z) catch |e| switch (e) {
        error.Unsupported => return,
        else => return e,
    };
    if (p) |pol| {
        try std.testing.expectEqual(@as(u8, 2), pol.version);
        try std.testing.expect(pol.contents != 0);
    }
}

const expected_id = "8699c2c53707405da5aba5ae4d8583c0";
