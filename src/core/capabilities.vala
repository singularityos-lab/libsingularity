namespace Singularity {
    public class ContractProvider : Object {
        public string interface_name { get; construct; }
        public string bus_name { get; construct; }
        public string object_path { get; construct; }
        public string app_id { get; construct; }

        public ContractProvider(string interface_name, string bus_name, string object_path, string app_id) {
            Object(interface_name: interface_name, bus_name: bus_name, object_path: object_path, app_id: app_id);
        }

        public static ContractProvider? from_file(string path) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
                string iface = kf.get_string("Capability", "Interface");
                string bus = kf.get_string("Capability", "BusName");
                string object_path = kf.get_string("Capability", "ObjectPath");
                string app = kf.has_key("Capability", "AppId") ? kf.get_string("Capability", "AppId") : bus;
                if (iface == "" || !DBus.is_name(bus) || !Variant.is_object_path(object_path)) return null;
                return new ContractProvider(iface, bus, object_path, app);
            } catch (Error e) {
                warning("Capabilities: %s: %s", path, e.message);
                return null;
            }
        }
    }

    public class Contracts : Object {
        public const string NOTES = "dev.sinty.Notes1";
        public const string TASKS = "dev.sinty.Tasks1";
        public const string CALENDAR = "dev.sinty.Calendar1";
        public const string TRANSLATE = "dev.sinty.Translate1";
        public const string TRANSLATION = "dev.sinty.TranslateService";
        public const string MAPS = "dev.sinty.Maps1";
        public const string WEATHER = "dev.sinty.Weather1";
        public const string COLORS = "dev.sinty.ColorPicker1";
        public const string SPREADSHEET = "dev.sinty.Spreadsheet1";
        public const string MAIL = "dev.sinty.Lettere.Mail";
        public const string COLLAB = "dev.sinty.Collab1";
    }

    public class Capabilities : Object {
        private static Gee.HashMap<string, ContractProvider>? table = null;
        private static int64 loaded_at = 0;

        private static void ensure_loaded() {
            int64 now = get_monotonic_time();
            if (table != null && now - loaded_at < 5 * TimeSpan.SECOND) return;
            loaded_at = now;
            table = new Gee.HashMap<string, ContractProvider>();
            foreach (string path in Runtime.find_data_files("singularity/capabilities", ".ini")) {
                var cap = ContractProvider.from_file(path);
                if (cap == null || table.has_key(cap.interface_name)) continue;
                if (ShareTargets.find_app_info(cap.app_id) == null) continue;
                table[cap.interface_name] = cap;
            }
        }

        public static ContractProvider? lookup(string interface_name) {
            ensure_loaded();
            return table[interface_name];
        }

        public static bool available(string interface_name) {
            return lookup(interface_name) != null;
        }

        public static bool has_app(string app_id) {
            return ShareTargets.find_app_info(app_id) != null;
        }

        public static async Variant call(string interface_name, string method, Variant? parameters, VariantType? reply_type, int timeout_ms = 30000) throws Error {
            var cap = lookup(interface_name);
            if (cap == null) throw new IOError.NOT_SUPPORTED(_("No installed app provides %s").printf(interface_name));
            var bus = yield GLib.Bus.get(BusType.SESSION);
            try {
                return yield bus.call(cap.bus_name, cap.object_path, interface_name, method, parameters, reply_type, DBusCallFlags.NONE, timeout_ms);
            } catch (Error e) {
                if (!(e is DBusError.SERVICE_UNKNOWN) && !(e is DBusError.NAME_HAS_NO_OWNER)) throw e;
            }
            yield start_app(bus, cap);
            return yield bus.call(cap.bus_name, cap.object_path, interface_name, method, parameters, reply_type, DBusCallFlags.NONE, timeout_ms);
        }

        public static void call_and_forget(string interface_name, string method, Variant? parameters) {
            call.begin(interface_name, method, parameters, null, 30000, (obj, res) => {
                try {
                    call.end(res);
                } catch (Error e) {
                    warning("Capabilities: %s.%s: %s", interface_name, method, e.message);
                }
            });
        }

        private static async void start_app(DBusConnection bus, ContractProvider cap) throws Error {
            var info = ShareTargets.find_app_info(cap.app_id);
            if (info == null) throw new IOError.NOT_FOUND(_("%s is not installed").printf(cap.app_id));
            bool resumed = false;
            SourceFunc resume = start_app.callback;
            uint watch = Bus.watch_name_on_connection(bus, cap.bus_name, BusNameWatcherFlags.NONE, () => {
                if (resumed) return;
                resumed = true;
                resume();
            }, null);
            uint timeout = 0;
            timeout = Timeout.add_seconds(15, () => {
                timeout = 0;
                if (!resumed) {
                    resumed = true;
                    resume();
                }
                return Source.REMOVE;
            });
            info.launch(null, Gdk.Display.get_default()?.get_app_launch_context());
            yield;
            Bus.unwatch_name(watch);
            if (timeout != 0) Source.remove(timeout);
        }
    }
}
