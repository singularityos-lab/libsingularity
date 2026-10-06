namespace Singularity.Animation {

    /**
     * An Animation that interpolates a numeric value between two endpoints
     * over a fixed duration using a configurable easing curve.
     *
     * Prefer the `with_curve` constructor with the durations and curves of
     * `Singularity.Motion`.
     */
    public class TimedAnimation : Animation {

        private uint effective_duration = 0;
        private bool effective_linear = false;

        /** Current interpolated value; updated on every frame between `value_from` and `value_to`. */
        public double value { get; private set; default = 0.0; }

        /** Starting value of the interpolation. */
        public double value_from { get; set; default = 0.0; }

        /** Ending value of the interpolation. */
        public double value_to { get; set; default = 1.0; }

        /** Duration of the animation in milliseconds. */
        public uint duration { get; set; default = 250; }

        /** Easing function applied to the normalised time `t`. */
        public Easing easing { get; set; default = Easing.EASE_OUT_CUBIC; }

        /** First control point x of the `CUBIC_BEZIER` easing, from 0 to 1. */
        public double bezier_x1 { get; set; default = 0.2; }

        /** First control point y of the `CUBIC_BEZIER` easing. */
        public double bezier_y1 { get; set; default = 0.0; }

        /** Second control point x of the `CUBIC_BEZIER` easing, from 0 to 1. */
        public double bezier_x2 { get; set; default = 0.0; }

        /** Second control point y of the `CUBIC_BEZIER` easing. */
        public double bezier_y2 { get; set; default = 1.0; }

        /**
         * Current velocity in value units per second.
         *
         * Pass it to a `SpringAnimation` to take over without a jump.
         */
        public double velocity { get; private set; default = 0.0; }

        /** Easing functions available for TimedAnimation. */
        public enum Easing {
            /** Constant speed. */
            LINEAR,
            /** Accelerates from rest. */
            EASE_IN_QUAD,
            /** Decelerates to rest. */
            EASE_OUT_QUAD,
            /** Accelerates then decelerates. */
            EASE_IN_OUT_QUAD,
            /** Accelerates from rest (cubic). */
            EASE_IN_CUBIC,
            /** Decelerates to rest (cubic). */
            EASE_OUT_CUBIC,
            /** Accelerates then decelerates (cubic). */
            EASE_IN_OUT_CUBIC,
            /** Cubic bezier defined by `bezier_x1`, `bezier_y1`, `bezier_x2` and `bezier_y2`. */
            CUBIC_BEZIER
        }

        /**
         * Creates a new timed animation.
         *
         * @param widget      The widget whose frame clock drives the animation.
         * @param from        Starting value.
         * @param to          Ending value.
         * @param duration_ms Duration in milliseconds.
         * @param easing_type Easing curve; defaults to `Easing.EASE_OUT_CUBIC`.
         */
        public TimedAnimation(Gtk.Widget? widget, double from, double to, uint duration_ms, Easing easing_type = Easing.EASE_OUT_CUBIC) {
            base(widget);
            this.value_from = from;
            this.value_to = to;
            this.duration = duration_ms;
            this.easing = easing_type;
            this.value = from;
        }

        /**
         * Creates a new timed animation that follows a Motion curve.
         *
         * @param widget      The widget whose frame clock drives the animation.
         * @param from        Starting value.
         * @param to          Ending value.
         * @param duration_ms Duration in milliseconds, usually a `Motion.Duration`.
         * @param curve       The Motion curve to follow.
         */
        public TimedAnimation.with_curve(Gtk.Widget? widget, double from, double to, uint duration_ms, Singularity.Motion.Curve curve) {
            this(widget, from, to, duration_ms, Easing.LINEAR);
            set_curve(curve);
        }

        /**
         * Follows a Motion curve.
         *
         * @param curve The curve; `LINEAR` selects `Easing.LINEAR`.
         */
        public void set_curve(Singularity.Motion.Curve curve) {
            if (curve == Singularity.Motion.Curve.LINEAR) {
                easing = Easing.LINEAR;
                return;
            }
            double x1, y1, x2, y2;
            curve.get_points(out x1, out y1, out x2, out y2);
            set_bezier(x1, y1, x2, y2);
        }

        /**
         * Follows an arbitrary cubic bezier, as in CSS `cubic-bezier()`.
         *
         * @param x1 First control point x, clamped to 0 to 1.
         * @param y1 First control point y.
         * @param x2 Second control point x, clamped to 0 to 1.
         * @param y2 Second control point y.
         */
        public void set_bezier(double x1, double y1, double x2, double y2) {
            bezier_x1 = x1.clamp(0.0, 1.0);
            bezier_y1 = y1;
            bezier_x2 = x2.clamp(0.0, 1.0);
            bezier_y2 = y2;
            easing = Easing.CUBIC_BEZIER;
        }

        protected override void on_begin() {
            value = value_from;
            velocity = 0.0;
            effective_duration = duration;
            effective_linear = false;
            if (reduced && reduced_mode == ReducedMode.SHORTEN) {
                effective_duration = uint.min(duration, Singularity.Motion.Duration.SMALL.ms());
                effective_linear = true;
            }
        }

        public override double current_value() {
            return value;
        }

        protected override void on_finish() {
            value = value_to;
            velocity = 0.0;
        }

        protected override bool on_update(double elapsed_ms) {
            double t = effective_duration > 0 ? elapsed_ms / effective_duration : 1.0;
            if (t >= 1.0) {
                on_finish();
                return false;
            }
            value = value_from + (value_to - value_from) * ease(t);
            velocity = (value_to - value_from) * ease_derivative(t) * 1000.0 / effective_duration;
            return true;
        }

        /**
         * Evaluates the easing of this animation.
         *
         * @param t Normalised time, clamped to 0 to 1.
         * @return The eased progress.
         */
        public double ease(double t) {
            t = t.clamp(0.0, 1.0);
            if (effective_linear) return t;
            switch (easing) {
                case Easing.LINEAR: return t;
                case Easing.EASE_IN_QUAD: return t * t;
                case Easing.EASE_OUT_QUAD: return t * (2 - t);
                case Easing.EASE_IN_OUT_QUAD: return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t;
                case Easing.EASE_IN_CUBIC: return t * t * t;
                case Easing.EASE_OUT_CUBIC:
                    t = t - 1;
                    return t * t * t + 1;
                case Easing.EASE_IN_OUT_CUBIC: return t < 0.5 ? 4 * t * t * t : (t - 1) * (2 * t - 2) * (2 * t - 2) + 1;
                case Easing.CUBIC_BEZIER: return Bezier.solve(bezier_x1, bezier_y1, bezier_x2, bezier_y2, t);
                default: return t;
            }
        }

        private double ease_derivative(double t) {
            if (!effective_linear && easing == Easing.CUBIC_BEZIER) {
                return Bezier.derivative(bezier_x1, bezier_y1, bezier_x2, bezier_y2, t);
            }
            const double H = 0.001;
            double low = double.max(0.0, t - H);
            double high = double.min(1.0, t + H);
            return high > low ? (ease(high) - ease(low)) / (high - low) : 0.0;
        }
    }
}
