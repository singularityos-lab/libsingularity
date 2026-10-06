namespace Singularity.Widgets {

    public class ControlStrip : Gtk.Box {

        public ControlStrip (int top = 4, int bottom = 4) {
            GLib.Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 6);
            add_css_class ("sx-control-strip");
            margin_start = 10;
            margin_end = 10;
            margin_top = top;
            margin_bottom = bottom;
        }

        public Gtk.Button add_icon_button (string icon_name, string tooltip, Gtk.Box? into = null) {
            var b = new Gtk.Button.from_icon_name (icon_name);
            b.tooltip_text = tooltip;
            b.add_css_class ("flat");
            b.update_property (Gtk.AccessibleProperty.LABEL, tooltip, -1);
            b.valign = Gtk.Align.CENTER;
            (into ?? this).append (b);
            return b;
        }

        public Gtk.Button add_text_button (string label, string? tooltip = null) {
            var b = new Gtk.Button.with_label (label);
            b.add_css_class ("flat");
            b.valign = Gtk.Align.CENTER;
            if (tooltip != null) b.tooltip_text = tooltip;
            append (b);
            return b;
        }

        public Gtk.ToggleButton add_icon_toggle (string icon_name, string tooltip, Gtk.Box? into = null) {
            var b = new Gtk.ToggleButton ();
            b.icon_name = icon_name;
            b.tooltip_text = tooltip;
            b.add_css_class ("flat");
            b.update_property (Gtk.AccessibleProperty.LABEL, tooltip, -1);
            b.valign = Gtk.Align.CENTER;
            (into ?? this).append (b);
            return b;
        }

        public Gtk.ToggleButton add_text_toggle (string label, string? tooltip = null) {
            var b = new Gtk.ToggleButton.with_label (label);
            b.add_css_class ("flat");
            b.valign = Gtk.Align.CENTER;
            if (tooltip != null) b.tooltip_text = tooltip;
            append (b);
            return b;
        }

        public Gtk.MenuButton add_icon_menu (string icon_name, string tooltip, GLib.MenuModel menu, Gtk.Box? into = null) {
            var b = new Gtk.MenuButton ();
            b.icon_name = icon_name;
            b.tooltip_text = tooltip;
            b.menu_model = menu;
            b.has_frame = false;
            b.update_property (Gtk.AccessibleProperty.LABEL, tooltip, -1);
            b.popover.add_css_class ("singularity-app-menu");
            b.valign = Gtk.Align.CENTER;
            (into ?? this).append (b);
            return b;
        }

        public Gtk.Box add_group () {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            box.add_css_class ("linked");
            box.valign = Gtk.Align.CENTER;
            append (box);
            return box;
        }

        public void add_separator () {
            var sep = new Gtk.Separator (Gtk.Orientation.VERTICAL);
            sep.add_css_class ("sx-control-strip-sep");
            append (sep);
        }

        public Gtk.Label add_numeric_label () {
            var l = new Gtk.Label ("");
            l.add_css_class ("numeric");
            append (l);
            return l;
        }

        public void add_spacer () {
            var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            append (spacer);
        }
    }
}
