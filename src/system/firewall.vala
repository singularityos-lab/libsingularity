using GLib;

namespace Singularity {

    [CCode (cname = "SINGULARITY_SYSCONFDIR")]
    extern const string FIREWALL_SYSCONFDIR;
    [CCode (cname = "SINGULARITY_FIREWALL_HELPER")]
    extern const string FIREWALL_DEFAULT_HELPER;
    [CCode (cname = "SINGULARITY_FIREWALL_STATE")]
    extern const string FIREWALL_DEFAULT_STATE;

    public errordomain FirewallError {
        NOT_AVAILABLE,
        INVALID,
        FAILED
    }

    public enum FirewallProfile {
        HOME,
        PUBLIC,
        OTHER;

        public string to_id() {
            switch (this) {
                case HOME: return "home";
                case PUBLIC: return "public";
                default: return "other";
            }
        }
    }

    public class FirewallRule : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public string[] ports { get; construct; }
        public bool public_too { get; construct; }
        public bool removable { get; construct; }

        public FirewallRule(string id, string label, string[] ports, bool public_too, bool removable = true) {
            Object(id: id, label: label, ports: ports, public_too: public_too, removable: removable);
        }

        public string ports_text() {
            string[] shown = {};
            foreach (unowned string port in ports) shown += port.replace("/", " ").up();
            return string.joinv(", ", shown);
        }
    }

    public class FirewallStatus : Object {
        public bool enabled { get; set; default = false; }
        public bool can_toggle { get; set; default = true; }
        public FirewallProfile profile { get; set; default = FirewallProfile.HOME; }
        public string zone { get; set; default = ""; }
        public Gee.ArrayList<FirewallRule> rules { get; set; default = new Gee.ArrayList<FirewallRule>(); }
    }

    public class FirewallConfig : Object {
        public const string FILE_NAME = "singularity/firewall.conf";
        private KeyFile keyfile = new KeyFile();

        public FirewallConfig() {
            string[] dirs = {};
            foreach (unowned string dir in Environment.get_system_config_dirs()) dirs += dir;
            dirs += FIREWALL_SYSCONFDIR;
            foreach (string dir in dirs) {
                string path = Path.build_filename(dir, FILE_NAME);
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                try {
                    keyfile.load_from_file(path, KeyFileFlags.NONE);
                    return;
                } catch (Error e) {
                    warning("FirewallConfig: cannot read %s: %s", path, e.message);
                    keyfile = new KeyFile();
                }
            }
        }

        public string get_string(string key, string fallback) {
            try {
                if (keyfile.has_key("Firewall", key)) return keyfile.get_string("Firewall", key).strip();
            } catch (Error e) {
            }
            return fallback;
        }
    }

    public interface FirewallBackend : Object {
        public abstract string name { get; }
        public abstract async bool is_available();
        public abstract async FirewallStatus status() throws Error;
        public abstract async void set_enabled(bool enabled) throws Error;
        public abstract async void set_profile(FirewallProfile profile) throws Error;
        public abstract async void allow(FirewallRule rule) throws Error;
        public abstract async void revoke(string id) throws Error;
    }

    namespace FirewallPorts {
        public bool valid_id(string id) {
            if (id.length == 0 || id.length > 32) return false;
            for (int i = 0; i < id.length; i++) {
                char c = id[i];
                if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
            }
            return true;
        }

        public bool parse(string port, out int first, out int last, out string protocol) {
            first = 0;
            last = 0;
            protocol = "";
            string[] parts = port.strip().down().split("/");
            if (parts.length != 2 || (parts[1] != "tcp" && parts[1] != "udp")) return false;
            protocol = parts[1];
            string[] range = parts[0].split("-");
            if (range.length < 1 || range.length > 2) return false;
            int64 a, b;
            if (!int64.try_parse(range[0], out a)) return false;
            b = a;
            if (range.length == 2 && !int64.try_parse(range[1], out b)) return false;
            if (a < 1 || b > 65535 || a > b || (range.length == 2 && a == b)) return false;
            first = (int) a;
            last = (int) b;
            return true;
        }

        public bool valid(string[] ports) {
            if (ports.length == 0) return false;
            foreach (unowned string p in ports) {
                int a, b;
                string proto;
                if (!parse(p, out a, out b, out proto)) return false;
            }
            return true;
        }

        public string clean_label(string label) {
            var sb = new StringBuilder();
            unichar c;
            int i = 0;
            while (label.get_next_char(ref i, out c)) {
                if (c < 0x20 || c == '"' || c == '\\' || c == 0x7f) continue;
                sb.append_unichar(c);
            }
            string text = sb.str.strip();
            while (text.length > 64) text = text.substring(0, text.index_of_nth_char(text.char_count() - 1));
            return text != "" ? text : "App";
        }
    }

    public class FirewalldBackend : Object, FirewallBackend {
        public const string BUS_NAME = "org.fedoraproject.FirewallD1";
        public const string PATH = "/org/fedoraproject/FirewallD1";
        public const string IFACE = "org.fedoraproject.FirewallD1";
        public const string CONFIG_PATH = "/org/fedoraproject/FirewallD1/config";
        public const string CONFIG_IFACE = "org.fedoraproject.FirewallD1.config";
        public const string SERVICE_PREFIX = "singularity-";

        private string home_zone;
        private string public_zone;

        public string name { get { return "firewalld"; } }

        public FirewalldBackend(string home_zone, string public_zone) {
            this.home_zone = home_zone;
            this.public_zone = public_zone;
        }

        private async DBusConnection bus() throws Error {
            return yield Bus.get(BusType.SYSTEM);
        }

        private async Variant call(string path, string iface, string method, Variant? args, string? reply)
                throws Error {
            var conn = yield bus();
            return yield conn.call(BUS_NAME, path, iface, method, args,
                reply != null ? new VariantType(reply) : null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                30000, null);
        }

        public async bool is_available() {
            try {
                var conn = yield bus();
                var ret = yield conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "NameHasOwner", new Variant("(s)", BUS_NAME), new VariantType("(b)"), DBusCallFlags.NONE, 2000,
                    null);
                bool owned;
                ret.get("(b)", out owned);
                if (owned) return true;
                var names = yield conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "ListActivatableNames", null, new VariantType("(as)"), DBusCallFlags.NONE, 2000, null);
                foreach (string n in names.get_child_value(0).get_strv()) if (n == BUS_NAME) return true;
            } catch (Error e) {
            }
            return false;
        }

        private async string[] zone_services(string zone) throws Error {
            var ret = yield call(PATH, IFACE + ".zone", "getServices", new Variant("(s)", zone), "(as)");
            return ret.get_child_value(0).get_strv();
        }

        private async ObjectPath? service_path(string service) {
            try {
                var ret = yield call(CONFIG_PATH, CONFIG_IFACE, "getServiceByName", new Variant("(s)", service), "(o)");
                return (ObjectPath) ret.get_child_value(0).get_string();
            } catch (Error e) {
                return null;
            }
        }

        private async ObjectPath zone_path(string zone) throws Error {
            var ret = yield call(CONFIG_PATH, CONFIG_IFACE, "getZoneByName", new Variant("(s)", zone), "(o)");
            return (ObjectPath) ret.get_child_value(0).get_string();
        }

        public async FirewallStatus status() throws Error {
            var st = new FirewallStatus();
            st.enabled = true;
            st.can_toggle = false;
            var zone = yield call(PATH, IFACE, "getDefaultZone", null, "(s)");
            st.zone = zone.get_child_value(0).get_string();
            st.profile = st.zone == home_zone ? FirewallProfile.HOME
                : st.zone == public_zone ? FirewallProfile.PUBLIC : FirewallProfile.OTHER;
            string[] home = yield zone_services(home_zone);
            string[] pub = yield zone_services(public_zone);
            string[] seen = {};
            string[] all = home;
            foreach (string s in pub) all += s;
            foreach (string service in all) {
                if (service in seen) continue;
                seen += service;
                bool ours = service.has_prefix(SERVICE_PREFIX);
                string label = service;
                string[] ports = {};
                var path = yield service_path(service);
                if (path != null) {
                    try {
                        var short_name = yield call(path, CONFIG_IFACE + ".service", "getShort", null, "(s)");
                        string s = short_name.get_child_value(0).get_string();
                        if (s != "") label = s;
                        var list = yield call(path, CONFIG_IFACE + ".service", "getPorts", null, "(a(ss))");
                        var iter = list.get_child_value(0).iterator();
                        string port, proto;
                        while (iter.next("(ss)", out port, out proto)) ports += "%s/%s".printf(port, proto);
                    } catch (Error e) {
                    }
                }
                string id = ours ? service.substring(SERVICE_PREFIX.length) : service;
                st.rules.add(new FirewallRule(id, label, ports, service in pub, ours));
            }
            return st;
        }

        public async void set_enabled(bool enabled) throws Error {
            throw new FirewallError.NOT_AVAILABLE(_("firewalld is managed by the system."));
        }

        public async void set_profile(FirewallProfile profile) throws Error {
            string zone = profile == FirewallProfile.PUBLIC ? public_zone : home_zone;
            yield call(PATH, IFACE, "setDefaultZone", new Variant("(s)", zone), null);
        }

        private Variant port_list(string[] ports) {
            var b = new VariantBuilder(new VariantType("a(ss)"));
            foreach (unowned string p in ports) {
                int a, z;
                string proto;
                FirewallPorts.parse(p, out a, out z, out proto);
                b.add("(ss)", a == z ? a.to_string() : "%d-%d".printf(a, z), proto);
            }
            return b.end();
        }

        public async void allow(FirewallRule rule) throws Error {
            string service = SERVICE_PREFIX + rule.id;
            var settings = new VariantBuilder(new VariantType("a{sv}"));
            settings.add("{sv}", "short", new Variant.string(rule.label));
            settings.add("{sv}", "description", new Variant.string(rule.label));
            settings.add("{sv}", "ports", port_list(rule.ports));
            var existing = yield service_path(service);
            if (existing != null) {
                yield call(existing, CONFIG_IFACE + ".service", "update2", new Variant.tuple({ settings.end() }), null);
            } else {
                yield call(CONFIG_PATH, CONFIG_IFACE, "addService2", new Variant("(s@a{sv})", service, settings.end()),
                    null);
            }
            foreach (string zone in new string[] { home_zone, public_zone }) {
                bool wanted = zone == home_zone || rule.public_too;
                var path = yield zone_path(zone);
                var ret = yield call(path, CONFIG_IFACE + ".zone", "queryService", new Variant("(s)", service), "(b)");
                bool present = ret.get_child_value(0).get_boolean();
                if (wanted && !present) yield call(path, CONFIG_IFACE + ".zone", "addService", new Variant("(s)", service), null);
                if (!wanted && present) yield call(path, CONFIG_IFACE + ".zone", "removeService", new Variant("(s)", service), null);
            }
            yield call(PATH, IFACE, "reload", null, null);
        }

        public async void revoke(string id) throws Error {
            string service = id.has_prefix(SERVICE_PREFIX) ? id : SERVICE_PREFIX + id;
            foreach (string zone in new string[] { home_zone, public_zone }) {
                var path = yield zone_path(zone);
                var ret = yield call(path, CONFIG_IFACE + ".zone", "queryService", new Variant("(s)", service), "(b)");
                if (ret.get_child_value(0).get_boolean())
                    yield call(path, CONFIG_IFACE + ".zone", "removeService", new Variant("(s)", service), null);
            }
            var existing = yield service_path(service);
            if (existing != null) yield call(existing, CONFIG_IFACE + ".service", "remove", null, null);
            yield call(PATH, IFACE, "reload", null, null);
        }
    }

    public class NftablesBackend : Object, FirewallBackend {
        private string[] command;
        private string state_file;

        public string name { get { return "nftables"; } }

        public NftablesBackend(string command, string state_file) {
            try {
                GLib.Shell.parse_argv(command, out this.command);
            } catch (Error e) {
                this.command = {};
            }
            this.state_file = state_file;
        }

        public async bool is_available() {
            if (command.length == 0) return false;
            string program = command[0];
            if (program == "pkexec" && command.length > 1) {
                if (Environment.find_program_in_path("pkexec") == null) return false;
                program = command[1];
            }
            bool helper = Path.is_absolute(program) ? FileUtils.test(program, FileTest.IS_EXECUTABLE)
                : Environment.find_program_in_path(program) != null;
            if (!helper) return false;
            foreach (string nft in new string[] { "/usr/sbin/nft", "/sbin/nft", "/usr/bin/nft" })
                if (FileUtils.test(nft, FileTest.IS_EXECUTABLE)) return true;
            return Environment.find_program_in_path("nft") != null;
        }

        public static FirewallStatus parse_state(string text) {
            var st = new FirewallStatus();
            foreach (string line in text.split("\n")) {
                if (line.has_prefix("enabled ")) st.enabled = line.substring(8).strip() == "1";
                else if (line.has_prefix("profile ")) {
                    st.zone = line.substring(8).strip();
                    st.profile = st.zone == "public" ? FirewallProfile.PUBLIC : FirewallProfile.HOME;
                } else if (line.has_prefix("rule ")) {
                    string[] parts = line.substring(5).split(" ", 4);
                    if (parts.length < 4) continue;
                    st.rules.add(new FirewallRule(parts[0], parts[3], parts[2].split(","), parts[1] == "1"));
                }
            }
            if (st.zone == "") st.zone = "home";
            return st;
        }

        public async FirewallStatus status() throws Error {
            string text = "";
            if (FileUtils.test(state_file, FileTest.EXISTS)) {
                uint8[] data;
                yield File.new_for_path(state_file).load_contents_async(null, out data, null);
                text = (string) data;
            }
            return parse_state(text);
        }

        private async void run(string[] args) throws Error {
            string[] argv = command;
            foreach (unowned string a in args) argv += a;
            var proc = new Subprocess.newv(argv, SubprocessFlags.STDERR_PIPE | SubprocessFlags.STDOUT_SILENCE);
            string? err;
            yield proc.communicate_utf8_async(null, null, null, out err);
            if (!proc.get_if_exited() || proc.get_exit_status() != 0) {
                int status = proc.get_if_exited() ? proc.get_exit_status() : -1;
                if (status == 126 || status == 127) throw new FirewallError.FAILED(_("Permission was not given."));
                string detail = (err ?? "").strip();
                throw new FirewallError.FAILED(detail != "" ? detail : _("The firewall could not be changed."));
            }
        }

        public async void set_enabled(bool enabled) throws Error {
            yield run({ enabled ? "enable" : "disable" });
        }

        public async void set_profile(FirewallProfile profile) throws Error {
            yield run({ "profile", profile == FirewallProfile.PUBLIC ? "public" : "home" });
        }

        public async void allow(FirewallRule rule) throws Error {
            yield run({ "allow", rule.id, rule.public_too ? "1" : "0", string.joinv(",", rule.ports),
                FirewallPorts.clean_label(rule.label) });
        }

        public async void revoke(string id) throws Error {
            yield run({ "revoke", id });
        }
    }

    public class FirewallManager : Object {
        private static FirewallManager? _instance = null;

        public FirewallBackend? backend { get; private set; default = null; }
        public bool ready { get; private set; default = false; }
        public FirewallStatus? current { get; private set; default = null; }

        public signal void changed();

        public static FirewallManager get_default() {
            if (_instance == null) _instance = new FirewallManager();
            return _instance;
        }

        public async FirewallBackend? detect() {
            if (ready) return backend;
            var config = new FirewallConfig();
            string choice = config.get_string("Backend", "auto").down();
            var firewalld = new FirewalldBackend(config.get_string("HomeZone", "home"),
                config.get_string("PublicZone", "public"));
            var nft = new NftablesBackend(config.get_string("HelperCommand", FIREWALL_DEFAULT_HELPER),
                config.get_string("StateFile", FIREWALL_DEFAULT_STATE));
            switch (choice) {
                case "none":
                    backend = null;
                    break;
                case "firewalld":
                    backend = (yield firewalld.is_available()) ? firewalld : null;
                    break;
                case "nftables":
                    backend = (yield nft.is_available()) ? nft : null;
                    break;
                default:
                    if (yield firewalld.is_available()) backend = firewalld;
                    else if (yield nft.is_available()) backend = nft;
                    break;
            }
            ready = true;
            return backend;
        }

        public async FirewallStatus? refresh() {
            yield detect();
            if (backend == null) return null;
            try {
                current = yield backend.status();
            } catch (Error e) {
                warning("FirewallManager: %s", e.message);
                current = null;
            }
            changed();
            return current;
        }

        private async FirewallBackend require() throws Error {
            yield detect();
            if (backend == null) throw new FirewallError.NOT_AVAILABLE(_("No firewall is available on this system."));
            return backend;
        }

        public async void set_enabled(bool enabled) throws Error {
            var b = yield require();
            yield b.set_enabled(enabled);
            yield refresh();
        }

        public async void set_profile(FirewallProfile profile) throws Error {
            var b = yield require();
            yield b.set_profile(profile);
            yield refresh();
        }

        public async void allow_app(string id, string label, string[] ports, bool public_too = false) throws Error {
            string[] kept = ports;
            if (!FirewallPorts.valid_id(id)) throw new FirewallError.INVALID("invalid id %s", id);
            if (!FirewallPorts.valid(kept)) throw new FirewallError.INVALID(_("Enter ports like 8080/tcp or 6000-6010/udp."));
            var b = yield require();
            yield b.allow(new FirewallRule(id, FirewallPorts.clean_label(label), kept, public_too));
            yield refresh();
        }

        public async void revoke_app(string id) throws Error {
            var b = yield require();
            yield b.revoke(id);
            yield refresh();
        }

        public async bool register_app(string id, string label, string[] ports, bool public_too = false) {
            string[] kept = ports;
            try {
                yield detect();
                if (backend == null) return false;
                var st = current ?? yield refresh();
                if (st != null) {
                    foreach (var rule in st.rules) {
                        if (rule.id == id && string.joinv(",", rule.ports) == string.joinv(",", kept)
                                && rule.public_too == public_too) return true;
                    }
                }
                yield allow_app(id, label, kept, public_too);
                return true;
            } catch (Error e) {
                warning("FirewallManager: cannot open ports for %s: %s", id, e.message);
                return false;
            }
        }

        public async bool unregister_app(string id) {
            try {
                yield detect();
                if (backend == null) return false;
                var st = current ?? yield refresh();
                bool present = false;
                if (st != null) foreach (var rule in st.rules) if (rule.id == id && rule.removable) present = true;
                if (!present) return true;
                yield revoke_app(id);
                return true;
            } catch (Error e) {
                warning("FirewallManager: cannot close ports for %s: %s", id, e.message);
                return false;
            }
        }
    }
}
