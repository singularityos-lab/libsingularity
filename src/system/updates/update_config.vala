using GLib;

namespace Singularity.Updates {

    [CCode (cname = "SINGULARITY_SYSCONFDIR")]
    extern const string UPDATES_SYSCONFDIR;
    [CCode (cname = "SINGULARITY_DEFAULT_UPDATES_BACKEND")]
    extern const string UPDATES_DEFAULT_BACKEND;

    public class Config : Object {
        public const string FILE_NAME = "singularity/updates.conf";
        public const string ATOMIC_BUS_NAME = "dev.sinty.UpdateProvider1";
        public const string ATOMIC_OBJECT_PATH = "/dev/sinty/UpdateProvider1";

        public string backend { get; set; default = "auto"; }
        public string atomic_name { get; set; default = ""; }
        public string atomic_bus { get; set; default = "system"; }
        public string atomic_bus_name { get; set; default = ATOMIC_BUS_NAME; }
        public string atomic_object_path { get; set; default = ATOMIC_OBJECT_PATH; }
        public string? source_path { get; private set; default = null; }

        public Config() {
            backend = normalize_backend(UPDATES_DEFAULT_BACKEND);
        }

        public static string[] search_dirs() {
            string[] dirs = {};
            foreach (unowned string dir in Environment.get_system_config_dirs()) dirs += dir;
            dirs += UPDATES_SYSCONFDIR;
            if (UPDATES_SYSCONFDIR != "/etc") dirs += "/etc";
            return dirs;
        }

        public static Config load() {
            var config = new Config();
            foreach (string dir in search_dirs()) {
                string path = Path.build_filename(dir, FILE_NAME);
                if (FileUtils.test(path, FileTest.IS_REGULAR) && config.load_file(path)) break;
            }
            return config;
        }

        public static string normalize_backend(string value) {
            switch (value.strip().down()) {
                case "packagekit": return "packagekit";
                case "atomic": return "atomic";
                case "none": return "none";
            }
            return "auto";
        }

        public bool load_file(string path) {
            var keyfile = new KeyFile();
            try {
                keyfile.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
                warning("Updates: cannot read %s: %s", path, e.message);
                return false;
            }
            source_path = path;
            backend = normalize_backend(read(keyfile, "Updates", "Backend", backend));
            atomic_name = read(keyfile, "Atomic", "Name", atomic_name);
            atomic_bus = read(keyfile, "Atomic", "Bus", atomic_bus).down() == "session" ? "session" : "system";
            atomic_bus_name = read(keyfile, "Atomic", "BusName", atomic_bus_name);
            atomic_object_path = read(keyfile, "Atomic", "ObjectPath", atomic_object_path);
            if (!Variant.is_object_path(atomic_object_path)) atomic_object_path = ATOMIC_OBJECT_PATH;
            return true;
        }

        private static string read(KeyFile keyfile, string group, string key, string fallback) {
            try {
                if (keyfile.has_group(group) && keyfile.has_key(group, key)) {
                    string value = keyfile.get_string(group, key).strip();
                    if (value != "") return value;
                }
            } catch (Error e) {
                warning("Updates: [%s] %s: %s", group, key, e.message);
            }
            return fallback;
        }

        public BusType atomic_bus_type() {
            return atomic_bus == "session" ? BusType.SESSION : BusType.SYSTEM;
        }
    }

    public class Backend : Object {
        private static Provider? _provider = null;
        private static bool _probing = false;
        private static Gee.ArrayList<SourceFuncWrapper>? _waiters = null;

        private class SourceFuncWrapper {
            public SourceFunc callback;

            public SourceFuncWrapper(owned SourceFunc callback) {
                this.callback = (owned) callback;
            }
        }

        public static Provider? current {
            get { return _provider; }
        }

        public static async Provider get_default() {
            if (_provider != null) return _provider;
            if (_waiters == null) _waiters = new Gee.ArrayList<SourceFuncWrapper>();
            if (_probing) {
                _waiters.add(new SourceFuncWrapper(get_default.callback));
                yield;
                return _provider;
            }
            _probing = true;
            _provider = yield detect(Config.load());
            _probing = false;
            foreach (var waiter in _waiters) Idle.add((owned) waiter.callback);
            _waiters.clear();
            return _provider;
        }

        public static async Provider detect(Config config) {
            if (config.backend == "atomic" || config.backend == "auto") {
                var atomic = new AtomicProvider(config);
                if (yield atomic.probe()) return atomic;
            }
            if (config.backend == "packagekit" || config.backend == "auto") {
                var packagekit = new PackageKitProvider();
                if (yield packagekit.probe()) return packagekit;
            }
            var none = new NoneProvider();
            yield none.probe();
            return none;
        }

        public static async bool service_present(BusType bus_type, string name) {
            try {
                var conn = yield Bus.get(bus_type);
                var owned_reply = yield conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "NameHasOwner", new Variant("(s)", name),
                    new VariantType("(b)"), DBusCallFlags.NONE, 5000, null);
                bool has_owner;
                owned_reply.get("(b)", out has_owner);
                if (has_owner) return true;
                var activatable = yield conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "ListActivatableNames", null,
                    new VariantType("(as)"), DBusCallFlags.NONE, 5000, null);
                var names = activatable.get_child_value(0);
                for (size_t i = 0; i < names.n_children(); i++) {
                    if (names.get_child_value(i).get_string() == name) return true;
                }
            } catch (Error e) {
                debug("Updates: cannot look up %s: %s", name, e.message);
            }
            return false;
        }
    }
}
