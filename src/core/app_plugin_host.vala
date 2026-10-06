using GLib;

namespace Singularity {

    public class AppPluginHost : Object {
        public const string HOST_KEY = "X-Singularity-Host";
        public const string DIR_NAME = "app-plugins";
        public const string COMMON_DIR = "common";

        private Gee.HashMap<string, Gee.ArrayList<Object>> _extensions = new Gee.HashMap<string, Gee.ArrayList<Object>>();
        private Gee.ArrayList<Type> _types = new Gee.ArrayList<Type>();
        private bool _loaded = false;

        public string app_id { get; construct; }
        public string name { get; construct; }
        public GLib.Settings? settings { get; construct; }
        public Peas.Engine engine { get; private set; }

        public signal void extension_added(Peas.PluginInfo info, Object extension);
        public signal void extension_removed(Peas.PluginInfo info, Object extension);
        public signal void plugins_changed();

        public AppPluginHost(string app_id, string name, GLib.Settings? settings) {
            Object(app_id: app_id, name: name, settings: settings);
        }

        construct {
            engine = new Peas.Engine();
            foreach (var d in search_dirs(name)) add_dir(engine, d);
            if (settings != null) {
                settings.changed["enabled-plugins"].connect(() => refresh());
                if (settings.settings_schema.has_key("disabled-plugins"))
                    settings.changed["disabled-plugins"].connect(() => refresh());
            }
        }

        public static GLib.Settings? desktop_settings() {
            var source = SettingsSchemaSource.get_default();
            if (source == null) return null;
            var schema = source.lookup("dev.sinty.desktop", true);
            if (schema == null || !schema.has_key("enabled-plugins")) return null;
            return new GLib.Settings("dev.sinty.desktop");
        }

        private static void add_dir(Peas.Engine engine, string dir) {
            if (!FileUtils.test(dir, FileTest.IS_DIR)) return;
            engine.add_search_path(dir, dir);
            try {
                var d = Dir.open(dir);
                string? entry;
                while ((entry = d.read_name()) != null) {
                    string sub = Path.build_filename(dir, entry);
                    if (FileUtils.test(sub, FileTest.IS_DIR)) engine.add_search_path(sub, sub);
                }
            } catch (FileError e) {
            }
        }

        public static string env_name(string name) {
            return "SINGULARITY_" + name.up().replace("-", "_") + "_PLUGIN_PATH";
        }

        public static string[] base_dirs() {
            string[] dirs = {};
            string? env = Environment.get_variable("SINGULARITY_APP_PLUGIN_PATH");
            if (env != null) foreach (var p in env.split(":")) if (p != "") dirs += p;
            try {
                string exe = FileUtils.read_link("/proc/self/exe");
                string prefix = Path.get_dirname(Path.get_dirname(exe));
                foreach (string libdir in new string[] { "lib", "lib64", "lib/x86_64-linux-gnu", "lib/aarch64-linux-gnu" })
                    dirs += Path.build_filename(prefix, libdir, "singularity", DIR_NAME);
            } catch (FileError e) {
            }
            if (!("/opt/local/lib/singularity/" + DIR_NAME in dirs)) dirs += "/opt/local/lib/singularity/" + DIR_NAME;
            dirs += Path.build_filename(Environment.get_user_data_dir(), "singularity", DIR_NAME);
            return dirs;
        }

        public static string[] search_dirs(string name) {
            string[] dirs = {};
            string? env = Environment.get_variable(env_name(name));
            if (env != null) foreach (var p in env.split(":")) if (p != "") dirs += p;
            foreach (var b in base_dirs()) {
                foreach (string sub in new string[] { name, COMMON_DIR }) {
                    string d = Path.build_filename(b, sub);
                    if (!(d in dirs)) dirs += d;
                }
            }
            return dirs;
        }

        public static string[] hosts_of(Peas.PluginInfo info) {
            string[] hosts = {};
            string? raw = info.get_external_data(HOST_KEY);
            if (raw == null) return hosts;
            foreach (unowned string h in raw.split(";")) {
                if (h.strip() != "") hosts += h.strip();
            }
            return hosts;
        }

        public static bool is_app_plugin(Peas.PluginInfo info) {
            return hosts_of(info).length > 0;
        }

        public static bool is_hosted_by(Peas.PluginInfo info, string app_id) {
            return app_id in hosts_of(info);
        }

        public static Gee.List<Peas.PluginInfo> catalog() {
            var engine = new Peas.Engine();
            foreach (var b in base_dirs()) {
                if (!FileUtils.test(b, FileTest.IS_DIR)) continue;
                try {
                    var d = Dir.open(b);
                    string? entry;
                    while ((entry = d.read_name()) != null) add_dir(engine, Path.build_filename(b, entry));
                } catch (FileError e) {
                }
            }
            engine.rescan_plugins();
            var result = new Gee.ArrayList<Peas.PluginInfo>();
            var seen = new Gee.HashSet<string>();
            var model = (ListModel) engine;
            for (uint i = 0; i < model.get_n_items(); i++) {
                var info = (Peas.PluginInfo) model.get_item(i);
                if (!is_app_plugin(info) || seen.contains(info.get_module_name())) continue;
                seen.add(info.get_module_name());
                result.add(info);
            }
            return result;
        }

        public static bool catalog_enabled(GLib.Settings? settings, Peas.PluginInfo info) {
            if (settings == null) return PluginPreferences.is_app_shipped(info);
            return PluginPreferences.is_enabled(settings, info);
        }

        public void add_extension_type(Type type) {
            if (_types.contains(type)) return;
            _types.add(type);
            if (!_loaded) return;
            var model = (ListModel) engine;
            for (uint i = 0; i < model.get_n_items(); i++) {
                var info = (Peas.PluginInfo) model.get_item(i);
                if (info.is_loaded() && _extensions.has_key(info.get_module_name())) create_extensions(info, type);
            }
        }

        public Gee.List<Peas.PluginInfo> plugins() {
            var result = new Gee.ArrayList<Peas.PluginInfo>();
            var model = (ListModel) engine;
            for (uint i = 0; i < model.get_n_items(); i++) {
                var info = (Peas.PluginInfo) model.get_item(i);
                if (is_hosted_by(info, app_id)) result.add(info);
            }
            return result;
        }

        public bool is_enabled(Peas.PluginInfo info) {
            return catalog_enabled(settings, info);
        }

        public void set_enabled(Peas.PluginInfo info, bool enabled) {
            if (settings != null) PluginPreferences.set_enabled(settings, info, enabled);
            refresh();
        }

        public bool is_active(string module) {
            return _extensions.has_key(module);
        }

        public void load() {
            _loaded = true;
            engine.rescan_plugins();
            refresh();
        }

        public void refresh() {
            if (!_loaded) return;
            bool changed = false;
            foreach (var info in plugins()) {
                string module = info.get_module_name();
                bool want = is_enabled(info);
                bool have = _extensions.has_key(module);
                if (want && !have) {
                    if (activate(info)) changed = true;
                } else if (!want && have) {
                    deactivate(info);
                    changed = true;
                }
            }
            if (changed) plugins_changed();
        }

        private bool activate(Peas.PluginInfo info) {
            PluginPreferences.bind_translations(info);
            if (!info.is_loaded()) engine.load_plugin(info);
            if (!info.is_loaded()) {
                warning("%s: cannot load plugin %s", app_id, info.get_module_name());
                return false;
            }
            _extensions[info.get_module_name()] = new Gee.ArrayList<Object>();
            foreach (var t in _types) create_extensions(info, t);
            return true;
        }

        private void create_extensions(Peas.PluginInfo info, Type type) {
            if (!engine.provides_extension(info, type)) return;
            var list = _extensions[info.get_module_name()];
            foreach (var existing in list) {
                if (existing.get_type().is_a(type)) return;
            }
            var ext = engine.create_extension_with_properties(info, type, {}, {});
            if (ext == null) return;
            list.add(ext);
            extension_added(info, ext);
        }

        private void deactivate(Peas.PluginInfo info) {
            var list = _extensions[info.get_module_name()];
            _extensions.unset(info.get_module_name());
            if (list == null) return;
            foreach (var ext in list) extension_removed(info, ext);
        }

        public Gee.List<Object> extensions(Type type) {
            var result = new Gee.ArrayList<Object>();
            foreach (var list in _extensions.values) {
                foreach (var ext in list) if (ext.get_type().is_a(type)) result.add(ext);
            }
            return result;
        }

        public Peas.PluginInfo? info_for(Object extension) {
            foreach (var e in _extensions.entries) {
                if (e.value.contains(extension)) return engine.get_plugin_info(e.key);
            }
            return null;
        }
    }
}
