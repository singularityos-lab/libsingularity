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
         *  - `accent-color`           (string)    – accent colour name or `"wallpaper"`
         *  - `dark-mode`              (boolean)   – whether dark mode is active
         *  - `background-picture-uri` (string)    – URI of the desktop wallpaper
         *  - `window-states`          (a{s(iib)}) – per-app saved window geometry
         *  - `force-ssd`              (boolean)   – use server-side decorations
         *  - `window-rounded-corners` (boolean)   – rounded window corners
         *  - `high-contrast`          (boolean)   – high-contrast accessibility mode
         *  - `large-text`             (boolean)   – large-text accessibility mode
         *  - `screen-reader-enabled`  (boolean)   – screen reader active
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
    }
}
