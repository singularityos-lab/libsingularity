namespace Singularity.Vector {

    public enum PathfinderOp {
        UNION,
        SUBTRACT,
        INTERSECT,
        EXCLUDE,
        DIVIDE,
        TRIM,
        MERGE,
        CROP,
        OUTLINE,
        MINUS_BACK
    }

    public delegate bool RegionPredicate (bool[] inside);

    public class ArrangementFace : Object {
        public PathData path;
        public bool[] inside;
        public Point sample;

        public ArrangementFace (PathData path, bool[] inside, Point sample) {
            this.path = path;
            this.inside = inside;
            this.sample = sample;
        }

        public int topmost () {
            for (int i = inside.length - 1; i >= 0; i--) if (inside[i]) return i;
            return -1;
        }

        public string signature () {
            var b = new StringBuilder ();
            foreach (bool v in inside) b.append_c (v ? '1' : '0');
            return b.str;
        }
    }

    public class Arrangement : Object {
        private class Hits : Object {
            private CurveEdge first;
            private CurveEdge second;
            private double epsilon;
            private int visited = 0;

            public Hits (CurveEdge first, CurveEdge second, double epsilon) {
                this.first = first;
                this.second = second;
                this.epsilon = epsilon;
            }

            public void find () {
                descend (first, second, 0, 1, 0, 1, 0);
            }

            private void descend (CurveEdge a, CurveEdge b, double a0, double a1, double b0, double b1, int depth) {
                if (++visited > 40000) return;
                var ab = a.hull ();
                var bb = b.hull ();
                if (!ab.inflate (epsilon).intersects (bb.inflate (epsilon))) return;
                if (depth >= 60 || (Math.hypot (ab.w, ab.h) < epsilon && Math.hypot (bb.w, bb.h) < epsilon)) {
                    double ta = (a0 + a1) / 2, tb = (b0 + b1) / 2;
                    for (int i = 0; i < 12; i++) {
                        var pa = first.at (ta);
                        var pb = second.at (tb);
                        var da = first.tangent (ta);
                        var db = second.tangent (tb);
                        double det = da.x * db.y - da.y * db.x;
                        if (det.abs () < 1e-16) break;
                        double rx = pa.x - pb.x, ry = pa.y - pb.y;
                        double na = ta - (rx * db.y - ry * db.x) / det;
                        double nb = tb - (rx * da.y - ry * da.x) / det;
                        if (na < a0 - 1e-8 || na > a1 + 1e-8 || nb < b0 - 1e-8 || nb > b1 + 1e-8) break;
                        ta = na.clamp (0, 1);
                        tb = nb.clamp (0, 1);
                    }
                    if (first.at (ta).distance (second.at (tb)) <= epsilon * 4) {
                        first.cut (ta);
                        second.cut (tb);
                    }
                    return;
                }
                if (Math.hypot (ab.w, ab.h) >= Math.hypot (bb.w, bb.h)) {
                    double mid = (a0 + a1) / 2;
                    descend (a.part (0, 0.5), b, a0, mid, b0, b1, depth + 1);
                    descend (a.part (0.5, 1), b, mid, a1, b0, b1, depth + 1);
                } else {
                    double mid = (b0 + b1) / 2;
                    descend (a, b.part (0, 0.5), a0, a1, b0, mid, depth + 1);
                    descend (a, b.part (0.5, 1), a0, a1, mid, b1, depth + 1);
                }
            }
        }

        public Gee.ArrayList<Gee.ArrayList<CurveEdge>> inputs = new Gee.ArrayList<Gee.ArrayList<CurveEdge>> ();
        private bool[] even_odd = {};
        public Gee.ArrayList<CurveEdge> pieces = new Gee.ArrayList<CurveEdge> ();
        private Gee.ArrayList<string> left_sets = new Gee.ArrayList<string> ();
        private Gee.ArrayList<string> right_sets = new Gee.ArrayList<string> ();
        public double epsilon = 1e-6;
        private double nudge = 0.001;

        public Arrangement (Gee.List<PathData> paths, bool[]? rules = null, bool close_open = true) {
            var box = Rect.empty ();
            bool first = true;
            for (int i = 0; i < paths.size; i++) {
                var list = PathOps.edges (paths[i], close_open);
                foreach (var e in list) e.source = i;
                inputs.add (list);
                even_odd += rules != null && i < rules.length ? rules[i] : false;
                var b = paths[i].control_bounds ();
                if (b.w <= 0 && b.h <= 0) continue;
                box = first ? b : box.union (b);
                first = false;
            }
            double diag = Math.hypot (box.w, box.h);
            epsilon = (diag * 1e-9).clamp (1e-8, 1e-5);
            nudge = (diag * 1e-6).clamp (0.00005, 0.05);
            intersect_all ();
            split_and_classify ();
        }

        private static bool same (CurveEdge a, CurveEdge b, double eps) {
            for (int i = 0; i <= 4; i++) if (a.at (i / 4.0).distance (b.at (i / 4.0)) > eps) return false;
            return true;
        }

        private void line_cuts (CurveEdge curve, CurveEdge line) {
            var path = new PathData ();
            path.move_to (curve.start.x, curve.start.y);
            path.segs.add (curve.segment.copy ());
            double dx = line.segment.x - line.start.x, dy = line.segment.y - line.start.y;
            double len = dx * dx + dy * dy;
            if (len < 1e-20) return;
            foreach (var hit in PathOps.line_hits (path, line.start, line.end ())) {
                curve.cut (hit.t);
                line.cut (((hit.point.x - line.start.x) * dx + (hit.point.y - line.start.y) * dy) / len);
            }
            foreach (double t in new double[] { 0, 1 }) {
                var p = curve.at (t);
                double u = ((p.x - line.start.x) * dx + (p.y - line.start.y) * dy) / len;
                if (u >= 0 && u <= 1 && line.at (u).distance (p) <= epsilon * 4) line.cut (u);
            }
        }

        private static bool seg_intersect (Point a, Point b, Point c, Point d, out double ta, out double tb) {
            ta = tb = 0;
            double r_x = b.x - a.x, r_y = b.y - a.y, s_x = d.x - c.x, s_y = d.y - c.y;
            double den = r_x * s_y - r_y * s_x;
            if (den.abs () < 1e-14) return false;
            double qx = c.x - a.x, qy = c.y - a.y;
            ta = (qx * s_y - qy * s_x) / den;
            tb = (qx * r_y - qy * r_x) / den;
            return ta >= -1e-9 && ta <= 1 + 1e-9 && tb >= -1e-9 && tb <= 1 + 1e-9;
        }

        private void pair (CurveEdge left, CurveEdge right) {
            if (!left.hull ().inflate (epsilon).intersects (right.hull ().inflate (epsilon))) return;
            if (same (left, right, epsilon) || same (left, right.reversed (), epsilon)) return;
            if (!left.is_curve () && !right.is_curve ()) {
                double ta, tb;
                if (seg_intersect (left.start, left.end (), right.start, right.end (), out ta, out tb)) {
                    left.cut (ta);
                    right.cut (tb);
                } else {
                    line_cuts (left, right);
                    line_cuts (right, left);
                }
            } else if (!right.is_curve ()) {
                line_cuts (left, right);
            } else if (!left.is_curve ()) {
                line_cuts (right, left);
            } else {
                new Hits (left, right, epsilon).find ();
            }
        }

        private void intersect_all () {
            var all = new Gee.ArrayList<CurveEdge> ();
            foreach (var list in inputs) all.add_all (list);
            for (int i = 0; i < all.size; i++) {
                for (int j = i + 1; j < all.size; j++) {
                    var a = all[i];
                    var b = all[j];
                    if (a.source == b.source) {
                        if (a.end ().distance (b.start) < epsilon || b.end ().distance (a.start) < epsilon) continue;
                    }
                    pair (a, b);
                }
            }
        }

        public bool[] membership (Point p) {
            bool[] result = new bool[inputs.size];
            for (int i = 0; i < inputs.size; i++) {
                int w = PathOps.winding (inputs[i], p);
                result[i] = even_odd[i] ? (w % 2 != 0) : w != 0;
            }
            return result;
        }

        private void split_and_classify () {
            foreach (var list in inputs) {
                foreach (var edge in list) {
                    edge.cuts.sort ((x, y) => x < y ? -1 : x > y ? 1 : 0);
                    for (int i = 0; i + 1 < edge.cuts.size; i++) {
                        double s = edge.cuts[i], e = edge.cuts[i + 1];
                        if (e - s < 1e-10) continue;
                        var piece = edge.part (s, e);
                        var mid = piece.at (0.5);
                        var dir = piece.tangent (0.5);
                        double len = Math.hypot (dir.x, dir.y);
                        if (len < 1e-12) continue;
                        bool dup = false;
                        foreach (var prev in pieces) {
                            if (same (prev, piece, epsilon * 8) || same (prev, piece.reversed (), epsilon * 8)) {
                                dup = true;
                                break;
                            }
                        }
                        if (dup) continue;
                        double nx = -dir.y / len * nudge, ny = dir.x / len * nudge;
                        pieces.add (piece);
                        left_sets.add (encode (membership (Point (mid.x + nx, mid.y + ny))));
                        right_sets.add (encode (membership (Point (mid.x - nx, mid.y - ny))));
                    }
                }
            }
        }

        public PathData region (RegionPredicate predicate) {
            var kept = new Gee.ArrayList<CurveEdge> ();
            for (int i = 0; i < pieces.size; i++) {
                bool l = predicate (decode (left_sets[i]));
                bool r = predicate (decode (right_sets[i]));
                if (l == r) continue;
                kept.add (l ? pieces[i].part (0, 1) : pieces[i].reversed ());
            }
            return trace (kept);
        }

        private PathData trace (Gee.ArrayList<CurveEdge> kept) {
            var result = new PathData ();
            double join = epsilon * 64 + nudge * 0.01;
            foreach (var edge in kept) {
                if (edge.used) continue;
                var first = edge.start;
                result.move_to (first.x, first.y);
                var current = edge;
                int guard = 0;
                while (true) {
                    current.used = true;
                    result.segs.add (current.segment.copy ());
                    var end = current.end ();
                    if (end.distance (first) <= join) {
                        result.close ();
                        break;
                    }
                    CurveEdge? next = null;
                    double best = join;
                    foreach (var cand in kept) {
                        if (cand.used) continue;
                        double d = end.distance (cand.start);
                        if (d < best) {
                            best = d;
                            next = cand;
                        }
                    }
                    if (next == null || ++guard > kept.size) {
                        result.close ();
                        break;
                    }
                    current = next;
                }
            }
            return result;
        }

        public static string encode (bool[] set) {
            var b = new StringBuilder ();
            foreach (bool v in set) b.append_c (v ? '1' : '0');
            return b.str;
        }

        public static bool[] decode (string key) {
            bool[] r = new bool[key.length];
            for (int i = 0; i < key.length; i++) r[i] = key[i] == '1';
            return r;
        }

        public Gee.ArrayList<ArrangementFace> faces () {
            var seen = new Gee.HashSet<string> ();
            for (int i = 0; i < pieces.size; i++) {
                foreach (var key in new string[] { left_sets[i], right_sets[i] }) {
                    if (key.contains ("1")) seen.add (key);
                }
            }
            var result = new Gee.ArrayList<ArrangementFace> ();
            foreach (var key in seen) {
                var region_path = region ((inside) => encode (inside) == key);
                foreach (var component in components (region_path)) {
                    var sample = interior_point (component);
                    result.add (new ArrangementFace (component, decode (key), sample));
                }
            }
            return result;
        }

        public static Gee.ArrayList<PathData> components (PathData path) {
            var outers = new Gee.ArrayList<PathData> ();
            var holes = new Gee.ArrayList<PathData> ();
            foreach (var c in PathOps.contours (path)) {
                double a = PathOps.signed_area (c);
                if (a.abs () < 1e-6) continue;
                if (a > 0) outers.add (c);
                else holes.add (c);
            }
            if (outers.size == 0 && holes.size > 0) {
                outers.add_all (holes);
                holes.clear ();
            }
            var result = new Gee.ArrayList<PathData> ();
            foreach (var o in outers) result.add (o.copy ());
            foreach (var h in holes) {
                var probe = h.segs[0];
                int best = -1;
                double best_area = double.INFINITY;
                for (int i = 0; i < outers.size; i++) {
                    if (!PathOps.contains (outers[i], Point (probe.x, probe.y))) {
                        var mid = PathOps.edges (h)[0].at (0.5);
                        if (!PathOps.contains (outers[i], mid)) continue;
                    }
                    double a = PathOps.signed_area (outers[i]).abs ();
                    if (a < best_area) {
                        best_area = a;
                        best = i;
                    }
                }
                if (best >= 0) result[best].append (h);
                else if (result.size > 0) result[0].append (h);
            }
            return result;
        }

        public static Point interior_point (PathData path) {
            var box = path.bounds ();
            for (int row = 1; row < 16; row++) {
                double y = box.y + box.h * row / 16.0;
                var hits = new Gee.ArrayList<double?> ();
                var edges = PathOps.edges (path, true);
                foreach (var poly in path.flatten (0.2)) {
                    var pts = poly.pts;
                    for (int i = 0; i < pts.length; i++) {
                        var a = pts[i];
                        var b = pts[(i + 1) % pts.length];
                        if ((a.y <= y && b.y > y) || (b.y <= y && a.y > y)) hits.add (a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y));
                    }
                }
                hits.sort ((p, q) => p < q ? -1 : p > q ? 1 : 0);
                double best_w = 0;
                double best_x = 0;
                for (int i = 0; i + 1 < hits.size; i++) {
                    double mx = (hits[i] + hits[i + 1]) / 2;
                    if (hits[i + 1] - hits[i] > best_w && PathOps.winding (edges, Point (mx, y)) != 0) {
                        best_w = hits[i + 1] - hits[i];
                        best_x = mx;
                    }
                }
                if (best_w > 0) return Point (best_x, y);
            }
            return Point (box.cx (), box.cy ());
        }

        public Gee.ArrayList<PathData> open_pieces (int source) {
            var result = new Gee.ArrayList<PathData> ();
            for (int i = 0; i < pieces.size; i++) {
                if (pieces[i].source != source) continue;
                var p = new PathData ();
                p.move_to (pieces[i].start.x, pieces[i].start.y);
                p.segs.add (pieces[i].segment.copy ());
                result.add (p);
            }
            return result;
        }
    }

    public class CurveBoolean {
        public static PathData apply (PathData first, PathData second, BoolOp op, bool first_even_odd = false, bool second_even_odd = false) {
            var paths = new Gee.ArrayList<PathData> ();
            paths.add (first);
            paths.add (second);
            var arr = new Arrangement (paths, { first_even_odd, second_even_odd });
            return arr.region ((s) => {
                switch (op) {
                    case BoolOp.INTERSECT: return s[0] && s[1];
                    case BoolOp.SUBTRACT: return s[0] && !s[1];
                    case BoolOp.EXCLUDE: return s[0] != s[1];
                    default: return s[0] || s[1];
                }
            });
        }

        public static PathData unite_all (Gee.List<PathData> paths) {
            if (paths.size == 0) return new PathData ();
            var arr = new Arrangement (paths);
            return arr.region ((s) => {
                foreach (bool v in s) if (v) return true;
                return false;
            });
        }

        public static PathData combine (Gee.List<PathData> paths, BoolOp op) {
            if (paths.size == 0) return new PathData ();
            var arr = new Arrangement (paths);
            int n = paths.size;
            return arr.region ((s) => {
                switch (op) {
                    case BoolOp.INTERSECT:
                        foreach (bool v in s) if (!v) return false;
                        return true;
                    case BoolOp.SUBTRACT:
                        if (!s[0]) return false;
                        for (int i = 1; i < n; i++) if (s[i]) return false;
                        return true;
                    case BoolOp.EXCLUDE:
                        int c = 0;
                        foreach (bool v in s) if (v) c++;
                        return c % 2 == 1;
                    default:
                        foreach (bool v in s) if (v) return true;
                        return false;
                }
            });
        }
    }
}
