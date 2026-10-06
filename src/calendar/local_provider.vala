using GLib;
using Gee;
using Json;

namespace Singularity.Calendar {

    public class LocalProvider : GLib.Object, CalendarProvider, WritableCalendarProvider {
        private ArrayList<CalendarEvent?> events;
        private bool _is_visible = true;
        private File storage_file;
        private FileMonitor? monitor = null;
        private bool loaded = false;
        private bool saving = false;
        private string _name;
        private string _id;
        private string _color;
        public string name { get { return _name; } }
        public string id { get { return _id; } }
        public string color { get { return _color; } }
        public string filename { get; private set; }
        public bool is_visible {
            get { return _is_visible; }
            set {
                if (_is_visible != value) {
                    _is_visible = value;
                    events_changed();
                }
            }
        }

        public static string calendar_dir() {
            return GLib.Path.build_filename(Environment.get_user_data_dir(), "singularity", "calendar");
        }

        private static string metadata_path() {
            return GLib.Path.build_filename(calendar_dir(), "calendars.ini");
        }

        private static KeyFile load_metadata() {
            var keyfile = new KeyFile();
            try {
                keyfile.load_from_file(metadata_path(), KeyFileFlags.NONE);
            } catch (Error e) {
            }
            return keyfile;
        }

        private static void save_metadata(KeyFile keyfile) {
            try {
                DirUtils.create_with_parents(calendar_dir(), 0755);
                keyfile.save_to_file(metadata_path());
            } catch (Error e) {
                warning("Failed to save calendar list: %s", e.message);
            }
        }

        public LocalProvider(string name = "Local", string id = "local-provider", string filename = "local.json", string color = "#3584e4") {
            this._id = id;
            this.filename = filename;
            var meta = load_metadata();
            try {
                this._name = meta.has_group(id) && meta.has_key(id, "name") ? meta.get_string(id, "name") : name;
                this._color = meta.has_group(id) && meta.has_key(id, "color") ? meta.get_string(id, "color") : color;
                if (meta.has_group(id) && meta.has_key(id, "visible")) this._is_visible = meta.get_boolean(id, "visible");
            } catch (Error e) {
                this._name = name;
                this._color = color;
            }
            events = new ArrayList<CalendarEvent?>();
            DirUtils.create_with_parents(calendar_dir(), 0755);
            storage_file = File.new_for_path(GLib.Path.build_filename(calendar_dir(), filename));
            try {
                monitor = storage_file.monitor_file(FileMonitorFlags.NONE, null);
                monitor.set_rate_limit(300);
                monitor.changed.connect((file, other, type) => {
                    if (saving) return;
                    if (type != FileMonitorEvent.CHANGES_DONE_HINT && type != FileMonitorEvent.CREATED && type != FileMonitorEvent.DELETED) return;
                    if (!loaded) return;
                    load_events();
                    events_changed();
                });
            } catch (Error e) {
            }
        }

        public static void register_all(CalendarManager manager) {
            var dir = File.new_for_path(calendar_dir());
            DirUtils.create_with_parents(calendar_dir(), 0755);
            if (manager.get_provider("local-provider") == null) manager.register_provider(new LocalProvider());
            try {
                var enumerator = dir.enumerate_children(FileAttribute.STANDARD_NAME, 0);
                FileInfo info;
                while ((info = enumerator.next_file()) != null) {
                    string file = info.get_name();
                    if (!file.has_suffix(".json") || file == "local.json") continue;
                    string base_name = file.substring(0, file.length - 5);
                    string cal_id = "local-" + base_name;
                    if (manager.get_provider(cal_id) != null) continue;
                    manager.register_provider(new LocalProvider(base_name, cal_id, file, CalendarManager.generate_color(base_name)));
                }
            } catch (Error e) {
                warning("Failed to list local calendars: %s", e.message);
            }
        }

        public static LocalProvider create(CalendarManager manager, string display_name, string color) {
            string slug = display_name.down().replace(" ", "-");
            var cleaned = new StringBuilder();
            unichar c;
            int index = 0;
            while (slug.get_next_char(ref index, out c)) {
                if (c.isalnum() || c == '-' || c == '_') cleaned.append_unichar(c);
            }
            string base_name = cleaned.len > 0 ? cleaned.str : "calendar";
            string candidate = base_name;
            int n = 2;
            while (manager.get_provider("local-" + candidate) != null
                    || FileUtils.test(GLib.Path.build_filename(calendar_dir(), candidate + ".json"), FileTest.EXISTS)) {
                candidate = "%s-%d".printf(base_name, n++);
            }
            var provider = new LocalProvider(display_name, "local-" + candidate, candidate + ".json", color);
            provider.store_metadata();
            provider.ensure_loaded();
            provider.save_events();
            manager.register_provider(provider);
            return provider;
        }

        private void store_metadata() {
            var meta = load_metadata();
            meta.set_string(_id, "name", _name);
            meta.set_string(_id, "color", _color);
            meta.set_boolean(_id, "visible", _is_visible);
            save_metadata(meta);
        }

        public void set_name(string value) {
            if (value.strip() == "" || value == _name) return;
            _name = value.strip();
            store_metadata();
            notify_property("name");
            events_changed();
        }

        public void set_color(string value) {
            if (value == _color) return;
            _color = value;
            store_metadata();
            notify_property("color");
            events_changed();
        }

        public void remember_visibility() {
            store_metadata();
        }

        public async Gee.List<CalendarEvent?> get_events(DateTime start, DateTime end) throws Error {
            ensure_loaded();
            return expand(events, start, end, _id, _color);
        }

        public static Gee.List<CalendarEvent?> expand(Gee.List<CalendarEvent?> source, DateTime start, DateTime end, string calendar_id, string fallback_color) {
            var result = new ArrayList<CalendarEvent?>();
            foreach (var evt in source) {
                if (!evt.is_recurring()) {
                    if (evt.start_time.compare(end) < 0 && evt.end_time.compare(start) > 0) {
                        CalendarEvent copy = evt;
                        copy.calendar_id = calendar_id;
                        if (copy.color == null || copy.color == "") copy.color = fallback_color;
                        result.add(copy);
                    }
                    continue;
                }
                var rule = RecurrenceRule.parse(evt.recurrence);
                if (rule == null) continue;
                int64 duration = evt.end_time.difference(evt.start_time);
                foreach (var occurrence in rule.occurrences(evt.start_time, start, end, evt.exdates, duration)) {
                    CalendarEvent copy = evt;
                    copy.start_time = occurrence;
                    copy.end_time = occurrence.add(duration);
                    copy.occurrence_start = occurrence;
                    copy.calendar_id = calendar_id;
                    if (copy.color == null || copy.color == "") copy.color = fallback_color;
                    result.add(copy);
                }
            }
            return result;
        }

        public CalendarEvent? find_event(string event_id) {
            ensure_loaded();
            foreach (var evt in events) {
                if (evt.id == event_id) {
                    CalendarEvent copy = evt;
                    copy.calendar_id = _id;
                    return copy;
                }
            }
            return null;
        }

        public async void import_file(string path) throws Error {
            ensure_loaded();
            uint8[] contents;
            FileUtils.get_data(path, out contents);
            var doc = Ics.parse((string) contents);
            foreach (CalendarEvent evt in doc.events) {
                evt.color = "";
                evt.calendar_id = _id;
                bool replaced = false;
                for (int i = 0; i < events.size; i++) {
                    if (events[i].id == evt.id) {
                        events[i] = evt;
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) events.add(evt);
            }
            if (doc.events.size > 0) {
                save_events();
                events_changed();
            }
        }

        public async void export_file(string path) throws Error {
            ensure_loaded();
            FileUtils.set_contents(path, Ics.serialize(events));
        }

        private static string member_string(Json.Object obj, string name) {
            if (!obj.has_member(name)) return "";
            var node = obj.get_member(name);
            if (node.get_node_type() != Json.NodeType.VALUE) return "";
            return node.get_string() ?? "";
        }

        private void load_events() {
            events.clear();
            if (!storage_file.query_exists()) return;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(storage_file.get_path());
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return;
                root.get_array().foreach_element((arr, index, node) => {
                    if (node.get_node_type() != Json.NodeType.OBJECT) return;
                    var obj = node.get_object();
                    CalendarEvent evt = CalendarEvent();
                    evt.id = member_string(obj, "id");
                    if (evt.id == "") evt.id = Uuid.string_random();
                    evt.title = member_string(obj, "title");
                    evt.description = member_string(obj, "description");
                    evt.color = member_string(obj, "color");
                    evt.location = member_string(obj, "location");
                    evt.recurrence = member_string(obj, "recurrence");
                    evt.organizer = member_string(obj, "organizer");
                    evt.organizer_name = member_string(obj, "organizer_name");
                    evt.calendar_id = _id;
                    evt.all_day = obj.has_member("all_day") ? obj.get_boolean_member("all_day") : false;
                    string start_str = member_string(obj, "start_time");
                    if (start_str == "") return;
                    var parsed_start = new DateTime.from_iso8601(start_str, new TimeZone.local());
                    if (parsed_start == null) return;
                    evt.start_time = parsed_start.to_local();
                    var parsed_end = new DateTime.from_iso8601(member_string(obj, "end_time"), new TimeZone.local());
                    evt.end_time = parsed_end != null ? parsed_end.to_local() : evt.start_time.add_hours(1);
                    string[] exdates = {};
                    if (obj.has_member("exdates") && obj.get_member("exdates").get_node_type() == Json.NodeType.ARRAY) {
                        obj.get_array_member("exdates").foreach_element((a, i, n) => {
                            if (n.get_node_type() == Json.NodeType.VALUE) exdates += n.get_string();
                        });
                    }
                    evt.exdates = exdates;
                    int[] alarms = {};
                    if (obj.has_member("alarms") && obj.get_member("alarms").get_node_type() == Json.NodeType.ARRAY) {
                        obj.get_array_member("alarms").foreach_element((a, i, n) => {
                            if (n.get_node_type() == Json.NodeType.VALUE) alarms += (int) n.get_int();
                        });
                    }
                    evt.alarms = alarms;
                    evt.attendees = new Gee.ArrayList<CalendarAttendee>();
                    if (obj.has_member("attendees") && obj.get_member("attendees").get_node_type() == Json.NodeType.ARRAY) {
                        obj.get_array_member("attendees").foreach_element((a, i, n) => {
                            if (n.get_node_type() != Json.NodeType.OBJECT) return;
                            var o = n.get_object();
                            var attendee = new CalendarAttendee(member_string(o, "email"), member_string(o, "name"),
                                member_string(o, "status") != "" ? member_string(o, "status") : "NEEDS-ACTION");
                            if (member_string(o, "role") != "") attendee.role = member_string(o, "role");
                            evt.attendees.add(attendee);
                        });
                    }
                    events.add(evt);
                });
            } catch (Error e) {
                warning("Failed to load events: %s", e.message);
            }
        }

        private void ensure_loaded() {
            if (loaded) return;
            loaded = true;
            load_events();
        }

        private void save_events() {
            var builder = new Json.Builder();
            builder.begin_array();
            foreach (var evt in events) {
                builder.begin_object();
                builder.set_member_name("id");
                builder.add_string_value(evt.id);
                builder.set_member_name("title");
                builder.add_string_value(evt.title ?? "");
                builder.set_member_name("description");
                builder.add_string_value(evt.description ?? "");
                builder.set_member_name("color");
                builder.add_string_value(evt.color ?? "");
                builder.set_member_name("all_day");
                builder.add_boolean_value(evt.all_day);
                builder.set_member_name("start_time");
                builder.add_string_value(evt.start_time.format_iso8601());
                builder.set_member_name("end_time");
                builder.add_string_value(evt.end_time.format_iso8601());
                if (evt.location != null && evt.location != "") {
                    builder.set_member_name("location");
                    builder.add_string_value(evt.location);
                }
                if (evt.is_recurring()) {
                    builder.set_member_name("recurrence");
                    builder.add_string_value(evt.recurrence);
                }
                if (evt.exdates != null && evt.exdates.length > 0) {
                    builder.set_member_name("exdates");
                    builder.begin_array();
                    foreach (string ex in evt.exdates) builder.add_string_value(ex);
                    builder.end_array();
                }
                if (evt.alarms != null && evt.alarms.length > 0) {
                    builder.set_member_name("alarms");
                    builder.begin_array();
                    foreach (int minutes in evt.alarms) builder.add_int_value(minutes);
                    builder.end_array();
                }
                if (evt.organizer != null && evt.organizer != "") {
                    builder.set_member_name("organizer");
                    builder.add_string_value(evt.organizer);
                    builder.set_member_name("organizer_name");
                    builder.add_string_value(evt.organizer_name ?? "");
                }
                if (evt.attendees != null && evt.attendees.size > 0) {
                    builder.set_member_name("attendees");
                    builder.begin_array();
                    foreach (var attendee in evt.attendees) {
                        builder.begin_object();
                        builder.set_member_name("email");
                        builder.add_string_value(attendee.email);
                        builder.set_member_name("name");
                        builder.add_string_value(attendee.name);
                        builder.set_member_name("role");
                        builder.add_string_value(attendee.role);
                        builder.set_member_name("status");
                        builder.add_string_value(attendee.status);
                        builder.end_object();
                    }
                    builder.end_array();
                }
                builder.end_object();
            }
            builder.end_array();
            var generator = new Json.Generator();
            generator.pretty = true;
            generator.set_root(builder.get_root());
            saving = true;
            try {
                FileUtils.set_contents(storage_file.get_path(), generator.to_data(null));
            } catch (Error e) {
                warning("Failed to save events: %s", e.message);
            }
            Timeout.add(600, () => {
                saving = false;
                return Source.REMOVE;
            });
        }

        private static CalendarEvent stored(CalendarEvent evt) {
            CalendarEvent copy = evt;
            copy.occurrence_start = null;
            if (copy.exdates == null) copy.exdates = {};
            if (copy.alarms == null) copy.alarms = {};
            return copy;
        }

        public void add_event(CalendarEvent evt) {
            ensure_loaded();
            events.add(stored(evt));
            save_events();
            events_changed();
        }

        public void delete_event(string event_id) {
            ensure_loaded();
            for (int i = 0; i < events.size; i++) {
                if (events[i].id == event_id) {
                    events.remove_at(i);
                    save_events();
                    events_changed();
                    return;
                }
            }
        }

        public void update_event(CalendarEvent evt) {
            ensure_loaded();
            for (int i = 0; i < events.size; i++) {
                if (events[i].id == evt.id) {
                    events[i] = stored(evt);
                    save_events();
                    events_changed();
                    return;
                }
            }
        }

        public void delete() {
            try {
                if (storage_file.query_exists()) storage_file.delete();
            } catch (Error e) {
                warning("Failed to delete calendar storage: %s", e.message);
            }
            var meta = load_metadata();
            try {
                if (meta.has_group(_id)) meta.remove_group(_id);
            } catch (Error e) {
            }
            save_metadata(meta);
        }
    }
}
