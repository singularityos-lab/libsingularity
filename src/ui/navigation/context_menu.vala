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

        /**
         * Creates a new context menu attached to the given widget.
         *
         * @param parent_widget The widget this popover is parented to.
         */
        public ContextMenu(Widget parent_widget) {
            set_parent(parent_widget);
            has_arrow = false;
            content_box = new Box(Orientation.VERTICAL, 0);
            set_child(content_box);
            add_css_class("context-menu");
        }

        /**
         * Appends a labelled item to the menu.
         *
         * @param label     Text shown on the row.
         * @param icon_name Optional symbolic icon displayed to the left of the label.
         * @param callback  Called when the item is clicked (after the menu pops down).
         */
        public void add_item(string label, string? icon_name, owned ClickedCallback callback) {
            var item = new MenuRow(label, icon_name);
            item.halign = Align.FILL;
            item.clicked.connect(() => {
                popdown();
                callback();
            });
            content_box.append(item);
        }

        /** Appends a horizontal separator between groups of items. */
        public void add_widget(Widget widget) {
            content_box.append(widget);
        }

        public void add_separator() {
            content_box.append(new Separator(Orientation.HORIZONTAL));
        }
        /** Callback type for context-menu item actions. */
        public delegate void ClickedCallback();
    }
}