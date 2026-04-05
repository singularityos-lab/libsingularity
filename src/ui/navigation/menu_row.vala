using Gtk;

namespace Singularity.Widgets {

    /**
     * A flat button styled as a menu row.
     *
     * Used by ContextMenu for individual menu items. Renders as a
     * full-width button with an optional leading icon and a left-aligned label.
     */
    public class MenuRow : Button {

        /**
         * Creates a new menu row.
         *
         * @param label_text Text displayed on the row.
         * @param icon_name  Optional symbolic icon shown to the left of the label.
         */
        public MenuRow(string label_text, string? icon_name = null) {
            add_css_class("flat");
            add_css_class("menu-row");
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.halign = Align.START;
            box.valign = Align.CENTER;
            if (icon_name != null) {
                var icon = new Image.from_icon_name(icon_name);
                icon.pixel_size = 16;
                icon.valign = Align.CENTER;
                box.append(icon);
            }
            var label = new Label(label_text);
            label.halign = Align.START;
            label.valign = Align.CENTER;
            box.append(label);
            set_child(box);
        }
    }
}
