using GLib;

namespace Singularity {

    [CCode (cname = "SINGULARITY_SYSCONFDIR")]
    extern const string POWER_SYSCONFDIR;
    [CCode (cname = "SINGULARITY_SUSPEND_COMMAND")]
    extern const string POWER_DEFAULT_SUSPEND_COMMAND;

    public class PowerConfig : Object {
        public const string FILE_NAME = "singularity/power.conf";

        private static PowerConfig? _instance = null;
        private KeyFile keyfile = new KeyFile();

        public string? source_path { get; private set; default = null; }

        public static PowerConfig get_default() {
            if (_instance == null) _instance = new PowerConfig();
            return _instance;
        }

        public PowerConfig() {
            reload();
        }

        public PowerConfig.from_file(string path) {
            load_file(path);
        }

        public static string[] search_dirs() {
            string[] dirs = {};
            foreach (unowned string dir in Environment.get_system_config_dirs()) dirs += dir;
            dirs += POWER_SYSCONFDIR;
            return dirs;
        }

        public void reload() {
            keyfile = new KeyFile();
            source_path = null;
            foreach (string dir in search_dirs()) {
                string path = Path.build_filename(dir, FILE_NAME);
                if (FileUtils.test(path, FileTest.IS_REGULAR) && load_file(path)) return;
            }
        }

        private bool load_file(string path) {
            try {
                keyfile.load_from_file(path, KeyFileFlags.NONE);
                source_path = path;
                return true;
            } catch (Error e) {
                warning("PowerConfig: cannot read %s: %s", path, e.message);
                keyfile = new KeyFile();
                return false;
            }
        }

        public string get_string(string group, string key, string fallback) {
            try {
                if (keyfile.has_group(group) && keyfile.has_key(group, key)) return keyfile.get_string(group, key).strip();
            } catch (Error e) {
                warning("PowerConfig: [%s] %s: %s", group, key, e.message);
            }
            return fallback;
        }
    }

    public interface SuspendBackend : Object {
        public abstract string name { owned get; }
        public abstract async bool is_available();
        public abstract async void suspend() throws Error;
    }

    public class LogindSuspendBackend : Object, SuspendBackend {
        public string name {
            owned get { return FileUtils.test("/run/systemd/system", FileTest.IS_DIR) ? "logind" : "elogind"; }
        }

        public async bool is_available() {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                var reply = yield bus.call("org.freedesktop.login1", "/org/freedesktop/login1",
                    "org.freedesktop.login1.Manager", "CanSuspend", null,
                    new VariantType("(s)"), DBusCallFlags.NONE, 3000, null);
                string answer;
                reply.get("(s)", out answer);
                return answer == "yes" || answer == "challenge";
            } catch (Error e) {
                debug("LogindSuspendBackend: %s", e.message);
                return false;
            }
        }

        public async void suspend() throws Error {
            var bus = yield Bus.get(BusType.SYSTEM);
            yield bus.call("org.freedesktop.login1", "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager", "Suspend", new Variant("(b)", true),
                null, DBusCallFlags.NONE, -1, null);
        }
    }

    public class CommandSuspendBackend : Object, SuspendBackend {
        public string command_line { get; construct; }

        public string name {
            owned get { return "command"; }
        }

        public CommandSuspendBackend(string command_line) {
            Object(command_line: command_line);
        }

        public async bool is_available() {
            string[] argv;
            try {
                if (!GLib.Shell.parse_argv(command_line, out argv) || argv.length == 0) return false;
            } catch (ShellError e) {
                return false;
            }
            if (Path.is_absolute(argv[0])) return FileUtils.test(argv[0], FileTest.IS_EXECUTABLE);
            return Environment.find_program_in_path(argv[0]) != null;
        }

        public async void suspend() throws Error {
            string[] argv;
            GLib.Shell.parse_argv(command_line, out argv);
            var process = new Subprocess.newv(argv, SubprocessFlags.NONE);
            yield process.wait_check_async(null);
        }
    }

    public class PowerActions : Object {
        private static PowerActions? _instance = null;
        private bool resolved = false;

        public SuspendBackend? suspend_backend { get; private set; default = null; }
        public bool can_suspend { get; private set; default = false; }
        public signal void about_to_suspend();

        public static PowerActions get_default() {
            if (_instance == null) _instance = new PowerActions();
            return _instance;
        }

        public PowerActions() {
            resolve.begin();
        }

        public static SuspendBackend? backend_for(PowerConfig config, out string choice) {
            choice = config.get_string("Suspend", "Backend", "auto").down();
            string command = config.get_string("Suspend", "Command", POWER_DEFAULT_SUSPEND_COMMAND);
            switch (choice) {
                case "logind":
                case "elogind":
                    return new LogindSuspendBackend();
                case "command":
                    return command != "" ? new CommandSuspendBackend(command) : null;
                case "none":
                    return null;
                default:
                    choice = "auto";
                    return null;
            }
        }

        public async void resolve() {
            string choice;
            var config = PowerConfig.get_default();
            SuspendBackend? backend = backend_for(config, out choice);
            if (choice == "auto") {
                var logind = new LogindSuspendBackend();
                if (yield logind.is_available()) {
                    backend = logind;
                } else {
                    string command = config.get_string("Suspend", "Command", POWER_DEFAULT_SUSPEND_COMMAND);
                    if (command != "") backend = new CommandSuspendBackend(command);
                }
            }
            bool available = backend != null && yield backend.is_available();
            suspend_backend = available ? backend : null;
            can_suspend = available;
            resolved = true;
            debug("PowerActions: suspend backend %s", available ? backend.name : "none");
        }

        private static bool lockscreen_flag(string key) {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.lockscreen", true) : null;
            if (schema == null || !schema.has_key(key)) return true;
            return new GLib.Settings("dev.sinty.lockscreen").get_boolean(key);
        }

        public async void suspend() throws Error {
            if (!resolved) yield resolve();
            if (suspend_backend == null) {
                throw new IOError.NOT_SUPPORTED(_("Suspend is not available on this system"));
            }
            about_to_suspend();
            if (lockscreen_flag("lock-on-suspend")) {
                lock_screen();
                Timeout.add(700, suspend.callback);
                yield;
            }
            yield suspend_backend.suspend();
        }

        public void lock_screen() {
            string command = PowerConfig.get_default().get_string("Lock", "Command", "");
            if (command == "") {
                SessionManager.get_default().lock_screen();
                return;
            }
            try {
                Process.spawn_command_line_async(command);
            } catch (Error e) {
                warning("PowerActions: lock command failed: %s", e.message);
                SessionManager.get_default().lock_screen();
            }
        }
    }
}
