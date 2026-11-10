const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const default_socket = "/run/atom/control.sock";

pub const Reply = struct {
    ok: bool = false,
    err: [256]u8 = std.mem.zeroes([256]u8),
    state: [64]u8 = std.mem.zeroes([64]u8),
};

const actions = [_][]const u8{ "start", "stop", "restart", "status" };

pub fn validUnit(unit: []const u8) bool {
    if (unit.len == 0 or unit.len > 128) return false;
    for (unit) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '@', '.', '_', '-', ':' => {},
        else => return false,
    };
    return true;
}

fn knownAction(action: []const u8) bool {
    for (actions) |a| if (std.mem.eql(u8, a, action)) return true;
    return false;
}

fn readFull(fd: i32, buf: []u8) !void {
    var n: usize = 0;
    while (n < buf.len) {
        const got = try sys.read(fd, buf[n..]);
        if (got == 0) return error.Io;
        n += got;
    }
}

fn stringField(body: []const u8, name: []const u8, out: []u8) bool {
    var key: [32]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "\"{s}\":", .{name}) catch return false;
    var i = (std.mem.indexOf(u8, body, k) orelse return false) + k.len;
    while (i < body.len and body[i] == ' ') i += 1;
    if (i >= body.len or body[i] != '"') return false;
    i += 1;
    var n: usize = 0;
    while (i < body.len and body[i] != '"') : (i += 1) {
        var c = body[i];
        if (c == '\\' and i + 1 < body.len) {
            i += 1;
            c = switch (body[i]) {
                'n' => '\n',
                't' => '\t',
                'u' => blk: {
                    if (i + 4 >= body.len) return false;
                    const v = std.fmt.parseInt(u16, body[i + 1 .. i + 5], 16) catch return false;
                    i += 4;
                    break :blk if (v < 0x80) @intCast(v) else '?';
                },
                else => body[i],
            };
        }
        if (n + 1 < out.len) {
            out[n] = c;
            n += 1;
        }
    }
    out[n] = 0;
    return true;
}

pub fn parseReply(body: []const u8) Reply {
    var r = Reply{};
    if (std.mem.indexOf(u8, body, "\"ok\":")) |i| {
        var j = i + 5;
        while (j < body.len and body[j] == ' ') j += 1;
        r.ok = std.mem.startsWith(u8, body[j..], "true");
    }
    _ = stringField(body, "error", &r.err);
    _ = stringField(body, "state", &r.state);
    return r;
}

pub fn address(socket: []const u8, addr: *linux.sockaddr.un) !linux.socklen_t {
    addr.* = std.mem.zeroes(linux.sockaddr.un);
    addr.family = linux.AF.UNIX;
    if (socket.len == 0 or socket.len >= addr.path.len) return error.TooBig;
    @memcpy(addr.path[0..socket.len], socket);
    if (socket[0] != '@') return @sizeOf(linux.sockaddr.un);
    addr.path[0] = 0;
    return @intCast(@offsetOf(linux.sockaddr.un, "path") + socket.len);
}

pub fn send(socket: []const u8, action: []const u8, unit: []const u8) !Reply {
    if (!knownAction(action) or !validUnit(unit)) return error.Invalid;
    var addr: linux.sockaddr.un = undefined;
    const addr_len = try address(socket, &addr);
    const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer sys.close(fd);
    _ = try sys.check(linux.connect(fd, @ptrCast(&addr), addr_len));
    var req: [256]u8 = undefined;
    const body = std.fmt.bufPrint(req[4..], "{{\"cmd\":\"{s}\",\"unit\":\"{s}\"}}", .{ action, unit }) catch return error.TooBig;
    std.mem.writeInt(u32, req[0..4], @intCast(body.len), .big);
    try sys.writeAll(fd, req[0 .. 4 + body.len]);
    var hdr: [4]u8 = undefined;
    try readFull(fd, &hdr);
    const len = std.mem.readInt(u32, &hdr, .big);
    if (len > 64 << 10) return error.TooBig;
    const reply = try sys.gpa.alloc(u8, len);
    defer sys.gpa.free(reply);
    try readFull(fd, reply);
    return parseReply(reply);
}

pub fn control(socket: []const u8, action: []const u8, unit: []const u8) !void {
    const r = try send(socket, action, unit);
    if (!r.ok or sys.cstr(&r.err).len > 0) return error.Io;
}

test "units and replies" {
    try std.testing.expect(validUnit("chrony.service"));
    try std.testing.expect(validUnit("getty@tty1.service"));
    try std.testing.expect(!validUnit("a\"b"));
    try std.testing.expect(!validUnit(""));
    const r = parseReply("{\"ok\":true,\"state\":\"running\"}");
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("running", sys.cstr(&r.state));
    const bad = parseReply("{\"ok\":false,\"error\":\"unit \\u003cx\\u003e not found\"}");
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings("unit <x> not found", sys.cstr(&bad.err));
    try std.testing.expectError(error.Invalid, send("/nonexistent", "kill", "x.service"));
}

fn serveOnce(lfd: i32) void {
    const cfd: i32 = @intCast(linux.accept(lfd, null, null));
    defer sys.close(cfd);
    var hdr: [4]u8 = undefined;
    readFull(cfd, &hdr) catch return;
    var body: [256]u8 = undefined;
    const n = std.mem.readInt(u32, &hdr, .big);
    readFull(cfd, body[0..n]) catch return;
    const reply = if (std.mem.indexOf(u8, body[0..n], "\"cmd\":\"status\"") != null and std.mem.indexOf(u8, body[0..n], "\"unit\":\"chrony.service\"") != null)
        "{\"ok\":true,\"state\":\"running\"}"
    else
        "{\"ok\":false,\"error\":\"no such unit\"}";
    var out: [128]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(reply.len), .big);
    @memcpy(out[4 .. 4 + reply.len], reply);
    sys.writeAll(cfd, out[0 .. 4 + reply.len]) catch {};
}

test "talks to the init control socket" {
    var pb: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "@sinty-system-test-{d}", .{linux.getpid()});
    const lfd: i32 = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer sys.close(lfd);
    var addr: linux.sockaddr.un = undefined;
    const len = try address(path, &addr);
    _ = try sys.check(linux.bind(lfd, @ptrCast(&addr), len));
    _ = try sys.check(linux.listen(lfd, 4));
    const a = try std.Thread.spawn(.{}, serveOnce, .{lfd});
    const r = try send(path, "status", "chrony.service");
    a.join();
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("running", sys.cstr(&r.state));
    const b = try std.Thread.spawn(.{}, serveOnce, .{lfd});
    try std.testing.expectError(error.Io, control(path, "start", "missing.service"));
    b.join();
}
