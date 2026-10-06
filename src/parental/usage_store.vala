namespace Singularity.Parental {

    public class AppUsage : Object {
        public string app_id { get; construct; }
        public int64 seconds { get; set; }

        public AppUsage(string app_id, int64 seconds) {
            Object(app_id: app_id);
            this.seconds = seconds;
        }
    }

    public interface UsageStore : Object {
        public abstract void add(string day, string app_id, int64 seconds);
        public abstract Gee.List<AppUsage> day(string day);
        public abstract void flush() throws Error;
        public abstract void clear() throws Error;
        public abstract bool readable { get; }
    }

    public class JsonUsageStore : Object, UsageStore {
        public string path { get; construct; }
        public int retention_days { get; construct; }

        private Gee.TreeMap<string, Gee.HashMap<string, int64?>> days = new Gee.TreeMap<string, Gee.HashMap<string, int64?>>();
        private bool dirty = false;
        private bool _readable = true;

        public JsonUsageStore(string path, int retention_days = 35) {
            Object(path: path, retention_days: retention_days);
            load();
        }

        public bool readable {
            get { return _readable; }
        }

        public void load() {
            days.clear();
            _readable = true;
            if (!FileUtils.test(path, FileTest.EXISTS)) {
                string dir = Path.get_dirname(path);
                _readable = !FileUtils.test(dir, FileTest.EXISTS) || FileUtils.test(dir, FileTest.IS_DIR);
                return;
            }
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var days_obj = root.get_object().get_object_member("days");
                if (days_obj == null) return;
                foreach (string day_key in days_obj.get_members()) {
                    var apps_obj = days_obj.get_object_member(day_key);
                    if (apps_obj == null) continue;
                    var map = new Gee.HashMap<string, int64?>();
                    foreach (string app in apps_obj.get_members()) {
                        int64 secs = apps_obj.get_int_member(app);
                        if (secs > 0) map[app] = secs;
                    }
                    days[day_key] = map;
                }
            } catch (Error e) {
                _readable = !(e is FileError.ACCES);
                if (_readable) warning("Screen time: cannot read %s: %s", path, e.message);
            }
        }

        public void add(string day, string app_id, int64 seconds) {
            if (seconds <= 0 || app_id == "") return;
            var map = days[day];
            if (map == null) {
                map = new Gee.HashMap<string, int64?>();
                days[day] = map;
            }
            int64? current = map[app_id];
            map[app_id] = (current ?? 0) + seconds;
            dirty = true;
        }

        public Gee.List<AppUsage> day(string day) {
            var list = new Gee.ArrayList<AppUsage>();
            var map = days[day];
            if (map == null) return list;
            foreach (var entry in map.entries) list.add(new AppUsage(entry.key, entry.value));
            list.sort((a, b) => a.seconds == b.seconds ? strcmp(a.app_id, b.app_id) : (a.seconds > b.seconds ? -1 : 1));
            return list;
        }

        private void prune() {
            var cutoff = new DateTime.now_local().add_days(-retention_days).format("%Y-%m-%d");
            var old = new Gee.ArrayList<string>();
            foreach (string key in days.keys) {
                if (strcmp(key, cutoff) < 0) old.add(key);
            }
            foreach (string key in old) days.unset(key);
        }

        public void flush() throws Error {
            if (!dirty) return;
            prune();
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("version");
            builder.add_int_value(1);
            builder.set_member_name("days");
            builder.begin_object();
            foreach (var day_entry in days.entries) {
                builder.set_member_name(day_entry.key);
                builder.begin_object();
                foreach (var app_entry in day_entry.value.entries) {
                    builder.set_member_name(app_entry.key);
                    builder.add_int_value(app_entry.value);
                }
                builder.end_object();
            }
            builder.end_object();
            builder.end_object();
            var gen = new Json.Generator();
            gen.set_root(builder.get_root());
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            FileUtils.set_contents_full(path, gen.to_data(null), -1, FileSetContentsFlags.CONSISTENT, 0600);
            dirty = false;
        }

        public void clear() throws Error {
            days.clear();
            dirty = true;
            flush();
        }
    }

    public class UsageReport : Object {
        public static string day_key(DateTime date) {
            return date.format("%Y-%m-%d");
        }

        public static int64 total(Gee.List<AppUsage> apps) {
            int64 sum = 0;
            foreach (var app in apps) sum += app.seconds;
            return sum;
        }

        public static int64[] week_totals(UsageStore store, DateTime last_day) {
            int64[] totals = new int64[7];
            for (int i = 0; i < 7; i++) {
                totals[i] = total(store.day(day_key(last_day.add_days(i - 6))));
            }
            return totals;
        }

        public static Gee.List<AppUsage> week_apps(UsageStore store, DateTime last_day) {
            var sums = new Gee.HashMap<string, int64?>();
            for (int i = 0; i < 7; i++) {
                foreach (var app in store.day(day_key(last_day.add_days(i - 6)))) {
                    int64? current = sums[app.app_id];
                    sums[app.app_id] = (current ?? 0) + app.seconds;
                }
            }
            var list = new Gee.ArrayList<AppUsage>();
            foreach (var entry in sums.entries) list.add(new AppUsage(entry.key, entry.value));
            list.sort((a, b) => a.seconds == b.seconds ? strcmp(a.app_id, b.app_id) : (a.seconds > b.seconds ? -1 : 1));
            return list;
        }

        public static Gee.List<AppUsage> fold(Gee.List<AppUsage> apps, int keep, string other_id = "other") {
            var list = new Gee.ArrayList<AppUsage>();
            int64 rest = 0;
            for (int i = 0; i < apps.size; i++) {
                if (i < keep) list.add(apps[i]);
                else rest += apps[i].seconds;
            }
            if (rest > 0) list.add(new AppUsage(other_id, rest));
            return list;
        }

        public static string format_duration(int64 seconds) {
            int64 minutes = (seconds + 30) / 60;
            if (minutes < 1) return seconds > 0 ? _("Under 1 min") : _("0 min");
            if (minutes < 60) return _("%d min").printf((int) minutes);
            int64 h = minutes / 60;
            int64 m = minutes % 60;
            if (m == 0) return _("%d h").printf((int) h);
            return _("%d h %d min").printf((int) h, (int) m);
        }
    }
}
