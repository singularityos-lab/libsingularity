const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const socket_path = "/run/sinty-recoverd.sock";

pub const Kind = enum(c_int) { none = 0, pin = 1, pattern = 2 };

pub const Verdict = enum(c_int) { ok = 0, fail = 1, locked = 2, blocked = 3, invalid = 4 };

pub const State = extern struct {
    kind: c_int,
    armed: bool,
    length: i32,
};

pub fn available() bool {
    return sys.exists(socket_path);
}

fn connect() !i32 {
    const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer sys.close(fd);
    var addr = linux.sockaddr.un{ .path = [_]u8{0} ** 108 };
    const p = std.mem.span(@as([*:0]const u8, socket_path));
    if (p.len >= addr.path.len) return error.TooBig;
    @memcpy(addr.path[0..p.len], p);
    _ = try sys.check(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un)));
    const tv = linux.timeval{ .sec = 10, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    return fd;
}

fn request(msg: []const u8, reply: []u8) ![]const u8 {
    const fd = try connect();
    defer sys.close(fd);
    try sys.writeAll(fd, msg);
    var len: usize = 0;
    while (len < reply.len) {
        const n = try sys.read(fd, reply[len..]);
        if (n == 0) break;
        len += n;
        if (std.mem.indexOfScalar(u8, reply[0..len], '\n') != null) break;
    }
    const line = reply[0..len];
    const end = std.mem.indexOfScalar(u8, line, '\n') orelse line.len;
    return line[0..end];
}

fn clean(s: []const u8) bool {
    return s.len > 0 and std.mem.indexOfAny(u8, s, "\r\n") == null;
}

fn verdict(r: []const u8) Verdict {
    if (std.mem.eql(u8, r, "OK")) return .ok;
    if (std.mem.eql(u8, r, "LOCKED")) return .locked;
    if (std.mem.eql(u8, r, "BLOCKED")) return .blocked;
    if (std.mem.eql(u8, r, "INVALID")) return .invalid;
    return .fail;
}

fn ask(comptime fmt: []const u8, args: anytype) !Verdict {
    var msg: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &msg);
    const line = std.fmt.bufPrint(&msg, fmt, args) catch return error.TooBig;
    var reply: [32]u8 = undefined;
    return verdict(try request(line, &reply));
}

pub fn state(out: *State) !void {
    var reply: [64]u8 = undefined;
    const r = try request("quick-state\n", &reply);
    var it = std.mem.tokenizeScalar(u8, r, ' ');
    const kind = it.next() orelse return error.Invalid;
    const armed = it.next() orelse return error.Invalid;
    const length = it.next() orelse return error.Invalid;
    out.kind = @intFromEnum(if (std.mem.eql(u8, kind, "pin"))
        Kind.pin
    else if (std.mem.eql(u8, kind, "pattern"))
        Kind.pattern
    else
        Kind.none);
    out.armed = std.mem.eql(u8, armed, "1");
    out.length = std.fmt.parseInt(i32, length, 10) catch return error.Invalid;
}

pub fn verify(secret: []const u8) !Verdict {
    if (!clean(secret)) return error.Invalid;
    return ask("quick-verify\n{s}\n", .{secret});
}

pub fn set(pin: []const u8, kind: Kind, secret: []const u8) !Verdict {
    if (!clean(pin) or !clean(secret) or kind == .none) return error.Invalid;
    return ask("quick-set\n{s}\n{s}\n{s}\n", .{ pin, @tagName(kind), secret });
}

pub fn clear(pin: []const u8) !Verdict {
    if (!clean(pin)) return error.Invalid;
    return ask("quick-clear\n{s}\n", .{pin});
}

pub fn lockdown() !void {
    var reply: [16]u8 = undefined;
    if (verdict(try request("lockdown\n", &reply)) != .ok) return error.Io;
}

test "verdicts map the daemon replies" {
    try std.testing.expectEqual(Verdict.ok, verdict("OK"));
    try std.testing.expectEqual(Verdict.locked, verdict("LOCKED"));
    try std.testing.expectEqual(Verdict.blocked, verdict("BLOCKED"));
    try std.testing.expectEqual(Verdict.invalid, verdict("INVALID"));
    try std.testing.expectEqual(Verdict.fail, verdict("FAIL"));
    try std.testing.expectEqual(Verdict.fail, verdict(""));
}

test "secrets with line breaks are refused before reaching the daemon" {
    try std.testing.expect(!clean("12\n34"));
    try std.testing.expect(!clean(""));
    try std.testing.expect(clean("2580"));
    try std.testing.expectError(error.Invalid, verify("1\n2"));
    try std.testing.expectError(error.Invalid, set("2468", .none, "1234"));
}
