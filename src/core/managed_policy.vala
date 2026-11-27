namespace Singularity {

    public class ManagedPolicy : Object {
        public const string DEFAULT_PATH = "/var/lib/sinty-it/policy.json";
        public const string ENV = "SINTY_POLICY_FILE";

        public const string SCREEN_LOCK_AFTER = "screen.lock-after";
        public const string USB_STORAGE = "usb.storage";
        public const string SIGNIN_NOTICE_TITLE = "signin.notice-title";
        public const string SIGNIN_NOTICE_TEXT = "signin.notice-text";
        public const string UPDATES_DEFER_DAYS = "updates.defer-days";
        public const string UPDATES_WINDOW = "updates.window";
        public const string KIOSK_APP = "kiosk.app";

        private static ManagedPolicy? instance;

        private string _path;
        private HashTable<string, string> _values = new HashTable<string, string>(str_hash, str_equal);
        private FileMonitor? _monitor;
        private FileMonitor? _parent_monitor;

        public signal void changed();

        public bool managed { get { return _values.size() > 0; } }

        public static ManagedPolicy get_default() {
            if (instance == null) instance = new ManagedPolicy(Environment.get_variable(ENV) ?? DEFAULT_PATH);
            return instance;
        }

        public ManagedPolicy(string path) {
            _path = path;
            watch();
            _values = read(_path);
        }

        public string? get_string(string key) {
            return _values.lookup(key);
        }

        public bool has(string key) {
            return _values.contains(key);
        }

        public int get_int(string key, int fallback) {
            var raw = _values.lookup(key);
            if (raw == null) return fallback;
            int64 v = 0;
            if (!int64.try_parse(raw.strip(), out v)) return fallback;
            if (v < int.MIN || v > int.MAX) return fallback;
            return (int) v;
        }

        public static HashTable<string, string> read(string path) {
            var values = new HashTable<string, string>(str_hash, str_equal);
            string text;
            try {
                if (!FileUtils.get_contents(path, out text)) return values;
            } catch (Error e) {
                return values;
            }
            var parser = new Json.Parser();
            try {
                parser.load_from_data(text);
            } catch (Error e) {
                warning("ManagedPolicy: %s: %s", path, e.message);
                return values;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return values;
            root.get_object().foreach_member((obj, name, node) => {
                if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(string)) return;
                values.insert(name, node.get_string());
            });
            return values;
        }

        private void watch() {
            var dir = File.new_for_path(_path).get_parent();
            if (dir == null) return;
            watch_dir();
            var grand = dir.get_parent();
            if (grand == null) return;
            try {
                _parent_monitor = grand.monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
                _parent_monitor.changed.connect((f, other, ev) => {
                    if (f.get_basename() != dir.get_basename()) return;
                    if (ev == FileMonitorEvent.CREATED || ev == FileMonitorEvent.MOVED_IN) {
                        watch_dir();
                    }
                    reload();
                });
            } catch (Error e) {
                _parent_monitor = null;
            }
        }

        private void watch_dir() {
            var file = File.new_for_path(_path);
            var dir = file.get_parent();
            _monitor = null;
            try {
                _monitor = dir.monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
                _monitor.changed.connect((f, other, ev) => {
                    if (f.get_basename() == file.get_basename() || (other != null && other.get_basename() == file.get_basename())) reload();
                });
            } catch (Error e) {
                _monitor = null;
            }
        }

        private void reload() {
            var next = read(_path);
            if (same(next, _values)) return;
            _values = next;
            changed();
        }

        private static bool same(HashTable<string, string> a, HashTable<string, string> b) {
            if (a.size() != b.size()) return false;
            bool equal = true;
            a.foreach((k, v) => {
                if (b.lookup(k) != v) equal = false;
            });
            return equal;
        }
    }
}
