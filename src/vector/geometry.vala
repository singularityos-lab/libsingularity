namespace Singularity.Vector {

    public struct Point {
        public double x;
        public double y;

        public Point (double x, double y) {
            this.x = x;
            this.y = y;
        }

        public double distance (Point o) {
            return Math.hypot (o.x - x, o.y - y);
        }
    }

    public struct Rect {
        public double x;
        public double y;
        public double w;
        public double h;

        public Rect (double x, double y, double w, double h) {
            this.x = x;
            this.y = y;
            this.w = w;
            this.h = h;
        }

        public Rect.empty () {
            x = double.INFINITY;
            y = double.INFINITY;
            w = -double.INFINITY;
            h = -double.INFINITY;
        }

        public bool is_empty () {
            return !(w >= 0 && h >= 0) || x.is_infinity () != 0;
        }

        public double x2 () {
            return x + w;
        }

        public double y2 () {
            return y + h;
        }

        public double cx () {
            return x + w / 2;
        }

        public double cy () {
            return y + h / 2;
        }

        public Rect union (Rect o) {
            if (is_empty ()) return o;
            if (o.is_empty ()) return this;
            double nx = double.min (x, o.x), ny = double.min (y, o.y);
            return Rect (nx, ny, double.max (x2 (), o.x2 ()) - nx, double.max (y2 (), o.y2 ()) - ny);
        }

        public Rect include (double px, double py) {
            if (is_empty ()) return Rect (px, py, 0, 0);
            double nx = double.min (x, px), ny = double.min (y, py);
            return Rect (nx, ny, double.max (x2 (), px) - nx, double.max (y2 (), py) - ny);
        }

        public Rect inflate (double d) {
            return Rect (x - d, y - d, w + 2 * d, h + 2 * d);
        }

        public bool contains (double px, double py) {
            return px >= x && px <= x + w && py >= y && py <= y + h;
        }

        public bool contains_rect (Rect o) {
            return o.x >= x && o.y >= y && o.x2 () <= x2 () && o.y2 () <= y2 ();
        }

        public bool intersects (Rect o) {
            return !(o.x > x2 () || o.x2 () < x || o.y > y2 () || o.y2 () < y);
        }

        public static Rect from_points (double x1, double y1, double x2, double y2) {
            return Rect (double.min (x1, x2), double.min (y1, y2), (x1 - x2).abs (), (y1 - y2).abs ());
        }
    }

    public enum SegKind {
        MOVE,
        LINE,
        CURVE,
        CLOSE
    }

    public class PathSeg {
        public SegKind kind;
        public double x1;
        public double y1;
        public double x2;
        public double y2;
        public double x;
        public double y;

        public PathSeg (SegKind kind, double x = 0, double y = 0) {
            this.kind = kind;
            this.x = x;
            this.y = y;
        }

        public PathSeg copy () {
            var s = new PathSeg (kind, x, y);
            s.x1 = x1;
            s.y1 = y1;
            s.x2 = x2;
            s.y2 = y2;
            return s;
        }
    }

    public class Polygon {
        public Point[] pts = {};
        public bool closed = true;

        public void add (double x, double y) {
            int n = pts.length;
            if (n > 0 && (pts[n - 1].x - x).abs () < 1e-9 && (pts[n - 1].y - y).abs () < 1e-9) return;
            Point[] a = (owned) pts;
            a += Point (x, y);
            pts = (owned) a;
        }

        public void drop_last () {
            Point[] a = (owned) pts;
            a.resize (a.length - 1);
            pts = (owned) a;
        }

        public double area () {
            double a = 0;
            for (int i = 0; i < pts.length; i++) {
                var p = pts[i];
                var q = pts[(i + 1) % pts.length];
                a += p.x * q.y - q.x * p.y;
            }
            return a / 2;
        }

        public double length () {
            double l = 0;
            for (int i = 1; i < pts.length; i++) l += pts[i - 1].distance (pts[i]);
            if (closed && pts.length > 1) l += pts[pts.length - 1].distance (pts[0]);
            return l;
        }
    }

    public class PathData {
        public Gee.ArrayList<PathSeg> segs = new Gee.ArrayList<PathSeg> ();

        public const double KAPPA = 0.5522847498;

        public PathData copy () {
            var p = new PathData ();
            foreach (var s in segs) p.segs.add (s.copy ());
            return p;
        }

        public bool is_empty () {
            return segs.size == 0;
        }

        public void move_to (double x, double y) {
            segs.add (new PathSeg (SegKind.MOVE, x, y));
        }

        public void line_to (double x, double y) {
            segs.add (new PathSeg (SegKind.LINE, x, y));
        }

        public void curve_to (double x1, double y1, double x2, double y2, double x, double y) {
            var s = new PathSeg (SegKind.CURVE, x, y);
            s.x1 = x1;
            s.y1 = y1;
            s.x2 = x2;
            s.y2 = y2;
            segs.add (s);
        }

        public void close () {
            segs.add (new PathSeg (SegKind.CLOSE));
        }

        public void append (PathData other) {
            foreach (var s in other.segs) segs.add (s.copy ());
        }

        public PathData.rect (double x, double y, double w, double h) {
            move_to (x, y);
            line_to (x + w, y);
            line_to (x + w, y + h);
            line_to (x, y + h);
            close ();
        }

        public PathData.round_rect (double x, double y, double w, double h, double r) {
            add_round_rect (x, y, w, h, r);
        }

        public void add_round_rect (double x, double y, double w, double h, double r) {
            r = double.min (r, double.min (w, h) / 2);
            if (r <= 0.01) {
                move_to (x, y);
                line_to (x + w, y);
                line_to (x + w, y + h);
                line_to (x, y + h);
                close ();
                return;
            }
            double k = r * (1 - KAPPA);
            move_to (x + r, y);
            line_to (x + w - r, y);
            curve_to (x + w - k, y, x + w, y + k, x + w, y + r);
            line_to (x + w, y + h - r);
            curve_to (x + w, y + h - k, x + w - k, y + h, x + w - r, y + h);
            line_to (x + r, y + h);
            curve_to (x + k, y + h, x, y + h - k, x, y + h - r);
            line_to (x, y + r);
            curve_to (x, y + k, x + k, y, x + r, y);
            close ();
        }

        public PathData.ellipse (double cx, double cy, double rx, double ry) {
            add_ellipse (cx, cy, rx, ry);
        }

        public void add_ellipse (double cx, double cy, double rx, double ry) {
            double kx = rx * KAPPA, ky = ry * KAPPA;
            move_to (cx + rx, cy);
            curve_to (cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry);
            curve_to (cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy);
            curve_to (cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry);
            curve_to (cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy);
            close ();
        }

        public void add_polygon (Point[] pts, bool closed = true) {
            if (pts.length == 0) return;
            move_to (pts[0].x, pts[0].y);
            for (int i = 1; i < pts.length; i++) line_to (pts[i].x, pts[i].y);
            if (closed) close ();
        }

        public void arc_to (double cx, double cy, double rx, double ry, double a1, double a2, bool connect = true) {
            double span = a2 - a1;
            int n = (int) Math.ceil (span.abs () / (Math.PI / 2) - 1e-9);
            if (n < 1) n = 1;
            double step = span / n;
            double sx = cx + rx * Math.cos (a1), sy = cy + ry * Math.sin (a1);
            if (connect && segs.size > 0) line_to (sx, sy);
            else move_to (sx, sy);
            double t = 4.0 / 3.0 * Math.tan (step / 4);
            for (int i = 0; i < n; i++) {
                double b1 = a1 + i * step, b2 = b1 + step;
                double c1 = Math.cos (b1), s1 = Math.sin (b1), c2 = Math.cos (b2), s2 = Math.sin (b2);
                curve_to (cx + rx * (c1 - t * s1), cy + ry * (s1 + t * c1),
                          cx + rx * (c2 + t * s2), cy + ry * (s2 - t * c2),
                          cx + rx * c2, cy + ry * s2);
            }
        }

        public void transform (Cairo.Matrix m) {
            foreach (var s in segs) {
                if (s.kind == SegKind.CLOSE) continue;
                m.transform_point (ref s.x, ref s.y);
                if (s.kind == SegKind.CURVE) {
                    m.transform_point (ref s.x1, ref s.y1);
                    m.transform_point (ref s.x2, ref s.y2);
                }
            }
        }

        public PathData transformed (Cairo.Matrix m) {
            var p = copy ();
            p.transform (m);
            return p;
        }

        public void scale (double sx, double sy) {
            var m = Cairo.Matrix (sx, 0, 0, sy, 0, 0);
            transform (m);
        }

        public void translate (double dx, double dy) {
            var m = Cairo.Matrix (1, 0, 0, 1, dx, dy);
            transform (m);
        }

        public Rect control_bounds () {
            var r = Rect.empty ();
            foreach (var s in segs) {
                if (s.kind == SegKind.CLOSE) continue;
                r = r.include (s.x, s.y);
                if (s.kind == SegKind.CURVE) {
                    r = r.include (s.x1, s.y1);
                    r = r.include (s.x2, s.y2);
                }
            }
            return r;
        }

        public Rect bounds () {
            var r = Rect.empty ();
            foreach (var poly in flatten (0.25)) {
                foreach (var p in poly.pts) r = r.include (p.x, p.y);
            }
            return r;
        }

        public void to_cairo (Cairo.Context cr) {
            foreach (var s in segs) {
                switch (s.kind) {
                    case SegKind.MOVE: cr.move_to (s.x, s.y); break;
                    case SegKind.LINE: cr.line_to (s.x, s.y); break;
                    case SegKind.CURVE: cr.curve_to (s.x1, s.y1, s.x2, s.y2, s.x, s.y); break;
                    case SegKind.CLOSE: cr.close_path (); break;
                }
            }
        }

        public bool has_closed_subpath () {
            foreach (var s in segs) if (s.kind == SegKind.CLOSE) return true;
            return false;
        }

        public Gee.ArrayList<Polygon> flatten (double tolerance = 0.5) {
            var list = new Gee.ArrayList<Polygon> ();
            Polygon? cur = null;
            double cx = 0, cy = 0, sx = 0, sy = 0;
            foreach (var s in segs) {
                switch (s.kind) {
                    case SegKind.MOVE:
                        cur = new Polygon ();
                        cur.closed = false;
                        list.add (cur);
                        cur.add (s.x, s.y);
                        cx = sx = s.x;
                        cy = sy = s.y;
                        break;
                    case SegKind.LINE:
                        if (cur == null) {
                            cur = new Polygon ();
                            cur.closed = false;
                            list.add (cur);
                            cur.add (cx, cy);
                        }
                        cur.add (s.x, s.y);
                        cx = s.x;
                        cy = s.y;
                        break;
                    case SegKind.CURVE:
                        if (cur == null) {
                            cur = new Polygon ();
                            cur.closed = false;
                            list.add (cur);
                            cur.add (cx, cy);
                        }
                        double len = Math.hypot (s.x1 - cx, s.y1 - cy) + Math.hypot (s.x2 - s.x1, s.y2 - s.y1) + Math.hypot (s.x - s.x2, s.y - s.y2);
                        int n = (int) Math.ceil (Math.sqrt (len / double.max (tolerance, 0.01)) * 1.5);
                        n = n.clamp (2, 200);
                        for (int i = 1; i <= n; i++) {
                            double t = (double) i / n;
                            Point p = bezier_point (cx, cy, s.x1, s.y1, s.x2, s.y2, s.x, s.y, t);
                            cur.add (p.x, p.y);
                        }
                        cx = s.x;
                        cy = s.y;
                        break;
                    case SegKind.CLOSE:
                        if (cur != null) {
                            cur.closed = true;
                            int last = cur.pts.length - 1;
                            if (last > 0 && (cur.pts[last].x - cur.pts[0].x).abs () < 1e-9 && (cur.pts[last].y - cur.pts[0].y).abs () < 1e-9) cur.drop_last ();
                        }
                        cx = sx;
                        cy = sy;
                        cur = null;
                        break;
                }
            }
            var result = new Gee.ArrayList<Polygon> ();
            foreach (var p in list) if (p.pts.length > 0) result.add (p);
            return result;
        }

        public static Point bezier_point (double x0, double y0, double x1, double y1, double x2, double y2, double x3, double y3, double t) {
            double u = 1 - t;
            double a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
            return Point (a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3);
        }

        public bool contains (double px, double py, bool even_odd = false) {
            int winding = 0;
            int crossings = 0;
            foreach (var poly in flatten (0.5)) {
                int n = poly.pts.length;
                if (n < 3) continue;
                for (int i = 0; i < n; i++) {
                    var a = poly.pts[i];
                    var b = poly.pts[(i + 1) % n];
                    if (a.y <= py) {
                        if (b.y > py && cross (a, b, px, py) > 0) {
                            winding++;
                            crossings++;
                        }
                    } else if (b.y <= py && cross (a, b, px, py) < 0) {
                        winding--;
                        crossings++;
                    }
                }
            }
            return even_odd ? (crossings % 2) == 1 : winding != 0;
        }

        private static double cross (Point a, Point b, double px, double py) {
            return (b.x - a.x) * (py - a.y) - (px - a.x) * (b.y - a.y);
        }

        public double distance_to (double px, double py) {
            double best = double.INFINITY;
            foreach (var poly in flatten (0.5)) {
                int n = poly.pts.length;
                if (n == 1) best = double.min (best, Math.hypot (poly.pts[0].x - px, poly.pts[0].y - py));
                int limit = poly.closed ? n : n - 1;
                for (int i = 0; i < limit; i++) {
                    best = double.min (best, segment_distance (poly.pts[i], poly.pts[(i + 1) % n], px, py));
                }
            }
            return best;
        }

        public static double segment_distance (Point a, Point b, double px, double py) {
            double dx = b.x - a.x, dy = b.y - a.y;
            double l2 = dx * dx + dy * dy;
            double t = l2 > 0 ? ((px - a.x) * dx + (py - a.y) * dy) / l2 : 0;
            t = t.clamp (0, 1);
            return Math.hypot (a.x + t * dx - px, a.y + t * dy - py);
        }

        public string to_svg (int decimals = 2) {
            var sb = new StringBuilder ();
            foreach (var s in segs) {
                if (sb.len > 0) sb.append_c (' ');
                switch (s.kind) {
                    case SegKind.MOVE: sb.append ("M%s %s".printf (fmt (s.x, decimals), fmt (s.y, decimals))); break;
                    case SegKind.LINE: sb.append ("L%s %s".printf (fmt (s.x, decimals), fmt (s.y, decimals))); break;
                    case SegKind.CURVE:
                        sb.append ("C%s %s %s %s %s %s".printf (fmt (s.x1, decimals), fmt (s.y1, decimals), fmt (s.x2, decimals),
                            fmt (s.y2, decimals), fmt (s.x, decimals), fmt (s.y, decimals)));
                        break;
                    case SegKind.CLOSE: sb.append ("Z"); break;
                }
            }
            return sb.str;
        }

        public static string fmt (double v, int decimals = 2) {
            if (v.is_nan () || v.is_infinity () != 0) v = 0;
            double m = Math.pow (10, decimals);
            double r = Math.round (v * m) / m;
            if (r == 0) r = 0;
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            string s = r.format (buf, "%." + decimals.to_string () + "f");
            if (s.contains (".")) {
                while (s.has_suffix ("0")) s = s.substring (0, s.length - 1);
                if (s.has_suffix (".")) s = s.substring (0, s.length - 1);
            }
            if (s == "-0") s = "0";
            return s;
        }

        public static PathData parse_svg (string d) {
            var p = new PathData ();
            var sc = new PathScanner (d);
            char cmd = 0;
            double cx = 0, cy = 0, sx = 0, sy = 0;
            double lcx = 0, lcy = 0;
            double lqx = 0, lqy = 0;
            char prev = 0;
            while (true) {
                sc.skip_ws ();
                if (sc.at_end ()) break;
                char c = sc.peek ();
                if (c.isalpha ()) {
                    cmd = c;
                    sc.pos++;
                } else if (cmd == 0) {
                    break;
                }
                bool rel = cmd.islower ();
                char up = cmd.toupper ();
                double ox = rel ? cx : 0, oy = rel ? cy : 0;
                bool ok = true;
                switch (up) {
                    case 'M': {
                        double x = 0, y = 0;
                        if (!sc.number (out x) || !sc.number (out y)) { ok = false; break; }
                        cx = ox + x;
                        cy = oy + y;
                        sx = cx;
                        sy = cy;
                        p.move_to (cx, cy);
                        cmd = rel ? 'l' : 'L';
                        break;
                    }
                    case 'L': {
                        double x = 0, y = 0;
                        if (!sc.number (out x) || !sc.number (out y)) { ok = false; break; }
                        cx = ox + x;
                        cy = oy + y;
                        p.line_to (cx, cy);
                        break;
                    }
                    case 'H': {
                        double x = 0;
                        if (!sc.number (out x)) { ok = false; break; }
                        cx = (rel ? cx : 0) + x;
                        p.line_to (cx, cy);
                        break;
                    }
                    case 'V': {
                        double y = 0;
                        if (!sc.number (out y)) { ok = false; break; }
                        cy = (rel ? cy : 0) + y;
                        p.line_to (cx, cy);
                        break;
                    }
                    case 'C': {
                        double x1 = 0, y1 = 0, x2 = 0, y2 = 0, x = 0, y = 0;
                        if (!sc.number (out x1) || !sc.number (out y1) || !sc.number (out x2) || !sc.number (out y2) || !sc.number (out x) || !sc.number (out y)) { ok = false; break; }
                        p.curve_to (ox + x1, oy + y1, ox + x2, oy + y2, ox + x, oy + y);
                        lcx = ox + x2;
                        lcy = oy + y2;
                        cx = ox + x;
                        cy = oy + y;
                        break;
                    }
                    case 'S': {
                        double x2 = 0, y2 = 0, x = 0, y = 0;
                        if (!sc.number (out x2) || !sc.number (out y2) || !sc.number (out x) || !sc.number (out y)) { ok = false; break; }
                        double x1 = cx, y1 = cy;
                        if (prev.toupper () == 'C' || prev.toupper () == 'S') {
                            x1 = 2 * cx - lcx;
                            y1 = 2 * cy - lcy;
                        }
                        p.curve_to (x1, y1, ox + x2, oy + y2, ox + x, oy + y);
                        lcx = ox + x2;
                        lcy = oy + y2;
                        cx = ox + x;
                        cy = oy + y;
                        break;
                    }
                    case 'Q': {
                        double qx = 0, qy = 0, x = 0, y = 0;
                        if (!sc.number (out qx) || !sc.number (out qy) || !sc.number (out x) || !sc.number (out y)) { ok = false; break; }
                        qx += ox;
                        qy += oy;
                        x += ox;
                        y += oy;
                        p.curve_to (cx + 2.0 / 3 * (qx - cx), cy + 2.0 / 3 * (qy - cy), x + 2.0 / 3 * (qx - x), y + 2.0 / 3 * (qy - y), x, y);
                        lqx = qx;
                        lqy = qy;
                        cx = x;
                        cy = y;
                        break;
                    }
                    case 'T': {
                        double x = 0, y = 0;
                        if (!sc.number (out x) || !sc.number (out y)) { ok = false; break; }
                        x += ox;
                        y += oy;
                        double qx = cx, qy = cy;
                        if (prev.toupper () == 'Q' || prev.toupper () == 'T') {
                            qx = 2 * cx - lqx;
                            qy = 2 * cy - lqy;
                        }
                        p.curve_to (cx + 2.0 / 3 * (qx - cx), cy + 2.0 / 3 * (qy - cy), x + 2.0 / 3 * (qx - x), y + 2.0 / 3 * (qy - y), x, y);
                        lqx = qx;
                        lqy = qy;
                        cx = x;
                        cy = y;
                        break;
                    }
                    case 'A': {
                        double rx = 0, ry = 0, rot = 0, large = 0, sweep = 0, x = 0, y = 0;
                        if (!sc.number (out rx) || !sc.number (out ry) || !sc.number (out rot) || !sc.flag (out large) || !sc.flag (out sweep) || !sc.number (out x) || !sc.number (out y)) { ok = false; break; }
                        x += ox;
                        y += oy;
                        p.svg_arc (cx, cy, rx, ry, rot, large != 0, sweep != 0, x, y);
                        cx = x;
                        cy = y;
                        break;
                    }
                    case 'Z':
                        p.close ();
                        cx = sx;
                        cy = sy;
                        break;
                    default:
                        ok = false;
                        break;
                }
                if (!ok) break;
                prev = cmd;
            }
            return p;
        }

        public void svg_arc (double x1, double y1, double rx, double ry, double angle, bool large, bool sweep, double x2, double y2) {
            if (rx == 0 || ry == 0) {
                line_to (x2, y2);
                return;
            }
            if (x1 == x2 && y1 == y2) return;
            rx = rx.abs ();
            ry = ry.abs ();
            double phi = angle * Math.PI / 180;
            double cp = Math.cos (phi), sp = Math.sin (phi);
            double dx = (x1 - x2) / 2, dy = (y1 - y2) / 2;
            double x1p = cp * dx + sp * dy;
            double y1p = -sp * dx + cp * dy;
            double lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
            if (lambda > 1) {
                double sl = Math.sqrt (lambda);
                rx *= sl;
                ry *= sl;
            }
            double num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
            double den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
            double coef = den == 0 ? 0 : Math.sqrt (double.max (0, num / den));
            if (large == sweep) coef = -coef;
            double cxp = coef * rx * y1p / ry;
            double cyp = -coef * ry * x1p / rx;
            double cx = cp * cxp - sp * cyp + (x1 + x2) / 2;
            double cy = sp * cxp + cp * cyp + (y1 + y2) / 2;
            double t1 = vec_angle (1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
            double dt = vec_angle ((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
            if (!sweep && dt > 0) dt -= 2 * Math.PI;
            else if (sweep && dt < 0) dt += 2 * Math.PI;
            int n = (int) Math.ceil (dt.abs () / (Math.PI / 2) - 1e-9);
            if (n < 1) n = 1;
            double step = dt / n;
            double t = 4.0 / 3.0 * Math.tan (step / 4);
            for (int i = 0; i < n; i++) {
                double a1 = t1 + i * step, a2 = a1 + step;
                double c1 = Math.cos (a1), s1 = Math.sin (a1), c2 = Math.cos (a2), s2 = Math.sin (a2);
                double ex1 = c1 - t * s1, ey1 = s1 + t * c1;
                double ex2 = c2 + t * s2, ey2 = s2 - t * c2;
                curve_to (cx + cp * rx * ex1 - sp * ry * ey1, cy + sp * rx * ex1 + cp * ry * ey1,
                          cx + cp * rx * ex2 - sp * ry * ey2, cy + sp * rx * ex2 + cp * ry * ey2,
                          cx + cp * rx * c2 - sp * ry * s2, cy + sp * rx * c2 + cp * ry * s2);
            }
            var last = segs[segs.size - 1];
            last.x = x2;
            last.y = y2;
        }

        private static double vec_angle (double ux, double uy, double vx, double vy) {
            double a = Math.atan2 (uy, ux);
            double b = Math.atan2 (vy, vx);
            double d = b - a;
            while (d > Math.PI) d -= 2 * Math.PI;
            while (d < -Math.PI) d += 2 * Math.PI;
            return d;
        }

        public static PathData from_polygons (Gee.List<Polygon> polys) {
            var p = new PathData ();
            foreach (var poly in polys) p.add_polygon (poly.pts, poly.closed);
            return p;
        }

        public int node_count () {
            int n = 0;
            foreach (var s in segs) if (s.kind != SegKind.CLOSE) n++;
            return n;
        }

        public void reverse () {
            var subs = split_subpaths ();
            segs.clear ();
            foreach (var sub in subs) {
                var list = sub.segs;
                if (list.size == 0) continue;
                bool closed = list[list.size - 1].kind == SegKind.CLOSE;
                int last = closed ? list.size - 2 : list.size - 1;
                move_to (list[last].x, list[last].y);
                for (int i = last; i >= 1; i--) {
                    var s = list[i];
                    var prev = list[i - 1];
                    if (s.kind == SegKind.CURVE) curve_to (s.x2, s.y2, s.x1, s.y1, prev.x, prev.y);
                    else line_to (prev.x, prev.y);
                }
                if (closed) close ();
            }
        }

        public Gee.ArrayList<PathData> split_subpaths () {
            var list = new Gee.ArrayList<PathData> ();
            PathData? cur = null;
            foreach (var s in segs) {
                if (s.kind == SegKind.MOVE || cur == null) {
                    cur = new PathData ();
                    list.add (cur);
                }
                cur.segs.add (s.copy ());
                if (s.kind == SegKind.CLOSE) cur = null;
            }
            return list;
        }
    }

    public class PathScanner {
        private unowned string src;
        public int pos = 0;

        public PathScanner (string s) {
            src = s;
        }

        public bool at_end () {
            return pos >= src.length;
        }

        public char peek () {
            return pos < src.length ? src[pos] : 0;
        }

        public void skip_ws () {
            while (pos < src.length && (src[pos].isspace () || src[pos] == ',')) pos++;
        }

        public bool flag (out double v) {
            skip_ws ();
            v = 0;
            if (pos >= src.length) return false;
            if (src[pos] == '0' || src[pos] == '1') {
                v = src[pos] == '1' ? 1 : 0;
                pos++;
                return true;
            }
            return false;
        }

        public bool number (out double v) {
            skip_ws ();
            v = 0;
            int start = pos;
            if (pos < src.length && (src[pos] == '-' || src[pos] == '+')) pos++;
            bool digits = false;
            while (pos < src.length && src[pos].isdigit ()) {
                pos++;
                digits = true;
            }
            if (pos < src.length && src[pos] == '.') {
                pos++;
                while (pos < src.length && src[pos].isdigit ()) {
                    pos++;
                    digits = true;
                }
            }
            if (!digits) {
                pos = start;
                return false;
            }
            if (pos < src.length && (src[pos] == 'e' || src[pos] == 'E')) {
                int save = pos;
                pos++;
                if (pos < src.length && (src[pos] == '-' || src[pos] == '+')) pos++;
                if (pos < src.length && src[pos].isdigit ()) {
                    while (pos < src.length && src[pos].isdigit ()) pos++;
                } else {
                    pos = save;
                }
            }
            v = double.parse (src.substring (start, pos - start));
            return true;
        }
    }

    namespace Units {
        public const double PX_PER_IN = 96.0;
        public const double PX_PER_CM = 96.0 / 2.54;
        public const double PX_PER_MM = 96.0 / 25.4;
        public const double PX_PER_PT = 96.0 / 72.0;

        public double mm_per (string unit) {
            switch (unit) {
                case "mm": return 1;
                case "cm": return 10;
                case "m": return 1000;
                case "km": return 1000000;
                case "in": return 25.4;
                case "ft": return 304.8;
                case "yd": return 914.4;
                case "mi": return 1609344;
                case "pt": return 25.4 / 72;
                case "px": return 25.4 / 96;
                default: return 1;
            }
        }

        public double parse_length (string? s, double fallback = 0) {
            if (s == null) return fallback;
            string t = s.strip ();
            if (t == "") return fallback;
            int i = 0;
            while (i < t.length && (t[i].isdigit () || t[i] == '.' || t[i] == '-' || t[i] == '+' || t[i] == 'e' || t[i] == 'E')) {
                if ((t[i] == 'e' || t[i] == 'E') && (i + 1 >= t.length || !(t[i + 1].isdigit () || t[i + 1] == '-' || t[i + 1] == '+'))) break;
                i++;
            }
            double v = double.parse (t.substring (0, i));
            string unit = t.substring (i).strip ().down ();
            switch (unit) {
                case "in": return v * PX_PER_IN;
                case "cm": return v * PX_PER_CM;
                case "mm": return v * PX_PER_MM;
                case "pt": return v * PX_PER_PT;
                case "pc": return v * PX_PER_PT * 12;
                default: return v;
            }
        }

        public string cm (double px) {
            return PathData.fmt (px / PX_PER_CM, 4) + "cm";
        }

        public string inches (double px) {
            return PathData.fmt (px / PX_PER_IN, 6);
        }
    }
}
