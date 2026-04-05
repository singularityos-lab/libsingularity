using Gtk;

namespace Singularity.Widgets {

    /**
     * A standard content page for preferences dialogs.
     *
     * Applies the canonical Singularity preferences layout: vertical box,
     * `preferences-page` CSS class, and consistent margins (24 px top/bottom,
     * 48 px start/end). Groups are appended with `append_group()`.
     */
    public class PreferencesPage : Gtk.Box {

        /**
         * Creates a new preferences page with the standard layout.
         */
        public PreferencesPage () {
            Object (
                orientation: Orientation.VERTICAL,
                spacing: 0
            );
            add_css_class ("preferences-page");
            margin_top    = 24;
            margin_bottom = 24;
            margin_start  = 48;
            margin_end    = 48;
        }

    /**
     * Appends a PreferencesGroup to the page.
     *
     * @param group The preferences group to add.
     */
        public void append_group (PreferencesGroup group) {
            append (group);
        }
    }
}
