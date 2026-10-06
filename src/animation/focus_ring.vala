namespace Singularity.Animation {

    /**
     * A keyboard focus ring that moves from control to control.
     *
     * When focus moves with the keyboard the ring slides and resizes from the
     * previous control to the new one over SMALL with the standard curve,
     * instead of jumping. It lives in an overlay on top of the window
     * content, never takes input, hides the control's own outline while it
     * surrounds it and fades out when focus stops being visible. With
     * Reduced Motion it jumps.
     */
    public class FocusRing : Gtk.Widget {

        public const float WIDTH = 2.0f;
        public const float GAP = 2.0f;
        public const string RINGED_CLASS = "singularity-focus-ringed";

        private unowned Gtk.Window? _window = null;
        private Gtk.Widget? _target = null;
        private Graphene.Rect _from = Graphene.Rect();
        private Graphene.Rect _to = Graphene.Rect();
        private Graphene.Rect _current = Graphene.Rect();
        private double _progress = 1.0;
        private double _alpha = 0.0;
        private bool _shown = false;
        private TimedAnimation? _move = null;
        private uint _tick_id = 0;

        static construct {
            set_css_name("focusring");
        }

        public FocusRing() {
            Object();
        }

        construct {
            can_target = false;
            can_focus = false;
            hexpand = true;
            vexpand = true;
            add_css_class("singularity-focus-ring");
        }

        public Gtk.Widget? target {
            get { return _target; }
        }

        public bool shown {
            get { return _shown; }
        }

        public Graphene.Rect current_rect {
            get { return _current; }
        }

        public static FocusRing install(Gtk.Window window, Gtk.Overlay overlay) {
            var ring = new FocusRing();
            ring._window = window;
            overlay.add_overlay(ring);
            overlay.set_measure_overlay(ring, false);
            window.notify["focus-widget"].connect(ring.refresh);
            window.notify["focus-visible"].connect(ring.refresh);
            window.add_css_class("singularity-focus-ring-motion");
            return ring;
        }

        public static Gtk.Widget ring_target(Gtk.Widget focus) {
            var parent = focus.get_parent();
            if (focus is Gtk.Text && parent != null
                    && (parent is Gtk.Entry || parent is Gtk.SearchEntry || parent is Gtk.PasswordEntry
                        || parent is Gtk.SpinButton)) {
                return parent;
            }
            return focus;
        }

        public void refresh() {
            var window = _window;
            var focus = window != null ? window.get_focus() : null;
            bool want = window != null && window.focus_visible && focus != null
                && focus.get_mapped() && focus.get_native() == get_native();
            if (!want) {
                set_target(null);
                hide_ring();
                return;
            }
            var target = ring_target(focus);
            Graphene.Rect bounds;
            if (!measure_target(target, out bounds)) {
                set_target(null);
                hide_ring();
                return;
            }
            set_target(target);
            if (!_shown) {
                _shown = true;
                _current = bounds;
                _from = bounds;
                _to = bounds;
                _progress = 1.0;
                ensure_tick();
                Singularity.Motion.tween(this, "ring-alpha", 1.0,
                    Singularity.Motion.Duration.MICRO, Singularity.Motion.Curve.LINEAR);
                queue_draw();
                return;
            }
            _from = _current;
            _to = bounds;
            _progress = 0.0;
            if (_move != null && _move.state == AnimationState.PLAYING) _move.reset();
            _move = new TimedAnimation.with_curve(this, 0.0, 1.0,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.STANDARD);
            _move.set_sink((value) => {
                _progress = value;
                _current = interpolate(_from, _to, value);
                queue_draw();
            });
            _move.play();
            ensure_tick();
        }

        public double ring_alpha {
            get { return _alpha; }
            set {
                _alpha = value;
                queue_draw();
            }
        }

        public override void measure(Gtk.Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum = 0;
            natural = 0;
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        private void hide_ring() {
            if (!_shown) return;
            _shown = false;
            var fade = Singularity.Motion.tween(this, "ring-alpha", 0.0,
                Singularity.Motion.Duration.MICRO, Singularity.Motion.Curve.LINEAR);
            fade.done.connect(() => {
                if (!_shown) stop_tick();
            });
        }

        private void set_target(Gtk.Widget? target) {
            if (_target == target) return;
            if (_target != null) _target.remove_css_class(RINGED_CLASS);
            _target = target;
            if (_target != null) _target.add_css_class(RINGED_CLASS);
        }

        private bool measure_target(Gtk.Widget target, out Graphene.Rect bounds) {
            bounds = Graphene.Rect();
            if (!target.compute_bounds(this, out bounds)) return false;
            return bounds.get_width() > 0 && bounds.get_height() > 0;
        }

        public static Graphene.Rect interpolate(Graphene.Rect from, Graphene.Rect to, double t) {
            var result = Graphene.Rect();
            result.init(
                (float) (from.get_x() + (to.get_x() - from.get_x()) * t),
                (float) (from.get_y() + (to.get_y() - from.get_y()) * t),
                (float) (from.get_width() + (to.get_width() - from.get_width()) * t),
                (float) (from.get_height() + (to.get_height() - from.get_height()) * t));
            return result;
        }

        private void ensure_tick() {
            if (_tick_id != 0) return;
            _tick_id = add_tick_callback(() => {
                follow();
                return true;
            });
        }

        private void stop_tick() {
            if (_tick_id == 0) return;
            remove_tick_callback(_tick_id);
            _tick_id = 0;
        }

        private void follow() {
            if (!_shown || _target == null) return;
            Graphene.Rect bounds;
            if (!measure_target(_target, out bounds)) return;
            if (bounds.equal(_to)) return;
            _to = bounds;
            if (_progress >= 1.0) _current = bounds;
            else _current = interpolate(_from, _to, _progress);
            queue_draw();
        }

        private float radius_for(Graphene.Rect rect) {
            float half = float.min(rect.get_width(), rect.get_height()) / 2.0f;
            if (_target != null && (_target.has_css_class("circular") || _target.has_css_class("pill")
                    || _target is Gtk.Switch)) {
                return half + GAP;
            }
            return float.min(10.0f, half + GAP);
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            if (_alpha <= 0.0) return;
            var rect = Graphene.Rect();
            rect.init(_current.get_x() - GAP - WIDTH, _current.get_y() - GAP - WIDTH,
                _current.get_width() + 2 * (GAP + WIDTH), _current.get_height() + 2 * (GAP + WIDTH));
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(rect, radius_for(rect));
            var color = Gdk.RGBA();
            if (!color.parse(Singularity.Style.StyleManager.get_default().accent_hex)) color.parse("#3584e4");
            color.alpha = (float) (0.75 * _alpha);
            float[] widths = { WIDTH, WIDTH, WIDTH, WIDTH };
            Gdk.RGBA[] colors = { color, color, color, color };
            snapshot.append_border(rounded, widths, colors);
        }
    }
}
