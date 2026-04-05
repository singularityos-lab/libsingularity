using Gtk;

namespace Singularity.Widgets {

    /**
     * An IconButton with a circular appearance.
     *
     * Identical to IconButton except the `.circular-button` CSS class is added automatically.
     */
    public class CircularButton : IconButton {

        /**
         * Creates a new circular icon button.
         *
         * @param icon_name Icon name (symbolic recommended).
         * @param tooltip   Optional tooltip text.
         * @param size      Icon pixel size; defaults to 16.
         */
        public CircularButton(string icon_name, string? tooltip = null, int size = 16) {
            base(icon_name, tooltip, size);
            add_css_class("circular-button");
        }
    }
}
