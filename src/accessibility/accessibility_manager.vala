using GLib;

namespace Singularity.Accessibility {

    /**
     * Manages desktop accessibility features for Singularity apps.
     *
     * Observes the `high-contrast`, `large-text`, and `screen-reader-enabled`
     * keys in the desktop GSettings schema (configured via
     * Singularity.Runtime.desktop_settings_schema) and applies the
     * corresponding changes to the GTK style and screen-reader process.
     *
     * Obtain the shared instance via get_default. The instance is
     * created automatically by Singularity.Application.startup.
     */
    public class AccessibilityManager : Object {

        private static AccessibilityManager? _instance;
        private GLib.Settings settings;

        /** Whether high-contrast mode is currently active. */
        public bool high_contrast { get; private set; default = false; }

        /** Whether large-text mode is currently active. */
        public bool large_text { get; private set; default = false; }

        /** Whether the screen reader (Orca) is currently enabled. */
        public bool screen_reader_enabled { get; private set; default = false; }

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

        private AccessibilityManager() {
            try {
                settings = new GLib.Settings(Singularity.Runtime.desktop_settings_schema);
                high_contrast = settings.get_boolean("high-contrast");
                large_text = settings.get_boolean("large-text");
                screen_reader_enabled = settings.get_boolean("screen-reader-enabled");
            } catch (Error e) {
                warning("AccessibilityManager: failed to load settings: %s", e.message);
                high_contrast = false;
                large_text = false;
                screen_reader_enabled = false;
            }

            Singularity.Style.StyleManager.get_default().set_high_contrast(high_contrast);
            Singularity.Style.StyleManager.get_default().set_large_text(large_text);

            if (settings == null) return;
            settings.changed["high-contrast"].connect(() => {
                bool val = settings.get_boolean("high-contrast");
                if (high_contrast != val) {
                    high_contrast = val;
                    high_contrast_changed(val);
                    Singularity.Style.StyleManager.get_default().set_high_contrast(val);
                }
            });
            settings.changed["large-text"].connect(() => {
                bool val = settings.get_boolean("large-text");
                if (large_text != val) {
                    large_text = val;
                    large_text_changed(val);
                    Singularity.Style.StyleManager.get_default().set_large_text(val);
                }
            });
            settings.changed["screen-reader-enabled"].connect(() => {
                bool val = settings.get_boolean("screen-reader-enabled");
                if (screen_reader_enabled != val) {
                    screen_reader_enabled = val;
                    _apply_screen_reader(val);
                }
            });
        }

        /**
         * Enables or disables high-contrast mode.
         *
         * Writes the value to GSettings and immediately applies the CSS
         * override via Singularity.Style.StyleManager.
         *
         * @param enabled `true` to enable high-contrast, `false` to disable.
         */
        public void toggle_high_contrast(bool enabled) {
            settings.set_boolean("high-contrast", enabled);
        }

        /**
         * Enables or disables large-text mode.
         *
         * Writes the value to GSettings and immediately updates the
         * application font size.
         *
         * @param enabled `true` to enable large text, `false` to disable.
         */
        public void toggle_large_text(bool enabled) {
            settings.set_boolean("large-text", enabled);
        }

        /**
         * Enables or disables the Orca screen reader.
         *
         * Starts or stops the `orca` process and persists the choice to
         * GSettings so it survives reboots.
         *
         * @param enabled `true` to start Orca, `false` to stop it.
         */
        public void set_screen_reader(bool enabled) {
            if (screen_reader_enabled == enabled) return;

            screen_reader_enabled = enabled;
            settings.set_boolean("screen-reader-enabled", enabled);
            _apply_screen_reader(enabled);
        }

        private void _apply_screen_reader(bool enabled) {
            if (enabled) {
                try {
                    GLib.Process.spawn_async(
                        null, {"orca"}, null,
                        GLib.SpawnFlags.SEARCH_PATH | GLib.SpawnFlags.DO_NOT_REAP_CHILD,
                        null, null
                    );
                } catch (Error e) {
                    warning("AccessibilityManager: failed to start orca: %s", e.message);
                }
            } else {
                try {
                    GLib.Process.spawn_async(
                        null, {"pkill", "-x", "orca"}, null,
                        GLib.SpawnFlags.SEARCH_PATH,
                        null, null
                    );
                } catch (Error e) {
                    warning("AccessibilityManager: failed to stop orca: %s", e.message);
                }
            }
        }
    }
}
