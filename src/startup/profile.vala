namespace Singularity.Startup {

    public class Profile : Object {
        private const int MAX_TASKS = 128;
        private const double WEIGHT = 0.3;
        private const int TRUSTED_RUNS = 3;

        private File file;
        private string fingerprint;
        private Gee.HashMap<string, double?> durations = new Gee.HashMap<string, double?>();
        private int runs = 0;

        private Profile(File file, string fingerprint) {
            this.file = file;
            this.fingerprint = fingerprint;
        }

        public static string condition_of(Request request) {
            return request.kind.to_id() + (request.files().length > 0 ? "-files" : "");
        }

        private static string binary_identity() {
            try {
                var exe = File.new_for_path(FileUtils.read_link("/proc/self/exe"));
                var info = exe.query_info("time::modified,standard::size", FileQueryInfoFlags.NONE);
                return "%lld-%lld".printf(info.get_size(), info.get_attribute_uint64("time::modified"));
            } catch (Error e) {
                return "unknown";
            }
        }

        public static Profile load(string app_id, Plan plan, Request request) {
            var dir = Path.build_filename(Environment.get_user_state_dir(), "singularity", "startup");
            string name = Checksum.compute_for_string(ChecksumType.SHA256, app_id + "\n" + condition_of(request)).substring(0, 24);
            string fingerprint = "%s|%s|%s".printf(plan.kind.to_id(), plan.version, binary_identity());
            var profile = new Profile(File.new_for_path(Path.build_filename(dir, name + ".json")), fingerprint);
            try {
                var parser = new Json.Parser();
                parser.load_from_file(profile.file.get_path());
                var root = parser.get_root().get_object();
                if (root.get_string_member("fingerprint") != fingerprint) return profile;
                profile.runs = (int) root.get_int_member("runs");
                var tasks = root.get_object_member("tasks");
                foreach (var id in tasks.get_members()) {
                    if (plan.get_task(id) != null) profile.durations[id] = tasks.get_double_member(id);
                }
            } catch (Error e) {
            }
            return profile;
        }

        public bool trusted() {
            return runs >= TRUSTED_RUNS;
        }

        public void apply(Runner runner) {
            if (!trusted()) return;
            foreach (var e in durations.entries) runner.predict(e.key, (int64) e.value);
        }

        public void record(Runner runner) {
            int count = 0;
            foreach (var t in runner.plan.tasks()) {
                if (t.state != TaskState.DONE || t.cached || count >= MAX_TASKS) continue;
                double now = (double) t.duration_us();
                durations[t.id] = durations.has_key(t.id) ? durations[t.id] * (1 - WEIGHT) + now * WEIGHT : now;
                count++;
            }
            runs++;
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("fingerprint");
            b.add_string_value(fingerprint);
            b.set_member_name("runs");
            b.add_int_value(runs);
            b.set_member_name("tasks");
            b.begin_object();
            foreach (var e in durations.entries) {
                b.set_member_name(e.key);
                b.add_double_value(e.value);
            }
            b.end_object();
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            try {
                DirUtils.create_with_parents(file.get_parent().get_path(), 0700);
                FileUtils.set_contents(file.get_path(), gen.to_data(null));
            } catch (Error e) {
            }
        }
    }
}
