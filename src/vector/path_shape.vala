namespace Singularity.Vector {

    public enum CornerKind { ROUND, INVERTED, CHAMFER }

    public class PathSimplify {
        public static PathData simplify (PathData source, double tolerance, double corner_angle = 40, bool straight = false) {
            var result = new PathData ();
            double limit = corner_angle * Math.PI / 180;
            foreach (var contour in PathOps.contours (source)) {
                bool closed = PathOps.contour_closed (contour);
                var edges = PathOps.edges (contour, false);
                if (edges.size == 0) continue;
                var runs = new Gee.ArrayList<Gee.ArrayList<CurveEdge>> ();
                var run = new Gee.ArrayList<CurveEdge> ();
                for (int i = 0; i < edges.size; i++) {
                    if (run.size > 0) {
                        var a = edges[i - 1].tangent (1);
                        var b = edges[i].tangent (0);
                        double turn = Math.atan2 (a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y).abs ();
                        if (turn > limit) {
                            runs.add (run);
                            run = new Gee.ArrayList<CurveEdge> ();
                        }
                    }
                    run.add (edges[i]);
                }
                runs.add (run);
                bool started = false;
                foreach (var r in runs) {
                    Point[] pts = {};
                    foreach (var e in r) {
                        double len = e.length ();
                        int n = (int) Math.ceil (len / double.max (tolerance / 2, 0.25)).clamp (2, 400);
                        for (int k = (pts.length == 0 ? 0 : 1); k <= n; k++) pts += e.at (k / (double) n);
                    }
                    if (!started) {
                        result.move_to (pts[0].x, pts[0].y);
                        started = true;
                    }
                    if (straight) {
                        var reduced = PolyOps.simplify (pts, tolerance);
                        for (int q = 1; q < reduced.length; q++) result.line_to (reduced[q].x, reduced[q].y);
                        continue;
                    }
                    foreach (var c in CurveFit.fit (pts, tolerance)) result.curve_to (c.p1.x, c.p1.y, c.p2.x, c.p2.y, c.p3.x, c.p3.y);
                }
                if (closed) result.close ();
            }
            return result;
        }

        public static int anchor_count (PathData path) {
            return PathOps.anchors (path).size;
        }
    }

    public class LiveCorners {
        public static PathData apply (PathData source, Gee.Map<int, double?> radii, Gee.Map<int, int>? kinds = null, double uniform = 0, CornerKind uniform_kind = CornerKind.ROUND) {
            var result = new PathData ();
            int offset = 0;
            foreach (var contour in PathOps.contours (source)) {
                bool closed = PathOps.contour_closed (contour);
                var edges = new Gee.ArrayList<CurveEdge> ();
                var anchor_index = new Gee.ArrayList<int> ();
                var move = contour.segs[0];
                var start = Point (move.x, move.y);
                for (int i = 1; i < contour.segs.size; i++) {
                    var s = contour.segs[i];
                    if (s.kind == SegKind.CLOSE) {
                        if (start.distance (Point (move.x, move.y)) < 1e-9) continue;
                        s = new PathSeg (SegKind.LINE, move.x, move.y);
                    }
                    var e = new CurveEdge (start, s);
                    if (s.kind == SegKind.CURVE || start.distance (e.end ()) > 1e-10) {
                        edges.add (e);
                        anchor_index.add (offset + i - 1);
                    }
                    start = e.end ();
                }
                int n = edges.size;
                if (n == 0) {
                    result.append (contour);
                    offset += contour.segs.size;
                    continue;
                }
                double[] r = new double[n];
                int[] kind = new int[n];
                for (int v = 0; v < n; v++) {
                    if (!closed && v == 0) continue;
                    int idx = anchor_index[v];
                    if (v == 0) idx = offset;
                    double val = uniform;
                    int k = (int) uniform_kind;
                    if (radii.has_key (idx)) val = radii[idx];
                    if (kinds != null && kinds.has_key (idx)) k = kinds[idx];
                    var a = edges[(v - 1 + n) % n].tangent (1);
                    var b = edges[v].tangent (0);
                    double turn = Math.atan2 (a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y).abs ();
                    if (turn < 0.02) val = 0;
                    r[v] = val;
                    kind[v] = k;
                }
                double[] ta = new double[n];
                double[] tb = new double[n];
                for (int i = 0; i < n; i++) {
                    var e = edges[i];
                    double len = e.length ();
                    var bz = e.is_curve () ? Bezier (e.start, Point (e.segment.x1, e.segment.y1), Point (e.segment.x2, e.segment.y2), e.end ()) : Bezier.line (e.start, e.end ());
                    double rs = double.min (r[i], len / 2);
                    double re = (closed || i + 1 < n) ? double.min (r[(i + 1) % n], len / 2) : 0;
                    ta[i] = rs > 0 ? bz.t_at_length (rs) : 0;
                    tb[i] = re > 0 ? bz.t_at_length (len - re) : 1;
                }
                var first_pt = edges[0].at (ta[0]);
                result.move_to (first_pt.x, first_pt.y);
                for (int i = 0; i < n; i++) {
                    var e = edges[i];
                    result.segs.add (PathOps.portion (e.start, e.segment, ta[i], tb[i]));
                    int nv = (i + 1) % n;
                    if (!closed && i + 1 >= n) break;
                    if (tb[i] >= 1 && ta[nv] <= 0) continue;
                    var from = e.at (tb[i]);
                    var to = edges[nv].at (ta[nv]);
                    var corner = e.end ();
                    switch ((CornerKind) kind[nv]) {
                        case CornerKind.CHAMFER:
                            result.line_to (to.x, to.y);
                            break;
                        case CornerKind.INVERTED:
                            var c1 = PathOps.mix (from, corner, 0.45);
                            var c2 = PathOps.mix (to, corner, 0.45);
                            var mid = Point (from.x + to.x - corner.x, from.y + to.y - corner.y);
                            c1 = PathOps.mix (from, mid, 0.55);
                            c2 = PathOps.mix (to, mid, 0.55);
                            result.curve_to (c1.x, c1.y, c2.x, c2.y, to.x, to.y);
                            break;
                        default:
                            var t1 = e.tangent (tb[i]);
                            var t2 = edges[nv].tangent (ta[nv]);
                            double angle = Math.atan2 (t1.x * t2.y - t1.y * t2.x, t1.x * t2.x + t1.y * t2.y).abs ();
                            double k = angle < 0.01 ? 0.33 : (4.0 / 3 * Math.tan (angle / 4) / Math.tan (angle / 2).clamp (0.01, 1000));
                            k = k.clamp (0.05, 1.0);
                            var h1 = PathOps.mix (from, corner, k);
                            var h2 = PathOps.mix (to, corner, k);
                            result.curve_to (h1.x, h1.y, h2.x, h2.y, to.x, to.y);
                            break;
                    }
                }
                if (closed) result.close ();
                offset += contour.segs.size;
            }
            return result;
        }
    }

    public class PolyOps {
        public static Point[] simplify (Point[] pts, double tolerance) {
            if (pts.length < 3) return pts;
            bool[] keep = new bool[pts.length];
            keep[0] = keep[pts.length - 1] = true;
            rdp (pts, 0, pts.length - 1, tolerance, keep);
            Point[] result = {};
            for (int i = 0; i < pts.length; i++) if (keep[i]) result += pts[i];
            return result;
        }

        public static PathData catmull (Point[] pts, bool closed, double tension = 1.0) {
            var p = new PathData ();
            int n = pts.length;
            if (n == 0) return p;
            p.move_to (pts[0].x, pts[0].y);
            if (n == 1) return p;
            int count = closed ? n : n - 1;
            for (int i = 0; i < count; i++) {
                var p0 = pts[closed ? (i - 1 + n) % n : int.max (i - 1, 0)];
                var p1 = pts[i];
                var p2 = pts[(i + 1) % n];
                var p3 = pts[closed ? (i + 2) % n : int.min (i + 2, n - 1)];
                double k = tension / 6;
                p.curve_to (p1.x + (p2.x - p0.x) * k, p1.y + (p2.y - p0.y) * k, p2.x - (p3.x - p1.x) * k, p2.y - (p3.y - p1.y) * k, p2.x, p2.y);
            }
            if (closed) p.close ();
            return p;
        }

        private static void rdp (Point[] pts, int a, int b, double tol, bool[] keep) {
            if (b <= a + 1) return;
            double best = 0;
            int idx = -1;
            for (int i = a + 1; i < b; i++) {
                double d = PathData.segment_distance (pts[a], pts[b], pts[i].x, pts[i].y);
                if (d > best) {
                    best = d;
                    idx = i;
                }
            }
            if (best > tol && idx > 0) {
                keep[idx] = true;
                rdp (pts, a, idx, tol, keep);
                rdp (pts, idx, b, tol, keep);
            }
        }
    }
}
