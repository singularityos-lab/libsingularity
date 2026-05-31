using Gtk;

namespace Singularity.Widgets {

    /**
     * Standard navigation-sidebar row used across Singularity apps.
     * One icon + one label, flat button, consistent padding and
     * spacing. Apps should prefer this over hand-rolled Box/Button
     * compositions so sidebars stay visually identical everywhere.
     *
     * Active state: call `set_active(true)` to apply the
     * `sidebar-nav-active` highlight; clear with `set_active(false)`.
     */
    public class SidebarRow : Button {

        public string icon_name { get; construct; }
        public string text      { get; construct; }

        private Image _img;
        private Label _lbl;

        public SidebarRow (string icon_name, string text) {
            Object (icon_name: icon_name, text: text);
            has_frame = false;
            halign = Align.FILL;
            add_css_class ("flat");
            add_css_class ("singularity-sidebar-row");

            var row = new Box (Orientation.HORIZONTAL, 12);
            _img = new Image.from_icon_name (icon_name);
            _img.pixel_size = 16;
            row.append (_img);
            _lbl = new Label (text);
            _lbl.xalign = 0;
            _lbl.hexpand = true;
            _lbl.ellipsize = Pango.EllipsizeMode.END;
            row.append (_lbl);
            set_child (row);
        }

        public void set_active (bool active) {
            if (active) add_css_class ("sidebar-nav-active");
            else        remove_css_class ("sidebar-nav-active");
        }

        /** Swap the row's icon at runtime (e.g. trash empty / full).
         *  Named with the `update_` prefix to avoid collision with
         *  Gtk.Button's own `set_icon_name`. */
        public void update_icon_name (string name) {
            _img.set_from_icon_name (name);
        }
    }
}
