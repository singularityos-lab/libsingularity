using Gtk;
using GLib;

namespace Singularity.Shell {

    /**
     * A custom global menu bar that replaces GtkPopoverMenuBar.
     */
    public class GlobalMenuBar : Box {

        // Action groups registered by the panel (app, win, dbusmenu…)
        private HashTable<string, ActionGroup> action_groups;

        // Currently open item index (-1 = none)
        private int open_index = -1;

        construct {
            orientation = Orientation.HORIZONTAL;
            spacing = 0;
            add_css_class("global-menu-bar");
            action_groups = new HashTable<string, ActionGroup>(str_hash, str_equal);
        }

        /**
         * Registers or unregisters an action group for menu-item activation.
         *
         * Menu items whose action names start with `prefix.` will be dispatched
         * through `group`. Pass null to remove a previously registered group.
         *
         * @param prefix The action-group prefix (e.g. `"app"`, `"win"`).
         * @param group  The GLib.ActionGroup to register, or null to remove.
         */
        public void register_action_group(string prefix, ActionGroup? group) {
            if (group == null) {
                action_groups.remove(prefix);
            } else {
                action_groups.insert(prefix, group);
            }
        }

        /**
         * Rebuilds the bar from a new GLib.MenuModel.
         *
         * Each top-level item in `model` becomes a button; its linked submenu
         * is opened in a popover on click. Passing null clears all buttons.
         *
         * @param model The new menu model, or null to clear the bar.
         */
        public void update_model(MenuModel? model) {
            open_index = -1;
            var child = get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                remove(child);
                child = next;
            }

            if (model == null) return;

            int n = model.get_n_items();
            for (int i = 0; i < n; i++) {
                MenuModel? submenu = model.get_item_link(i, Menu.LINK_SUBMENU);
                if (submenu == null) submenu = model.get_item_link(i, Menu.LINK_SECTION);
                string? label = null;
                model.get_item_attribute(i, Menu.ATTRIBUTE_LABEL, "s", out label);
                if (label == null) label = "";

                int captured_idx = i;
                var btn = make_top_button(label, submenu, captured_idx);
                append(btn);
            }
        }

        private Button make_top_button(string label, MenuModel? submenu, int index) {
            var btn = new Button.with_label(label);
            btn.add_css_class("global-menu-item");
            btn.has_frame = false;

            btn.clicked.connect(() => {
                if (open_index == index) {
                    close_active();
                } else {
                    open_item(btn, submenu, index);
                }
            });

            var motion = new EventControllerMotion();
            motion.enter.connect((x, y) => {
                if (open_index >= 0 && open_index != index) {
                    open_item(btn, submenu, index);
                }
            });
            btn.add_controller(motion);

            return btn;
        }

        private void open_item(Button btn, MenuModel? submenu, int index) {
            close_active();
            if (submenu == null) return;

            open_index = index;
            btn.add_css_class("active");

            var popover = build_menu_popover(submenu);
            popover.set_parent(btn);
            ulong handler_id = 0;
            handler_id = popover.closed.connect(() => {
                btn.remove_css_class("active");
                if (open_index == index) open_index = -1;
                popover.disconnect(handler_id);
                popover.unparent();
            });
            popover.popup();
        }

        private void close_active() {
            if (open_index < 0) return;
            int idx = 0;
            var child = get_first_child();
            while (child != null) {
                if (idx == open_index) {
                    // Find and popdown the popover parented to this button
                    var pop = child.get_last_child() as Popover;
                    if (pop != null) pop.popdown();
                    child.remove_css_class("active");
                    break;
                }
                child = child.get_next_sibling();
                idx++;
            }
            open_index = -1;
        }

        private Popover build_menu_popover(MenuModel model) {
            var popover = new Popover();
            popover.has_arrow = false;
            popover.add_css_class("global-menu-popover");

            var box = new Box(Orientation.VERTICAL, 0);
            popover.set_child(box);
            append_menu_items(box, model, popover);
            return popover;
        }

        private void append_menu_items(Box box, MenuModel model, Popover root_popover) {
            int n = model.get_n_items();
            for (int i = 0; i < n; i++) {
                MenuModel? section = model.get_item_link(i, Menu.LINK_SECTION);
                if (section != null) {
                    if (i > 0) box.append(new Separator(Orientation.HORIZONTAL));
                    append_menu_items(box, section, root_popover);
                    continue;
                }

                MenuModel? submenu = model.get_item_link(i, Menu.LINK_SUBMENU);
                string? label = null;
                model.get_item_attribute(i, Menu.ATTRIBUTE_LABEL, "s", out label);
                string? icon_name = null;
                model.get_item_attribute(i, "icon", "s", out icon_name);
                string? action = null;
                model.get_item_attribute(i, Menu.ATTRIBUTE_ACTION, "s", out action);

                if (label == null) label = "";

                if (submenu != null) {
                    box.append(make_submenu_row(label, icon_name, submenu));
                } else if (action != null) {
                    string captured_action = action.dup();
                    Variant? target = model.get_item_attribute_value(i, Menu.ATTRIBUTE_TARGET, null);
                    var row = make_item_row(label, icon_name);
                    row.sensitive = is_action_enabled(action);
                    row.clicked.connect(() => {
                        root_popover.popdown();
                        do_activate(captured_action, target);
                    });
                    box.append(row);
                }
            }
        }

        private Button make_item_row(string label, string? icon_name) {
            var btn = new Button();
            btn.add_css_class("flat");
            btn.add_css_class("menu-row");
            btn.halign = Align.FILL;
            var box = new Box(Orientation.HORIZONTAL, 8);
            box.halign = Align.START;
            if (icon_name != null && icon_name.length > 0) {
                var icon = new Image.from_icon_name(icon_name);
                icon.pixel_size = 16;
                icon.valign = Align.CENTER;
                box.append(icon);
            }
            var lbl = new Label(label);
            lbl.halign = Align.START;
            lbl.valign = Align.CENTER;
            box.append(lbl);
            btn.set_child(box);
            return btn;
        }

        private Button make_submenu_row(string label, string? icon_name, MenuModel submenu) {
            var btn = make_item_row(label, icon_name);
            btn.add_css_class("has-submenu");

            var inner = btn.get_child() as Box;
            if (inner != null) {
                var spacer = new Box(Orientation.HORIZONTAL, 0);
                spacer.hexpand = true;
                inner.append(spacer);
                var arrow = new Image.from_icon_name("go-next-symbolic");
                arrow.pixel_size = 12;
                arrow.valign = Align.CENTER;
                inner.append(arrow);
            }

            var motion = new EventControllerMotion();
            Popover? sub = null;
            uint sub_enter_id = 0;
            motion.enter.connect((x, y) => {
                if (sub != null) return;
                if (sub_enter_id != 0) GLib.Source.remove(sub_enter_id);
                sub_enter_id = GLib.Timeout.add(100, () => {
                    sub_enter_id = 0;
                    if (sub != null) return GLib.Source.REMOVE;
                    sub = build_menu_popover(submenu);
                    sub.set_parent(btn);
                    sub.set_position(PositionType.RIGHT);
                    ulong handler_id = 0;
                    handler_id = sub.closed.connect(() => {
                        sub.disconnect(handler_id);
                        sub.unparent();
                        sub = null;
                    });
                    sub.popup();
                    return GLib.Source.REMOVE;
                });
            });
            motion.leave.connect(() => {
                if (sub_enter_id != 0) {
                    GLib.Source.remove(sub_enter_id);
                    sub_enter_id = 0;
                }
            });
            btn.add_controller(motion);
            return btn;
        }

        private void do_activate(string action_name, Variant? target) {
            int dot = action_name.index_of_char('.');
            if (dot < 0) { warning("GlobalMenuBar: no prefix in '%s'", action_name); return; }
            string prefix = action_name[0:dot];
            string name = action_name[dot + 1:action_name.length];

            var ag = action_groups.get(prefix);
            if (ag != null && ag.has_action(name)) {
                ag.activate_action(name, target);
            } else {
                warning("GlobalMenuBar: action '%s' not dispatched", action_name);
            }
        }

        private bool is_action_enabled(string action_name) {
            int dot = action_name.index_of_char('.');
            if (dot < 0) return true;
            string prefix = action_name[0:dot];
            string name = action_name[dot + 1:action_name.length];
            var ag = action_groups.get(prefix);
            if (ag != null) return ag.get_action_enabled(name);
            return true;
        }
    }
}
