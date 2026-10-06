namespace Singularity.Vector {

    public class CurveEdge : Object {
        public Point start;
        public PathSeg segment;
        public int source = -1;
        public Gee.ArrayList<double?> cuts = new Gee.ArrayList<double?> ();
        private Gee.ArrayList<double?> monotone = new Gee.ArrayList<double?> ();
        public bool used = false;

        public CurveEdge (Point start, PathSeg segment) {
            this.start = start;
            this.segment = segment.copy ();
            cuts.add (0);
            cuts.add (1);
            monotone.add (0);
            monotone.add (1);
            if (segment.kind == SegKind.CURVE) {
                double a = -start.y + 3 * segment.y1 - 3 * segment.y2 + segment.y;
                double b = 2 * (start.y - 2 * segment.y1 + segment.y2);
                double c = segment.y1 - start.y;
                double disc = b * b - 4 * a * c;
                if (a.abs () > 1e-14 && disc >= 0) {
                    double root = Math.sqrt (disc);
                    add_extremum ((-b - root) / (2 * a));
                    add_extremum ((-b + root) / (2 * a));
                } else if (b.abs () > 1e-14) {
                    add_extremum (-c / b);
                }
                monotone.sort ((x, y) => x < y ? -1 : x > y ? 1 : 0);
            }
        }

        private void add_extremum (double t) {
            if (t > 0 && t < 1) monotone.add (t);
        }

        public bool is_curve () {
            return segment.kind == SegKind.CURVE;
        }

        public Point end () {
            return Point (segment.x, segment.y);
        }

        public Point at (double t) {
            return PathOps.seg_point (start, segment, t);
        }

        public Point tangent (double t) {
            return PathOps.seg_tangent (start, segment, t);
        }

        public Point second (double t) {
            if (segment.kind != SegKind.CURVE) return Point (0, 0);
            return Point (6 * ((1 - t) * (segment.x2 - 2 * segment.x1 + start.x) + t * (segment.x - 2 * segment.x2 + segment.x1)),
                6 * ((1 - t) * (segment.y2 - 2 * segment.y1 + start.y) + t * (segment.y - 2 * segment.y2 + segment.y1)));
        }

        public Rect hull () {
            var box = Rect.from_points (start.x, start.y, segment.x, segment.y);
            if (segment.kind == SegKind.CURVE) {
                box = box.include (segment.x1, segment.y1);
                box = box.include (segment.x2, segment.y2);
            }
            return box;
        }

        public CurveEdge part (double a, double b) {
            var e = new CurveEdge (at (a), PathOps.portion (start, segment, a, b));
            e.source = source;
            return e;
        }

        public CurveEdge reversed () {
            var edge = new PathSeg (segment.kind, start.x, start.y);
            if (segment.kind == SegKind.CURVE) {
                edge.x1 = segment.x2;
                edge.y1 = segment.y2;
                edge.x2 = segment.x1;
                edge.y2 = segment.y1;
            }
            var e = new CurveEdge (end (), edge);
            e.source = source;
            return e;
        }

        public int winding (Point p) {
            int count = 0;
            for (int i = 0; i + 1 < monotone.size; i++) {
                double low = monotone[i], high = monotone[i + 1];
                var first = at (low);
                var last = at (high);
                bool upward = first.y <= p.y && p.y < last.y;
                bool downward = last.y <= p.y && p.y < first.y;
                if (!upward && !downward) continue;
                for (int step = 0; step < 48; step++) {
                    double mid = (low + high) / 2;
                    if ((at (mid).y < p.y) == upward) low = mid;
                    else high = mid;
                }
                if (at ((low + high) / 2).x > p.x) count += upward ? 1 : -1;
            }
            return count;
        }

        public void cut (double t) {
            if (t < -1e-8 || t > 1 + 1e-8 || !t.is_finite ()) return;
            t = t.clamp (0, 1);
            foreach (double existing in cuts) if ((existing - t).abs () < 1e-9) return;
            cuts.add (t);
        }

        public double length () {
            if (segment.kind != SegKind.CURVE) return start.distance (end ());
            return Bezier (start, Point (segment.x1, segment.y1), Point (segment.x2, segment.y2), end ()).length (0.05);
        }
    }

    public class PathHit : Object {
        public int segment;
        public double t;
        public Point point;
        public double distance;

        public PathHit (int segment, double t, Point point, double distance) {
            this.segment = segment;
            this.t = t;
            this.point = point;
            this.distance = distance;
        }
    }

    public struct PathSample {
        public Point point;
        public double angle;
        public double distance;
    }

    public class PathOps {
        public static Point mix (Point a, Point b, double t) {
            return Point (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
        }

        public static Point seg_point (Point start, PathSeg edge, double t) {
            var end = Point (edge.x, edge.y);
            if (edge.kind != SegKind.CURVE) return mix (start, end, t);
            var a = mix (start, Point (edge.x1, edge.y1), t);
            var b = mix (Point (edge.x1, edge.y1), Point (edge.x2, edge.y2), t);
            var c = mix (Point (edge.x2, edge.y2), end, t);
            return mix (mix (a, b, t), mix (b, c, t), t);
        }

        public static Point seg_tangent (Point start, PathSeg s, double t) {
            if (s.kind != SegKind.CURVE) return Point (s.x - start.x, s.y - start.y);
            double u = 1 - t;
            var d = Point (3 * u * u * (s.x1 - start.x) + 6 * u * t * (s.x2 - s.x1) + 3 * t * t * (s.x - s.x2),
                3 * u * u * (s.y1 - start.y) + 6 * u * t * (s.y2 - s.y1) + 3 * t * t * (s.y - s.y2));
            if (Math.hypot (d.x, d.y) < 1e-9) {
                if (t < 0.5) return Point (s.x2 - start.x, s.y2 - start.y);
                return Point (s.x - s.x1, s.y - s.y1);
            }
            return d;
        }

        public static PathSeg portion (Point start, PathSeg edge, double a, double b) {
            var finish = seg_point (start, edge, b);
            var result = new PathSeg (edge.kind == SegKind.CLOSE ? SegKind.LINE : edge.kind, finish.x, finish.y);
            if (edge.kind == SegKind.CURVE) {
                double span = b - a;
                var first = seg_point (start, edge, a);
                var da = seg_tangent (start, edge, a);
                var db = seg_tangent (start, edge, b);
                result.x1 = first.x + da.x * span / 3;
                result.y1 = first.y + da.y * span / 3;
                result.x2 = finish.x - db.x * span / 3;
                result.y2 = finish.y - db.y * span / 3;
            }
            return result;
        }

        public static Gee.ArrayList<PathData> contours (PathData path) {
            var result = new Gee.ArrayList<PathData> ();
            PathData? current = null;
            bool closed = false;
            foreach (var s in path.segs) {
                if (!s.x.is_finite () || !s.y.is_finite ()) continue;
                if (s.kind == SegKind.MOVE) {
                    current = new PathData ();
                    result.add (current);
                    closed = false;
                } else if (current == null || closed) {
                    if (s.kind == SegKind.CLOSE) continue;
                    var anchor = current != null && current.segs.size > 0 ? current.segs[0] : s;
                    current = new PathData ();
                    current.move_to (anchor.x, anchor.y);
                    result.add (current);
                    closed = false;
                }
                current.segs.add (s.copy ());
                if (s.kind == SegKind.CLOSE) closed = true;
            }
            return result;
        }

        public static bool contour_closed (PathData contour) {
            return contour.segs.size > 0 && contour.segs[contour.segs.size - 1].kind == SegKind.CLOSE;
        }

        public static bool all_closed (PathData path) {
            var list = contours (path);
            if (list.size == 0) return false;
            foreach (var c in list) if (!contour_closed (c)) return false;
            return true;
        }

        public static PathData reversed (PathData path) {
            var result = new PathData ();
            foreach (var contour in contours (path)) {
                int last = contour.segs.size - 1;
                bool closed = contour.segs[last].kind == SegKind.CLOSE;
                if (closed) last--;
                if (last < 0) continue;
                var end = contour.segs[last];
                result.move_to (end.x, end.y);
                for (int i = last; i > 0; i--) {
                    var edge = contour.segs[i];
                    var prev = contour.segs[i - 1];
                    var r = new PathSeg (edge.kind, prev.x, prev.y);
                    if (edge.kind == SegKind.CURVE) {
                        r.x1 = edge.x2;
                        r.y1 = edge.y2;
                        r.x2 = edge.x1;
                        r.y2 = edge.y1;
                    }
                    result.segs.add (r);
                }
                if (closed) result.close ();
            }
            return result;
        }

        public static Gee.ArrayList<CurveEdge> edges (PathData path, bool include_open_closing = false) {
            var result = new Gee.ArrayList<CurveEdge> ();
            foreach (var contour in contours (path)) {
                if (contour.segs.size == 0) continue;
                var move = contour.segs[0];
                var start = Point (move.x, move.y);
                bool closed = contour_closed (contour);
                for (int i = 1; i < contour.segs.size; i++) {
                    var s = contour.segs[i];
                    if (s.kind == SegKind.CLOSE) {
                        if (start.distance (Point (move.x, move.y)) < 1e-10) continue;
                        s = new PathSeg (SegKind.LINE, move.x, move.y);
                    }
                    var edge = new CurveEdge (start, s);
                    if (s.kind == SegKind.CURVE || start.distance (edge.end ()) > 1e-10) result.add (edge);
                    start = edge.end ();
                }
                if (!closed && include_open_closing && start.distance (Point (move.x, move.y)) > 1e-10) {
                    result.add (new CurveEdge (start, new PathSeg (SegKind.LINE, move.x, move.y)));
                }
            }
            return result;
        }

        public static int winding (Gee.List<CurveEdge> edges, Point p) {
            int w = 0;
            foreach (var e in edges) w += e.winding (p);
            return w;
        }

        public static bool contains (PathData path, Point p, bool even_odd = false) {
            int w = winding (edges (path, true), p);
            return even_odd ? (w % 2) != 0 : w != 0;
        }

        public static PathHit? nearest (PathData path, Point p, double radius = double.INFINITY) {
            PathHit? best = null;
            double dist = radius;
            Point start = Point (0, 0), origin = start;
            for (int i = 0; i < path.segs.size; i++) {
                var edge = path.segs[i];
                if (edge.kind == SegKind.MOVE) {
                    origin = Point (edge.x, edge.y);
                    start = origin;
                    if (start.distance (p) < dist) {
                        dist = start.distance (p);
                        best = new PathHit (i, 0, start, dist);
                    }
                    continue;
                }
                var actual = edge.kind == SegKind.CLOSE ? new PathSeg (SegKind.LINE, origin.x, origin.y) : edge;
                int n = actual.kind == SegKind.CURVE ? 24 : 1;
                for (int k = 0; k < n; k++) {
                    double a = k / (double) n, b = (k + 1) / (double) n;
                    for (int step = 0; step < 30; step++) {
                        double l = a + (b - a) / 3, r = b - (b - a) / 3;
                        if (seg_point (start, actual, l).distance (p) < seg_point (start, actual, r).distance (p)) b = r;
                        else a = l;
                    }
                    double t = (a + b) / 2;
                    var q = seg_point (start, actual, t);
                    double d = q.distance (p);
                    if (d < dist) {
                        dist = d;
                        best = new PathHit (i, t, q, d);
                    }
                }
                start = Point (actual.x, actual.y);
            }
            return best;
        }

        private static double side (Point p, Point a, Point b) {
            return (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x);
        }

        public static Gee.ArrayList<PathHit> line_hits (PathData path, Point a, Point b) {
            var cuts = new Gee.ArrayList<PathHit> ();
            if (a.distance (b) < 1e-8) return cuts;
            Point start = Point (0, 0), origin = start;
            double length = a.distance (b);
            for (int i = 0; i < path.segs.size; i++) {
                var edge = path.segs[i];
                if (edge.kind == SegKind.MOVE) {
                    origin = Point (edge.x, edge.y);
                    start = origin;
                    continue;
                }
                var actual = edge.kind == SegKind.CLOSE ? new PathSeg (SegKind.LINE, origin.x, origin.y) : edge;
                double d0 = side (start, a, b), d3 = side (Point (actual.x, actual.y), a, b);
                double d1 = actual.kind == SegKind.CURVE ? side (Point (actual.x1, actual.y1), a, b) : d0 + (d3 - d0) / 3;
                double d2 = actual.kind == SegKind.CURVE ? side (Point (actual.x2, actual.y2), a, b) : d0 + (d3 - d0) * 2 / 3;
                double pp = -d0 + 3 * d1 - 3 * d2 + d3, q = 3 * d0 - 6 * d1 + 3 * d2, r = -3 * d0 + 3 * d1;
                var bounds = new Gee.ArrayList<double?> ();
                bounds.add (0);
                bounds.add (1);
                double disc = 4 * q * q - 12 * pp * r;
                if (pp.abs () > 1e-12 && disc >= 0) {
                    double root = Math.sqrt (disc);
                    double t1 = (-2 * q - root) / (6 * pp), t2 = (-2 * q + root) / (6 * pp);
                    if (t1 > 0 && t1 < 1) bounds.add (t1);
                    if (t2 > 0 && t2 < 1) bounds.add (t2);
                } else if (q.abs () > 1e-12) {
                    double t = -r / (2 * q);
                    if (t > 0 && t < 1) bounds.add (t);
                }
                bounds.sort ((x, y) => x < y ? -1 : x > y ? 1 : 0);
                for (int n = 0; n + 1 < bounds.size; n++) {
                    double low = bounds[n], high = bounds[n + 1];
                    double dl = side (seg_point (start, actual, low), a, b), dh = side (seg_point (start, actual, high), a, b);
                    if (dl.abs () < 1e-10 && dh.abs () < 1e-10) continue;
                    if (dl * dh > 0) continue;
                    for (int step = 0; step < 48; step++) {
                        double mid = (low + high) / 2;
                        double dm = side (seg_point (start, actual, mid), a, b);
                        if (dl * dm <= 0) high = mid;
                        else {
                            low = mid;
                            dl = dm;
                        }
                    }
                    double t = (low + high) / 2;
                    var hit = seg_point (start, actual, t);
                    double u = ((hit.x - a.x) * (b.x - a.x) + (hit.y - a.y) * (b.y - a.y)) / (length * length);
                    if (u < 0 || u > 1) continue;
                    if (cuts.size > 0 && cuts[cuts.size - 1].segment == i && (cuts[cuts.size - 1].t - t).abs () < 1e-7) continue;
                    cuts.add (new PathHit (i, t, hit, u));
                }
                start = Point (actual.x, actual.y);
            }
            return cuts;
        }

        public static Gee.ArrayList<PathData> split (PathData path, Gee.Collection<PathHit> cuts, bool close_regions = false) {
            var list = contours (path);
            var result = new Gee.ArrayList<PathData> ();
            var untouched = new PathData ();
            int offset = 0;
            foreach (var contour in list) {
                bool closed = contour_closed (contour);
                var pieces = new Gee.ArrayList<PathData> ();
                var current = new PathData ();
                current.segs.add (contour.segs[0].copy ());
                var start = Point (contour.segs[0].x, contour.segs[0].y);
                var origin = start;
                bool changed = false;
                for (int i = 1; i < contour.segs.size; i++) {
                    var edge = contour.segs[i];
                    var actual = edge.kind == SegKind.CLOSE ? new PathSeg (SegKind.LINE, origin.x, origin.y) : edge;
                    var positions = new Gee.ArrayList<double?> ();
                    foreach (var cut in cuts) {
                        if (cut.segment != offset + i) continue;
                        if (!cut.t.is_finite () || cut.t < 0 || cut.t > 1) continue;
                        if (!closed && ((i == 1 && cut.t == 0) || (i == contour.segs.size - 1 && cut.t == 1))) continue;
                        positions.add (cut.t);
                    }
                    positions.sort ((x, y) => x < y ? -1 : x > y ? 1 : 0);
                    double prev = 0;
                    foreach (double pos in positions) {
                        if (pos > prev + 1e-8) current.segs.add (portion (start, actual, prev, pos));
                        else if (pos != 0 || current.segs.size <= 1) continue;
                        if (current.segs.size > 1) pieces.add (current);
                        current = new PathData ();
                        var hit = seg_point (start, actual, pos);
                        current.move_to (hit.x, hit.y);
                        prev = pos;
                        changed = true;
                    }
                    if (prev < 1 && (actual.kind == SegKind.CURVE || start.distance (Point (actual.x, actual.y)) > 1e-12)) current.segs.add (portion (start, actual, prev, 1));
                    start = Point (actual.x, actual.y);
                }
                if (!changed) {
                    untouched.append (contour);
                } else {
                    if (closed && pieces.size > 0) {
                        for (int i = 1; i < pieces[0].segs.size; i++) current.segs.add (pieces[0].segs[i].copy ());
                        pieces.remove_at (0);
                    }
                    if (current.segs.size > 1) pieces.add (current);
                    if (closed && close_regions) foreach (var piece in pieces) piece.close ();
                    result.add_all (pieces);
                }
                offset += contour.segs.size;
            }
            if (untouched.segs.size > 0) {
                if (result.size > 0) result[0].append (untouched);
                else result.add (untouched);
            }
            return result;
        }

        public static PathData join (PathData a, PathData b, double snap = 0.01) {
            var ca = contours (a);
            var cb = contours (b);
            if (ca.size != 1 || cb.size != 1 || contour_closed (ca[0]) || contour_closed (cb[0])) {
                var r = a.copy ();
                r.append (b);
                return r;
            }
            var first = ca[0];
            var second = cb[0];
            var a_end = Point (first.segs[first.segs.size - 1].x, first.segs[first.segs.size - 1].y);
            var a_start = Point (first.segs[0].x, first.segs[0].y);
            var b_start = Point (second.segs[0].x, second.segs[0].y);
            var b_end = Point (second.segs[second.segs.size - 1].x, second.segs[second.segs.size - 1].y);
            double d1 = a_end.distance (b_start), d2 = a_end.distance (b_end), d3 = a_start.distance (b_start), d4 = a_start.distance (b_end);
            double best = double.min (double.min (d1, d2), double.min (d3, d4));
            if (best == d2) second = reversed (second);
            else if (best == d3) first = reversed (first);
            else if (best == d4) {
                first = reversed (first);
                second = reversed (second);
            }
            var result = first.copy ();
            var start2 = Point (second.segs[0].x, second.segs[0].y);
            var end1 = Point (result.segs[result.segs.size - 1].x, result.segs[result.segs.size - 1].y);
            if (end1.distance (start2) > snap) result.line_to (start2.x, start2.y);
            for (int i = 1; i < second.segs.size; i++) result.segs.add (second.segs[i].copy ());
            return result;
        }

        public static double length (PathData path) {
            double total = 0;
            foreach (var e in edges (path)) total += e.length ();
            return total;
        }

        public static Gee.ArrayList<PathSample?> sample (PathData path, double step, bool include_closing = true) {
            var result = new Gee.ArrayList<PathSample?> ();
            double travelled = 0;
            step = double.max (step, 0.05);
            foreach (var e in edges (path, false)) {
                double len = e.length ();
                int n = int.max (1, (int) Math.ceil (len / step));
                for (int i = (result.size == 0 ? 0 : 1); i <= n; i++) {
                    double t = i / (double) n;
                    var d = e.tangent (t);
                    PathSample s = { e.at (t), Math.atan2 (d.y, d.x), travelled + len * t };
                    result.add (s);
                }
                travelled += len;
            }
            return result;
        }

        public static bool point_at (PathData path, double distance, out Point point, out double angle) {
            point = Point (0, 0);
            angle = 0;
            double travelled = 0;
            CurveEdge? last = null;
            foreach (var e in edges (path)) {
                double len = e.length ();
                if (travelled + len >= distance && len > 0) {
                    var bz = e.is_curve () ? Bezier (e.start, Point (e.segment.x1, e.segment.y1), Point (e.segment.x2, e.segment.y2), e.end ()) : Bezier.line (e.start, e.end ());
                    double t = bz.t_at_length (distance - travelled);
                    point = e.at (t);
                    var d = e.tangent (t);
                    angle = Math.atan2 (d.y, d.x);
                    return true;
                }
                travelled += len;
                last = e;
            }
            if (last != null) {
                point = last.end ();
                var d = last.tangent (1);
                angle = Math.atan2 (d.y, d.x);
            }
            return false;
        }

        public static double signed_area (PathData path) {
            double a = 0;
            foreach (var poly in path.flatten (0.2)) {
                var pts = poly.pts;
                for (int i = 0; i < pts.length; i++) {
                    var p = pts[i];
                    var q = pts[(i + 1) % pts.length];
                    a += p.x * q.y - q.x * p.y;
                }
            }
            return a / 2;
        }

        public static Rect tight_bounds (PathData path) {
            var box = Rect.empty ();
            bool first = true;
            foreach (var poly in path.flatten (0.1)) {
                foreach (var p in poly.pts) {
                    if (first) {
                        box = Rect (p.x, p.y, 0, 0);
                        first = false;
                    } else {
                        box = box.include (p.x, p.y);
                    }
                }
            }
            return box;
        }

        public static PathData insert_point (PathData path, int segment, double t) {
            var result = new PathData ();
            Point start = Point (0, 0), origin = start;
            for (int i = 0; i < path.segs.size; i++) {
                var s = path.segs[i];
                if (s.kind == SegKind.MOVE) {
                    origin = Point (s.x, s.y);
                    start = origin;
                    result.segs.add (s.copy ());
                    continue;
                }
                if (i == segment && s.kind != SegKind.CLOSE) {
                    result.segs.add (portion (start, s, 0, t));
                    result.segs.add (portion (start, s, t, 1));
                } else if (i == segment && s.kind == SegKind.CLOSE) {
                    var line = new PathSeg (SegKind.LINE, origin.x, origin.y);
                    var mid = seg_point (start, line, t);
                    result.line_to (mid.x, mid.y);
                    result.segs.add (s.copy ());
                } else {
                    result.segs.add (s.copy ());
                }
                if (s.kind != SegKind.CLOSE) start = Point (s.x, s.y);
            }
            return result;
        }

        public static PathData remove_anchor (PathData path, int index) {
            if (index < 0 || index >= path.segs.size) return path.copy ();
            var s = path.segs[index];
            if (s.kind == SegKind.CLOSE) return path.copy ();
            var result = new PathData ();
            if (s.kind == SegKind.MOVE) {
                for (int i = 0; i < path.segs.size; i++) {
                    if (i == index) continue;
                    if (i == index + 1 && path.segs[i].kind != SegKind.MOVE && path.segs[i].kind != SegKind.CLOSE) {
                        result.move_to (path.segs[i].x, path.segs[i].y);
                        continue;
                    }
                    result.segs.add (path.segs[i].copy ());
                }
                return cleanup (result);
            }
            for (int i = 0; i < path.segs.size; i++) {
                if (i == index) continue;
                var c = path.segs[i].copy ();
                if (i == index + 1 && c.kind == SegKind.CURVE && s.kind == SegKind.CURVE) {
                    c.x1 = s.x1;
                    c.y1 = s.y1;
                } else if (i == index + 1 && c.kind == SegKind.LINE && s.kind == SegKind.CURVE) {
                    c = new PathSeg (SegKind.CURVE, c.x, c.y);
                    c.x1 = s.x1;
                    c.y1 = s.y1;
                    c.x2 = path.segs[i].x;
                    c.y2 = path.segs[i].y;
                }
                result.segs.add (c);
            }
            return cleanup (result);
        }

        public static PathData cleanup (PathData path) {
            var result = new PathData ();
            foreach (var c in contours (path)) {
                int drawn = 0;
                foreach (var s in c.segs) if (s.kind == SegKind.LINE || s.kind == SegKind.CURVE) drawn++;
                if (drawn == 0) continue;
                result.append (c);
            }
            return result;
        }

        public static Gee.ArrayList<int> anchors (PathData path) {
            var list = new Gee.ArrayList<int> ();
            for (int i = 0; i < path.segs.size; i++) {
                var s = path.segs[i];
                if (s.kind == SegKind.CLOSE) continue;
                if (s.kind != SegKind.MOVE && i + 1 < path.segs.size && path.segs[i + 1].kind == SegKind.CLOSE) {
                    int m = i;
                    while (m > 0 && path.segs[m].kind != SegKind.MOVE) m--;
                    if (Point (s.x, s.y).distance (Point (path.segs[m].x, path.segs[m].y)) < 1e-6) continue;
                }
                list.add (i);
            }
            return list;
        }

        public static void prev_next (PathData path, int anchor, out int incoming, out int outgoing) {
            incoming = -1;
            outgoing = -1;
            if (anchor < 0 || anchor >= path.segs.size) return;
            if (path.segs[anchor].kind != SegKind.MOVE) incoming = anchor;
            if (anchor + 1 < path.segs.size && path.segs[anchor + 1].kind != SegKind.MOVE && path.segs[anchor + 1].kind != SegKind.CLOSE) outgoing = anchor + 1;
            int first = anchor;
            while (first > 0 && path.segs[first].kind != SegKind.MOVE) first--;
            int end = first + 1;
            while (end < path.segs.size && path.segs[end].kind != SegKind.MOVE && path.segs[end].kind != SegKind.CLOSE) end++;
            bool closed = end < path.segs.size && path.segs[end].kind == SegKind.CLOSE;
            if (!closed) return;
            int last = end - 1;
            bool coincident = Point (path.segs[first].x, path.segs[first].y).distance (Point (path.segs[last].x, path.segs[last].y)) < 1e-6;
            if (anchor == first) incoming = coincident ? last : end;
            if (anchor == last && coincident) outgoing = first + 1 < end ? first + 1 : -1;
            if (anchor == last && !coincident) outgoing = end;
        }

        public static PathData from_beziers (Gee.List<Bezier?> curves, bool closed) {
            var p = new PathData ();
            if (curves.size == 0) return p;
            p.move_to (curves[0].p0.x, curves[0].p0.y);
            foreach (var c in curves) p.curve_to (c.p1.x, c.p1.y, c.p2.x, c.p2.y, c.p3.x, c.p3.y);
            if (closed) p.close ();
            return p;
        }

        public static PathData polygon_path (Point[] pts, bool closed) {
            var p = new PathData ();
            if (pts.length == 0) return p;
            p.move_to (pts[0].x, pts[0].y);
            for (int i = 1; i < pts.length; i++) p.line_to (pts[i].x, pts[i].y);
            if (closed) p.close ();
            return p;
        }

        public static void arc (PathData path, Point center, Point from, Point to, double angle) {
            double radius = center.distance (from);
            int count = (int) Math.ceil (angle.abs () / (Math.PI / 2));
            if (count == 0 || radius < 1e-10) {
                path.line_to (to.x, to.y);
                return;
            }
            double start = Math.atan2 (from.y - center.y, from.x - center.x);
            for (int i = 0; i < count; i++) {
                double a = start + angle * i / count, b = start + angle * (i + 1) / count;
                double k = 4.0 / 3 * Math.tan ((b - a) / 4);
                var first = Point (center.x + radius * Math.cos (a), center.y + radius * Math.sin (a));
                var last = i + 1 == count ? to : Point (center.x + radius * Math.cos (b), center.y + radius * Math.sin (b));
                path.curve_to (first.x - radius * Math.sin (a) * k, first.y + radius * Math.cos (a) * k,
                    last.x + radius * Math.sin (b) * k, last.y - radius * Math.cos (b) * k, last.x, last.y);
            }
        }

        public static PathData map_points (PathData source, owned MapFunc f, double tolerance = 0.25) {
            var result = new PathData ();
            foreach (var contour in contours (source)) {
                bool closed = contour_closed (contour);
                var curves = new Gee.ArrayList<Bezier?> ();
                Point start = Point (contour.segs[0].x, contour.segs[0].y);
                var origin = start;
                for (int i = 1; i < contour.segs.size; i++) {
                    var s = contour.segs[i];
                    if (s.kind == SegKind.CLOSE) {
                        if (start.distance (origin) < 1e-9) continue;
                        s = new PathSeg (SegKind.LINE, origin.x, origin.y);
                    }
                    var bz = s.kind == SegKind.CURVE ? Bezier (start, Point (s.x1, s.y1), Point (s.x2, s.y2), Point (s.x, s.y)) : Bezier.line (start, Point (s.x, s.y));
                    double len = bz.length (0.5);
                    int n = (int) Math.ceil (len / 6.0).clamp (1, 64);
                    Point[] pts = {};
                    for (int k = 0; k <= n; k++) pts += f (bz.at (k / (double) n));
                    var fitted = CurveFit.fit (pts, tolerance);
                    curves.add_all (fitted);
                    start = Point (s.x, s.y);
                }
                result.append (from_beziers (curves, closed));
            }
            return result;
        }
    }

    public delegate Point MapFunc (Point p);
}
