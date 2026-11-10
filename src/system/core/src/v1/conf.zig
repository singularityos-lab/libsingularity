const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const i18n = @import("i18n.zig");

const Line = struct {
    raw: []u8,
    group: bool = false,
    key: []const u8 = "",
    value: []const u8 = "",

    fn name(l: *const Line) []const u8 {
        return l.raw[1 .. l.raw.len - 1];
    }
};

fn validGroup(g: []const u8) bool {
    if (g.len == 0) return false;
    for (g) |c| if (c == '[' or c == ']' or c < 0x20 or c == 0x7f) return false;
    return true;
}

fn validKey(k: []const u8) bool {
    if (k.len == 0 or k[0] == ' ' or k[k.len - 1] == ' ') return false;
    const open = std.mem.indexOfScalar(u8, k, '[');
    for (k, 0..) |c, i| {
        if (c == '=' or c == '\n' or c == '\r' or c == 0) return false;
        if (c == '[' and i != open.?) return false;
        if (c == ']' and (open == null or i != k.len - 1)) return false;
    }
    if (open) |o| if (k[k.len - 1] != ']' or o == 0) return false;
    return true;
}

pub const KeyFile = struct {
    lines: std.ArrayList(Line) = .empty,

    pub fn parse(text: []const u8) !KeyFile {
        var kf = KeyFile{};
        errdefer kf.deinit();
        var it = std.mem.splitScalar(u8, text, '\n');
        var in_group = false;
        while (it.next()) |raw_line| {
            if (it.index == null and raw_line.len == 0) break;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const t = std.mem.trimStart(u8, line, " \t");
            if (t.len == 0 or t[0] == '#') {
                try kf.push(.{ .raw = try sys.gpa.dupe(u8, line) });
                continue;
            }
            if (t[0] == '[') {
                const g = std.mem.trimEnd(u8, t, " \t");
                if (g[g.len - 1] != ']' or !validGroup(g[1 .. g.len - 1])) return error.Invalid;
                try kf.push(.{ .raw = try sys.gpa.dupe(u8, g), .group = true });
                in_group = true;
                continue;
            }
            if (!in_group) return error.Invalid;
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse return error.Invalid;
            const key = std.mem.trimEnd(u8, t[0..eq], " \t");
            if (!validKey(key)) return error.Invalid;
            const copy = try sys.gpa.dupe(u8, t);
            errdefer sys.gpa.free(copy);
            const vstart = std.mem.indexOfNonePos(u8, copy, eq + 1, " \t") orelse copy.len;
            try kf.push(.{ .raw = copy, .key = copy[0..key.len], .value = copy[vstart..] });
        }
        return kf;
    }

    fn push(kf: *KeyFile, l: Line) !void {
        errdefer sys.gpa.free(l.raw);
        try kf.lines.append(sys.gpa, l);
    }

    pub fn deinit(kf: *KeyFile) void {
        for (kf.lines.items) |l| sys.gpa.free(l.raw);
        kf.lines.deinit(sys.gpa);
    }

    fn find(kf: *const KeyFile, group: []const u8, key: []const u8) ?usize {
        var cur = false;
        var hit: ?usize = null;
        for (kf.lines.items, 0..) |*l, i| {
            if (l.group) {
                cur = std.mem.eql(u8, l.name(), group);
                continue;
            }
            if (cur and l.key.len > 0 and std.mem.eql(u8, l.key, key)) hit = i;
        }
        return hit;
    }

    pub fn raw(kf: *const KeyFile, group: []const u8, key: []const u8) ?[]const u8 {
        const i = kf.find(group, key) orelse return null;
        return kf.lines.items[i].value;
    }

    pub fn hasGroup(kf: *const KeyFile, group: []const u8) bool {
        for (kf.lines.items) |*l| if (l.group and std.mem.eql(u8, l.name(), group)) return true;
        return false;
    }

    pub fn string(kf: *const KeyFile, group: []const u8, key: []const u8) ![]u8 {
        const v = kf.raw(group, key) orelse return error.NotFound;
        return unescape(v, false);
    }

    pub fn localeString(kf: *const KeyFile, group: []const u8, key: []const u8, locale: []const u8) ![]u8 {
        var candidates: [4][]const u8 = undefined;
        var n: usize = 0;
        const dot = std.mem.indexOfScalar(u8, locale, '.');
        const at = std.mem.indexOfScalar(u8, locale, '@');
        const base_end = @min(dot orelse locale.len, at orelse locale.len);
        const lang_end = std.mem.indexOfScalar(u8, locale[0..base_end], '_') orelse base_end;
        const modifier = if (at) |a| locale[a..] else "";
        var bufs: [4][160]u8 = undefined;
        if (locale.len > 0) {
            if (modifier.len > 0) {
                candidates[n] = std.fmt.bufPrint(&bufs[n], "{s}[{s}{s}]", .{ key, locale[0..base_end], modifier }) catch "";
                n += 1;
            }
            candidates[n] = std.fmt.bufPrint(&bufs[n], "{s}[{s}]", .{ key, locale[0..base_end] }) catch "";
            n += 1;
            if (modifier.len > 0) {
                candidates[n] = std.fmt.bufPrint(&bufs[n], "{s}[{s}{s}]", .{ key, locale[0..lang_end], modifier }) catch "";
                n += 1;
            }
            if (lang_end != base_end) {
                candidates[n] = std.fmt.bufPrint(&bufs[n], "{s}[{s}]", .{ key, locale[0..lang_end] }) catch "";
                n += 1;
            }
        }
        for (candidates[0..n]) |c| if (kf.raw(group, c)) |v| return unescape(v, false);
        return kf.string(group, key);
    }

    pub fn boolean(kf: *const KeyFile, group: []const u8, key: []const u8) !bool {
        const v = std.mem.trimEnd(u8, kf.raw(group, key) orelse return error.NotFound, " \t");
        if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
        if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
        return error.Invalid;
    }

    pub fn integer(kf: *const KeyFile, group: []const u8, key: []const u8) !i64 {
        const v = std.mem.trimEnd(u8, kf.raw(group, key) orelse return error.NotFound, " \t");
        return std.fmt.parseInt(i64, v, 10) catch error.Invalid;
    }

    pub fn list(kf: *const KeyFile, group: []const u8, key: []const u8) !*i18n.TextList {
        const v = kf.raw(group, key) orelse return error.NotFound;
        const out = try i18n.TextList.create();
        errdefer out.destroy();
        var start: usize = 0;
        var i: usize = 0;
        while (i <= v.len) : (i += 1) {
            if (i < v.len and v[i] == '\\') {
                i += 1;
                continue;
            }
            if (i == v.len or v[i] == ';') {
                if (i == v.len and start == v.len) break;
                const item = try unescape(v[start..i], true);
                defer sys.gpa.free(item);
                const z = try sys.dupZ(sys.gpa, item);
                errdefer sys.gpa.free(std.mem.span(z));
                try out.append(.{ .ptr = z });
                start = i + 1;
            }
        }
        return out;
    }

    pub fn setRaw(kf: *KeyFile, group: []const u8, key: []const u8, value: []const u8) !void {
        if (!validGroup(group) or !validKey(key)) return error.Invalid;
        if (std.mem.indexOfAny(u8, value, "\n\r") != null) return error.Invalid;
        const text = try std.fmt.allocPrint(sys.gpa, "{s}={s}", .{ key, value });
        errdefer sys.gpa.free(text);
        const line = Line{ .raw = text, .key = text[0..key.len], .value = text[key.len + 1 ..] };
        if (kf.find(group, key)) |i| {
            sys.gpa.free(kf.lines.items[i].raw);
            kf.lines.items[i] = line;
            return;
        }
        var cur = false;
        var insert: ?usize = null;
        for (kf.lines.items, 0..) |*l, i| {
            if (l.group) {
                cur = std.mem.eql(u8, l.name(), group);
                if (cur) insert = i + 1;
                continue;
            }
            if (cur and l.key.len > 0) insert = i + 1;
        }
        if (insert) |at| return kf.lines.insert(sys.gpa, at, line);
        if (kf.lines.items.len > 0 and kf.lines.items[kf.lines.items.len - 1].raw.len > 0) try kf.push(.{ .raw = try sys.gpa.dupe(u8, "") });
        try kf.push(.{ .raw = try std.fmt.allocPrint(sys.gpa, "[{s}]", .{group}), .group = true });
        try kf.lines.append(sys.gpa, line);
    }

    pub fn setString(kf: *KeyFile, group: []const u8, key: []const u8, value: []const u8) !void {
        const v = try escape(value, false);
        defer sys.gpa.free(v);
        try kf.setRaw(group, key, v);
    }

    pub fn setList(kf: *KeyFile, group: []const u8, key: []const u8, items: []const []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(sys.gpa);
        for (items) |it| {
            const e = try escape(it, true);
            defer sys.gpa.free(e);
            try out.appendSlice(sys.gpa, e);
            try out.append(sys.gpa, ';');
        }
        try kf.setRaw(group, key, out.items);
    }

    pub fn remove(kf: *KeyFile, group: []const u8, key: []const u8) !void {
        const i = kf.find(group, key) orelse return error.NotFound;
        sys.gpa.free(kf.lines.items[i].raw);
        _ = kf.lines.orderedRemove(i);
    }

    pub fn groups(kf: *const KeyFile) !*i18n.TextList {
        const out = try i18n.TextList.create();
        errdefer out.destroy();
        for (kf.lines.items) |*l| {
            if (!l.group) continue;
            const dup = for (out.items.items) |t| {
                if (std.mem.eql(u8, std.mem.span(t.ptr), l.name())) break true;
            } else false;
            if (dup) continue;
            const z = try sys.dupZ(sys.gpa, l.name());
            errdefer sys.gpa.free(std.mem.span(z));
            try out.append(.{ .ptr = z });
        }
        return out;
    }

    pub fn keys(kf: *const KeyFile, group: []const u8) !*i18n.TextList {
        if (!kf.hasGroup(group)) return error.NotFound;
        const out = try i18n.TextList.create();
        errdefer out.destroy();
        var cur = false;
        for (kf.lines.items) |*l| {
            if (l.group) {
                cur = std.mem.eql(u8, l.name(), group);
                continue;
            }
            if (!cur or l.key.len == 0) continue;
            const dup = for (out.items.items) |t| {
                if (std.mem.eql(u8, std.mem.span(t.ptr), l.key)) break true;
            } else false;
            if (dup) continue;
            const z = try sys.dupZ(sys.gpa, l.key);
            errdefer sys.gpa.free(std.mem.span(z));
            try out.append(.{ .ptr = z });
        }
        return out;
    }

    pub fn serialize(kf: *const KeyFile) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(sys.gpa);
        for (kf.lines.items) |l| {
            try out.appendSlice(sys.gpa, l.raw);
            try out.append(sys.gpa, '\n');
        }
        return out.toOwnedSlice(sys.gpa);
    }

    pub fn save(kf: *const KeyFile, path: []const u8) !void {
        const data = try kf.serialize();
        defer sys.gpa.free(data);
        try atomicWrite(path, data, 0o644);
    }
};

pub fn unescape(v: []const u8, in_list: bool) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(sys.gpa, v.len);
    errdefer out.deinit(sys.gpa);
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (v[i] != '\\') {
            try out.append(sys.gpa, v[i]);
            continue;
        }
        i += 1;
        if (i >= v.len) return error.Invalid;
        try out.append(sys.gpa, switch (v[i]) {
            's' => ' ',
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '\\' => '\\',
            ';' => if (in_list) ';' else blk: {
                try out.append(sys.gpa, '\\');
                break :blk ';';
            },
            else => return error.Invalid,
        });
    }
    return out.toOwnedSlice(sys.gpa);
}

pub fn escape(v: []const u8, in_list: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(sys.gpa);
    for (v, 0..) |c, i| {
        switch (c) {
            ' ' => if (i == 0) try out.appendSlice(sys.gpa, "\\s") else try out.append(sys.gpa, ' '),
            '\n' => try out.appendSlice(sys.gpa, "\\n"),
            '\t' => try out.appendSlice(sys.gpa, "\\t"),
            '\r' => try out.appendSlice(sys.gpa, "\\r"),
            '\\' => try out.appendSlice(sys.gpa, "\\\\"),
            ';' => if (in_list) try out.appendSlice(sys.gpa, "\\;") else try out.append(sys.gpa, ';'),
            0 => return error.Invalid,
            else => try out.append(sys.gpa, c),
        }
    }
    return out.toOwnedSlice(sys.gpa);
}

pub fn atomicWrite(path: []const u8, data: []const u8, mode: linux.mode_t) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const dir = if (slash) |s| (if (s == 0) "/" else path[0..s]) else ".";
    var tb: [600]u8 = undefined;
    var nonce: [4]u8 = undefined;
    _ = linux.getrandom(&nonce, nonce.len, 0);
    const tmp = try sys.pathZ(&tb, "{s}.{x}.tmp", .{ path, std.mem.readInt(u32, &nonce, .little) });
    const fd = try sys.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, mode);
    var ok = false;
    defer if (!ok) {
        _ = linux.unlink(tmp);
    };
    {
        defer sys.close(fd);
        try sys.writeAll(fd, data);
        _ = try sys.check(linux.fsync(fd));
    }
    var pb: [600]u8 = undefined;
    _ = try sys.check(linux.rename(tmp, try sys.pathZ(&pb, "{s}", .{path})));
    ok = true;
    var db: [600]u8 = undefined;
    const dfd = sys.open(try sys.pathZ(&db, "{s}", .{dir}), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) catch return;
    defer sys.close(dfd);
    _ = linux.fsync(dfd);
}

pub fn find(name: []const u8, out: []u8) ![]const u8 {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOf(u8, name, "..") != null) return error.Invalid;
    const dirs = if (std.c.getenv("XDG_CONFIG_DIRS")) |d| std.mem.span(d) else "/etc/xdg";
    var it = std.mem.splitScalar(u8, dirs, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue;
        var b: [600]u8 = undefined;
        const p = sys.pathZ(&b, "{s}/{s}", .{ d, name }) catch continue;
        if (sys.exists(p)) return std.fmt.bufPrint(out, "{s}", .{std.mem.span(p)}) catch error.TooBig;
    }
    var b: [600]u8 = undefined;
    const p = try sys.pathZ(&b, "/etc/{s}", .{name});
    if (sys.exists(p)) return std.fmt.bufPrint(out, "{s}", .{std.mem.span(p)}) catch error.TooBig;
    return error.NotFound;
}

pub fn load(path: [*:0]const u8) !KeyFile {
    const data = try sys.readAlloc(sys.gpa, path, 16 << 20);
    defer sys.gpa.free(data);
    return KeyFile.parse(data);
}

test "key files follow the desktop entry rules" {
    const text =
        \\# Integrazione
        \\[Hostname]
        \\Backend = command
        \\Command=sinty-host-helper  set
        \\
        \\[Desktop Entry]
        \\Name=Files
        \\Name[it]=File
        \\Name[pt_BR]=Arquivos
        \\Name[sr@latin]=Datoteke
        \\Comment=\sLeading\tand\\back
        \\Keywords=folder;disk\;usb;
        \\NoDisplay=true
        \\Count=-17
        \\Name=Files Again
        \\
    ;
    var kf = try KeyFile.parse(text);
    defer kf.deinit();
    const backend = try kf.string("Hostname", "Backend");
    defer sys.gpa.free(backend);
    try std.testing.expectEqualStrings("command", backend);
    const cmd = try kf.string("Hostname", "Command");
    defer sys.gpa.free(cmd);
    try std.testing.expectEqualStrings("sinty-host-helper  set", cmd);
    const name = try kf.string("Desktop Entry", "Name");
    defer sys.gpa.free(name);
    try std.testing.expectEqualStrings("Files Again", name);
    for ([_][2][]const u8{ .{ "it_IT.UTF-8", "File" }, .{ "pt_BR", "Arquivos" }, .{ "pt_PT", "Files Again" }, .{ "sr_RS@latin", "Datoteke" }, .{ "", "Files Again" } }) |c| {
        const v = try kf.localeString("Desktop Entry", "Name", c[0]);
        defer sys.gpa.free(v);
        try std.testing.expectEqualStrings(c[1], v);
    }
    const comment = try kf.string("Desktop Entry", "Comment");
    defer sys.gpa.free(comment);
    try std.testing.expectEqualStrings(" Leading\tand\\back", comment);
    const kw = try kf.list("Desktop Entry", "Keywords");
    defer kw.destroy();
    try std.testing.expectEqual(@as(usize, 2), kw.count());
    try std.testing.expectEqualStrings("disk;usb", std.mem.span(kw.at(1).?.ptr));
    try std.testing.expect(try kf.boolean("Desktop Entry", "NoDisplay"));
    try std.testing.expectEqual(@as(i64, -17), try kf.integer("Desktop Entry", "Count"));
    try std.testing.expectError(error.Invalid, kf.boolean("Hostname", "Backend"));
    try std.testing.expectError(error.NotFound, kf.string("Hostname", "Missing"));

    try kf.setString("Hostname", "Pretty", " Il mio PC\n");
    try kf.setList("Extra", "Apps", &.{ "a;b", "c" });
    try kf.remove("Desktop Entry", "Count");
    try std.testing.expectError(error.Invalid, kf.setString("Bad]", "k", "v"));
    try std.testing.expectError(error.Invalid, kf.setString("Hostname", "a=b", "v"));
    const out = try kf.serialize();
    defer sys.gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Command=sinty-host-helper  set\nPretty=\\sIl mio PC\\n\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\n[Extra]\nApps=a\\;b;c;\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Count=") == null);
    try std.testing.expect(std.mem.startsWith(u8, out, "# Integrazione\n"));

    var again = try KeyFile.parse(out);
    defer again.deinit();
    const pretty = try again.string("Hostname", "Pretty");
    defer sys.gpa.free(pretty);
    try std.testing.expectEqualStrings(" Il mio PC\n", pretty);
    const apps = try again.list("Extra", "Apps");
    defer apps.destroy();
    try std.testing.expectEqualStrings("a;b", std.mem.span(apps.at(0).?.ptr));
    const gs = try again.groups();
    defer gs.destroy();
    try std.testing.expectEqual(@as(usize, 3), gs.count());
    const ks = try again.keys("Desktop Entry");
    defer ks.destroy();
    try std.testing.expectEqual(@as(usize, 7), ks.count());

    try std.testing.expectError(error.Invalid, KeyFile.parse("Key=before group\n"));
    try std.testing.expectError(error.Invalid, KeyFile.parse("[Ok]\nno equals\n"));
    try std.testing.expectError(error.Invalid, KeyFile.parse("[Ok\n"));

    const tmp = std.mem.span(std.c.getenv("TMPDIR") orelse return);
    var pb: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/conf-test.conf", .{tmp});
    try again.save(path);
    try again.setString("Hostname", "Backend", "auto");
    try again.save(path);
    var zb: [512]u8 = undefined;
    var loaded = try load(try sys.pathZ(&zb, "{s}", .{path}));
    defer loaded.deinit();
    const b2 = try loaded.string("Hostname", "Backend");
    defer sys.gpa.free(b2);
    try std.testing.expectEqualStrings("auto", b2);
}

test "installed desktop entries parse" {
    var d = sys.Dir.open("/usr/share/applications") catch return error.SkipZigTest;
    defer d.close();
    var parsed: usize = 0;
    var failed: usize = 0;
    while (try d.next()) |e| {
        if (!std.mem.endsWith(u8, e.name, ".desktop")) continue;
        var b: [512]u8 = undefined;
        var kf = load(try sys.pathZ(&b, "/usr/share/applications/{s}", .{e.name})) catch |err| {
            std.debug.print("rejected {s}: {}\n", .{ e.name, err });
            failed += 1;
            continue;
        };
        defer kf.deinit();
        const n = try kf.localeString("Desktop Entry", "Name", "it_IT.UTF-8");
        sys.gpa.free(n);
        parsed += 1;
    }
    try std.testing.expect(parsed > 0);
    try std.testing.expectEqual(@as(usize, 0), failed);
}
