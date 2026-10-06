using Gtk;

namespace Singularity.Widgets {

    /**
     * Two finger touchpad swipes for back and forward navigation.
     *
     * Wraps a content widget in an overlay and watches touchpad scroll
     * sequences in the capture phase. A sequence is claimed only once it is
     * clearly horizontal, so vertical scrolling and mouse wheels keep working.
     * An arrow grows from the edge while swiping and turns into the accent
     * color once releasing would navigate.
     */
    public class SwipeNavigation : Box {
        private const double AXIS_LOCK = 12;
        private const double THRESHOLD = 140;

        public signal void back();
        public signal void forward();

        public bool can_go_back { get; set; default = false; }
        public bool can_go_forward { get; set; default = false; }

        private Box indicator;
        private Image arrow;
        private double dx = 0;
        private double dy = 0;
        private bool tracking = false;
        private bool horizontal = false;
        private GLib.Settings? input_settings = null;

        public SwipeNavigation(Widget content) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            var overlay = new Overlay();
            overlay.hexpand = true;
            overlay.vexpand = true;
            overlay.child = content;
            append(overlay);

            indicator = new Box(Orientation.HORIZONTAL, 0);
            indicator.add_css_class("swipe-nav-indicator");
            indicator.valign = Align.CENTER;
            indicator.can_target = false;
            indicator.visible = false;
            arrow = new Image();
            arrow.pixel_size = 20;
            arrow.hexpand = true;
            arrow.halign = Align.CENTER;
            indicator.append(arrow);
            overlay.add_overlay(indicator);

            var source = SettingsSchemaSource.get_default();
            if (source != null && source.lookup("dev.sinty.desktop", true) != null) {
                input_settings = new GLib.Settings("dev.sinty.desktop");
            }

            var scroll = new EventControllerScroll(EventControllerScrollFlags.BOTH_AXES);
            scroll.propagation_phase = PropagationPhase.CAPTURE;
            scroll.scroll_begin.connect(() => {
                dx = 0;
                dy = 0;
                tracking = true;
                horizontal = false;
            });
            scroll.scroll.connect(on_scroll);
            scroll.scroll_end.connect(finish);
            add_controller(scroll);
        }

        private bool natural() {
            if (input_settings == null) return true;
            return input_settings.settings_schema.has_key("natural-scrolling")
                ? input_settings.get_boolean("natural-scrolling") : true;
        }

        private bool on_scroll(double delta_x, double delta_y) {
            if (!tracking) return false;
            dx += delta_x;
            dy += delta_y;
            if (!horizontal) {
                if (dx.abs() < AXIS_LOCK && dy.abs() < AXIS_LOCK) return false;
                if (dx.abs() < dy.abs() * 1.5) {
                    tracking = false;
                    return false;
                }
                horizontal = true;
            }
            show_progress();
            return true;
        }

        private bool going_back() {
            return natural() ? dx < 0 : dx > 0;
        }

        private bool allowed() {
            return going_back() ? can_go_back : can_go_forward;
        }

        private void show_progress() {
            if (!allowed()) {
                indicator.visible = false;
                return;
            }
            double progress = double.min(dx.abs() / THRESHOLD, 1.0);
            bool back_side = going_back();
            indicator.visible = true;
            indicator.halign = back_side ? Align.START : Align.END;
            arrow.icon_name = back_side ? "go-previous-symbolic" : "go-next-symbolic";
            int offset = (int) (-40 + 56 * progress);
            indicator.margin_start = back_side ? offset : 0;
            indicator.margin_end = back_side ? 0 : offset;
            indicator.opacity = 0.35 + 0.65 * progress;
            if (progress >= 1.0) indicator.add_css_class("ready");
            else indicator.remove_css_class("ready");
        }

        private void finish() {
            bool claimed = tracking && horizontal;
            tracking = false;
            horizontal = false;
            indicator.visible = false;
            indicator.remove_css_class("ready");
            if (!claimed || dx.abs() < THRESHOLD || !allowed()) return;
            if (going_back()) back();
            else forward();
        }
    }
}
