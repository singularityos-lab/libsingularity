namespace Singularity {

    public class NearbyDevice : Object {
        public string id { get; construct; }
        public string name { get; set; default = ""; }
        public string device_type { get; set; default = "phone"; }
        public string icon_name { get; set; default = "phone-symbolic"; }
        public bool reachable { get; set; default = false; }
        public bool paired { get; set; default = false; }
        public string pair_state { get; set; default = "none"; }
        public string verification { get; set; default = ""; }
        public int battery { get; set; default = -1; }
        public bool charging { get; set; default = false; }
        public bool always_allow_files { get; set; default = false; }
        public string address { get; set; default = ""; }
        public string[] plugins { get; set; default = {}; }
        public bool supports_sms { get; set; default = false; }
        public bool supports_find { get; set; default = false; }
        public bool supports_media { get; set; default = false; }
        public bool has_conversations { get; set; default = false; }
        public int notification_count { get; set; default = 0; }

        public NearbyDevice(string id) {
            Object(id: id);
        }

        public bool has_plugin(string plugin) {
            return plugin in plugins;
        }

        public string full_icon_name {
            owned get { return device_type == "phone" || device_type == "tablet" ? "phone" : "computer"; }
        }

        public bool usable {
            get { return paired && reachable; }
        }

        public void update_from(Variant dict) {
            name = str(dict, "name", name);
            device_type = str(dict, "type", device_type);
            icon_name = str(dict, "icon", icon_name);
            reachable = flag(dict, "reachable");
            paired = flag(dict, "paired");
            pair_state = str(dict, "pair-state", "none");
            verification = str(dict, "verification", "");
            var b = dict.lookup_value("battery", VariantType.INT32);
            battery = b != null ? b.get_int32() : -1;
            charging = flag(dict, "charging");
            always_allow_files = flag(dict, "always-allow-files");
            address = str(dict, "address", "");
            var p = dict.lookup_value("plugins", VariantType.STRING_ARRAY);
            plugins = p != null ? p.dup_strv() : new string[0];
            supports_sms = flag(dict, "supports-sms");
            supports_find = flag(dict, "supports-find");
            supports_media = flag(dict, "supports-media");
            has_conversations = flag(dict, "has-conversations");
            var nc = dict.lookup_value("notification-count", VariantType.INT32);
            notification_count = nc != null ? nc.get_int32() : 0;
        }

        private static string str(Variant d, string key, string fallback) {
            var v = d.lookup_value(key, VariantType.STRING);
            return v != null ? v.get_string() : fallback;
        }

        private static bool flag(Variant d, string key) {
            var v = d.lookup_value(key, VariantType.BOOLEAN);
            return v != null && v.get_boolean();
        }

        public string status_text() {
            if (pair_state == "incoming") return _("Wants to pair");
            if (pair_state == "requested") return _("Waiting for %s").printf(name);
            if (!paired) return reachable ? _("Not paired") : _("Not nearby");
            if (!reachable) return _("Not connected");
            if (battery >= 0) {
                return charging ? _("Connected, %d%%, charging").printf(battery) : _("Connected, %d%%").printf(battery);
            }
            return _("Connected");
        }

        public string battery_icon() {
            if (battery < 0) return "battery-missing-symbolic";
            string level = battery >= 90 ? "full" : battery >= 60 ? "good" : battery >= 30 ? "low" : battery >= 10 ? "caution" : "empty";
            return charging ? "battery-%s-charging-symbolic".printf(level) : "battery-%s-symbolic".printf(level);
        }
    }

    public class NearbyClient : Object {
        public const string BUS_NAME = "dev.sinty.Nearby";
        public const string OBJECT_PATH = "/dev/sinty/Nearby";
        public const string INTERFACE = "dev.sinty.Nearby1";
        public const string[] PLUGINS = { "share", "clipboard", "notifications", "battery", "findmyphone", "sms", "mpris", "runcommand", "ping" };

        private static NearbyClient? instance;
        private DBusConnection? bus;
        private bool? activatable = null;
        private Gee.HashMap<string, NearbyDevice> by_id = new Gee.HashMap<string, NearbyDevice>();
        private uint refresh_id = 0;

        public Gee.ArrayList<NearbyDevice> devices { get; default = new Gee.ArrayList<NearbyDevice>(); }
        public bool running { get; private set; default = false; }
        public bool discoverable { get; private set; default = true; }
        public string device_name { get; private set; default = ""; }
        public string receive_folder { get; private set; default = ""; }
        public bool bluetooth_available { get; private set; default = false; }
        public bool run_commands_allowed { get; private set; default = true; }

        public signal void changed();
        public signal void device_changed(NearbyDevice device);
        public signal void clipboard_received(string text, string device_id);
        public signal void pair_requested(string device_id, string name, string code);
        public signal void transfer_progress(string transfer_id, int64 done, int64 total);
        public signal void transfer_finished(string transfer_id, bool ok, string detail);
        public signal void conversations_changed(string device_id);
        public signal void media_changed(string device_id);
        public signal void notifications_changed(string device_id);
        public signal void transfer_started(string transfer_id, string device_id, string name, int64 size, bool incoming);
        public signal void transfer_requested(string batch_id, string device_id, string summary, int64 size);
        public signal void received_files_changed();

        public static NearbyClient get_default() {
            if (instance == null) instance = new NearbyClient();
            return instance;
        }

        private NearbyClient() {
            try {
                bus = Bus.get_sync(BusType.SESSION, null);
            } catch (Error e) {
                bus = null;
                return;
            }
            Bus.watch_name_on_connection(bus, BUS_NAME, BusNameWatcherFlags.NONE, () => {
                running = true;
                refresh.begin();
            }, () => {
                running = false;
                devices.clear();
                by_id.clear();
                changed();
            });
            bus.signal_subscribe(BUS_NAME, INTERFACE, null, OBJECT_PATH, null, DBusSignalFlags.NONE, on_signal);
            bus.signal_subscribe(BUS_NAME, "org.freedesktop.DBus.Properties", "PropertiesChanged", OBJECT_PATH, INTERFACE,
                DBusSignalFlags.NONE, (c, s, p, i, n, parameters) => schedule_refresh());
        }

        public bool available {
            get {
                if (bus == null) return false;
                if (running) return true;
                if (activatable == null) {
                    activatable = false;
                    try {
                        var reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                            "ListActivatableNames", null, new VariantType("(as)"), DBusCallFlags.NONE, 2000, null);
                        foreach (string n in reply.get_child_value(0).dup_strv()) if (n == BUS_NAME) activatable = true;
                    } catch (Error e) {
                    }
                }
                return activatable;
            }
        }

        public void start() {
            if (bus == null || running || !available) return;
            refresh.begin();
        }

        private void on_signal(DBusConnection c, string? sender, string path, string iface, string name, Variant parameters) {
            switch (name) {
                case "DevicesChanged":
                case "DeviceChanged":
                    schedule_refresh();
                    break;
                case "ClipboardReceived":
                    clipboard_received(parameters.get_child_value(0).dup_string(), parameters.get_child_value(1).dup_string());
                    break;
                case "PairRequested":
                    schedule_refresh();
                    pair_requested(parameters.get_child_value(0).dup_string(), parameters.get_child_value(1).dup_string(),
                        parameters.get_child_value(2).dup_string());
                    break;
                case "TransferProgress":
                    transfer_progress(parameters.get_child_value(0).dup_string(), parameters.get_child_value(1).get_int64(),
                        parameters.get_child_value(2).get_int64());
                    break;
                case "TransferFinished":
                    transfer_finished(parameters.get_child_value(0).dup_string(), parameters.get_child_value(1).get_boolean(),
                        parameters.get_child_value(2).dup_string());
                    break;
                case "ConversationsChanged":
                    conversations_changed(parameters.get_child_value(0).dup_string());
                    break;
                case "MediaChanged":
                    media_changed(parameters.get_child_value(0).dup_string());
                    break;
                case "NotificationsChanged":
                    schedule_refresh();
                    notifications_changed(parameters.get_child_value(0).dup_string());
                    break;
                case "TransferStarted":
                    transfer_started(parameters.get_child_value(0).dup_string(), parameters.get_child_value(1).dup_string(),
                        parameters.get_child_value(2).dup_string(), parameters.get_child_value(3).get_int64(),
                        parameters.get_child_value(4).get_boolean());
                    break;
                case "TransferRequested":
                    transfer_requested(parameters.get_child_value(0).dup_string(), parameters.get_child_value(1).dup_string(),
                        parameters.get_child_value(2).dup_string(), parameters.get_child_value(3).get_int64());
                    break;
                case "ReceivedFilesChanged":
                    received_files_changed();
                    break;
            }
        }

        private void schedule_refresh() {
            if (refresh_id != 0) return;
            refresh_id = Timeout.add(80, () => {
                refresh_id = 0;
                refresh.begin();
                return Source.REMOVE;
            });
        }

        public async void refresh() {
            if (bus == null) return;
            try {
                var reply = yield bus.call(BUS_NAME, OBJECT_PATH, INTERFACE, "ListDevices", null,
                    new VariantType("(aa{sv})"), DBusCallFlags.NONE, 5000, null);
                var list = reply.get_child_value(0);
                var seen = new Gee.HashSet<string>();
                devices.clear();
                for (size_t i = 0; i < list.n_children(); i++) {
                    var dict = list.get_child_value(i);
                    var idv = dict.lookup_value("id", VariantType.STRING);
                    if (idv == null) continue;
                    string id = idv.get_string();
                    var d = by_id[id];
                    if (d == null) {
                        d = new NearbyDevice(id);
                        by_id[id] = d;
                    }
                    d.update_from(dict);
                    devices.add(d);
                    seen.add(id);
                }
                foreach (string id in by_id.keys.to_array()) if (!seen.contains(id)) by_id.unset(id);
                var props = yield bus.call(BUS_NAME, OBJECT_PATH, "org.freedesktop.DBus.Properties", "GetAll",
                    new Variant("(s)", INTERFACE), new VariantType("(a{sv})"), DBusCallFlags.NONE, 5000, null);
                var all = props.get_child_value(0);
                var v = all.lookup_value("Discoverable", VariantType.BOOLEAN);
                if (v != null) discoverable = v.get_boolean();
                v = all.lookup_value("Name", VariantType.STRING);
                if (v != null) device_name = v.get_string();
                v = all.lookup_value("ReceiveFolder", VariantType.STRING);
                if (v != null) receive_folder = v.get_string();
                v = all.lookup_value("BluetoothAvailable", VariantType.BOOLEAN);
                if (v != null) bluetooth_available = v.get_boolean();
                v = all.lookup_value("RunCommandsAllowed", VariantType.BOOLEAN);
                if (v != null) run_commands_allowed = v.get_boolean();
                running = true;
            } catch (Error e) {
                debug("nearby: %s", e.message);
            }
            changed();
        }

        public NearbyDevice? find(string id) {
            return by_id[id];
        }

        public Gee.List<NearbyDevice> usable_devices() {
            var result = new Gee.ArrayList<NearbyDevice>();
            foreach (var d in devices) if (d.usable) result.add(d);
            return result;
        }

        public async Variant? call(string method, Variant? parameters, string? reply_type = null) throws Error {
            if (bus == null) throw new IOError.NOT_CONNECTED(_("No session bus"));
            return yield bus.call(BUS_NAME, OBJECT_PATH, INTERFACE, method, parameters,
                reply_type != null ? new VariantType(reply_type) : null, DBusCallFlags.NONE, 15000, null);
        }

        public async void set_service_property(string property, Variant value) throws Error {
            if (bus == null) throw new IOError.NOT_CONNECTED(_("No session bus"));
            yield bus.call(BUS_NAME, OBJECT_PATH, "org.freedesktop.DBus.Properties", "Set",
                new Variant("(ssv)", INTERFACE, property, value), null, DBusCallFlags.NONE, 5000, null);
            yield refresh();
        }

        public async void simple(string method, Variant? parameters) {
            try {
                yield call(method, parameters);
            } catch (Error e) {
                warning("nearby: %s: %s", method, e.message);
            }
            schedule_refresh();
        }

        public async string share_files(string id, File[] files) throws Error {
            string[] uris = {};
            foreach (var f in files) uris += f.get_uri();
            var reply = yield call("ShareFiles", new Variant("(s^as)", id, uris), "(s)");
            return reply.get_child_value(0).dup_string();
        }

        public async string bluetooth_send_files(string address, File[] files) throws Error {
            string[] uris = {};
            foreach (var f in files) uris += f.get_uri();
            var reply = yield call("BluetoothSendFiles", new Variant("(s^as)", address, uris), "(s)");
            return reply.get_child_value(0).dup_string();
        }

        public async Variant[] list(string method, Variant? parameters = null) {
            Variant[] result = {};
            try {
                var reply = yield call(method, parameters, "(aa{sv})");
                var arr = reply.get_child_value(0);
                for (size_t i = 0; i < arr.n_children(); i++) result += arr.get_child_value(i);
            } catch (Error e) {
                debug("nearby: %s: %s", method, e.message);
            }
            return result;
        }

        public void send_clipboard(string text) {
            if (!running || text == "") return;
            simple.begin("SendClipboard", new Variant("(s)", text));
        }

        public static string text_of(Variant dict, string key, string fallback = "") {
            var v = dict.lookup_value(key, VariantType.STRING);
            return v != null ? v.get_string() : fallback;
        }

        public static bool flag_of(Variant dict, string key) {
            var v = dict.lookup_value(key, VariantType.BOOLEAN);
            return v != null && v.get_boolean();
        }

        public static int64 int_of(Variant dict, string key) {
            var v = dict.lookup_value(key, null);
            if (v == null) return 0;
            if (v.is_of_type(VariantType.INT64)) return v.get_int64();
            if (v.is_of_type(VariantType.INT32)) return v.get_int32();
            return 0;
        }

        public static string feature_title(string plugin) {
            switch (plugin) {
                case "share": return _("Files and Links");
                case "clipboard": return _("Shared Clipboard");
                case "notifications": return _("Notifications");
                case "sms": return _("Messages");
                case "battery": return _("Battery");
                case "findmyphone": return _("Find My Device");
                case "mpris": return _("Media Controls");
                case "ping": return _("Ping");
                case "runcommand": return _("Run Commands");
                default: return plugin;
            }
        }

        public static string feature_description(string plugin) {
            switch (plugin) {
                case "share": return _("Send and receive files, links and text");
                case "clipboard": return _("Copy on one device, paste on the other");
                case "notifications": return _("Show the phone's notifications here, reply and dismiss");
                case "sms": return _("Read and send text messages");
                case "battery": return _("Show the battery level of the device");
                case "findmyphone": return _("Make the device ring");
                case "mpris": return _("Control music and videos on both devices");
                case "ping": return _("Show a notification when the device pings");
                case "runcommand": return _("Let the device run the commands you choose on this computer");
                default: return "";
            }
        }

        public string[] features_for_settings() {
            string[] result = {};
            foreach (string p in PLUGINS) {
                if (p == "runcommand" && !run_commands_allowed) continue;
                result += p;
            }
            return result;
        }

        public const string APP_DESKTOP_ID = "dev.sinty.Nearby.desktop";

        private static AppInfo? app_info() {
            foreach (var info in AppInfo.get_all()) {
                if (info.get_id() == APP_DESKTOP_ID) return info;
            }
            return null;
        }

        public static bool app_installed() {
            return app_info() != null;
        }

        public static void open_app(string? device_id = null, string? page = null) {
            var info = app_info();
            if (info == null) {
                open_settings();
                return;
            }
            string args = "";
            if (device_id != null && device_id != "") args += " --device " + GLib.Shell.quote(device_id);
            if (page != null && page != "") args += " --page " + GLib.Shell.quote(page);
            try {
                if (args == "") {
                    info.launch(null, null);
                } else {
                    var cmd = AppInfo.create_from_commandline(info.get_executable() + args, info.get_name(), AppInfoCreateFlags.NONE);
                    cmd.launch(null, null);
                }
            } catch (Error e) {
                warning("nearby: %s", e.message);
            }
        }

        public static void open_settings() {
            try {
                var conn = Bus.get_sync(BusType.SESSION, null);
                conn.call.begin("dev.sinty.desktop", "/dev/sinty/Shell", "dev.sinty.Shell", "OpenSettings",
                    new Variant("(s)", "connected-devices"), null, DBusCallFlags.NONE, 5000, null);
            } catch (Error e) {
                warning("nearby: %s", e.message);
            }
        }
    }
}
