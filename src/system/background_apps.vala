using GLib;

namespace Singularity {

    public class BackgroundApp : Object {
        public string app_id { get; construct; }
        public string instance { get; construct; }
        public string message { get; construct; }

        public BackgroundApp(string app_id, string instance, string message) {
            Object(app_id: app_id, instance: instance, message: message);
        }

        public string display_name {
            owned get {
                var info = new DesktopAppInfo(app_id + ".desktop");
                return info != null ? info.get_display_name() : app_id;
            }
        }

        public Icon? icon {
            owned get {
                var info = new DesktopAppInfo(app_id + ".desktop");
                return info != null ? info.get_icon() : null;
            }
        }
    }

    public class BackgroundApps : Object {
        public const string BUS_NAME = "org.freedesktop.background.Monitor";
        public const string OBJECT_PATH = "/org/freedesktop/background/monitor";
        public const string INTERFACE = "org.freedesktop.background.Monitor";
        public const string CONFIG_FILE = "singularity/background-apps.conf";
        public const string DEFAULT_STOP_COMMAND = "flatpak kill {instance}";

        public signal void changed();

        public bool available { get; private set; default = false; }

        private static BackgroundApps? _default = null;
        private DBusConnection? _conn = null;
        private BackgroundApp[] _apps = {};
        private uint _signal_id = 0;
        private uint _owner_id = 0;

        public static BackgroundApps get_default() {
            if (_default == null) _default = new BackgroundApps();
            return _default;
        }

        public BackgroundApp[] list() {
            return _apps;
        }

        public async void start() {
            if (_conn != null) return;
            try {
                _conn = yield Bus.get(BusType.SESSION);
            } catch (Error e) {
                return;
            }
            _signal_id = _conn.signal_subscribe(null, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                OBJECT_PATH, INTERFACE, DBusSignalFlags.NONE, (c, sender, path, iface, name, parameters) => {
                    refresh.begin();
                });
            _owner_id = _conn.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                "/org/freedesktop/DBus", BUS_NAME, DBusSignalFlags.NONE, (c, sender, path, iface, name, parameters) => {
                    refresh.begin();
                });
            yield refresh();
        }

        public async void refresh() {
            if (_conn == null) return;
            BackgroundApp[] found = {};
            try {
                var reply = yield _conn.call(BUS_NAME, OBJECT_PATH, "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", INTERFACE, "BackgroundApps"), new VariantType("(v)"),
                    DBusCallFlags.NONE, 5000, null);
                available = true;
                found = parse(reply.get_child_value(0).get_variant());
            } catch (Error e) {
                available = false;
            }
            _apps = found;
            changed();
        }

        public static BackgroundApp[] parse(Variant list) {
            BackgroundApp[] result = {};
            if (!list.is_of_type(new VariantType("aa{sv}"))) return result;
            foreach (var entry in list) {
                var dict = new VariantDict(entry);
                string app_id = "";
                string instance = "";
                string message = "";
                dict.lookup("app_id", "s", out app_id);
                dict.lookup("instance", "s", out instance);
                dict.lookup("message", "s", out message);
                if (app_id == null || app_id == "") continue;
                result += new BackgroundApp(app_id, instance ?? "", message ?? "");
            }
            return result;
        }

        public static string stop_command_template() {
            var file = new KeyFile();
            string[] dirs = { Environment.get_user_config_dir() };
            foreach (unowned string dir in Environment.get_system_config_dirs()) dirs += dir;
            foreach (unowned string dir in dirs) {
                try {
                    file.load_from_file(Path.build_filename(dir, CONFIG_FILE), KeyFileFlags.NONE);
                    return file.get_string("Stop", "Command").strip();
                } catch (Error e) {
                }
            }
            return DEFAULT_STOP_COMMAND;
        }

        public static string[] stop_argv(string template, BackgroundApp app) {
            string[] argv = {};
            try {
                Shell.parse_argv(template, out argv);
            } catch (ShellError e) {
                return {};
            }
            for (int i = 0; i < argv.length; i++) {
                argv[i] = argv[i].replace("{instance}", app.instance).replace("{app_id}", app.app_id);
            }
            return argv;
        }

        public async bool stop(BackgroundApp app) {
            if (yield quit_action(app.app_id)) return true;
            string template = stop_command_template();
            if (template == "") return false;
            string[] argv = stop_argv(template, app);
            if (argv.length == 0) return false;
            try {
                var process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                yield process.wait_async();
                return process.get_successful();
            } catch (Error e) {
                return false;
            }
        }

        private async bool quit_action(string app_id) {
            if (_conn == null || !DBus.is_name(app_id)) return false;
            string path = "/" + app_id.replace(".", "/").replace("-", "_");
            try {
                var reply = yield _conn.call(app_id, path, "org.freedesktop.Application", "ActivateAction",
                    new Variant("(sava{sv})", "quit", new VariantBuilder(new VariantType("av")),
                        new VariantBuilder(new VariantType("a{sv}"))),
                    null, DBusCallFlags.NO_AUTO_START, 3000, null);
                return reply != null;
            } catch (Error e) {
                return false;
            }
        }
    }
}
