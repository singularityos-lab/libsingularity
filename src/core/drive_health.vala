namespace Singularity {

    public enum DriveCondition {
        UNKNOWN,
        GOOD,
        WATCH,
        WORN,
        FAILING;

        public static DriveCondition parse(string state) {
            switch (state) {
                case "good": return GOOD;
                case "watch": return WATCH;
                case "worn": return WORN;
                case "failing": return FAILING;
            }
            return UNKNOWN;
        }
    }

    public class DriveHealth : Object {
        public const string BUS_NAME = "dev.sinty.DiskHealth";
        public const string OBJECT_PATH = "/dev/sinty/DiskHealth";
        public const string INTERFACE = "dev.sinty.DiskHealth1";
        public const string SIGNATURE = "(sssstsasxt)";

        public string key { get; set; default = ""; }
        public string device { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string serial { get; set; default = ""; }
        public uint64 size { get; set; }
        public DriveCondition condition { get; set; default = DriveCondition.UNKNOWN; }
        public string[] reasons { get; set; default = {}; }
        public int64 last_seen { get; set; }
        public uint64 real_size { get; set; }

        public bool troubled {
            get { return condition == DriveCondition.WORN || condition == DriveCondition.FAILING; }
        }

        public static DriveHealth? from_variant(Variant v) {
            if (!v.is_of_type(new VariantType(SIGNATURE))) return null;
            var h = new DriveHealth();
            h.key = v.get_child_value(0).get_string();
            h.device = v.get_child_value(1).get_string();
            h.name = v.get_child_value(2).get_string();
            h.serial = v.get_child_value(3).get_string();
            h.size = v.get_child_value(4).get_uint64();
            h.condition = DriveCondition.parse(v.get_child_value(5).get_string());
            h.reasons = v.get_child_value(6).get_strv();
            h.last_seen = v.get_child_value(7).get_int64();
            h.real_size = v.get_child_value(8).get_uint64();
            return h;
        }

        private static async Variant? call(string method, Variant? args, string reply) {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                return yield bus.call(BUS_NAME, OBJECT_PATH, INTERFACE, method, args,
                    new VariantType(reply), DBusCallFlags.NO_AUTO_START, 5000);
            } catch (Error e) {
                return null;
            }
        }

        public static async DriveHealth? lookup(string device) {
            if (device == "") return null;
            var r = yield call("Health", new Variant("(s)", device), "(" + SIGNATURE + ")");
            return r != null ? from_variant(r.get_child_value(0)) : null;
        }

        public static async Gee.List<DriveHealth> all() {
            var out = new Gee.ArrayList<DriveHealth>();
            var r = yield call("Drives", null, "(a" + SIGNATURE + ")");
            if (r == null) return out;
            var list = r.get_child_value(0);
            for (size_t i = 0; i < list.n_children(); i++) {
                var h = from_variant(list.get_child_value(i));
                if (h != null) out.add(h);
            }
            return out;
        }

        public static async void report_backup(string device, bool ok, string detail) {
            yield call("Report", new Variant("(ssbs)", device, "backup", ok, detail), "()");
        }

        public string summary() {
            switch (condition) {
                case DriveCondition.GOOD: return _("No problems found");
                case DriveCondition.WATCH: return _("A few errors, nothing to worry about yet");
                case DriveCondition.WORN: return _("Worn, copy your files to another drive");
                case DriveCondition.FAILING: return _("Failing, copy your files now");
            }
            return _("Not checked yet");
        }

        public string icon_name() {
            switch (condition) {
                case DriveCondition.WORN: return "dialog-warning-symbolic";
                case DriveCondition.FAILING: return "dialog-error-symbolic";
            }
            return "emblem-ok-symbolic";
        }

        public static string reason_text(string reason) {
            switch (reason) {
                case "fake-capacity": return _("It reports more space than it really has, files written past that point are lost.");
                case "smart-failing": return _("The drive itself reports that it is failing.");
                case "smart-worn": return _("The drive reports damaged areas.");
                case "unreadable": return _("Some parts of the drive could not be read back.");
                case "read-only": return _("Files could no longer be saved, so the drive was switched to read only.");
                case "check-failed": return _("A check of a Startup Key, a Key backup or a backup on this drive failed.");
                case "io-error": return _("Reading or writing failed several times.");
                case "timeout": return _("The drive stopped answering several times.");
                case "reset": return _("The drive disconnected and reconnected by itself several times.");
                case "slow-writes": return _("Saving files became much slower than usual.");
            }
            return reason;
        }

        public string explain() {
            string[] lines = {};
            foreach (var r in reasons) lines += reason_text(r);
            return string.joinv("\n", lines);
        }
    }

    public class DriveHealthMonitor : Object {
        private static DriveHealthMonitor? instance;
        private DBusConnection? bus;
        private uint subscription;

        public signal void changed(string key, DriveCondition condition, string[] reasons, bool alert);

        public static DriveHealthMonitor get_default() {
            if (instance == null) {
                instance = new DriveHealthMonitor();
                instance.follow.begin();
            }
            return instance;
        }

        private async void follow() {
            try {
                bus = yield Bus.get(BusType.SYSTEM);
            } catch (Error e) {
                return;
            }
            subscription = bus.signal_subscribe(null, DriveHealth.INTERFACE, "Changed", DriveHealth.OBJECT_PATH, null,
                DBusSignalFlags.NONE, (conn, sender, path, iface, name, args) => {
                    if (!args.is_of_type(new VariantType("(ssasb)"))) return;
                    changed(args.get_child_value(0).get_string(),
                        DriveCondition.parse(args.get_child_value(1).get_string()),
                        args.get_child_value(2).get_strv(),
                        args.get_child_value(3).get_boolean());
                });
        }
    }
}
