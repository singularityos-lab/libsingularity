namespace Singularity {
    public class GameModeManager : Object {
        private static GameModeManager? _instance = null;

        // Whether gamemode daemon is available on this system
        public bool available { get; private set; default = false; }
        // Whether auto-gamemode (activate when fullscreen game detected) is enabled
        public bool auto_mode { get; set; default = false; }
        // Whether gamemode is currently active
        public bool active { get; private set; default = false; }

        private GLib.Settings _settings;
        private GLib.DBusProxy? _gamemode_proxy = null;
        private int _registered_pid = -1;

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
            available = GLib.Environment.find_program_in_path("gamemoded") != null;
            if (available) {
                try {
                    var connection = yield GLib.Bus.get(GLib.BusType.SESSION, null);
                    _gamemode_proxy = yield new GLib.DBusProxy(
                        connection,
                        GLib.DBusProxyFlags.NONE,
                        null,
                        "com.feralinteractive.GameMode",
                        "/com/feralinteractive/GameMode",
                        "com.feralinteractive.GameMode",
                        null
                    );
                } catch (GLib.Error e) {
                    // D-Bus not available but binary exists - still show the setting
                    _gamemode_proxy = null;
                }
            }
            state_changed();
        }

        public void on_fullscreen_app(string app_id, bool is_fullscreen) {
            if (!auto_mode || !available) return;
            if (is_fullscreen) activate(app_id);
            else deactivate();
        }

        public void activate(string? reason = null) {
            if (active) return;
            if (_gamemode_proxy != null) {
                try {
                    int pid = (int) Posix.getpid();
                    _gamemode_proxy.call_sync(
                        "RegisterGame",
                        new GLib.Variant("(ii)", pid, pid),
                        GLib.DBusCallFlags.NONE,
                        1000,
                        null
                    );
                    _registered_pid = pid;
                    active = true;
                    state_changed();
                } catch (GLib.Error e) {
                    warning("GameMode: RegisterGame failed: %s", e.message);
                }
            } else if (available) {
                try {
                    new GLib.Subprocess.newv(
                        { "gamemoderun", "true" },
                        GLib.SubprocessFlags.NONE
                    );
                    active = true;
                    state_changed();
                } catch (GLib.Error e) {
                    warning("GameMode: gamemoderun failed: %s", e.message);
                }
            }
        }

        public void deactivate() {
            if (!active) return;
            if (_gamemode_proxy != null && _registered_pid >= 0) {
                try {
                    _gamemode_proxy.call_sync(
                        "UnregisterGame",
                        new GLib.Variant("(ii)", _registered_pid, _registered_pid),
                        GLib.DBusCallFlags.NONE,
                        1000,
                        null
                    );
                } catch (GLib.Error e) {
                    warning("GameMode: UnregisterGame failed: %s", e.message);
                }
                _registered_pid = -1;
            }
            active = false;
            state_changed();
        }
    }
}
