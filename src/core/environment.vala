namespace Singularity {

    /**
     * Global configuration for the libsingularity runtime.
     *
     * Set desktop_settings_schema before instantiating any
     * Application or Widgets.Window when integrating
     * libsingularity into a desktop environment other than Singularity.
     *
     * Example:
     * {{{
     *   Singularity.Runtime.desktop_settings_schema = "org.mydesktop.shell";
     *   var app = new Singularity.Application("org.myapp.MyApp");
     *   app.run(args);
     * }}}
     */
    public class Runtime : Object {

        /**
         * GSettings schema ID for the host desktop environment.
         *
         * libsingularity reads window geometry, accent colour, dark mode, and
         * accessibility preferences from this schema. The schema must expose
         * the following keys:
         *
         *  - `accent-color`           (string)    - accent colour name or `"wallpaper"`
         *  - `dark-mode`              (boolean)   - whether dark mode is active
         *  - `background-picture-uri` (string)    - URI of the desktop wallpaper
         *  - `window-states`          (a{s(iib)}) - per-app saved window geometry
         *  - `force-ssd`              (boolean)   - use server-side decorations
         *  - `window-rounded-corners` (boolean)   - rounded window corners
         *  - `high-contrast`          (boolean)   - high-contrast accessibility mode
         *  - `large-text`             (boolean)   - large-text accessibility mode
         *  - `screen-reader-enabled`  (boolean)   - screen reader active
         *
         * Defaults to `"dev.sinty.desktop"`.
         */
        // The backing variable is a plain C-level static (zero-initialized).
        // The getter does a lazy initialisation so it is always non-null,
        // even when the GObject class_init has not yet run.
        private static string? _desktop_settings_schema = null;

        public static string desktop_settings_schema {
            get {
                if (_desktop_settings_schema == null)
                    _desktop_settings_schema = "dev.sinty.desktop";
                return _desktop_settings_schema;
            }
            set { _desktop_settings_schema = value; }
        }

        /**
         * Returns true when running inside the Singularity shell.
         *
         * Checks XDG_CURRENT_DESKTOP first (fast path), then falls back
         * to a D-Bus probe of the shell service.
         */
        public static bool is_shell_running () {
            string? xdg = Environment.get_variable ("XDG_CURRENT_DESKTOP");
            if (xdg != null && xdg.down ().contains ("singularity"))
                return true;

            try {
                Bus.get_proxy_sync<Singularity.Shell.ShellService> (
                    BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                return true;
            } catch (Error e) {
                return false;
            }
        }

        /** Session bus name owned by the Singularity shell. */
        public const string SHELL_BUS_NAME = "dev.sinty.desktop";

        /**
         * Returns true when the desktop shows application menus in its top
         * panel: the Singularity shell is running and the desktop's
         * `global-menu-enabled` key is on. When this returns false,
         * Widgets.Window hides GTK's in-window menu bar and offers the
         * application menu bar in an App Menu bubble instead.
         */
        public static bool is_global_menu_active () {
            return is_shell_running () && global_menu_enabled ();
        }

        /** Key of the desktop settings that turns the file history on and off. */
        public const string FILE_HISTORY_KEY = "remember-recent-files";

        /**
         * Whether apps may keep and show recently used files, as set in
         * Settings, Applications, Privacy. Apps check it before recording
         * or listing their own file history; true when the desktop
         * settings are not installed.
         */
        public static bool file_history_enabled () {
            var settings = Core.safe_settings (desktop_settings_schema);
            if (settings == null || !settings.settings_schema.has_key (FILE_HISTORY_KEY))
                return true;
            return settings.get_boolean (FILE_HISTORY_KEY);
        }

        internal static bool global_menu_enabled () {
            var settings = Core.safe_settings (desktop_settings_schema);
            if (settings == null || !settings.settings_schema.has_key ("global-menu-enabled"))
                return true;
            return settings.get_boolean ("global-menu-enabled");
        }

        /**
         * Returns the directories that may hold `subdir` under a data
         * directory, most specific first: the user data directory, the
         * install prefix of the running binary, every XDG system data
         * directory and /opt/local/share. Duplicates are removed.
         *
         * @param subdir Path below the data directory, e.g. `singularity/search-providers`.
         */
        public static string[] data_dirs (string subdir) {
            string[] roots = { Environment.get_user_data_dir () };
            try {
                string exe = FileUtils.read_link ("/proc/self/exe");
                roots += Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share");
            } catch (Error e) {
            }
            foreach (unowned string d in Environment.get_system_data_dirs ())
                roots += d;
            roots += "/opt/local/share";
            string[] dirs = {};
            foreach (string root in roots) {
                string dir = Path.build_filename (root, subdir);
                if (!(dir in dirs))
                    dirs += dir;
            }
            return dirs;
        }

        /**
         * Returns the files ending in `suffix` found in `data_dirs (subdir)`.
         * When the same file name exists in several directories, only the
         * most specific one is returned, so a user copy overrides a system one.
         *
         * @param subdir Path below the data directory.
         * @param suffix File name suffix, e.g. `.ini`.
         */
        public static string[] find_data_files (string subdir, string suffix) {
            string[] names = {};
            string[] paths = {};
            foreach (string dir in data_dirs (subdir)) {
                Dir handle;
                try {
                    handle = Dir.open (dir, 0);
                } catch (FileError e) {
                    continue;
                }
                string? name;
                while ((name = handle.read_name ()) != null) {
                    if (!name.has_suffix (suffix) || name in names)
                        continue;
                    names += name;
                    paths += Path.build_filename (dir, name);
                }
            }
            return paths;
        }

        private static int _is_sinty_os = -1;

        /**
         * Returns true when running on Sinty OS, as opposed to the Singularity
         * desktop on another distribution. Read once from /etc/os-release ID.
         */
        public static bool is_sinty_os () {
            if (_is_sinty_os < 0) {
                _is_sinty_os = 0;
                string content;
                try {
                    if (FileUtils.get_contents ("/etc/os-release", out content)) {
                        foreach (string line in content.split ("\n")) {
                            if (!line.has_prefix ("ID="))
                                continue;
                            string id = line.substring (3).replace ("\"", "").strip ();
                            if (id == "sinty" || id.has_prefix ("sinty"))
                                _is_sinty_os = 1;
                            break;
                        }
                    }
                } catch (Error e) {
                    _is_sinty_os = 0;
                }
            }
            return _is_sinty_os == 1;
        }
    }
}
