using GLib;

namespace Singularity.App {

    /**
     * D-Bus interface that an application exposes to advertise its settings
     * panel to the Singularity Settings app.
     *
     * Register this interface on the session bus under the application's own
     * bus name (e.g. `"org.example.MyApp"`) at a well-known object path such
     * as `/org/example/MyApp/Settings`.
     *
     * The Singularity Settings app discovers and queries this interface when
     * displaying the per-app settings page.
     */
    [DBus (name = "dev.sinty.App.Settings")]
    public interface SettingsService : Object {

        /**
         * Returns the settings schema as a serialised GVariant.
         *
         * The variant describes the keys, types, labels, and widget hints
         * that the Settings app should render.
         */
        public abstract async Variant get_settings_schema() throws IOError;

        /**
         * Writes a setting value.
         *
         * @param key   GSettings key name.
         * @param value New value encoded as a GLib.Variant.
         */
        public abstract async void set_setting(string key, Variant value) throws IOError;

        /** Emitted when a setting is changed programmatically or by another client. */
        public signal void setting_changed(string key, Variant value);
    }
}
