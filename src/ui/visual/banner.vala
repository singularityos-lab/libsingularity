using Gtk;

namespace Singularity.Widgets {

    /** Look of a Banner. */
    public enum BannerStyle {
        /** Neutral information, such as working offline. */
        INFO,
        /** Something needs attention but the content still works. */
        WARNING,
        /** Something failed, such as a server refusing a password. */
        ERROR
    }

    /**
     * Inline bar at the top of a content area, with a message, an optional
     * icon and up to two buttons.
     *
     * Place it above the content it talks about and toggle `visible`. The
     * main button is the suggested action, e.g. `"Try Again"`; the secondary
     * one is a plain button, e.g. `"Settings"`. Screen readers announce the
     * title when the banner appears and whenever it changes while visible.
     *
     * Example:
     * {{{
     *   var banner = new Singularity.Widgets.Banner (_("Remote images are hidden"));
     *   banner.button_label = _("Load Images");
     *   banner.button_clicked.connect (() => load_images ());
     *   box.prepend (banner);
     * }}}
     */
    public class Banner : Box {

        /** Emitted when the user presses the main button. */
        public signal void button_clicked();

        /** Emitted when the user presses the secondary button. */
        public signal void secondary_clicked();

        private Image _icon;
        private Label _label;
        private Box _buttons;
        private Button _button;
        private Button _secondary;
        private BannerStyle _style = BannerStyle.INFO;

        /** Text of the message. */
        public string title {
            get { return _label.label; }
            set {
                if (_label.label == value) return;
                _label.label = value;
                if (get_mapped() && value != "") announce(value, AccessibleAnnouncementPriority.MEDIUM);
            }
        }

        /** Icon shown before the message. Hidden when null. */
        public string? icon_name {
            owned get { return _icon.icon_name; }
            set {
                _icon.icon_name = value;
                _icon.visible = value != null && value != "";
            }
        }

        /** Label of the main button. Hidden when null. */
        public string? button_label {
            get { return _button.visible ? _button.label : null; }
            set {
                _button.visible = value != null && value != "";
                if (_button.visible) _button.label = value;
                _sync_buttons();
            }
        }

        /** Label of the secondary button. Hidden when null. */
        public string? secondary_label {
            get { return _secondary.visible ? _secondary.label : null; }
            set {
                _secondary.visible = value != null && value != "";
                if (_secondary.visible) _secondary.label = value;
                _sync_buttons();
            }
        }

        /** Look of the banner. */
        public BannerStyle style {
            get { return _style; }
            set {
                _style = value;
                remove_css_class("warning");
                remove_css_class("error");
                if (value == BannerStyle.WARNING) add_css_class("warning");
                else if (value == BannerStyle.ERROR) add_css_class("error");
            }
        }

        construct {
            orientation = Orientation.VERTICAL;
            spacing = 8;
            add_css_class("singularity-banner");

            var top = new Box(Orientation.HORIZONTAL, 10);
            _icon = new Image();
            _icon.valign = Align.START;
            _icon.visible = false;
            top.append(_icon);
            _label = new Label("");
            _label.xalign = 0;
            _label.hexpand = true;
            _label.wrap = true;
            _label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            top.append(_label);
            append(top);

            _buttons = new Box(Orientation.HORIZONTAL, 8);
            _buttons.halign = Align.END;
            _buttons.layout_manager = new BannerButtonsLayout();
            _secondary = new Button();
            _secondary.add_css_class("pill");
            _secondary.visible = false;
            _secondary.clicked.connect(() => secondary_clicked());
            _buttons.append(_secondary);
            _button = new Button();
            _button.add_css_class("pill");
            _button.add_css_class("suggested-action");
            _button.visible = false;
            _button.clicked.connect(() => button_clicked());
            _buttons.append(_button);
            _buttons.visible = false;
            append(_buttons);

            map.connect(() => {
                if (_label.label != "") announce(_label.label, AccessibleAnnouncementPriority.MEDIUM);
                Singularity.Motion.reveal(this, Singularity.Motion.Preset.FADE);
            });
        }

        /**
         * @param title Text of the message.
         * @param style Look of the banner.
         */
        public Banner(string title = "", BannerStyle style = BannerStyle.INFO) {
            Object();
            this.title = title;
            this.style = style;
        }

        private void _sync_buttons() {
            _buttons.visible = _button.visible || _secondary.visible;
        }
    }

    private class BannerButtonsLayout : LayoutManager {
        private const int SPACING = 8;

        protected override SizeRequestMode get_request_mode(Widget widget) {
            return SizeRequestMode.HEIGHT_FOR_WIDTH;
        }

        private static int row_width(Widget widget, out int widest) {
            int total = 0;
            int count = 0;
            widest = 0;
            for (var child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (!child.should_layout()) continue;
                int min, nat;
                child.measure(Orientation.HORIZONTAL, -1, out min, out nat, null, null);
                total += nat;
                widest = int.max(widest, min);
                count++;
            }
            return count > 1 ? total + SPACING * (count - 1) : total;
        }

        protected override void measure(Widget widget, Orientation orientation, int for_size,
                                        out int minimum, out int natural,
                                        out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            int widest;
            int row = row_width(widget, out widest);
            if (orientation == Orientation.HORIZONTAL) {
                minimum = widest;
                natural = row;
                return;
            }
            bool stacked = for_size >= 0 && for_size < row;
            minimum = natural = 0;
            int count = 0;
            for (var child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (!child.should_layout()) continue;
                int min, nat;
                child.measure(Orientation.VERTICAL, stacked ? for_size : -1, out min, out nat, null, null);
                if (stacked) {
                    minimum += min;
                    natural += nat;
                } else {
                    minimum = int.max(minimum, min);
                    natural = int.max(natural, nat);
                }
                count++;
            }
            if (stacked && count > 1) {
                minimum += SPACING * (count - 1);
                natural += SPACING * (count - 1);
            }
        }

        protected override void allocate(Widget widget, int width, int height, int baseline) {
            int widest;
            int row = row_width(widget, out widest);
            bool stacked = width < row;
            int x = stacked ? 0 : width - row;
            int y = 0;
            for (var child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (!child.should_layout()) continue;
                if (stacked) {
                    int min, nat;
                    child.measure(Orientation.VERTICAL, width, out min, out nat, null, null);
                    child.allocate_size({ 0, y, width, nat }, -1);
                    y += nat + SPACING;
                } else {
                    int min, nat;
                    child.measure(Orientation.HORIZONTAL, -1, out min, out nat, null, null);
                    child.allocate_size({ x, 0, nat, height }, -1);
                    x += nat + SPACING;
                }
            }
        }
    }
}
