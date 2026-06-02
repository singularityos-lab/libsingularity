using Gtk;

namespace Singularity.Widgets {

    /**
     * A frameless icon-only button used throughout the Singularity UI.
     *
     * Wraps a Gtk.Button with a single Gtk.Image child and applies the standard
     * `singularity-button` and `singularity-icon-button` CSS classes.
     */
    public class IconButton : Button {
        private Image _img;

        /** The icon name shown on the button. Backed by the image so it is safe
         *  to set after construction (e.g. by GtkBuilder from a .ui/vetro). */
        public string icon {
            owned get { return _img != null ? (_img.icon_name ?? "") : ""; }
            set { if (_img != null) _img.icon_name = value; }
        }
        /** Pixel size of the icon image. */
        public int icon_size {
            get { return _img != null ? _img.pixel_size : 16; }
            set { if (_img != null) _img.pixel_size = value; }
        }

        /**
         * Creates a new icon button.
         *
         * @param icon_name Symbolic icon name (e.g. `"document-save-symbolic"`).
         * @param tooltip   Optional tooltip text shown on hover.
         * @param size      Icon pixel size; defaults to 16.
         */
        public IconButton(string icon_name, string? tooltip = null, int size = 16) {
            Object(tooltip_text: tooltip);
            icon_size = size;
            icon = icon_name;
        }

        // The image child is built empty in construct so .ui/vetro instances are
        // assembled too; icon/icon-size are then applied via their setters (by
        // GtkBuilder post-construct, or by the constructor above).
        construct {
            has_frame = false;
            add_css_class("singularity-button");
            add_css_class("singularity-icon-button");
            _img = new Image();
            _img.pixel_size = 16;
            set_child(_img);
        }
    }
}
