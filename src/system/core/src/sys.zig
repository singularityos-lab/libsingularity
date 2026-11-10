const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ NotFound, Access, Invalid, Busy, Unsupported, NoMemory, Io, TooBig, Again, Exists };

pub fn fromErrno(e: linux.E) Error {
    return switch (e) {
        .NOENT, .NODEV, .NXIO, .SRCH => error.NotFound,
        .ACCES, .PERM, .ROFS => error.Access,
        .INVAL, .BADF, .NOTDIR, .ISDIR => error.Invalid,
        .BUSY => error.Busy,
        .NOSYS, .OPNOTSUPP, .NOTTY, .AFNOSUPPORT, .PROTONOSUPPORT => error.Unsupported,
        .NOMEM, .NOBUFS => error.NoMemory,
        .AGAIN => error.Again,
        .EXIST => error.Exists,
        else => error.Io,
    };
}

pub fn code(err: anyerror) c_int {
    return switch (err) {
        error.NotFound => -@as(c_int, @intFromEnum(linux.E.NOENT)),
        error.Access => -@as(c_int, @intFromEnum(linux.E.ACCES)),
        error.Invalid => -@as(c_int, @intFromEnum(linux.E.INVAL)),
        error.Busy => -@as(c_int, @intFromEnum(linux.E.BUSY)),
        error.Unsupported => -@as(c_int, @intFromEnum(linux.E.OPNOTSUPP)),
        error.NoMemory, error.OutOfMemory => -@as(c_int, @intFromEnum(linux.E.NOMEM)),
        error.Again => -@as(c_int, @intFromEnum(linux.E.AGAIN)),
        error.TooBig => -@as(c_int, @intFromEnum(linux.E.FBIG)),
        error.Exists => -@as(c_int, @intFromEnum(linux.E.EXIST)),
        else => -@as(c_int, @intFromEnum(linux.E.IO)),
    };
}

pub fn check(rc: usize) Error!usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) return fromErrno(e);
    return rc;
}

pub fn open(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) Error!i32 {
    while (true) {
        const rc = linux.openat(linux.AT.FDCWD, path, flags, mode);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return fromErrno(e);
        return @intCast(rc);
    }
}

pub fn openAt(dir: i32, path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) Error!i32 {
    while (true) {
        const rc = linux.openat(dir, path, flags, mode);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return fromErrno(e);
        return @intCast(rc);
    }
}

pub fn close(fd: i32) void {
    _ = linux.close(fd);
}

pub fn read(fd: i32, buf: []u8) Error!usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return fromErrno(e);
        return rc;
    }
}

pub fn pread(fd: i32, buf: []u8, offset: u64) Error!usize {
    while (true) {
        const rc = linux.pread(fd, buf.ptr, buf.len, @intCast(offset));
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return fromErrno(e);
        return rc;
    }
}

pub fn write(fd: i32, buf: []const u8) Error!usize {
    while (true) {
        const rc = linux.write(fd, buf.ptr, buf.len);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return fromErrno(e);
        return rc;
    }
}

pub fn pwriteAll(fd: i32, buf: []const u8, offset: u64) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.pwrite(fd, buf.ptr + done, buf.len - done, @intCast(offset + done));
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return fromErrno(e);
        if (rc == 0) return error.Io;
        done += rc;
    }
}

pub fn writeAll(fd: i32, buf: []const u8) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const n = try write(fd, buf[done..]);
        if (n == 0) return error.Io;
        done += n;
    }
}

pub fn ioctl(fd: i32, request: u32, arg: usize) Error!usize {
    while (true) {
        const rc = linux.ioctl(fd, request, arg);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return fromErrno(e);
        return rc;
    }
}

pub fn readFileAt(dir: i32, path: [*:0]const u8, buf: []u8) Error![]u8 {
    const fd = try openAt(dir, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = try read(fd, buf[len..]);
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

pub fn readFile(path: [*:0]const u8, buf: []u8) Error![]u8 {
    return readFileAt(linux.AT.FDCWD, path, buf);
}

pub fn readAlloc(alloc: std.mem.Allocator, path: [*:0]const u8, limit: usize) ![]u8 {
    const fd = try open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = try read(fd, &chunk);
        if (n == 0) break;
        if (list.items.len + n > limit) return error.TooBig;
        try list.appendSlice(alloc, chunk[0..n]);
    }
    return list.toOwnedSlice(alloc);
}

pub fn writeFile(path: [*:0]const u8, data: []const u8) Error!void {
    const fd = try open(path, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }, 0);
    defer close(fd);
    try writeAll(fd, data);
}

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x00");
}

pub fn readTrim(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const data = readFile(path, buf) catch return null;
    return trim(data);
}

pub fn readInt(comptime T: type, path: [*:0]const u8) ?T {
    var buf: [64]u8 = undefined;
    const s = readTrim(path, &buf) orelse return null;
    return std.fmt.parseInt(T, s, 10) catch null;
}

pub fn pathZ(buf: []u8, comptime fmt: []const u8, args: anytype) Error![*:0]const u8 {
    const s = std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch return error.TooBig;
    return s.ptr;
}

pub const Dir = struct {
    fd: i32,
    buf: [8192]u8 align(8) = undefined,
    pos: usize = 0,
    end: usize = 0,

    pub fn open(path: [*:0]const u8) Error!Dir {
        const fd = try sysOpenDir(path);
        return .{ .fd = fd };
    }

    pub fn close(self: *Dir) void {
        _ = linux.close(self.fd);
    }

    pub const Entry = struct { name: [:0]const u8, kind: u8 };

    pub fn next(self: *Dir) Error!?Entry {
        while (true) {
            if (self.pos >= self.end) {
                const rc = linux.getdents64(self.fd, &self.buf, self.buf.len);
                const e = linux.errno(rc);
                if (e != .SUCCESS) return fromErrno(e);
                if (rc == 0) return null;
                self.pos = 0;
                self.end = rc;
            }
            const base = self.pos;
            const reclen = std.mem.readInt(u16, self.buf[base + 16 ..][0..2], .little);
            const kind = self.buf[base + 18];
            self.pos += reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(&self.buf[base + 19]);
            const name = std.mem.span(name_ptr);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .kind = kind };
        }
    }
};

fn sysOpenDir(path: [*:0]const u8) Error!i32 {
    return open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
}

pub fn exists(path: [*:0]const u8) bool {
    return linux.errno(linux.faccessat(linux.AT.FDCWD, path, linux.F_OK, 0)) == .SUCCESS;
}

pub fn copyName(dst: []u8, src: []const u8) void {
    const n = @min(dst.len - 1, src.len);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

pub fn dupZ(alloc: std.mem.Allocator, s: []const u8) ![*:0]u8 {
    const out = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(out[0..s.len], s);
    return out.ptr;
}

pub const gpa = std.heap.c_allocator;

pub fn List(comptime T: type) type {
    return struct {
        items: std.ArrayList(T) = .empty,

        const Self = @This();

        pub fn create() !*Self {
            const self = try gpa.create(Self);
            self.* = .{};
            return self;
        }

        pub fn destroy(self: *Self) void {
            if (@hasDecl(T, "deinit")) for (self.items.items) |*item| item.deinit();
            self.items.deinit(gpa);
            gpa.destroy(self);
        }

        pub fn append(self: *Self, item: T) !void {
            try self.items.append(gpa, item);
        }

        pub fn at(self: *const Self, i: usize) ?*const T {
            if (i >= self.items.items.len) return null;
            return &self.items.items[i];
        }

        pub fn count(self: *const Self) usize {
            return self.items.items.len;
        }
    };
}

pub fn mkdirs(path: []const u8) Error!void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.TooBig;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        const rc = linux.mkdirat(linux.AT.FDCWD, @ptrCast(&buf), 0o755);
        const e = linux.errno(rc);
        if (e != .SUCCESS and e != .EXIST) return fromErrno(e);
    }
}

pub fn createFile(path: [*:0]const u8, data: []const u8) Error!void {
    const fd = try open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    defer close(fd);
    try writeAll(fd, data);
}

pub fn put(root: []const u8, rel: []const u8, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, rel }) catch return error.TooBig;
    if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| try mkdirs(full[0..slash]);
    var zbuf: [4096]u8 = undefined;
    try createFile(try pathZ(&zbuf, "{s}", .{full}), data);
}

pub fn symlink(target: [*:0]const u8, path: [*:0]const u8) Error!void {
    _ = try check(linux.symlinkat(target, linux.AT.FDCWD, path));
}

pub fn readLink(path: [*:0]const u8, buf: []u8) Error![]u8 {
    const rc = try check(linux.readlinkat(linux.AT.FDCWD, path, buf.ptr, buf.len));
    return buf[0..rc];
}

pub fn testRoot(buf: []u8, name: []const u8) ![]const u8 {
    const env = std.c.getenv("TMPDIR");
    const base: []const u8 = if (env) |p| std.mem.span(p) else "/tmp";
    const pid = linux.getpid();
    const root = std.fmt.bufPrint(buf, "{s}/sinty-system-test-{d}-{s}", .{ base, pid, name }) catch return error.TooBig;
    try mkdirs(root);
    return root;
}

pub fn sleepMs(ms: u64) void {
    var ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    while (linux.errno(linux.nanosleep(&ts, &ts)) == .INTR) {}
}

pub fn baseName(s: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, s, '/') orelse return s;
    return s[i + 1 ..];
}

pub fn cstr(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}
