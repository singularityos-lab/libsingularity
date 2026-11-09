using GLib;

namespace Singularity.Profiles {

    public const string SERVICE_NAME = "dev.sinty.Profiles";
    public const string SERVICE_PATH = "/dev/sinty/Profiles";

    [DBus (name = "dev.sinty.Profiles1")]
    public interface ServiceProxy : Object {
        public abstract string active_profile { owned get; }
        public abstract string reason { owned get; }
        public abstract async string list_profiles() throws GLib.Error;
        public abstract async string list_areas() throws GLib.Error;
        public abstract async string current_facts() throws GLib.Error;
        public abstract async string save_profile(string data) throws GLib.Error;
        public abstract async void delete_profile(string id) throws GLib.Error;
        public abstract async string capture_current(string id) throws GLib.Error;
        public abstract async void activate(string id) throws GLib.Error;
        public abstract async void activate_from(string id, string source) throws GLib.Error;
        public abstract async void deactivate() throws GLib.Error;
        public abstract async void register_area(string id, ObjectPath path) throws GLib.Error;
        public abstract async void unregister_area(string id) throws GLib.Error;
        public abstract async HashTable<string, Variant> status() throws GLib.Error;
        public signal void status_changed(HashTable<string, Variant> status);
        public signal void profiles_changed();
    }

    public class Client : Object {
        private static Client? _instance = null;
        private ServiceProxy? _proxy = null;
        private bool _connecting = false;

        public string active_profile { get; private set; default = ""; }
        public string reason { get; private set; default = ""; }
        public string detail { get; private set; default = ""; }
        public bool available { get { return _proxy != null; } }

        public signal void status_changed();
        public signal void profiles_changed();

        public static Client get_default() {
            if (_instance == null) _instance = new Client();
            return _instance;
        }

        private Client() {
            Bus.watch_name(BusType.SESSION, SERVICE_NAME, BusNameWatcherFlags.AUTO_START,
                () => connect_proxy.begin(),
                () => {
                    _proxy = null;
                    active_profile = "";
                    reason = "";
                    detail = "";
                    status_changed();
                });
        }

        private async void connect_proxy() {
            if (_connecting || _proxy != null) return;
            _connecting = true;
            try {
                _proxy = yield Bus.get_proxy<ServiceProxy>(BusType.SESSION, SERVICE_NAME, SERVICE_PATH);
                _proxy.status_changed.connect((s) => take_status(s));
                _proxy.profiles_changed.connect(() => profiles_changed());
                take_status(yield _proxy.status());
                profiles_changed();
            } catch (Error e) {
                debug("profiles: service not reachable: %s", e.message);
                _proxy = null;
            }
            _connecting = false;
        }

        private void take_status(HashTable<string, Variant> s) {
            var a = s["active"];
            var r = s["reason"];
            var d = s["detail"];
            active_profile = a != null ? a.get_string() : "";
            reason = r != null ? r.get_string() : "";
            detail = d != null ? d.get_string() : "";
            status_changed();
        }

        private ServiceProxy require() throws Error {
            if (_proxy == null) throw new IOError.NOT_CONNECTED("The profiles service is not running");
            return _proxy;
        }

        public async ProfileSet load() throws Error {
            var set = ProfileSet.from_data(yield require().list_profiles());
            if (set == null) throw new IOError.INVALID_DATA("Unreadable profiles");
            return set;
        }

        public async Gee.ArrayList<AreaInfo> areas() throws Error {
            var list = new Gee.ArrayList<AreaInfo>();
            var parser = new Json.Parser();
            parser.load_from_data(yield require().list_areas());
            var root = parser.get_root();
            if (root != null && root.get_node_type() == Json.NodeType.ARRAY) {
                root.get_array().foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    var info = AreaInfo.from_json(n.get_object());
                    if (info != null) list.add(info);
                });
            }
            return list;
        }

        public async Json.Object facts() throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(yield require().current_facts());
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return new Json.Object();
            return root.get_object();
        }

        public async string save(Profile profile) throws Error {
            return yield require().save_profile(profile.to_data());
        }

        public async void remove(string id) throws Error {
            yield require().delete_profile(id);
        }

        public async Profile? capture(string id) throws Error {
            return Profile.from_data(yield require().capture_current(id));
        }

        public async void activate(string id, string source = "") throws Error {
            if (source == "") yield require().activate(id);
            else yield require().activate_from(id, source);
        }

        public async void deactivate() throws Error {
            yield require().deactivate();
        }
    }

    public class AppArea : Area {
        public string app_id { get; private set; }
        private bool _registered = false;

        public AppArea(string app_id, string label, string icon_name) {
            base(Areas.APP_PREFIX + app_id, label, icon_name);
            this.app_id = app_id;
        }

        public async bool register() {
            try {
                var conn = yield Bus.get(BusType.SESSION);
                if (!export(conn)) return false;
                var proxy = yield Bus.get_proxy<ServiceProxy>(BusType.SESSION, SERVICE_NAME, SERVICE_PATH);
                yield proxy.register_area(info.id, new ObjectPath(object_path));
                _registered = true;
            } catch (Error e) {
                debug("profiles: %s not registered: %s", app_id, e.message);
            }
            return _registered;
        }

        public async void unregister() {
            if (!_registered) return;
            try {
                var proxy = yield Bus.get_proxy<ServiceProxy>(BusType.SESSION, SERVICE_NAME, SERVICE_PATH);
                yield proxy.unregister_area(info.id);
            } catch (Error e) {
            }
            unexport();
            _registered = false;
        }
    }

    public class DescribedAppArea : Area {
        public string app_id { get; private set; }

        public DescribedAppArea(string app_id, string label, string icon_name) {
            base(Areas.APP_PREFIX + app_id, label, icon_name);
            this.app_id = app_id;
        }

        public static DescribedAppArea? load(string app_id, string label, string icon_name) {
            var descriptor = Singularity.Core.AppSettingsLoader.load_for_app(app_id);
            if (descriptor == null) return null;
            var area = new DescribedAppArea(app_id, label, icon_name);
            foreach (var item in descriptor.items) {
                if (!item.profile) continue;
                var settings = Singularity.Core.AppSettingsLoader.settings_for(descriptor, item);
                if (settings == null) continue;
                area.bind_setting(settings, item.key, option_for(item));
            }
            return area.info.options.size > 0 ? area : null;
        }

        private static Option option_for(Singularity.Core.AppSettingItem item) {
            OptionKind kind;
            switch (item.setting_type) {
                case "boolean": kind = OptionKind.BOOLEAN; break;
                case "int": kind = OptionKind.INTEGER; break;
                case "double": kind = OptionKind.NUMBER; break;
                default: kind = item.options.size > 0 ? OptionKind.CHOICE : OptionKind.TEXT; break;
            }
            var opt = new Option(item.key, item.label, kind);
            if (item.subtitle != null) opt.subtitle = item.subtitle;
            if (kind == OptionKind.INTEGER || kind == OptionKind.NUMBER) opt.with_range(item.min, item.max);
            foreach (var o in item.options) opt.add_choice(o.id, o.label);
            return opt;
        }

        public static string[] described_apps() {
            var seen = new Gee.HashSet<string>();
            string[] ids = {};
            string[] dirs = { Path.build_filename(Environment.get_user_data_dir(), "singularity", "app-settings") };
            foreach (unowned string d in Environment.get_system_data_dirs()) {
                dirs += Path.build_filename(d, "singularity", "app-settings");
            }
            foreach (string dir in dirs) {
                try {
                    var e = Dir.open(dir);
                    string? name;
                    while ((name = e.read_name()) != null) {
                        if (!name.has_suffix(".json")) continue;
                        string id = name.substring(0, name.length - 5);
                        if (seen.add(id)) ids += id;
                    }
                } catch (FileError err) {
                }
            }
            return ids;
        }
    }
}
