using GLib;

namespace Singularity.Accessibility {

    /**
     * Applies the desktop accessibility settings to Singularity apps.
     *
     * Reads the standard `org.gnome.desktop.a11y.*` and
     * `org.gnome.desktop.interface` keys written by the Settings panel (and
     * the legacy keys in the desktop schema) and applies high contrast, text
     * scaling and the always visible keyboard focus to the running process.
     * The shell additionally owns the screen reader process, see
     * manage_screen_reader.
     *
     * Obtain the shared instance via get_default. The instance is
     * created automatically by Singularity.Application.startup.
     */
    public class AccessibilityManager : Object {

        private static AccessibilityManager? _instance;
        private GLib.Settings? settings;
        private GLib.Settings? a11y_iface;
        private GLib.Settings? iface;
        private GLib.Settings? applications;
        private Pid orca_pid = 0;
        private bool managing_screen_reader = false;

        /** Whether high-contrast mode is currently active. */
        public bool high_contrast { get; private set; default = false; }

        /** Whether large-text mode is currently active. */
        public bool large_text { get; private set; default = false; }

        /** Whether the screen reader (Orca) is currently enabled. */
        public bool screen_reader_enabled { get; private set; default = false; }

        /** Whether the keyboard focus stays visible after pointer use. */
        public bool always_show_focus { get; private set; default = false; }

        /** Emitted when the high-contrast mode changes. */
        public signal void high_contrast_changed(bool enabled);

        /** Emitted when the large-text mode changes. */
        public signal void large_text_changed(bool enabled);

        /**
         * Returns the shared AccessibilityManager instance,
         * creating it on first call.
         */
        public static AccessibilityManager get_default() {
            if (_instance == null) {
                _instance = new AccessibilityManager();
            }
            return _instance;
        }

        private static GLib.Settings? optional(string schema) {
            var src = GLib.SettingsSchemaSource.get_default();
            if (src == null || src.lookup(schema, true) == null) return null;
            return new GLib.Settings(schema);
        }

        private static bool has(GLib.Settings? s, string key) {
            return s != null && s.settings_schema.has_key(key);
        }

        private AccessibilityManager() {
            settings = Singularity.Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
            a11y_iface = optional("org.gnome.desktop.a11y.interface");
            iface = optional("org.gnome.desktop.interface");
            applications = optional("org.gnome.desktop.a11y.applications");

            if (has(settings, "high-contrast")) settings.changed["high-contrast"].connect(() => sync_contrast());
            if (has(a11y_iface, "high-contrast")) a11y_iface.changed["high-contrast"].connect(() => sync_contrast());
            if (has(settings, "large-text")) settings.changed["large-text"].connect(() => sync_text());
            if (has(iface, "text-scaling-factor")) iface.changed["text-scaling-factor"].connect(() => sync_text());
            if (has(settings, "always-show-focus")) settings.changed["always-show-focus"].connect(() => sync_focus());
            if (has(applications, "screen-reader-enabled")) {
                applications.changed["screen-reader-enabled"].connect(() => sync_screen_reader());
            }
            if (has(settings, "screen-reader-enabled")) {
                settings.changed["screen-reader-enabled"].connect(() => sync_screen_reader());
            }

            sync_contrast();
            sync_text();
            sync_focus();
            screen_reader_enabled = read_screen_reader();
        }

        private void sync_contrast() {
            bool val = (has(a11y_iface, "high-contrast") && a11y_iface.get_boolean("high-contrast"))
                || (has(settings, "high-contrast") && settings.get_boolean("high-contrast"));
            Singularity.Style.StyleManager.get_default().set_high_contrast(val);
            if (high_contrast != val) {
                high_contrast = val;
                high_contrast_changed(val);
            }
        }

        private void sync_text() {
            double factor = has(iface, "text-scaling-factor") ? iface.get_double("text-scaling-factor") : 1.0;
            if (has(settings, "large-text") && settings.get_boolean("large-text")) factor = double.max(factor, 1.4);
            Singularity.Style.StyleManager.get_default().set_text_scale(factor);
            bool val = factor >= 1.2;
            if (large_text != val) {
                large_text = val;
                large_text_changed(val);
            }
        }

        private void sync_focus() {
            always_show_focus = has(settings, "always-show-focus") && settings.get_boolean("always-show-focus");
            var toplevels = Gtk.Window.get_toplevels();
            for (uint i = 0; i < toplevels.get_n_items(); i++) {
                var win = toplevels.get_item(i) as Gtk.Window;
                if (win != null) watch_focus(win);
            }
            if (!toplevels.get_data<bool>("singularity-a11y-watched")) {
                toplevels.set_data<bool>("singularity-a11y-watched", true);
                toplevels.items_changed.connect((pos, removed, added) => {
                    for (uint i = pos; i < pos + added; i++) {
                        var win = toplevels.get_item(i) as Gtk.Window;
                        if (win != null) watch_focus(win);
                    }
                });
            }
        }

        private void watch_focus(Gtk.Window win) {
            if (always_show_focus) win.focus_visible = true;
            if (win.get_data<bool>("singularity-a11y-focus")) return;
            win.set_data<bool>("singularity-a11y-focus", true);
            win.notify["focus-visible"].connect(() => {
                if (always_show_focus && !win.focus_visible) win.focus_visible = true;
            });
        }

        private bool read_screen_reader() {
            return (has(applications, "screen-reader-enabled") && applications.get_boolean("screen-reader-enabled"))
                || (has(settings, "screen-reader-enabled") && settings.get_boolean("screen-reader-enabled"));
        }

        /**
         * Makes this process responsible for starting and stopping the screen
         * reader. Only the shell calls this, so a single Orca runs per session.
         */
        public void manage_screen_reader() {
            managing_screen_reader = true;
            sync_screen_reader();
        }

        private void sync_screen_reader() {
            screen_reader_enabled = read_screen_reader();
            if (!managing_screen_reader) return;
            if (screen_reader_enabled && orca_pid == 0) {
                try {
                    GLib.Process.spawn_async(null, { "orca", "--replace" }, null,
                        GLib.SpawnFlags.SEARCH_PATH | GLib.SpawnFlags.DO_NOT_REAP_CHILD,
                        null, out orca_pid);
                    ChildWatch.add(orca_pid, (pid, status) => {
                        GLib.Process.close_pid(pid);
                        if (orca_pid == pid) orca_pid = 0;
                    });
                } catch (Error e) {
                    warning("AccessibilityManager: failed to start orca: %s", e.message);
                }
            } else if (!screen_reader_enabled && orca_pid != 0) {
                try {
                    GLib.Process.spawn_async(null, { "kill", "-TERM", ((int) orca_pid).to_string() }, null,
                        GLib.SpawnFlags.SEARCH_PATH, null, null);
                } catch (Error e) {
                    warning("AccessibilityManager: failed to stop orca: %s", e.message);
                }
            }
        }

        /** Whether a screen reader is installed on this system. */
        public static bool screen_reader_available() {
            return GLib.Environment.find_program_in_path("orca") != null;
        }

        /**
         * Enables or disables high-contrast mode.
         *
         * @param enabled `true` to enable high-contrast, `false` to disable.
         */
        public void toggle_high_contrast(bool enabled) {
            if (has(a11y_iface, "high-contrast")) a11y_iface.set_boolean("high-contrast", enabled);
            else if (has(settings, "high-contrast")) settings.set_boolean("high-contrast", enabled);
        }

        /**
         * Enables or disables large-text mode.
         *
         * @param enabled `true` to enable large text, `false` to disable.
         */
        public void toggle_large_text(bool enabled) {
            if (has(iface, "text-scaling-factor")) iface.set_double("text-scaling-factor", enabled ? 1.4 : 1.0);
            else if (has(settings, "large-text")) settings.set_boolean("large-text", enabled);
        }

        /**
         * Enables or disables the Orca screen reader.
         *
         * @param enabled `true` to start Orca, `false` to stop it.
         */
        public void set_screen_reader(bool enabled) {
            if (has(applications, "screen-reader-enabled")) applications.set_boolean("screen-reader-enabled", enabled);
            else if (has(settings, "screen-reader-enabled")) settings.set_boolean("screen-reader-enabled", enabled);
        }
    }
}
