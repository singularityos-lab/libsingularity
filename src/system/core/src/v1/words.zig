const std = @import("std");
const sys = @import("../sys.zig");

const max_word = 48;
const samples = 40;

pub const Key = extern struct {
    codepoint: u32,
    x: f32,
    y: f32,
};

const Entry = struct {
    word: [*:0]const u8,
    len: usize,
    freq: u32,
    folded: []const u8,
    lower: []const u8,
    head: u32,
    tail: u32,
};

pub const Words = struct {
    alloc: std.mem.Allocator,
    buffer: []u8,
    entries: []Entry,
    storage: []Entry,
    by_key: []u32,
    known: std.StringHashMapUnmanaged(u32),
    folded_store: []u8,

    pub fn deinit(self: *Words) void {
        self.known.deinit(self.alloc);
        self.alloc.free(self.by_key);
        self.alloc.free(self.storage);
        self.alloc.free(self.folded_store);
        self.alloc.free(self.buffer);
        self.alloc.destroy(self);
    }

    pub fn word(self: *const Words, id: u32) [*:0]const u8 {
        return self.entries[id].word;
    }

    pub fn contains(self: *const Words, text: []const u8) bool {
        var buf: [max_word * 4]u8 = undefined;
        const lower = lowerInto(&buf, text) orelse return false;
        return self.known.contains(lower);
    }

    pub fn complete(self: *const Words, prefix: []const u8, out: []u32) usize {
        var buf: [max_word * 4]u8 = undefined;
        const key = foldInto(&buf, prefix) orelse return 0;
        if (key.len == 0) return 0;
        var lo: usize = 0;
        var hi: usize = self.by_key.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (std.mem.order(u8, self.entries[self.by_key[mid]].folded, key) == .lt) lo = mid + 1 else hi = mid;
        }
        var top = Top.init(out);
        var i = lo;
        while (i < self.by_key.len) : (i += 1) {
            const id = self.by_key[i];
            if (!std.mem.startsWith(u8, self.entries[id].folded, key)) break;
            top.offer(id, @floatFromInt(self.entries[id].freq));
        }
        return top.n;
    }

    pub fn correct(self: *const Words, text: []const u8, out: []u32) usize {
        var buf: [max_word * 4]u8 = undefined;
        const key = foldInto(&buf, text) orelse return 0;
        if (key.len < 2) return 0;
        const limit: usize = if (key.len <= 4) 1 else 2;
        var top = Top.init(out);
        for (self.entries, 0..) |entry, id| {
            const f = entry.folded;
            if (f.len + limit < key.len or key.len + limit < f.len) continue;
            const d = distance(key, f, limit) orelse continue;
            const freq: f64 = @floatFromInt(entry.freq);
            top.offer(@intCast(id), @log(freq + 1.0) - 4.0 * @as(f64, @floatFromInt(d)));
        }
        return top.n;
    }

    pub fn swipe(self: *const Words, keys: []const Key, trace: []const [2]f32, out: []u32) usize {
        if (keys.len < 2 or trace.len < 2) return 0;
        const pitch = keyPitch(keys);
        var path: [samples][2]f32 = undefined;
        resample(trace, &path);
        const first = trace[0];
        const last = trace[trace.len - 1];
        const reach = pitch * 1.25;
        var length: f32 = 0;
        for (1..trace.len) |i| length += dist(trace[i - 1], trace[i]);
        const top_freq: f64 = @floatFromInt(@max(1, self.entries[0].freq));
        var top = Top.init(out);
        var points: [max_word][2]f32 = undefined;
        for (self.entries, 0..) |entry, id| {
            if (entry.head == 0) continue;
            const head = keyFor(keys, entry.head) orelse continue;
            if (dist(head, first) > reach) continue;
            const tail = keyFor(keys, entry.tail) orelse continue;
            if (dist(tail, last) > reach) continue;
            const n = templateFor(keys, entry.lower, &points) orelse continue;
            if (n == 0) continue;
            if (dist(points[0], first) > reach) continue;
            if (dist(points[n - 1], last) > reach) continue;
            if (n == 1 and length > pitch * 1.5) continue;
            var ideal: [samples][2]f32 = undefined;
            resample(points[0..n], &ideal);
            var total: f32 = 0;
            for (0..samples) |s| total += dist(path[s], ideal[s]);
            const location = total / samples / pitch;
            var miss: f32 = 0;
            for (points[0..n]) |p| miss = @max(miss, nearest(trace, p) / pitch);
            if (miss > 1.6) continue;
            const freq: f64 = @floatFromInt(entry.freq);
            const rarity = -@log(freq / top_freq);
            const score = -(@as(f64, location) * 2.5 + @as(f64, miss) + rarity * 0.12);
            top.offer(@intCast(id), score);
        }
        return top.n;
    }
};

const Top = struct {
    ids: []u32,
    scores: [64]f64 = undefined,
    n: usize = 0,

    fn init(out: []u32) Top {
        return .{ .ids = out[0..@min(out.len, 64)] };
    }

    fn offer(self: *Top, id: u32, score: f64) void {
        if (self.ids.len == 0) return;
        if (self.n == self.ids.len and score <= self.scores[self.n - 1]) return;
        var at = if (self.n < self.ids.len) self.n else self.n - 1;
        while (at > 0 and self.scores[at - 1] < score) : (at -= 1) {
            self.scores[at] = self.scores[at - 1];
            self.ids[at] = self.ids[at - 1];
        }
        self.scores[at] = score;
        self.ids[at] = id;
        if (self.n < self.ids.len) self.n += 1;
    }
};

fn dist(a: [2]f32, b: [2]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return @sqrt(dx * dx + dy * dy);
}

fn nearest(trace: []const [2]f32, p: [2]f32) f32 {
    var best: f32 = std.math.floatMax(f32);
    for (trace) |t| best = @min(best, dist(t, p));
    return best;
}

fn keyPitch(keys: []const Key) f32 {
    var gaps: [128]f32 = undefined;
    var n: usize = 0;
    for (keys, 0..) |a, i| {
        if (n == gaps.len) break;
        var best: f32 = std.math.floatMax(f32);
        for (keys, 0..) |b, j| {
            if (i == j) continue;
            const d = dist(.{ a.x, a.y }, .{ b.x, b.y });
            if (d > 0.5) best = @min(best, d);
        }
        if (best < std.math.floatMax(f32)) {
            gaps[n] = best;
            n += 1;
        }
    }
    if (n == 0) return 1;
    std.mem.sort(f32, gaps[0..n], {}, std.sort.asc(f32));
    return gaps[n / 2];
}

fn resample(points: []const [2]f32, out: *[samples][2]f32) void {
    var length: f32 = 0;
    for (1..points.len) |i| length += dist(points[i - 1], points[i]);
    if (points.len == 1 or length <= 0) {
        for (out) |*o| o.* = points[0];
        return;
    }
    const step = length / @as(f32, samples - 1);
    out[0] = points[0];
    var filled: usize = 1;
    var walked: f32 = 0;
    var target = step;
    var i: usize = 1;
    while (i < points.len and filled < samples - 1) {
        const a = points[i - 1];
        const b = points[i];
        const seg = dist(a, b);
        if (walked + seg >= target and seg > 0) {
            const t = (target - walked) / seg;
            out[filled] = .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
            filled += 1;
            target += step;
            continue;
        }
        walked += seg;
        i += 1;
    }
    while (filled < samples) : (filled += 1) out[filled] = points[points.len - 1];
}

fn keyFor(keys: []const Key, cp: u32) ?[2]f32 {
    for (keys) |k| if (k.codepoint == cp) return .{ k.x, k.y };
    var buf: [4]u8 = undefined;
    const folded = foldCodepoint(cp, &buf);
    if (folded.len == 0) return null;
    const base: u32 = folded[0];
    if (base == cp) return null;
    for (keys) |k| if (k.codepoint == base) return .{ k.x, k.y };
    return null;
}

fn endsOf(lower: []const u8) ?[2]u32 {
    var view = std.unicode.Utf8View.init(lower) catch return null;
    var it = view.iterator();
    var head: ?u32 = null;
    var tail: u32 = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp == '\'' or cp == '-') continue;
        if (head == null) head = cp;
        tail = cp;
    }
    return .{ head orelse return null, tail };
}

fn templateFor(keys: []const Key, lower: []const u8, out: *[max_word][2]f32) ?usize {
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(lower) catch return null;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\'' or cp == '-') continue;
        const p = keyFor(keys, cp) orelse return null;
        if (n > 0 and out[n - 1][0] == p[0] and out[n - 1][1] == p[1]) continue;
        if (n == max_word) return null;
        out[n] = p;
        n += 1;
    }
    return n;
}

fn distance(a: []const u8, b: []const u8, limit: usize) ?usize {
    if (a.len > max_word or b.len > max_word) return null;
    var prev2: [max_word + 1]usize = undefined;
    var prev: [max_word + 1]usize = undefined;
    var cur: [max_word + 1]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (1..a.len + 1) |i| {
        cur[0] = i;
        var row_min = cur[0];
        for (1..b.len + 1) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            var v = @min(prev[j] + 1, @min(cur[j - 1] + 1, prev[j - 1] + cost));
            if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]) v = @min(v, prev2[j - 2] + 1);
            cur[j] = v;
            row_min = @min(row_min, v);
        }
        if (row_min > limit) return null;
        prev2 = prev;
        prev = cur;
    }
    return if (prev[b.len] <= limit) prev[b.len] else null;
}

fn lowerCodepoint(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp >= 0xC0 and cp <= 0xDE and cp != 0xD7) return cp + 32;
    if (cp >= 0x100 and cp <= 0x17F and cp % 2 == 0) return cp + 1;
    return cp;
}

fn foldCodepoint(cp: u32, buf: *[4]u8) []const u8 {
    const base: []const u8 = switch (cp) {
        0xE0...0xE5 => "a",
        0xE7 => "c",
        0xE8...0xEB => "e",
        0xEC...0xEF => "i",
        0xF1 => "n",
        0xF2...0xF6, 0xF8 => "o",
        0xF9...0xFC => "u",
        0xFD, 0xFF => "y",
        0xDF => "ss",
        0xE6 => "ae",
        0x153 => "oe",
        0x101, 0x103, 0x105 => "a",
        0x107, 0x109, 0x10B, 0x10D => "c",
        0x113, 0x115, 0x117, 0x119, 0x11B => "e",
        0x12B, 0x12D, 0x12F => "i",
        0x144, 0x146, 0x148 => "n",
        0x14D, 0x14F, 0x151 => "o",
        0x15B, 0x15D, 0x15F, 0x161 => "s",
        0x16B, 0x16D, 0x16F, 0x171, 0x173 => "u",
        0x17A, 0x17C, 0x17E => "z",
        else => {
            const n = std.unicode.utf8Encode(@intCast(cp), buf) catch return "";
            return buf[0..n];
        },
    };
    return base;
}

fn lowerInto(buf: []u8, word: []const u8) ?[]const u8 {
    var view = std.unicode.Utf8View.init(word) catch return null;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        const l = lowerCodepoint(cp);
        if (n + 4 > buf.len) return null;
        n += std.unicode.utf8Encode(l, buf[n..]) catch return null;
    }
    return buf[0..n];
}

fn foldInto(buf: []u8, word: []const u8) ?[]const u8 {
    var view = std.unicode.Utf8View.init(word) catch return null;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        var tmp: [4]u8 = undefined;
        const f = foldCodepoint(lowerCodepoint(cp), &tmp);
        if (n + f.len > buf.len) return null;
        @memcpy(buf[n .. n + f.len], f);
        n += f.len;
    }
    return buf[0..n];
}

pub fn parse(alloc: std.mem.Allocator, buffer: []u8) !*Words {
    var count: usize = 0;
    for (buffer) |c| {
        if (c == '\n') count += 1;
    }
    const entries = try alloc.alloc(Entry, count + 1);
    errdefer alloc.free(entries);
    const store = try alloc.alloc(u8, buffer.len * 4 + 16);
    errdefer alloc.free(store);
    var used: usize = 0;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, buffer, '\n');
    var offset: usize = 0;
    while (lines.next()) |line| {
        const start = offset;
        offset += line.len + 1;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (tab == 0 or tab > max_word) continue;
        const freq = std.fmt.parseInt(u32, std.mem.trimEnd(u8, line[tab + 1 ..], "\r"), 10) catch continue;
        buffer[start + tab] = 0;
        const word = line[0..tab];
        const lower = lowerInto(store[used..], word) orelse continue;
        used += lower.len;
        const folded = foldInto(store[used..], word) orelse continue;
        used += folded.len;
        const ends = endsOf(lower) orelse [2]u32{ 0, 0 };
        entries[n] = .{
            .word = @ptrCast(buffer[start..].ptr),
            .len = tab,
            .freq = freq,
            .folded = folded,
            .lower = lower,
            .head = ends[0],
            .tail = ends[1],
        };
        n += 1;
    }
    if (n == 0) return error.Invalid;
    const self = try alloc.create(Words);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .buffer = buffer,
        .entries = entries[0..n],
        .storage = entries,
        .by_key = try alloc.alloc(u32, n),
        .known = .{},
        .folded_store = store,
    };
    errdefer alloc.free(self.by_key);
    for (self.by_key, 0..) |*k, i| k.* = @intCast(i);
    std.mem.sort(u32, self.by_key, self.entries, struct {
        fn less(e: []Entry, a: u32, b: u32) bool {
            return switch (std.mem.order(u8, e[a].folded, e[b].folded)) {
                .lt => true,
                .gt => false,
                .eq => e[a].freq > e[b].freq,
            };
        }
    }.less);
    try self.known.ensureTotalCapacity(alloc, @intCast(n));
    for (self.entries, 0..) |e, i| {
        const gop = self.known.getOrPutAssumeCapacity(e.lower);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
    }
    return self;
}

pub fn open(path: [*:0]const u8) !*Words {
    const buffer = try sys.readAlloc(sys.gpa, path, 16 << 20);
    errdefer sys.gpa.free(buffer);
    return parse(sys.gpa, buffer);
}

const testing = std.testing;

const sample =
    "the\t1000\nI\t900\nhello\t300\nhelp\t280\nhell\t50\nhelmet\t20\nhouse\t200\nhorse\t60\ndon't\t150\nperché\t120\nHaus\t80\nwhat\t400\nwet\t30\n";

fn sampleWords() !*Words {
    const buf = try testing.allocator.dupe(u8, sample);
    return parse(testing.allocator, buf);
}

fn ids(w: *const Words, out: []const u32) [8][]const u8 {
    var r: [8][]const u8 = .{""} ** 8;
    for (out, 0..) |id, i| r[i] = std.mem.span(w.word(id));
    return r;
}

const qwerty = [_][]const u8{ "qwertyuiop", "asdfghjkl", "zxcvbnm" };

fn layout(out: *[26]Key) []Key {
    var n: usize = 0;
    for (qwerty, 0..) |row, r| {
        for (row, 0..) |c, i| {
            out[n] = .{ .codepoint = c, .x = @as(f32, @floatFromInt(i)) * 40 + @as(f32, @floatFromInt(r)) * 20 + 20, .y = @as(f32, @floatFromInt(r)) * 60 + 30 };
            n += 1;
        }
    }
    return out[0..n];
}

fn traceFor(keys: []const Key, text: []const u8, out: *[256][2]f32, wobble: f32) []const [2]f32 {
    var n: usize = 0;
    var prev: ?[2]f32 = null;
    for (text, 0..) |c, ci| {
        const p = keyFor(keys, c).?;
        const jitter: f32 = if (ci % 2 == 0) wobble else -wobble;
        const q = [2]f32{ p[0] + jitter, p[1] - jitter };
        if (prev) |a| {
            for (1..9) |s| {
                const t = @as(f32, @floatFromInt(s)) / 8;
                out[n] = .{ a[0] + (q[0] - a[0]) * t, a[1] + (q[1] - a[1]) * t };
                n += 1;
            }
        } else {
            out[n] = q;
            n += 1;
        }
        prev = q;
    }
    return out[0..n];
}

test "completion folds accents and ranks by frequency" {
    const w = try sampleWords();
    defer w.deinit();
    var out: [3]u32 = undefined;
    const n = w.complete("hel", &out);
    try testing.expectEqual(@as(usize, 3), n);
    const got = ids(w, out[0..n]);
    try testing.expectEqualStrings("hello", got[0]);
    try testing.expectEqualStrings("help", got[1]);
    var one: [1]u32 = undefined;
    try testing.expectEqual(@as(usize, 1), w.complete("perche", &one));
    try testing.expectEqualStrings("perché", std.mem.span(w.word(one[0])));
    try testing.expectEqual(@as(usize, 1), w.complete("hau", &one));
    try testing.expectEqualStrings("Haus", std.mem.span(w.word(one[0])));
}

test "known words ignore case but not accents" {
    const w = try sampleWords();
    defer w.deinit();
    try testing.expect(w.contains("Hello"));
    try testing.expect(w.contains("haus"));
    try testing.expect(w.contains("i"));
    try testing.expect(!w.contains("perche"));
    try testing.expect(w.contains("PERCHÉ"));
}

test "corrections prefer close and frequent words" {
    const w = try sampleWords();
    defer w.deinit();
    var out: [3]u32 = undefined;
    var n = w.correct("teh", &out);
    try testing.expect(n >= 1);
    try testing.expectEqualStrings("the", std.mem.span(w.word(out[0])));
    n = w.correct("dont", &out);
    try testing.expect(n >= 1);
    try testing.expectEqualStrings("don't", std.mem.span(w.word(out[0])));
    n = w.correct("helo", &out);
    try testing.expectEqualStrings("hello", std.mem.span(w.word(out[0])));
}

test "swipe traces decode to the traced word" {
    const w = try sampleWords();
    defer w.deinit();
    var kb: [26]Key = undefined;
    const keys = layout(&kb);
    var buf: [256][2]f32 = undefined;
    var out: [3]u32 = undefined;
    for ([_][]const u8{ "hello", "house", "what", "the", "horse", "help" }) |text| {
        const n = w.swipe(keys, traceFor(keys, text, &buf, 6), &out);
        try testing.expect(n >= 1);
        try testing.expectEqualStrings(text, std.mem.span(w.word(out[0])));
    }
}

test "swipe without a matching start key finds nothing" {
    const w = try sampleWords();
    defer w.deinit();
    var kb: [26]Key = undefined;
    const keys = layout(&kb);
    var buf: [256][2]f32 = undefined;
    var out: [3]u32 = undefined;
    try testing.expectEqual(@as(usize, 0), w.swipe(keys, traceFor(keys, "zx", &buf, 0), &out));
}
