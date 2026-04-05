namespace Singularity.Animation {

    /**
     * An Animation that interpolates a numeric value between two endpoints
     * over a fixed duration using a configurable easing curve.
     */
    public class TimedAnimation : Animation {

        private int64 start_time = 0;

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
            EASE_IN_OUT_CUBIC
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
        public TimedAnimation(Gtk.Widget widget, double from, double to, uint duration_ms, Easing easing_type = Easing.EASE_OUT_CUBIC) {
            base(widget);
            this.value_from = from;
            this.value_to = to;
            this.duration = duration_ms;
            this.easing = easing_type;
            this.value = from;
        }

        /** Resets the elapsed timer and starts playback from `value_from`. */
        public new void play() {
            start_time = 0;
            base.play();
        }

        protected override bool on_update(int64 frame_time) {
            if (start_time == 0) {
                start_time = frame_time;
            }

            int64 elapsed = (frame_time - start_time) / 1000;
            double t = (double)elapsed / (double)duration;
            if (t >= 1.0) {
                value = value_to;
                return false;
            }

            double eased_t = ease(t);
            value = value_from + (value_to - value_from) * eased_t;

            return true;
        }

        private double ease(double t) {
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
                default: return t;
            }
        }
    }
}
