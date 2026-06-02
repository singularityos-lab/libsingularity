using Gtk;

namespace Singularity.Widgets {

    /**
     * A flat button styled as a menu row.
     *
     * Used by ContextMenu for individual menu items. Renders as a
     * full-width button with an optional leading icon and a left-aligned label.
     */
    public class MenuRow : Button {

        private Label _label;
        private Image _icon;

        /** Text displayed on the row. Safe to set after construction. */
        public string label_text {
            get { return _label != null ? _label.label : ""; }
            set { if (_label != null) _label.label = value ?? ""; }
        }
        /** Optional symbolic icon shown to the left of the label ("" for none). */
        public string icon_name {
            owned get { return _icon != null ? (_icon.icon_name ?? "") : ""; }
            set {
                if (_icon == null) return;
                _icon.icon_name = value;
                _icon.visible = (value != null && value != "");
            }
        }

        /**
         * Creates a new menu row.
         *
         * @param label_text Text displayed on the row.
         * @param icon_name  Optional symbolic icon shown to the left of the label.
         */
        public MenuRow(string label_text, string? icon_name = null) {
            Object();
            this.label_text = label_text;
            this.icon_name = icon_name ?? "";
        }

        // Children built empty in construct so .ui/vetro instances are assembled
        // too; label-text/icon-name are then applied via their setters.
        construct {
            add_css_class("flat");
            add_css_class("menu-row");
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.halign = Align.START;
            box.valign = Align.CENTER;
            _icon = new Image();
            _icon.pixel_size = 16;
            _icon.valign = Align.CENTER;
            _icon.visible = false;
            box.append(_icon);
            _label = new Label("");
            _label.halign = Align.START;
            _label.valign = Align.CENTER;
            box.append(_label);
            set_child(box);
        }
    }
}
