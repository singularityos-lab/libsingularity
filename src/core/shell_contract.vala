using GLib;

namespace Singularity.Shell {

    /**
     * D-Bus interface exposed by the Singularity shell at
     * `dev.sinty.Shell` (object path `/dev/sinty/Shell`).
     *
     * Apps and plugins can obtain a proxy for this interface to interact
     * with the running shell:
     *
     * {{{
     *   ShellService shell = Bus.get_proxy_sync(
     *       BusType.SESSION,
     *       "dev.sinty.Shell",
     *       "/dev/sinty/Shell"
     *   );
     *   shell.open_settings("desktop");
     * }}}
     */
    [DBus (name = "dev.sinty.Shell")]
    public interface ShellService : Object {

        /**
         * Opens the Singularity Settings app at the given page.
         *
         * @param page Page identifier, e.g. `"desktop"`, `"display"`.
         */
        public abstract void open_settings(string page) throws IOError;

        /**
         * Pins an application to the dock.
         *
         * @param app_id Desktop file ID, e.g. `"org.example.MyApp.desktop"`.
         */
        public abstract void add_favorite(string app_id) throws IOError;

        /**
         * Unpins an application from the dock.
         *
         * @param app_id Desktop file ID.
         */
        public abstract void remove_favorite(string app_id) throws IOError;

        /**
         * Moves a pinned application to a new position in the dock.
         *
         * @param app_id   Desktop file ID.
         * @param position Zero-based target index.
         */
        public abstract void move_favorite(string app_id, int position) throws IOError;

        /** Switches focus to the next open window (Alt+Tab forward). */
        public abstract void switch_windows_next() throws IOError;

        /** Switches focus to the previous open window (Alt+Tab backward). */
        public abstract void switch_windows_prev() throws IOError;

        /**
         * Opens the Settings sidebar directly on the details page of a specific app.
         *
         * @param app_id Desktop file ID, e.g. `"dev.sinty.leafs"`.
         */
        public abstract void open_app_settings(string app_id) throws IOError;
    }
}
