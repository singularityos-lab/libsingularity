using Gtk;

namespace Singularity.Widgets {

    /**
     * A flat button styled as a menu row.
     *
     * Used by ContextMenu for individual menu items. Renders as a
     * full-width button with an optional leading icon and a left-aligned label.
     */
    public class MenuRow : Button {

        /** Text displayed on the row. */
        public string label_text { get; construct; default = ""; }
        /** Optional symbolic icon shown to the left of the label ("" for none). */
        public string icon_name { get; construct; default = ""; }

        /**
         * Creates a new menu row.
         *
         * @param label_text Text displayed on the row.
         * @param icon_name  Optional symbolic icon shown to the left of the label.
         */
        public MenuRow(string label_text, string? icon_name = null) {
            Object(label_text: label_text, icon_name: icon_name ?? "");
        }

        // Built in construct so .ui/vetro instances are assembled too.
        construct {
            add_css_class("flat");
            add_css_class("menu-row");
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.halign = Align.START;
            box.valign = Align.CENTER;
            if (icon_name != "") {
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
