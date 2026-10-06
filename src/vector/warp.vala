namespace Singularity.Vector {

    public enum WarpStyle {
        ARC, ARC_LOWER, ARC_UPPER, ARCH, BULGE, SHELL_LOWER, SHELL_UPPER, FLAG, WAVE, FISH, RISE, FISHEYE, INFLATE, SQUEEZE, TWIST;

        public static string[] ids () {
            return { "arc", "arc-lower", "arc-upper", "arch", "bulge", "shell-lower", "shell-upper", "flag", "wave", "fish", "rise", "fisheye", "inflate", "squeeze", "twist" };
        }

        public string to_id () {
            return ids ()[(int) this];
        }

        public static WarpStyle from_id (string id) {
            var list = ids ();
            for (int i = 0; i < list.length; i++) if (list[i] == id) return (WarpStyle) i;
            return ARC;
        }
    }

    public class Warp {
        public static Point preset (WarpStyle style, Rect box, Point p, double bend, double hdist = 0, double vdist = 0, bool vertical = false) {
            if (box.w <= 0 || box.h <= 0) return p;
            double u = (p.x - box.x) / box.w;
            double v = (p.y - box.y) / box.h;
            if (vertical) {
                double t = u;
                u = v;
                v = t;
            }
            double nx = u * 2 - 1;
            double ny = v * 2 - 1;
            double b = bend.clamp (-1, 1);
            double ox = 0, oy = 0;
            switch (style) {
                case WarpStyle.ARC:
                    oy = -b * (1 - nx * nx) * 0.5;
                    break;
                case WarpStyle.ARC_LOWER:
                    oy = -b * (1 - nx * nx) * 0.5 * (ny + 1) / 2;
                    break;
                case WarpStyle.ARC_UPPER:
                    oy = -b * (1 - nx * nx) * 0.5 * (1 - ny) / 2;
                    break;
                case WarpStyle.ARCH:
                    oy = -b * (1 - nx * nx) * 0.5;
                    ox = 0;
                    break;
                case WarpStyle.BULGE:
                    oy = b * ny * (1 - nx * nx) * 0.5;
                    break;
                case WarpStyle.SHELL_LOWER:
                    oy = b * (1 - nx * nx) * 0.5 * (ny + 1) / 2;
                    break;
                case WarpStyle.SHELL_UPPER:
                    oy = -b * (1 - nx * nx) * 0.5 * (1 - ny) / 2;
                    break;
                case WarpStyle.FLAG:
                    oy = b * Math.sin (u * Math.PI * 2) * 0.25;
                    break;
                case WarpStyle.WAVE:
                    oy = b * Math.sin (u * Math.PI * 2) * 0.25 * (1 - ny.abs () * 0.5);
                    break;
                case WarpStyle.FISH:
                    oy = b * ny * Math.sin (u * Math.PI) * 0.4 * (u < 0.75 ? 1 : (1 - u) * 4 - 1);
                    break;
                case WarpStyle.RISE:
                    oy = -b * u * 0.5;
                    break;
                case WarpStyle.FISHEYE:
                    double r = Math.sqrt (nx * nx + ny * ny);
                    double f = r < 1 ? b * (1 - r * r) * 0.5 : 0;
                    ox = nx * f * 0.5;
                    oy = ny * f * 0.5;
                    break;
                case WarpStyle.INFLATE:
                    ox = nx * b * (1 - ny * ny) * 0.25;
                    oy = ny * b * (1 - nx * nx) * 0.25;
                    break;
                case WarpStyle.SQUEEZE:
                    ox = -nx * b * (1 - ny * ny) * 0.25;
                    break;
                case WarpStyle.TWIST:
                    double ang = b * Math.PI / 2 * (1 - Math.sqrt (nx * nx + ny * ny).clamp (0, 1));
                    double cx = nx * Math.cos (ang) - ny * Math.sin (ang);
                    double cy = nx * Math.sin (ang) + ny * Math.cos (ang);
                    ox = (cx - nx) / 2;
                    oy = (cy - ny) / 2;
                    break;
            }
            u += ox;
            v += oy;
            if (hdist != 0) {
                double scale = 1 + hdist * (v - 0.5);
                u = 0.5 + (u - 0.5) * scale;
            }
            if (vdist != 0) {
                double scale = 1 + vdist * (u - 0.5);
                v = 0.5 + (v - 0.5) * scale;
            }
            if (vertical) {
                double t = u;
                u = v;
                v = t;
            }
            return Point (box.x + u * box.w, box.y + v * box.h);
        }

        public static Point mesh (Point[] grid, int rows, int cols, Rect box, Point p) {
            if (box.w <= 0 || box.h <= 0 || grid.length != (rows + 1) * (cols + 1)) return p;
            double u = ((p.x - box.x) / box.w).clamp (0, 1) * cols;
            double v = ((p.y - box.y) / box.h).clamp (0, 1) * rows;
            int c = int.min ((int) u, cols - 1);
            int r = int.min ((int) v, rows - 1);
            double fu = u - c, fv = v - r;
            var p00 = grid[r * (cols + 1) + c];
            var p10 = grid[r * (cols + 1) + c + 1];
            var p01 = grid[(r + 1) * (cols + 1) + c];
            var p11 = grid[(r + 1) * (cols + 1) + c + 1];
            double x = p00.x * (1 - fu) * (1 - fv) + p10.x * fu * (1 - fv) + p01.x * (1 - fu) * fv + p11.x * fu * fv;
            double y = p00.y * (1 - fu) * (1 - fv) + p10.y * fu * (1 - fv) + p01.y * (1 - fu) * fv + p11.y * fu * fv;
            return Point (x, y);
        }

        public static double[] homography (Point[] src, Point[] dst) {
            double[,] a = new double[8, 9];
            for (int i = 0; i < 4; i++) {
                double x = src[i].x, y = src[i].y, X = dst[i].x, Y = dst[i].y;
                double[] r1 = { x, y, 1, 0, 0, 0, -x * X, -y * X, X };
                double[] r2 = { 0, 0, 0, x, y, 1, -x * Y, -y * Y, Y };
                for (int k = 0; k < 9; k++) {
                    a[i * 2, k] = r1[k];
                    a[i * 2 + 1, k] = r2[k];
                }
            }
            for (int col = 0; col < 8; col++) {
                int pivot = col;
                for (int row = col + 1; row < 8; row++) if (a[row, col].abs () > a[pivot, col].abs ()) pivot = row;
                for (int k = 0; k < 9; k++) {
                    double t = a[col, k];
                    a[col, k] = a[pivot, k];
                    a[pivot, k] = t;
                }
                double d = a[col, col];
                if (d.abs () < 1e-14) return { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
                for (int k = col; k < 9; k++) a[col, k] /= d;
                for (int row = 0; row < 8; row++) {
                    if (row == col) continue;
                    double f = a[row, col];
                    for (int k = col; k < 9; k++) a[row, k] -= f * a[col, k];
                }
            }
            return { a[0, 8], a[1, 8], a[2, 8], a[3, 8], a[4, 8], a[5, 8], a[6, 8], a[7, 8], 1 };
        }

        public static Point project (double[] h, Point p) {
            double w = h[6] * p.x + h[7] * p.y + h[8];
            if (w.abs () < 1e-12) w = 1e-12;
            return Point ((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w);
        }

        public static PathData pucker_bloat (PathData source, double amount) {
            var box = source.bounds ();
            var c = Point (box.cx (), box.cy ());
            var result = new PathData ();
            foreach (var s in source.segs) {
                var n = s.copy ();
                if (s.kind == SegKind.CURVE) {
                    n.x1 = s.x1 + (c.x - s.x1) * amount;
                    n.y1 = s.y1 + (c.y - s.y1) * amount;
                    n.x2 = s.x2 + (c.x - s.x2) * amount;
                    n.y2 = s.y2 + (c.y - s.y2) * amount;
                }
                result.segs.add (n);
            }
            var out_path = new PathData ();
            Point prev = Point (0, 0);
            foreach (var s in result.segs) {
                if (s.kind == SegKind.LINE) {
                    var a = PathOps.mix (prev, Point (s.x, s.y), 1.0 / 3);
                    var b = PathOps.mix (prev, Point (s.x, s.y), 2.0 / 3);
                    out_path.curve_to (a.x + (c.x - a.x) * amount, a.y + (c.y - a.y) * amount, b.x + (c.x - b.x) * amount, b.y + (c.y - b.y) * amount, s.x, s.y);
                } else {
                    out_path.segs.add (s.copy ());
                }
                if (s.kind != SegKind.CLOSE) prev = Point (s.x, s.y);
            }
            return out_path;
        }

        public static PathData roughen (PathData source, double size, int detail, bool smooth, uint32 seed) {
            var rand = new GLib.Rand.with_seed (seed);
            var result = new PathData ();
            foreach (var contour in PathOps.contours (source)) {
                bool closed = PathOps.contour_closed (contour);
                double len = PathOps.length (contour);
                int count = int.max (3, (int) (len / 100.0 * detail));
                Point[] pts = {};
                var samples = PathOps.sample (contour, len / count);
                foreach (var s in samples) pts += Point (s.point.x + (rand.next_double () * 2 - 1) * size, s.point.y + (rand.next_double () * 2 - 1) * size);
                if (closed && pts.length > 1) pts = pts[0:pts.length - 1];
                if (smooth) {
                    var smoothed = PolyOps.catmull (pts, closed);
                    result.append (smoothed);
                } else {
                    result.append (PathOps.polygon_path (pts, closed));
                }
            }
            return result;
        }

        public static PathData zigzag (PathData source, double size, int ridges, bool smooth) {
            var result = new PathData ();
            foreach (var contour in PathOps.contours (source)) {
                bool closed = PathOps.contour_closed (contour);
                double len = PathOps.length (contour);
                int n = int.max (2, ridges * 2 * PathOps.edges (contour).size);
                Point[] pts = {};
                for (int i = 0; i <= n; i++) {
                    Point p;
                    double a;
                    PathOps.point_at (contour, len * i / n, out p, out a);
                    double sgn = i % 2 == 0 ? 1 : -1;
                    if (i == 0 || i == n) sgn = closed ? sgn : 0;
                    pts += Point (p.x - Math.sin (a) * size * sgn, p.y + Math.cos (a) * size * sgn);
                }
                if (closed) pts = pts[0:pts.length - 1];
                result.append (smooth ? PolyOps.catmull (pts, closed) : PathOps.polygon_path (pts, closed));
            }
            return result;
        }

        public static PathData twist (PathData source, double degrees) {
            var box = source.bounds ();
            var c = Point (box.cx (), box.cy ());
            double rmax = Math.hypot (box.w, box.h) / 2;
            double rad = degrees * Math.PI / 180;
            return PathOps.map_points (source, (p) => {
                double dx = p.x - c.x, dy = p.y - c.y;
                double r = Math.hypot (dx, dy);
                double a = rad * (1 - (r / rmax).clamp (0, 1));
                return Point (c.x + dx * Math.cos (a) - dy * Math.sin (a), c.y + dx * Math.sin (a) + dy * Math.cos (a));
            });
        }
    }
}
