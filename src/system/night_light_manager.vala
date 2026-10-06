namespace Singularity {

    public interface GammaBackend : GLib.Object {
        public abstract void set_night_light(int temperature);
        public abstract void reset_night_light();
    }

    public delegate double NightLightEase(double progress);

    public class NightLightManager : GLib.Object {
        public signal void changed();
        /** Effective active state (schedule-aware), what the quick tile shows. */
        public bool enabled { get; private set; default = false; }
        public const int TEMP_MIN = 1000;
        public const int TEMP_MAX = 6500;
        public const int TEMP_DEFAULT = 4000;

        public uint transition_ms { get; set; default = 0; }
        public string sun_source { get; private set; default = ""; }
        public bool has_location { get; private set; default = false; }
        public double latitude { get; private set; default = 0; }
        public double longitude { get; private set; default = 0; }

        private static NightLightManager? _instance;
        private GLib.Settings settings;
        private uint timer_id = 0;
        private bool _last_active = false;
        private int _last_temp = 0;
        private bool _applied = false;
        private GammaBackend? _backend;
        private NightLightEase? _ease = null;
        private int _shown_temp = TEMP_MAX;
        private uint _anim_id = 0;
        private bool _locating = false;
        private bool _geoclue_tried = false;

        /** Assigning a backend re-applies the current effective state to it. */
        public GammaBackend? backend {
            get { return _backend; }
            set {
                _backend = value;
                _applied = false;
                refresh();
            }
        }

        public static NightLightManager get_default() {
            if (_instance == null) _instance = new NightLightManager();
            return _instance;
        }

        construct {
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed.connect((key) => {
                if (key == "privacy-location-enabled") {
                    _geoclue_tried = false;
                    if (sun_source == "location") {
                        has_location = false;
                        sun_source = "";
                    }
                }
                if (key.has_prefix("night-light") || key == "privacy-location-enabled") refresh();
            });
            refresh();
        }

        public void set_ease(owned NightLightEase? ease) {
            _ease = (owned) ease;
        }

        private bool sun_schedule() {
            return settings.settings_schema.has_key("night-light-schedule")
                && settings.get_string("night-light-schedule") == "sunset-sunrise";
        }

        public string from_key() {
            return sun_schedule() ? "night-light-sun-from" : "night-light-adaptive-from";
        }

        public string to_key() {
            return sun_schedule() ? "night-light-sun-to" : "night-light-adaptive-to";
        }

        /** Recompute effective state from settings + schedule and apply to backend. */
        public void refresh() {
            if (settings.get_boolean("night-light-enabled") && settings.get_boolean("night-light-adaptive")
                    && sun_schedule()) {
                update_sun_times();
            }
            bool active = settings.get_boolean("night-light-enabled")
                          && (!settings.get_boolean("night-light-adaptive") || is_night());
            int temp = settings.get_int("night-light-temperature").clamp(TEMP_MIN, TEMP_MAX);
            bool state_changed = (active != _last_active || temp != _last_temp);
            if (backend != null && (!_applied || state_changed)) {
                bool animate = _applied && active != _last_active && transition_ms > 0;
                apply(active ? temp : TEMP_MAX, animate);
                _applied = true;
            }
            if (state_changed) {
                _last_active = active;
                _last_temp = temp;
                enabled = active;
                changed();
            }
            reschedule();
        }

        private void apply(int target, bool animate) {
            if (_anim_id != 0) {
                Source.remove(_anim_id);
                _anim_id = 0;
            }
            if (!animate || _shown_temp == target) {
                push(target);
                return;
            }
            int start = _shown_temp;
            int64 begin = GLib.get_monotonic_time();
            double duration = transition_ms * 1000.0;
            _anim_id = Timeout.add(16, () => {
                double t = ((GLib.get_monotonic_time() - begin) / duration).clamp(0.0, 1.0);
                double eased = _ease != null ? _ease(t) : t;
                if (t >= 1.0) {
                    _anim_id = 0;
                    push(target);
                    return Source.REMOVE;
                }
                push((int) Math.round(start + (target - start) * eased));
                return Source.CONTINUE;
            });
        }

        private void push(int temperature) {
            _shown_temp = temperature;
            if (backend == null) return;
            if (temperature >= TEMP_MAX) backend.reset_night_light();
            else backend.set_night_light(temperature);
        }

        public int shown_temperature { get { return _shown_temp; } }

        /** Flip the persisted master switch (used by the quick tile). */
        public void toggle() { settings.set_boolean("night-light-enabled", !settings.get_boolean("night-light-enabled")); }
        public void set_temperature(int k){ settings.set_int("night-light-temperature", k.clamp(TEMP_MIN, TEMP_MAX)); }
        public void set_adaptive(bool v)  { settings.set_boolean("night-light-adaptive", v); }
        public void set_schedule_from(string hhmm) { settings.set_string("night-light-adaptive-from", hhmm); }
        public void set_schedule_to(string hhmm)   { settings.set_string("night-light-adaptive-to", hhmm); }

        public void set_location(double lat, double lon, string source) {
            latitude = lat;
            longitude = lon;
            has_location = true;
            sun_source = source;
            refresh();
        }

        private void update_sun_times() {
            if (!has_location) {
                string? tz = SunTimes.local_timezone_id();
                double lat = 0, lon = 0;
                if (tz != null && SunTimes.timezone_coordinates(tz, out lat, out lon)) {
                    latitude = lat;
                    longitude = lon;
                    has_location = true;
                    sun_source = "timezone";
                }
            }
            if (sun_source != "location" && !_geoclue_tried && !_locating && location_allowed()) {
                _geoclue_tried = true;
                locate.begin();
            }
            if (!has_location) {
                write_if_changed("night-light-sun-source", "");
                return;
            }
            string sunset, sunrise;
            var day = SunTimes.local_times(latitude, longitude, new DateTime.now_local(), out sunset, out sunrise);
            if (day == SunDay.POLAR_DAY) {
                sunset = "00:00";
                sunrise = "00:00";
            } else if (day == SunDay.POLAR_NIGHT) {
                sunset = "00:00";
                sunrise = "23:59";
            }
            write_if_changed("night-light-sun-from", sunset);
            write_if_changed("night-light-sun-to", sunrise);
            write_if_changed("night-light-sun-source", sun_source);
        }

        private void write_if_changed(string key, string value) {
            if (!settings.settings_schema.has_key(key)) return;
            if (settings.get_string(key) != value) settings.set_string(key, value);
        }

        private bool location_allowed() {
            return !settings.settings_schema.has_key("privacy-location-enabled")
                || settings.get_boolean("privacy-location-enabled");
        }

        private async void locate() {
            _locating = true;
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                var reply = yield bus.call("org.freedesktop.GeoClue2", "/org/freedesktop/GeoClue2/Manager",
                    "org.freedesktop.GeoClue2.Manager", "GetClient", null, new VariantType("(o)"),
                    DBusCallFlags.NONE, 10000);
                string client;
                reply.get("(o)", out client);
                yield bus.call("org.freedesktop.GeoClue2", client, "org.freedesktop.DBus.Properties", "Set",
                    new Variant("(ssv)", "org.freedesktop.GeoClue2.Client", "DesktopId", new Variant.string("dev.sinty.desktop")),
                    null, DBusCallFlags.NONE, 5000);
                yield bus.call("org.freedesktop.GeoClue2", client, "org.freedesktop.DBus.Properties", "Set",
                    new Variant("(ssv)", "org.freedesktop.GeoClue2.Client", "RequestedAccuracyLevel", new Variant.uint32(4)),
                    null, DBusCallFlags.NONE, 5000);
                string? location_path = null;
                bool resumed = false;
                uint sub = bus.signal_subscribe("org.freedesktop.GeoClue2", "org.freedesktop.GeoClue2.Client",
                    "LocationUpdated", client, null, DBusSignalFlags.NONE, (c, s, p, i, n, parameters) => {
                        if (resumed) return;
                        resumed = true;
                        parameters.get("(oo)", null, out location_path);
                        locate.callback();
                    });
                uint timeout = 0;
                timeout = Timeout.add_seconds(30, () => {
                    timeout = 0;
                    if (!resumed) {
                        resumed = true;
                        locate.callback();
                    }
                    return Source.REMOVE;
                });
                yield bus.call("org.freedesktop.GeoClue2", client, "org.freedesktop.GeoClue2.Client", "Start",
                    null, null, DBusCallFlags.NONE, 10000);
                yield;
                bus.signal_unsubscribe(sub);
                if (timeout != 0) Source.remove(timeout);
                bus.call.begin("org.freedesktop.GeoClue2", client, "org.freedesktop.GeoClue2.Client", "Stop",
                    null, null, DBusCallFlags.NONE, 5000, null);
                if (location_path != null) {
                    var props = yield bus.call("org.freedesktop.GeoClue2", location_path,
                        "org.freedesktop.DBus.Properties", "GetAll", new Variant("(s)", "org.freedesktop.GeoClue2.Location"),
                        new VariantType("(a{sv})"), DBusCallFlags.NONE, 5000);
                    var dict = props.get_child_value(0);
                    var lat = dict.lookup_value("Latitude", VariantType.DOUBLE);
                    var lon = dict.lookup_value("Longitude", VariantType.DOUBLE);
                    if (lat != null && lon != null && location_allowed()) {
                        _locating = false;
                        message("NightLight: location from GeoClue");
                        set_location(lat.get_double(), lon.get_double(), "location");
                        return;
                    }
                }
            } catch (GLib.Error e) {
                message("NightLight: GeoClue unavailable, using the timezone: %s", e.message);
            }
            _locating = false;
        }

        private int parse_minutes(string hhmm, int fallback) {
            var parts = hhmm.split(":");
            if (parts.length != 2) return fallback;
            int h = int.parse(parts[0]);
            int m = int.parse(parts[1]);
            if (h < 0 || h > 23 || m < 0 || m > 59) return fallback;
            return h * 60 + m;
        }

        private bool is_night() {
            int from = parse_minutes(settings.get_string(from_key()), 19 * 60);
            int to   = parse_minutes(settings.get_string(to_key()), 7 * 60);
            if (from == to) return false;
            var now = new DateTime.now_local();
            int cur = now.get_hour() * 60 + now.get_minute();
            if (from < to) return cur >= from && cur < to;
            return cur >= from || cur < to;
        }

        private void reschedule() {
            if (timer_id != 0) {
                Source.remove(timer_id);
                timer_id = 0;
            }
            if (!settings.get_boolean("night-light-enabled")
                    || !settings.get_boolean("night-light-adaptive")) return;

            int from = parse_minutes(settings.get_string(from_key()), 19 * 60);
            int to   = parse_minutes(settings.get_string(to_key()), 7 * 60);
            var now = new DateTime.now_local();
            int cur = now.get_hour() * 60 + now.get_minute();
            int wait = 1440 - cur;
            if (from != to) {
                int d_from = (from - cur + 1440) % 1440;
                int d_to   = (to   - cur + 1440) % 1440;
                wait = int.min(wait, int.min(d_from == 0 ? 1440 : d_from, d_to == 0 ? 1440 : d_to));
            }
            uint secs = (uint) (wait * 60 - now.get_second() + 2);
            timer_id = Timeout.add_seconds(secs, () => {
                timer_id = 0;
                refresh();
                return Source.REMOVE;
            });
        }
    }
}
