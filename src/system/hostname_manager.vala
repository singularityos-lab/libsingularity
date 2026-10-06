using GLib;

namespace Singularity {

    public class HostnameManager : Object {
        public const string BUS_NAME = "org.freedesktop.hostname1";
        public const string PATH = "/org/freedesktop/hostname1";
        public const string CONFIG_FILE = "singularity/sharing.conf";

        private static HostnameManager? _instance = null;

        public string hostname { get; private set; default = ""; }
        public string pretty_name { get; private set; default = ""; }
        public string backend { get; private set; default = "none"; }
        public bool can_change { get; private set; default = false; }

        private string[] command = {};

        public static HostnameManager get_default() {
            if (_instance == null) _instance = new HostnameManager();
            return _instance;
        }

        public static string display_name(string pretty, string hostname) {
            return pretty.strip() != "" ? pretty.strip() : hostname;
        }

        public static string static_name(string pretty) {
            var sb = new StringBuilder();
            string folded = pretty.normalize(-1, NormalizeMode.NFKD) ?? pretty;
            unichar c;
            int i = 0;
            bool dash = false;
            while (folded.get_next_char(ref i, out c)) {
                if (c < 128 && c.isalnum()) {
                    sb.append_unichar(c.tolower());
                    dash = false;
                } else if ((c == ' ' || c == '-' || c == '_' || c == '.' || c == '\'') && !dash && sb.len > 0) {
                    sb.append_c('-');
                    dash = true;
                }
            }
            string name = sb.str;
            while (name.has_suffix("-")) name = name.substring(0, name.length - 1);
            if (name.length > 63) name = name.substring(0, 63);
            while (name.has_suffix("-")) name = name.substring(0, name.length - 1);
            return name != "" ? name : "computer";
        }

        private string config_value(string key, string fallback) {
            string[] dirs = {};
            foreach (unowned string dir in Environment.get_system_config_dirs()) dirs += dir;
            dirs += FIREWALL_SYSCONFDIR;
            foreach (string dir in dirs) {
                string path = Path.build_filename(dir, CONFIG_FILE);
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                var kf = new KeyFile();
                try {
                    kf.load_from_file(path, KeyFileFlags.NONE);
                    return kf.has_key("Hostname", key) ? kf.get_string("Hostname", key).strip() : fallback;
                } catch (Error e) {
                    return fallback;
                }
            }
            return fallback;
        }

        private async bool hostnamed_present() {
            try {
                var conn = yield Bus.get(BusType.SYSTEM);
                foreach (string method in new string[] { "ListNames", "ListActivatableNames" }) {
                    var ret = yield conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                        method, null, new VariantType("(as)"), DBusCallFlags.NONE, 2000, null);
                    foreach (string n in ret.get_child_value(0).get_strv()) if (n == BUS_NAME) return true;
                }
            } catch (Error e) {
            }
            return false;
        }

        public async void load() {
            hostname = Environment.get_host_name();
            pretty_name = "";
            string choice = config_value("Backend", "auto").down();
            string cmd = config_value("Command", "");
            if (choice != "none" && choice != "command" && (yield hostnamed_present())) {
                backend = "hostnamed";
                can_change = true;
                try {
                    var conn = yield Bus.get(BusType.SYSTEM);
                    var ret = yield conn.call(BUS_NAME, PATH, "org.freedesktop.DBus.Properties", "GetAll",
                        new Variant("(s)", "org.freedesktop.hostname1"), new VariantType("(a{sv})"),
                        DBusCallFlags.NONE, 5000, null);
                    var props = ret.get_child_value(0);
                    var h = props.lookup_value("StaticHostname", VariantType.STRING);
                    if (h == null || h.get_string() == "") h = props.lookup_value("Hostname", VariantType.STRING);
                    if (h != null && h.get_string() != "") hostname = h.get_string();
                    var p = props.lookup_value("PrettyHostname", VariantType.STRING);
                    if (p != null) pretty_name = p.get_string();
                } catch (Error e) {
                    warning("HostnameManager: %s", e.message);
                }
                return;
            }
            if (choice != "none" && cmd != "") {
                try {
                    GLib.Shell.parse_argv(cmd, out command);
                    backend = "command";
                    can_change = true;
                    return;
                } catch (Error e) {
                    warning("HostnameManager: bad Command: %s", e.message);
                }
            }
            backend = "none";
            can_change = false;
        }

        public async void set_name(string pretty) throws Error {
            string name = static_name(pretty);
            if (backend == "hostnamed") {
                var conn = yield Bus.get(BusType.SYSTEM);
                yield conn.call(BUS_NAME, PATH, "org.freedesktop.hostname1", "SetPrettyHostname",
                    new Variant("(sb)", pretty.strip(), true), null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                    60000, null);
                yield conn.call(BUS_NAME, PATH, "org.freedesktop.hostname1", "SetStaticHostname",
                    new Variant("(sb)", name, true), null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                    60000, null);
            } else if (backend == "command") {
                string[] argv = command;
                argv += name;
                argv += pretty.strip();
                var proc = new Subprocess.newv(argv, SubprocessFlags.STDERR_PIPE);
                string? err;
                yield proc.communicate_utf8_async(null, null, null, out err);
                if (!proc.get_successful()) throw new IOError.FAILED((err ?? "").strip());
            } else {
                throw new IOError.NOT_SUPPORTED(_("The computer name cannot be changed on this system."));
            }
            yield load();
        }
    }
}
