using GLib;

namespace Singularity {

    /** Builds the detail page of a QuickTile when the user opens it. */
    public delegate Gtk.Widget QuickTileDetailFunc();

    /**
     * A tile in the quick settings grid of the sidebar, registered by a
     * plugin through PluginContext.add_quick_tile.
     *
     * The shell draws it like the built-in tiles (Wi-Fi, Bluetooth, ...):
     * icon, title and subtitle, highlighted while `active`. The user can
     * reorder it and hide it from the quick settings editor like any other
     * tile. A tile with a detail page gets the chevron that opens it.
     */
    public class QuickTile : Object {
        /**
         * Stable identifier, stored in the tile order and visibility
         * settings. Use a reverse-DNS name such as `dev.sinty.clock.timer`.
         */
        public string id { get; construct; }
        /** Primary label. */
        public string title { get; set; }
        /** Symbolic icon name. */
        public string icon_name { get; set; }
        /** Secondary label below the title; hidden when empty. */
        public string subtitle { get; set; default = ""; }
        /** Whether the tile is drawn highlighted. */
        public bool active { get; set; default = false; }
        /**
         * When true (default), a click flips `active` and emits `toggled`
         * before `clicked`. Set it to false for tiles that run an action,
         * or that set `active` themselves once a change really happened.
         */
        public bool toggleable { get; set; default = true; }
        /** Title of the detail page, defaults to `title`. */
        public string? detail_title { get; set; default = null; }

        /** Emitted after a click flipped `active`, only for toggleable tiles. */
        public signal void toggled(bool active);
        /** Emitted on every click of the tile. */
        public signal void clicked();
        /** Emitted by `open_detail_page`; the shell shows the detail page. */
        public signal void detail_page_requested();

        private QuickTileDetailFunc? _detail_func = null;

        public QuickTile(string id, string title, string icon_name) {
            Object(id: id, title: title, icon_name: icon_name);
        }

        /** Whether the tile has a detail page. */
        public bool has_detail_page {
            get { return _detail_func != null; }
        }

        /**
         * Sets the factory of the detail page, or null to remove it. The
         * shell calls it each time the user opens the page and shows the
         * widget below a header with a back button.
         */
        public void set_detail_page(owned QuickTileDetailFunc? factory) {
            _detail_func = (owned) factory;
            notify_property("has-detail-page");
        }

        /**
         * Opens the detail page in the sidebar, as the chevron does. Does
         * nothing when the tile has no detail page.
         */
        public void open_detail_page() {
            if (has_detail_page) detail_page_requested();
        }

        /** Builds the detail page, or returns null when there is none. */
        public Gtk.Widget? create_detail_page() {
            return _detail_func != null ? _detail_func() : null;
        }

        /**
         * Handles a click from the shell: flips `active` for toggleable
         * tiles, then emits the signals.
         */
        public void click() {
            if (toggleable) {
                active = !active;
                toggled(active);
            }
            clicked();
        }
    }

    /**
     * A button a plugin adds to a built-in settings page of the shell with
     * PluginContext.add_settings_page_action, such as "Share Network" on
     * each saved network of the Wi-Fi page.
     */
    public class SettingsPageAction : Object {
        /** The Wi-Fi page, reached from the Wi-Fi tile and Settings, Network. */
        public const string WIFI = "wifi";
        /**
         * Every saved network of the Wi-Fi page. The shell shows the action
         * as an icon button and a menu item on each network that has saved
         * credentials, and emits `activated_for` with the network name.
         */
        public const string WIFI_NETWORK = "wifi-network";

        /** Stable reverse-DNS identifier. */
        public string id { get; construct; }
        /** The page showing the button, such as `WIFI`. */
        public string page { get; construct; }
        /** Text of the button. */
        public string label { get; set; }
        /** Symbolic icon shown before the label, or null. */
        public string? icon_name { get; set; default = null; }
        /** Whether the button is shown. */
        public bool visible { get; set; default = true; }

        /** Emitted when the user presses the button. */
        public signal void activated();
        /**
         * Emitted when the user picks the action on one item of the page,
         * such as a saved network of `WIFI_NETWORK`; `target` names it.
         */
        public signal void activated_for(string target);

        public SettingsPageAction(string id, string page, string label, string? icon_name = null) {
            Object(id: id, page: page, label: label, icon_name: icon_name);
        }

        /** Emits `activated`, as a press of the button does. */
        public void activate() {
            activated();
        }

        /** Emits `activated_for`, as a press on the item `target` does. */
        public void activate_for(string target) {
            activated_for(target);
        }
    }
}
