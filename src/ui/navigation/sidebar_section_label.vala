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

        private Label _lbl;
        private string _raw_text = "";

        /** Section caption text (rendered uppercase). Safe to set after
         *  construction (e.g. by GtkBuilder from a .ui/vetro). */
        public string text {
            get { return _raw_text; }
            set {
                _raw_text = value ?? "";
                if (_lbl != null) _lbl.label = _raw_text.up();
            }
        }

        public SidebarSectionLabel(string text) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            this.text = text;
        }

        // The label is built empty in construct so .ui/vetro instances are
        // assembled too; the text is then applied via its setter.
        construct {
            add_css_class("sidebar-section-label");

            _lbl = new Label("");
            _lbl.add_css_class("dim-label");
            _lbl.add_css_class("caption");
            _lbl.xalign = 0f;
            _lbl.hexpand = true;
            append(_lbl);
        }
    }
}
