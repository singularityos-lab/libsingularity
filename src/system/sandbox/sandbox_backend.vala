using GLib;

namespace Singularity.Sandbox {

    [CCode (cname = "SINGULARITY_SYSCONFDIR")]
    extern const string SANDBOX_SYSCONFDIR;
    [CCode (cname = "SINGULARITY_DEFAULT_SANDBOX_BACKENDS")]
    extern const string SANDBOX_DEFAULT_BACKENDS;

    public enum Group {
        FILES,
        NETWORK,
        DEVICES,
        SOCKETS,
        FEATURES,
        SESSION_BUS,
        SYSTEM_BUS,
        ENVIRONMENT;

        public string to_id() {
            switch (this) {
                case FILES: return "files";
                case NETWORK: return "network";
                case DEVICES: return "devices";
                case SOCKETS: return "sockets";
                case FEATURES: return "features";
                case SESSION_BUS: return "session-bus";
                case SYSTEM_BUS: return "system-bus";
                default: return "environment";
            }
        }

        public static Group[] all() {
            return { FILES, NETWORK, DEVICES, SOCKETS, FEATURES, SESSION_BUS, SYSTEM_BUS, ENVIRONMENT };
        }
    }

    public enum Kind {
        TOGGLE,
        FILESYSTEM,
        BUS_POLICY,
        VALUE
    }

    public class Permission : Object {
        public Group group { get; construct; }
        public string key { get; construct; }
        public Kind kind { get; set; default = Kind.TOGGLE; }
        public string label { get; set; default = ""; }
        public string detail { get; set; default = ""; }
        public bool enabled { get; set; default = false; }
        public bool default_enabled { get; set; default = false; }
        public string value { get; set; default = ""; }
        public string default_value { get; set; default = ""; }
        public bool overridden { get; set; default = false; }
        public bool editable { get; set; default = true; }
        public bool revocable { get; set; default = false; }
        public string native_key { get; set; default = ""; }
        public string category { get; set; default = ""; }

        public Permission(Group group, string key) {
            Object(group: group, key: key);
        }

        public string id {
            owned get { return group.to_id() + ":" + key; }
        }

        public bool is_default {
            get { return !overridden; }
        }
    }

    public class App : Object {
        public string backend { get; construct; }
        public string id { get; construct; }
        public string name { get; set; default = ""; }
        public string portal_app_id { get; set; default = ""; }
        public string desktop_id { get; set; default = ""; }
        public string icon_name { get; set; default = ""; }
        public string version { get; set; default = ""; }

        public App(string backend, string id) {
            Object(backend: backend, id: id);
        }

        public string display_name {
            owned get {
                if (desktop_id != "") {
                    var info = new DesktopAppInfo(desktop_id);
                    if (info != null) return info.get_display_name();
                }
                return name != "" ? name : id;
            }
        }

        public Icon? icon {
            owned get {
                if (desktop_id != "") {
                    var info = new DesktopAppInfo(desktop_id);
                    if (info != null && info.get_icon() != null) return info.get_icon();
                }
                if (icon_name != "") {
                    if (Path.is_absolute(icon_name)) return new FileIcon(File.new_for_path(icon_name));
                    return new ThemedIcon(icon_name);
                }
                return new ThemedIcon("application-x-executable");
            }
        }

        public bool matches(string any_id) {
            if (any_id == "") return false;
            string bare = any_id.has_suffix(".desktop") ? any_id.substring(0, any_id.length - 8) : any_id;
            if (bare == id || bare == portal_app_id) return true;
            if (desktop_id != "" && (any_id == desktop_id || bare + ".desktop" == desktop_id)) return true;
            return false;
        }
    }

    public abstract class Backend : Object {
        public abstract string kind { get; }
        public abstract string label { get; }

        public signal void changed(string app_id);

        public abstract bool available();
        public abstract async App[] list_apps();
        public abstract App? app_for_desktop(string desktop_id, KeyFile? entry);
        public abstract async Permission[] permissions(App app);
        public abstract async bool set_enabled(App app, Permission permission, bool enabled);
        public abstract async bool reset(App app, Permission permission);
        public abstract async bool reset_all(App app);

        public virtual string? app_id_for_pid(int pid) {
            return null;
        }

        public virtual async void refresh_runtime() {
        }

        public virtual string[] running_app_ids() {
            return {};
        }

        public async Permission? category_permission(App app, string category) {
            foreach (var permission in yield permissions(app)) {
                if (permission.category == category) return permission;
            }
            return null;
        }

        public virtual async bool has_overrides(App app) {
            foreach (var permission in yield permissions(app)) {
                if (permission.overridden) return true;
            }
            return false;
        }
    }

    public class Config : Object {
        public const string FILE_NAME = "singularity/sandbox.conf";

        public string[] backends { get; set; }
        public string cpak_command { get; set; default = "cpak"; }
        public string flatpak_user_dir { get; set; default = ""; }
        public string flatpak_system_dir { get; set; default = ""; }
        public string? source_path { get; private set; default = null; }

        public Config() {
            backends = parse_backends(SANDBOX_DEFAULT_BACKENDS);
        }

        public static string[] parse_backends(string value) {
            string[] result = {};
            foreach (string part in value.replace(",", ";").split(";")) {
                string name = part.strip().down();
                if (name == "" || name in result) continue;
                if (name == "auto") {
                    foreach (string known in new string[] { "flatpak", "cpak" }) {
                        if (!(known in result)) result += known;
                    }
                    continue;
                }
                if (name == "none") return {};
                result += name;
            }
            return result;
        }

        public static string[] search_dirs() {
            string[] dirs = { Environment.get_user_config_dir() };
            foreach (unowned string dir in Environment.get_system_config_dirs()) dirs += dir;
            dirs += SANDBOX_SYSCONFDIR;
            if (SANDBOX_SYSCONFDIR != "/etc") dirs += "/etc";
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

        public bool load_file(string path) {
            var file = new KeyFile();
            try {
                file.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
                warning("Sandbox: cannot read %s: %s", path, e.message);
                return false;
            }
            source_path = path;
            string listed = read(file, "Sandbox", "Backends", "");
            if (listed != "") backends = parse_backends(listed);
            cpak_command = read(file, "cpak", "Command", cpak_command);
            flatpak_user_dir = read(file, "Flatpak", "UserDir", flatpak_user_dir);
            flatpak_system_dir = read(file, "Flatpak", "SystemDir", flatpak_system_dir);
            return true;
        }

        private static string read(KeyFile file, string group, string key, string fallback) {
            try {
                if (file.has_group(group) && file.has_key(group, key)) {
                    string value = file.get_string(group, key).strip();
                    if (value != "") return value;
                }
            } catch (Error e) {
            }
            return fallback;
        }
    }

    public class Backends : Object {
        private static Backends? _default = null;
        private Backend[] _all = {};
        private App[] _apps = {};
        private bool _loaded = false;

        public signal void changed(string backend, string app_id);

        public static Backends get_default() {
            if (_default == null) _default = new Backends.from_config(Config.load());
            return _default;
        }

        public Backends.from_config(Config config) {
            foreach (string name in config.backends) {
                Backend? backend = create(name, config);
                if (backend != null) add(backend);
            }
        }

        public Backends.with(Backend[] backends) {
            foreach (var backend in backends) add(backend);
        }

        public static Backend? create(string name, Config config) {
            switch (name) {
                case "flatpak": return new FlatpakBackend(config.flatpak_user_dir, config.flatpak_system_dir);
                case "cpak": return new CpakBackend(config.cpak_command);
            }
            return null;
        }

        public void add(Backend backend) {
            _all += backend;
            backend.changed.connect((app_id) => changed(backend.kind, app_id));
        }

        public Backend[] all() {
            return _all;
        }

        public Backend[] enabled() {
            Backend[] result = {};
            foreach (var backend in _all) {
                if (backend.available()) result += backend;
            }
            return result;
        }

        public Backend? find(string kind) {
            foreach (var backend in _all) {
                if (backend.kind == kind) return backend;
            }
            return null;
        }

        public async App[] apps(bool reload = false) {
            if (_loaded && !reload) return _apps;
            App[] found = {};
            foreach (var backend in enabled()) {
                foreach (var app in yield backend.list_apps()) found += app;
            }
            _apps = found;
            _loaded = true;
            return _apps;
        }

        public async App? find_app(string any_id) {
            foreach (var app in yield apps()) {
                if (app.matches(any_id)) return app;
            }
            return null;
        }

        public App? cached_app(string any_id) {
            foreach (var app in _apps) {
                if (app.matches(any_id)) return app;
            }
            return null;
        }

        public async void refresh_runtime() {
            foreach (var backend in enabled()) yield backend.refresh_runtime();
        }

        public App? app_for_desktop(string desktop_id, KeyFile? entry = null) {
            KeyFile? file = entry;
            if (file == null) {
                var info = new DesktopAppInfo(desktop_id);
                if (info != null && info.get_filename() != null) {
                    file = new KeyFile();
                    try {
                        file.load_from_file(info.get_filename(), KeyFileFlags.NONE);
                    } catch (Error e) {
                        file = null;
                    }
                }
            }
            foreach (var backend in enabled()) {
                var app = backend.app_for_desktop(desktop_id, file);
                if (app != null) return app;
            }
            return null;
        }

        public async string? app_id_for_pid(int pid) {
            if (pid <= 0) return null;
            foreach (var backend in enabled()) {
                string? id = backend.app_id_for_pid(pid);
                if (id != null && id != "") return id;
            }
            return null;
        }
    }
}
