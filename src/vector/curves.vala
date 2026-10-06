namespace Singularity.Vector {

    public struct Bezier {
        public Point p0;
        public Point p1;
        public Point p2;
        public Point p3;

        public Bezier (Point p0, Point p1, Point p2, Point p3) {
            this.p0 = p0;
            this.p1 = p1;
            this.p2 = p2;
            this.p3 = p3;
        }

        public Bezier.line (Point a, Point b) {
            p0 = a;
            p1 = Point (a.x + (b.x - a.x) / 3, a.y + (b.y - a.y) / 3);
            p2 = Point (a.x + (b.x - a.x) * 2 / 3, a.y + (b.y - a.y) * 2 / 3);
            p3 = b;
        }

        public Point at (double t) {
            return PathData.bezier_point (p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, t);
        }

        public Point derivative (double t) {
            double u = 1 - t;
            double a = 3 * u * u, b = 6 * u * t, c = 3 * t * t;
            return Point (a * (p1.x - p0.x) + b * (p2.x - p1.x) + c * (p3.x - p2.x),
                          a * (p1.y - p0.y) + b * (p2.y - p1.y) + c * (p3.y - p2.y));
        }

        public double angle_at (double t) {
            var d = derivative (t);
            if (Math.hypot (d.x, d.y) < 1e-12) {
                d = derivative (t < 0.5 ? t + 1e-3 : t - 1e-3);
                if (Math.hypot (d.x, d.y) < 1e-12) d = Point (p3.x - p0.x, p3.y - p0.y);
            }
            return Math.atan2 (d.y, d.x);
        }

        public void split (double t, out Bezier left, out Bezier right) {
            var a = lerp (p0, p1, t);
            var b = lerp (p1, p2, t);
            var c = lerp (p2, p3, t);
            var d = lerp (a, b, t);
            var e = lerp (b, c, t);
            var f = lerp (d, e, t);
            left = Bezier (p0, a, d, f);
            right = Bezier (f, e, c, p3);
        }

        public Bezier sub (double t0, double t1) {
            Bezier l, r;
            split (t0, out l, out r);
            if (t0 >= 1) return Bezier (p3, p3, p3, p3);
            double tt = (t1 - t0) / (1 - t0);
            Bezier l2, r2;
            r.split (tt.clamp (0, 1), out l2, out r2);
            return l2;
        }

        public double length (double tolerance = 0.01) {
            return length_to (1.0, tolerance);
        }

        public double length_to (double t, double tolerance = 0.01) {
            if (t <= 0) return 0;
            int n = 64;
            double total = 0;
            var prev = p0;
            for (int i = 1; i <= n; i++) {
                double tt = t * i / n;
                var p = at (tt);
                total += prev.distance (p);
                prev = p;
            }
            return total;
        }

        public double t_at_length (double len) {
            if (len <= 0) return 0;
            int n = 256;
            double total = 0;
            var prev = p0;
            for (int i = 1; i <= n; i++) {
                double tt = (double) i / n;
                var p = at (tt);
                double d = prev.distance (p);
                if (total + d >= len) {
                    double f = d > 0 ? (len - total) / d : 0;
                    return (tt - 1.0 / n) + f / n;
                }
                total += d;
                prev = p;
            }
            return 1;
        }

        public double nearest_t (double px, double py) {
            double best_t = 0, best = double.INFINITY;
            int n = 64;
            for (int i = 0; i <= n; i++) {
                double t = (double) i / n;
                var p = at (t);
                double d = Math.hypot (p.x - px, p.y - py);
                if (d < best) {
                    best = d;
                    best_t = t;
                }
            }
            double lo = double.max (0, best_t - 1.0 / n), hi = double.min (1, best_t + 1.0 / n);
            for (int k = 0; k < 30; k++) {
                double m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
                var a = at (m1);
                var b = at (m2);
                if (Math.hypot (a.x - px, a.y - py) < Math.hypot (b.x - px, b.y - py)) hi = m2;
                else lo = m1;
            }
            return (lo + hi) / 2;
        }

        public Bezier reversed () {
            return Bezier (p3, p2, p1, p0);
        }

        public static Point lerp (Point a, Point b, double t) {
            return Point (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
        }

        public Point[] flatten (double tolerance = 0.25) {
            double len = p0.distance (p1) + p1.distance (p2) + p2.distance (p3);
            int n = (int) Math.ceil (Math.sqrt (len / double.max (tolerance, 0.01)) * 1.5);
            n = n.clamp (1, 400);
            Point[] pts = { p0 };
            for (int i = 1; i <= n; i++) pts += at ((double) i / n);
            return pts;
        }
    }

    namespace Polyline {
        public double length (Point[] pts, bool closed = false) {
            double l = 0;
            for (int i = 1; i < pts.length; i++) l += pts[i - 1].distance (pts[i]);
            if (closed && pts.length > 1) l += pts[pts.length - 1].distance (pts[0]);
            return l;
        }

        public Point at_length (Point[] pts, double len, out double angle) {
            angle = 0;
            if (pts.length == 0) return Point (0, 0);
            if (pts.length == 1) return pts[0];
            double acc = 0;
            for (int i = 1; i < pts.length; i++) {
                double d = pts[i - 1].distance (pts[i]);
                angle = Math.atan2 (pts[i].y - pts[i - 1].y, pts[i].x - pts[i - 1].x);
                if (acc + d >= len && d > 0) {
                    double f = ((len - acc) / d).clamp (0, 1);
                    return Bezier.lerp (pts[i - 1], pts[i], f);
                }
                acc += d;
            }
            return pts[pts.length - 1];
        }

        public Point[] resample (Point[] pts, double spacing) {
            if (pts.length < 2 || spacing <= 0) return pts;
            double total = length (pts);
            int n = int.max (1, (int) Math.round (total / spacing));
            Point[] result = {};
            for (int i = 0; i <= n; i++) {
                double a;
                result += at_length (pts, total * i / n, out a);
            }
            return result;
        }

        public double signed_area (Point[] pts) {
            double a = 0;
            for (int i = 0; i < pts.length; i++) {
                var p = pts[i];
                var q = pts[(i + 1) % pts.length];
                a += p.x * q.y - q.x * p.y;
            }
            return a / 2;
        }

        public Point[] reversed (Point[] pts) {
            Point[] r = new Point[pts.length];
            for (int i = 0; i < pts.length; i++) r[i] = pts[pts.length - 1 - i];
            return r;
        }

        public Point[] simplify (Point[] pts, double tolerance) {
            if (pts.length < 3) return pts;
            var keep = new bool[pts.length];
            keep[0] = true;
            keep[pts.length - 1] = true;
            rdp (pts, 0, pts.length - 1, tolerance, keep);
            Point[] out_pts = {};
            for (int i = 0; i < pts.length; i++) if (keep[i]) out_pts += pts[i];
            return out_pts;
        }

        private void rdp (Point[] pts, int a, int b, double tol, bool[] keep) {
            if (b <= a + 1) return;
            double best = -1;
            int idx = -1;
            for (int i = a + 1; i < b; i++) {
                double d = PathData.segment_distance (pts[a], pts[b], pts[i].x, pts[i].y);
                if (d > best) {
                    best = d;
                    idx = i;
                }
            }
            if (best > tol) {
                keep[idx] = true;
                rdp (pts, a, idx, tol, keep);
                rdp (pts, idx, b, tol, keep);
            }
        }

        public bool segment_intersection (Point a, Point b, Point c, Point d, out Point hit, out double t, out double u) {
            hit = Point (0, 0);
            t = 0;
            u = 0;
            double rx = b.x - a.x, ry = b.y - a.y, sx = d.x - c.x, sy = d.y - c.y;
            double den = rx * sy - ry * sx;
            if (den.abs () < 1e-12) return false;
            double qx = c.x - a.x, qy = c.y - a.y;
            t = (qx * sy - qy * sx) / den;
            u = (qx * ry - qy * rx) / den;
            hit = Point (a.x + rx * t, a.y + ry * t);
            return true;
        }

        public Point[] smooth_catmull_rom (Point[] pts, int steps = 8) {
            if (pts.length < 3) return pts;
            Point[] out_pts = {};
            for (int i = 0; i < pts.length - 1; i++) {
                var p0 = pts[int.max (0, i - 1)];
                var p1 = pts[i];
                var p2 = pts[i + 1];
                var p3 = pts[int.min (pts.length - 1, i + 2)];
                var bz = Bezier (p1,
                    Point (p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6),
                    Point (p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6), p2);
                for (int s = (i == 0 ? 0 : 1); s <= steps; s++) out_pts += bz.at ((double) s / steps);
            }
            return out_pts;
        }
    }

    public class CurveFit {
        public static Gee.ArrayList<Bezier?> fit (Point[] pts, double error) {
            var result = new Gee.ArrayList<Bezier?> ();
            if (pts.length < 2) return result;
            if (pts.length == 2) {
                result.add (Bezier.line (pts[0], pts[1]));
                return result;
            }
            var t1 = unit (sub (pts[1], pts[0]));
            var t2 = unit (sub (pts[pts.length - 2], pts[pts.length - 1]));
            fit_cubic (pts, 0, pts.length - 1, t1, t2, error, result, 0);
            return result;
        }

        private static Point sub (Point a, Point b) {
            return Point (a.x - b.x, a.y - b.y);
        }

        private static Point unit (Point v) {
            double l = Math.hypot (v.x, v.y);
            return l > 1e-12 ? Point (v.x / l, v.y / l) : Point (0, 0);
        }

        private static double dot (Point a, Point b) {
            return a.x * b.x + a.y * b.y;
        }

        private static void fit_cubic (Point[] pts, int first, int last, Point t1, Point t2, double error, Gee.ArrayList<Bezier?> result, int depth) {
            int n = last - first + 1;
            if (n == 2) {
                double d = pts[first].distance (pts[last]) / 3;
                result.add (Bezier (pts[first], Point (pts[first].x + t1.x * d, pts[first].y + t1.y * d),
                    Point (pts[last].x + t2.x * d, pts[last].y + t2.y * d), pts[last]));
                return;
            }
            var u = chord_params (pts, first, last);
            var bz = generate (pts, first, last, u, t1, t2);
            int split;
            double max_err = max_error (pts, first, last, bz, u, out split);
            if (max_err < error) {
                result.add (bz);
                return;
            }
            if (max_err < error * 4) {
                for (int it = 0; it < 4; it++) {
                    reparam (pts, first, last, u, bz);
                    bz = generate (pts, first, last, u, t1, t2);
                    max_err = max_error (pts, first, last, bz, u, out split);
                    if (max_err < error) {
                        result.add (bz);
                        return;
                    }
                }
            }
            if (depth > 24) {
                result.add (bz);
                return;
            }
            split = split.clamp (first + 1, last - 1);
            var tc = unit (sub (pts[split - 1], pts[split + 1]));
            fit_cubic (pts, first, split, t1, tc, error, result, depth + 1);
            fit_cubic (pts, split, last, Point (-tc.x, -tc.y), t2, error, result, depth + 1);
        }

        private static double[] chord_params (Point[] pts, int first, int last) {
            var u = new double[last - first + 1];
            u[0] = 0;
            for (int i = first + 1; i <= last; i++) u[i - first] = u[i - first - 1] + pts[i].distance (pts[i - 1]);
            double total = u[last - first];
            for (int i = 0; i < u.length; i++) u[i] = total > 0 ? u[i] / total : 0;
            return u;
        }

        private static Bezier generate (Point[] pts, int first, int last, double[] u, Point t1, Point t2) {
            double c00 = 0, c01 = 0, c11 = 0, x0 = 0, x1 = 0;
            var p0 = pts[first];
            var p3 = pts[last];
            for (int i = 0; i < u.length; i++) {
                double t = u[i], m = 1 - t;
                double b0 = m * m * m, b1 = 3 * t * m * m, b2 = 3 * t * t * m, b3 = t * t * t;
                var a1 = Point (t1.x * b1, t1.y * b1);
                var a2 = Point (t2.x * b2, t2.y * b2);
                c00 += dot (a1, a1);
                c01 += dot (a1, a2);
                c11 += dot (a2, a2);
                var tmp = Point (pts[first + i].x - (p0.x * (b0 + b1) + p3.x * (b2 + b3)),
                                 pts[first + i].y - (p0.y * (b0 + b1) + p3.y * (b2 + b3)));
                x0 += dot (a1, tmp);
                x1 += dot (a2, tmp);
            }
            double det = c00 * c11 - c01 * c01;
            double alpha1 = det.abs () > 1e-12 ? (x0 * c11 - x1 * c01) / det : 0;
            double alpha2 = det.abs () > 1e-12 ? (c00 * x1 - c01 * x0) / det : 0;
            double seg = p0.distance (p3);
            double eps = 1e-6 * seg;
            if (alpha1 < eps || alpha2 < eps) {
                alpha1 = seg / 3;
                alpha2 = seg / 3;
            }
            return Bezier (p0, Point (p0.x + t1.x * alpha1, p0.y + t1.y * alpha1), Point (p3.x + t2.x * alpha2, p3.y + t2.y * alpha2), p3);
        }

        private static double max_error (Point[] pts, int first, int last, Bezier bz, double[] u, out int split) {
            split = (first + last) / 2;
            double best = 0;
            for (int i = first + 1; i < last; i++) {
                var p = bz.at (u[i - first]);
                double d = p.distance (pts[i]);
                if (d > best) {
                    best = d;
                    split = i;
                }
            }
            return best;
        }

        private static void reparam (Point[] pts, int first, int last, double[] u, Bezier bz) {
            for (int i = first; i <= last; i++) {
                double t = u[i - first];
                var q = bz.at (t);
                var d1 = bz.derivative (t);
                double m = 1 - t;
                var d2 = Point (6 * m * (bz.p2.x - 2 * bz.p1.x + bz.p0.x) + 6 * t * (bz.p3.x - 2 * bz.p2.x + bz.p1.x),
                                6 * m * (bz.p2.y - 2 * bz.p1.y + bz.p0.y) + 6 * t * (bz.p3.y - 2 * bz.p2.y + bz.p1.y));
                double num = (q.x - pts[i].x) * d1.x + (q.y - pts[i].y) * d1.y;
                double den = d1.x * d1.x + d1.y * d1.y + (q.x - pts[i].x) * d2.x + (q.y - pts[i].y) * d2.y;
                if (den.abs () > 1e-12) u[i - first] = (t - num / den).clamp (0, 1);
            }
        }
    }
}
