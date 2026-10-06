using GLib;

namespace Singularity {

    [CCode (cname = "SINGULARITY_CHARGE_LIMIT_COMMAND")]
    extern const string POWER_DEFAULT_CHARGE_LIMIT_COMMAND;

    public class BatteryHealth : Object {
        public string name { get; construct; }
        public string path { get; construct; }
        public string model { get; private set; default = ""; }
        public string status { get; private set; default = ""; }
        public int level { get; private set; default = -1; }
        public double full { get; private set; default = 0.0; }
        public double design { get; private set; default = 0.0; }
        public int cycles { get; private set; default = -1; }
        public int charge_limit { get; private set; default = -1; }

        public int health {
            get {
                if (full <= 0.0 || design <= 0.0) return -1;
                return (int) Math.round(double.min(full / design, 1.0) * 100.0);
            }
        }

        public bool limit_supported {
            get { return charge_limit >= 0; }
        }

        public BatteryHealth(string name, string path) {
            Object(name: name, path: path);
        }

        private string? read(string file) {
            try {
                string contents;
                if (FileUtils.get_contents(Path.build_filename(path, file), out contents)) return contents.strip();
            } catch (FileError e) {
            }
            return null;
        }

        private double read_number(string file) {
            string? value = read(file);
            if (value == null || value == "") return -1.0;
            return double.parse(value);
        }

        public void refresh() {
            model = read("model_name") ?? "";
            status = read("status") ?? "";
            level = (int) read_number("capacity");
            full = read_number("energy_full");
            design = read_number("energy_full_design");
            if (full <= 0.0 || design <= 0.0) {
                full = read_number("charge_full");
                design = read_number("charge_full_design");
            }
            cycles = (int) read_number("cycle_count");
            if (cycles <= 0) cycles = -1;
            string? limit = read("charge_control_end_threshold");
            charge_limit = limit != null && limit != "" ? int.parse(limit) : -1;
        }

        public static Gee.List<BatteryHealth> scan(string root) {
            var list = new Gee.ArrayList<BatteryHealth>();
            var names = new Gee.ArrayList<string>();
            try {
                var dir = Dir.open(root, 0);
                string? entry;
                while ((entry = dir.read_name()) != null) names.add(entry);
            } catch (FileError e) {
                return list;
            }
            names.sort((a, b) => strcmp(a, b));
            foreach (string entry in names) {
                string dir_path = Path.build_filename(root, entry);
                string type = "";
                string present = "1";
                try {
                    FileUtils.get_contents(Path.build_filename(dir_path, "type"), out type);
                } catch (FileError e) {
                    continue;
                }
                if (type.strip() != "Battery") continue;
                try {
                    string scope;
                    FileUtils.get_contents(Path.build_filename(dir_path, "scope"), out scope);
                    if (scope.strip() == "Device") continue;
                } catch (FileError e) {
                }
                try {
                    FileUtils.get_contents(Path.build_filename(dir_path, "present"), out present);
                } catch (FileError e) {
                }
                if (present.strip() == "0") continue;
                var battery = new BatteryHealth(entry, dir_path);
                battery.refresh();
                list.add(battery);
            }
            return list;
        }
    }

    public class HistoryPoint : Object {
        public uint32 time { get; construct; }
        public double value { get; construct; }

        public HistoryPoint(uint32 time, double value) {
            Object(time: time, value: value);
        }
    }

    public interface ChargeLimitBackend : Object {
        public abstract string name { owned get; }
        public abstract bool supports(BatteryHealth battery);
        public abstract async void set_limit(BatteryHealth battery, int percent) throws Error;
    }

    public class CommandChargeLimit : Object, ChargeLimitBackend {
        public string command_line { get; construct; }

        public string name {
            owned get { return "command"; }
        }

        public CommandChargeLimit(string command_line) {
            Object(command_line: command_line);
        }

        private string[]? argv() {
            string[] parsed;
            try {
                if (!GLib.Shell.parse_argv(command_line, out parsed) || parsed.length == 0) return null;
            } catch (ShellError e) {
                return null;
            }
            bool found = Path.is_absolute(parsed[0])
                ? FileUtils.test(parsed[0], FileTest.IS_EXECUTABLE)
                : Environment.find_program_in_path(parsed[0]) != null;
            return found ? parsed : null;
        }

        public bool supports(BatteryHealth battery) {
            return battery.limit_supported && argv() != null;
        }

        public async void set_limit(BatteryHealth battery, int percent) throws Error {
            string[]? args = argv();
            if (args == null) throw new IOError.NOT_SUPPORTED(_("The charge limit helper is not installed"));
            args += "charge-limit";
            args += battery.name;
            args += percent.clamp(50, 100).to_string();
            var process = new Subprocess.newv(args, SubprocessFlags.STDERR_PIPE);
            string? err;
            yield process.communicate_utf8_async(null, null, null, out err);
            if (!process.get_successful()) {
                string detail = err != null ? err.strip() : "";
                throw new IOError.FAILED(detail != "" ? detail : _("The charge limit could not be changed"));
            }
        }
    }

    public class BatteryManager : Object {
        public const int LIMIT_PERCENT = 80;

        private static BatteryManager? _instance = null;
        private Gee.List<BatteryHealth> _batteries = new Gee.ArrayList<BatteryHealth>();

        public string sysfs_root { get; construct; }
        public ChargeLimitBackend? charge_limit_backend { get; construct; }
        public signal void changed();

        public Gee.List<BatteryHealth> batteries {
            owned get { return _batteries.read_only_view; }
        }

        public static BatteryManager get_default() {
            if (_instance == null) _instance = BatteryManager.from_config(PowerConfig.get_default());
            return _instance;
        }

        public BatteryManager(string sysfs_root, ChargeLimitBackend? backend) {
            Object(sysfs_root: sysfs_root, charge_limit_backend: backend);
            refresh();
        }

        public static BatteryManager from_config(PowerConfig config) {
            string root = config.get_string("Battery", "SysfsPath", "/sys/class/power_supply");
            string choice = config.get_string("Battery", "ChargeLimit", "auto").down();
            string command = config.get_string("Battery", "ChargeLimitCommand", POWER_DEFAULT_CHARGE_LIMIT_COMMAND);
            ChargeLimitBackend? backend = null;
            if (choice != "none" && choice != "disabled" && command != "") backend = new CommandChargeLimit(command);
            return new BatteryManager(root, backend);
        }

        public void refresh() {
            _batteries = BatteryHealth.scan(sysfs_root);
            changed();
        }

        public BatteryHealth? primary {
            owned get { return _batteries.size > 0 ? _batteries[0] : null; }
        }

        public bool charge_limit_available {
            get {
                if (charge_limit_backend == null) return false;
                foreach (var battery in _batteries) {
                    if (charge_limit_backend.supports(battery)) return true;
                }
                return false;
            }
        }

        public bool charge_limit_active {
            get {
                foreach (var battery in _batteries) {
                    if (battery.limit_supported && battery.charge_limit <= LIMIT_PERCENT) return true;
                }
                return false;
            }
        }

        public async Gee.List<HistoryPoint> history(string battery_name, uint seconds, uint points) {
            var result = new Gee.ArrayList<HistoryPoint>();
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                var devices = yield bus.call("org.freedesktop.UPower", "/org/freedesktop/UPower",
                    "org.freedesktop.UPower", "EnumerateDevices", null,
                    new VariantType("(ao)"), DBusCallFlags.NONE, 3000, null);
                var iter = devices.get_child_value(0).iterator();
                string? device_path;
                while (iter.next("o", out device_path)) {
                    var native = yield bus.call("org.freedesktop.UPower", device_path,
                        "org.freedesktop.DBus.Properties", "Get",
                        new Variant("(ss)", "org.freedesktop.UPower.Device", "NativePath"),
                        new VariantType("(v)"), DBusCallFlags.NONE, 3000, null);
                    if (native.get_child_value(0).get_variant().get_string() != battery_name) continue;
                    var reply = yield bus.call("org.freedesktop.UPower", device_path,
                        "org.freedesktop.UPower.Device", "GetHistory",
                        new Variant("(suu)", "charge", seconds, points),
                        new VariantType("(a(udu))"), DBusCallFlags.NONE, 3000, null);
                    var items = reply.get_child_value(0).iterator();
                    uint32 time;
                    double value;
                    uint32 state;
                    while (items.next("(udu)", out time, out value, out state)) {
                        if (value > 0.0) result.add(new HistoryPoint(time, value));
                    }
                    break;
                }
            } catch (Error e) {
                debug("BatteryManager: no history: %s", e.message);
            }
            result.sort((a, b) => (int) (a.time > b.time) - (int) (a.time < b.time));
            return result;
        }

        public async void set_charge_limited(bool limited) throws Error {
            if (charge_limit_backend == null) throw new IOError.NOT_SUPPORTED(_("Charge limits are turned off on this system"));
            Error? failure = null;
            foreach (var battery in _batteries) {
                if (!charge_limit_backend.supports(battery)) continue;
                try {
                    yield charge_limit_backend.set_limit(battery, limited ? LIMIT_PERCENT : 100);
                } catch (Error e) {
                    failure = e;
                }
            }
            refresh();
            if (failure != null) throw failure;
        }
    }
}
