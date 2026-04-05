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
        public string icon { get; construct; }
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
            Object(icon: icon_name, icon_size: size);
            has_frame = false;
            tooltip_text = tooltip;
            add_css_class("singularity-button");
            add_css_class("singularity-icon-button");
            var img = new Image.from_icon_name(icon_name);
            img.pixel_size = size;
            set_child(img);
        }
    }
}
