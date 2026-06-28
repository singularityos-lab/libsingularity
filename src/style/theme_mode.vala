namespace Singularity.Style {

    /**
     * The three valid appearance modes. The fourth conceptual combination
     * (light shell with dark apps) is intentionally not representable.
     */
    public enum ColorMode { DUAL, LIGHT, DARK }

    /**
     * Resolves the effective appearance from the dev.sinty.desktop theme-mode,
     * theme-adaptive and adaptive schedule keys.
     *
     * Shared by the shell, first-party apps and the portal Settings backend so
     * the policy lives in one place. The shell follows shell_dark (dark unless
     * full Light), applications follow app_dark (light unless full Dark). When
     * adaptive is enabled the effective mode becomes Dark during the configured
     * night window.
     */
    public class ThemeMode : Object {

        private static ThemeMode? _instance;
        private GLib.Settings? settings;
        private uint timer_id = 0;

        /** Emitted whenever the effective mode may have changed. */
        public signal void changed();

        public static ThemeMode get_default() {
            if (_instance == null) {
                _instance = new ThemeMode();
            }
            return _instance;
        }

        construct {
            settings = Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
            if (settings != null) {
                settings.changed["theme-mode"].connect(on_settings_changed);
                settings.changed["theme-adaptive"].connect(on_settings_changed);
                settings.changed["theme-adaptive-from"].connect(on_settings_changed);
                settings.changed["theme-adaptive-to"].connect(on_settings_changed);
            }
            reschedule();
        }

        private void on_settings_changed() {
            reschedule();
            changed();
        }

        /** The configured base mode, ignoring the adaptive schedule. */
        public ColorMode base_mode() {
            if (settings == null) return ColorMode.DUAL;
            switch (settings.get_string("theme-mode")) {
                case "light": return ColorMode.LIGHT;
                case "dark":  return ColorMode.DARK;
                default:      return ColorMode.DUAL;
            }
        }

        /** The effective mode after applying the adaptive night override. */
        public ColorMode effective() {
            var b = base_mode();
            if (settings != null
                    && settings.get_boolean("theme-adaptive")
                    && b != ColorMode.DARK
                    && is_night()) {
                return ColorMode.DARK;
            }
            return b;
        }

        /** Whether the shell chrome should be dark (dark unless full Light). */
        public bool shell_dark() { return effective() != ColorMode.LIGHT; }

        /** Whether application content should be dark (light unless full Dark). */
        public bool app_dark() { return effective() == ColorMode.DARK; }

        private int parse_minutes(string hhmm, int fallback) {
            var parts = hhmm.split(":");
            if (parts.length != 2) return fallback;
            int h = int.parse(parts[0]);
            int m = int.parse(parts[1]);
            if (h < 0 || h > 23 || m < 0 || m > 59) return fallback;
            return h * 60 + m;
        }

        private bool is_night() {
            if (settings == null) return false;
            int from = parse_minutes(settings.get_string("theme-adaptive-from"), 19 * 60);
            int to   = parse_minutes(settings.get_string("theme-adaptive-to"), 7 * 60);
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
            if (settings == null || !settings.get_boolean("theme-adaptive")) return;
            if (base_mode() == ColorMode.DARK) return;

            int from = parse_minutes(settings.get_string("theme-adaptive-from"), 19 * 60);
            int to   = parse_minutes(settings.get_string("theme-adaptive-to"), 7 * 60);
            var now = new DateTime.now_local();
            int cur = now.get_hour() * 60 + now.get_minute();
            int d_from = (from - cur + 1440) % 1440;
            int d_to   = (to   - cur + 1440) % 1440;
            int wait = int.min(d_from == 0 ? 1440 : d_from, d_to == 0 ? 1440 : d_to);
            uint secs = (uint) (wait * 60 - now.get_second() + 2);
            timer_id = Timeout.add_seconds(secs, () => {
                timer_id = 0;
                reschedule();
                changed();
                return Source.REMOVE;
            });
        }
    }
}
