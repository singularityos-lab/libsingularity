namespace Singularity.Animation {

    public class Bezier {

        private const int NEWTON_STEPS = 8;
        private const double PRECISION = 1e-7;

        private static double coordinate(double p1, double p2, double s) {
            double inverse = 1.0 - s;
            return 3.0 * inverse * inverse * s * p1 + 3.0 * inverse * s * s * p2 + s * s * s;
        }

        private static double slope(double p1, double p2, double s) {
            double inverse = 1.0 - s;
            return 3.0 * inverse * inverse * p1 + 6.0 * inverse * s * (p2 - p1) + 3.0 * s * s * (1.0 - p2);
        }

        public static double solve_parameter(double x1, double x2, double x) {
            double s = x;
            for (int i = 0; i < NEWTON_STEPS; i++) {
                double error = coordinate(x1, x2, s) - x;
                if (Math.fabs(error) < PRECISION) return s;
                double derivative = slope(x1, x2, s);
                if (Math.fabs(derivative) < 1e-6) break;
                s -= error / derivative;
            }
            double low = 0.0;
            double high = 1.0;
            s = x;
            while (high - low > PRECISION) {
                double value = coordinate(x1, x2, s);
                if (Math.fabs(value - x) < PRECISION) return s;
                if (value < x) low = s;
                else high = s;
                s = (low + high) * 0.5;
            }
            return s;
        }

        public static double solve(double x1, double y1, double x2, double y2, double t) {
            if (t <= 0.0) return 0.0;
            if (t >= 1.0) return 1.0;
            return coordinate(y1, y2, solve_parameter(x1, x2, t));
        }

        public static double derivative(double x1, double y1, double x2, double y2, double t) {
            t = t.clamp(0.0, 1.0);
            double s = solve_parameter(x1, x2, t);
            double dx = slope(x1, x2, s);
            if (Math.fabs(dx) < 1e-9) return 0.0;
            return slope(y1, y2, s) / dx;
        }
    }

    public class SpringSolver {

        public static void evaluate(double damping, double stiffness, double mass,
                                    double displacement, double velocity, double seconds,
                                    out double position, out double speed) {
            double omega = Math.sqrt(stiffness / mass);
            double zeta = damping / (2.0 * Math.sqrt(stiffness * mass));
            if (Math.fabs(zeta - 1.0) < 1e-6) {
                double b = velocity + omega * displacement;
                double decay = Math.exp(-omega * seconds);
                position = decay * (displacement + b * seconds);
                speed = decay * (b - omega * (displacement + b * seconds));
                return;
            }
            if (zeta < 1.0) {
                double omega_d = omega * Math.sqrt(1.0 - zeta * zeta);
                double a = displacement;
                double b = (velocity + zeta * omega * displacement) / omega_d;
                double decay = Math.exp(-zeta * omega * seconds);
                double cosine = Math.cos(omega_d * seconds);
                double sine = Math.sin(omega_d * seconds);
                position = decay * (a * cosine + b * sine);
                speed = decay * (-zeta * omega * (a * cosine + b * sine) + omega_d * (b * cosine - a * sine));
                return;
            }
            double root = Math.sqrt(zeta * zeta - 1.0);
            double r1 = -omega * (zeta - root);
            double r2 = -omega * (zeta + root);
            double c2 = (velocity - r1 * displacement) / (r2 - r1);
            double c1 = displacement - c2;
            position = c1 * Math.exp(r1 * seconds) + c2 * Math.exp(r2 * seconds);
            speed = r1 * c1 * Math.exp(r1 * seconds) + r2 * c2 * Math.exp(r2 * seconds);
        }

        public static bool at_rest(double displacement, double velocity, double epsilon) {
            return Math.fabs(displacement) < epsilon && Math.fabs(velocity) / 60.0 < epsilon;
        }

        public static double settle_time(double damping, double stiffness, double mass,
                                         double displacement, double velocity,
                                         double epsilon = Singularity.Motion.REST_EPSILON) {
            const double STEP = 0.001;
            const double LIMIT = 10.0;
            for (double t = 0.0; t < LIMIT; t += STEP) {
                double position, speed;
                evaluate(damping, stiffness, mass, displacement, velocity, t, out position, out speed);
                if (at_rest(position, speed, epsilon)) return t;
            }
            return LIMIT;
        }
    }

    public class VelocityTracker {

        private const int64 WINDOW_US = 100000;

        private int64[] _times = {};
        private double[] _values = {};

        public void reset() {
            _times = {};
            _values = {};
        }

        public void add(int64 time_us, double value) {
            int64[] times = {};
            double[] values = {};
            for (int i = 0; i < _times.length; i++) {
                if (time_us - _times[i] <= WINDOW_US && _times[i] < time_us) {
                    times += _times[i];
                    values += _values[i];
                }
            }
            times += time_us;
            values += value;
            _times = times;
            _values = values;
        }

        public double velocity {
            get {
                int count = _times.length;
                if (count < 2) return 0.0;
                double mean_t = 0.0;
                double mean_v = 0.0;
                for (int i = 0; i < count; i++) {
                    mean_t += (_times[i] - _times[0]) / 1000000.0;
                    mean_v += _values[i];
                }
                mean_t /= count;
                mean_v /= count;
                double numerator = 0.0;
                double denominator = 0.0;
                for (int i = 0; i < count; i++) {
                    double dt = (_times[i] - _times[0]) / 1000000.0 - mean_t;
                    numerator += dt * (_values[i] - mean_v);
                    denominator += dt * dt;
                }
                return denominator > 0.0 ? numerator / denominator : 0.0;
            }
        }
    }
}
