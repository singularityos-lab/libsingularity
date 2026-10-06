using GLib;

namespace Singularity {

    /**
     * Answers a pick of an entry added with `DockMenu.add_reply_item`.
     *
     * @param item_id The entry id.
     * @return What the shell should do, such as copying text, or null.
     */
    public delegate SearchActivationReply? DockMenuReplyFunc(string item_id);

    /**
     * Dynamic entries in the dock menu of a running app, such as recent
     * connections or favourite stations, published over the
     * `dev.sinty.Dock` D-Bus service.
     *
     * The entries appear at the top of the menu shown on a right click of
     * the app's dock icon. When the user picks one, `activated` is emitted
     * in the app with the entry id. The dock drops the entries when the app
     * leaves the bus, and the helper publishes them again if the dock
     * restarts.
     */
    public class DockMenu : Object {
        private const string DOCK_NAME = "dev.sinty.Dock";
        private const string DOCK_PATH = "/dev/sinty/Dock";
        private const string DOCK_INTERFACE = "dev.sinty.Dock";

        /** Desktop id of the app, with or without the `.desktop` suffix. */
        public string app_id { get; construct; }

        /** Emitted with the entry id when the user picks an entry. */
        public signal void activated(string item_id);

        private GenericArray<Variant> _items = new GenericArray<Variant>();
        private DBusConnection? _bus = null;
        private uint _subscription = 0;
        private uint _watch = 0;
        private bool _published = false;
        private DockMenuReplyFunc? _reply_func = null;
        private uint _reply_registration = 0;
        private string? _reply_path = null;

        public DockMenu(string app_id) {
            Object(app_id: app_id);
        }

        construct {
            try {
                _bus = Bus.get_sync(BusType.SESSION);
            } catch (Error e) {
                warning("DockMenu: no session bus: %s", e.message);
                return;
            }
            _subscription = _bus.signal_subscribe(DOCK_NAME, DOCK_INTERFACE, "MenuItemActivated",
                DOCK_PATH, null, DBusSignalFlags.NONE, on_signal);
            _watch = Bus.watch_name_on_connection(_bus, DOCK_NAME, BusNameWatcherFlags.NONE, () => {
                if (_published) send_menu();
            }, null);
        }

        ~DockMenu() {
            if (_bus != null && _subscription != 0) _bus.signal_unsubscribe(_subscription);
            if (_watch != 0) Bus.unwatch_name(_watch);
            if (_bus != null && _reply_registration != 0) _bus.unregister_object(_reply_registration);
        }

        /**
         * Appends an entry. Call `publish` to show the changes.
         *
         * @param id        Identifier passed to `activated`.
         * @param label     Text of the entry.
         * @param icon_name Symbolic icon name, or null.
         * @param enabled   Whether the entry can be picked.
         */
        public void add_item(string id, string label, string? icon_name = null, bool enabled = true) {
            var dict = new VariantBuilder(VariantType.VARDICT);
            dict.add("{sv}", "id", new Variant.string(id));
            dict.add("{sv}", "label", new Variant.string(label));
            if (icon_name != null) dict.add("{sv}", "icon", new Variant.string(icon_name));
            if (!enabled) dict.add("{sv}", "enabled", new Variant.boolean(false));
            _items.add(dict.end());
        }

        /**
         * Appends an entry whose pick is answered by the function set with
         * `set_reply_func`, at the moment of the click. Return
         * `SearchActivationReply.copy` from it to have the shell copy text,
         * which a background app cannot do on Wayland. The text leaves the
         * app only then, so it can be a secret such as a one-time code.
         * `activated` is not emitted for these entries.
         *
         * @param id        Identifier passed to the reply function.
         * @param label     Text of the entry.
         * @param icon_name Symbolic icon name, or null.
         * @param enabled   Whether the entry can be picked.
         */
        public void add_reply_item(string id, string label, string? icon_name = null, bool enabled = true) {
            string? path = ensure_reply_object();
            var dict = new VariantBuilder(VariantType.VARDICT);
            dict.add("{sv}", "id", new Variant.string(id));
            dict.add("{sv}", "label", new Variant.string(label));
            if (icon_name != null) dict.add("{sv}", "icon", new Variant.string(icon_name));
            if (!enabled) dict.add("{sv}", "enabled", new Variant.boolean(false));
            if (path != null) dict.add("{sv}", "reply", new Variant.object_path(path));
            _items.add(dict.end());
        }

        /**
         * Sets the function that answers entries added with `add_reply_item`.
         * Only the process that owns `dev.sinty.Dock` can trigger it.
         */
        public void set_reply_func(owned DockMenuReplyFunc func) {
            _reply_func = (owned) func;
            ensure_reply_object();
        }

        /**
         * Answers a pick of an entry added with `add_reply_item`. The default
         * calls the function set with `set_reply_func`; override it in a
         * subclass when the answer needs asynchronous work, such as reading
         * a secret from the keyring.
         *
         * @param item_id The entry id.
         * @return What the shell should do, or null.
         */
        public virtual async SearchActivationReply? reply_for_item(string item_id) {
            return _reply_func != null ? _reply_func(item_id) : null;
        }

        /** Object path of the reply object, for tests and diagnostics. */
        public string? reply_path {
            get { return _reply_path; }
        }

        internal async HashTable<string, Variant> answer(string item_id, string caller) throws DBusError {
            var app = GLib.Application.get_default();
            if (app != null) app.hold();
            string? owner = null;
            try {
                var result = yield _bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "GetNameOwner", new Variant("(s)", DOCK_NAME), new VariantType("(s)"),
                    DBusCallFlags.NONE, 2000, null);
                owner = result.get_child_value(0).get_string();
            } catch (Error e) {
            }
            SearchActivationReply? reply = null;
            if (owner != null && owner == caller) reply = yield reply_for_item(item_id);
            if (app != null) app.release();
            if (owner == null || owner != caller) throw new DBusError.ACCESS_DENIED("Only the dock can activate entries");
            return reply != null ? reply.to_dict() : new HashTable<string, Variant>(str_hash, str_equal);
        }

        /**
         * The object path where the replies of `app_id` are served:
         * `/dev/sinty/DockMenu/` followed by the lowercase desktop id without
         * `.desktop`, every character other than a-z and 0-9 turned into `_`.
         */
        public static string reply_path_for(string app_id) {
            var path = new StringBuilder("/dev/sinty/DockMenu/");
            string id = normalize(app_id);
            for (int i = 0; i < id.length; i++) {
                char c = id[i];
                if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) path.append_c(c);
                else path.append_c('_');
            }
            return path.str;
        }

        /**
         * Serves the replies right away, before any entry is published. Call
         * it before the application runs so that a desktop action marked
         * with `X-Singularity-Dock-Reply=true` reaches the app even when the
         * dock starts it over D-Bus.
         */
        public void export_replies() {
            ensure_reply_object();
        }

        private string? ensure_reply_object() {
            if (_reply_path != null || _bus == null) return _reply_path;
            string path = reply_path_for(app_id);
            try {
                _reply_registration = _bus.register_object(path, new DockMenuSkeleton(this));
                _reply_path = path;
            } catch (IOError e) {
                warning("DockMenu: cannot export %s: %s", path, e.message);
            }
            return _reply_path;
        }

        /** Appends a separator. Call `publish` to show the changes. */
        public void add_separator() {
            var dict = new VariantBuilder(VariantType.VARDICT);
            dict.add("{sv}", "separator", new Variant.boolean(true));
            _items.add(dict.end());
        }

        /** Removes every entry. Call `publish` to show the changes. */
        public void clear() {
            _items.remove_range(0, _items.length);
        }

        /** Sends the current entries to the dock. */
        public void publish() {
            _published = true;
            send_menu();
        }

        /** Removes the entries from the dock. */
        public void unpublish() {
            _published = false;
            if (_bus == null) return;
            _bus.call.begin(DOCK_NAME, DOCK_PATH, DOCK_INTERFACE, "ClearMenu",
                new Variant("(s)", app_id), null, DBusCallFlags.NO_AUTO_START, 2000, null);
        }

        private void send_menu() {
            if (_bus == null) return;
            var items = new Variant.array(VariantType.VARDICT, _items.data);
            _bus.call.begin(DOCK_NAME, DOCK_PATH, DOCK_INTERFACE, "SetMenu",
                new Variant("(s@aa{sv})", app_id, items), null, DBusCallFlags.NO_AUTO_START, 2000, null,
                (obj, res) => {
                    try {
                        _bus.call.end(res);
                    } catch (Error e) {
                        debug("DockMenu: SetMenu failed: %s", e.message);
                    }
                });
        }

        private void on_signal(DBusConnection connection, string? sender, string path,
                               string iface, string name, Variant parameters) {
            string target, item;
            parameters.get("(ss)", out target, out item);
            if (normalize(target) == normalize(app_id)) activated(item);
        }

        private static string normalize(string id) {
            string s = id.down();
            return s.has_suffix(".desktop") ? s.substring(0, s.length - 8) : s;
        }
    }

    [DBus (name = "dev.sinty.DockMenu1")]
    internal class DockMenuSkeleton : Object {
        private weak DockMenu menu;

        public DockMenuSkeleton(DockMenu menu) {
            this.menu = menu;
        }

        public async HashTable<string, Variant> activate_item(string item_id, GLib.BusName sender)
                throws GLib.DBusError, GLib.IOError {
            return yield menu.answer(item_id, sender);
        }
    }
}
