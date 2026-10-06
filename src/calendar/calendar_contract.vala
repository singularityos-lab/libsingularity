using GLib;

namespace Singularity.Calendar {

    /**
     * Represents a single calendar event.
     */
    public struct CalendarEvent {
        /** Unique identifier for the event. */
        public string id;
        /** Human-readable title. */
        public string title;
        /** Optional longer description. */
        public string description;
        /** Start date and time. */
        public DateTime start_time;
        /** End date and time. */
        public DateTime end_time;
        /** CSS colour string used to tint the event in the UI. */
        public string color;
        /** Whether the event spans an entire day. */
        public bool all_day;
        public string location;
        public string recurrence;
        public string[] exdates;
        public string organizer;
        public string organizer_name;
        public Gee.ArrayList<CalendarAttendee>? attendees;
        public int[] alarms;
        public string calendar_id;
        public DateTime? occurrence_start;

        public bool is_recurring() {
            return recurrence != null && recurrence != "";
        }

        public string series_key() {
            return occurrence_start != null ? id + "@" + RecurrenceRule.occurrence_key(occurrence_start) : id;
        }
    }

    public class CalendarAttendee : Object {
        public string name { get; set; default = ""; }
        public string email { get; set; default = ""; }
        public string role { get; set; default = "REQ-PARTICIPANT"; }
        public string status { get; set; default = "NEEDS-ACTION"; }

        public CalendarAttendee(string email, string name = "", string status = "NEEDS-ACTION") {
            this.email = email;
            this.name = name;
            this.status = status;
        }

        public string display_name() {
            return name != "" ? name : email;
        }

        public CalendarAttendee copy() {
            var other = new CalendarAttendee(email, name, status);
            other.role = role;
            return other;
        }
    }

    /**
     * Interface that calendar data sources must implement.
     *
     * Register a provider with `CalendarManager.register_provider()`.
     */
    public interface CalendarProvider : Object {
        /** Human-readable display name for this calendar source. */
        public abstract string name { get; }
        /** Unique machine-readable identifier. */
        public abstract string id { get; }
        /** Default colour (CSS string) for events from this source. */
        public abstract string color { get; }
        /** Whether events from this provider are shown in the calendar. */
        public abstract bool is_visible { get; set; }

        /** Emitted whenever the set of events may have changed. */
        public signal void events_changed();

        /**
         * Fetches events in the given time range.
         *
         * @param start Beginning of the query window (inclusive).
         * @param end   End of the query window (exclusive).
         * @return List of matching events.
         */
        public abstract async Gee.List<CalendarEvent?> get_events(DateTime start, DateTime end) throws Error;

        /**
         * Imports events from a file (e.g. an `.ics` file).
         *
         * @param path Filesystem path to the file to import.
         */
        public abstract async void import_file(string path) throws Error;
    }

    /**
     * Extension of CalendarProvider for mutable calendar sources.
     *
     * Implement this interface in addition to CalendarProvider when
     * the provider supports creating, updating, and deleting events.
     */
    public interface WritableCalendarProvider : CalendarProvider {
        /**
         * Adds a new event to this calendar.
         *
         * @param evt The event to add.
         */
        public abstract void add_event (CalendarEvent evt);

        /**
         * Deletes the event with the given ID.
         *
         * @param id Identifier of the event to remove.
         */
        public abstract void delete_event (string id);

        /**
         * Updates an existing event with new data.
         *
         * @param evt Updated event data; the `id` field must match an existing event.
         */
        public abstract void update_event (CalendarEvent evt);

        public abstract CalendarEvent? find_event (string id);

        public abstract async void export_file (string path) throws Error;
    }

    /**
     * Aggregates multiple CalendarProvider instances and exposes a unified event API.
     *
     * Obtain the shared instance via `get_default()`.
     */
    public class CalendarManager : Object {
        private static CalendarManager? _instance;
        private Gee.ArrayList<CalendarProvider> providers;
        private Gee.HashMap<string, ulong> _provider_handlers;

        /** Returns the shared CalendarManager instance, creating it on first call. */
        public static CalendarManager get_default() {
            if (_instance == null) {
                _instance = new CalendarManager();
            }
            return _instance;
        }

        private CalendarManager() {
            providers = new Gee.ArrayList<CalendarProvider>();
            _provider_handlers = new Gee.HashMap<string, ulong>();
        }

        /**
         * Generates a deterministic CSS colour string from a seed string.
         *
         * Useful for automatically assigning distinct colours to calendars.
         *
         * @param seed Any non-empty string (e.g. a calendar name or ID).
         * @return A hex colour string such as `#a23c7e`.
         */
        public static string generate_color(string seed) {
            uint hash = seed.hash();
            int r = (int)((hash & 0xFF0000) >> 16);
            int g = (int)((hash & 0x00FF00) >> 8);
            int b = (int)(hash & 0x0000FF);
            return "#%02x%02x%02x".printf((r % 156) + 50, (g % 156) + 50, (b % 156) + 50);
        }

        /** Emitted whenever any registered provider reports a change. */
        public signal void events_changed();

        /** Emitted when a provider is registered or removed. */
        public signal void providers_changed();

        /**
         * Registers a calendar provider.
         *
         * Events from the provider will be included in `get_events()`
         * when `CalendarProvider.is_visible` is true.
         *
         * @param provider The provider to register.
         */
        public void register_provider(CalendarProvider provider) {
            providers.add(provider);
            ulong handler_id = provider.events_changed.connect(() => {
                events_changed();
            });
            _provider_handlers[provider.id] = handler_id;
            providers_changed();
        }

        /**
         * Removes a previously registered provider by ID.
         *
         * @param id The CalendarProvider.id of the provider to remove.
         */
        public void unregister_provider(string id) {
            var provider = get_provider(id);
            if (provider != null) {
                if (_provider_handlers.has_key(id)) {
                    provider.disconnect(_provider_handlers[id]);
                    _provider_handlers.unset(id);
                }
                providers.remove(provider);
                events_changed();
                providers_changed();
            }
        }

        /**
         * Returns the provider with the given ID, or null if not registered.
         *
         * @param id The CalendarProvider.id to look up.
         */
        public CalendarProvider? get_provider(string id) {
            foreach (var p in providers) {
                if (p.id == id) return p;
            }
            return null;
        }

        public Gee.List<WritableCalendarProvider> get_writable_providers() {
            var result = new Gee.ArrayList<WritableCalendarProvider>();
            foreach (var p in providers) {
                if (p is WritableCalendarProvider) result.add((WritableCalendarProvider) p);
            }
            return result;
        }

        public async Gee.List<CalendarEvent?> search(string query, DateTime start, DateTime end) {
            var matches = new Gee.ArrayList<CalendarEvent?>();
            string needle = query.strip().casefold();
            if (needle == "") return matches;
            var events = yield get_events(start, end);
            foreach (var evt in events) {
                string haystack = "%s %s %s".printf(evt.title ?? "", evt.description ?? "", evt.location ?? "").casefold();
                if (haystack.contains(needle)) matches.add(evt);
            }
            matches.sort((a, b) => a.start_time.compare(b.start_time));
            return matches;
        }

        /** Returns the list of all registered providers. */
        public Gee.List<CalendarProvider> get_providers() {
            return providers;
        }

        /**
         * Aggregates events from all visible providers in the given time range.
         *
         * @param start Beginning of the query window (inclusive).
         * @param end   End of the query window (exclusive).
         * @return Combined list of events from all visible providers.
         */
        public async Gee.List<CalendarEvent?> get_events(DateTime start, DateTime end) {
            var all_events = new Gee.ArrayList<CalendarEvent?>();
            foreach (var provider in providers) {
                if (!provider.is_visible) continue;
                try {
                    var events = yield provider.get_events(start, end);
                    foreach (var evt in events) {
                        if (evt.calendar_id == null || evt.calendar_id == "") evt.calendar_id = provider.id;
                        all_events.add(evt);
                    }
                } catch (Error e) {
                    warning("Failed to fetch events from %s: %s", provider.name, e.message);
                }
            }
            return all_events;
        }

        /** Convenience: add event to the local (writable) provider. */
        public void add_local_event (CalendarEvent evt) {
            var local = get_provider ("local-provider") as WritableCalendarProvider;
            if (local != null) local.add_event (evt);
        }

        /** Convenience: delete event from the local provider. */
        public void delete_local_event (string id) {
            var local = get_provider ("local-provider") as WritableCalendarProvider;
            if (local != null) local.delete_event (id);
        }

        /** Convenience: update event in the local provider. */
        public void update_local_event (CalendarEvent evt) {
            var local = get_provider ("local-provider") as WritableCalendarProvider;
            if (local != null) local.update_event (evt);
        }
    }
}
