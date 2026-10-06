namespace Singularity.Animation {

    public class SpringAnimation : Animation {

        private double start_value = 0.0;
        private double start_velocity = 0.0;
        private VelocityTracker tracker = new VelocityTracker();

        public double value { get; private set; default = 0.0; }

        public double velocity { get; private set; default = 0.0; }

        public double value_from { get; set; default = 0.0; }

        public double value_to { get; set; default = 1.0; }

        public double initial_velocity { get; set; default = 0.0; }

        public double damping { get; set; default = 30.0; }

        public double stiffness { get; set; default = 400.0; }

        public double mass { get; set; default = 1.0; }

        public double epsilon { get; set; default = Singularity.Motion.REST_EPSILON; }

        public bool clamp { get; set; default = false; }

        public bool tracking { get; private set; default = false; }

        public SpringAnimation(Gtk.Widget? widget, double from, double to, Singularity.Motion.Spring spring = Singularity.Motion.Spring.SNAPPY) {
            base(widget);
            value_from = from;
            value_to = to;
            value = from;
            use_spring(spring);
            reduced_mode = ReducedMode.SHORTEN;
        }

        public SpringAnimation.with_params(Gtk.Widget? widget, double from, double to,
                                           double damping, double stiffness, double mass = 1.0) {
            base(widget);
            value_from = from;
            value_to = to;
            value = from;
            this.damping = damping;
            this.stiffness = stiffness;
            this.mass = mass;
            reduced_mode = ReducedMode.SHORTEN;
        }

        public void use_spring(Singularity.Motion.Spring spring) {
            damping = spring.damping();
            stiffness = spring.stiffness();
            mass = spring.mass();
        }

        public double estimated_duration {
            get {
                return SpringSolver.settle_time(damping, stiffness, mass,
                    value_from - value_to, initial_velocity, epsilon) * 1000.0;
            }
        }

        protected override void on_begin() {
            tracking = false;
            start_value = value_from;
            start_velocity = initial_velocity;
            value = value_from;
            velocity = initial_velocity;
        }

        public override double current_value() {
            return value;
        }

        protected override void on_finish() {
            value = value_to;
            velocity = 0.0;
        }

        protected override bool on_update(double elapsed_ms) {
            if (reduced) {
                double duration = Singularity.Motion.Duration.SMALL.ms();
                double t = elapsed_ms / duration;
                if (t >= 1.0) {
                    on_finish();
                    return false;
                }
                value = start_value + (value_to - start_value) * t;
                velocity = (value_to - start_value) * 1000.0 / duration;
                return true;
            }
            double position, speed;
            SpringSolver.evaluate(damping, stiffness, mass, start_value - value_to, start_velocity,
                elapsed_ms / 1000.0, out position, out speed);
            if (clamp && crossed(position)) {
                on_finish();
                return false;
            }
            if (SpringSolver.at_rest(position, speed, epsilon)) {
                on_finish();
                return false;
            }
            value = value_to + position;
            velocity = speed;
            return true;
        }

        private bool crossed(double position) {
            double initial = start_value - value_to;
            if (initial == 0.0) return false;
            return (initial > 0.0 && position < 0.0) || (initial < 0.0 && position > 0.0);
        }

        public void override_velocity(double new_velocity) {
            velocity = new_velocity;
            if (state == AnimationState.PLAYING) {
                start_value = value;
                start_velocity = new_velocity;
                restart_clock();
            }
        }

        public void set_current(double current) {
            value = current;
            if (state == AnimationState.PLAYING) {
                start_value = current;
                start_velocity = velocity;
                restart_clock();
            }
        }

        public void retarget(double to) {
            if (state != AnimationState.PLAYING) {
                value_from = value;
                initial_velocity = velocity;
                value_to = to;
                play();
                return;
            }
            start_value = value;
            start_velocity = velocity;
            value_from = value;
            value_to = to;
            restart_clock();
        }

        public void track(double new_value) {
            var motion = Singularity.Motion.get_default();
            track_at(motion.manual_clock ? motion.manual_time : GLib.get_monotonic_time(), new_value);
        }

        public void track_at(int64 time_us, double new_value) {
            if (!tracking) {
                if (state == AnimationState.PLAYING) reset();
                tracker.reset();
                tracking = true;
            }
            tracker.add(time_us, new_value);
            value = new_value;
            velocity = tracker.velocity;
            tick();
        }

        public void release(double to, double release_velocity = double.NAN) {
            double speed = release_velocity.is_nan() ? tracker.velocity : release_velocity;
            tracking = false;
            if (state == AnimationState.PLAYING) reset();
            value_from = value;
            value_to = to;
            initial_velocity = speed;
            delay = 0;
            play();
        }
    }
}
