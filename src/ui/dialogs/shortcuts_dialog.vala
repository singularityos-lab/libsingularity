using Gtk;

namespace Singularity.Widgets {

    /**
     * Dialog listing the keyboard shortcuts of an application.
     *
     * Built from the application's menu bar: every top-level menu becomes a
     * group holding the items that have an accelerator, taken from the
     * item's `accel` attribute or from the accelerators set with
     * Gtk.Application.set_accels_for_action. Singularity.Application opens
     * it from the automatic `app.shortcuts` action.
     */
    public class ShortcutsDialog : AppDialog {

        /**
         * @param app Application whose menu bar and accelerators are listed.
         */
        public ShortcutsDialog(Gtk.Application app) {
            base(app, true);
            set_title(_("Keyboard Shortcuts"));
            set_default_size(460, 560);

            var body = new Box(Orientation.VERTICAL, 18);
            body.margin_top = 12;
            body.margin_bottom = 20;
            body.margin_start = 20;
            body.margin_end = 20;

            MenuModel? bar = app.menubar;
            int n = bar != null ? bar.get_n_items() : 0;
            for (int i = 0; i < n; i++) {
                MenuModel? sub = bar.get_item_link(i, Menu.LINK_SUBMENU);
                if (sub == null) sub = bar.get_item_link(i, Menu.LINK_SECTION);
                if (sub == null) continue;
                string? label = null;
                bar.get_item_attribute(i, Menu.ATTRIBUTE_LABEL, "s", out label);
                var group = new PreferencesGroup(label != null ? label.replace("_", "") : null);
                if (_collect(app, sub, group) > 0) body.append(group);
            }

            if (body.get_first_child() == null) {
                var empty = new Label(_("This app has no keyboard shortcuts"));
                empty.add_css_class("dim-label");
                empty.margin_top = 24;
                body.append(empty);
            }

            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.set_child(body);
            content_box.append(scroll);
        }

        private static int _collect(Gtk.Application app, MenuModel model, PreferencesGroup group) {
            int rows = 0;
            int n = model.get_n_items();
            for (int i = 0; i < n; i++) {
                MenuModel? link = model.get_item_link(i, Menu.LINK_SECTION);
                if (link == null) link = model.get_item_link(i, Menu.LINK_SUBMENU);
                if (link != null) {
                    rows += _collect(app, link, group);
                    continue;
                }
                string? accel = item_accel(app, model, i);
                if (accel == null) continue;
                uint key;
                Gdk.ModifierType mods;
                if (!Gtk.accelerator_parse(accel, out key, out mods) || key == 0) continue;
                string? label = null;
                model.get_item_attribute(i, Menu.ATTRIBUTE_LABEL, "s", out label);
                if (label == null || label == "") continue;
                var row = new ActionRow(label.replace("_", ""));
                var keys = new Label(Gtk.accelerator_get_label(key, mods));
                keys.add_css_class("dim-label");
                keys.valign = Align.CENTER;
                row.add_suffix(keys);
                group.add_row(row);
                rows++;
            }
            return rows;
        }

        /**
         * Returns the first accelerator of a menu item: its `accel`
         * attribute, or else the first accelerator the application set for
         * the item's action and target.
         *
         * @param app   Application holding the accelerators.
         * @param model Menu containing the item.
         * @param index Position of the item in `model`.
         * @return The accelerator in Gtk.accelerator_parse format, or null.
         */
        public static string? item_accel(Gtk.Application app, MenuModel model, int index) {
            string? accel = null;
            model.get_item_attribute(index, "accel", "s", out accel);
            if (accel != null && accel != "") return accel;
            string? action = null;
            model.get_item_attribute(index, Menu.ATTRIBUTE_ACTION, "s", out action);
            if (action == null || action == "") return null;
            Variant? target = model.get_item_attribute_value(index, Menu.ATTRIBUTE_TARGET, null);
            string detailed = GLib.Action.print_detailed_name(action, target);
            string[] accels = app.get_accels_for_action(detailed);
            return accels.length > 0 ? accels[0] : null;
        }
    }
}
