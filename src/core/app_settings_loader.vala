using GLib;
using Json;
using Gee;

namespace Singularity.Core {

    /**
     * Describes the GSettings-backed settings panel of an application.
     *
     * Loaded by AppSettingsLoader from a JSON descriptor file
     * installed by the application under
     * `$XDG_DATA_DIR/singularity/app-settings/`.
     */
    public class AppSettingsDescriptor : GLib.Object {
        /** GSettings schema ID this descriptor maps to. */
        public string schema_id { get; set; }

        /** Ordered list of setting items to display. */
        public ArrayList<AppSettingItem> items { get; private set; }

        public AppSettingsDescriptor() {
            items = new ArrayList<AppSettingItem>();
        }
    }

    /** A single selectable option within a AppSettingItem of type `combo`. */
    public class AppSettingOption : GLib.Object {
        /** Machine-readable option identifier stored in GSettings. */
        public string id { get; set; }

        /** Human-readable label shown in the UI. */
        public string label { get; set; }

        /** Optional secondary line shown under the option label. */
        public string? subtitle { get; set; }
    }

    /**
     * A single preference item inside an AppSettingsDescriptor.
     *
     * The `widget` field selects the UI control (`toggle`, `slider`,
     * `combo`, `entry`, ..). Numeric `min`/`max` apply to sliders.
     */
    public class AppSettingItem : GLib.Object {
        /** GSettings key this item controls. */
        public string key { get; set; }

        /** Human-readable label shown beside the control. */
        public string label { get; set; }

        /** Optional secondary line shown under the label. */
        public string? subtitle { get; set; }

        /** GSettings value type (`"boolean"`, `"int"`, `"string"`, ..). */
        public string setting_type { get; set; }

        /** Widget type hint (`"toggle"`, `"slider"`, `"combo"`, `"entry"`, `"color-scheme-selector"`, ..). */
        public string widget { get; set; }

        /**
         * Theme set hint for color-scheme-selector widgets.
         * Valid values: `"terminal"`, `"leafs"`, `"edit"`, `"write"`.
         * If omitted, the provider is chosen by matching the current value
         * against all available theme sets.
         */
        public string theme_set { get; set; }

        /** Minimum value for slider widgets. */
        public double min { get; set; }

        /** Maximum value for slider widgets. */
        public double max { get; set; }

        /** Available options for combo widgets. */
        public ArrayList<AppSettingOption> options { get; private set; }

        public string? schema_id { get; set; }

        public string? path { get; set; }

        public AppSettingItem() {
            options = new ArrayList<AppSettingOption>();
        }
    }

    /**
     * Loads per-application settings descriptors from JSON files.
     *
     * Each application that exposes settings to the Singularity Settings
     * panel installs a JSON descriptor file named `<app-id>.json` under
     * `$XDG_DATA_DIR/singularity/app-settings/`. The loader searches all
     * XDG data directories in order (user directory first, then system).
     *
     * Descriptor format:
     * {{{
     * {
     *   "schema-id": "org.example.MyApp",
     *   "settings": [
     *     { "key": "enable-feature", "label": "Enable feature", "subtitle": "Optional hint", "type": "boolean", "widget": "toggle" },
     *     { "key": "font-size", "label": "Font size", "type": "int", "widget": "slider", "min": 8, "max": 32 },
     *     { "key": "mode", "label": "Mode", "type": "string", "widget": "combo",
     *       "options": [ { "id": "a", "label": "A", "subtitle": "Optional hint" } ] }
     *   ]
     * }
     * }}}
     */
    public class AppSettingsLoader : GLib.Object {

        /**
         * Loads the settings descriptor for the given application.
         *
         * @param app_id Application ID, with or without a trailing `.desktop`
         *               suffix (e.g. `"org.example.MyApp"` or
         *               `"org.example.MyApp.desktop"`).
         * @return The parsed descriptor, or `null` if no descriptor file was
         *         found or it could not be parsed.
         */
        public static AppSettingsDescriptor? load_for_app(string app_id) {
            string clean_id = app_id;
            if (clean_id.has_suffix(".desktop")) {
                clean_id = clean_id.substring(0, clean_id.length - 8);
            }
            string filename = "%s.json".printf(clean_id);
            debug("AppSettingsLoader: looking for '%s' (file: %s)", app_id, filename);

            // Search XDG data directories: user dir first, then system dirs.
            var search_paths = new ArrayList<string>();
            search_paths.add(GLib.Path.build_filename(
                GLib.Environment.get_user_data_dir(), "singularity", "app-settings"
            ));
            foreach (unowned string sysdir in GLib.Environment.get_system_data_dirs()) {
                search_paths.add(GLib.Path.build_filename(sysdir, "singularity", "app-settings"));
            }

            AppSettingsDescriptor? descriptor = null;
            foreach (var path in search_paths) {
                var file_path = GLib.Path.build_filename(path, filename);
                var file = File.new_for_path(file_path);
                if (file.query_exists()) {
                    debug("AppSettingsLoader: found at %s", file_path);
                    descriptor = parse_json(file);
                    break;
                }
            }

            if (Singularity.Widgets.ToolbarSettings.is_registered(clean_id)) {
                if (descriptor == null) descriptor = new AppSettingsDescriptor();
                descriptor.items.add(toolbar_style_item(clean_id));
            }

            if (descriptor == null) warning("AppSettingsLoader: settings not found for %s", clean_id);
            return descriptor;
        }

        public static GLib.Settings? settings_for(AppSettingsDescriptor descriptor, AppSettingItem item) {
            string? schema_id = item.schema_id ?? descriptor.schema_id;
            if (schema_id == null) return null;
            var src = GLib.SettingsSchemaSource.get_default();
            if (src == null) return null;
            var schema = src.lookup(schema_id, true);
            if (schema == null || !schema.has_key(item.key)) return null;
            return new GLib.Settings.full(schema, null, item.schema_id != null ? item.path : null);
        }

        private static AppSettingItem toolbar_style_item(string app_id) {
            var item = new AppSettingItem();
            item.schema_id = Singularity.Widgets.ToolbarSettings.SCHEMA_ID;
            item.path = Singularity.Widgets.ToolbarSettings.path_for(app_id);
            item.key = "toolbar-style";
            item.label = _("Toolbar Style");
            item.setting_type = "string";
            item.widget = "combo";
            string[,] choices = {
                { "compact", _("Compact"), _("Icons, with short text where needed") },
                { "expanded", _("Expanded"), _("Icons and text") },
                { "text", _("Text Only"), _("Text without icons") }
            };
            for (int i = 0; i < choices.length[0]; i++) {
                var option = new AppSettingOption();
                option.id = choices[i, 0];
                option.label = choices[i, 1];
                option.subtitle = choices[i, 2];
                item.options.add(option);
            }
            return item;
        }

        private static AppSettingsDescriptor? parse_json(File file) {
            try {
                var parser = new Parser();
                parser.load_from_file(file.get_path());
                var root_node = parser.get_root();
                if (root_node == null || root_node.get_node_type() != Json.NodeType.OBJECT) {
                    return null;
                }

                var root = root_node.get_object();
                var descriptor = new AppSettingsDescriptor();
                if (root.has_member("schema-id")) {
                    descriptor.schema_id = root.get_string_member("schema-id");
                }

                if (root.has_member("settings")) {
                    var settings_array = root.get_array_member("settings");
                    if (settings_array != null) {
                        settings_array.foreach_element((arr, index, node) => {
                            if (node.get_node_type() != Json.NodeType.OBJECT) return;
                            var obj = node.get_object();
                            var item = new AppSettingItem();
                            if (obj.has_member("key")) item.key = obj.get_string_member("key");
                            if (obj.has_member("label")) item.label = obj.get_string_member("label");
                            if (obj.has_member("subtitle")) item.subtitle = obj.get_string_member("subtitle");
                            if (obj.has_member("type")) item.setting_type = obj.get_string_member("type");
                            if (obj.has_member("widget")) item.widget = obj.get_string_member("widget");
                            if (obj.has_member("theme-set")) item.theme_set = obj.get_string_member("theme-set");
                            if (obj.has_member("min")) item.min = obj.get_double_member("min");
                            if (obj.has_member("max")) item.max = obj.get_double_member("max");
                            if (obj.has_member("schema-id")) item.schema_id = obj.get_string_member("schema-id");
                            if (obj.has_member("path")) item.path = obj.get_string_member("path");
                            if (obj.has_member("options")) {
                                var options_array = obj.get_array_member("options");
                                if (options_array != null) {
                                    options_array.foreach_element((opt_arr, opt_idx, opt_node) => {
                                        if (opt_node.get_node_type() != Json.NodeType.OBJECT) return;
                                        var opt_obj = opt_node.get_object();
                                        var option = new AppSettingOption();
                                        if (opt_obj.has_member("id")) option.id = opt_obj.get_string_member("id");
                                        if (opt_obj.has_member("label")) option.label = opt_obj.get_string_member("label");
                                        if (opt_obj.has_member("subtitle")) option.subtitle = opt_obj.get_string_member("subtitle");
                                        item.options.add(option);
                                    });
                                }
                            }
                            descriptor.items.add(item);
                        });
                    }
                }

                return descriptor;
            } catch (Error e) {
                warning("Failed to parse settings descriptor %s: %s", file.get_path(), e.message);
                return null;
            }
        }
    }
}
