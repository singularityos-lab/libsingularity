using Gtk;

namespace Singularity.Widgets {

    /**
     * A styled section/category label for app sidebars.
     *
     * Renders as an uppercase, dimmed caption - consistent across Files,
     * Store, and any other app with a categorised navigation sidebar.
     * Use instead of raw Label + CSS classes everywhere a sidebar needs
     * a visual group heading.
     */
    public class SidebarSectionLabel : Box {

        public SidebarSectionLabel(string text) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            add_css_class("sidebar-section-label");

            var lbl = new Label(text.up());
            lbl.add_css_class("dim-label");
            lbl.add_css_class("caption");
            lbl.xalign = 0f;
            lbl.hexpand = true;
            append(lbl);
        }
    }
}
