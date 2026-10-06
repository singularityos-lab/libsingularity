using GLib;

namespace Singularity {

    /**
     * Global registry of overview widget providers. Anyone (plugins via
     * PluginContext, or the overview itself scanning .widget manifests) can
     * register a provider. The overview subscribes to `changed` to refresh
     * its picker.
     *
     * Manifest format (key-file, suffix .widget, located in
     * $XDG_DATA_DIRS/singularity/widgets/):
     *
     *   [Widget]
     *   Id=music.now-playing
     *   ProviderId=dev.sinty.music
     *   Name=Now Playing
     *   IconName=audio-x-generic-symbolic
     *   Sizes=2x1;2x2
     *   Module=libsingularity-music-widget.so   # optional
     *   ModuleSymbol=singularity_music_widget_new # required if Module set
     *
     * The module exports a single C symbol with signature:
     *     OverviewWidgetProvider* singularity_music_widget_new(void);
     * The registry calls it once at load time. If Module is omitted the
     * manifest is informational only (used by the picker to advertise that
     * the app *would* provide a widget if its module were installed).
     */
    public class OverviewWidgetRegistry : Object {
        private static OverviewWidgetRegistry? _instance = null;
        public static OverviewWidgetRegistry get_default() {
            if (_instance == null) _instance = new OverviewWidgetRegistry();
            return _instance;
        }

        public signal void changed();

        /**
         * Emitted after `save_instance_config` stored a new configuration.
         * The overview rebuilds the instance with it.
         */
        public signal void instance_config_changed(string instance_id, Variant? config);

        /**
         * Emitted by `close_overview`. The shell hides the overview that
         * shows the widgets.
         */
        public signal void close_overview_requested();

        /**
         * Hides the overview, for a widget that opened an app or a view and
         * wants the user to see it. Does nothing outside the shell.
         */
        public void close_overview() {
            close_overview_requested();
        }

        /** Store used by the config methods; set by the host, null elsewhere. */
        public OverviewWidgetConfigStore? config_store { get; set; default = null; }

        /**
         * Returns the saved configuration of a widget instance, or null when
         * there is none or no host store is set.
         */
        public Variant? get_instance_config(string instance_id) {
            return config_store != null ? config_store.load_config(instance_id) : null;
        }

        /**
         * Saves the configuration of a widget instance, typically from
         * OverviewWidgetProvider.configure_instance. The host persists it
         * and passes it back to create_instance from then on.
         *
         * @return false when no host store is set.
         */
        public bool save_instance_config(string instance_id, Variant? config) {
            if (config_store == null) return false;
            config_store.save_config(instance_id, config);
            instance_config_changed(instance_id, config);
            return true;
        }

        private GLib.GenericArray<OverviewWidgetProvider> _providers =
            new GLib.GenericArray<OverviewWidgetProvider>();
        // Modules kept alive for the lifetime of the registry. The factory
        // returns an OverviewWidgetProvider whose vtable lives in the .so,
        // so closing the module would yank the vtable out from under us.
        private GLib.List<GLib.Module> _modules = new GLib.List<GLib.Module>();
        private bool _manifests_loaded = false;

        public void add(OverviewWidgetProvider p) {
            for (int i = 0; i < _providers.length; i++)
                if (_providers[i].id == p.id) return; // dedup
            _providers.add(p);
            changed();
        }

        public void remove(OverviewWidgetProvider p) {
            for (int i = 0; i < _providers.length; i++) {
                if (_providers[i] == p) {
                    _providers.remove_index(i);
                    changed();
                    return;
                }
            }
        }

        public OverviewWidgetProvider? find(string id) {
            for (int i = 0; i < _providers.length; i++)
                if (_providers[i].id == id) return _providers[i];
            return null;
        }

        public OverviewWidgetProvider[] list() {
            var r = new OverviewWidgetProvider[_providers.length];
            for (int i = 0; i < _providers.length; i++) r[i] = _providers[i];
            return r;
        }

        /** Idempotent - call once when the overview starts. */
        public void load_manifests() {
            if (_manifests_loaded) return;
            _manifests_loaded = true;
            foreach (var dir in widget_dirs())
                scan_dir(dir);
        }

        private string[] widget_dirs() {
            var dirs = new GLib.GenericArray<string>();
            dirs.add(Path.build_filename(Environment.get_user_data_dir(),
                                          "singularity", "widgets"));
            foreach (var d in Environment.get_system_data_dirs())
                dirs.add(Path.build_filename(d, "singularity", "widgets"));
            // Singularity's canonical install root.
            dirs.add("/opt/local/share/singularity/widgets");
            var r = new string[dirs.length];
            for (int i = 0; i < dirs.length; i++) r[i] = dirs[i];
            return r;
        }

        private void scan_dir(string dir) {
            var d = File.new_for_path(dir);
            if (!d.query_exists()) return;
            try {
                var enumerator = d.enumerate_children("standard::name",
                    FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = enumerator.next_file()) != null) {
                    string name = info.get_name();
                    if (!name.has_suffix(".widget")) continue;
                    load_manifest(Path.build_filename(dir, name));
                }
            } catch (Error e) {
                warning("OverviewWidgetRegistry: scan_dir %s: %s", dir, e.message);
            }
        }

        private void load_manifest(string path) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
                if (!kf.has_group("Widget")) return;
                string module = kf.has_key("Widget", "Module")
                    ? kf.get_string("Widget", "Module") : "";
                if (module == "") return; // manifest-only entries are TODO

                string symbol = kf.has_key("Widget", "ModuleSymbol")
                    ? kf.get_string("Widget", "ModuleSymbol") : "";
                if (symbol == "") {
                    warning("Widget manifest %s: Module set but ModuleSymbol missing", path);
                    return;
                }

                // Resolve module path: if relative, try same dir, then standard libdirs.
                string mod_path = resolve_module(path, module);
                if (mod_path == null) {
                    warning("Widget manifest %s: cannot find module %s", path, module);
                    return;
                }

                var mod = Module.open(mod_path, ModuleFlags.LAZY);
                if (mod == null) {
                    warning("Widget manifest %s: dlopen failed: %s", path, Module.error());
                    return;
                }
                void* sym;
                if (!mod.symbol(symbol, out sym) || sym == null) {
                    warning("Widget manifest %s: symbol %s not found", path, symbol);
                    return;
                }

                // Cast the C symbol to a function returning a GObject ref.
                // The function must return a new ref to an OverviewWidgetProvider.
                var factory = (WidgetFactoryFunc) sym;
                Object obj = factory();
                var provider = obj as OverviewWidgetProvider;
                if (provider == null) {
                    warning("Widget manifest %s: factory did not return an OverviewWidgetProvider", path);
                    return;
                }

                // Keep the module alive for the life of the registry.
                _modules.prepend((owned) mod);
                add(provider);
            } catch (Error e) {
                warning("Widget manifest %s: parse error: %s", path, e.message);
            }
        }

        private string? resolve_module(string manifest_path, string module) {
            if (Path.is_absolute(module) &&
                FileUtils.test(module, FileTest.EXISTS))
                return module;
            string dir = Path.get_dirname(manifest_path);
            string cand = Path.build_filename(dir, module);
            if (FileUtils.test(cand, FileTest.EXISTS)) return cand;
            // Common install layouts.
            string[] roots = {
                "/usr/lib/singularity/widgets",
                "/usr/lib64/singularity/widgets",
                "/usr/local/lib/singularity/widgets",
                "/opt/local/lib/singularity/widgets",
                "/opt/local/lib64/singularity/widgets",
                Path.build_filename(Environment.get_user_data_dir(),
                    "singularity", "widgets")
            };
            foreach (var r in multiarch_widget_dirs({ "/usr/lib", "/usr/local/lib", "/opt/local/lib" })) roots += r;
            foreach (var r in roots) {
                cand = Path.build_filename(r, module);
                if (FileUtils.test(cand, FileTest.EXISTS)) return cand;
            }
            return null;
        }
    }

    /**
     * The `<libdir>/<multiarch triplet>/singularity/widgets` directories that
     * exist under `libdirs`, such as `/usr/lib/x86_64-linux-gnu/singularity/widgets`.
     */
    public string[] multiarch_widget_dirs(string[] libdirs) {
        string[] found = {};
        foreach (var libdir in libdirs) {
            Dir d;
            try {
                d = Dir.open(libdir, 0);
            } catch (FileError e) {
                continue;
            }
            string? name;
            var names = new GenericArray<string>();
            while ((name = d.read_name()) != null) {
                if (name.contains("-linux-")) names.add(name);
            }
            names.sort(strcmp);
            foreach (var triplet in names.data) {
                string path = Path.build_filename(libdir, triplet, "singularity", "widgets");
                if (FileUtils.test(path, FileTest.IS_DIR)) found += path;
            }
        }
        return found;
    }

    [CCode (has_target = false)]
    public delegate Object WidgetFactoryFunc();

    /**
     * Where the host keeps the configuration of each overview widget
     * instance. The shell sets one on OverviewWidgetRegistry.config_store.
     */
    public interface OverviewWidgetConfigStore : Object {
        /** Returns the saved configuration of `instance_id`, or null. */
        public abstract Variant? load_config(string instance_id);
        /** Saves the configuration of `instance_id`; null clears it. */
        public abstract void save_config(string instance_id, Variant? config);
    }

    /**
     * Global registry of search providers. Same shape as
     * OverviewWidgetRegistry. Plugins or first-party code register here;
     * the overview's search bar subscribes to `changed` and re-fans each
     * keystroke out to all providers concurrently.
     */
    public class SearchProviderRegistry : Object {
        private static SearchProviderRegistry? _instance = null;
        public static SearchProviderRegistry get_default() {
            if (_instance == null) _instance = new SearchProviderRegistry();
            return _instance;
        }

        public signal void added(SearchProvider provider);
        public signal void removed(SearchProvider provider);

        private GLib.GenericArray<SearchProvider> _providers =
            new GLib.GenericArray<SearchProvider>();

        public void add(SearchProvider p) {
            for (int i = 0; i < _providers.length; i++)
                if (_providers[i].id == p.id) return;
            _providers.add(p);
            added(p);
        }
        public void remove(SearchProvider p) {
            for (int i = 0; i < _providers.length; i++) {
                if (_providers[i] == p) {
                    _providers.remove_index(i);
                    removed(p);
                    return;
                }
            }
        }
        public SearchProvider[] list() {
            var r = new SearchProvider[_providers.length];
            for (int i = 0; i < _providers.length; i++) r[i] = _providers[i];
            return r;
        }
    }
}
