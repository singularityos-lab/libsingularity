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
        private Image _submenu_arrow;
        private Label _subtitle;
        private Image _check;

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

        public string subtitle {
            get { return _subtitle != null ? _subtitle.label : ""; }
            set {
                if (_subtitle == null) return;
                _subtitle.label = value ?? "";
                _subtitle.visible = value != null && value != "";
            }
        }

        public bool checked {
            get { return _check != null && _check.visible; }
            set { if (_check != null) _check.visible = value; }
        }

        public bool has_submenu {
            get { return _submenu_arrow != null && _submenu_arrow.visible; }
            set {
                if (_submenu_arrow == null) return;
                _submenu_arrow.visible = value;
                if (value) add_css_class("has-submenu");
                else remove_css_class("has-submenu");
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
            var box = new Box(Orientation.HORIZONTAL, 8);
            box.halign = Align.FILL;
            box.valign = Align.CENTER;
            _icon = new Image();
            _icon.pixel_size = 16;
            _icon.valign = Align.CENTER;
            _icon.visible = false;
            box.append(_icon);
            _label = new Label("");
            _label.halign = Align.START;
            _label.valign = Align.CENTER;
            _label.xalign = 0;
            _subtitle = new Label("");
            _subtitle.halign = Align.START;
            _subtitle.xalign = 0;
            _subtitle.add_css_class("caption");
            _subtitle.add_css_class("dim-label");
            _subtitle.visible = false;
            var texts = new Box(Orientation.VERTICAL, 0);
            texts.hexpand = true;
            texts.valign = Align.CENTER;
            texts.append(_label);
            texts.append(_subtitle);
            box.append(texts);
            _check = new Image.from_icon_name("object-select-symbolic");
            _check.pixel_size = 16;
            _check.valign = Align.CENTER;
            _check.visible = false;
            box.append(_check);
            _submenu_arrow = new Image.from_icon_name("pan-end-symbolic");
            _submenu_arrow.pixel_size = 12;
            _submenu_arrow.valign = Align.CENTER;
            _submenu_arrow.add_css_class("submenu-arrow");
            _submenu_arrow.visible = false;
            box.append(_submenu_arrow);
            set_child(box);
        }
    }
}
