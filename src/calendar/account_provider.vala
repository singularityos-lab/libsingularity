using Singularity.Accounts;

namespace Singularity.Calendar {

    /**
     * A calendar of an online account (CalDAV, Microsoft Graph), kept in a
     * local mirror and synchronised both ways.
     *
     * Edits made while offline are uploaded on the next sync. Properties
     * the Calendar app does not edit (categories, custom properties,
     * time zones) are kept when an event is changed.
     */
    public class AccountCalendarProvider : GLib.Object, CalendarProvider, WritableCalendarProvider {
        private SyncedCollection collection;
        private string _id;
        private string _color;
        private bool _is_visible = true;
        private Gee.HashMap<string, Gee.List<CalendarEvent?>> parsed = new Gee.HashMap<string, Gee.List<CalendarEvent?>>();
        private Gee.HashMap<string, string> parsed_from = new Gee.HashMap<string, string>();

        public string name { get { return collection.name; } }
        public string id { get { return _id; } }
        public string color { get { return _color; } }
        /** Name of the account the calendar belongs to. */
        public string account_name { get; private set; }
        /** Identifier of the account the calendar belongs to. */
        public string account_id { get { return collection.account_id; } }
        /** The synchronised collection behind the calendar. */
        public SyncedCollection synced { get { return collection; } }
        /** True when the server does not accept changes. */
        public bool read_only { get { return collection.read_only; } }

        public bool is_visible {
            get { return _is_visible; }
            set {
                if (_is_visible != value) {
                    _is_visible = value;
                    remember_visibility();
                    events_changed();
                }
            }
        }

        public AccountCalendarProvider(Account account, SyncedCollection collection) {
            this.collection = collection;
            _id = "account-%s-%s".printf(account.id, Checksum.compute_for_string(ChecksumType.SHA1, collection.remote.id).substring(0, 12));
            _color = collection.color != "" ? collection.color : CalendarManager.generate_color(collection.remote.id);
            account_name = account.display_name;
            var meta = load_state();
            try {
                if (meta.has_key(_id, "visible")) _is_visible = meta.get_boolean(_id, "visible");
            } catch (Error e) {
            }
            collection.changed.connect(() => events_changed());
        }

        private static string state_path() {
            return Path.build_filename(LocalProvider.calendar_dir(), "accounts.ini");
        }

        private static KeyFile load_state() {
            var kf = new KeyFile();
            try {
                kf.load_from_file(state_path(), KeyFileFlags.NONE);
            } catch (Error e) {
            }
            return kf;
        }

        /** Stores whether the calendar is shown. */
        public void remember_visibility() {
            var kf = load_state();
            kf.set_boolean(_id, "visible", _is_visible);
            try {
                DirUtils.create_with_parents(LocalProvider.calendar_dir(), 0755);
                kf.save_to_file(state_path());
            } catch (Error e) {
                warning("Failed to save calendar visibility: %s", e.message);
            }
        }

        private Gee.List<CalendarEvent?> events_of(SyncItem item) {
            string key = item.uid;
            if (parsed.has_key(key) && parsed_from[key] == item.data) return parsed[key];
            var list = new Gee.ArrayList<CalendarEvent?>();
            var doc = Ics.parse(item.data);
            foreach (CalendarEvent evt in doc.events) {
                evt.calendar_id = _id;
                list.add(evt);
            }
            parsed[key] = list;
            parsed_from[key] = item.data;
            return list;
        }

        private Gee.List<CalendarEvent?> all_events() {
            var all = new Gee.ArrayList<CalendarEvent?>();
            foreach (var item in collection.items()) all.add_all(events_of(item));
            return all;
        }

        public async Gee.List<CalendarEvent?> get_events(DateTime start, DateTime end) throws Error {
            return LocalProvider.expand(all_events(), start, end, _id, _color);
        }

        public CalendarEvent? find_event(string event_id) {
            foreach (var evt in all_events()) {
                if (evt.id == event_id) {
                    CalendarEvent copy = evt;
                    copy.calendar_id = _id;
                    return copy;
                }
            }
            return null;
        }

        private const string[] MANAGED = {
            "UID", "DTSTAMP", "DTSTART", "DTEND", "DURATION", "SUMMARY", "DESCRIPTION", "LOCATION",
            "RRULE", "EXDATE", "ORGANIZER", "ATTENDEE", "STATUS"
        };

        /**
         * Builds the iCalendar text for an event, keeping the unmanaged
         * properties and components of `previous` when given.
         */
        public static string compose(CalendarEvent evt, string? previous) {
            var list = new Gee.ArrayList<CalendarEvent?>();
            CalendarEvent copy = evt;
            copy.occurrence_start = null;
            list.add(copy);
            string fresh = Ics.serialize(list, "");
            if (previous == null || previous == "") return fresh;
            var old_root = Component.parse(previous);
            var new_root = Component.parse(fresh);
            if (old_root == null || new_root == null) return fresh;
            Component? old_event = null;
            foreach (var c in old_root.children) {
                if (c.name == "VEVENT" && c.get_line("RECURRENCE-ID") == null) {
                    old_event = c;
                    break;
                }
            }
            var new_event = new_root.get_child("VEVENT");
            if (old_event == null || new_event == null) return fresh;
            foreach (string name in MANAGED) old_event.remove(name);
            foreach (var line in new_event.lines) {
                if (line.name in MANAGED) old_event.lines.add(line);
            }
            var kept = new Gee.ArrayList<Component>();
            foreach (var c in old_event.children) if (c.name != "VALARM") kept.add(c);
            foreach (var c in new_event.children) if (c.name == "VALARM") kept.add(c);
            old_event.children = kept;
            int sequence = int.parse(old_event.get_value("SEQUENCE"));
            old_event.set_value("SEQUENCE", (sequence + 1).to_string());
            old_event.set_value("LAST-MODIFIED", Converters.ical_utc(new DateTime.now_utc()));
            old_root.remove("METHOD");
            return old_root.to_string();
        }

        private SyncItem? item_for(string event_id) {
            var direct = collection.get_item(event_id);
            if (direct != null) return direct;
            foreach (var item in collection.items()) {
                foreach (var evt in events_of(item)) if (evt.id == event_id) return item;
            }
            return null;
        }

        public void add_event(CalendarEvent evt) {
            if (evt.id == null || evt.id == "") evt.id = Uuid.string_random();
            collection.put(evt.id, compose(evt, null));
            events_changed();
        }

        public void update_event(CalendarEvent evt) {
            var item = item_for(evt.id);
            if (item == null) {
                add_event(evt);
                return;
            }
            if (item.uid != evt.id) {
                warning("Changing a single occurrence of %s on an online calendar is not supported", item.uid);
                return;
            }
            collection.put(item.uid, compose(evt, item.data));
            events_changed();
        }

        public void delete_event(string event_id) {
            var item = item_for(event_id);
            if (item == null) return;
            collection.remove(item.uid);
            events_changed();
        }

        public async void import_file(string path) throws Error {
            uint8[] contents;
            FileUtils.get_data(path, out contents);
            var doc = Ics.parse((string) contents);
            foreach (CalendarEvent evt in doc.events) {
                collection.put(evt.id, compose(evt, null));
            }
            events_changed();
        }

        public async void export_file(string path) throws Error {
            FileUtils.set_contents(path, Ics.serialize(all_events()));
        }
    }

    /**
     * Registers the calendars of every online account with the calendar
     * capability switched on, and keeps the registrations in step with
     * the accounts service.
     */
    public class AccountCalendars : GLib.Object {
        private static AccountCalendars? instance;
        private CalendarManager manager;
        private CollectionTracker tracker;
        private Gee.HashMap<SyncedCollection, AccountCalendarProvider> providers = new Gee.HashMap<SyncedCollection, AccountCalendarProvider>();

        /** The tracker behind the registrations, for sync status. */
        public CollectionTracker collections { get { return tracker; } }

        /**
         * Starts registering online calendars with `manager`. Calling it
         * again does nothing.
         */
        public static AccountCalendars register_all(CalendarManager manager) {
            if (instance == null) instance = new AccountCalendars(manager);
            return instance;
        }

        private AccountCalendars(CalendarManager manager) {
            this.manager = manager;
            tracker = new CollectionTracker(ContentKind.EVENTS);
            tracker.set_added.connect((cs) => sync_set(cs));
            tracker.collections_changed.connect((cs) => sync_set(cs));
            tracker.set_removed.connect((cs) => {
                foreach (var c in providers.keys.to_array()) {
                    if (c.account_id == cs.account.id) drop(c);
                }
            });
            tracker.start.begin();
        }

        private void sync_set(CollectionSet cs) {
            foreach (var c in providers.keys.to_array()) {
                if (c.account_id == cs.account.id && !(c in cs.collections)) drop(c);
            }
            foreach (var c in cs.collections) {
                if (providers.has_key(c)) continue;
                var p = new AccountCalendarProvider(cs.account, c);
                providers[c] = p;
                manager.register_provider(p);
            }
        }

        private void drop(SyncedCollection c) {
            var p = providers[c];
            if (p == null) return;
            providers.unset(c);
            manager.unregister_provider(p.id);
        }

        /** Syncs every online calendar now. */
        public async void refresh() {
            yield tracker.refresh_all();
        }
    }
}
