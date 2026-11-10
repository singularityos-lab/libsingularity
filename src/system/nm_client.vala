namespace Singularity {

    internal const string NM_BUS = "org.freedesktop.NetworkManager";
    internal const string NM_PATH = "/org/freedesktop/NetworkManager";
    internal const string NM_IFACE = "org.freedesktop.NetworkManager";
    internal const string NM_SETTINGS_PATH = "/org/freedesktop/NetworkManager/Settings";
    internal const string NM_SETTINGS_IFACE = "org.freedesktop.NetworkManager.Settings";
    internal const string NM_CONNECTION_IFACE = "org.freedesktop.NetworkManager.Settings.Connection";
    internal const string NM_DEVICE_IFACE = "org.freedesktop.NetworkManager.Device";
    internal const string NM_WIRELESS_IFACE = "org.freedesktop.NetworkManager.Device.Wireless";
    internal const string NM_WIRED_IFACE = "org.freedesktop.NetworkManager.Device.Wired";
    internal const string NM_AP_IFACE = "org.freedesktop.NetworkManager.AccessPoint";
    internal const string NM_ACTIVE_IFACE = "org.freedesktop.NetworkManager.Connection.Active";
    internal const string NM_VPN_IFACE = "org.freedesktop.NetworkManager.VPN.Connection";
    internal const string NM_IP4_IFACE = "org.freedesktop.NetworkManager.IP4Config";
    internal const string NM_IP6_IFACE = "org.freedesktop.NetworkManager.IP6Config";

    public enum NmDeviceType {
        UNKNOWN = 0, ETHERNET = 1, WIFI = 2, BT = 5, MODEM = 8, WIREGUARD = 29
    }

    public enum NmDeviceState {
        UNKNOWN = 0, UNMANAGED = 10, UNAVAILABLE = 20, DISCONNECTED = 30, PREPARE = 40,
        CONFIG = 50, NEED_AUTH = 60, IP_CONFIG = 70, IP_CHECK = 80, SECONDARIES = 90,
        ACTIVATED = 100, DEACTIVATING = 110, FAILED = 120
    }

    public enum NmActiveState {
        UNKNOWN = 0, ACTIVATING = 1, ACTIVATED = 2, DEACTIVATING = 3, DEACTIVATED = 4
    }

    public enum NmActiveReason {
        UNKNOWN = 0, NONE = 1, USER_DISCONNECTED = 2, DEVICE_DISCONNECTED = 3, SERVICE_STOPPED = 4,
        IP_CONFIG_INVALID = 5, CONNECT_TIMEOUT = 6, SERVICE_START_TIMEOUT = 7,
        SERVICE_START_FAILED = 8, NO_SECRETS = 9, LOGIN_FAILED = 10, CONNECTION_REMOVED = 11
    }

    public enum NmVpnState {
        UNKNOWN = 0, PREPARE = 1, NEED_AUTH = 2, CONNECT = 3, IP_CONFIG_GET = 4,
        ACTIVATED = 5, FAILED = 6, DISCONNECTED = 7
    }

    public const uint NM_CONNECTIVITY_PORTAL = 2;
    public const uint NM_METERED_YES = 1;
    public const uint NM_METERED_GUESS_YES = 3;

    public class NmConnection : GLib.Object {
        public string path { get; construct; }
        internal Variant settings;
        private weak NmClient client;

        internal NmConnection(NmClient client, string path, Variant settings) {
            Object(path: path);
            this.client = client;
            this.settings = settings;
        }

        public NmConnection.detached(Variant settings) {
            Object(path: "");
            this.settings = settings;
        }

        public Variant? value(string setting, string key) {
            var group = settings.lookup_value(setting, new VariantType("a{sv}"));
            if (group == null) return null;
            return group.lookup_value(key, null);
        }

        public bool has_setting(string setting) {
            return settings.lookup_value(setting, new VariantType("a{sv}")) != null;
        }

        private string text(string setting, string key) {
            var v = value(setting, key);
            return v != null && v.is_of_type(VariantType.STRING) ? v.get_string() : "";
        }

        public string get_id() { return text("connection", "id"); }
        public string get_uuid() { return text("connection", "uuid"); }
        public string get_connection_type() { return text("connection", "type"); }

        public string? get_interface_name() {
            string name = text("connection", "interface-name");
            return name != "" ? name : null;
        }

        public bool autoconnect {
            get {
                var v = value("connection", "autoconnect");
                return v == null || !v.is_of_type(VariantType.BOOLEAN) || v.get_boolean();
            }
        }

        public string? wifi_ssid() {
            var v = value("802-11-wireless", "ssid");
            if (v == null || !v.is_of_type(new VariantType("ay"))) return null;
            return NmClient.ssid_text(v);
        }

        public string wifi_mode() {
            string mode = text("802-11-wireless", "mode");
            return mode != "" ? mode : "infrastructure";
        }

        public bool is_hotspot() {
            return get_connection_type() == "802-11-wireless" && wifi_mode() == "ap";
        }

        public string ipv4_method() {
            string m = text("ipv4", "method");
            return m != "" ? m : "auto";
        }

        public string ipv4_gateway() { return text("ipv4", "gateway"); }

        public bool ipv4_ignore_auto_dns {
            get {
                var v = value("ipv4", "ignore-auto-dns");
                return v != null && v.is_of_type(VariantType.BOOLEAN) && v.get_boolean();
            }
        }

        public string[] ipv4_addresses() {
            string[] out = {};
            var data = value("ipv4", "address-data");
            if (data != null && data.is_of_type(new VariantType("aa{sv}"))) {
                foreach (var entry in data) {
                    var a = entry.lookup_value("address", VariantType.STRING);
                    var p = entry.lookup_value("prefix", VariantType.UINT32);
                    if (a != null) out += "%s/%u".printf(a.get_string(), p != null ? p.get_uint32() : 32);
                }
                return out;
            }
            var legacy = value("ipv4", "addresses");
            if (legacy != null && legacy.is_of_type(new VariantType("aau"))) {
                foreach (var entry in legacy) {
                    if (entry.n_children() < 2) continue;
                    out += "%s/%u".printf(NmClient.ipv4_text(entry.get_child_value(0).get_uint32()),
                        entry.get_child_value(1).get_uint32());
                }
            }
            return out;
        }

        public string[] ipv4_dns() {
            string[] out = {};
            var data = value("ipv4", "dns-data");
            if (data != null && data.is_of_type(VariantType.STRING_ARRAY)) return data.get_strv();
            var legacy = value("ipv4", "dns");
            if (legacy != null && legacy.is_of_type(new VariantType("au"))) {
                foreach (var entry in legacy) out += NmClient.ipv4_text(entry.get_uint32());
            }
            return out;
        }

        internal Variant changed(string setting, HashTable<string, Variant?> changes) {
            var outer = new VariantBuilder(new VariantType("a{sa{sv}}"));
            bool seen = false;
            foreach (var group in settings) {
                string name = group.get_child_value(0).get_string();
                var inner = group.get_child_value(1);
                if (name != setting) {
                    outer.add("{s@a{sv}}", name, inner);
                    continue;
                }
                seen = true;
                outer.add("{s@a{sv}}", name, NmClient.merge(inner, changes));
            }
            if (!seen) outer.add("{s@a{sv}}", setting, NmClient.merge(null, changes));
            return outer.end();
        }

        public async void commit(Variant new_settings) throws Error {
            if (client == null) throw new IOError.NOT_CONNECTED("The connection is not saved");
            yield client.call(path, NM_CONNECTION_IFACE, "Update", new Variant.tuple({ new_settings }));
            settings = new_settings;
        }

        public async void delete_async() throws Error {
            if (client == null) throw new IOError.NOT_CONNECTED("The connection is not saved");
            yield client.call(path, NM_CONNECTION_IFACE, "Delete", null);
        }
    }

    public class NmClient : GLib.Object {
        private DBusObjectManagerClient manager;
        private DBusConnection bus;
        private HashTable<string, NmConnection> connections =
            new HashTable<string, NmConnection>(str_hash, str_equal);

        public signal void properties_changed(string path, string iface);
        public signal void object_added(string path);
        public signal void object_removed(string path);
        public signal void connection_added(NmConnection conn);
        public signal void connection_removed(NmConnection conn);
        public signal void connection_updated(NmConnection conn);
        public signal void active_state_changed(string path, uint state, uint reason);
        public signal void vpn_state_changed(string path, uint state, uint reason);

        public static async NmClient create(Cancellable? cancellable = null) throws Error {
            var c = new NmClient();
            c.bus = yield Bus.get(BusType.SYSTEM, cancellable);
            c.manager = (DBusObjectManagerClient) yield new DBusObjectManagerClient(
                c.bus, DBusObjectManagerClientFlags.DO_NOT_AUTO_START, NM_BUS, "/org/freedesktop",
                null, cancellable);
            if (c.manager.name_owner == null) throw new IOError.NOT_FOUND("NetworkManager is not running");
            c.manager.interface_proxy_properties_changed.connect((obj, proxy, changed, invalidated) => {
                c.properties_changed(obj.get_object_path(), proxy.get_interface_name());
            });
            c.manager.interface_proxy_signal.connect((obj, proxy, sender, name, parameters) => {
                c.on_signal(obj.get_object_path(), proxy.get_interface_name(), name, parameters);
            });
            c.manager.object_added.connect((obj) => c.on_object_added(obj.get_object_path()));
            c.manager.object_removed.connect((obj) => c.on_object_removed(obj.get_object_path()));
            foreach (var path in c.paths_with(NM_CONNECTION_IFACE)) yield c.load_connection(path, false);
            return c;
        }

        private void on_signal(string path, string iface, string name, Variant parameters) {
            if (iface == NM_ACTIVE_IFACE && name == "StateChanged" && parameters.n_children() >= 2) {
                active_state_changed(path, parameters.get_child_value(0).get_uint32(),
                    parameters.get_child_value(1).get_uint32());
            } else if (iface == NM_VPN_IFACE && name == "VpnStateChanged" && parameters.n_children() >= 2) {
                vpn_state_changed(path, parameters.get_child_value(0).get_uint32(),
                    parameters.get_child_value(1).get_uint32());
            } else if (iface == NM_CONNECTION_IFACE && name == "Updated") {
                load_connection.begin(path, true);
            }
        }

        private void on_object_added(string path) {
            if (has_interface(path, NM_CONNECTION_IFACE)) load_connection.begin(path, false);
            object_added(path);
        }

        private void on_object_removed(string path) {
            var conn = connections.lookup(path);
            if (conn != null) {
                connections.remove(path);
                connection_removed(conn);
            }
            object_removed(path);
        }

        private async void load_connection(string path, bool update) {
            try {
                var reply = yield call(path, NM_CONNECTION_IFACE, "GetSettings", null);
                var settings = reply.get_child_value(0);
                var existing = connections.lookup(path);
                if (existing != null) {
                    existing.settings = settings;
                    connection_updated(existing);
                    return;
                }
                var conn = new NmConnection(this, path, settings);
                connections.insert(path, conn);
                if (!update) connection_added(conn);
            } catch (Error e) {
                warning("Cannot read connection %s: %s", path, e.message);
            }
        }

        public bool has_interface(string path, string iface) {
            return manager.get_interface(path, iface) != null;
        }

        public string[] paths_with(string iface) {
            string[] out = {};
            foreach (var obj in manager.get_objects()) {
                if (obj.get_interface(iface) != null) out += obj.get_object_path();
            }
            return out;
        }

        public Variant? prop(string path, string iface, string name) {
            var proxy = manager.get_interface(path, iface) as GLib.DBusProxy;
            return proxy != null ? proxy.get_cached_property(name) : null;
        }

        public bool prop_bool(string path, string iface, string name, bool fallback = false) {
            var v = prop(path, iface, name);
            return v != null && v.is_of_type(VariantType.BOOLEAN) ? v.get_boolean() : fallback;
        }

        public uint prop_uint(string path, string iface, string name) {
            var v = prop(path, iface, name);
            if (v == null) return 0;
            if (v.is_of_type(VariantType.UINT32)) return v.get_uint32();
            if (v.is_of_type(VariantType.BYTE)) return v.get_byte();
            return 0;
        }

        public string prop_string(string path, string iface, string name) {
            var v = prop(path, iface, name);
            return v != null && (v.is_of_type(VariantType.STRING) || v.is_of_type(VariantType.OBJECT_PATH))
                ? v.get_string() : "";
        }

        public string? prop_path(string path, string iface, string name) {
            string p = prop_string(path, iface, name);
            return p != "" && p != "/" ? p : null;
        }

        public string[] prop_paths(string path, string iface, string name) {
            var v = prop(path, iface, name);
            if (v == null || !v.is_of_type(VariantType.OBJECT_PATH_ARRAY)) return {};
            return v.get_objv();
        }

        public async Variant call(string path, string iface, string method, Variant? parameters,
                                  Cancellable? cancellable = null) throws Error {
            return yield bus.call(NM_BUS, path, iface, method, parameters, null,
                DBusCallFlags.NONE, 120000, cancellable);
        }

        public async void set_property(string path, string iface, string name, Variant value) throws Error {
            yield bus.call(NM_BUS, path, "org.freedesktop.DBus.Properties", "Set",
                new Variant("(ssv)", iface, name, value), null, DBusCallFlags.NONE, -1, null);
        }

        public bool wireless_enabled { get { return prop_bool(NM_PATH, NM_IFACE, "WirelessEnabled", true); } }
        public bool wwan_enabled { get { return prop_bool(NM_PATH, NM_IFACE, "WwanEnabled", true); } }

        public string? primary_connection() { return prop_path(NM_PATH, NM_IFACE, "PrimaryConnection"); }
        public string[] active_connections() { return prop_paths(NM_PATH, NM_IFACE, "ActiveConnections"); }
        public string[] devices() { return prop_paths(NM_PATH, NM_IFACE, "Devices"); }

        public List<NmConnection> get_connections() {
            var list = new List<NmConnection>();
            foreach (var conn in connections.get_values()) list.append(conn);
            list.sort((a, b) => strcmp(a.path, b.path));
            return list;
        }

        public NmConnection? connection(string? path) {
            return path != null ? connections.lookup(path) : null;
        }

        public NmConnection? connection_by_id(string id) {
            foreach (var conn in connections.get_values()) if (conn.get_id() == id) return conn;
            return null;
        }

        public string device_iface(string device) { return prop_string(device, NM_DEVICE_IFACE, "Interface"); }
        public uint device_type(string device) { return prop_uint(device, NM_DEVICE_IFACE, "DeviceType"); }
        public uint device_state(string device) { return prop_uint(device, NM_DEVICE_IFACE, "State"); }
        public string? device_active(string device) { return prop_path(device, NM_DEVICE_IFACE, "ActiveConnection"); }

        public string? device_by_iface(string iface) {
            foreach (var d in devices()) if (device_iface(d) == iface) return d;
            return null;
        }

        public string active_type(string active) { return prop_string(active, NM_ACTIVE_IFACE, "Type"); }
        public string active_id(string active) { return prop_string(active, NM_ACTIVE_IFACE, "Id"); }
        public string active_uuid(string active) { return prop_string(active, NM_ACTIVE_IFACE, "Uuid"); }
        public uint active_state(string active) { return prop_uint(active, NM_ACTIVE_IFACE, "State"); }
        public string? active_connection(string active) { return prop_path(active, NM_ACTIVE_IFACE, "Connection"); }
        public string[] active_devices(string active) { return prop_paths(active, NM_ACTIVE_IFACE, "Devices"); }

        public string ap_ssid(string ap) {
            var v = prop(ap, NM_AP_IFACE, "Ssid");
            return v != null && v.is_of_type(new VariantType("ay")) ? ssid_text(v) : "";
        }

        public NmAccessPoint? access_point(string ap, string device) {
            if (!has_interface(ap, NM_AP_IFACE)) return null;
            bool secured = prop_uint(ap, NM_AP_IFACE, "WpaFlags") != 0
                || prop_uint(ap, NM_AP_IFACE, "RsnFlags") != 0;
            return new NmAccessPoint(ap, device, ap_ssid(ap), (uint8) prop_uint(ap, NM_AP_IFACE, "Strength"),
                secured, prop_uint(ap, NM_AP_IFACE, "Frequency"));
        }

        public NmDeviceInfo device_info(string device) {
            string hw = prop_string(device, NM_DEVICE_IFACE, "HwAddress");
            uint speed = 0;
            if (has_interface(device, NM_WIRELESS_IFACE)) {
                if (hw == "") hw = prop_string(device, NM_WIRELESS_IFACE, "HwAddress");
                speed = prop_uint(device, NM_WIRELESS_IFACE, "Bitrate") / 1000;
            } else if (has_interface(device, NM_WIRED_IFACE)) {
                if (hw == "") hw = prop_string(device, NM_WIRED_IFACE, "HwAddress");
                speed = prop_uint(device, NM_WIRED_IFACE, "Speed");
            }
            string address = "";
            string gateway = "";
            string[] dns = {};
            string? ip4 = prop_path(device, NM_DEVICE_IFACE, "Ip4Config");
            if (ip4 != null) {
                var data = prop(ip4, NM_IP4_IFACE, "AddressData");
                if (data != null && data.is_of_type(new VariantType("aa{sv}")) && data.n_children() > 0) {
                    var first = data.get_child_value(0);
                    var a = first.lookup_value("address", VariantType.STRING);
                    var p = first.lookup_value("prefix", VariantType.UINT32);
                    if (a != null) address = "%s/%u".printf(a.get_string(), p != null ? p.get_uint32() : 32);
                }
                gateway = prop_string(ip4, NM_IP4_IFACE, "Gateway");
                var ns = prop(ip4, NM_IP4_IFACE, "NameserverData");
                if (ns != null && ns.is_of_type(new VariantType("aa{sv}"))) {
                    foreach (var entry in ns) {
                        var a = entry.lookup_value("address", VariantType.STRING);
                        if (a != null) dns += a.get_string();
                    }
                } else {
                    var legacy = prop(ip4, NM_IP4_IFACE, "Nameservers");
                    if (legacy != null && legacy.is_of_type(new VariantType("au")))
                        foreach (var entry in legacy) dns += ipv4_text(entry.get_uint32());
                }
            }
            return new NmDeviceInfo(device, device_iface(device), hw, speed, address, gateway, dns);
        }

        public string ip_address(string device, bool ipv6) {
            string? config = prop_path(device, NM_DEVICE_IFACE, ipv6 ? "Ip6Config" : "Ip4Config");
            if (config == null) return "";
            var data = prop(config, ipv6 ? NM_IP6_IFACE : NM_IP4_IFACE, "AddressData");
            if (data == null || !data.is_of_type(new VariantType("aa{sv}")) || data.n_children() == 0) return "";
            var a = data.get_child_value(0).lookup_value("address", VariantType.STRING);
            return a != null ? a.get_string() : "";
        }

        public async void activate(string connection, string? device, string? specific) throws Error {
            yield call(NM_PATH, NM_IFACE, "ActivateConnection",
                new Variant("(ooo)", connection, device ?? "/", specific ?? "/"));
        }

        public async void add_and_activate(Variant settings, string? device, string? specific) throws Error {
            yield call(NM_PATH, NM_IFACE, "AddAndActivateConnection",
                new Variant("(@a{sa{sv}}oo)", settings, device ?? "/", specific ?? "/"));
        }

        public async void deactivate(string active) throws Error {
            yield call(NM_PATH, NM_IFACE, "DeactivateConnection", new Variant("(o)", active));
        }

        public async string add_connection(Variant settings) throws Error {
            var reply = yield call(NM_SETTINGS_PATH, NM_SETTINGS_IFACE, "AddConnection",
                new Variant("(@a{sa{sv}})", settings));
            return reply.get_child_value(0).get_string();
        }

        public async void request_scan(string device) throws Error {
            yield call(device, NM_WIRELESS_IFACE, "RequestScan",
                new Variant("(@a{sv})", new Variant.array(new VariantType("{sv}"), {})));
        }

        public static string ssid_text(Variant bytes) {
            var raw = bytes.get_data_as_bytes();
            unowned uint8[] data = raw.get_data();
            var sb = new StringBuilder();
            for (int i = 0; i < data.length; i++) sb.append_c((char) data[i]);
            string s = sb.str;
            return s.validate() ? s : s.make_valid();
        }

        public static Variant ssid_bytes(string ssid) {
            return new Variant.from_bytes(new VariantType("ay"), new Bytes(ssid.data), true);
        }

        public static string ipv4_text(uint32 network_order) {
            uint8 a = (uint8) (network_order & 0xff);
            uint8 b = (uint8) ((network_order >> 8) & 0xff);
            uint8 c = (uint8) ((network_order >> 16) & 0xff);
            uint8 d = (uint8) ((network_order >> 24) & 0xff);
            return "%u.%u.%u.%u".printf(a, b, c, d);
        }

        public static bool ipv4_valid(string text) {
            var addr = new InetAddress.from_string(text.strip());
            return addr != null && addr.family == SocketFamily.IPV4;
        }

        public static uint32 ipv4_value(string text) {
            var addr = new InetAddress.from_string(text.strip());
            var b = new uint8[4];
            Memory.copy(b, addr.to_bytes(), 4);
            return (uint32) b[0] | ((uint32) b[1] << 8) | ((uint32) b[2] << 16) | ((uint32) b[3] << 24);
        }

        public static string new_uuid() {
            return GLib.Uuid.string_random();
        }

        internal static Variant merge(Variant? group, HashTable<string, Variant?> changes) {
            var b = new VariantBuilder(new VariantType("a{sv}"));
            if (group != null) {
                foreach (var entry in group) {
                    string key = entry.get_child_value(0).get_string();
                    if (changes.contains(key)) continue;
                    b.add("{sv}", key, entry.get_child_value(1).get_variant());
                }
            }
            changes.foreach((key, v) => {
                if (v != null) b.add("{sv}", key, v);
            });
            return b.end();
        }

        public static Variant settings(HashTable<string, HashTable<string, Variant?>> groups) {
            var outer = new VariantBuilder(new VariantType("a{sa{sv}}"));
            var names = groups.get_keys();
            names.sort(strcmp);
            foreach (var name in names) outer.add("{s@a{sv}}", name, merge(null, groups.lookup(name)));
            return outer.end();
        }
    }

    public class NmAccessPoint : GLib.Object {
        public string path { get; construct; }
        public string device { get; construct; }
        public string ssid { get; construct; }
        public uint8 strength { get; construct; }
        public bool secured { get; construct; }
        public uint frequency { get; construct; }

        public NmAccessPoint(string path, string device, string ssid, uint8 strength, bool secured,
                             uint frequency) {
            Object(path: path, device: device, ssid: ssid, strength: strength, secured: secured,
                   frequency: frequency);
        }
    }

    public class NmDeviceInfo : GLib.Object {
        public string path { get; construct; }
        public string iface { get; construct; }
        public string hw_address { get; construct; }
        public uint speed_mbps { get; construct; }
        public string ip4_address { get; construct; }
        public string ip4_gateway { get; construct; }
        public string[] ip4_dns { get; construct; }

        public NmDeviceInfo(string path, string iface, string hw_address, uint speed_mbps,
                            string ip4_address, string ip4_gateway, string[] ip4_dns) {
            Object(path: path, iface: iface, hw_address: hw_address, speed_mbps: speed_mbps,
                   ip4_address: ip4_address, ip4_gateway: ip4_gateway, ip4_dns: ip4_dns);
        }
    }

    internal class NmSettings {
        public HashTable<string, HashTable<string, Variant?>> groups =
            new HashTable<string, HashTable<string, Variant?>>(str_hash, str_equal);

        public void group(string name) {
            if (groups.lookup(name) == null)
                groups.insert(name, new HashTable<string, Variant?>(str_hash, str_equal));
        }

        public void set(string name, string key, Variant? value) {
            group(name);
            groups.lookup(name).insert(key, value);
        }

        public Variant build() {
            return NmClient.settings(groups);
        }
    }
}
