namespace Singularity.Parental {

    [CCode (cname = "SINGULARITY_PARENTAL_SYSCONFDIR")]
    extern const string BUILD_SYSCONFDIR;
    [CCode (cname = "SINGULARITY_PARENTAL_DIR")]
    extern const string BUILD_POLICY_DIR;
    [CCode (cname = "SINGULARITY_PARENTAL_COMMAND")]
    extern const string BUILD_COMMAND;

    public class Config : Object {
        public const string FILE_NAME = "singularity/parental-controls.conf";

        private static Config? _instance = null;
        private KeyFile keyfile = new KeyFile();

        public string? source_path { get; private set; default = null; }

        public static Config get_default() {
            if (_instance == null) _instance = new Config();
            return _instance;
        }

        public Config() {
            reload();
        }

        public Config.from_file(string path) {
            if (!FileUtils.test(path, FileTest.IS_REGULAR)) return;
            try {
                keyfile.load_from_file(path, KeyFileFlags.NONE);
                source_path = path;
            } catch (Error e) {
                warning("Parental: cannot read %s: %s", path, e.message);
            }
        }

        public void reload() {
            keyfile = new KeyFile();
            source_path = null;
            string[] dirs = {};
            foreach (unowned string dir in Environment.get_system_config_dirs()) dirs += dir;
            dirs += BUILD_SYSCONFDIR;
            foreach (string dir in dirs) {
                string path = Path.build_filename(dir, FILE_NAME);
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                try {
                    keyfile.load_from_file(path, KeyFileFlags.NONE);
                    source_path = path;
                    return;
                } catch (Error e) {
                    warning("Parental: cannot read %s: %s", path, e.message);
                    keyfile = new KeyFile();
                }
            }
        }

        public string get_string(string group, string key, string fallback) {
            try {
                if (keyfile.has_group(group) && keyfile.has_key(group, key)) {
                    string value = keyfile.get_string(group, key).strip();
                    if (value != "") return value;
                }
            } catch (Error e) {
            }
            return fallback;
        }

        public string backend {
            owned get { return get_string("Policy", "Backend", "auto"); }
        }

        public string policy_directory {
            owned get { return get_string("Policy", "Directory", BUILD_POLICY_DIR); }
        }

        public string write_command {
            owned get { return get_string("Policy", "Command", BUILD_COMMAND); }
        }

        public string usage_directory_template {
            owned get { return get_string("Usage", "Directory", "%h/.local/share/singularity/screen-time"); }
        }

        public string usage_directory_for(string user_name, string home) {
            return usage_directory_template.replace("%h", home).replace("%u", user_name);
        }

        public int usage_retention_days {
            get { return int.parse(get_string("Usage", "RetentionDays", "35")).clamp(7, 3650); }
        }
    }

    public interface PolicyStore : Object {
        public abstract string name { owned get; }
        public abstract Policy load(string user_name);
        public abstract async void save(Policy policy) throws Error;
        public abstract string? path_for(string user_name);
    }

    public class FilePolicyStore : Object, PolicyStore {
        public string directory { get; construct; }
        public string command { get; construct; }

        public FilePolicyStore(string directory, string command) {
            Object(directory: directory, command: command);
        }

        public string name {
            owned get { return "file"; }
        }

        public static bool valid_user_name(string user_name) {
            if (user_name == "" || user_name.length > 64 || user_name.has_prefix("-")) return false;
            for (int i = 0; i < user_name.length; i++) {
                char c = user_name[i];
                if (!(c.isalnum() || c == '_' || c == '-' || c == '.')) return false;
            }
            return user_name != "." && user_name != "..";
        }

        public string? path_for(string user_name) {
            if (!valid_user_name(user_name)) return null;
            return Path.build_filename(directory, user_name + ".conf");
        }

        public Policy load(string user_name) {
            string? path = path_for(user_name);
            if (path == null || !FileUtils.test(path, FileTest.IS_REGULAR)) return new Policy(user_name);
            try {
                string data;
                FileUtils.get_contents(path, out data);
                return Policy.from_data(user_name, data);
            } catch (Error e) {
                warning("Parental: cannot read %s: %s", path, e.message);
                return new Policy(user_name);
            }
        }

        public async void save(Policy policy) throws Error {
            if (!valid_user_name(policy.user_name)) throw new IOError.INVALID_ARGUMENT("Invalid user name");
            string[] argv;
            GLib.Shell.parse_argv(command, out argv);
            argv += policy.is_active ? "set" : "clear";
            argv += policy.user_name;
            var launcher = new SubprocessLauncher(SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var proc = launcher.spawnv(argv);
            string? stdout_text;
            string? stderr_text;
            yield proc.communicate_utf8_async(policy.is_active ? policy.to_data() : "", null, out stdout_text, out stderr_text);
            if (!proc.get_if_exited() || proc.get_exit_status() != 0) {
                int status = proc.get_if_exited() ? proc.get_exit_status() : -1;
                if (status == 126 || status == 127) throw new IOError.PERMISSION_DENIED("Authorization was not granted");
                string detail = (stderr_text ?? "").strip();
                throw new IOError.FAILED(detail != "" ? detail : "The parental controls helper failed");
            }
        }
    }

    public class MalcontentMirrorStore : Object, PolicyStore {
        private FilePolicyStore files;

        public MalcontentMirrorStore(FilePolicyStore files) {
            this.files = files;
        }

        public string name {
            owned get { return "malcontent"; }
        }

        public string? path_for(string user_name) {
            return files.path_for(user_name);
        }

        public Policy load(string user_name) {
            return files.load(user_name);
        }

        public static bool available() {
            try {
                var bus = Bus.get_sync(BusType.SYSTEM);
                var reply = bus.call_sync("org.freedesktop.Accounts", "/org/freedesktop/Accounts",
                    "org.freedesktop.DBus.Introspectable", "Introspect", null, new VariantType("(s)"),
                    DBusCallFlags.NONE, 2000);
                string xml;
                reply.get("(s)", out xml);
                if (xml.contains("com.endlessm.ParentalControls")) return true;
                var user_reply = bus.call_sync("org.freedesktop.Accounts", "/org/freedesktop/Accounts",
                    "org.freedesktop.Accounts", "FindUserByName", new Variant("(s)", Environment.get_user_name()),
                    new VariantType("(o)"), DBusCallFlags.NONE, 2000);
                string path;
                user_reply.get("(o)", out path);
                var intro = bus.call_sync("org.freedesktop.Accounts", path,
                    "org.freedesktop.DBus.Introspectable", "Introspect", null, new VariantType("(s)"),
                    DBusCallFlags.NONE, 2000);
                intro.get("(s)", out xml);
                return xml.contains("com.endlessm.ParentalControls.AppFilter");
            } catch (Error e) {
                return false;
            }
        }

        private static string machine_arch() {
            try {
                string arch;
                FileUtils.get_contents("/proc/sys/kernel/arch", out arch);
                if (arch.strip() != "") return arch.strip();
            } catch (Error e) {
            }
            return "x86_64";
        }

        private static KeyFile? find_desktop_file(string id) {
            string[] dirs = { Environment.get_user_data_dir() };
            foreach (unowned string dir in Environment.get_system_data_dirs()) dirs += dir;
            foreach (string dir in dirs) {
                string path = Path.build_filename(dir, "applications", id + ".desktop");
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                var kf = new KeyFile();
                try {
                    kf.load_from_file(path, KeyFileFlags.NONE);
                    return kf;
                } catch (Error e) {
                }
            }
            return null;
        }

        public static string[] app_filter_entries(Policy policy) {
            string[] entries = {};
            foreach (string id in policy.blocked_apps) {
                var kf = find_desktop_file(id);
                if (kf == null) continue;
                try {
                    if (kf.has_key("Desktop Entry", "X-Flatpak")) {
                        entries += "app/%s/%s/stable".printf(kf.get_string("Desktop Entry", "X-Flatpak"), machine_arch());
                        continue;
                    }
                    string[] argv;
                    GLib.Shell.parse_argv(kf.get_string("Desktop Entry", "Exec"), out argv);
                    string? exe = argv.length > 0 ? Environment.find_program_in_path(argv[0]) : null;
                    if (exe != null) entries += exe;
                } catch (Error e) {
                }
            }
            return entries;
        }

        public async void save(Policy policy) throws Error {
            yield files.save(policy);
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                var reply = yield bus.call("org.freedesktop.Accounts", "/org/freedesktop/Accounts",
                    "org.freedesktop.Accounts", "FindUserByName", new Variant("(s)", policy.user_name),
                    new VariantType("(o)"), DBusCallFlags.NONE, 5000);
                string path;
                reply.get("(o)", out path);
                var filter = new Variant("(bas)", false, app_filter_entries(policy));
                yield bus.call("org.freedesktop.Accounts", path, "org.freedesktop.DBus.Properties", "Set",
                    new Variant("(ssv)", "com.endlessm.ParentalControls.AppFilter", "AppFilter", filter),
                    null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 30000);
                uint limit_type = policy.bedtime_enabled ? 1 : 0;
                yield bus.call("org.freedesktop.Accounts", path, "org.freedesktop.DBus.Properties", "Set",
                    new Variant("(ssv)", "com.endlessm.ParentalControls.SessionLimits", "DailySchedule",
                        new Variant("(uu)", (uint) policy.bedtime_end * 60, (uint) policy.bedtime_start * 60)),
                    null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 30000);
                yield bus.call("org.freedesktop.Accounts", path, "org.freedesktop.DBus.Properties", "Set",
                    new Variant("(ssv)", "com.endlessm.ParentalControls.SessionLimits", "LimitType",
                        new Variant.uint32(limit_type)),
                    null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 30000);
            } catch (Error e) {
                warning("Parental: could not mirror the policy to malcontent: %s", e.message);
            }
        }
    }

    public class Stores : Object {
        private static PolicyStore? _policy = null;

        public static PolicyStore policy_store() {
            if (_policy != null) return _policy;
            var config = Config.get_default();
            var files = new FilePolicyStore(config.policy_directory, config.write_command);
            string backend = config.backend;
            if (backend == "malcontent" || (backend == "auto" && MalcontentMirrorStore.available())) {
                _policy = new MalcontentMirrorStore(files);
            } else {
                _policy = files;
            }
            return _policy;
        }

        public static UsageStore usage_store_for(string user_name, string home) {
            var config = Config.get_default();
            return new JsonUsageStore(Path.build_filename(config.usage_directory_for(user_name, home), "usage.json"),
                config.usage_retention_days);
        }
    }
}

namespace Singularity.Parental {

    public class WebFilter : Object {
        private static WebFilter? _instance = null;
        private FilePolicyStore store;
        private Policy policy;
        private FileMonitor? monitor = null;

        public static WebFilter get_default() {
            if (_instance == null) _instance = new WebFilter();
            return _instance;
        }

        private WebFilter() {
            var config = Config.get_default();
            store = new FilePolicyStore(config.policy_directory, config.write_command);
            policy = store.load(Environment.get_user_name());
            string? path = store.path_for(Environment.get_user_name());
            if (path == null) return;
            try {
                monitor = File.new_for_path(Path.get_dirname(path)).monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
                monitor.changed.connect(() => policy = store.load(Environment.get_user_name()));
            } catch (Error e) {
                debug("Parental: cannot watch %s: %s", path, e.message);
            }
        }

        public bool active {
            get { return policy.web_filter_enabled; }
        }

        public bool blocks(string uri) {
            return policy.blocks_uri(uri);
        }
    }
}
