namespace Singularity.Migration {

    public interface Migratable : Object {
        public abstract Variant save_model();
        public abstract async void restore_model(Variant model) throws Error;
        public abstract string window_kind(Gtk.Window window);
        public abstract Variant save_window(Gtk.Window window);
        public abstract async Gtk.Window? rebuild_window(string kind, Variant data) throws Error;

        public virtual string[] files() {
            return {};
        }

        public virtual void prepare_move() throws MigrationError {
        }
    }

    public static string portable_path(File file) {
        string path = file.get_path() ?? file.get_uri();
        string home = Environment.get_home_dir();
        if (path == home) return "~";
        if (path.has_prefix(home + "/")) return "~" + path.substring(home.length);
        return path;
    }

    public static File local_file(string portable) {
        if (portable == "~") return File.new_for_path(Environment.get_home_dir());
        if (portable.has_prefix("~/")) return File.new_for_path(Environment.get_home_dir() + portable.substring(1));
        if (portable.contains("://")) return File.new_for_uri(portable);
        return File.new_for_path(portable);
    }

    public errordomain MigrationError {
        UNSUPPORTED,
        INVALID,
        FAILED
    }

    public class Report : Object {
        public bool exact { get; set; default = false; }
        public string[] differences { get; set; default = {}; }
    }

    public class Session : Object {
        public const string TYPE = "(usvasa(svvi))";
        public const uint VERSION = 1;
        private const uint SETTLE_MS = 4000;

        public static bool supported(GLib.Application app) {
            return app is Migratable && text_history_available();
        }

        private static Gee.List<Gtk.Window> windows_of(Gtk.Application app) {
            var list = new Gee.ArrayList<Gtk.Window>();
            foreach (var w in app.get_windows()) list.insert(0, w);
            return list;
        }

        public static Variant capture(Gtk.Application app) throws MigrationError {
            if (!supported(app)) throw new MigrationError.UNSUPPORTED("%s cannot move to another device".printf(app.application_id));
            var owner = (Migratable) app;
            owner.prepare_move();
            var windows = windows_of(app);
            var kept = new Gee.ArrayList<Gtk.Window>();
            foreach (var w in windows) {
                if (w.visible && owner.window_kind(w) != "") kept.add(w);
            }
            var built = new VariantBuilder(new VariantType("a(svvi)"));
            foreach (var w in kept) {
                var state = new WidgetState();
                var widgets = state.capture(w);
                if (state.unsupported.length > 0) {
                    throw new MigrationError.UNSUPPORTED("the undo history of %s cannot be saved".printf(state.unsupported[0]));
                }
                int parent = w.transient_for != null ? kept.index_of(w.transient_for) : -1;
                built.add("(svvi)", owner.window_kind(w), owner.save_window(w), widgets, parent);
            }
            return new Variant.tuple({
                new Variant.uint32(VERSION),
                new Variant.string(app.application_id),
                new Variant.variant(owner.save_model()),
                new Variant.strv(owner.files()),
                built.end()
            });
        }

        public static async Report restore(Gtk.Application app, Variant state) throws Error {
            if (!supported(app)) throw new MigrationError.UNSUPPORTED("%s cannot receive apps from another device".printf(app.application_id));
            if (!state.is_of_type(new VariantType(TYPE))) throw new MigrationError.INVALID("this is not an app state");
            uint version = state.get_child_value(0).get_uint32();
            string app_id = state.get_child_value(1).get_string();
            Variant model = state.get_child_value(2).get_variant();
            Variant windows = state.get_child_value(4);
            if (version != VERSION) throw new MigrationError.INVALID("app state version %u is not supported".printf(version));
            if (app_id != app.application_id) throw new MigrationError.INVALID("this state belongs to %s".printf(app_id));
            var owner = (Migratable) app;
            yield owner.restore_model(model);
            var built = new Gee.ArrayList<Gtk.Window>();
            var states = new Gee.ArrayList<WidgetState>();
            var differences = new Gee.ArrayList<string>();
            var iter = windows.iterator();
            string kind;
            Variant data, widgets;
            int parent;
            while (iter.next("(svvi)", out kind, out data, out widgets, out parent)) {
                var w = yield owner.rebuild_window(kind, data);
                if (w == null) {
                    differences.add("window %s was not rebuilt".printf(kind));
                    continue;
                }
                if (parent >= 0 && parent < built.size) w.transient_for = built[parent];
                built.add(w);
                var ws = new WidgetState();
                ws.apply(w, widgets);
                w.present();
                yield mapped(w);
                ws.apply(w, widgets);
                states.add(ws);
                foreach (var p in ws.missing) differences.add("%s: %s is missing".printf(kind, p));
            }
            yield settle(built, states);
            var report = new Report();
            report.differences = differences.to_array();
            report.exact = differences.size == 0;
            return report;
        }

        private static async void mapped(Gtk.Window w) {
            if (!w.get_mapped()) {
                ulong id = w.map.connect(() => mapped.callback());
                yield;
                w.disconnect(id);
            }
            Idle.add(mapped.callback, Priority.LOW);
            yield;
        }

        private static async void settle(Gee.List<Gtk.Window> windows, Gee.List<WidgetState> states) {
            int64 deadline = get_monotonic_time() + SETTLE_MS * 1000;
            while (true) {
                bool done = true;
                foreach (var s in states) done &= s.settle();
                if (done || get_monotonic_time() > deadline) return;
                Timeout.add(16, settle.callback);
                yield;
            }
        }

        public static async Report certify(Gtk.Application app) throws Error {
            var settings = Gtk.Settings.get_default();
            bool blink = settings.gtk_cursor_blink;
            bool animations = settings.gtk_enable_animations;
            settings.gtk_cursor_blink = false;
            settings.gtk_enable_animations = false;
            app.hold();
            try {
                var before = capture(app);
                var pictures = new Gee.ArrayList<Bytes?>();
                foreach (var w in windows_of(app)) {
                    if (w.visible) pictures.add(picture(w));
                }
                var originals = windows_of(app);
                foreach (var w in originals) w.destroy();
                var report = yield restore(app, before);
                var after = capture(app);
                var differences = new Gee.ArrayList<string>.wrap(report.differences);
                compare(before, after, differences);
                int index = 0;
                foreach (var w in windows_of(app)) {
                    if (!w.visible) continue;
                    if (index < pictures.size) {
                        var now = picture(w);
                        if (pictures[index] == null || now == null || pictures[index].compare(now) != 0) {
                            differences.add("window %d looks different".printf(index));
                        }
                    }
                    index++;
                }
                report.differences = differences.to_array();
                report.exact = differences.size == 0;
                return report;
            } finally {
                settings.gtk_cursor_blink = blink;
                settings.gtk_enable_animations = animations;
                app.release();
            }
        }

        public static Variant snapshot(Gtk.Application app) {
            var owner = app as Migratable;
            var all = new VariantBuilder(new VariantType("a(siiay)"));
            foreach (var w in windows_of(app)) {
                if (!w.visible || owner == null || owner.window_kind(w) == "") continue;
                var pixels = picture(w);
                if (pixels == null) continue;
                all.add("(sii@ay)", owner.window_kind(w), w.get_width(), w.get_height(),
                    new Variant.from_bytes(VariantType.BYTESTRING, pixels, true));
            }
            return all.end();
        }

        public static Bytes? picture(Gtk.Window w) {
            int width = w.get_width(), height = w.get_height();
            var native = w.get_native();
            if (width <= 0 || height <= 0 || native == null || native.get_renderer() == null) return null;
            var paintable = new Gtk.WidgetPaintable(w);
            var snapshot = new Gtk.Snapshot();
            paintable.snapshot(snapshot, width, height);
            var node = snapshot.to_node();
            if (node == null) return null;
            var texture = native.get_renderer().render_texture(node, Graphene.Rect().init(0, 0, width, height));
            var downloader = new Gdk.TextureDownloader(texture);
            downloader.set_format(Gdk.MemoryFormat.R8G8B8A8);
            size_t stride;
            var bytes = downloader.download_bytes(out stride);
            if (stride == (size_t) width * 4) return bytes;
            var packed = new ByteArray.sized(width * height * 4);
            unowned uint8[] data = bytes.get_data();
            for (int y = 0; y < height; y++) packed.append(data[y * stride : y * stride + width * 4]);
            return ByteArray.free_to_bytes(packed);
        }

        public static void compare(Variant before, Variant after, Gee.List<string> differences) {
            Variant bw = before.get_child_value(4), aw = after.get_child_value(4);
            if (!before.get_child_value(2).equal(after.get_child_value(2))) differences.add("the app data differs");
            if (bw.n_children() != aw.n_children()) {
                differences.add("%u windows became %u".printf((uint) bw.n_children(), (uint) aw.n_children()));
                return;
            }
            for (size_t i = 0; i < bw.n_children(); i++) {
                var b = bw.get_child_value(i), a = aw.get_child_value(i);
                if (!b.get_child_value(1).equal(a.get_child_value(1))) differences.add("window %u data differs".printf((uint) i));
                var bwid = b.get_child_value(2).get_variant(), awid = a.get_child_value(2).get_variant();
                var later = new Gee.HashMap<string, Variant>();
                var it = awid.iterator();
                string path;
                Variant dict;
                while (it.next("{s@a{sv}}", out path, out dict)) later[path] = dict;
                it = bwid.iterator();
                while (it.next("{s@a{sv}}", out path, out dict)) {
                    var other = later[path];
                    if (other == null) {
                        differences.add("window %u: %s is gone".printf((uint) i, path));
                        continue;
                    }
                    var others = new VariantDict(other);
                    var kit = dict.iterator();
                    string key;
                    Variant value;
                    while (kit.next("{sv}", out key, out value)) {
                        var then = others.lookup_value(key, null);
                        if (then == null || !then.equal(value)) {
                            differences.add("window %u: %s %s differs".printf((uint) i, path, key));
                        }
                    }
                }
            }
        }
    }
}
