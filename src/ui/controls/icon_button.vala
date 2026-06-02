using Gtk;

namespace Singularity.Widgets {

    /**
     * A frameless icon-only button used throughout the Singularity UI.
     *
     * Wraps a Gtk.Button with a single Gtk.Image child and applies the standard
     * `singularity-button` and `singularity-icon-button` CSS classes.
     */
    public class IconButton : Button {
        /** The icon name this button was created with. */
        public string icon { get; construct; default = ""; }
        /** Pixel size of the icon image. */
        public int icon_size { get; construct; default = 16; }

        /**
         * Creates a new icon button.
         *
         * @param icon_name Symbolic icon name (e.g. `"document-save-symbolic"`).
         * @param tooltip   Optional tooltip text shown on hover.
         * @param size      Icon pixel size; defaults to 16.
         */
        public IconButton(string icon_name, string? tooltip = null, int size = 16) {
            Object(icon: icon_name, icon_size: size, tooltip_text: tooltip);
        }

        // Setup lives in construct (not the named constructor body) so the widget
        // is fully built when instantiated from a .ui/vetro template too, where
        // GtkBuilder passes icon/icon-size at construction via g_object_new.
        construct {
            has_frame = false;
            add_css_class("singularity-button");
            add_css_class("singularity-icon-button");
            var img = new Image.from_icon_name(icon);
            img.pixel_size = icon_size;
            set_child(img);
        }
    }
}
