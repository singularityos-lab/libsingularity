using GLib;
using Gee;

namespace Singularity.Calendar {

    public class WebCalendarProvider : GLib.Object, CalendarProvider {
        private const int REFRESH_SECONDS = 1800;
        private ArrayList<CalendarEvent?> events = new ArrayList<CalendarEvent?>();
        private bool _is_visible = true;
        private string _name;
        private string _id;
        private string _color;
        private bool loaded = false;
        private bool fetching = false;
        private int64 fetched_at = 0;
        private uint refresh_source = 0;

        public string name { get { return _name; } }
        public string id { get { return _id; } }
        public string color { get { return _color; } }
        public string url { get; private set; }
        public string last_error { get; private set; default = ""; }
        public bool is_visible {
            get { return _is_visible; }
            set {
                if (_is_visible != value) {
                    _is_visible = value;
                    events_changed();
                }
            }
        }

        private static string list_path() {
            return GLib.Path.build_filename(LocalProvider.calendar_dir(), "subscriptions.ini");
        }

        private static KeyFile load_list() {
            var keyfile = new KeyFile();
            try {
                keyfile.load_from_file(list_path(), KeyFileFlags.NONE);
            } catch (Error e) {
            }
            return keyfile;
        }

        private static void save_list(KeyFile keyfile) {
            try {
                DirUtils.create_with_parents(LocalProvider.calendar_dir(), 0755);
                FileUtils.set_contents_full(list_path(), keyfile.to_data(), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning("Failed to save calendar subscriptions: %s", e.message);
            }
        }

        private string cache_path() {
            return GLib.Path.build_filename(LocalProvider.calendar_dir(), _id + ".ics");
        }

        public WebCalendarProvider(string id, string name, string url, string color) {
            _id = id;
            _name = name;
            _color = color;
            this.url = url;
        }

        public static string normalize_url(string text) {
            string value = text.strip();
            if (value.has_prefix("webcals://")) return "https://" + value.substring(10);
            if (value.has_prefix("webcal://")) return "https://" + value.substring(9);
            return value;
        }

        private static FileMonitor? list_monitor = null;

        public static void register_all(CalendarManager manager) {
            var list = load_list();
            if (list_monitor == null) {
                try {
                    DirUtils.create_with_parents(LocalProvider.calendar_dir(), 0755);
                    list_monitor = File.new_for_path(list_path()).monitor_file(FileMonitorFlags.NONE, null);
                    list_monitor.set_rate_limit(500);
                    list_monitor.changed.connect((file, other, type) => {
                        if (type != FileMonitorEvent.CHANGES_DONE_HINT && type != FileMonitorEvent.CREATED && type != FileMonitorEvent.DELETED) return;
                        sync_with_list(manager);
                    });
                } catch (Error e) {
                }
            }
            foreach (string group in list.get_groups()) {
                if (manager.get_provider(group) != null) continue;
                try {
                    var provider = new WebCalendarProvider(group,
                        list.get_string(group, "name"),
                        list.get_string(group, "url"),
                        list.has_key(group, "color") ? list.get_string(group, "color") : CalendarManager.generate_color(group));
                    if (list.has_key(group, "visible")) provider._is_visible = list.get_boolean(group, "visible");
                    manager.register_provider(provider);
                } catch (Error e) {
                    warning("Invalid calendar subscription %s: %s", group, e.message);
                }
            }
        }

        private static void sync_with_list(CalendarManager manager) {
            var list = load_list();
            var stale = new ArrayList<string>();
            foreach (var provider in manager.get_providers()) {
                if (provider is WebCalendarProvider && !list.has_group(provider.id)) stale.add(provider.id);
            }
            foreach (string id in stale) manager.unregister_provider(id);
            register_all(manager);
        }

        public static async WebCalendarProvider subscribe(CalendarManager manager, string name, string address, string? color = null) throws Error {
            string url = normalize_url(address);
            var uri = Uri.parse(url, UriFlags.NONE);
            string scheme = uri.get_scheme();
            if (scheme != "https" && scheme != "http") throw new IOError.INVALID_ARGUMENT(_("The address must start with https:// or webcal://"));
            var list = load_list();
            foreach (string group in list.get_groups()) {
                try {
                    if (list.get_string(group, "url") == url) throw new IOError.EXISTS(_("You are already subscribed to this calendar"));
                } catch (KeyFileError e) {
                }
            }
            string id = "web-" + Checksum.compute_for_string(ChecksumType.SHA1, url).substring(0, 12);
            string title = name.strip() != "" ? name.strip() : uri.get_host();
            var provider = new WebCalendarProvider(id, title, url, color ?? CalendarManager.generate_color(id));
            string body = yield provider.download();
            var document = Ics.parse(body);
            if (document.events.size == 0 && !body.contains("BEGIN:VCALENDAR")) {
                throw new IOError.INVALID_DATA(_("This address does not point to a calendar"));
            }
            provider.apply(body);
            provider.store();
            manager.register_provider(provider);
            return provider;
        }

        public void unsubscribe(CalendarManager manager) {
            var list = load_list();
            try {
                list.remove_group(_id);
            } catch (Error e) {
            }
            save_list(list);
            FileUtils.remove(cache_path());
            if (refresh_source != 0) {
                Source.remove(refresh_source);
                refresh_source = 0;
            }
            manager.unregister_provider(_id);
        }

        private void store() {
            var list = load_list();
            list.set_string(_id, "name", _name);
            list.set_string(_id, "url", url);
            list.set_string(_id, "color", _color);
            list.set_boolean(_id, "visible", _is_visible);
            save_list(list);
        }

        public void set_name(string value) {
            if (value.strip() == "" || value == _name) return;
            _name = value.strip();
            store();
            notify_property("name");
            events_changed();
        }

        public void set_color(string value) {
            if (value == _color) return;
            _color = value;
            store();
            notify_property("color");
            events_changed();
        }

        public void remember_visibility() {
            store();
        }

        private async string download() throws Error {
            var session = new Soup.Session();
            session.timeout = 30;
            session.user_agent = "Singularity-Calendar";
            var msg = new Soup.Message("GET", url);
            if (msg == null) throw new IOError.INVALID_ARGUMENT(_("The address is not valid"));
            msg.request_headers.append("Accept", "text/calendar, */*");
            var bytes = yield session.send_and_read_async(msg, Priority.DEFAULT, null);
            if (msg.status_code == 401 || msg.status_code == 403) throw new IOError.PERMISSION_DENIED(_("The calendar is private or the link has expired"));
            if (msg.status_code == 404) throw new IOError.NOT_FOUND(_("The calendar was not found at this address"));
            if (msg.status_code < 200 || msg.status_code >= 300) throw new IOError.FAILED(_("The server answered with error %u").printf(msg.status_code));
            unowned uint8[] data = bytes.get_data();
            if (data == null || data.length == 0) return "";
            var builder = new StringBuilder.sized(data.length + 1);
            builder.append_len((string) data, data.length);
            return builder.str;
        }

        private void apply(string body) {
            var document = Ics.parse(body);
            events = document.events;
            fetched_at = get_real_time();
            last_error = "";
            try {
                FileUtils.set_contents(cache_path(), body);
            } catch (Error e) {
            }
        }

        private void load_cache() {
            if (loaded) return;
            loaded = true;
            string body;
            try {
                FileUtils.get_contents(cache_path(), out body);
                events = Ics.parse(body).events;
            } catch (Error e) {
            }
            refresh_source = Timeout.add_seconds(REFRESH_SECONDS, () => {
                refresh.begin();
                return Source.CONTINUE;
            });
        }

        public async void refresh() {
            if (fetching) return;
            fetching = true;
            try {
                string body = yield download();
                apply(body);
                events_changed();
            } catch (Error e) {
                last_error = e.message;
                warning("Failed to refresh calendar %s: %s", _name, e.message);
            }
            fetching = false;
        }

        public async Gee.List<CalendarEvent?> get_events(DateTime start, DateTime end) throws Error {
            load_cache();
            if (fetched_at == 0 || get_real_time() - fetched_at > (int64) REFRESH_SECONDS * 1000000) {
                if (!fetching) {
                    fetched_at = get_real_time();
                    refresh.begin();
                }
            }
            return LocalProvider.expand(events, start, end, _id, _color);
        }

        public async void import_file(string path) throws Error {
            throw new IOError.NOT_SUPPORTED(_("Subscribed calendars are read-only"));
        }
    }
}
