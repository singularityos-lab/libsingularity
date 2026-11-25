using GLib;

namespace Singularity {

    public errordomain OrganizationError {
        NOT_AVAILABLE,
        INVALID,
        REFUSED,
        DENIED,
        FAILED
    }

    public class OrganizationDevice : Object {
        public const string BUS_NAME = "dev.sinty.ITAgent1";
        public const string PATH = "/dev/sinty/ITAgent1";
        public const string IFACE = "dev.sinty.ITAgent1";

        private static OrganizationDevice? _instance = null;
        private uint signal_id = 0;
        private DBusConnection? conn = null;

        public bool available { get; private set; default = false; }
        public bool enrolled { get; private set; default = false; }
        public string server { get; private set; default = ""; }
        public string device { get; private set; default = ""; }
        public string group { get; private set; default = ""; }

        public signal void changed();

        public static OrganizationDevice get_default() {
            if (_instance == null) _instance = new OrganizationDevice();
            return _instance;
        }

        public string server_host() {
            var uri = server;
            int scheme = uri.index_of("://");
            if (scheme >= 0) uri = uri.substring(scheme + 3);
            int slash = uri.index_of_char('/');
            return slash >= 0 ? uri.substring(0, slash) : uri;
        }

        private async DBusConnection bus() throws Error {
            if (conn == null) {
                conn = yield Bus.get(BusType.SYSTEM);
                signal_id = conn.signal_subscribe(BUS_NAME, IFACE, "Changed", PATH, null, DBusSignalFlags.NONE,
                    () => refresh.begin());
            }
            return conn;
        }

        private async bool activatable(DBusConnection c) {
            try {
                var ret = yield c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "NameHasOwner", new Variant("(s)", BUS_NAME), new VariantType("(b)"), DBusCallFlags.NONE, 2000,
                    null);
                bool owned;
                ret.get("(b)", out owned);
                if (owned) return true;
                var names = yield c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "ListActivatableNames", null, new VariantType("(as)"), DBusCallFlags.NONE, 2000, null);
                foreach (string n in names.get_child_value(0).get_strv()) if (n == BUS_NAME) return true;
            } catch (Error e) {
            }
            return false;
        }

        private async Variant call(string method, Variant? args, string? reply) throws Error {
            var c = yield bus();
            try {
                return yield c.call(BUS_NAME, PATH, IFACE, method, args,
                    reply != null ? new VariantType(reply) : null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                    120000, null);
            } catch (Error e) {
                string? remote = DBusError.get_remote_error(e);
                DBusError.strip_remote_error(e);
                if (remote == "org.freedesktop.DBus.Error.AccessDenied")
                    throw new OrganizationError.DENIED(_("You are not allowed to change this."));
                if (remote == IFACE + ".Error.Refused")
                    throw new OrganizationError.REFUSED(_("The organization did not accept this enrollment code."));
                if (remote == IFACE + ".Error.Invalid")
                    throw new OrganizationError.INVALID(e.message);
                if (remote != null && remote.has_prefix("org.freedesktop.DBus.Error.ServiceUnknown"))
                    throw new OrganizationError.NOT_AVAILABLE(_("Device management is not installed."));
                throw new OrganizationError.FAILED(e.message);
            }
        }

        public async void refresh() {
            try {
                var c = yield bus();
                available = yield activatable(c);
                if (available) {
                    var ret = yield call("Status", null, "(bsss)");
                    bool on;
                    string srv, dev, grp;
                    ret.get("(bsss)", out on, out srv, out dev, out grp);
                    enrolled = on;
                    server = srv;
                    device = dev;
                    group = grp;
                } else {
                    enrolled = false;
                }
            } catch (Error e) {
                warning("OrganizationDevice: %s", e.message);
                enrolled = false;
            }
            changed();
        }

        public async void enroll(string server, string token, string name) throws Error {
            yield call("Enroll", new Variant("(sss)", server, token, name), "(ss)");
            yield refresh();
        }

        public async void leave() throws Error {
            yield call("Leave", null, null);
            yield refresh();
        }
    }
}
