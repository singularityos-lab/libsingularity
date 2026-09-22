namespace Singularity.Style {

    /**
     * The three valid appearance modes. The fourth conceptual combination
     * (light shell with dark apps) is intentionally not representable.
     */
    public enum ColorMode { DUAL, LIGHT, DARK }

    /**
     * Resolves the effective appearance from the dev.sinty.desktop theme-mode,
     * theme-adaptive and adaptive schedule keys, plus the night light schedule
     * when night-light-dark-theme is set.
     *
     * Shared by the shell, first-party apps and the portal Settings backend so
     * the policy lives in one place. The shell follows shell_dark (dark unless
     * full Light), applications follow app_dark (light unless full Dark). When
     * adaptive is enabled, or night-light-dark-theme follows an adaptive night
     * light, the effective mode becomes Dark during that night window.
     */
    public class ThemeMode : Object {

        private static ThemeMode? _instance;
        private GLib.Settings? settings;
        private GLib.Settings? if_settings = null;
        private bool _override_set = false;
        private ColorMode _override = ColorMode.DUAL;
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
                settings.changed["night-light-enabled"].connect(on_settings_changed);
                settings.changed["night-light-adaptive"].connect(on_settings_changed);
                settings.changed["night-light-adaptive-from"].connect(on_settings_changed);
                settings.changed["night-light-adaptive-to"].connect(on_settings_changed);
                settings.changed["night-light-dark-theme"].connect(on_settings_changed);
            } else {
                if_settings = Core.safe_settings("org.gnome.desktop.interface");
                if (if_settings != null)
                    if_settings.changed["color-scheme"].connect(on_settings_changed);
                var gs = Gtk.Settings.get_default();
                if (gs != null)
                    gs.notify["gtk-application-prefer-dark-theme"].connect(on_settings_changed);
            }
            reschedule();
        }

        private void on_settings_changed() {
            reschedule();
            changed();
        }

        /** The configured base mode, ignoring the adaptive schedule. */
        public ColorMode base_mode() {
            if (settings == null) return standalone_mode();
            switch (settings.get_string("theme-mode")) {
                case "light": return ColorMode.LIGHT;
                case "dark":  return ColorMode.DARK;
                default:      return ColorMode.DUAL;
            }
        }

        /** The effective mode after applying the adaptive night override. */
        public ColorMode effective() {
            var b = base_mode();
            if (settings == null || b == ColorMode.DARK) return b;
            if (settings.get_boolean("theme-adaptive")
                    && in_window("theme-adaptive-from", "theme-adaptive-to")) {
                return ColorMode.DARK;
            }
            if (follows_night_light()
                    && in_window("night-light-adaptive-from", "night-light-adaptive-to")) {
                return ColorMode.DARK;
            }
            return b;
        }

        /** Whether the shell chrome should be dark (dark unless full Light). */
        public bool shell_dark() { return effective() != ColorMode.LIGHT; }

        /** Whether application content should be dark (light unless full Dark). */
        public bool app_dark() { return effective() == ColorMode.DARK; }

        /**
         * Force a standalone appearance, used by an app's own preferences when
         * running outside the Singularity desktop. Under the desktop this is
         * ignored (the desktop theme-mode wins).
         */
        public void set_standalone_override(ColorMode m) {
            _override_set = true;
            _override = m;
            changed();
        }

        /** Drop the standalone override and follow the system preference again. */
        public void clear_standalone_override() {
            _override_set = false;
            changed();
        }

        private ColorMode standalone_mode() {
            if (_override_set) return _override;
            return system_prefers_dark() ? ColorMode.DARK : ColorMode.LIGHT;
        }

        private bool system_prefers_dark() {
            if (if_settings != null && if_settings.get_string("color-scheme") == "prefer-dark")
                return true;
            var gs = Gtk.Settings.get_default();
            return gs != null && gs.gtk_application_prefer_dark_theme;
        }

        private int parse_minutes(string hhmm, int fallback) {
            var parts = hhmm.split(":");
            if (parts.length != 2) return fallback;
            int h = int.parse(parts[0]);
            int m = int.parse(parts[1]);
            if (h < 0 || h > 23 || m < 0 || m > 59) return fallback;
            return h * 60 + m;
        }

        private bool follows_night_light() {
            return settings.settings_schema.has_key("night-light-dark-theme")
                && settings.get_boolean("night-light-dark-theme")
                && settings.get_boolean("night-light-enabled")
                && settings.get_boolean("night-light-adaptive");
        }

        private bool in_window(string from_key, string to_key) {
            int from = parse_minutes(settings.get_string(from_key), 19 * 60);
            int to   = parse_minutes(settings.get_string(to_key), 7 * 60);
            if (from == to) return false;
            var now = new DateTime.now_local();
            int cur = now.get_hour() * 60 + now.get_minute();
            if (from < to) return cur >= from && cur < to;
            return cur >= from || cur < to;
        }

        private int minutes_to_edge(string from_key, string to_key, int cur) {
            int from = parse_minutes(settings.get_string(from_key), 19 * 60);
            int to   = parse_minutes(settings.get_string(to_key), 7 * 60);
            int d_from = (from - cur + 1440) % 1440;
            int d_to   = (to   - cur + 1440) % 1440;
            return int.min(d_from == 0 ? 1440 : d_from, d_to == 0 ? 1440 : d_to);
        }

        private void reschedule() {
            if (timer_id != 0) {
                Source.remove(timer_id);
                timer_id = 0;
            }
            if (settings == null || base_mode() == ColorMode.DARK) return;
            bool theme_adaptive = settings.get_boolean("theme-adaptive");
            bool night_light = follows_night_light();
            if (!theme_adaptive && !night_light) return;

            var now = new DateTime.now_local();
            int cur = now.get_hour() * 60 + now.get_minute();
            int wait = 1440;
            if (theme_adaptive)
                wait = int.min(wait, minutes_to_edge("theme-adaptive-from", "theme-adaptive-to", cur));
            if (night_light)
                wait = int.min(wait, minutes_to_edge("night-light-adaptive-from", "night-light-adaptive-to", cur));
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
