namespace Singularity.Assets {

    public class Asset : Object {
        public string id { get; set; default = ""; }
        public string kind { get; set; default = "color"; }
        public string name { get; set; default = ""; }
        public string app { get; set; default = ""; }
        public int version { get; set; default = 1; }
        public int64 modified { get; set; }
        public Gee.HashMap<string, string> fields = new Gee.HashMap<string, string> ();

        public string get_field (string key, string fallback = "") {
            return fields.has_key (key) ? fields[key] : fallback;
        }

        public double get_number (string key, double fallback = 0) {
            if (!fields.has_key (key)) return fallback;
            double v;
            return double.try_parse (fields[key], out v) ? v : fallback;
        }

        public void set_field (string key, string value) {
            fields[key] = value;
        }

        public Asset copy () {
            var a = new Asset ();
            a.id = id;
            a.kind = kind;
            a.name = name;
            a.app = app;
            a.version = version;
            a.modified = modified;
            foreach (var e in fields.entries) a.fields[e.key] = e.value;
            return a;
        }

        public Json.Node to_json () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("id").add_string_value (id);
            b.set_member_name ("kind").add_string_value (kind);
            b.set_member_name ("name").add_string_value (name);
            b.set_member_name ("app").add_string_value (app);
            b.set_member_name ("version").add_int_value (version);
            b.set_member_name ("modified").add_int_value (modified);
            b.set_member_name ("fields").begin_object ();
            var keys = new Gee.ArrayList<string> ();
            keys.add_all (fields.keys);
            keys.sort ();
            foreach (var k in keys) b.set_member_name (k).add_string_value (fields[k]);
            b.end_object ();
            b.end_object ();
            return b.get_root ();
        }

        public static Asset? from_json (Json.Node node) {
            if (node.get_node_type () != Json.NodeType.OBJECT) return null;
            var o = node.get_object ();
            var a = new Asset ();
            a.id = o.has_member ("id") ? o.get_string_member ("id") : Uuid.string_random ();
            a.kind = o.has_member ("kind") ? o.get_string_member ("kind") : "color";
            a.name = o.has_member ("name") ? o.get_string_member ("name") : "";
            a.app = o.has_member ("app") ? o.get_string_member ("app") : "";
            a.version = o.has_member ("version") ? (int) o.get_int_member ("version") : 1;
            a.modified = o.has_member ("modified") ? o.get_int_member ("modified") : 0;
            if (o.has_member ("fields")) {
                var f = o.get_object_member ("fields");
                foreach (var k in f.get_members ()) {
                    var n = f.get_member (k);
                    if (n.get_value_type () == typeof (string)) a.fields[k] = n.get_string ();
                    else if (n.get_node_type () == Json.NodeType.VALUE) a.fields[k] = n.get_value ().strdup_contents ().replace ("\"", "");
                }
            }
            return a;
        }
    }

    public class AssetLibrary : Object {
        private static AssetLibrary? instance;
        private Gee.ArrayList<Asset> items = new Gee.ArrayList<Asset> ();
        private FileMonitor? monitor;
        private bool saving;
        public string path { get; private set; }

        public signal void changed ();

        public AssetLibrary (string? path = null) {
            this.path = path ?? default_path ();
            load ();
            try {
                var f = File.new_for_path (this.path);
                monitor = f.monitor_file (FileMonitorFlags.NONE, null);
                monitor.changed.connect ((a, b, ev) => {
                    if (saving) return;
                    if (ev == FileMonitorEvent.CHANGES_DONE_HINT || ev == FileMonitorEvent.CREATED || ev == FileMonitorEvent.DELETED) {
                        load ();
                        changed ();
                    }
                });
            } catch (Error e) {
            }
        }

        public static AssetLibrary get_default () {
            if (instance == null) instance = new AssetLibrary ();
            return instance;
        }

        public static string default_path () {
            string? over = Environment.get_variable ("SINGULARITY_ASSET_LIBRARY");
            if (over != null && over != "") return over;
            return Path.build_filename (Environment.get_user_data_dir (), "singularity", "library", "assets.json");
        }

        public void load () {
            items.clear ();
            try {
                string text;
                if (!FileUtils.get_contents (path, out text)) return;
                var parser = new Json.Parser ();
                parser.load_from_data (text);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;
                var o = root.get_object ();
                if (!o.has_member ("assets")) return;
                foreach (var n in o.get_array_member ("assets").get_elements ()) {
                    var a = Asset.from_json (n);
                    if (a != null) items.add (a);
                }
            } catch (Error e) {
            }
        }

        public void save () throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("format").add_string_value ("singularity-assets");
            b.set_member_name ("version").add_int_value (1);
            b.set_member_name ("assets").begin_array ();
            foreach (var a in items) b.add_value (a.to_json ());
            b.end_array ();
            b.end_object ();
            var gen = new Json.Generator ();
            gen.pretty = true;
            gen.set_root (b.get_root ());
            DirUtils.create_with_parents (Path.get_dirname (path), 0755);
            saving = true;
            try {
                FileUtils.set_contents (path, gen.to_data (null));
            } finally {
                Timeout.add (300, () => {
                    saving = false;
                    return Source.REMOVE;
                });
            }
        }

        public Gee.List<Asset> list (string? kind = null, string? query = null) {
            var r = new Gee.ArrayList<Asset> ();
            string q = query != null ? query.strip ().down () : "";
            foreach (var a in items) {
                if (kind != null && kind != "" && a.kind != kind) continue;
                if (q != "" && !a.name.down ().contains (q) && !a.get_field ("code").down ().contains (q) && !a.get_field ("supplier").down ().contains (q)) continue;
                r.add (a);
            }
            return r;
        }

        public Asset? find (string id) {
            foreach (var a in items) if (a.id == id) return a;
            return null;
        }

        public Asset add (Asset a) throws Error {
            if (a.id == "") a.id = Uuid.string_random ();
            a.modified = get_real_time () / 1000000;
            var existing = find (a.id);
            if (existing != null) items.remove (existing);
            items.add (a);
            save ();
            changed ();
            return a;
        }

        public void update (Asset a) throws Error {
            var existing = find (a.id);
            if (existing != null) {
                a.version = existing.version + 1;
                items.remove (existing);
            }
            a.modified = get_real_time () / 1000000;
            items.add (a);
            save ();
            changed ();
        }

        public bool remove (string id) throws Error {
            var existing = find (id);
            if (existing == null) return false;
            items.remove (existing);
            save ();
            changed ();
            return true;
        }

        public static string drag_text (Asset a) {
            return "singularity-asset:" + a.id;
        }

        public Asset? from_drag_text (string text) {
            if (!text.has_prefix ("singularity-asset:")) return null;
            return find (text.substring ("singularity-asset:".length).strip ());
        }
    }
}
