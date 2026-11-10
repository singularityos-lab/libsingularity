const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

const tag_operation = 0x01;
const tag_job = 0x02;
const tag_end = 0x03;
const tag_printer = 0x04;
const tag_integer = 0x21;
const tag_boolean = 0x22;
const tag_enum = 0x23;
const tag_begin_collection = 0x34;
const tag_end_collection = 0x37;
const tag_name = 0x42;
const tag_keyword = 0x44;
const tag_uri = 0x45;
const tag_charset = 0x47;
const tag_language = 0x48;
const tag_mime = 0x49;

const op_print_job = 0x0002;
const op_cancel_job = 0x0008;
const op_get_jobs = 0x000A;
const op_get_printer_attributes = 0x000B;
const op_cups_get_default = 0x4001;
const op_cups_get_printers = 0x4002;

const max_response = 16 << 20;

pub const Printer = extern struct {
    name: [128]u8,
    uri: [256]u8,
    info: [256]u8,
    location: [256]u8,
    make_model: [256]u8,
    state: u32,
    queued: u32,
    accepting: bool,
    is_default: bool,
    pad: [6]u8,
};

pub const Job = extern struct {
    id: u32,
    state: u32,
    name: [256]u8,
    printer_uri: [256]u8,
    user: [64]u8,
    created: i64,
    kbytes: u32,
    pad: u32,
};

pub const Printers = sys.List(Printer);
pub const Jobs = sys.List(Job);

pub const Request = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn init(op: u16, id: u32) !Request {
        var r = Request{};
        errdefer r.deinit();
        var head: [8]u8 = undefined;
        head[0] = 2;
        head[1] = 0;
        std.mem.writeInt(u16, head[2..4], op, .big);
        std.mem.writeInt(u32, head[4..8], id, .big);
        try r.buf.appendSlice(sys.gpa, &head);
        try r.group(tag_operation);
        try r.text(tag_charset, "attributes-charset", "utf-8");
        try r.text(tag_language, "attributes-natural-language", "en");
        return r;
    }

    pub fn deinit(r: *Request) void {
        r.buf.deinit(sys.gpa);
    }

    pub fn group(r: *Request, tag: u8) !void {
        try r.buf.append(sys.gpa, tag);
    }

    fn attr(r: *Request, tag: u8, name: []const u8, value: []const u8) !void {
        if (name.len > 0xffff or value.len > 0xffff) return error.TooBig;
        var n: [2]u8 = undefined;
        try r.buf.append(sys.gpa, tag);
        std.mem.writeInt(u16, &n, @intCast(name.len), .big);
        try r.buf.appendSlice(sys.gpa, &n);
        try r.buf.appendSlice(sys.gpa, name);
        std.mem.writeInt(u16, &n, @intCast(value.len), .big);
        try r.buf.appendSlice(sys.gpa, &n);
        try r.buf.appendSlice(sys.gpa, value);
    }

    pub fn text(r: *Request, tag: u8, name: []const u8, value: []const u8) !void {
        try r.attr(tag, name, value);
    }

    pub fn int(r: *Request, tag: u8, name: []const u8, value: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, value, .big);
        try r.attr(tag, name, &b);
    }

    pub fn keywords(r: *Request, name: []const u8, values: []const []const u8) !void {
        for (values, 0..) |v, i| try r.attr(tag_keyword, if (i == 0) name else "", v);
    }

    pub fn finish(r: *Request) ![]const u8 {
        try r.buf.append(sys.gpa, tag_end);
        return r.buf.items;
    }
};

pub const Attr = struct {
    group: u8,
    index: usize,
    tag: u8,
    name: []const u8,
    value: []const u8,

    pub fn int(a: Attr) ?i32 {
        if (a.value.len != 4) return null;
        return std.mem.readInt(i32, a.value[0..4], .big);
    }
};

pub const Response = struct {
    data: []u8,
    status: u16,
    id: u32,

    pub fn deinit(r: *Response) void {
        sys.gpa.free(r.data);
    }

    pub fn iterator(r: *const Response) Iterator {
        return .{ .data = r.data, .pos = 8 };
    }
};

pub const Iterator = struct {
    data: []const u8,
    pos: usize,
    group: u8 = 0,
    index: usize = 0,
    name: []const u8 = "",
    depth: usize = 0,

    pub fn next(it: *Iterator) !?Attr {
        while (it.pos < it.data.len) {
            const tag = it.data[it.pos];
            if (tag == tag_end) return null;
            if (tag < 0x10) {
                it.group = tag;
                it.index += 1;
                it.pos += 1;
                continue;
            }
            if (it.pos + 3 > it.data.len) return error.Invalid;
            const nl = std.mem.readInt(u16, it.data[it.pos + 1 ..][0..2], .big);
            const ns = it.pos + 3;
            if (ns + nl + 2 > it.data.len) return error.Invalid;
            const vl = std.mem.readInt(u16, it.data[ns + nl ..][0..2], .big);
            const vs = ns + nl + 2;
            if (vs + vl > it.data.len) return error.Invalid;
            it.pos = vs + vl;
            if (nl > 0 and it.depth == 0) it.name = it.data[ns .. ns + nl];
            if (tag == tag_begin_collection) {
                it.depth += 1;
                continue;
            }
            if (tag == tag_end_collection) {
                if (it.depth == 0) return error.Invalid;
                it.depth -= 1;
                continue;
            }
            if (it.depth > 0) continue;
            return .{ .group = it.group, .index = it.index, .tag = tag, .name = it.name, .value = it.data[vs .. vs + vl] };
        }
        return error.Invalid;
    }
};

pub fn parseResponse(data: []u8) !Response {
    if (data.len < 9 or data[0] < 1) return error.Invalid;
    var it = Iterator{ .data = data, .pos = 8 };
    while (try it.next()) |_| {}
    return .{ .data = data, .status = std.mem.readInt(u16, data[2..4], .big), .id = std.mem.readInt(u32, data[4..8], .big) };
}

pub const Server = struct {
    unix: [108]u8 = [_]u8{0} ** 108,
    host: [64]u8 = [_]u8{0} ** 64,
    port: u16 = 0,

    pub fn default() Server {
        var s = Server{};
        if (std.c.getenv("CUPS_SERVER")) |p| {
            const v = std.mem.span(p);
            if (v.len > 0 and v[0] == '/') {
                sys.copyName(&s.unix, v);
                return s;
            }
        }
        sys.copyName(&s.unix, "/run/cups/cups.sock");
        return s;
    }

    pub fn parse(addr: []const u8) !Server {
        var s = Server{};
        if (addr.len > 0 and addr[0] == '/') {
            if (addr.len >= s.unix.len) return error.TooBig;
            sys.copyName(&s.unix, addr);
            return s;
        }
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.Invalid;
        const host = addr[0..colon];
        if (!std.mem.eql(u8, host, "localhost") and !std.mem.eql(u8, host, "127.0.0.1")) return error.Unsupported;
        sys.copyName(&s.host, host);
        s.port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch return error.Invalid;
        return s;
    }

    fn connect(s: *const Server) !i32 {
        if (s.port == 0) {
            const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
            errdefer sys.close(fd);
            var addr = linux.sockaddr.un{ .path = [_]u8{0} ** 108 };
            @memcpy(addr.path[0..s.unix.len], &s.unix);
            _ = try sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
            return fd;
        }
        const fd: i32 = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
        errdefer sys.close(fd);
        var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, s.port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        _ = try sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
        return fd;
    }

    pub fn uri(s: *const Server, buf: []u8, resource: []const u8) ![]const u8 {
        if (s.port == 0) return std.fmt.bufPrint(buf, "ipp://localhost{s}", .{resource}) catch error.TooBig;
        return std.fmt.bufPrint(buf, "ipp://localhost:{d}{s}", .{ s.port, resource }) catch error.TooBig;
    }

    pub fn send(s: *const Server, resource: []const u8, ipp: []const u8, document: []const u8) !Response {
        const fd = try s.connect();
        defer sys.close(fd);
        const tv = linux.timeval{ .sec = 30, .usec = 0 };
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        var head: [512]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/ipp\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ resource, ipp.len + document.len }) catch return error.TooBig;
        try sys.writeAll(fd, h);
        try sys.writeAll(fd, ipp);
        if (document.len > 0) try sys.writeAll(fd, document);
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(sys.gpa);
        var tmp: [16384]u8 = undefined;
        while (true) {
            const n = try sys.read(fd, &tmp);
            if (n == 0) break;
            try raw.appendSlice(sys.gpa, tmp[0..n]);
            if (raw.items.len > max_response) return error.TooBig;
            if (complete(raw.items)) break;
        }
        const body = try httpBody(raw.items);
        return parseResponse(body);
    }
};

pub const Queue = struct {
    resource_buf: [160]u8 = undefined,
    uri_buf: [256]u8 = undefined,
    resource: []const u8 = "",
    uri: []const u8 = "",

    pub fn init(q: *Queue, s: *const Server, name: []const u8) !void {
        if (name.len == 0 or name.len > 127) return error.Invalid;
        for (name) |ch| if (ch <= ' ' or ch == '/' or ch == '#' or ch == '?' or ch == '%' or ch == 0x7f) return error.Invalid;
        q.resource = std.fmt.bufPrint(&q.resource_buf, "/printers/{s}", .{name}) catch return error.TooBig;
        q.uri = try s.uri(&q.uri_buf, q.resource);
    }
};

fn headerEnd(raw: []const u8) ?usize {
    const i = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    return i + 4;
}

fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn complete(raw: []const u8) bool {
    const end = headerEnd(raw) orelse return false;
    const head = raw[0..end];
    if (std.mem.startsWith(u8, raw, "HTTP/1.1 100") or std.mem.startsWith(u8, raw, "HTTP/1.0 100")) return complete(raw[end..]);
    if (header(head, "Content-Length")) |cl| {
        const n = std.fmt.parseInt(usize, cl, 10) catch return false;
        return raw.len - end >= n;
    }
    if (header(head, "Transfer-Encoding")) |te| {
        if (std.ascii.eqlIgnoreCase(te, "chunked")) return std.mem.endsWith(u8, raw, "0\r\n\r\n");
    }
    return false;
}

pub fn httpBody(raw_in: []const u8) ![]u8 {
    var raw = raw_in;
    while (true) {
        const end = headerEnd(raw) orelse return error.Invalid;
        if (!std.mem.startsWith(u8, raw, "HTTP/1.")) return error.Invalid;
        if (raw.len < 12) return error.Invalid;
        const code = std.fmt.parseInt(u16, raw[9..12], 10) catch return error.Invalid;
        if (code == 100) {
            raw = raw[end..];
            continue;
        }
        if (code == 401 or code == 403) return error.Access;
        if (code == 404) return error.NotFound;
        if (code != 200) return error.Io;
        const head = raw[0..end];
        const rest = raw[end..];
        if (header(head, "Transfer-Encoding")) |te| {
            if (std.ascii.eqlIgnoreCase(te, "chunked")) {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(sys.gpa);
                var p: usize = 0;
                while (true) {
                    const nl = std.mem.indexOfPos(u8, rest, p, "\r\n") orelse return error.Invalid;
                    const size_text = rest[p..nl];
                    const semi = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
                    const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_text[0..semi], " "), 16) catch return error.Invalid;
                    p = nl + 2;
                    if (size == 0) break;
                    if (p + size + 2 > rest.len) return error.Invalid;
                    try out.appendSlice(sys.gpa, rest[p .. p + size]);
                    p += size + 2;
                }
                return out.toOwnedSlice(sys.gpa);
            }
        }
        const n = if (header(head, "Content-Length")) |cl| std.fmt.parseInt(usize, cl, 10) catch return error.Invalid else rest.len;
        if (n > rest.len) return error.Invalid;
        return sys.gpa.dupe(u8, rest[0..n]);
    }
}

fn statusError(status: u16) ?anyerror {
    if (status < 0x0100) return null;
    return switch (status) {
        0x0401, 0x0403 => error.Access,
        0x0400, 0x040B, 0x040C, 0x040D => error.Invalid,
        0x0406, 0x0407 => error.NotFound,
        0x0501 => error.Unsupported,
        0x0506, 0x0507 => error.Busy,
        else => error.Io,
    };
}

const printer_attrs = [_][]const u8{ "printer-name", "printer-uri-supported", "printer-info", "printer-location", "printer-make-and-model", "printer-state", "queued-job-count", "printer-is-accepting-jobs" };

fn fillPrinter(p: *Printer, a: Attr) void {
    if (std.mem.eql(u8, a.name, "printer-name")) sys.copyName(&p.name, a.value);
    if (std.mem.eql(u8, a.name, "printer-uri-supported") and p.uri[0] == 0) sys.copyName(&p.uri, a.value);
    if (std.mem.eql(u8, a.name, "printer-info")) sys.copyName(&p.info, a.value);
    if (std.mem.eql(u8, a.name, "printer-location")) sys.copyName(&p.location, a.value);
    if (std.mem.eql(u8, a.name, "printer-make-and-model")) sys.copyName(&p.make_model, a.value);
    if (std.mem.eql(u8, a.name, "printer-state")) p.state = @intCast(@max(a.int() orelse 0, 0));
    if (std.mem.eql(u8, a.name, "queued-job-count")) p.queued = @intCast(@max(a.int() orelse 0, 0));
    if (std.mem.eql(u8, a.name, "printer-is-accepting-jobs") and a.value.len == 1) p.accepting = a.value[0] == 1;
}

fn collectPrinters(resp: *const Response, list: *Printers) !void {
    var it = resp.iterator();
    var cur: ?Printer = null;
    var index: usize = 0;
    while (try it.next()) |a| {
        if (a.group != tag_printer) continue;
        if (cur == null or a.index != index) {
            if (cur) |p| try list.append(p);
            cur = std.mem.zeroes(Printer);
            index = a.index;
        }
        fillPrinter(&cur.?, a);
    }
    if (cur) |p| try list.append(p);
}

pub fn printers(s: *const Server) !*Printers {
    var req = try Request.init(op_cups_get_printers, 1);
    defer req.deinit();
    try req.keywords("requested-attributes", &printer_attrs);
    var resp = try s.send("/", try req.finish(), "");
    defer resp.deinit();
    if (statusError(resp.status)) |e| return e;
    const list = try Printers.create();
    errdefer list.destroy();
    try collectPrinters(&resp, list);
    var def: [128]u8 = undefined;
    if (defaultPrinter(s, &def)) |name| {
        for (list.items.items) |*p| p.is_default = std.mem.eql(u8, sys.cstr(&p.name), name);
    } else |_| {}
    return list;
}

pub fn defaultPrinter(s: *const Server, out: []u8) ![]const u8 {
    var req = try Request.init(op_cups_get_default, 1);
    defer req.deinit();
    try req.keywords("requested-attributes", &.{"printer-name"});
    var resp = try s.send("/", try req.finish(), "");
    defer resp.deinit();
    if (statusError(resp.status)) |e| return e;
    var it = resp.iterator();
    while (try it.next()) |a| if (a.group == tag_printer and std.mem.eql(u8, a.name, "printer-name")) {
        sys.copyName(out, a.value);
        return sys.cstr(out);
    };
    return error.NotFound;
}

pub fn printer(s: *const Server, uri: []const u8, resource: []const u8) !Printer {
    var req = try Request.init(op_get_printer_attributes, 1);
    defer req.deinit();
    try req.text(tag_uri, "printer-uri", uri);
    try req.keywords("requested-attributes", &printer_attrs);
    var resp = try s.send(resource, try req.finish(), "");
    defer resp.deinit();
    if (statusError(resp.status)) |e| return e;
    var p = std.mem.zeroes(Printer);
    var it = resp.iterator();
    while (try it.next()) |a| if (a.group == tag_printer) fillPrinter(&p, a);
    if (p.uri[0] == 0) sys.copyName(&p.uri, uri);
    return p;
}

pub fn jobs(s: *const Server, uri: []const u8, resource: []const u8, completed: bool) !*Jobs {
    var req = try Request.init(op_get_jobs, 1);
    defer req.deinit();
    try req.text(tag_uri, "printer-uri", uri);
    try req.text(tag_keyword, "which-jobs", if (completed) "completed" else "not-completed");
    try req.keywords("requested-attributes", &.{ "job-id", "job-name", "job-state", "job-printer-uri", "job-originating-user-name", "time-at-creation", "job-k-octets" });
    var resp = try s.send(resource, try req.finish(), "");
    defer resp.deinit();
    if (statusError(resp.status)) |e| return e;
    const list = try Jobs.create();
    errdefer list.destroy();
    var it = resp.iterator();
    var cur: ?Job = null;
    var index: usize = 0;
    while (try it.next()) |a| {
        if (a.group != tag_job) continue;
        if (cur == null or a.index != index) {
            if (cur) |j| try list.append(j);
            cur = std.mem.zeroes(Job);
            index = a.index;
        }
        const j = &cur.?;
        if (std.mem.eql(u8, a.name, "job-id")) j.id = @intCast(@max(a.int() orelse 0, 0));
        if (std.mem.eql(u8, a.name, "job-name")) sys.copyName(&j.name, a.value);
        if (std.mem.eql(u8, a.name, "job-state")) j.state = @intCast(@max(a.int() orelse 0, 0));
        if (std.mem.eql(u8, a.name, "job-printer-uri")) sys.copyName(&j.printer_uri, a.value);
        if (std.mem.eql(u8, a.name, "job-originating-user-name")) sys.copyName(&j.user, a.value);
        if (std.mem.eql(u8, a.name, "time-at-creation")) j.created = a.int() orelse 0;
        if (std.mem.eql(u8, a.name, "job-k-octets")) j.kbytes = @intCast(@max(a.int() orelse 0, 0));
    }
    if (cur) |j| try list.append(j);
    return list;
}

fn userName(buf: []u8) []const u8 {
    if (std.c.getenv("USER")) |u| {
        sys.copyName(buf, std.mem.span(u));
        return sys.cstr(buf);
    }
    return std.fmt.bufPrint(buf, "{d}", .{linux.getuid()}) catch "user";
}

fn documentFormat(data: []const u8) []const u8 {
    if (std.mem.startsWith(u8, data, "%PDF-")) return "application/pdf";
    if (std.mem.startsWith(u8, data, "%!")) return "application/postscript";
    if (std.mem.startsWith(u8, data, "\x89PNG")) return "image/png";
    if (std.mem.startsWith(u8, data, "\xff\xd8\xff")) return "image/jpeg";
    if (std.unicode.utf8ValidateSlice(data[0..@min(data.len, 4096)]) and std.mem.indexOfScalar(u8, data[0..@min(data.len, 4096)], 0) == null) return "text/plain";
    return "application/octet-stream";
}

pub fn printData(s: *const Server, uri: []const u8, resource: []const u8, title: []const u8, data: []const u8, copies: i32) !u32 {
    if (data.len == 0 or copies < 1 or copies > 999) return error.Invalid;
    var ub: [64]u8 = undefined;
    var req = try Request.init(op_print_job, 1);
    defer req.deinit();
    try req.text(tag_uri, "printer-uri", uri);
    try req.text(tag_name, "requesting-user-name", userName(&ub));
    try req.text(tag_name, "job-name", if (title.len > 0) title else "Document");
    try req.text(tag_mime, "document-format", documentFormat(data));
    if (copies > 1) {
        try req.group(tag_job);
        try req.int(tag_integer, "copies", copies);
    }
    var resp = try s.send(resource, try req.finish(), data);
    defer resp.deinit();
    if (statusError(resp.status)) |e| return e;
    var it = resp.iterator();
    while (try it.next()) |a| if (std.mem.eql(u8, a.name, "job-id")) return @intCast(@max(a.int() orelse 0, 0));
    return error.Invalid;
}

pub fn printFile(s: *const Server, uri: []const u8, resource: []const u8, path: [*:0]const u8, title: []const u8, copies: i32) !u32 {
    const data = try sys.readAlloc(sys.gpa, path, 256 << 20);
    defer sys.gpa.free(data);
    return printData(s, uri, resource, if (title.len > 0) title else sys.baseName(std.mem.span(path)), data, copies);
}

pub fn cancel(s: *const Server, uri: []const u8, resource: []const u8, id: u32) !void {
    var ub: [64]u8 = undefined;
    var req = try Request.init(op_cancel_job, 1);
    defer req.deinit();
    try req.text(tag_uri, "printer-uri", uri);
    try req.int(tag_integer, "job-id", @intCast(id));
    try req.text(tag_name, "requesting-user-name", userName(&ub));
    var resp = try s.send(resource, try req.finish(), "");
    defer resp.deinit();
    if (statusError(resp.status)) |e| return e;
}

test "ipp requests encode and responses decode" {
    var req = try Request.init(op_get_jobs, 7);
    defer req.deinit();
    try req.text(tag_uri, "printer-uri", "ipp://localhost/printers/office");
    try req.keywords("requested-attributes", &.{ "job-id", "job-state" });
    const bytes = try req.finish();
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0x0A, 0, 0, 0, 7, 1, 0x47, 0, 18 }, bytes[0..12]);
    try std.testing.expectEqual(@as(u8, tag_end), bytes[bytes.len - 1]);

    var copy = try sys.gpa.dupe(u8, bytes);
    copy[2] = 0;
    copy[3] = 0;
    var resp = try parseResponse(copy);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 0), resp.status);
    try std.testing.expectEqual(@as(u32, 7), resp.id);
    var it = resp.iterator();
    var names: usize = 0;
    var last: []const u8 = "";
    while (try it.next()) |a| {
        names += 1;
        last = a.name;
    }
    try std.testing.expectEqual(@as(usize, 5), names);
    try std.testing.expectEqualStrings("requested-attributes", last);
    const cut = try sys.gpa.dupe(u8, bytes[0 .. bytes.len - 4]);
    defer sys.gpa.free(cut);
    try std.testing.expectError(error.Invalid, parseResponse(cut));
}

test "queue names become printer resources" {
    const s = try Server.parse("/run/cups/cups.sock");
    var q = Queue{};
    try q.init(&s, "ufficio");
    try std.testing.expectEqualStrings("/printers/ufficio", q.resource);
    try std.testing.expectEqualStrings("ipp://localhost/printers/ufficio", q.uri);
    const t = try Server.parse("localhost:631");
    try q.init(&t, "a");
    try std.testing.expectEqualStrings("ipp://localhost:631/printers/a", q.uri);
    try std.testing.expectError(error.Invalid, q.init(&s, "../x"));
    try std.testing.expectError(error.Invalid, q.init(&s, "a b"));
    try std.testing.expectError(error.Invalid, q.init(&s, ""));
    try std.testing.expectError(error.Unsupported, Server.parse("example.com:631"));
}

test "http bodies with length or chunks" {
    const plain = try httpBody("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabcdef");
    defer sys.gpa.free(plain);
    try std.testing.expectEqualStrings("abc", plain);
    const chunked = try httpBody("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\n\r\n");
    defer sys.gpa.free(chunked);
    try std.testing.expectEqualStrings("abcde", chunked);
    try std.testing.expectError(error.Access, httpBody("HTTP/1.1 401 Unauthorized\r\n\r\n"));
    try std.testing.expect(complete("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nab"));
    try std.testing.expect(!complete("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na"));
}

test "a simulated IPP Everywhere printer takes a job" {
    const addr = std.c.getenv("SINTY_IPP_PRINTER") orelse return error.SkipZigTest;
    const s = try Server.parse(std.mem.span(addr));
    var ub: [128]u8 = undefined;
    const uri = try s.uri(&ub, "/ipp/print");
    const p = try printer(&s, uri, "/ipp/print");
    try std.testing.expectEqualStrings("Sinty Test", sys.cstr(&p.name));
    try std.testing.expect(p.accepting);
    try std.testing.expect(p.state >= 3 and p.state <= 5);
    const id = try printData(&s, uri, "/ipp/print", "prova.txt", "Ciao dalla stampa\n", 2);
    try std.testing.expect(id > 0);
    var found = false;
    for (0..50) |_| {
        const all = try jobs(&s, uri, "/ipp/print", true);
        defer all.destroy();
        const open = try jobs(&s, uri, "/ipp/print", false);
        defer open.destroy();
        for (all.items.items) |j| if (j.id == id) {
            try std.testing.expectEqualStrings("prova.txt", sys.cstr(&j.name));
            found = true;
        };
        for (open.items.items) |j| if (j.id == id) {
            try std.testing.expectEqualStrings("prova.txt", sys.cstr(&j.name));
            found = true;
        };
        if (found) break;
        sys.sleepMs(100);
    }
    try std.testing.expect(found);
    try std.testing.expectError(error.Invalid, printData(&s, uri, "/ipp/print", "x", "", 1));
    try std.testing.expectError(error.NotFound, cancel(&s, uri, "/ipp/print", 99999));
}

test "torchio answers the CUPS dialect" {
    const addr = std.c.getenv("SINTY_TORCHIO_SOCKET") orelse return error.SkipZigTest;
    const want = std.mem.span(std.c.getenv("SINTY_TORCHIO_PRINTER") orelse return error.SkipZigTest);
    const s = try Server.parse(std.mem.span(addr));
    const list = try printers(&s);
    defer list.destroy();
    var hit: ?Printer = null;
    for (list.items.items) |p| {
        if (std.mem.eql(u8, sys.cstr(&p.name), want)) hit = p;
    }
    const p = hit orelse return error.TestUnexpectedResult;
    try std.testing.expect(p.is_default);
    try std.testing.expect(p.uri[0] != 0);
    var def: [128]u8 = undefined;
    try std.testing.expectEqualStrings(want, try defaultPrinter(&s, &def));
    var rb: [160]u8 = undefined;
    const resource = try std.fmt.bufPrint(&rb, "/printers/{s}", .{want});
    var ub: [256]u8 = undefined;
    const uri = try s.uri(&ub, resource);
    const one = try printer(&s, uri, resource);
    try std.testing.expectEqualStrings(want, sys.cstr(&one.name));
    const id = try printData(&s, uri, resource, "torchio.txt", "Prova torchio\n", 1);
    try std.testing.expect(id > 0);
    var found = false;
    for (0..50) |_| {
        for ([_]bool{ false, true }) |done| {
            const js = try jobs(&s, uri, resource, done);
            defer js.destroy();
            for (js.items.items) |j| if (j.id == id) {
                try std.testing.expectEqualStrings("torchio.txt", sys.cstr(&j.name));
                found = true;
            };
        }
        if (found) break;
        sys.sleepMs(100);
    }
    try std.testing.expect(found);
    try std.testing.expectError(error.NotFound, cancel(&s, uri, resource, 99999));
}
