namespace Singularity.Vector {

    public struct StrokeSample {
        public double x;
        public double y;
        public double pressure;
        public double tilt_x;
        public double tilt_y;
        public double time;

        public StrokeSample (double x, double y, double pressure = 1.0, double tilt_x = 0, double tilt_y = 0, double time = 0) {
            this.x = x;
            this.y = y;
            this.pressure = pressure;
            this.tilt_x = tilt_x;
            this.tilt_y = tilt_y;
            this.time = time;
        }

        public double tilt () {
            return Math.hypot (tilt_x, tilt_y).clamp (0, 1);
        }
    }

    public class ResponseCurve {
        public double x1 = 0.25;
        public double y1 = 0.25;
        public double x2 = 0.75;
        public double y2 = 0.75;

        public ResponseCurve (double x1 = 0.25, double y1 = 0.25, double x2 = 0.75, double y2 = 0.75) {
            this.x1 = x1;
            this.y1 = y1;
            this.x2 = x2;
            this.y2 = y2;
        }

        public ResponseCurve copy () {
            return new ResponseCurve (x1, y1, x2, y2);
        }

        public double map (double v) {
            v = v.clamp (0, 1);
            double lo = 0, hi = 1;
            for (int i = 0; i < 40; i++) {
                double t = (lo + hi) / 2;
                double x = cubic (0, x1, x2, 1, t);
                if (x < v) lo = t;
                else hi = t;
            }
            return cubic (0, y1, y2, 1, (lo + hi) / 2).clamp (0, 1);
        }

        private static double cubic (double a, double b, double c, double d, double t) {
            double u = 1 - t;
            return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d;
        }

        public string to_string () {
            return "%s %s %s %s".printf (PathData.fmt (x1, 4), PathData.fmt (y1, 4), PathData.fmt (x2, 4), PathData.fmt (y2, 4));
        }

        public static ResponseCurve parse (string? s) {
            var c = new ResponseCurve ();
            if (s == null) return c;
            var parts = s.strip ().split (" ");
            if (parts.length == 4) {
                c.x1 = double.parse (parts[0]);
                c.y1 = double.parse (parts[1]);
                c.x2 = double.parse (parts[2]);
                c.y2 = double.parse (parts[3]);
            }
            return c;
        }
    }

    public class StrokeOutline {
        public static Point[] build (Point[] centers, double[] widths, bool round_caps = true) {
            int n = centers.length;
            if (n == 0) return {};
            if (n == 1) {
                Point[] dot = {};
                double r = double.max (widths[0] / 2, 0.05);
                for (int i = 0; i < 16; i++) {
                    double a = 2 * Math.PI * i / 16;
                    dot += Point (centers[0].x + r * Math.cos (a), centers[0].y + r * Math.sin (a));
                }
                return dot;
            }
            Point[] left = {};
            Point[] right = {};
            for (int i = 0; i < n; i++) {
                double dx, dy;
                if (i == 0) {
                    dx = centers[1].x - centers[0].x;
                    dy = centers[1].y - centers[0].y;
                } else if (i == n - 1) {
                    dx = centers[n - 1].x - centers[n - 2].x;
                    dy = centers[n - 1].y - centers[n - 2].y;
                } else {
                    dx = centers[i + 1].x - centers[i - 1].x;
                    dy = centers[i + 1].y - centers[i - 1].y;
                }
                double l = Math.hypot (dx, dy);
                if (l < 1e-12) {
                    dx = 1;
                    dy = 0;
                    l = 1;
                }
                double nx = -dy / l, ny = dx / l;
                double r = double.max (widths[i] / 2, 0.01);
                left += Point (centers[i].x + nx * r, centers[i].y + ny * r);
                right += Point (centers[i].x - nx * r, centers[i].y - ny * r);
            }
            Point[] outline = {};
            foreach (var p in left) outline += p;
            if (round_caps) foreach (var cp in cap (centers[n - 1], left[n - 1], right[n - 1], widths[n - 1] / 2)) outline += cp;
            for (int i = n - 1; i >= 0; i--) outline += right[i];
            if (round_caps) foreach (var cp in cap (centers[0], right[0], left[0], widths[0] / 2)) outline += cp;
            return outline;
        }

        private static Point[] cap (Point c, Point from, Point to, double r) {
            Point[] outline = {};
            double a0 = Math.atan2 (from.y - c.y, from.x - c.x);
            double a1 = Math.atan2 (to.y - c.y, to.x - c.x);
            double sweep = a1 - a0;
            while (sweep > 0) sweep -= 2 * Math.PI;
            if (sweep < -2 * Math.PI + 1e-6) sweep += 2 * Math.PI;
            int steps = 8;
            for (int i = 1; i < steps; i++) {
                double a = a0 + sweep * i / steps;
                outline += Point (c.x + r * Math.cos (a), c.y + r * Math.sin (a));
            }
            return outline;
        }

        public static PathData to_path (Point[] outline) {
            var p = new PathData ();
            p.add_polygon (outline, true);
            return p;
        }
    }

    public class Smoother {
        private double strength;
        private double sx;
        private double sy;
        private double sp;
        private bool started;

        public Smoother (double strength) {
            this.strength = strength.clamp (0, 0.98);
        }

        public StrokeSample push (StrokeSample s) {
            if (!started) {
                started = true;
                sx = s.x;
                sy = s.y;
                sp = s.pressure;
                return s;
            }
            double k = 1 - strength;
            sx += (s.x - sx) * k;
            sy += (s.y - sy) * k;
            sp += (s.pressure - sp) * k;
            var o = s;
            o.x = sx;
            o.y = sy;
            o.pressure = sp;
            return o;
        }
    }
}
