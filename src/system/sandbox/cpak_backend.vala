using GLib;

namespace Singularity.Sandbox {

    public class CpakToggle {
        public string native;
        public Group group;
        public string key;
        public string category;
        public bool legacy;

        public CpakToggle(string native, Group group, string key, string category = "", bool legacy = false) {
            this.native = native;
            this.group = group;
            this.key = key;
            this.category = category;
            this.legacy = legacy;
        }
    }

    public class OrderedMap : Object {
        private Gee.ArrayList<string> _keys = new Gee.ArrayList<string>();
        private Gee.HashMap<string, string> _values = new Gee.HashMap<string, string>();

        public new string? get(string key) {
            return _values[key];
        }

        public new void set(string key, string value) {
            if (!_values.has_key(key)) _keys.add(key);
            _values[key] = value;
        }

        public bool has_key(string key) {
            return _values.has_key(key);
        }

        public string[] keys {
            owned get { return _keys.to_array(); }
        }
    }

    public class CpakRecord : Object {
        public string origin = "";
        public string version = "";
        public string name = "";
        public string cpak_id = "";
        public string[] desktop_ids = {};
        public Json.Object declared = new Json.Object();
    }

    public class CpakGrant : Object {
        public string id = "";
        public string selection = "";
        public string kind = "";
        public string access = "";
        public string lifetime = "";
    }

    public class CpakBackend : Backend {
        private string[] _command;
        private string _command_line;
        private Gee.HashMap<string, CpakRecord> _records = new Gee.HashMap<string, CpakRecord>();
        private Gee.HashMap<int, string> _running = new Gee.HashMap<int, string>();
        private Gee.HashMap<string, Gee.ArrayList<CpakGrant>> _grants = new Gee.HashMap<string, Gee.ArrayList<CpakGrant>>();
        private Gee.HashMap<string, int64?> _grants_time = new Gee.HashMap<string, int64?>();

        public const int64 GRANTS_TTL = 10 * TimeSpan.SECOND;

        public override string kind {
            get { return "cpak"; }
        }

        public override string label {
            get { return "cpak"; }
        }

        public CpakBackend(string command = "cpak") {
            _command_line = command;
            try {
                Shell.parse_argv(command, out _command);
            } catch (ShellError e) {
                _command = { "cpak" };
            }
        }

        public static CpakToggle[] toggles() {
            return {
                new CpakToggle("network", Group.NETWORK, "network"),
                new CpakToggle("hostNetwork", Group.NETWORK, "host-network"),
                new CpakToggle("deviceVideo", Group.DEVICES, "camera", "camera"),
                new CpakToggle("deviceDri", Group.DEVICES, "dri"),
                new CpakToggle("deviceInput", Group.DEVICES, "input"),
                new CpakToggle("deviceUsb", Group.DEVICES, "usb"),
                new CpakToggle("deviceAlsa", Group.DEVICES, "alsa"),
                new CpakToggle("deviceSerial", Group.DEVICES, "serial"),
                new CpakToggle("deviceKvm", Group.DEVICES, "kvm"),
                new CpakToggle("deviceFuse", Group.DEVICES, "fuse"),
                new CpakToggle("deviceTun", Group.DEVICES, "tun"),
                new CpakToggle("deviceShm", Group.DEVICES, "shm"),
                new CpakToggle("deviceTTY", Group.DEVICES, "tty"),
                new CpakToggle("deviceAll", Group.DEVICES, "all"),
                new CpakToggle("socketWayland", Group.SOCKETS, "wayland"),
                new CpakToggle("displayX11", Group.SOCKETS, "x11"),
                new CpakToggle("socketX11", Group.SOCKETS, "x11-socket", "", true),
                new CpakToggle("socketPulseAudio", Group.SOCKETS, "pulseaudio", "microphone"),
                new CpakToggle("socketCups", Group.SOCKETS, "cups"),
                new CpakToggle("socketSshAgent", Group.SOCKETS, "ssh-auth"),
                new CpakToggle("socketGpgAgent", Group.SOCKETS, "gpg-agent"),
                new CpakToggle("socketAtSpiBus", Group.SOCKETS, "at-spi"),
                new CpakToggle("socketSessionBus", Group.SOCKETS, "session-bus", "", true),
                new CpakToggle("socketSystemBus", Group.SOCKETS, "system-bus", "", true),
                new CpakToggle("notification", Group.FEATURES, "notifications", "notifications"),
                new CpakToggle("openURI", Group.FEATURES, "open-uri"),
                new CpakToggle("bluetooth", Group.FEATURES, "bluetooth"),
                new CpakToggle("socketBluetooth", Group.FEATURES, "bluetooth-socket", "", true),
                new CpakToggle("hostApplications", Group.FEATURES, "host-apps"),
                new CpakToggle("process", Group.FEATURES, "host-processes"),
                new CpakToggle("userNamespaces", Group.FEATURES, "user-namespaces"),
                new CpakToggle("asRoot", Group.FEATURES, "as-root"),
                new CpakToggle("fsHost", Group.FILES, "host", "", true),
                new CpakToggle("fsHostHome", Group.FILES, "home-legacy", "", true),
                new CpakToggle("fsHostEtc", Group.FILES, "host-etc", "", true)
            };
        }

        public static string toggle_label(string key) {
            switch (key) {
                case "host-network": return _("Host Network");
                case "alsa": return _("Sound Cards");
                case "serial": return _("Serial Ports");
                case "fuse": return _("Mount File Systems");
                case "tun": return _("VPN Tunnels");
                case "tty": return _("Terminals");
                case "x11-socket": return _("X11 Socket");
                case "at-spi": return _("Accessibility Bus");
                case "notifications": return _("Notifications");
                case "open-uri": return _("Open Links and Files in Other Apps");
                case "bluetooth-socket": return _("Bluetooth Socket");
                case "host-apps": return _("Start Other Apps");
                case "host-processes": return _("See Other Processes");
                case "user-namespaces": return _("Nested Sandboxes");
                case "as-root": return _("Run as Administrator Inside the Sandbox");
                case "home-legacy": return _("Home Folder");
            }
            return Catalog.label("", key);
        }

        public override bool available() {
            if (_command.length == 0) return false;
            return Path.is_absolute(_command[0]) ? FileUtils.test(_command[0], FileTest.IS_EXECUTABLE)
                : Environment.find_program_in_path(_command[0]) != null;
        }

        private async string? run(string[] args, out int status) {
            status = -1;
            string[] argv = {};
            foreach (string part in _command) argv += part;
            foreach (string part in args) argv += part;
            try {
                var process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                string? stdout_text = null;
                string? stderr_text = null;
                yield process.communicate_utf8_async(null, null, out stdout_text, out stderr_text);
                status = process.get_if_exited() ? process.get_exit_status() : -1;
                if (status != 0 && stderr_text != null && stderr_text.strip() != "") {
                    warning("Sandbox: %s %s: %s", _command_line, string.joinv(" ", args), stderr_text.strip());
                }
                return stdout_text;
            } catch (Error e) {
                warning("Sandbox: cannot run %s: %s", _command_line, e.message);
                return null;
            }
        }

        public static string export_id(string cpak_id, string entry_path) {
            string hash = Checksum.compute_for_string(ChecksumType.SHA256, cpak_id);
            string base_name = Path.get_basename(entry_path);
            return "cpak-%s-%s".printf(hash, base_name);
        }

        public static string portal_id(string desktop_id) {
            return desktop_id.has_suffix(".desktop") ? desktop_id.substring(0, desktop_id.length - 8) : desktop_id;
        }

        public static CpakRecord[] parse_list(string json) {
            CpakRecord[] records = {};
            var parser = new Json.Parser();
            try {
                parser.load_from_data(json);
            } catch (Error e) {
                return records;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return records;
            foreach (var node in root.get_array().get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var object = node.get_object();
                var record = new CpakRecord();
                record.origin = string_member(object, "origin");
                record.version = string_member(object, "version");
                record.name = string_member(object, "name");
                record.cpak_id = string_member(object, "cpak_id");
                if (record.origin == "") continue;
                if (object.has_member("parsed_desktop_entries")
                    && object.get_member("parsed_desktop_entries").get_node_type() == Json.NodeType.ARRAY) {
                    string[] ids = {};
                    foreach (var entry in object.get_array_member("parsed_desktop_entries").get_elements()) {
                        if (entry.get_value_type() == typeof(string)) ids += export_id(record.cpak_id, entry.get_string());
                    }
                    record.desktop_ids = ids;
                }
                if (object.has_member("parsed_override")
                    && object.get_member("parsed_override").get_node_type() == Json.NodeType.OBJECT) {
                    record.declared = object.get_object_member("parsed_override");
                }
                records += record;
            }
            return records;
        }

        public static CpakGrant[] parse_grants(string json) {
            CpakGrant[] grants = {};
            var parser = new Json.Parser();
            try {
                parser.load_from_data(json);
            } catch (Error e) {
                return grants;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return grants;
            foreach (var node in root.get_array().get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var object = node.get_object();
                var grant = new CpakGrant();
                grant.id = string_member(object, "id");
                grant.selection = string_member(object, "selection");
                grant.kind = string_member(object, "kind");
                grant.access = string_member(object, "access");
                grant.lifetime = string_member(object, "lifetime");
                if (grant.id != "" && grant.lifetime != "session") grants += grant;
            }
            return grants;
        }

        public static Gee.HashMap<int, string> parse_running(string json) {
            var running = new Gee.HashMap<int, string>();
            var parser = new Json.Parser();
            try {
                parser.load_from_data(json);
            } catch (Error e) {
                return running;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return running;
            foreach (var node in root.get_array().get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var object = node.get_object();
                if (string_member(object, "container") != "running") continue;
                int64 pid = object.has_member("container_pid") ? object.get_int_member("container_pid") : 0;
                string origin = string_member(object, "origin");
                if (pid > 0 && origin != "") running[(int) pid] = origin;
            }
            return running;
        }

        private static string string_member(Json.Object object, string name) {
            if (!object.has_member(name)) return "";
            var node = object.get_member(name);
            if (node.get_value_type() != typeof(string)) return "";
            return node.get_string() ?? "";
        }

        private static bool bool_member(Json.Object? object, string name) {
            if (object == null || !object.has_member(name)) return false;
            var node = object.get_member(name);
            return node.get_value_type() == typeof(bool) && node.get_boolean();
        }

        private App make_app(CpakRecord record) {
            var app = new App(kind, record.origin);
            app.name = record.name;
            app.version = record.version;
            if (record.desktop_ids.length > 0) {
                app.desktop_id = record.desktop_ids[0];
                app.portal_app_id = portal_id(record.desktop_ids[0]);
            }
            return app;
        }

        public override async App[] list_apps() {
            int status;
            string? output = yield run({ "list", "--json" }, out status);
            App[] apps = {};
            if (output == null || status != 0) return apps;
            _records.clear();
            foreach (var record in parse_list(output)) {
                _records[record.origin] = record;
                if (record.desktop_ids.length == 0) continue;
                apps += make_app(record);
            }
            return apps;
        }

        public static string? origin_from_entry(KeyFile entry) {
            try {
                string origin = entry.get_string("Desktop Entry", "X-cpak-Origin").strip();
                if (origin != "") return origin;
            } catch (Error e) {
            }
            try {
                string exec = entry.get_string("Desktop Entry", "Exec");
                string[] argv;
                Shell.parse_argv(exec, out argv);
                for (int i = 0; i + 1 < argv.length; i++) {
                    if (argv[i] == "--desktop-launch") return argv[i + 1];
                }
            } catch (Error e) {
            }
            return null;
        }

        public override App? app_for_desktop(string desktop_id, KeyFile? entry) {
            if (entry == null) return null;
            string? origin = origin_from_entry(entry);
            if (origin == null) return null;
            var record = _records[origin.down()] ?? _records[origin];
            if (record != null) return make_app(record);
            var app = new App(kind, origin);
            app.desktop_id = desktop_id;
            app.portal_app_id = portal_id(desktop_id);
            return app;
        }

        public static string override_path(string origin, string version) {
            return Path.build_filename(Environment.get_home_dir(), ".config", "cpak", "overrides", origin, version, "cpak.json");
        }

        private async CpakRecord? record_for(App app) {
            if (!_records.has_key(app.id)) yield list_apps();
            return _records[app.id];
        }

        private async CpakGrant[] grants_for(string origin) {
            int64 now = get_monotonic_time();
            int64? stamp = _grants_time[origin];
            if (stamp == null || now - stamp > GRANTS_TTL) {
                var list = new Gee.ArrayList<CpakGrant>();
                int status;
                string? output = yield run({ "grant", "list", origin, "--json" }, out status);
                if (output != null && status == 0) {
                    foreach (var grant in parse_grants(output)) list.add(grant);
                }
                _grants[origin] = list;
                _grants_time[origin] = get_monotonic_time();
            }
            return _grants[origin].to_array();
        }

        private void forget(string origin) {
            _grants_time.unset(origin);
        }

        public static Json.Object? load_override(string path) {
            var parser = new Json.Parser();
            try {
                parser.load_from_file(path);
            } catch (Error e) {
                return null;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
            return root.get_object();
        }

        public override async Permission[] permissions(App app) {
            var record = yield record_for(app);
            if (record == null) return {};
            var user = load_override(override_path(record.origin, record.version));
            return build(record.declared, user, yield grants_for(record.origin));
        }

        public static Permission[] build(Json.Object declared, Json.Object? user, CpakGrant[] grants) {
            Permission[] result = {};
            Json.Object effective = user ?? declared;
            foreach (var toggle in toggles()) {
                bool before = bool_member(declared, toggle.native);
                bool now = bool_member(effective, toggle.native);
                if (toggle.legacy && !before && !now) continue;
                var permission = new Permission(toggle.group, toggle.key);
                permission.native_key = toggle.native;
                permission.category = toggle.category;
                permission.default_enabled = before;
                permission.enabled = now;
                permission.overridden = before != now;
                permission.label = toggle_label(toggle.key);
                permission.detail = Catalog.detail("", toggle.key);
                result += permission;
            }
            var declared_fs = filesystems(declared);
            var effective_fs = filesystems(effective);
            string[] paths = {};
            foreach (string name in Catalog.standard_filesystems()) paths += name;
            foreach (string name in declared_fs.keys) {
                if (!(name in paths)) paths += name;
            }
            foreach (string name in effective_fs.keys) {
                if (!(name in paths)) paths += name;
            }
            foreach (string name in paths) {
                var permission = new Permission(Group.FILES, name);
                permission.kind = Kind.FILESYSTEM;
                permission.native_key = "filesystem";
                permission.default_enabled = declared_fs.has_key(name);
                permission.default_value = declared_fs[name] ?? "";
                permission.enabled = effective_fs.has_key(name);
                permission.value = effective_fs[name] ?? "";
                permission.overridden = permission.enabled != permission.default_enabled
                    || permission.value != permission.default_value;
                string token = permission.enabled && permission.value == "read-only" ? name + ":ro" : name;
                permission.label = Catalog.describe_filesystem(token);
                permission.detail = name;
                result += permission;
            }
            foreach (var grant in grants) {
                var permission = new Permission(Group.FILES, "grant:" + grant.id);
                permission.kind = Kind.FILESYSTEM;
                permission.native_key = "grant";
                permission.enabled = true;
                permission.default_enabled = true;
                permission.editable = false;
                permission.revocable = true;
                permission.value = grant.access;
                permission.label = grant.access == "read-only"
                    ? _("%s, read only").printf(Path.get_basename(grant.selection)) : Path.get_basename(grant.selection);
                permission.detail = _("%s, chosen in the file picker").printf(grant.selection);
                result += permission;
            }
            var declared_bus = bus_names(declared);
            var effective_bus = bus_names(effective);
            string[] names = {};
            foreach (string name in declared_bus.keys) names += name;
            foreach (string name in effective_bus.keys) {
                if (!(name in names)) names += name;
            }
            foreach (string name in names) {
                var permission = new Permission(Group.SESSION_BUS, name);
                permission.kind = Kind.BUS_POLICY;
                permission.native_key = "sessionBus";
                permission.default_value = declared_bus[name] ?? "none";
                permission.default_enabled = declared_bus.has_key(name);
                permission.value = effective_bus[name] ?? "none";
                permission.enabled = effective_bus.has_key(name);
                permission.overridden = permission.enabled != permission.default_enabled;
                permission.label = name;
                permission.detail = permission.value;
                result += permission;
            }
            var declared_env = environment(declared);
            var effective_env = environment(effective);
            foreach (string name in effective_env.keys) {
                var permission = new Permission(Group.ENVIRONMENT, name);
                permission.kind = Kind.VALUE;
                permission.native_key = "env";
                permission.editable = false;
                permission.value = effective_env[name];
                permission.default_value = declared_env[name] ?? "";
                permission.enabled = true;
                permission.default_enabled = declared_env.has_key(name);
                permission.overridden = permission.value != permission.default_value;
                permission.label = name;
                permission.detail = permission.value;
                result += permission;
            }
            return result;
        }

        public static OrderedMap filesystems(Json.Object object) {
            var map = new OrderedMap();
            if (!object.has_member("filesystem") || object.get_member("filesystem").get_node_type() != Json.NodeType.ARRAY) {
                return map;
            }
            foreach (var node in object.get_array_member("filesystem").get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                string path = string_member(node.get_object(), "path");
                string access = string_member(node.get_object(), "access");
                if (path != "") map[path] = access != "" ? access : "read-write";
            }
            return map;
        }

        public static OrderedMap bus_names(Json.Object object) {
            var map = new OrderedMap();
            if (!object.has_member("sessionBus") || object.get_member("sessionBus").get_node_type() != Json.NodeType.OBJECT) {
                return map;
            }
            var bus = object.get_object_member("sessionBus");
            if (bus.has_member("talk") && bus.get_member("talk").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var node in bus.get_array_member("talk").get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    string name = string_member(node.get_object(), "name");
                    if (name != "") map[name] = "talk";
                }
            }
            if (bus.has_member("own") && bus.get_member("own").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var node in bus.get_array_member("own").get_elements()) {
                    if (node.get_value_type() == typeof(string)) map[node.get_string()] = "own";
                }
            }
            return map;
        }

        public static OrderedMap environment(Json.Object object) {
            var map = new OrderedMap();
            if (!object.has_member("env") || object.get_member("env").get_node_type() != Json.NodeType.ARRAY) return map;
            foreach (var node in object.get_array_member("env").get_elements()) {
                if (node.get_value_type() != typeof(string)) continue;
                string item = node.get_string();
                int eq = item.index_of("=");
                if (eq > 0) map[item.substring(0, eq)] = item.substring(eq + 1);
            }
            return map;
        }

        public static string filesystem_value(Json.Object effective, Json.Object declared, string path, bool enabled) {
            var builder = new Json.Builder();
            builder.begin_array();
            var current = filesystems(effective);
            var defaults = filesystems(declared);
            foreach (string key in current.keys) {
                if (key == path) continue;
                add_filesystem(builder, key, current[key]);
            }
            if (enabled) add_filesystem(builder, path, defaults[path] ?? current[path] ?? "read-write");
            builder.end_array();
            return to_json(builder.get_root());
        }

        private static void add_filesystem(Json.Builder builder, string path, string access) {
            builder.begin_object();
            builder.set_member_name("path");
            builder.add_string_value(path);
            builder.set_member_name("access");
            builder.add_string_value(access);
            builder.end_object();
        }

        public static string session_bus_value(Json.Object effective, Json.Object declared, string name, bool enabled) {
            var talk = new Gee.ArrayList<Json.Node>();
            var own = new Gee.ArrayList<string>();
            collect_bus(effective, name, talk, own);
            if (enabled) {
                var declared_talk = new Gee.ArrayList<Json.Node>();
                var declared_own = new Gee.ArrayList<string>();
                collect_bus(declared, null, declared_talk, declared_own);
                bool restored = false;
                foreach (var node in declared_talk) {
                    if (string_member(node.get_object(), "name") == name) {
                        talk.add(node.copy());
                        restored = true;
                    }
                }
                if (name in declared_own.to_array()) {
                    own.add(name);
                    restored = true;
                }
                if (!restored) {
                    var builder = new Json.Builder();
                    builder.begin_object();
                    builder.set_member_name("name");
                    builder.add_string_value(name);
                    builder.end_object();
                    talk.add(builder.get_root());
                }
            }
            var result = new Json.Builder();
            result.begin_object();
            if (talk.size > 0) {
                result.set_member_name("talk");
                result.begin_array();
                foreach (var node in talk) result.add_value(node.copy());
                result.end_array();
            }
            if (own.size > 0) {
                result.set_member_name("own");
                result.begin_array();
                foreach (string item in own) result.add_string_value(item);
                result.end_array();
            }
            result.end_object();
            return to_json(result.get_root());
        }

        private static void collect_bus(Json.Object object, string? skip, Gee.ArrayList<Json.Node> talk, Gee.ArrayList<string> own) {
            if (!object.has_member("sessionBus") || object.get_member("sessionBus").get_node_type() != Json.NodeType.OBJECT) return;
            var bus = object.get_object_member("sessionBus");
            if (bus.has_member("talk") && bus.get_member("talk").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var node in bus.get_array_member("talk").get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    if (skip != null && string_member(node.get_object(), "name") == skip) continue;
                    talk.add(node);
                }
            }
            if (bus.has_member("own") && bus.get_member("own").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var node in bus.get_array_member("own").get_elements()) {
                    if (node.get_value_type() != typeof(string)) continue;
                    if (skip != null && node.get_string() == skip) continue;
                    own.add(node.get_string());
                }
            }
        }

        private static string to_json(Json.Node node) {
            var generator = new Json.Generator();
            generator.set_root(node);
            return generator.to_data(null);
        }

        public static string[]? override_args(string origin, Json.Object declared, Json.Object? user,
                                              Permission permission, bool enabled) {
            Json.Object effective = user ?? declared;
            switch (permission.native_key) {
                case "grant":
                case "env":
                    return null;
                case "filesystem":
                    return { "override", origin, "-k", "filesystem", "-v",
                             filesystem_value(effective, declared, permission.key, enabled) };
                case "sessionBus":
                    return { "override", origin, "-k", "sessionBus", "-v",
                             session_bus_value(effective, declared, permission.key, enabled) };
            }
            if (permission.native_key == "") return null;
            return { "override", origin, "-k", permission.native_key, "-v", enabled ? "true" : "false" };
        }

        private async bool apply(App app, Permission permission, bool enabled) {
            var record = yield record_for(app);
            if (record == null) return false;
            var user = load_override(override_path(record.origin, record.version));
            string[]? args = override_args(record.origin, record.declared, user, permission, enabled);
            if (args == null) return false;
            int status;
            yield run(args, out status);
            return status == 0;
        }

        public override async bool set_enabled(App app, Permission permission, bool enabled) {
            bool ok = yield apply(app, permission, enabled);
            if (ok) changed(app.id);
            return ok;
        }

        public override async bool reset(App app, Permission permission) {
            bool ok;
            forget(app.id);
            if (permission.revocable) {
                int status;
                yield run({ "grant", "revoke", app.id, permission.key.substring(6) }, out status);
                ok = status == 0;
            } else {
                ok = yield apply(app, permission, permission.default_enabled);
            }
            if (ok) changed(app.id);
            return ok;
        }

        public override async bool reset_all(App app) {
            bool ok = true;
            foreach (var permission in yield permissions(app)) {
                if (!permission.overridden || permission.revocable || !permission.editable) continue;
                if (!(yield apply(app, permission, permission.default_enabled))) ok = false;
            }
            changed(app.id);
            return ok;
        }

        public override async void refresh_runtime() {
            int status;
            string? output = yield run({ "ps", "--json" }, out status);
            if (output == null || status != 0) {
                _running.clear();
                return;
            }
            _running = parse_running(output);
        }

        public override string[] running_app_ids() {
            string[] result = {};
            foreach (string origin in _running.values) {
                if (!(origin in result)) result += origin;
            }
            return result;
        }

        public override string? app_id_for_pid(int pid) {
            int current = pid;
            for (int depth = 0; depth < 64 && current > 1; depth++) {
                if (_running.has_key(current)) {
                    var record = _records[_running[current]];
                    if (record != null && record.desktop_ids.length > 0) return portal_id(record.desktop_ids[0]);
                    return _running[current];
                }
                current = parent_pid(current);
            }
            return null;
        }

        public static int parent_pid(int pid) {
            string contents;
            try {
                FileUtils.get_contents("/proc/%d/status".printf(pid), out contents);
            } catch (Error e) {
                return 0;
            }
            foreach (string line in contents.split("\n")) {
                if (line.has_prefix("PPid:")) return int.parse(line.substring(5).strip());
            }
            return 0;
        }
    }
}
