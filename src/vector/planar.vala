namespace Singularity.Vector {

    public class PlanarFace : Object {
        public PathData path;
        public Point sample;
        public double area;

        public PlanarFace (PathData path, Point sample, double area) {
            this.path = path;
            this.sample = sample;
            this.area = area;
        }
    }

    public class PlanarFaces {
        private class HalfEdge : Object {
            public int from;
            public int to;
            public CurveEdge curve;
            public double angle;
            public HalfEdge? twin;
            public bool used = false;
            public int component = -1;
        }

        public static Gee.ArrayList<PlanarFace> compute (Gee.List<PathData> paths) {
            var arr = new Arrangement (paths, null, false);
            var pieces = arr.pieces;
            var points = new Gee.ArrayList<Point?> ();
            double snap = double.max (arr.epsilon * 200, 1e-4);
            var halfs = new Gee.ArrayList<HalfEdge> ();
            var outgoing = new Gee.HashMap<int, Gee.ArrayList<HalfEdge>> ();
            foreach (var p in pieces) {
                int a = vertex (points, p.start, snap);
                int b = vertex (points, p.end (), snap);
                if (a == b && !p.is_curve ()) continue;
                var h1 = new HalfEdge ();
                h1.from = a;
                h1.to = b;
                h1.curve = p;
                var t0 = p.tangent (0);
                h1.angle = Math.atan2 (t0.y, t0.x);
                var h2 = new HalfEdge ();
                h2.from = b;
                h2.to = a;
                h2.curve = p.reversed ();
                var t1 = h2.curve.tangent (0);
                h2.angle = Math.atan2 (t1.y, t1.x);
                h1.twin = h2;
                h2.twin = h1;
                halfs.add (h1);
                halfs.add (h2);
                foreach (var h in new HalfEdge[] { h1, h2 }) {
                    if (!outgoing.has_key (h.from)) outgoing[h.from] = new Gee.ArrayList<HalfEdge> ();
                    outgoing[h.from].add (h);
                }
            }
            foreach (var list in outgoing.values) list.sort ((x, y) => x.angle < y.angle ? -1 : x.angle > y.angle ? 1 : 0);
            int comp = 0;
            foreach (var h in halfs) {
                if (h.component >= 0) continue;
                var stack = new Gee.ArrayList<HalfEdge> ();
                stack.add (h);
                while (stack.size > 0) {
                    var cur = stack.remove_at (stack.size - 1);
                    if (cur.component >= 0) continue;
                    cur.component = comp;
                    cur.twin.component = comp;
                    foreach (var n in outgoing[cur.to]) if (n.component < 0) stack.add (n);
                    foreach (var n in outgoing[cur.from]) if (n.component < 0) stack.add (n);
                }
                comp++;
            }
            var bounded = new Gee.ArrayList<PlanarFace> ();
            var bounded_comp = new Gee.ArrayList<int> ();
            var outers = new Gee.ArrayList<PathData> ();
            var outer_comp = new Gee.ArrayList<int> ();
            foreach (var start in halfs) {
                if (start.used) continue;
                var loop = new PathData ();
                loop.move_to (start.curve.start.x, start.curve.start.y);
                var cur = start;
                int guard = 0;
                bool ok = true;
                while (true) {
                    cur.used = true;
                    loop.segs.add (cur.curve.segment.copy ());
                    var list = outgoing[cur.to];
                    var tin = cur.curve.tangent (1);
                    double back = Math.atan2 (-tin.y, -tin.x);
                    HalfEdge? next = null;
                    double best = double.INFINITY;
                    foreach (var cand in list) {
                        if (cand == cur.twin && list.size > 1) continue;
                        double d = back - cand.angle;
                        while (d <= 1e-9) d += 2 * Math.PI;
                        if (d < best) {
                            best = d;
                            next = cand;
                        }
                    }
                    if (next == null) next = cur.twin;
                    if (next == start) break;
                    if (next.used || ++guard > halfs.size) {
                        ok = false;
                        break;
                    }
                    cur = next;
                }
                if (!ok) continue;
                loop.close ();
                double area = PathOps.signed_area (loop);
                if (area > 1e-6) {
                    bounded.add (new PlanarFace (loop, Arrangement.interior_point (loop), area));
                    bounded_comp.add (start.component);
                } else {
                    outers.add (loop);
                    outer_comp.add (start.component);
                }
            }
            for (int i = 0; i < outers.size; i++) {
                var probe = PathOps.edges (outers[i])[0].at (0.5);
                int best = -1;
                double best_area = double.INFINITY;
                for (int f = 0; f < bounded.size; f++) {
                    if (bounded_comp[f] == outer_comp[i]) continue;
                    if (bounded[f].area >= best_area) continue;
                    if (PathOps.contains (bounded[f].path, probe)) {
                        best = f;
                        best_area = bounded[f].area;
                    }
                }
                if (best >= 0) {
                    bounded[best].path.append (outers[i]);
                    bounded[best].sample = Arrangement.interior_point (bounded[best].path);
                }
            }
            return bounded;
        }

        private static int vertex (Gee.ArrayList<Point?> points, Point p, double snap) {
            for (int i = 0; i < points.size; i++) if (points[i].distance (p) <= snap) return i;
            points.add (p);
            return points.size - 1;
        }

        public static PlanarFace? face_at (Gee.List<PlanarFace> faces, Point p) {
            PlanarFace? best = null;
            foreach (var f in faces) {
                if (!PathOps.contains (f.path, p)) continue;
                if (best == null || f.area < best.area) best = f;
            }
            return best;
        }
    }
}
