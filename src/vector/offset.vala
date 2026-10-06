namespace Singularity.Vector {

    public enum CornerStyle {
        INTERSECT,
        SQUARE,
        BEVEL,
        ROUND;

        public string to_id () {
            switch (this) {
                case SQUARE: return "square";
                case BEVEL: return "bevel";
                case ROUND: return "round";
                default: return "intersect";
            }
        }

        public static CornerStyle from_id (string? id) {
            switch (id) {
                case "square": return SQUARE;
                case "bevel": return BEVEL;
                case "round": return ROUND;
                default: return INTERSECT;
            }
        }
    }

    public class OffsetEdge {
        public Point[] pts;
        public double width;
        public CornerStyle end_corner = CornerStyle.INTERSECT;

        public OffsetEdge (Point[] pts, double width) {
            this.pts = pts;
            this.width = width;
        }
    }

    public class Offset {
        public static Point[] polyline (Point[] pts, double d) {
            int n = pts.length;
            if (n < 2) return pts;
            Point[] result = new Point[n];
            for (int i = 0; i < n; i++) {
                double nx1 = 0, ny1 = 0, nx2 = 0, ny2 = 0;
                bool has1 = false, has2 = false;
                if (i > 0) has1 = normal (pts[i - 1], pts[i], out nx1, out ny1);
                if (i < n - 1) has2 = normal (pts[i], pts[i + 1], out nx2, out ny2);
                if (!has1) {
                    nx1 = nx2;
                    ny1 = ny2;
                }
                if (!has2) {
                    nx2 = nx1;
                    ny2 = ny1;
                }
                double bx = nx1 + nx2, by = ny1 + ny2;
                double bl = Math.hypot (bx, by);
                if (bl < 1e-9) {
                    bx = nx1;
                    by = ny1;
                } else {
                    bx /= bl;
                    by /= bl;
                }
                double dot = bx * nx1 + by * ny1;
                double k = dot.abs () > 0.2 ? d / dot : d * 5;
                result[i] = Point (pts[i].x + bx * k, pts[i].y + by * k);
            }
            return result;
        }

        private static bool normal (Point a, Point b, out double nx, out double ny) {
            double dx = b.x - a.x, dy = b.y - a.y;
            double l = Math.hypot (dx, dy);
            if (l < 1e-12) {
                nx = 0;
                ny = 0;
                return false;
            }
            nx = dy / l;
            ny = -dx / l;
            return true;
        }

        public static Point[] closed (Gee.List<OffsetEdge> edges) {
            Point[] all = {};
            foreach (var e in edges) foreach (var p in e.pts) all += p;
            double sign = Polyline.signed_area (all) >= 0 ? 1 : -1;
            int count = edges.size;
            var off_edges = new Gee.ArrayList<OffsetEdge> ();
            for (int i = 0; i < count; i++) off_edges.add (new OffsetEdge (polyline (edges[i].pts, edges[i].width * sign), 0));
            Point[] out_pts = {};
            for (int i = 0; i < count; i++) {
                var cur = off_edges[i].pts;
                var next = off_edges[(i + 1) % count].pts;
                if (cur.length < 2) continue;
                for (int k = 1; k < cur.length - 1; k++) out_pts += cur[k];
                if (next.length < 2) {
                    out_pts += cur[cur.length - 1];
                    continue;
                }
                var e = edges[i];
                var en = edges[(i + 1) % count];
                foreach (var jp in join (cur[cur.length - 2], cur[cur.length - 1], next[0], next[1], e.pts[e.pts.length - 1], e.width, en.width, e.end_corner)) out_pts += jp;
            }
            return out_pts;
        }

        private static Point[] join (Point a0, Point a1, Point b0, Point b1, Point corner, double wa, double wb, CornerStyle style) {
            Point[] out_pts = {};
            Point hit;
            double t, u;
            bool ok = Polyline.segment_intersection (a0, a1, b0, b1, out hit, out t, out u);
            switch (style) {
                case CornerStyle.BEVEL:
                    out_pts += a1;
                    out_pts += b0;
                    return out_pts;
                case CornerStyle.ROUND: {
                    out_pts += a1;
                    double r = (a1.distance (corner) + b0.distance (corner)) / 2;
                    double s = Math.atan2 (a1.y - corner.y, a1.x - corner.x);
                    double e = Math.atan2 (b0.y - corner.y, b0.x - corner.x);
                    double sweep = e - s;
                    while (sweep > Math.PI) sweep -= 2 * Math.PI;
                    while (sweep < -Math.PI) sweep += 2 * Math.PI;
                    int steps = int.max (2, (int) (sweep.abs () / 0.15));
                    for (int i = 1; i < steps; i++) {
                        double ang = s + sweep * i / steps;
                        out_pts += Point (corner.x + r * Math.cos (ang), corner.y + r * Math.sin (ang));
                    }
                    out_pts += b0;
                    return out_pts;
                }
                case CornerStyle.SQUARE: {
                    double dax = a1.x - a0.x, day = a1.y - a0.y;
                    double la = Math.hypot (dax, day);
                    double dbx = b1.x - b0.x, dby = b1.y - b0.y;
                    double lb = Math.hypot (dbx, dby);
                    if (la < 1e-12 || lb < 1e-12) break;
                    var pa = Point (a1.x + dax / la * wb, a1.y + day / la * wb);
                    var pb = Point (b0.x - dbx / lb * wa, b0.y - dby / lb * wa);
                    if (ok && t > 1 && hit.distance (a1) < pa.distance (a1)) {
                        out_pts += hit;
                        return out_pts;
                    }
                    out_pts += pa;
                    out_pts += pb;
                    return out_pts;
                }
                default:
                    break;
            }
            if (ok && hit.distance (corner) < 10 * double.max (wa, wb) + 1e-6) {
                out_pts += hit;
            } else {
                out_pts += a1;
                out_pts += b0;
            }
            return out_pts;
        }
    }
}
