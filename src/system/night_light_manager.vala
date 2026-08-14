namespace Singularity {

    public interface GammaBackend : GLib.Object {
        public abstract void set_night_light(int temperature);
        public abstract void reset_night_light();
    }

    public class NightLightManager : GLib.Object {
        public signal void changed();
        /** Effective active state (schedule-aware) — what the quick tile shows. */
        public bool enabled { get; private set; default = false; }
        public const int TEMP_MIN = 1000;
        public const int TEMP_MAX = 6500;
        public const int TEMP_DEFAULT = 4000;

        private static NightLightManager? _instance;
        private GLib.Settings settings;
        private uint timer_id = 0;
        private bool _last_active = false;
        private int _last_temp = 0;
        private bool _applied = false;
        private GammaBackend? _backend;

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
            settings.changed.connect((key) => { refresh(); });
            refresh();
        }

        /** Recompute effective state from settings + schedule and apply to backend. */
        public void refresh() {
            bool active = settings.get_boolean("night-light-enabled")
                          && (!settings.get_boolean("night-light-adaptive") || is_night());
            int temp = settings.get_int("night-light-temperature").clamp(TEMP_MIN, TEMP_MAX);
            bool state_changed = (active != _last_active || temp != _last_temp);
            if (backend != null && (!_applied || state_changed)) {
                if (active) backend.set_night_light(temp);
                else backend.reset_night_light();
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

        /** Flip the persisted master switch (used by the quick tile). */
        public void toggle() { settings.set_boolean("night-light-enabled", !settings.get_boolean("night-light-enabled")); }
        public void set_temperature(int k){ settings.set_int("night-light-temperature", k.clamp(TEMP_MIN, TEMP_MAX)); }
        public void set_adaptive(bool v)  { settings.set_boolean("night-light-adaptive", v); }
        public void set_schedule_from(string hhmm) { settings.set_string("night-light-adaptive-from", hhmm); }
        public void set_schedule_to(string hhmm)   { settings.set_string("night-light-adaptive-to", hhmm); }

        private int parse_minutes(string hhmm, int fallback) {
            var parts = hhmm.split(":");
            if (parts.length != 2) return fallback;
            int h = int.parse(parts[0]);
            int m = int.parse(parts[1]);
            if (h < 0 || h > 23 || m < 0 || m > 59) return fallback;
            return h * 60 + m;
        }

        private bool is_night() {
            int from = parse_minutes(settings.get_string("night-light-adaptive-from"), 19 * 60);
            int to   = parse_minutes(settings.get_string("night-light-adaptive-to"), 7 * 60);
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

            int from = parse_minutes(settings.get_string("night-light-adaptive-from"), 19 * 60);
            int to   = parse_minutes(settings.get_string("night-light-adaptive-to"), 7 * 60);
            if (from == to) return;
            var now = new DateTime.now_local();
            int cur = now.get_hour() * 60 + now.get_minute();
            int d_from = (from - cur + 1440) % 1440;
            int d_to   = (to   - cur + 1440) % 1440;
            int wait = int.min(d_from == 0 ? 1440 : d_from, d_to == 0 ? 1440 : d_to);
            uint secs = (uint) (wait * 60 - now.get_second() + 2);
            timer_id = Timeout.add_seconds(secs, () => {
                timer_id = 0;
                refresh();
                return Source.REMOVE;
            });
        }
    }
}
