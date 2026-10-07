using GLib;

namespace Singularity.Calendar {
    public class TasksProvider : Object, CalendarProvider {
        public const string ID = "tasks";
        public const string EVENT_PREFIX = "task:";
        private FileMonitor? monitor;
        private bool _visible = true;

        public string name { get { return _("Tasks"); } }
        public string id { get { return ID; } }
        public string color { get { return "#26a269"; } }
        public bool is_visible {
            get { return _visible; }
            set {
                if (_visible == value) return;
                _visible = value;
                events_changed();
            }
        }

        public static string path() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "tasks", "tasks.json");
        }

        public static void register(CalendarManager manager) {
            if (manager.get_provider(ID) == null) manager.register_provider(new TasksProvider());
        }

        public static string? task_uid(string event_id) {
            return event_id.has_prefix(EVENT_PREFIX) ? event_id.substring(EVENT_PREFIX.length) : null;
        }

        construct {
            try {
                monitor = File.new_for_path(path()).monitor_file(FileMonitorFlags.NONE);
                monitor.changed.connect((f, o, ev) => {
                    if (ev == FileMonitorEvent.CHANGES_DONE_HINT || ev == FileMonitorEvent.CREATED || ev == FileMonitorEvent.DELETED) events_changed();
                });
            } catch (Error e) {
                warning("TasksProvider: %s", e.message);
            }
        }

        public async Gee.List<CalendarEvent?> get_events(DateTime start, DateTime end) throws Error {
            var result = new Gee.ArrayList<CalendarEvent?>();
            if (!FileUtils.test(path(), FileTest.EXISTS)) return result;
            var parser = new Json.Parser();
            parser.load_from_file(path());
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return result;
            var obj = root.get_object();
            if (!obj.has_member("tasks")) return result;
            foreach (var node in obj.get_array_member("tasks").get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var t = node.get_object();
                if (t.get_boolean_member_with_default("completed", false) || t.has_member("trashed_at")) continue;
                string due = t.get_string_member_with_default("due", "");
                if (due == "") continue;
                bool all_day = due.length == 10;
                DateTime? when = null;
                if (all_day) {
                    int y = 0, m = 0, d = 0;
                    if (due.scanf("%d-%d-%d", out y, out m, out d) == 3) when = new DateTime.local(y, m, d, 0, 0, 0);
                } else {
                    when = new DateTime.from_iso8601(due, new TimeZone.local());
                }
                if (when == null) continue;
                var finish = all_day ? when.add_days(1) : when.add_minutes(30);
                if (finish.compare(start) <= 0 || when.compare(end) >= 0) continue;
                CalendarEvent e = CalendarEvent();
                e.id = EVENT_PREFIX + t.get_string_member_with_default("uid", "");
                e.title = t.get_string_member_with_default("title", _("Untitled Task"));
                e.description = t.get_string_member_with_default("notes", "");
                e.start_time = when;
                e.end_time = finish;
                e.all_day = all_day;
                e.color = color;
                e.location = "";
                e.recurrence = "";
                e.exdates = {};
                e.organizer = "";
                e.organizer_name = "";
                e.attendees = null;
                e.alarms = {};
                e.calendar_id = ID;
                result.add(e);
            }
            return result;
        }

        public async void import_file(string path) throws Error {
            throw new IOError.NOT_SUPPORTED(_("Tasks cannot import calendar files"));
        }
    }
}
