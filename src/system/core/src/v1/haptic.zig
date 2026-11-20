const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

const ff_rumble: u16 = 0x50;
const ev_ff: u16 = 0x15;

const Effect = extern struct {
    kind: u16,
    id: i16,
    direction: u16,
    trigger_button: u16,
    trigger_interval: u16,
    replay_length: u16,
    replay_delay: u16,
    u: extern union {
        rumble: extern struct { strong: u16, weak: u16 },
        periodic: extern struct { fields: [9]u16, custom_len: u32, custom_data: ?*anyopaque },
    },
};

const Event = extern struct {
    time: linux.timeval,
    kind: u16,
    code: u16,
    value: i32,
};

const eviocsff: u32 = (1 << 30) | (@as(u32, @sizeOf(Effect)) << 16) | ('E' << 8) | 0x80;

var lock: std.c.pthread_mutex_t = .{};
var fd: i32 = -1;
var probed = false;
var effect_id: i16 = -1;
var effect_ms: u16 = 0;
var effect_strength: u16 = 0;

fn hasRumble(caps: []const u8) bool {
    var words: [8]u64 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, caps, " \n");
    while (it.next()) |w| {
        if (n == words.len) return false;
        words[n] = std.fmt.parseInt(u64, w, 16) catch return false;
        n += 1;
    }
    const bit: usize = ff_rumble;
    const word = bit / 64;
    if (word >= n) return false;
    return (words[n - 1 - word] >> @intCast(bit % 64)) & 1 == 1;
}

fn probe(root: []const u8) i32 {
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var path: [128]u8 = undefined;
        const caps_path = std.fmt.bufPrintZ(&path, "{s}/class/input/event{d}/device/capabilities/ff", .{ root, i }) catch return -1;
        var buf: [256]u8 = undefined;
        const caps = sys.readFile(caps_path, &buf) catch continue;
        if (!hasRumble(caps)) continue;
        var dev: [64]u8 = undefined;
        const dev_path = std.fmt.bufPrintZ(&dev, "/dev/input/event{d}", .{i}) catch return -1;
        return sys.open(dev_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NONBLOCK = true }, 0) catch continue;
    }
    return -1;
}

fn device() i32 {
    if (!probed) {
        probed = true;
        fd = probe("/sys");
    }
    return fd;
}

pub fn available() bool {
    _ = std.c.pthread_mutex_lock(&lock);
    defer _ = std.c.pthread_mutex_unlock(&lock);
    return device() >= 0;
}

pub fn pulse(ms: u32, strength: u16) !void {
    if (ms == 0 or ms > 1000) return error.Invalid;
    _ = std.c.pthread_mutex_lock(&lock);
    defer _ = std.c.pthread_mutex_unlock(&lock);
    const d = device();
    if (d < 0) return error.Unsupported;
    const length: u16 = @intCast(ms);
    if (effect_id < 0 or effect_ms != length or effect_strength != strength) {
        var e = std.mem.zeroes(Effect);
        e.kind = ff_rumble;
        e.id = effect_id;
        e.replay_length = length;
        e.u.rumble = .{ .strong = strength, .weak = strength / 2 };
        _ = sys.ioctl(d, eviocsff, @intFromPtr(&e)) catch |err| {
            effect_id = -1;
            return err;
        };
        effect_id = e.id;
        effect_ms = length;
        effect_strength = strength;
    }
    var ev = std.mem.zeroes(Event);
    ev.kind = ev_ff;
    ev.code = @intCast(effect_id);
    ev.value = 1;
    _ = try sys.write(d, std.mem.asBytes(&ev));
}

pub const key_ms: u32 = 12;
pub const key_strength: u16 = 0x6000;

pub fn key() !void {
    try pulse(key_ms, key_strength);
}

test "rumble bit in the capability words" {
    try std.testing.expect(hasRumble("107030000 0\n"));
    try std.testing.expect(!hasRumble("0 0\n"));
    try std.testing.expect(!hasRumble("30000\n"));
    try std.testing.expect(hasRumble("10000 0 0\n") == false);
    try std.testing.expect(hasRumble("0 10000 0\n"));
}
