namespace Singularity.Equations {

    public class GalleryEntry : Object {
        public string id { get; set; }
        public string name { get; set; }
        public string category { get; set; default = ""; }
        public string mathml { get; set; }
        public string latex { get; set; default = ""; }
        public int64 created { get; set; }

        public Equation to_equation() {
            var eq = new Equation.from_mathml(mathml);
            return eq;
        }
    }

    public class UserGallery : Object {
        private static UserGallery? instance;
        private Gee.ArrayList<GalleryEntry> entries = new Gee.ArrayList<GalleryEntry>();
        private FileMonitor? monitor;
        private bool saving;

        public string path { get; construct; }

        public signal void changed();

        public UserGallery(string path) {
            Object(path: path);
            load();
        }

        public static UserGallery get_default() {
            if (instance == null) {
                instance = new UserGallery(default_path());
                instance.watch();
            }
            return instance;
        }

        public static string default_path() {
            string? over = Environment.get_variable("SINGULARITY_EQUATION_GALLERY");
            if (over != null && over != "") return over;
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "equations", "gallery.json");
        }

        public Gee.List<GalleryEntry> items() {
            var list = new Gee.ArrayList<GalleryEntry>();
            list.add_all(entries);
            return list;
        }

        public Gee.List<string> categories() {
            var set = new Gee.TreeSet<string>();
            foreach (var e in entries) if (e.category != "") set.add(e.category);
            var list = new Gee.ArrayList<string>();
            list.add_all(set);
            return list;
        }

        public GalleryEntry? find(string id) {
            foreach (var e in entries) if (e.id == id) return e;
            return null;
        }

        public GalleryEntry add(string name, string category, string mathml, string latex = "") {
            var e = new GalleryEntry();
            e.id = "%08x%08x".printf(Random.next_int(), (uint) (get_real_time() & 0xffffffff));
            e.name = name.strip() != "" ? name.strip() : _("Equation");
            e.category = category.strip();
            e.mathml = mathml;
            e.latex = latex;
            e.created = get_real_time() / 1000000;
            entries.add(e);
            changed();
            return e;
        }

        public void remove(string id) {
            var e = find(id);
            if (e == null) return;
            entries.remove(e);
            changed();
        }

        public void rename(string id, string name, string category) {
            var e = find(id);
            if (e == null) return;
            e.name = name;
            e.category = category;
            changed();
        }

        private void load() {
            entries.clear();
            if (!FileUtils.test(path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var o = root.get_object();
                if (!o.has_member("equations")) return;
                foreach (var n in o.get_array_member("equations").get_elements()) {
                    var eo = n.get_object();
                    var e = new GalleryEntry();
                    e.id = eo.has_member("id") ? eo.get_string_member("id") : "%08x".printf(Random.next_int());
                    e.name = eo.has_member("name") ? eo.get_string_member("name") : "";
                    e.category = eo.has_member("category") ? eo.get_string_member("category") : "";
                    e.mathml = eo.has_member("mathml") ? eo.get_string_member("mathml") : "";
                    e.latex = eo.has_member("latex") ? eo.get_string_member("latex") : "";
                    e.created = eo.has_member("created") ? eo.get_int_member("created") : 0;
                    if (e.mathml != "") entries.add(e);
                }
            } catch (Error err) {
                warning("equation gallery: %s", err.message);
            }
        }

        public void save() throws Error {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("version");
            b.add_int_value(1);
            b.set_member_name("equations");
            b.begin_array();
            foreach (var e in entries) {
                b.begin_object();
                b.set_member_name("id");
                b.add_string_value(e.id);
                b.set_member_name("name");
                b.add_string_value(e.name);
                b.set_member_name("category");
                b.add_string_value(e.category);
                b.set_member_name("mathml");
                b.add_string_value(e.mathml);
                b.set_member_name("latex");
                b.add_string_value(e.latex);
                b.set_member_name("created");
                b.add_int_value(e.created);
                b.end_object();
            }
            b.end_array();
            b.end_object();
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(b.get_root());
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            saving = true;
            FileUtils.set_contents(path, gen.to_data(null));
            Timeout.add(400, () => {
                saving = false;
                return Source.REMOVE;
            });
        }

        private void watch() {
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                monitor = File.new_for_path(path).monitor_file(FileMonitorFlags.NONE, null);
                monitor.changed.connect((f, other, ev) => {
                    if (saving) return;
                    if (ev != FileMonitorEvent.CHANGES_DONE_HINT && ev != FileMonitorEvent.DELETED && ev != FileMonitorEvent.CREATED) return;
                    load();
                    changed();
                });
            } catch (Error e) {
                monitor = null;
            }
        }
    }
}
