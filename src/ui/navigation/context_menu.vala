using Gtk;

namespace Singularity.Widgets {

    /**
     * A popover-based context menu for Singularity apps.
     *
     * Attach to any widget with the constructor, then add labelled items via
     * `add_item()` and visual separators via `add_separator()`.
     * The menu pops down automatically after an item is clicked.
     */
    public class ContextMenu : Popover {
        private Box content_box;
        private Widget parent_widget;

        /**
         * Creates a new context menu attached to the given widget.
         *
         * @param parent_widget The widget this popover is parented to.
         */
        // Half of the popover padding (40 px ÷ 2) cancels the inward
        // offset of the visible card so it lands aligned with the anchor.
        private const int SHADOW_OFFSET = 10;

        public ContextMenu(Widget parent_widget) {
            this.parent_widget = parent_widget;
            set_parent(parent_widget);
            has_arrow = false;
            content_box = new Box(Orientation.VERTICAL, 0);
            set_child(content_box);
            add_css_class("context-menu");
            set_offset(-SHADOW_OFFSET, -SHADOW_OFFSET);
        }

        /**
         * Appends a labelled item to the menu.
         *
         * @param label     Text shown on the row.
         * @param icon_name Optional symbolic icon displayed to the left of the label.
         * @param callback  Called when the item is clicked (after the menu pops down).
         */
        public void add_item(string label, string? icon_name, owned ClickedCallback callback,
                              string? css_class = null) {
            var item = new MenuRow(label, icon_name);
            item.halign = Align.FILL;
            if (css_class != null && css_class.length > 0)
                item.add_css_class(css_class);
            item.clicked.connect(() => {
                popdown();
                callback();
            });
            content_box.append(item);
        }

        /**
         * Appends a labelled item using a GIcon (e.g. an application icon)
         * instead of a themed icon name. Mirrors the Files "Open With" rows.
         */
        public void add_item_gicon(string label, GLib.Icon? gicon, owned ClickedCallback callback) {
            var btn = new Button();
            btn.has_frame = false;
            btn.add_css_class("flat");
            btn.add_css_class("menu-row");
            btn.halign = Align.FILL;
            var hbox = new Box(Orientation.HORIZONTAL, 10);
            hbox.halign = Align.START;
            var ico = (gicon != null)
                ? new Image.from_gicon(gicon)
                : new Image.from_icon_name("application-x-executable-symbolic");
            ico.pixel_size = 16;
            hbox.append(ico);
            var lbl = new Label(label);
            lbl.halign = Align.START;
            hbox.append(lbl);
            btn.set_child(hbox);
            btn.clicked.connect(() => {
                popdown();
                callback();
            });
            content_box.append(btn);
        }

        /** Appends a horizontal separator between groups of items. */
        public void add_widget(Widget widget) {
            content_box.append(widget);
        }

        public void add_separator() {
            content_box.append(new Separator(Orientation.HORIZONTAL));
        }

        /**
         * Appends an item that opens a nested submenu when clicked.
         *
         * Returns the child ContextMenu so the caller can populate it with
         * `add_item()` calls. The submenu opens at the same anchor as this menu.
         */
        public ContextMenu add_submenu(string label, string? icon_name) {
            var sub = new ContextMenu(parent_widget);
            var item = new MenuRow(label, icon_name);
            item.halign = Align.FILL;
            item.add_css_class("has-submenu");
            item.clicked.connect(() => {
                Gdk.Rectangle rect;
                bool has_rect = get_pointing_to(out rect);
                popdown();
                if (has_rect) sub.set_pointing_to(rect);
                sub.popup();
            });
            content_box.append(item);
            return sub;
        }
        /** Callback type for context-menu item actions. */
        public delegate void ClickedCallback();

        public static void attach_editable(Widget host, bool with_undo = false) {
            var click = new Gtk.GestureClick();
            click.button = Gdk.BUTTON_SECONDARY;
            click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
            click.pressed.connect((n, x, y) => {
                var menu = new ContextMenu(host);
                Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
                menu.set_pointing_to(rect);

                if (with_undo) {
                    menu.add_item("Undo", "edit-undo-symbolic",
                        () => host.activate_action("text.undo", null));
                    menu.add_item("Redo", "edit-redo-symbolic",
                        () => host.activate_action("text.redo", null));
                    menu.add_separator();
                }
                menu.add_item("Cut", "edit-cut-symbolic",
                    () => host.activate_action("clipboard.cut", null));
                menu.add_item("Copy", "edit-copy-symbolic",
                    () => host.activate_action("clipboard.copy", null));
                menu.add_item("Paste", "edit-paste-symbolic",
                    () => host.activate_action("clipboard.paste", null));
                menu.add_separator();
                menu.add_item("Select All", "edit-select-all-symbolic",
                    () => host.activate_action("selection.select-all", null));

                menu.popup();
                click.set_state(Gtk.EventSequenceState.CLAIMED);
            });
            host.add_controller(click);
        }
    }
}