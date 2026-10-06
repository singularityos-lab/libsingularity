namespace Singularity.Animation {

    public class KeyframeAnimation : Animation {

        private double[] offsets = {};
        private double[] values = {};
        private Singularity.Motion.Curve[] curves = {};

        public double value { get; private set; default = 0.0; }

        public uint duration { get; set; default = Singularity.Motion.Duration.MEDIUM; }

        public KeyframeAnimation(Gtk.Widget? widget, uint duration_ms, double start_value) {
            base(widget);
            duration = duration_ms;
            value = start_value;
            add(0.0, start_value, Singularity.Motion.Curve.LINEAR);
        }

        public KeyframeAnimation add(double offset, double frame_value, Singularity.Motion.Curve curve = Singularity.Motion.Curve.STANDARD) {
            offset = offset.clamp(0.0, 1.0);
            int index = offsets.length;
            while (index > 0 && offsets[index - 1] > offset) index--;
            double[] new_offsets = {};
            double[] new_values = {};
            Singularity.Motion.Curve[] new_curves = {};
            for (int i = 0; i < offsets.length; i++) {
                if (i == index) {
                    new_offsets += offset;
                    new_values += frame_value;
                    new_curves += curve;
                }
                new_offsets += offsets[i];
                new_values += values[i];
                new_curves += curves[i];
            }
            if (index == offsets.length) {
                new_offsets += offset;
                new_values += frame_value;
                new_curves += curve;
            }
            offsets = new_offsets;
            values = new_values;
            curves = new_curves;
            return this;
        }

        public double value_at(double t) {
            if (offsets.length == 0) return value;
            t = t.clamp(0.0, 1.0);
            if (t <= offsets[0]) return values[0];
            for (int i = 1; i < offsets.length; i++) {
                if (t <= offsets[i]) {
                    double span = offsets[i] - offsets[i - 1];
                    double local = span > 0.0 ? (t - offsets[i - 1]) / span : 1.0;
                    return values[i - 1] + (values[i] - values[i - 1]) * curves[i].ease(local);
                }
            }
            return values[values.length - 1];
        }

        protected override void on_begin() {
            value = value_at(0.0);
        }

        public override double current_value() {
            return value;
        }

        protected override void on_finish() {
            value = value_at(1.0);
        }

        protected override bool on_update(double elapsed_ms) {
            double t = duration > 0 ? elapsed_ms / duration : 1.0;
            if (t >= 1.0) {
                on_finish();
                return false;
            }
            value = value_at(t);
            return true;
        }
    }
}
