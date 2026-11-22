using Gtk;

namespace Singularity.Widgets {

    public class PageHero : Box {
        public const int ICON_SIZE = 32;

        private const string HERO = "singularity-page-hero";

        private Image icon_image;
        private Label title_label;
        private Label state_label;
        private GenericArray<PageHeroState> states = new GenericArray<PageHeroState>();

        public string icon_name {
            owned get { return icon_image.icon_name; }
            set {
                if (icon_image.icon_name == value) return;
                Singularity.Animation.IconMotion.stop(icon_image);
                icon_image.icon_name = value;
                if (icon_image.get_mapped()) Singularity.Animation.IconMotion.play(icon_image);
            }
        }

        public string title {
            get { return title_label.label; }
            set {
                title_label.label = value;
                refresh_state();
            }
        }

        public PageHero(string icon_name, string title) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 12);
            add_css_class("page-hero");
            halign = Align.CENTER;
            valign = Align.CENTER;
            margin_top = 14;
            margin_bottom = 14;

            icon_image = new Image.from_icon_name(icon_name);
            icon_image.pixel_size = ICON_SIZE;
            icon_image.accessible_role = AccessibleRole.PRESENTATION;
            Singularity.Animation.IconMotion.play_when_shown(icon_image);
            append(icon_image);

            var text = new Box(Orientation.VERTICAL, 2);
            text.valign = Align.CENTER;
            append(text);

            title_label = new Label(title);
            title_label.add_css_class("title-2");
            title_label.wrap = true;
            title_label.lines = 2;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.justify = Justification.CENTER;
            text.append(title_label);

            state_label = new Label("");
            state_label.add_css_class("dim-label");
            state_label.add_css_class("page-hero-state");
            state_label.ellipsize = Pango.EllipsizeMode.END;
            state_label.visible = false;
            text.append(state_label);
        }

        public void watch(Widget content) {
            content.set_data<PageHero>(HERO, this);
        }

        internal static PageHero? above(Widget widget) {
            for (var parent = widget.get_parent(); parent != null; parent = parent.get_parent()) {
                var hero = parent.get_data<PageHero>(HERO);
                if (hero != null) return hero;
            }
            return null;
        }

        internal void show_state(Widget owner, string text) {
            var state = state_of(owner);
            if (state != null) state.text = text;
            else states.add(new PageHeroState(owner, text));
            refresh_state();
        }

        internal void drop_state(Widget owner) {
            var state = state_of(owner);
            if (state != null) states.remove(state);
            refresh_state();
        }

        private PageHeroState? state_of(Widget owner) {
            foreach (var state in states.data) {
                if (state.owner == owner) return state;
            }
            return null;
        }

        private void refresh_state() {
            string text = states.length > 0 ? states[0].text : "";
            state_label.label = text;
            state_label.visible = text != "" && text != title_label.label;
        }
    }

    private class PageHeroState {
        public unowned Widget owner;
        public string text;

        public PageHeroState(Widget owner, string text) {
            this.owner = owner;
            this.text = text;
        }
    }
}
