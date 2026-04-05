using GLib;

namespace Singularity.Settings {

    /**
     * D-Bus interface exposed by the Singularity Settings app at
     * `dev.sinty.AppSettings`.
     *
     * Allows apps to register a custom settings panel that the Singularity
     * Settings app will display under the app's entry.
     */
    [DBus (name = "dev.sinty.AppSettings")]
    public interface AppSettings : Object {

        /**
         * Returns a JSON string describing the settings layout.
         *
         * The format is an array of group objects, each containing an array
         * of item descriptors. Use SettingsBuilder to construct this
         * string.
         */
        public abstract string get_settings_layout() throws Error;

        /**
         * Writes a single GSettings value on behalf of the caller.
         *
         * @param schema GSettings schema ID.
         * @param key    Settings key.
         * @param value  New value as a GLib.Variant.
         */
        public abstract void set_setting(string schema, string key, Variant value) throws Error;

        /**
         * Reads a single GSettings value.
         *
         * @param schema GSettings schema ID.
         * @param key    Settings key.
         * @return Current value as a GLib.Variant.
         */
        public abstract Variant get_setting(string schema, string key) throws Error;
    }

    /**
     * Fluent builder for the JSON settings-layout string returned by
     * AppSettings.get_settings_layout.
     *
     * Example:
     * {{{
     *   var builder = new SettingsBuilder();
     *   builder.add_group("general", "General");
     *   builder.add_toggle("org.example.MyApp", "dark-mode", "Dark mode");
     *   builder.end_group();
     *   string layout = builder.build();
     * }}}
     */
    public class SettingsBuilder : Object {

        private StringBuilder json;

        public SettingsBuilder() {
            json = new StringBuilder();
            json.append("[");
        }

        /**
         * Begins a new settings group.
         *
         * Must be closed with end_group before calling again or
         * before build.
         *
         * @param id    Machine-readable group identifier.
         * @param title Human-readable group heading.
         */
        public void add_group(string id, string title) {
            if (json.len > 1) json.append(",");
            json.append("""{"id": "%s", "title": "%s", "items": [""".printf(id, title));
        }

        /** Closes the current settings group. */
        public void end_group() {
            json.append("]}");
        }

        /**
         * Adds a boolean toggle item to the current group.
         *
         * @param schema GSettings schema ID.
         * @param key    Boolean GSettings key.
         * @param label  Human-readable label.
         */
        public void add_toggle(string schema, string key, string label) {
            append_item("""{"type": "toggle", "schema": "%s", "key": "%s", "label": "%s"}""".printf(schema, key, label));
        }

        /**
         * Adds a text-entry item to the current group.
         *
         * @param schema GSettings schema ID.
         * @param key    String GSettings key.
         * @param label  Human-readable label.
         */
        public void add_entry(string schema, string key, string label) {
            append_item("""{"type": "entry", "schema": "%s", "key": "%s", "label": "%s"}""".printf(schema, key, label));
        }

        private void append_item(string item) {
             if (json.str.get(json.len - 1) != '[') json.append(",");
             json.append(item);
        }

        /**
         * Finalises and returns the JSON layout string.
         *
         * The builder should not be used after calling this method.
         */
        public string build() {
            json.append("]");
            return json.str;
        }
    }
}
