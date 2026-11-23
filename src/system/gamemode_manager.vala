namespace Singularity {
    public class GameModeManager : Object {
        private static GameModeManager? _instance = null;

        // Whether gamemode daemon is available on this system
        public bool available { get; private set; default = false; }
        // Whether auto-gamemode (activate when fullscreen game detected) is enabled
        public bool auto_mode { get; set; default = false; }
        // Whether gamemode is currently active
        public bool active { get; private set; default = false; }
        public bool requested { get; private set; default = false; }
        public bool held_elsewhere { get; private set; default = false; }

        private GLib.Settings _settings;
        private GLib.DBusProxy? _gamemode_proxy = null;
        private int _registered_pid = -1;
        private GLib.DBusConnection? _system = null;
        private string? _profiles_name = null;
        private uint32 _hold = 0;
        private int _clients = 0;

        public signal void state_changed();

        public static GameModeManager get_default() {
            if (_instance == null) {
                _instance = new GameModeManager();
            }
            return _instance;
        }

        private GameModeManager() {
            _settings = new GLib.Settings("dev.sinty.desktop");
            auto_mode = _settings.get_boolean("gamemode-auto");
            _settings.changed["gamemode-auto"].connect(() => {
                auto_mode = _settings.get_boolean("gamemode-auto");
            });
            check_availability.begin();
        }

        private async void check_availability() {
            try {
                var connection = yield GLib.Bus.get(GLib.BusType.SESSION, null);
                foreach (string method in new string[] { "ListNames", "ListActivatableNames" }) {
                    var names = yield connection.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                        "org.freedesktop.DBus", method, null, new GLib.VariantType("(as)"),
                        GLib.DBusCallFlags.NONE, 2000, null);
                    foreach (string n in names.get_child_value(0).get_strv()) {
                        if (n == "com.feralinteractive.GameMode") available = true;
                    }
                }
                if (available) {
                    _gamemode_proxy = yield new GLib.DBusProxy(
                        connection,
                        GLib.DBusProxyFlags.NONE,
                        null,
                        "com.feralinteractive.GameMode",
                        "/com/feralinteractive/GameMode",
                        "com.feralinteractive.GameMode",
                        null
                    );
                    _gamemode_proxy.g_properties_changed.connect(() => read_clients());
                    _gamemode_proxy.notify["g-name-owner"].connect(() => read_clients());
                    read_clients();
                }
            } catch (GLib.Error e) {
                available = false;
                _gamemode_proxy = null;
            }
            if (!available) yield find_profiles();
            state_changed();
        }

        private async void find_profiles() {
            try {
                _system = yield GLib.Bus.get(GLib.BusType.SYSTEM, null);
                foreach (string name in new string[] { "org.freedesktop.UPower.PowerProfiles", "net.hadess.PowerProfiles" }) {
                    var owner = yield _system.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                        "org.freedesktop.DBus", "NameHasOwner", new GLib.Variant("(s)", name),
                        new GLib.VariantType("(b)"), GLib.DBusCallFlags.NONE, 2000, null);
                    bool has = owner.get_child_value(0).get_boolean();
                    if (!has) {
                        var names = yield _system.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                            "org.freedesktop.DBus", "ListActivatableNames", null, new GLib.VariantType("(as)"),
                            GLib.DBusCallFlags.NONE, 2000, null);
                        has = name in names.get_child_value(0).get_strv();
                    }
                    if (has) {
                        _profiles_name = name;
                        available = true;
                        return;
                    }
                }
            } catch (GLib.Error e) {
                _profiles_name = null;
            }
        }

        private void read_clients() {
            var count = _gamemode_proxy != null && _gamemode_proxy.g_name_owner != null
                ? _gamemode_proxy.get_cached_property("ClientCount") : null;
            _clients = count != null && count.is_of_type(GLib.VariantType.INT32) ? count.get_int32() : 0;
            update();
        }

        private void update() {
            int own = _registered_pid >= 0 ? 1 : 0;
            bool was_active = active, was_requested = requested, was_elsewhere = held_elsewhere;
            requested = _registered_pid >= 0 || _hold != 0;
            held_elsewhere = _clients > own;
            active = requested || held_elsewhere;
            if (was_active != active || was_requested != requested || was_elsewhere != held_elsewhere) state_changed();
        }

        private static string profiles_path(string name) {
            return "/" + name.replace(".", "/");
        }

        public void on_fullscreen_app(string app_id, bool is_fullscreen) {
            if (!auto_mode || !available) return;
            if (is_fullscreen) activate(app_id);
            else deactivate();
        }

        public void activate(string? reason = null) {
            if (requested) return;
            if (_gamemode_proxy != null) {
                try {
                    int pid = (int) Posix.getpid();
                    _gamemode_proxy.call_sync(
                        "RegisterGameByPID",
                        new GLib.Variant("(ii)", pid, pid),
                        GLib.DBusCallFlags.NONE,
                        1000,
                        null
                    );
                    _registered_pid = pid;
                    _clients = int.max(_clients, 1);
                    update();
                } catch (GLib.Error e) {
                    warning("GameMode: RegisterGameByPID failed: %s", e.message);
                }
            } else if (_system != null && _profiles_name != null) {
                try {
                    var r = _system.call_sync(_profiles_name, profiles_path(_profiles_name), _profiles_name,
                        "HoldProfile", new GLib.Variant("(sss)", "performance", "Game Mode", reason ?? "dev.sinty.desktop"),
                        new GLib.VariantType("(u)"), GLib.DBusCallFlags.NONE, 2000, null);
                    _hold = r.get_child_value(0).get_uint32();
                    update();
                } catch (GLib.Error e) {
                    warning("GameMode: HoldProfile failed: %s", e.message);
                }
            }
        }

        public void deactivate() {
            if (!requested) return;
            if (_gamemode_proxy != null && _registered_pid >= 0) {
                try {
                    _gamemode_proxy.call_sync(
                        "UnregisterGameByPID",
                        new GLib.Variant("(ii)", _registered_pid, _registered_pid),
                        GLib.DBusCallFlags.NONE,
                        1000,
                        null
                    );
                } catch (GLib.Error e) {
                    warning("GameMode: UnregisterGameByPID failed: %s", e.message);
                }
                _registered_pid = -1;
                _clients = int.max(_clients - 1, 0);
            }
            if (_system != null && _profiles_name != null && _hold != 0) {
                try {
                    _system.call_sync(_profiles_name, profiles_path(_profiles_name), _profiles_name,
                        "ReleaseProfile", new GLib.Variant("(u)", _hold), null, GLib.DBusCallFlags.NONE, 2000, null);
                } catch (GLib.Error e) {
                    warning("GameMode: ReleaseProfile failed: %s", e.message);
                }
                _hold = 0;
            }
            update();
        }
    }
}
