using Gtk;

namespace Singularity.Widgets {

    /**
     * An empty-state page with a centred icon, title, description, and
     * optional child widget (for example an action button).
     *
     * Use this instead of a blank content area whenever a view has no items
     * to display (for example an empty search result or an unconnected state).
     */
    public class StatusPage : Box {
        private Image icon_image;
        private Label title_label;
        private Label description_label;
        private Box child_box;

        /** Symbolic icon shown at the top of the page. Set to empty string to hide. */
        public string icon_name {
            set {
                icon_image.icon_name = value;
                icon_image.visible = (value != null && value != "");
            }
        }
        /** Primary title text (large, bold). Set to empty string to hide. */
        public string title {
            get { return title_label.label; }
            set {
                title_label.label = value;
                title_label.visible = (value != null && value != "");
            }
        }
        /** Secondary description text (smaller, muted). Set to empty string to hide. */
        public string description {
            get { return description_label.label; }
            set {
                description_label.label = value;
                description_label.visible = (value != null && value != "");
            }
        }
        /** Optional child widget shown below the description (e.g. an action button). */
        public Widget? child {
            get { return child_box.get_first_child(); }
            set {
                if (child_box.get_first_child() != null) {
                    child_box.remove(child_box.get_first_child());
                }
                if (value != null) {
                    child_box.append(value);
                }
            }
        }

        public StatusPage() {
            Object(orientation: Orientation.VERTICAL, spacing: 12);

            add_css_class("status-page");

            valign = Align.CENTER;
            halign = Align.CENTER;

            margin_top = 24;
            margin_bottom = 24;
            margin_start = 24;
            margin_end = 24;

            icon_image = new Image();
            icon_image.pixel_size = 96;
            icon_image.add_css_class("status-page-icon");
            icon_image.visible = false;
            append(icon_image);

            title_label = new Label("");
            title_label.add_css_class("title-1");
            title_label.wrap = true;
            title_label.justify = Justification.CENTER;
            title_label.visible = false;
            append(title_label);

            description_label = new Label("");
            description_label.add_css_class("body");
            description_label.add_css_class("dim-label");
            description_label.wrap = true;
            description_label.justify = Justification.CENTER;
            description_label.visible = false;
            append(description_label);
            
            child_box = new Box(Orientation.VERTICAL, 0);
            child_box.halign = Align.CENTER;
            append(child_box);
        }
    }
}
