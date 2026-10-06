using GLib;

namespace Singularity.Sandbox {

    public class FlatpakContext : Object {
        public Gee.HashMap<string, string> tokens = new Gee.HashMap<string, string>();
        public Gee.HashMap<string, string> session_bus = new Gee.HashMap<string, string>();
        public Gee.HashMap<string, string> system_bus = new Gee.HashMap<string, string>();
        public Gee.HashMap<string, string> environment = new Gee.HashMap<string, string>();

        public static string[] context_keys() {
            return { "shared", "sockets", "devices", "features", "filesystems" };
        }

        public static string[] parse_list(string value) {
            string[] items = {};
            foreach (string part in value.split(";")) {
                string item = part.strip();
                if (item != "") items += item;
            }
            return items;
        }

        public static string name_of(string item) {
            string name = item.has_prefix("!") ? item.substring(1) : item;
            foreach (string mode in new string[] { ":ro", ":rw", ":create" }) {
                if (name.has_suffix(mode)) return name.substring(0, name.length - mode.length);
            }
            return name;
        }

        public static string token_key(string context_key, string name) {
            return context_key + "/" + name;
        }

        public void merge_file(string path) {
            var file = new KeyFile();
            try {
                file.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
                return;
            }
            merge(file);
        }

        public void merge(KeyFile file) {
            foreach (string key in context_keys()) {
                string raw = "";
                try {
                    raw = file.get_string("Context", key);
                } catch (Error e) {
                    continue;
                }
                foreach (string item in parse_list(raw)) {
                    string name = name_of(item);
                    if (item.has_prefix("!")) tokens[token_key(key, name)] = "!";
                    else tokens[token_key(key, name)] = item;
                }
            }
            merge_group(file, "Session Bus Policy", session_bus);
            merge_group(file, "System Bus Policy", system_bus);
            merge_group(file, "Environment", environment);
        }

        private static void merge_group(KeyFile file, string group, Gee.HashMap<string, string> into) {
            if (!file.has_group(group)) return;
            try {
                foreach (string key in file.get_keys(group)) into[key] = file.get_string(group, key).strip();
            } catch (Error e) {
            }
        }

        public bool has(string context_key, string name) {
            string? value = tokens[token_key(context_key, name)];
            return value != null && value != "!";
        }

        public string? raw(string context_key, string name) {
            return tokens[token_key(context_key, name)];
        }

        public string[] names(string context_key) {
            string[] result = {};
            string prefix = context_key + "/";
            foreach (string key in tokens.keys) {
                if (key.has_prefix(prefix)) result += key.substring(prefix.length);
            }
            return result;
        }
    }

    public class FlatpakBackend : Backend {
        private string _user_dir;
        private string _system_dir;

        public override string kind {
            get { return "flatpak"; }
        }

        public override string label {
            get { return "Flatpak"; }
        }

        public FlatpakBackend(string user_dir = "", string system_dir = "") {
            _user_dir = user_dir;
            _system_dir = system_dir;
        }

        public string user_dir {
            owned get {
                if (_user_dir != "") return _user_dir;
                string? env = Environment.get_variable("FLATPAK_USER_DIR");
                return env != null && env != "" ? env : Path.build_filename(Environment.get_user_data_dir(), "flatpak");
            }
        }

        public string system_dir {
            owned get {
                if (_system_dir != "") return _system_dir;
                string? env = Environment.get_variable("FLATPAK_SYSTEM_DIR");
                return env != null && env != "" ? env : "/var/lib/flatpak";
            }
        }

        public override bool available() {
            foreach (string root in new string[] { user_dir, system_dir }) {
                if (FileUtils.test(Path.build_filename(root, "app"), FileTest.IS_DIR)) return true;
            }
            return false;
        }

        public string? metadata_path(string app_id) {
            foreach (string root in new string[] { user_dir, system_dir }) {
                string path = Path.build_filename(root, "app", app_id, "current", "active", "metadata");
                if (FileUtils.test(path, FileTest.EXISTS)) return path;
            }
            return null;
        }

        public string override_path(string app_id) {
            return Path.build_filename(user_dir, "overrides", app_id);
        }

        public override async App[] list_apps() {
            App[] apps = {};
            string[] seen = {};
            foreach (string root in new string[] { user_dir, system_dir }) {
                try {
                    var directory = Dir.open(Path.build_filename(root, "app"));
                    string? name;
                    while ((name = directory.read_name()) != null) {
                        if (name in seen || metadata_path(name) == null) continue;
                        seen += name;
                        apps += make_app(name);
                    }
                } catch (FileError e) {
                }
            }
            return apps;
        }

        private App make_app(string app_id) {
            var app = new App(kind, app_id);
            app.portal_app_id = app_id;
            app.desktop_id = app_id + ".desktop";
            app.icon_name = app_id;
            app.name = app_id;
            return app;
        }

        public override App? app_for_desktop(string desktop_id, KeyFile? entry) {
            string? app_id = null;
            if (entry != null) {
                try {
                    app_id = entry.get_string("Desktop Entry", "X-Flatpak").strip();
                } catch (Error e) {
                    app_id = null;
                }
            }
            if (app_id == null || app_id == "") {
                app_id = desktop_id.has_suffix(".desktop") ? desktop_id.substring(0, desktop_id.length - 8) : desktop_id;
            }
            if (metadata_path(app_id) == null) return null;
            var app = make_app(app_id);
            app.desktop_id = desktop_id.has_suffix(".desktop") ? desktop_id : desktop_id + ".desktop";
            return app;
        }

        public FlatpakContext defaults(string app_id) {
            var context = new FlatpakContext();
            string? metadata = metadata_path(app_id);
            if (metadata != null) context.merge_file(metadata);
            context.merge_file(Path.build_filename(system_dir, "overrides", "global"));
            context.merge_file(Path.build_filename(system_dir, "overrides", app_id));
            context.merge_file(Path.build_filename(user_dir, "overrides", "global"));
            return context;
        }

        public FlatpakContext user_override(string app_id) {
            var context = new FlatpakContext();
            context.merge_file(override_path(app_id));
            return context;
        }

        public override async Permission[] permissions(App app) {
            return build(defaults(app.id), user_override(app.id));
        }

        public static Permission[] build(FlatpakContext base_context, FlatpakContext user) {
            Permission[] result = {};
            foreach (var entry in Catalog.toggles()) {
                result += toggle(entry.group, entry.context_key, entry.key, base_context, user);
            }
            foreach (string context_key in new string[] { "shared", "sockets", "devices", "features" }) {
                Group group = Catalog.group_for(context_key);
                string[] names = base_context.names(context_key);
                foreach (string name in user.names(context_key)) {
                    if (!(name in names)) names += name;
                }
                foreach (string name in names) {
                    if (Catalog.is_known(context_key, name)) continue;
                    result += toggle(group, context_key, name, base_context, user);
                }
            }
            string[] filesystems = {};
            foreach (string name in Catalog.standard_filesystems()) filesystems += name;
            foreach (string name in base_context.names("filesystems")) {
                if (!(name in filesystems)) filesystems += name;
            }
            foreach (string name in user.names("filesystems")) {
                if (!(name in filesystems)) filesystems += name;
            }
            foreach (string name in filesystems) {
                string? before = base_context.raw("filesystems", name);
                string? mine = user.raw("filesystems", name);
                if (before == null && mine == null && !(name in Catalog.standard_filesystems())) continue;
                var permission = new Permission(Group.FILES, name);
                permission.kind = Kind.FILESYSTEM;
                permission.default_enabled = before != null && before != "!";
                permission.default_value = permission.default_enabled ? before : "";
                string effective = mine ?? before ?? "";
                permission.enabled = effective != "" && effective != "!";
                permission.value = permission.enabled ? effective : "";
                permission.overridden = mine != null;
                permission.label = Catalog.describe_filesystem(permission.enabled ? effective : name);
                permission.detail = name;
                result += permission;
            }
            result = append_bus(result, Group.SESSION_BUS, base_context.session_bus, user.session_bus);
            result = append_bus(result, Group.SYSTEM_BUS, base_context.system_bus, user.system_bus);
            string[] vars = {};
            foreach (string name in base_context.environment.keys) vars += name;
            foreach (string name in user.environment.keys) {
                if (!(name in vars)) vars += name;
            }
            foreach (string name in vars) {
                var permission = new Permission(Group.ENVIRONMENT, name);
                permission.kind = Kind.VALUE;
                permission.editable = false;
                permission.default_value = base_context.environment[name] ?? "";
                permission.overridden = user.environment.has_key(name);
                permission.value = permission.overridden ? user.environment[name] : permission.default_value;
                permission.enabled = permission.value != "";
                permission.default_enabled = permission.default_value != "";
                permission.label = name;
                permission.detail = permission.value;
                result += permission;
            }
            return result;
        }

        private static Permission[] append_bus(Permission[] list, Group group, Gee.HashMap<string, string> before,
                                               Gee.HashMap<string, string> mine) {
            Permission[] result = list;
            string[] names = {};
            foreach (string name in before.keys) names += name;
            foreach (string name in mine.keys) {
                if (!(name in names)) names += name;
            }
            foreach (string name in names) {
                var permission = new Permission(group, name);
                permission.kind = Kind.BUS_POLICY;
                permission.default_value = before[name] ?? "none";
                permission.default_enabled = permission.default_value != "none";
                permission.overridden = mine.has_key(name);
                permission.value = permission.overridden ? mine[name] : permission.default_value;
                permission.enabled = permission.value != "none";
                permission.label = name;
                permission.detail = permission.value;
                result += permission;
            }
            return result;
        }

        private static Permission toggle(Group group, string context_key, string key, FlatpakContext before,
                                         FlatpakContext user) {
            var permission = new Permission(group, key);
            permission.default_enabled = before.has(context_key, key);
            string? mine = user.raw(context_key, key);
            permission.overridden = mine != null;
            permission.enabled = mine != null ? mine != "!" : permission.default_enabled;
            permission.label = Catalog.label(context_key, key);
            permission.detail = Catalog.detail(context_key, key);
            permission.native_key = context_key;
            if (context_key == "devices" && key == "all") permission.category = "camera";
            return permission;
        }

        public override async bool set_enabled(App app, Permission permission, bool enabled) {
            bool ok = write(app.id, permission, enabled, false);
            if (ok) changed(app.id);
            return ok;
        }

        public override async bool reset(App app, Permission permission) {
            bool ok = write(app.id, permission, permission.default_enabled, true);
            if (ok) changed(app.id);
            return ok;
        }

        public override async bool reset_all(App app) {
            string path = override_path(app.id);
            if (FileUtils.test(path, FileTest.EXISTS) && FileUtils.unlink(path) != 0) return false;
            changed(app.id);
            return true;
        }

        public bool write(string app_id, Permission permission, bool enabled, bool clear) {
            string path = override_path(app_id);
            var file = new KeyFile();
            try {
                file.load_from_file(path, KeyFileFlags.KEEP_COMMENTS);
            } catch (Error e) {
            }
            bool matches_default = enabled == permission.default_enabled;
            switch (permission.kind) {
                case Kind.TOGGLE:
                case Kind.FILESYSTEM:
                    string context_key = permission.kind == Kind.FILESYSTEM ? "filesystems"
                        : Catalog.context_key_for(permission.group);
                    string[] current = {};
                    try {
                        current = FlatpakContext.parse_list(file.get_string("Context", context_key));
                    } catch (Error e) {
                    }
                    string[] next = {};
                    foreach (string item in current) {
                        if (FlatpakContext.name_of(item) != permission.key) next += item;
                    }
                    if (!clear && !matches_default) {
                        if (!enabled) next += "!" + permission.key;
                        else if (permission.kind == Kind.FILESYSTEM && permission.default_value != "") next += permission.default_value;
                        else next += permission.key;
                    }
                    if (next.length == 0) {
                        try {
                            file.remove_key("Context", context_key);
                        } catch (Error e) {
                        }
                    } else {
                        file.set_string("Context", context_key, string.joinv(";", next) + ";");
                    }
                    break;
                case Kind.BUS_POLICY:
                    string group = permission.group == Group.SYSTEM_BUS ? "System Bus Policy" : "Session Bus Policy";
                    if (clear || matches_default) {
                        try {
                            file.remove_key(group, permission.key);
                        } catch (Error e) {
                        }
                    } else {
                        string policy = permission.default_enabled ? permission.default_value : "talk";
                        file.set_string(group, permission.key, enabled ? policy : "none");
                    }
                    break;
                default:
                    if (!clear) return false;
                    try {
                        file.remove_key("Environment", permission.key);
                    } catch (Error e) {
                    }
                    break;
            }
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0755);
                return FileUtils.set_contents(path, file.to_data());
            } catch (Error e) {
                warning("Sandbox: cannot write %s: %s", path, e.message);
                return false;
            }
        }

        public override string? app_id_for_pid(int pid) {
            string contents;
            try {
                FileUtils.get_contents("/proc/%d/cgroup".printf(pid), out contents);
            } catch (Error e) {
                return null;
            }
            return app_id_from_cgroup(contents);
        }

        public static string? app_id_from_cgroup(string contents) {
            foreach (string line in contents.split("\n")) {
                int start = line.index_of("app-flatpak-");
                if (start < 0) continue;
                string unit = line.substring(start + 12);
                int slash = unit.index_of("/");
                if (slash >= 0) unit = unit.substring(0, slash);
                if (unit.has_suffix(".scope")) unit = unit.substring(0, unit.length - 6);
                int dash = unit.last_index_of("-");
                if (dash > 0) return unit.substring(0, dash);
            }
            return null;
        }
    }
}
