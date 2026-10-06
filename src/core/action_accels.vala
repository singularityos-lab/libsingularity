namespace Singularity {

    /**
     * Publishes the keyboard shortcuts of an application on the session bus.
     *
     * GTK keeps the accelerators set with Gtk.Application.set_accels_for_action
     * inside the process: org.gtk.Actions lists the actions but not their keys,
     * and an app without a menu bar has nothing else to read. This object
     * exports `dev.sinty.ActionAccels1` next to org.gtk.Actions, on the
     * application object path, so the desktop can show those shortcuts, for
     * example in the Hold Super cheatsheet.
     *
     * Singularity.Application exports it by itself. Any other Gtk.Application
     * can do it from its `dbus_register`:
     *
     * {{{
     * Singularity.ActionAccels.for_application (this).export (connection, object_path);
     * }}}
     */
    public class ActionAccels : Object {
        public const string INTERFACE = "dev.sinty.ActionAccels1";
        private const string DATA_KEY = "singularity-action-accels";
        private const int MENU_DEPTH = 4;

        private weak Gtk.Application app;
        private HashTable<string, string> labels = new HashTable<string, string>(str_hash, str_equal);
        private HashTable<string, string> groups = new HashTable<string, string>(str_hash, str_equal);
        private DBusConnection? connection = null;
        private uint registration = 0;

        private ActionAccels(Gtk.Application app) {
            this.app = app;
        }

        /** Returns the exporter of `app`, creating it on first use. */
        public static ActionAccels for_application(Gtk.Application app) {
            unowned ActionAccels? existing = app.get_data<ActionAccels>(DATA_KEY);
            if (existing != null) return existing;
            var accels = new ActionAccels(app);
            app.set_data<ActionAccels>(DATA_KEY, accels);
            return accels;
        }

        /**
         * Gives a shortcut a readable name and, optionally, the group it is
         * listed under. Without it the label and group come from the menu bar
         * item that uses the action, when there is one.
         *
         * @param detailed_action Action such as `win.zoom-in` or `app.open::recent`.
         * @param label           Name shown next to the keys.
         * @param group           Heading such as `View`; null keeps the default.
         */
        public void describe(string detailed_action, string label, string? group = null) {
            labels.replace(detailed_action, label);
            if (group != null) groups.replace(detailed_action, group);
            else groups.remove(detailed_action);
        }

        /** Exports the interface at `object_path`. Calling it again moves it. */
        public void export(DBusConnection connection, string object_path) throws IOError {
            unexport();
            registration = connection.register_object(object_path, new ActionAccelsSkeleton(this));
            this.connection = connection;
        }

        /** Removes the interface from the bus. */
        public void unexport() {
            if (connection != null && registration != 0) connection.unregister_object(registration);
            registration = 0;
            connection = null;
        }

        /**
         * Every action that has at least one accelerator, as dictionaries with
         * `action` (s), `accels` (as), `label` (s) and `group` (s). Label and
         * group are empty when nothing describes the action.
         */
        public HashTable<string, Variant>[] list() {
            HashTable<string, Variant>[] result = {};
            var app = this.app;
            if (app == null) return result;
            var menu_labels = new HashTable<string, string>(str_hash, str_equal);
            var menu_groups = new HashTable<string, string>(str_hash, str_equal);
            if (app.menubar != null) scan_menu(app.menubar, "", 0, menu_labels, menu_groups);
            foreach (string detailed in app.list_action_descriptions()) {
                string[] accels = app.get_accels_for_action(detailed);
                if (accels.length == 0) continue;
                string label = labels.lookup(detailed) ?? menu_labels.lookup(detailed) ?? "";
                string group = groups.lookup(detailed) ?? menu_groups.lookup(detailed) ?? "";
                var entry = new HashTable<string, Variant>(str_hash, str_equal);
                entry.insert("action", new Variant.string(detailed));
                entry.insert("accels", new Variant.strv(accels));
                entry.insert("label", new Variant.string(label));
                entry.insert("group", new Variant.string(group));
                result += entry;
            }
            return result;
        }

        private static void scan_menu(MenuModel menu, string group, int depth,
                                      HashTable<string, string> menu_labels,
                                      HashTable<string, string> menu_groups) {
            if (depth > MENU_DEPTH) return;
            for (int i = 0; i < menu.get_n_items(); i++) {
                string? label = null;
                menu.get_item_attribute(i, Menu.ATTRIBUTE_LABEL, "s", out label);
                string clean = label != null ? label.replace("_", "").replace("…", "").strip() : "";
                MenuModel? sub = menu.get_item_link(i, Menu.LINK_SUBMENU);
                if (sub != null) {
                    scan_menu(sub, depth == 0 && clean != "" ? clean : group, depth + 1, menu_labels, menu_groups);
                    continue;
                }
                MenuModel? section = menu.get_item_link(i, Menu.LINK_SECTION);
                if (section != null) {
                    scan_menu(section, group, depth + 1, menu_labels, menu_groups);
                    continue;
                }
                string? action = null;
                menu.get_item_attribute(i, Menu.ATTRIBUTE_ACTION, "s", out action);
                if (action == null || clean == "") continue;
                Variant? target = menu.get_item_attribute_value(i, Menu.ATTRIBUTE_TARGET, null);
                string detailed = GLib.Action.print_detailed_name(action, target);
                if (!menu_labels.contains(detailed)) {
                    menu_labels.insert(detailed, clean);
                    if (group != "") menu_groups.insert(detailed, group);
                }
            }
        }
    }

    [DBus (name = "dev.sinty.ActionAccels1")]
    internal class ActionAccelsSkeleton : Object {
        private weak ActionAccels owner;

        public ActionAccelsSkeleton(ActionAccels owner) {
            this.owner = owner;
        }

        public HashTable<string, Variant>[] list_accels() throws GLib.DBusError, GLib.IOError {
            return owner.list();
        }
    }
}
