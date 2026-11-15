using GLib;

namespace Singularity {

    public enum WatchFaceOptionKind {
        CHOICE,
        COLOR,
        TOGGLE
    }

    public enum WatchFaceRefresh {
        MINUTE,
        SECOND,
        CONTINUOUS
    }

    public class WatchFaceOption : Object {
        public string key { get; construct; }
        public string label { get; construct; }
        public WatchFaceOptionKind kind { get; construct; }
        public string default_value { get; construct; }
        private string[] _values = {};
        private string[] _labels = {};

        private WatchFaceOption(string key, string label, WatchFaceOptionKind kind, string default_value) {
            Object(key: key, label: label, kind: kind, default_value: default_value);
        }

        public static WatchFaceOption choice(string key, string label, string[] values, string[] labels, string default_value) {
            var option = new WatchFaceOption(key, label, WatchFaceOptionKind.CHOICE, default_value);
            option._values = values;
            option._labels = labels;
            return option;
        }

        public static WatchFaceOption colors(string key, string label, string[] values, string[] labels, string default_value) {
            var option = new WatchFaceOption(key, label, WatchFaceOptionKind.COLOR, default_value);
            option._values = values;
            option._labels = labels;
            return option;
        }

        public static WatchFaceOption toggle(string key, string label, bool default_value) {
            return new WatchFaceOption(key, label, WatchFaceOptionKind.TOGGLE, default_value ? "true" : "false");
        }

        public string[] get_values() {
            return _values;
        }

        public string[] get_labels() {
            return _labels;
        }
    }

    public class WatchFaceFrame : Object {
        public int width { get; set; }
        public int height { get; set; }
        public DateTime time { get; set; }
        public double seconds { get; set; }
        public double battery { get; set; default = -1.0; }
        public bool charging { get; set; default = false; }
        public uint notifications { get; set; default = 0; }
        public Cairo.ImageSurface? wallpaper { get; set; default = null; }
        public double elapsed { get; set; default = 0.0; }
        private HashTable<string, string> _values = new HashTable<string, string>(str_hash, str_equal);

        public WatchFaceFrame() {
            time = new DateTime.now_local();
        }

        public void set_value(string key, string value) {
            _values.insert(key, value);
        }

        public string get_value(string key, string fallback) {
            return _values.lookup(key) ?? fallback;
        }

        public bool get_flag(string key, bool fallback) {
            string? v = _values.lookup(key);
            return v == null ? fallback : v == "true";
        }

        public Gdk.RGBA get_color(string key, string fallback) {
            var color = Gdk.RGBA();
            if (!color.parse(get_value(key, fallback))) color.parse(fallback);
            return color;
        }

        public double size {
            get { return double.min(width, height); }
        }
    }

    public abstract class WatchFaceProvider : Object {
        public abstract string id { get; }
        public abstract string name { get; }

        public virtual WatchFaceOption[] get_options() {
            return {};
        }

        public virtual WatchFaceRefresh get_refresh(WatchFaceFrame frame) {
            return WatchFaceRefresh.MINUTE;
        }

        public abstract void draw(Cairo.Context cr, WatchFaceFrame frame);
    }

    [CCode (has_target = false)]
    public delegate Object WatchFaceFactoryFunc();

    public class WatchFaceRegistry : Object {
        private static WatchFaceRegistry? _instance = null;
        private GenericArray<WatchFaceProvider> _providers = new GenericArray<WatchFaceProvider>();
        private List<Module> _modules = new List<Module>();
        private bool _manifests_loaded = false;

        public signal void changed();

        public static WatchFaceRegistry get_default() {
            if (_instance == null) {
                _instance = new WatchFaceRegistry();
                WatchFaces.register_builtin(_instance);
            }
            return _instance;
        }

        public void add(WatchFaceProvider provider) {
            for (int i = 0; i < _providers.length; i++) {
                if (_providers[i].id == provider.id) return;
            }
            _providers.add(provider);
            changed();
        }

        public void remove(WatchFaceProvider provider) {
            for (int i = 0; i < _providers.length; i++) {
                if (_providers[i] != provider) continue;
                _providers.remove_index(i);
                changed();
                return;
            }
        }

        public WatchFaceProvider? find(string id) {
            for (int i = 0; i < _providers.length; i++) {
                if (_providers[i].id == id) return _providers[i];
            }
            return null;
        }

        public WatchFaceProvider[] list() {
            var result = new WatchFaceProvider[_providers.length];
            for (int i = 0; i < _providers.length; i++) result[i] = _providers[i];
            return result;
        }

        public int index_of(string id) {
            for (int i = 0; i < _providers.length; i++) {
                if (_providers[i].id == id) return i;
            }
            return -1;
        }

        public void load_manifests() {
            if (_manifests_loaded) return;
            _manifests_loaded = true;
            var dirs = new GenericArray<string>();
            dirs.add(Path.build_filename(Environment.get_user_data_dir(), "singularity", "watchfaces"));
            foreach (var d in Environment.get_system_data_dirs()) dirs.add(Path.build_filename(d, "singularity", "watchfaces"));
            dirs.add("/opt/local/share/singularity/watchfaces");
            foreach (var dir in dirs.data) scan_dir(dir);
        }

        private void scan_dir(string dir) {
            var d = File.new_for_path(dir);
            if (!d.query_exists()) return;
            try {
                var enumerator = d.enumerate_children("standard::name", FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = enumerator.next_file()) != null) {
                    if (info.get_name().has_suffix(".watchface")) load_manifest(Path.build_filename(dir, info.get_name()));
                }
            } catch (Error e) {
                warning("WatchFaceRegistry: scan %s: %s", dir, e.message);
            }
        }

        private void load_manifest(string path) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
                if (!kf.has_group("Watch Face")) return;
                string module = kf.get_string("Watch Face", "Module");
                string symbol = kf.get_string("Watch Face", "ModuleSymbol");
                string? mod_path = resolve_module(path, module);
                if (mod_path == null) {
                    warning("Watch face %s: cannot find module %s", path, module);
                    return;
                }
                var mod = Module.open(mod_path, ModuleFlags.LAZY);
                if (mod == null) {
                    warning("Watch face %s: %s", path, Module.error());
                    return;
                }
                void* sym;
                if (!mod.symbol(symbol, out sym) || sym == null) {
                    warning("Watch face %s: symbol %s not found", path, symbol);
                    return;
                }
                var factory = (WatchFaceFactoryFunc) sym;
                var provider = factory() as WatchFaceProvider;
                if (provider == null) {
                    warning("Watch face %s: factory did not return a WatchFaceProvider", path);
                    return;
                }
                _modules.prepend((owned) mod);
                add(provider);
            } catch (Error e) {
                warning("Watch face %s: %s", path, e.message);
            }
        }

        private string? resolve_module(string manifest_path, string module) {
            if (Path.is_absolute(module)) return FileUtils.test(module, FileTest.EXISTS) ? module : null;
            string[] roots = { Path.get_dirname(manifest_path), "/usr/lib/singularity/watchfaces", "/usr/lib64/singularity/watchfaces",
                "/usr/local/lib/singularity/watchfaces", "/opt/local/lib/singularity/watchfaces", "/opt/local/lib64/singularity/watchfaces" };
            foreach (var root in roots) {
                string candidate = Path.build_filename(root, module);
                if (FileUtils.test(candidate, FileTest.EXISTS)) return candidate;
            }
            return null;
        }
    }

    public class WatchFaceStore : Object {
        public const string DEFAULT_FACE = "dev.sinty.watch.meridian";
        private const string CURRENT_GROUP = "Watch";
        private static WatchFaceStore? _instance = null;
        private KeyFile _kf = new KeyFile();
        private string _path;

        public signal void changed(string face_id);
        public signal void current_changed();

        public static WatchFaceStore get_default() {
            if (_instance == null) _instance = new WatchFaceStore();
            return _instance;
        }

        private WatchFaceStore() {
            _path = Path.build_filename(Environment.get_user_config_dir(), "singularity", "watch-faces.ini");
            try {
                _kf.load_from_file(_path, KeyFileFlags.NONE);
            } catch (Error e) {
                _kf = new KeyFile();
            }
        }

        public string current {
            owned get {
                try {
                    string id = _kf.get_string(CURRENT_GROUP, "face");
                    if (WatchFaceRegistry.get_default().find(id) != null) return id;
                } catch (Error e) {
                }
                return DEFAULT_FACE;
            }
            set {
                if (value == current) return;
                _kf.set_string(CURRENT_GROUP, "face", value);
                save();
                current_changed();
            }
        }

        public string get_value(WatchFaceProvider face, WatchFaceOption option) {
            try {
                return _kf.get_string(face.id, option.key);
            } catch (Error e) {
                return option.default_value;
            }
        }

        public void set_value(WatchFaceProvider face, string key, string value) {
            _kf.set_string(face.id, key, value);
            save();
            changed(face.id);
        }

        public void fill(WatchFaceProvider face, WatchFaceFrame frame) {
            foreach (var option in face.get_options()) frame.set_value(option.key, get_value(face, option));
        }

        private void save() {
            try {
                DirUtils.create_with_parents(Path.get_dirname(_path), 0755);
                _kf.save_to_file(_path);
            } catch (Error e) {
                warning("WatchFaceStore: %s", e.message);
            }
        }
    }
}
