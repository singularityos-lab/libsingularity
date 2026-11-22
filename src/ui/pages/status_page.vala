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
        private bool has_icon = false;
        private PageHero? head = null;

        /** Icon shown at the top of the page, in its full-color version when the theme has one. Set to empty string to hide. */
        public string icon_name {
            set {
                icon_image.icon_name = large_icon_name(value);
                has_icon = value != null && value != "";
                icon_image.visible = has_icon && head == null;
                if (get_mapped()) join_head();
            }
        }
        /** Primary title text (large, bold). Set to empty string to hide. */
        public string title {
            get { return title_label.label; }
            set {
                title_label.label = value;
                title_label.visible = (value != null && value != "") && head == null;
                if (head != null && get_mapped()) head.show_state(this, value);
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

        /**
         * A smaller variant for narrow places such as a popover or a side
         * panel: a 48 pixel icon, a heading-sized title and tighter spacing.
         */
        public bool compact {
            get { return has_css_class("compact"); }
            set {
                if (value) add_css_class("compact");
                else remove_css_class("compact");
                spacing = value ? 6 : 12;
                int margin = value ? 12 : 24;
                margin_top = margin;
                margin_bottom = margin;
                margin_start = margin;
                margin_end = margin;
                if (value) {
                    title_label.remove_css_class("title-1");
                    title_label.add_css_class("title-4");
                    child_box.margin_top = 6;
                } else {
                    title_label.remove_css_class("title-4");
                    title_label.add_css_class("title-1");
                    child_box.margin_top = 0;
                }
            }
        }

        public StatusPage() {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
        }

        // Built in construct so .ui/vetro instances are assembled too; the
        // icon-name/title/description properties are then applied by GtkBuilder.
        construct {
            orientation = Orientation.VERTICAL;
            spacing = 12;
            add_css_class("status-page");

            valign = Align.CENTER;
            halign = Align.CENTER;

            margin_top = 24;
            margin_bottom = 24;
            margin_start = 24;
            margin_end = 24;

            icon_image = new Image();
            icon_image.add_css_class("status-page-icon");
            icon_image.visible = false;
            Singularity.Animation.IconMotion.play_when_shown(icon_image);
            append(icon_image);

            title_label = new Label("");
            title_label.add_css_class("title-1");
            title_label.add_css_class("status-page-title");
            title_label.wrap = true;
            title_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            title_label.justify = Justification.CENTER;
            title_label.visible = false;
            append(title_label);

            description_label = new Label("");
            description_label.add_css_class("body");
            description_label.add_css_class("dim-label");
            description_label.wrap = true;
            description_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            description_label.justify = Justification.CENTER;
            description_label.visible = false;
            append(description_label);
            
            child_box = new Box(Orientation.VERTICAL, 0);
            child_box.halign = Align.CENTER;
            append(child_box);
        }

        public override void map() {
            join_head();
            base.map();
        }

        public override void unmap() {
            if (head != null) head.drop_state(this);
            base.unmap();
        }

        private void join_head() {
            if (!has_icon) return;
            head = PageHero.above(this);
            icon_image.visible = head == null;
            title_label.visible = head == null && title_label.label != "";
            if (head != null) head.show_state(this, title_label.label);
        }
    }
}
