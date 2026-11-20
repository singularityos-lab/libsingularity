namespace Singularity {

    public enum LedLayerKind {
        TEXT,
        BITMAP,
        BAR;

        public string to_id() {
            switch (this) {
                case TEXT: return "text";
                case BITMAP: return "bitmap";
                default: return "bar";
            }
        }

        public static LedLayerKind from_id(string id) {
            switch (id) {
                case "bitmap": return BITMAP;
                case "bar": return BAR;
                default: return TEXT;
            }
        }
    }

    public enum LedScroll {
        NONE,
        AUTO,
        ALWAYS;

        public string to_id() {
            switch (this) {
                case AUTO: return "auto";
                case ALWAYS: return "always";
                default: return "none";
            }
        }

        public static LedScroll from_id(string id) {
            switch (id) {
                case "auto": return AUTO;
                case "always": return ALWAYS;
                default: return NONE;
            }
        }
    }

    public class LedFrame : Object {
        public int duration_ms { get; set; default = 100; }
        public uint8[] pixels;

        public LedFrame(int width, int height) {
            pixels = new uint8[width * height];
        }

        public LedFrame copy() {
            var f = new LedFrame(0, 0);
            f.duration_ms = duration_ms;
            f.pixels = pixels;
            return f;
        }
    }

    public class LedLayer : Object {
        public LedLayerKind kind { get; set; default = LedLayerKind.TEXT; }
        public string name { get; set; default = ""; }
        public int x { get; set; default = 0; }
        public int y { get; set; default = 0; }
        public int width { get; set; default = 0; }
        public int height { get; set; default = 0; }
        public int level { get; set; default = 7; }
        public string when { get; set; default = ""; }
        public int blink_ms { get; set; default = 0; }
        public bool visible { get; set; default = true; }

        public string text { get; set; default = ""; }
        public LedScroll scroll { get; set; default = LedScroll.AUTO; }
        public int speed { get; set; default = 12; }
        public int gap { get; set; default = 4; }
        public int tracking { get; set; default = 1; }
        public int alternate_level { get; set; default = -1; }

        public string source { get; set; default = ""; }
        public bool vertical { get; set; default = false; }

        public GenericArray<LedFrame> frames = new GenericArray<LedFrame>();

        public LedLayer.text_layer(string text) {
            kind = LedLayerKind.TEXT;
            this.text = text;
        }

        public int total_ms() {
            int t = 0;
            foreach (var f in frames) t += int.max(f.duration_ms, 1);
            return t;
        }

        public LedFrame? frame_at(int64 ms) {
            if (frames.length == 0) return null;
            int total = total_ms();
            int64 t = ms % total;
            foreach (var f in frames) {
                int d = int.max(f.duration_ms, 1);
                if (t < d) return f;
                t -= d;
            }
            return frames[frames.length - 1];
        }

        public LedLayer copy() {
            var l = new LedLayer();
            l.kind = kind; l.name = name; l.x = x; l.y = y; l.width = width; l.height = height;
            l.level = level; l.when = when; l.blink_ms = blink_ms; l.visible = visible;
            l.text = text; l.scroll = scroll; l.speed = speed; l.gap = gap;
            l.tracking = tracking; l.alternate_level = alternate_level;
            l.source = source; l.vertical = vertical;
            foreach (var f in frames) l.frames.add(f.copy());
            return l;
        }
    }

    public errordomain LedSceneError {
        INVALID
    }

    public class LedScene : Object {
        public const string FORMAT = "sinty-led-scene";
        public const int VERSION = 1;

        public string name { get; set; default = ""; }
        public int width { get; set; default = 13; }
        public int height { get; set; default = 8; }
        public GenericArray<LedLayer> layers = new GenericArray<LedLayer>();

        public LedScene(string name, int width, int height) {
            this.name = name;
            this.width = width;
            this.height = height;
        }

        public LedScene copy() {
            var s = new LedScene(name, width, height);
            foreach (var l in layers) s.layers.add(l.copy());
            return s;
        }

        private static char level_char(uint8 v) {
            return (char) ('0' + int.min(v, 7));
        }

        private static uint8 char_level(char c) {
            if (c >= '0' && c <= '7') return (uint8) (c - '0');
            if (c == '#') return 7;
            return 0;
        }

        public string to_json() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("format"); b.add_string_value(FORMAT);
            b.set_member_name("version"); b.add_int_value(VERSION);
            b.set_member_name("name"); b.add_string_value(name);
            b.set_member_name("width"); b.add_int_value(width);
            b.set_member_name("height"); b.add_int_value(height);
            b.set_member_name("layers");
            b.begin_array();
            foreach (var l in layers) {
                b.begin_object();
                b.set_member_name("type"); b.add_string_value(l.kind.to_id());
                if (l.name != "") { b.set_member_name("name"); b.add_string_value(l.name); }
                b.set_member_name("x"); b.add_int_value(l.x);
                b.set_member_name("y"); b.add_int_value(l.y);
                if (l.width > 0) { b.set_member_name("w"); b.add_int_value(l.width); }
                if (l.height > 0) { b.set_member_name("h"); b.add_int_value(l.height); }
                b.set_member_name("level"); b.add_int_value(l.level);
                if (l.when != "") { b.set_member_name("when"); b.add_string_value(l.when); }
                if (l.blink_ms > 0) { b.set_member_name("blink_ms"); b.add_int_value(l.blink_ms); }
                if (!l.visible) { b.set_member_name("visible"); b.add_boolean_value(false); }
                switch (l.kind) {
                    case LedLayerKind.TEXT:
                        b.set_member_name("text"); b.add_string_value(l.text);
                        b.set_member_name("scroll"); b.add_string_value(l.scroll.to_id());
                        b.set_member_name("speed"); b.add_int_value(l.speed);
                        b.set_member_name("gap"); b.add_int_value(l.gap);
                        if (l.tracking != 1) { b.set_member_name("tracking"); b.add_int_value(l.tracking); }
                        if (l.alternate_level >= 0) { b.set_member_name("alternate_level"); b.add_int_value(l.alternate_level); }
                        break;
                    case LedLayerKind.BAR:
                        b.set_member_name("source"); b.add_string_value(l.source);
                        b.set_member_name("vertical"); b.add_boolean_value(l.vertical);
                        break;
                    case LedLayerKind.BITMAP:
                        b.set_member_name("frames");
                        b.begin_array();
                        int fw = l.width > 0 ? l.width : width;
                        int fh = l.height > 0 ? l.height : height;
                        foreach (var f in l.frames) {
                            b.begin_object();
                            b.set_member_name("ms"); b.add_int_value(f.duration_ms);
                            b.set_member_name("rows");
                            b.begin_array();
                            for (int r = 0; r < fh; r++) {
                                var row = new StringBuilder();
                                for (int c = 0; c < fw; c++) {
                                    int i = r * fw + c;
                                    row.append_c(level_char(i < f.pixels.length ? f.pixels[i] : 0));
                                }
                                b.add_string_value(row.str);
                            }
                            b.end_array();
                            b.end_object();
                        }
                        b.end_array();
                        break;
                }
                b.end_object();
            }
            b.end_array();
            b.end_object();
            var g = new Json.Generator();
            g.pretty = true;
            g.indent = 2;
            g.set_root(b.get_root());
            return g.to_data(null);
        }

        private static int64 int_member(Json.Object o, string key, int64 fallback) {
            return o.has_member(key) ? o.get_int_member(key) : fallback;
        }

        private static string string_member(Json.Object o, string key, string fallback) {
            return o.has_member(key) ? o.get_string_member(key) : fallback;
        }

        public static LedScene from_json(string data) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(data);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) throw new LedSceneError.INVALID("not a scene");
            var o = root.get_object();
            if (string_member(o, "format", "") != FORMAT) throw new LedSceneError.INVALID("not a Sinty LED scene");
            if (int_member(o, "version", 0) > VERSION) throw new LedSceneError.INVALID("made by a newer version");
            int w = (int) int_member(o, "width", 13);
            int h = (int) int_member(o, "height", 8);
            if (w < 1 || h < 1 || w * h > 4096) throw new LedSceneError.INVALID("bad size");
            var scene = new LedScene(string_member(o, "name", ""), w, h);
            if (!o.has_member("layers")) return scene;
            foreach (var node in o.get_array_member("layers").get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var lo = node.get_object();
                var l = new LedLayer();
                l.kind = LedLayerKind.from_id(string_member(lo, "type", "text"));
                l.name = string_member(lo, "name", "");
                l.x = (int) int_member(lo, "x", 0);
                l.y = (int) int_member(lo, "y", 0);
                l.width = (int) int_member(lo, "w", 0);
                l.height = (int) int_member(lo, "h", 0);
                l.level = (int) int_member(lo, "level", 7).clamp(0, 7);
                l.when = string_member(lo, "when", "");
                l.blink_ms = (int) int_member(lo, "blink_ms", 0);
                l.visible = lo.has_member("visible") ? lo.get_boolean_member("visible") : true;
                l.text = string_member(lo, "text", "");
                l.scroll = LedScroll.from_id(string_member(lo, "scroll", "auto"));
                l.speed = (int) int_member(lo, "speed", 12).clamp(1, 200);
                l.gap = (int) int_member(lo, "gap", 4).clamp(0, 64);
                l.tracking = (int) int_member(lo, "tracking", 1).clamp(0, 4);
                l.alternate_level = (int) int_member(lo, "alternate_level", -1).clamp(-1, 7);
                l.source = string_member(lo, "source", "");
                l.vertical = lo.has_member("vertical") && lo.get_boolean_member("vertical");
                if (l.kind == LedLayerKind.BITMAP && lo.has_member("frames")) {
                    int fw = l.width > 0 ? l.width : w;
                    int fh = l.height > 0 ? l.height : h;
                    foreach (var fn in lo.get_array_member("frames").get_elements()) {
                        if (fn.get_node_type() != Json.NodeType.OBJECT) continue;
                        var fo = fn.get_object();
                        var f = new LedFrame(fw, fh);
                        f.duration_ms = (int) int_member(fo, "ms", 100).clamp(10, 60000);
                        if (fo.has_member("rows")) {
                            var rows = fo.get_array_member("rows");
                            for (int r = 0; r < fh && r < (int) rows.get_length(); r++) {
                                string row = rows.get_string_element(r);
                                for (int c = 0; c < fw && c < row.length; c++) f.pixels[r * fw + c] = char_level(row[c]);
                            }
                        }
                        l.frames.add(f);
                    }
                }
                scene.layers.add(l);
            }
            return scene;
        }

        public static LedScene load(string path) throws Error {
            string data;
            FileUtils.get_contents(path, out data);
            return from_json(data);
        }

        public void save(string path) throws Error {
            DirUtils.create_with_parents(Path.get_dirname(path), 0755);
            FileUtils.set_contents(path, to_json());
        }

        public static string user_dir() {
            return Path.build_filename(Environment.get_user_data_dir(), "sinty", "led-scenes");
        }

        private static LedLayer bitmap(int x, int y, int w, int h, string[] rows, int level = 7) {
            var l = new LedLayer();
            l.kind = LedLayerKind.BITMAP;
            l.x = x; l.y = y; l.width = w; l.height = h; l.level = level;
            var f = new LedFrame(w, h);
            f.duration_ms = 1000;
            for (int r = 0; r < h && r < rows.length; r++) {
                for (int c = 0; c < w && c < rows[r].length; c++) f.pixels[r * w + c] = char_level(rows[r][c]);
            }
            l.frames.add(f);
            return l;
        }

        public static string[] builtin_ids() {
            return { "clock", "now-playing", "notifications", "system", "battery" };
        }

        public static LedScene builtin(string id, int width, int height) {
            var s = new LedScene(id, width, height);
            int top = int.max((height - LedFont.HEIGHT) / 2, 0);
            switch (id) {
                case "now-playing": {
                    s.layers.add(bitmap(0, top, 3, 5, { "#..", "##.", "###", "##.", "#.." }));
                    var t = new LedLayer.text_layer("{media}");
                    t.x = 4; t.y = top; t.scroll = LedScroll.ALWAYS; t.speed = 10;
                    s.layers.add(t);
                    var p = new LedLayer();
                    p.kind = LedLayerKind.BAR; p.source = "{media_progress}";
                    p.x = 0; p.y = height - 1; p.height = 1; p.level = 2;
                    s.layers.add(p);
                    break;
                }
                case "notifications": {
                    s.layers.add(bitmap(0, top, 5, 5, { "..#..", ".###.", ".###.", "#####", "..#.." }));
                    var t = new LedLayer.text_layer("{notifications}");
                    t.x = 7; t.y = top; t.scroll = LedScroll.AUTO;
                    s.layers.add(t);
                    break;
                }
                case "system": {
                    string[] labels = { "C", "M" };
                    string[] sources = { "{cpu}", "{memory}" };
                    for (int i = 0; i < 2; i++) {
                        int row = i * 4;
                        var t = new LedLayer.text_layer(labels[i]);
                        t.y = row == 0 ? 0 : height - LedFont.HEIGHT; t.scroll = LedScroll.NONE; t.level = 3;
                        var b = new LedLayer();
                        b.kind = LedLayerKind.BAR; b.source = sources[i];
                        b.x = 4; b.y = i == 0 ? 1 : height - 4; b.height = 3;
                        s.layers.add(t);
                        s.layers.add(b);
                    }
                    break;
                }
                case "battery": {
                    s.layers.add(bitmap(0, top, 13, 5, {
                        "##########...", "#........#...", "#........##..", "#........#...", "##########..."
                    }, 4));
                    var b = new LedLayer();
                    b.kind = LedLayerKind.BAR; b.source = "{battery}";
                    b.x = 1; b.y = top + 1; b.width = 8; b.height = 3;
                    s.layers.add(b);
                    var c = bitmap(11, top, 2, 5, { ".#", "#.", "##", ".#", "#." });
                    c.when = "{charging}"; c.blink_ms = 700;
                    s.layers.add(c);
                    break;
                }
                default: {
                    var t = new LedLayer.text_layer("{time}");
                    t.y = top; t.scroll = LedScroll.AUTO; t.speed = 8;
                    t.tracking = 0; t.alternate_level = 3;
                    s.layers.add(t);
                    break;
                }
            }
            return s;
        }
    }

    public class LedContext : Object {
        private HashTable<string, string> values = new HashTable<string, string>(str_hash, str_equal);

        public signal void changed(string key);

        public void set_value(string key, string value) {
            string? old = values.lookup(key);
            if (old == value) return;
            values.insert(key, value);
            changed(key);
        }

        public string get_value(string key) {
            return values.lookup(key) ?? "";
        }

        public string[] keys() {
            string[] k = {};
            foreach (unowned string key in values.get_keys()) k += key;
            return k;
        }

        public string expand(string text) {
            if (text.index_of_char('{') < 0) return text;
            var out = new StringBuilder();
            int i = 0;
            while (i < text.length) {
                if (text[i] == '{') {
                    int end = text.index_of_char('}', i + 1);
                    if (end > i) {
                        out.append(get_value(text.substring(i + 1, end - i - 1)));
                        i = end + 1;
                        continue;
                    }
                }
                out.append_c(text[i]);
                i++;
            }
            return out.str;
        }

        public bool truthy(string expr) {
            if (expr == "") return true;
            string v = expand(expr).strip();
            return v != "" && v != "0" && v != "false";
        }
    }

    public class LedRenderer : Object {
        public static bool animated(LedScene scene, LedContext ctx) {
            foreach (var l in scene.layers) {
                if (!l.visible || !ctx.truthy(l.when)) continue;
                if (l.blink_ms > 0) return true;
                if (l.kind == LedLayerKind.BITMAP && l.frames.length > 1) return true;
                if (l.kind == LedLayerKind.TEXT) {
                    int area = l.width > 0 ? l.width : scene.width - l.x;
                    if (l.scroll == LedScroll.ALWAYS) return true;
                    if (l.scroll == LedScroll.AUTO && LedFont.text_width(ctx.expand(l.text), l.tracking) > area) return true;
                }
            }
            return false;
        }

        public static uint8[] render(LedScene scene, LedContext ctx, int64 ms) {
            int w = scene.width;
            int h = scene.height;
            var out = new uint8[w * h];
            foreach (var l in scene.layers) {
                if (!l.visible || !ctx.truthy(l.when)) continue;
                if (l.blink_ms > 0 && (ms / l.blink_ms) % 2 == 1) continue;
                uint8 level = (uint8) l.level.clamp(0, 7);
                int ax = l.x;
                int ay = l.y;
                int aw = l.width > 0 ? l.width : w - l.x;
                int ah = l.height > 0 ? l.height : h - l.y;
                uint8 alt = l.alternate_level >= 0 ? (uint8) l.alternate_level : level;
                LedFont.PixelFunc plot = (px, py, alternate) => {
                    if (px < ax || py < ay || px >= ax + aw || py >= ay + ah) return;
                    if (px < 0 || py < 0 || px >= w || py >= h) return;
                    int i = py * w + px;
                    uint8 v = alternate ? alt : level;
                    if (v > out[i]) out[i] = v;
                };
                switch (l.kind) {
                    case LedLayerKind.TEXT: {
                        string text = ctx.expand(l.text);
                        int tw = LedFont.text_width(text, l.tracking);
                        bool moving = l.scroll == LedScroll.ALWAYS || (l.scroll == LedScroll.AUTO && tw > aw);
                        if (!moving) {
                            LedFont.draw_text(text, ax, ay, plot, l.tracking);
                            break;
                        }
                        int span = tw + l.gap;
                        if (l.scroll == LedScroll.ALWAYS) span = int.max(span, aw);
                        int offset = (int) ((ms * l.speed / 1000) % span);
                        for (int pos = ax - offset; pos < ax + aw; pos += span) {
                            LedFont.draw_text(text, pos, ay, plot, l.tracking);
                        }
                        break;
                    }
                    case LedLayerKind.BITMAP: {
                        var f = l.frame_at(ms);
                        if (f == null) break;
                        int fw = l.width > 0 ? l.width : w;
                        int fh = l.height > 0 ? l.height : h;
                        for (int r = 0; r < fh; r++) {
                            for (int c = 0; c < fw; c++) {
                                int i = r * fw + c;
                                if (i >= f.pixels.length || f.pixels[i] == 0) continue;
                                int px = ax + c, py = ay + r;
                                if (px < 0 || py < 0 || px >= w || py >= h) continue;
                                uint8 v = (uint8) int.min(f.pixels[i], level);
                                int o = py * w + px;
                                if (v > out[o]) out[o] = v;
                            }
                        }
                        break;
                    }
                    case LedLayerKind.BAR: {
                        double pct = double.parse(ctx.expand(l.source)).clamp(0, 100);
                        int len = (int) Math.round((l.vertical ? ah : aw) * pct / 100.0);
                        for (int r = 0; r < ah; r++) {
                            for (int c = 0; c < aw; c++) {
                                bool on = l.vertical ? (ah - 1 - r) < len : c < len;
                                if (on) plot(ax + c, ay + r, false);
                            }
                        }
                        break;
                    }
                }
            }
            return out;
        }
    }
}
