namespace Singularity.Vector {

    public enum JoinKind { MITER, ROUND, BEVEL }
    public enum CapKind { BUTT, ROUND, SQUARE }
    public enum StrokeAlign { CENTER, INSIDE, OUTSIDE }

    public class WidthPoint {
        public double t;
        public double left;
        public double right;

        public WidthPoint (double t, double left, double right) {
            this.t = t;
            this.left = left;
            this.right = right;
        }

        public WidthPoint copy () {
            return new WidthPoint (t, left, right);
        }
    }

    public class CurveOffset {
        private static Point unit (Point p) {
            double l = Math.hypot (p.x, p.y);
            if (l < 1e-12 || !l.is_finite ()) return Point (1, 0);
            return Point (p.x / l, p.y / l);
        }

        private static Point normal_point (CurveEdge e, double t, double d) {
            var p = e.at (t);
            var u = unit (e.tangent (t));
            return Point (p.x - u.y * d, p.y + u.x * d);
        }

        private static Point normal_derivative (CurveEdge e, double t, double d) {
            var first = e.tangent (t);
            if (!e.is_curve ()) return first;
            var second = e.second (t);
            double len = Math.hypot (first.x, first.y);
            if (len < 1e-9) return first;
            double cross = first.x * second.y - first.y * second.x;
            double k = cross / (len * len * len);
            return Point (first.x * (1 - d * k), first.y * (1 - d * k));
        }

        private static void fit (PathData path, CurveEdge e, double d, double a, double b, int depth) {
            var start = normal_point (e, a, d);
            var end = normal_point (e, b, d);
            if (!e.is_curve ()) {
                path.line_to (end.x, end.y);
                return;
            }
            var first = normal_derivative (e, a, d);
            var last = normal_derivative (e, b, d);
            double step = (b - a) / 3;
            var seg = new PathSeg (SegKind.CURVE, end.x, end.y);
            seg.x1 = start.x + first.x * step;
            seg.y1 = start.y + first.y * step;
            seg.x2 = end.x - last.x * step;
            seg.y2 = end.y - last.y * step;
            double worst = 0;
            for (int i = 1; i < 12; i++) {
                double t = i / 12.0;
                worst = double.max (worst, PathOps.seg_point (start, seg, t).distance (normal_point (e, a + (b - a) * t, d)));
            }
            if (worst > 0.02 && depth < 12) {
                double mid = (a + b) / 2;
                fit (path, e, d, a, mid, depth + 1);
                fit (path, e, d, mid, b, depth + 1);
            } else {
                path.segs.add (seg);
            }
        }

        private static void join (PathData path, CurveEdge prev, CurveEdge next, double d, JoinKind kind, double limit) {
            var a = normal_point (prev, 1, d);
            var b = normal_point (next, 0, d);
            if (a.distance (b) < 1e-8) return;
            var inc = unit (prev.tangent (1));
            var out_dir = unit (next.tangent (0));
            double cross = inc.x * out_dir.y - inc.y * out_dir.x;
            double dot = inc.x * out_dir.x + inc.y * out_dir.y;
            bool outer = cross * d < 0;
            if (!outer) {
                path.line_to (next.start.x, next.start.y);
                path.line_to (b.x, b.y);
                return;
            }
            if (kind == JoinKind.ROUND) {
                PathOps.arc (path, next.start, a, b, Math.atan2 (cross, dot));
                return;
            }
            if (kind == JoinKind.MITER && cross.abs () > 1e-10) {
                double dist = ((b.x - a.x) * out_dir.y - (b.y - a.y) * out_dir.x) / cross;
                var corner = Point (a.x + inc.x * dist, a.y + inc.y * dist);
                if (corner.distance (next.start) <= d.abs () * limit) path.line_to (corner.x, corner.y);
            }
            path.line_to (b.x, b.y);
        }

        private static PathData side (Gee.List<CurveEdge> segs, bool closed, double d, JoinKind kind, double limit) {
            var path = new PathData ();
            if (segs.size == 0) return path;
            var start = normal_point (segs[0], 0, d);
            path.move_to (start.x, start.y);
            for (int i = 0; i < segs.size; i++) {
                if (i > 0) join (path, segs[i - 1], segs[i], d, kind, limit);
                fit (path, segs[i], d, 0, 1, 0);
            }
            if (closed) {
                join (path, segs[segs.size - 1], segs[0], d, kind, limit);
                path.close ();
            }
            return path;
        }

        private static Gee.ArrayList<CurveEdge> contour_edges (PathData contour) {
            var result = new Gee.ArrayList<CurveEdge> ();
            var move = contour.segs[0];
            var start = Point (move.x, move.y);
            for (int i = 1; i < contour.segs.size; i++) {
                var s = contour.segs[i];
                if (s.kind == SegKind.CLOSE) s = new PathSeg (SegKind.LINE, move.x, move.y);
                var e = new CurveEdge (start, s);
                if (s.kind == SegKind.CURVE || start.distance (e.end ()) > 1e-10) result.add (e);
                start = e.end ();
            }
            return result;
        }

        public static PathData offset (PathData source, double amount, JoinKind kind = JoinKind.MITER, double limit = 4) {
            if (amount.abs () < 1e-9) return source.copy ();
            if (PathOps.all_closed (source)) {
                var band = stroke (source, amount.abs () * 2, kind, CapKind.BUTT, limit);
                return CurveBoolean.apply (source, band, amount > 0 ? BoolOp.UNION : BoolOp.SUBTRACT);
            }
            var result = new PathData ();
            var all = PathOps.edges (source, true);
            foreach (var contour in PathOps.contours (source)) {
                var segs = contour_edges (contour);
                if (segs.size == 0) continue;
                bool closed = PathOps.contour_closed (contour);
                double d = amount;
                if (closed) {
                    var mid = segs[0].at (0.5);
                    var dir = unit (segs[0].tangent (0.5));
                    bool left_in = PathOps.winding (all, Point (mid.x - dir.y * 0.01, mid.y + dir.x * 0.01)) != 0;
                    d = left_in ? -amount : amount;
                }
                result.append (side (segs, closed, d, kind, limit));
            }
            if (PathOps.all_closed (source)) {
                var cleaned = clean (result);
                if (!cleaned.is_empty ()) return cleaned;
            }
            return result;
        }

        public static PathData clean (PathData path) {
            var list = new Gee.ArrayList<PathData> ();
            list.add (path);
            var arr = new Arrangement (list);
            return arr.region ((s) => s[0]);
        }

        private static void cap (PathData path, Point center, Point from, Point to, Point tangent, double radius, CapKind kind) {
            if (kind == CapKind.ROUND) {
                PathOps.arc (path, center, from, to, -Math.PI);
            } else if (kind == CapKind.SQUARE) {
                path.line_to (from.x + tangent.x * radius, from.y + tangent.y * radius);
                path.line_to (to.x + tangent.x * radius, to.y + tangent.y * radius);
                path.line_to (to.x, to.y);
            } else {
                path.line_to (to.x, to.y);
            }
        }

        public static PathData stroke (PathData source, double width, JoinKind kind = JoinKind.MITER, CapKind ends = CapKind.BUTT, double limit = 4, StrokeAlign align = StrokeAlign.CENTER) {
            var result = new PathData ();
            if (width <= 0) return result;
            double w = align == StrokeAlign.CENTER ? width : width * 2;
            double r = w / 2;
            foreach (var contour in PathOps.contours (source)) {
                var segs = contour_edges (contour);
                if (segs.size == 0) {
                    if (ends == CapKind.ROUND && contour.segs.size > 0) result.append (new PathData.ellipse (contour.segs[0].x, contour.segs[0].y, r, r));
                    continue;
                }
                bool closed = PathOps.contour_closed (contour);
                var right = side (segs, closed, r, kind, limit);
                var left = PathOps.reversed (side (segs, closed, -r, kind, limit));
                if (closed) {
                    result.append (right);
                    result.append (left);
                    continue;
                }
                var first = segs[0];
                var last = segs[segs.size - 1];
                cap (right, last.end (), normal_point (last, 1, r), normal_point (last, 1, -r), unit (last.tangent (1)), r, ends);
                for (int i = 1; i < left.segs.size; i++) {
                    if (left.segs[i].kind == SegKind.CLOSE) continue;
                    right.segs.add (left.segs[i].copy ());
                }
                var t = unit (first.tangent (0));
                cap (right, first.start, normal_point (first, 0, -r), normal_point (first, 0, r), Point (-t.x, -t.y), r, ends);
                right.close ();
                result.append (right);
            }
            var outline = clean (result);
            if (outline.is_empty ()) outline = result;
            if (align == StrokeAlign.INSIDE && PathOps.all_closed (source)) return CurveBoolean.apply (outline, source, BoolOp.INTERSECT);
            if (align == StrokeAlign.OUTSIDE && PathOps.all_closed (source)) return CurveBoolean.apply (outline, source, BoolOp.SUBTRACT);
            return outline;
        }

        public static PathData dash (PathData source, double[] pattern, double phase = 0) {
            double total = 0;
            foreach (double v in pattern) total += v;
            if (pattern.length == 0 || total <= 0) return source.copy ();
            var result = new PathData ();
            foreach (var contour in PathOps.contours (source)) {
                double len = PathOps.length (contour);
                double pos = -(phase % total);
                int idx = 0;
                while (pos < len) {
                    double seg_len = pattern[idx % pattern.length];
                    bool on = idx % 2 == 0;
                    double a = double.max (pos, 0), b = double.min (pos + seg_len, len);
                    if (on && b > a) result.append (sub_path (contour, a, b));
                    pos += seg_len;
                    idx++;
                    if (idx > 100000) break;
                }
            }
            return result;
        }

        public static PathData sub_path (PathData contour, double from, double to) {
            var result = new PathData ();
            double travelled = 0;
            bool started = false;
            foreach (var e in PathOps.edges (contour)) {
                double len = e.length ();
                double s = travelled, f = travelled + len;
                travelled = f;
                if (f <= from || s >= to || len <= 0) continue;
                var bz = e.is_curve () ? Bezier (e.start, Point (e.segment.x1, e.segment.y1), Point (e.segment.x2, e.segment.y2), e.end ()) : Bezier.line (e.start, e.end ());
                double ta = from > s ? bz.t_at_length (from - s) : 0;
                double tb = to < f ? bz.t_at_length (to - s) : 1;
                if (!started) {
                    var p = e.at (ta);
                    result.move_to (p.x, p.y);
                    started = true;
                }
                result.segs.add (PathOps.portion (e.start, e.segment, ta, tb));
            }
            return result;
        }

        public static double profile_at (Gee.List<WidthPoint> profile, double t, bool left) {
            if (profile.size == 0) return 1;
            if (t <= profile[0].t) return left ? profile[0].left : profile[0].right;
            for (int i = 0; i + 1 < profile.size; i++) {
                var a = profile[i];
                var b = profile[i + 1];
                if (t >= a.t && t <= b.t) {
                    double u = b.t - a.t < 1e-9 ? 0 : (t - a.t) / (b.t - a.t);
                    u = u * u * (3 - 2 * u);
                    double va = left ? a.left : a.right, vb = left ? b.left : b.right;
                    return va + (vb - va) * u;
                }
            }
            var last = profile[profile.size - 1];
            return left ? last.left : last.right;
        }

        public static PathData variable (PathData source, double width, Gee.List<WidthPoint> profile, CapKind ends = CapKind.ROUND) {
            var result = new PathData ();
            foreach (var contour in PathOps.contours (source)) {
                double len = PathOps.length (contour);
                if (len <= 0) continue;
                bool closed = PathOps.contour_closed (contour);
                var samples = PathOps.sample (contour, double.max (len / 400, 0.5));
                Point[] lefts = {};
                Point[] rights = {};
                foreach (var s in samples) {
                    double t = s.distance / len;
                    double wl = width / 2 * profile_at (profile, t, true);
                    double wr = width / 2 * profile_at (profile, t, false);
                    double nx = -Math.sin (s.angle), ny = Math.cos (s.angle);
                    lefts += Point (s.point.x - nx * wl, s.point.y - ny * wl);
                    rights += Point (s.point.x + nx * wr, s.point.y + ny * wr);
                }
                var left_curves = CurveFit.fit (lefts, 0.15);
                var right_curves = CurveFit.fit (rights, 0.15);
                if (closed) {
                    result.append (PathOps.from_beziers (left_curves, true));
                    result.append (PathOps.reversed (PathOps.from_beziers (right_curves, true)));
                    continue;
                }
                var p = PathOps.from_beziers (left_curves, false);
                var r = PathOps.reversed (PathOps.from_beziers (right_curves, false));
                var last = samples[samples.size - 1];
                var first = samples[0];
                var end_center = last.point;
                var rs = r.segs[0];
                if (ends == CapKind.ROUND) PathOps.arc (p, end_center, lefts[lefts.length - 1], Point (rs.x, rs.y), Math.PI);
                else p.line_to (rs.x, rs.y);
                for (int i = 1; i < r.segs.size; i++) p.segs.add (r.segs[i].copy ());
                if (ends == CapKind.ROUND) PathOps.arc (p, first.point, rights[0], lefts[0], Math.PI);
                p.close ();
                result.append (p);
            }
            var cleaned = clean (result);
            return cleaned.is_empty () ? result : cleaned;
        }
    }
}
