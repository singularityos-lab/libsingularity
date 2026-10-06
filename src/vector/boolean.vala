namespace Singularity.Vector {

    public enum BoolOp {
        UNION,
        SUBTRACT,
        INTERSECT,
        EXCLUDE
    }

    public class PathBoolean {
        private const double EPS = 1e-7;

        private class Edge {
            public Point a;
            public Point b;
            public bool from_a;
            public bool used;

            public Edge (Point a, Point b, bool from_a) {
                this.a = a;
                this.b = b;
                this.from_a = from_a;
            }
        }

        private static Gee.ArrayList<Polygon> closed_polys (PathData p) {
            var list = new Gee.ArrayList<Polygon> ();
            foreach (var poly in p.flatten (0.25)) {
                if (poly.pts.length < 3) continue;
                poly.closed = true;
                list.add (poly);
            }
            return list;
        }

        private static int winding (Gee.List<Polygon> polys, double px, double py) {
            int w = 0;
            foreach (var poly in polys) {
                int n = poly.pts.length;
                for (int i = 0; i < n; i++) {
                    var a = poly.pts[i];
                    var b = poly.pts[(i + 1) % n];
                    if (a.y <= py) {
                        if (b.y > py && (b.x - a.x) * (py - a.y) - (px - a.x) * (b.y - a.y) > 0) w++;
                    } else if (b.y <= py && (b.x - a.x) * (py - a.y) - (px - a.x) * (b.y - a.y) < 0) {
                        w--;
                    }
                }
            }
            return w;
        }

        private static bool result_in (BoolOp op, bool ina, bool inb) {
            switch (op) {
                case BoolOp.UNION: return ina || inb;
                case BoolOp.SUBTRACT: return ina && !inb;
                case BoolOp.INTERSECT: return ina && inb;
                default: return ina != inb;
            }
        }

        private static Gee.ArrayList<Edge> edges_of (Gee.List<Polygon> polys, bool from_a) {
            var list = new Gee.ArrayList<Edge> ();
            foreach (var poly in polys) {
                int n = poly.pts.length;
                for (int i = 0; i < n; i++) {
                    var a = poly.pts[i];
                    var b = poly.pts[(i + 1) % n];
                    if (a.distance (b) < 1e-9) continue;
                    list.add (new Edge (a, b, from_a));
                }
            }
            return list;
        }

        private static Gee.ArrayList<Edge> split (Gee.List<Edge> edges, Gee.List<Edge> others) {
            var result = new Gee.ArrayList<Edge> ();
            foreach (var e in edges) {
                var ts = new Gee.ArrayList<double?> ();
                foreach (var o in others) {
                    double t, u;
                    if (intersect (e.a, e.b, o.a, o.b, out t, out u)) {
                        if (t > EPS && t < 1 - EPS) ts.add (t);
                    } else {
                        foreach (var q in new Point[] { o.a, o.b }) {
                            double tt = project (e.a, e.b, q);
                            if (tt > EPS && tt < 1 - EPS) {
                                var pp = Point (e.a.x + (e.b.x - e.a.x) * tt, e.a.y + (e.b.y - e.a.y) * tt);
                                if (pp.distance (q) < 1e-6) ts.add (tt);
                            }
                        }
                    }
                }
                ts.sort ((x, y) => x < y ? -1 : (x > y ? 1 : 0));
                var prev = e.a;
                double last_t = 0;
                foreach (double? t in ts) {
                    if (t - last_t < EPS) continue;
                    var p = Point (e.a.x + (e.b.x - e.a.x) * t, e.a.y + (e.b.y - e.a.y) * t);
                    result.add (new Edge (prev, p, e.from_a));
                    prev = p;
                    last_t = t;
                }
                result.add (new Edge (prev, e.b, e.from_a));
            }
            return result;
        }

        private static double project (Point a, Point b, Point p) {
            double dx = b.x - a.x, dy = b.y - a.y;
            double l2 = dx * dx + dy * dy;
            if (l2 < 1e-18) return -1;
            return ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2;
        }

        private static bool intersect (Point a, Point b, Point c, Point d, out double t, out double u) {
            t = 0;
            u = 0;
            double rx = b.x - a.x, ry = b.y - a.y, sx = d.x - c.x, sy = d.y - c.y;
            double den = rx * sy - ry * sx;
            if (den.abs () < 1e-12) return false;
            double qx = c.x - a.x, qy = c.y - a.y;
            t = (qx * sy - qy * sx) / den;
            u = (qx * ry - qy * rx) / den;
            return t >= -EPS && t <= 1 + EPS && u >= -EPS && u <= 1 + EPS;
        }

        public static PathData apply (PathData pa, PathData pb, BoolOp op) {
            var a = closed_polys (pa);
            var b = closed_polys (pb);
            var ea = edges_of (a, true);
            var eb = edges_of (b, false);
            var sa = split (ea, eb);
            var sb = split (eb, ea);
            var all = new Gee.ArrayList<Edge> ();
            all.add_all (sa);
            all.add_all (sb);
            var bounds = pa.control_bounds ().union (pb.control_bounds ());
            double off = double.max (bounds.w, bounds.h) * 1e-5 + 1e-4;
            var kept = new Gee.ArrayList<Edge> ();
            var seen = new Gee.HashSet<string> ();
            foreach (var e in all) {
                double mx = (e.a.x + e.b.x) / 2, my = (e.a.y + e.b.y) / 2;
                double dx = e.b.x - e.a.x, dy = e.b.y - e.a.y;
                double len = Math.hypot (dx, dy);
                if (len < 1e-9) continue;
                double nx = -dy / len * off, ny = dx / len * off;
                bool l_in = result_in (op, winding (a, mx + nx, my + ny) != 0, winding (b, mx + nx, my + ny) != 0);
                bool r_in = result_in (op, winding (a, mx - nx, my - ny) != 0, winding (b, mx - nx, my - ny) != 0);
                if (l_in == r_in) continue;
                Edge k = l_in ? new Edge (e.a, e.b, e.from_a) : new Edge (e.b, e.a, e.from_a);
                string key = "%s:%s:%s:%s".printf (PathData.fmt (k.a.x, 4), PathData.fmt (k.a.y, 4), PathData.fmt (k.b.x, 4), PathData.fmt (k.b.y, 4));
                if (seen.contains (key)) continue;
                seen.add (key);
                kept.add (k);
            }
            return chain (kept);
        }

        private static string pkey (Point p) {
            return "%s:%s".printf (PathData.fmt (p.x, 3), PathData.fmt (p.y, 3));
        }

        private static PathData chain (Gee.ArrayList<Edge> edges) {
            var by_start = new Gee.HashMap<string, Gee.ArrayList<Edge>> ();
            foreach (var e in edges) {
                string k = pkey (e.a);
                if (!by_start.has_key (k)) by_start[k] = new Gee.ArrayList<Edge> ();
                by_start[k].add (e);
            }
            var result = new PathData ();
            foreach (var start in edges) {
                if (start.used) continue;
                var poly = new Polygon ();
                var cur = start;
                string start_key = pkey (start.a);
                int guard = 0;
                while (cur != null && guard++ < edges.size + 2) {
                    cur.used = true;
                    poly.add (cur.a.x, cur.a.y);
                    string k = pkey (cur.b);
                    if (k == start_key) break;
                    Edge? next = null;
                    double best = double.INFINITY;
                    if (by_start.has_key (k)) {
                        double ang_in = Math.atan2 (cur.b.y - cur.a.y, cur.b.x - cur.a.x);
                        foreach (var cand in by_start[k]) {
                            if (cand.used) continue;
                            double ang_out = Math.atan2 (cand.b.y - cand.a.y, cand.b.x - cand.a.x);
                            double turn = ang_out - ang_in;
                            while (turn <= -Math.PI) turn += 2 * Math.PI;
                            while (turn > Math.PI) turn -= 2 * Math.PI;
                            double score = -turn;
                            if (score < best) {
                                best = score;
                                next = cand;
                            }
                        }
                    }
                    cur = next;
                }
                if (poly.pts.length >= 3) {
                    var pts = simplify (poly.pts);
                    if (pts.length >= 3) result.add_polygon (pts, true);
                }
            }
            return result;
        }

        private static Point[] simplify (Point[] pts) {
            Point[] out_pts = {};
            int n = pts.length;
            for (int i = 0; i < n; i++) {
                var prev = pts[(i + n - 1) % n];
                var cur = pts[i];
                var next = pts[(i + 1) % n];
                double cr = (cur.x - prev.x) * (next.y - cur.y) - (cur.y - prev.y) * (next.x - cur.x);
                double scale = Math.hypot (cur.x - prev.x, cur.y - prev.y) * Math.hypot (next.x - cur.x, next.y - cur.y);
                if (scale > 0 && (cr / scale).abs () < 1e-9) continue;
                out_pts += cur;
            }
            return out_pts;
        }

        public static double area (PathData p) {
            double total = 0;
            foreach (var poly in p.flatten (0.25)) total += poly.area ();
            return total.abs ();
        }
    }
}
