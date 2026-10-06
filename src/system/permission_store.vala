using GLib;

namespace Singularity {

    public class PermissionEntry : Object {
        public string app_id { get; construct; }
        public string[] values { get; construct; }

        public PermissionEntry(string app_id, string[] values) {
            Object(app_id: app_id, values: values);
        }

        public string first {
            get { return values.length > 0 ? values[0] : ""; }
        }

        public bool allowed {
            get { return first == "yes" || (first != "no" && first != "ask" && first != "" && first != "NONE"); }
        }
    }

    public class PermissionStore : Object {
        public const string BUS_NAME = "org.freedesktop.impl.portal.PermissionStore";
        public const string OBJECT_PATH = "/org/freedesktop/impl/portal/PermissionStore";
        public const string INTERFACE = "org.freedesktop.impl.portal.PermissionStore";

        public const string TABLE_DEVICES = "devices";
        public const string TABLE_LOCATION = "location";
        public const string TABLE_BACKGROUND = "background";
        public const string TABLE_NOTIFICATIONS = "notifications";
        public const string TABLE_SCREENCAST = "screencast";
        public const string TABLE_REMOTE_DESKTOP = "remote-desktop";
        public const string TABLE_GLOBAL_SHORTCUTS = "global-shortcuts";
        public const string TABLE_SCREENSHOT = "screenshot";

        public signal void changed(string table, string id);

        public bool available { get; private set; default = false; }

        private static PermissionStore? _default = null;
        private DBusConnection? _conn = null;
        private uint _signal_id = 0;

        public static PermissionStore get_default() {
            if (_default == null) _default = new PermissionStore();
            return _default;
        }

        public PermissionStore.for_connection(DBusConnection conn) {
            _conn = conn;
            watch();
        }

        private async DBusConnection? connection() {
            if (_conn != null) return _conn;
            try {
                _conn = yield Bus.get(BusType.SESSION);
                watch();
            } catch (Error e) {
                _conn = null;
            }
            return _conn;
        }

        private void watch() {
            if (_conn == null || _signal_id != 0) return;
            _signal_id = _conn.signal_subscribe(null, INTERFACE, "Changed", OBJECT_PATH, null,
                DBusSignalFlags.NONE, (c, sender, path, iface, name, parameters) => {
                    string table = parameters.get_child_value(0).get_string();
                    string id = parameters.get_child_value(1).get_string();
                    changed(table, id);
                });
        }

        private async Variant? call(string method, Variant? parameters, string reply_type) {
            var conn = yield connection();
            if (conn == null) {
                available = false;
                return null;
            }
            try {
                var reply = yield conn.call(BUS_NAME, OBJECT_PATH, INTERFACE, method, parameters,
                    new VariantType(reply_type), DBusCallFlags.NONE, 5000, null);
                available = true;
                return reply;
            } catch (Error e) {
                if (e is DBusError.SERVICE_UNKNOWN || e is DBusError.NAME_HAS_NO_OWNER) available = false;
                return null;
            }
        }

        public async bool probe() {
            yield list("devices");
            return available;
        }

        public async string[] list(string table) {
            var reply = yield call("List", new Variant("(s)", table), "(as)");
            if (reply == null) return {};
            return reply.get_child_value(0).dup_strv();
        }

        public async PermissionEntry[] lookup(string table, string id) {
            var reply = yield call("Lookup", new Variant("(ss)", table, id), "(a{sas}v)");
            if (reply == null) return {};
            return parse_permissions(reply.get_child_value(0));
        }

        public async bool set_permission(string table, string id, string app_id, string[] values) {
            var reply = yield call("SetPermission",
                new Variant("(sbss^as)", table, true, id, app_id, values), "()");
            return reply != null;
        }

        public async bool delete_permission(string table, string id, string app_id) {
            var reply = yield call("DeletePermission", new Variant("(sss)", table, id, app_id), "()");
            return reply != null;
        }

        public async bool delete_entry(string table, string id) {
            var reply = yield call("Delete", new Variant("(ss)", table, id), "()");
            return reply != null;
        }

        public static PermissionEntry[] parse_permissions(Variant permissions) {
            PermissionEntry[] entries = {};
            if (!permissions.is_of_type(new VariantType("a{sas}"))) return entries;
            var iter = permissions.iterator();
            string app_id;
            Variant values;
            while (iter.next("{s@as}", out app_id, out values)) {
                entries += new PermissionEntry(app_id, values.dup_strv());
            }
            return entries;
        }
    }
}
