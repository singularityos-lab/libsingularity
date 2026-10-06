using GLib;

namespace Singularity {

    /**
     * Decides which Peas plugins are enabled, for the shell and for Files.
     *
     * A plugin is enabled when its module is listed in `enabled-plugins`.
     * A plugin shipped by an app declares the app in its `.plugin` file with
     * `X-Singularity-App=<app id>`; it is enabled by default and stays
     * enabled unless the user turned it off, which lists it in
     * `disabled-plugins`.
     */
    public class PluginPreferences : Object {
        /** Key of the `.plugin` file naming the app that ships the plugin. */
        public const string APP_KEY = "X-Singularity-App";
        /** Key of the `.plugin` file naming the gettext domain of its strings. */
        public const string GETTEXT_DOMAIN_KEY = "X-Singularity-Gettext-Domain";

        private static GenericSet<string>? _bound_domains = null;

        /**
         * The gettext domain of a plugin: `X-Singularity-Gettext-Domain`
         * when set, otherwise the domain of the app named by
         * `X-Singularity-App`, or null for plugins of neither kind.
         */
        public static string? gettext_domain(Peas.PluginInfo info) {
            string? domain = info.get_external_data(GETTEXT_DOMAIN_KEY);
            if (domain != null && domain.strip() != "") return domain.strip();
            string? app = info.get_external_data(APP_KEY);
            if (app == null || app.strip() == "") return null;
            string? exe = null;
            string id = app.strip();
            var desktop = new KeyFile();
            try {
                string full;
                desktop.load_from_data_dirs("applications/" + (id.has_suffix(".desktop") ? id : id + ".desktop"),
                    out full, KeyFileFlags.NONE);
                string[] argv;
                GLib.Shell.parse_argv(desktop.get_string("Desktop Entry", "Exec"), out argv);
                if (argv.length > 0) exe = argv[0];
            } catch (Error e) {
            }
            return domain_for_app(id, exe);
        }

        /**
         * The gettext domain an app uses: the base name of its executable,
         * or `singularity-` followed by the last part of its id.
         *
         * @param app_id     The app id, such as `dev.sinty.clock`.
         * @param executable The `Exec` program of its desktop file, or null.
         */
        public static string domain_for_app(string app_id, string? executable) {
            if (executable != null && executable.strip() != "") return Path.get_basename(executable.strip());
            string id = app_id.has_suffix(".desktop") ? app_id.substring(0, app_id.length - 8) : app_id;
            int dot = id.last_index_of_char('.');
            return "singularity-" + (dot >= 0 ? id.substring(dot + 1) : id).down();
        }

        /**
         * The first of `dirs` holding a catalog of `domain` for one of
         * `languages`, or null.
         */
        public static string? find_locale_dir(string domain, string[] dirs, string[] languages) {
            foreach (unowned string dir in dirs) {
                foreach (unowned string lang in languages) {
                    if (FileUtils.test(Path.build_filename(dir, lang, "LC_MESSAGES", domain + ".mo"), FileTest.EXISTS))
                        return dir;
                }
            }
            return null;
        }

        /**
         * Binds the gettext domain of a plugin to the locale directory that
         * holds its catalogs, so its `_()` strings are translated inside the
         * host. The directory is looked up next to the plugin, next to the
         * host binary, under `/opt/local` and in the XDG data directories.
         *
         * @return The domain, or null when the plugin declares none.
         */
        public static string? bind_translations(Peas.PluginInfo info) {
            string? domain = gettext_domain(info);
            if (domain == null) return null;
            if (_bound_domains == null) _bound_domains = new GenericSet<string>(str_hash, str_equal);
            if (_bound_domains.contains(domain)) return domain;
            string[] dirs = {};
            string module_dir = info.get_module_dir();
            int at = module_dir.index_of("/singularity/plugins");
            if (at > 0) {
                string base_dir = module_dir.substring(0, at);
                dirs += Path.build_filename(base_dir, "locale");
                int lib = base_dir.index_of("/lib");
                if (lib >= 0) dirs += Path.build_filename(base_dir.substring(0, lib), "share", "locale");
                else dirs += Path.build_filename(Path.get_dirname(base_dir), "share", "locale");
            }
            try {
                string exe = FileUtils.read_link("/proc/self/exe");
                dirs += Path.build_filename(Path.get_dirname(Path.get_dirname(exe)), "share", "locale");
            } catch (FileError e) {
            }
            dirs += "/opt/local/share/locale";
            dirs += Path.build_filename(Environment.get_user_data_dir(), "locale");
            foreach (unowned string d in Environment.get_system_data_dirs()) dirs += Path.build_filename(d, "locale");
            string? found = find_locale_dir(domain, dirs, Intl.get_language_names());
            if (found != null) {
                Intl.bindtextdomain(domain, found);
                Intl.bind_textdomain_codeset(domain, "UTF-8");
            }
            _bound_domains.add(domain);
            return domain;
        }

        /** Whether `info` was shipped by an app and is on by default. */
        public static bool is_app_shipped(Peas.PluginInfo info) {
            string? app = info.get_external_data(APP_KEY);
            return app != null && app.strip() != "";
        }

        /** Whether the plugin should be loaded under `settings`. */
        public static bool is_enabled(GLib.Settings settings, Peas.PluginInfo info) {
            string module = info.get_module_name();
            if (module in settings.get_strv("enabled-plugins")) return true;
            if (!is_app_shipped(info)) return false;
            if (!has_disabled_key(settings)) return true;
            return !(module in settings.get_strv("disabled-plugins"));
        }

        /**
         * Records the user's choice for a plugin. Turning an app-shipped
         * plugin off lists it in `disabled-plugins`, so it stays off.
         */
        public static void set_enabled(GLib.Settings settings, Peas.PluginInfo info, bool enabled) {
            string module = info.get_module_name();
            string[] on = without(settings.get_strv("enabled-plugins"), module);
            if (enabled && !is_app_shipped(info)) on += module;
            settings.set_strv("enabled-plugins", on);
            if (!has_disabled_key(settings)) return;
            string[] off = without(settings.get_strv("disabled-plugins"), module);
            if (!enabled && is_app_shipped(info)) off += module;
            settings.set_strv("disabled-plugins", off);
        }

        private static bool has_disabled_key(GLib.Settings settings) {
            return settings.settings_schema.has_key("disabled-plugins");
        }

        private static string[] without(string[] list, string module) {
            string[] result = {};
            foreach (string s in list) {
                if (s != null && s.length > 0 && s != module) result += s;
            }
            return result;
        }
    }
}
