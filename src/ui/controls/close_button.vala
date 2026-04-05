using Gtk;

namespace Singularity.Widgets {

    /**
     * A frameless icon button pre-configured with the standard window-close icon.
     *
     * Used internally by ToolBar and AppDialog; can also be placed manually
     * anywhere a close action is needed.
     */
    public class CloseButton : IconButton {

        /** Creates a new close button with the `"window-close-symbolic"` icon. */
        public CloseButton() {
            base("window-close-symbolic", "Close", 16);
        }
    }
}
