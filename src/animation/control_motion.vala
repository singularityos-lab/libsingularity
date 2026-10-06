namespace Singularity.Animation {

    /**
     * Spring motion for the knob of a `Gtk.Switch`.
     *
     * The knob follows the snappy spring when the switch changes, keeps its
     * velocity when the switch is flipped again halfway, and widens by 10 %
     * while it is pressed. The track colour follows CSS over SMALL.
     */
    public class SwitchMotion : Object {

        public const double PRESS_WIDEN = 1.1;

        private const string DATA_KEY = "singularity-switch-motion";

        private Gtk.Widget? _slider = null;
        private ChildTransform? _transform = null;
        private SpringAnimation? _spring = null;
        private double _position = 0.0;
        private bool _pressed = false;

        public unowned Gtk.Switch target { get; construct; }

        public double position {
            get { return _position; }
        }

        private SwitchMotion(Gtk.Switch target) {
            Object(target: target);
        }

        construct {
            _position = target.active ? 1.0 : 0.0;
            target.notify["active"].connect(on_active);
            var click = new Gtk.GestureClick();
            click.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            click.pressed.connect(() => press(true));
            click.released.connect(() => press(false));
            click.stopped.connect(() => press(false));
            click.cancel.connect(() => press(false));
            target.add_controller(click);
        }

        public static SwitchMotion attach(Gtk.Switch target) {
            var existing = target.get_data<SwitchMotion>(DATA_KEY);
            if (existing != null) return existing;
            var motion = new SwitchMotion(target);
            target.set_data<SwitchMotion>(DATA_KEY, motion);
            return motion;
        }

        public static SwitchMotion? lookup(Gtk.Switch target) {
            return target.get_data<SwitchMotion>(DATA_KEY);
        }

        private Gtk.Widget? slider() {
            if (_slider != null && _slider.get_parent() == target) return _slider;
            for (var child = target.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child.get_css_name() == "slider" || child.get_type().name() == "GtkGizmo") {
                    _slider = child;
                    return child;
                }
            }
            return null;
        }

        private ChildTransform? transform() {
            if (_transform != null) return _transform;
            var knob = slider();
            if (knob == null) return null;
            _transform = ChildTransform.for_widget(knob, place);
            return _transform;
        }

        private void place(out int width, out int height, out double x, out double y) {
            int minimum, natural, minimum_baseline, natural_baseline;
            _slider.measure(Gtk.Orientation.HORIZONTAL, -1, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
            width = minimum;
            height = target.get_height();
            x = _position.clamp(-0.2, 1.2) * (target.get_width() - width);
            y = 0.0;
            _transform.origin_x = _position.clamp(0.0, 1.0);
        }

        private void on_active() {
            double to = target.active ? 1.0 : 0.0;
            if (!target.get_mapped()) {
                _position = to;
                return;
            }
            var knob = transform();
            if (knob == null) {
                _position = to;
                return;
            }
            if (_spring != null && _spring.state == AnimationState.PLAYING) {
                _spring.retarget(to);
                return;
            }
            _spring = new SpringAnimation(target, _position, to, Singularity.Motion.Spring.SNAPPY);
            var spring = _spring;
            spring.set_sink((value) => {
                _position = value;
                knob.hold = true;
                target.queue_allocate();
            });
            spring.done.connect(() => {
                if (_spring != spring) return;
                _position = to;
                _spring = null;
                if (!_pressed) knob.hold = false;
                target.queue_allocate();
            });
            spring.play();
        }

        public void press(bool pressed) {
            if (_pressed == pressed) return;
            _pressed = pressed;
            var knob = transform();
            if (knob == null) return;
            if (pressed) knob.hold = true;
            if (Singularity.Motion.reduced()) {
                knob.scale_x = 1.0;
                if (!pressed && _spring == null) knob.hold = false;
                return;
            }
            var widen = Singularity.Motion.tween(knob, "scale-x", pressed ? PRESS_WIDEN : 1.0,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.STANDARD, target);
            if (!pressed) {
                widen.done.connect(() => {
                    if (!_pressed && _spring == null) knob.hold = false;
                });
            }
        }
    }

    /**
     * Installs the automatic motion of every application: switches, page
     * stacks inside `Singularity.Widgets.Window` content and popovers.
     */
    public class WidgetMotion : Object {

        private static bool installed = false;

        public static void install() {
            if (installed) return;
            installed = true;
            typeof(Gtk.Switch).class_ref();
            typeof(Gtk.Stack).class_ref();
            typeof(Gtk.Popover).class_ref();
            uint map_signal = Signal.lookup("map", typeof(Gtk.Widget));
            Signal.add_emission_hook(map_signal, 0, (hint, values) => {
                var widget = values[0].get_object() as Gtk.Widget;
                if (widget is Gtk.Switch) {
                    SwitchMotion.attach((Gtk.Switch) widget);
                } else if (widget is Gtk.Stack) {
                    attach_stack((Gtk.Stack) widget);
                } else if (widget is Gtk.Popover) {
                    PopoverMotion.enter((Gtk.Popover) widget);
                }
                return true;
            });
        }

        private static void attach_stack(Gtk.Stack stack) {
            if (PageTransition.lookup(stack) != null || PageTransition.is_excluded(stack)) return;
            if (!PageTransition.is_page_like(stack.transition_type)) return;
            var root = stack.get_root() as Singularity.Widgets.Window;
            if (root == null || stack.get_native() != root || !stack.is_ancestor(root.content_area)) return;
            PageTransition.attach(stack);
        }
    }

    /**
     * Popover entrance: fades in over MEDIUM while the content grows from
     * 0.96 at the side the popover points from.
     */
    public class PopoverMotion : Object {

        private const string SKIP_KEY = "singularity-popover-motion-skip";

        public static void exclude(Gtk.Popover popover) {
            popover.set_data<bool>(SKIP_KEY, true);
        }

        public static void origin_for(Gtk.PositionType position, out double x, out double y) {
            switch (position) {
                case Gtk.PositionType.TOP: x = 0.5; y = 1.0; return;
                case Gtk.PositionType.LEFT: x = 1.0; y = 0.5; return;
                case Gtk.PositionType.RIGHT: x = 0.0; y = 0.5; return;
                default: x = 0.5; y = 0.0; return;
            }
        }

        public static void enter(Gtk.Popover popover) {
            if (popover.get_data<bool>(SKIP_KEY)) return;
            var content = popover.child;
            if (content == null) return;
            popover.opacity = 0.0;
            Singularity.Motion.tween(popover, "opacity", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER, popover);
            if (Singularity.Motion.reduced()) return;
            var transform = ChildTransform.for_widget(content, (out width, out height, out x, out y) => {
                var parent = content.get_parent();
                width = parent != null ? parent.get_width() : content.get_width();
                height = parent != null ? parent.get_height() : content.get_height();
                x = 0.0;
                y = 0.0;
            });
            double ox, oy;
            origin_for(popover.position, out ox, out oy);
            transform.origin_x = ox;
            transform.origin_y = oy;
            transform.scale_x = Singularity.Motion.ENTER_SCALE;
            transform.scale_y = Singularity.Motion.ENTER_SCALE;
            Singularity.Motion.tween(transform, "scale-x", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER, popover);
            Singularity.Motion.tween(transform, "scale-y", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER, popover);
        }
    }
}
