namespace Singularity.Vector {

    public class TraceLayer : Object {
        public double r;
        public double g;
        public double b;
        public PathData path = new PathData ();
        public int pixels;

        public TraceLayer (double r, double g, double b) {
            this.r = r;
            this.g = g;
            this.b = b;
        }
    }

    public class TraceOptions : Object {
        public string mode = "bw";
        public int colors = 6;
        public int threshold = 128;
        public double noise = 4;
        public double accuracy = 1.0;
        public double corner = 60;
        public bool ignore_white = false;
        public bool straight = false;
    }

    public class BitmapTrace {
        public static Gee.ArrayList<TraceLayer> trace (uint8[] rgba, int width, int height, int stride, TraceOptions opts) {
            var layers = new Gee.ArrayList<TraceLayer> ();
            if (width <= 0 || height <= 0) return layers;
            int n = width * height;
            int[] labels = new int[n];
            double[] palette = {};
            if (opts.mode == "bw" || opts.mode == "gray") {
                int levels = opts.mode == "bw" ? 2 : int.max (2, opts.colors);
                for (int y = 0; y < height; y++) {
                    for (int x = 0; x < width; x++) {
                        int o = y * stride + x * 4;
                        double a = rgba[o + 3] / 255.0;
                        double lum = (0.2126 * rgba[o] + 0.7152 * rgba[o + 1] + 0.0722 * rgba[o + 2]) * a + 255 * (1 - a);
                        if (levels == 2) labels[y * width + x] = lum < opts.threshold ? 0 : 1;
                        else labels[y * width + x] = ((int) (lum / 256.0 * levels)).clamp (0, levels - 1);
                    }
                }
                for (int i = 0; i < levels; i++) {
                    double v = levels == 2 ? (i == 0 ? 0 : 1) : (i + 0.5) / levels;
                    palette += v;
                    palette += v;
                    palette += v;
                }
            } else {
                palette = quantize (rgba, width, height, stride, int.max (2, opts.colors), labels);
            }
            int k = palette.length / 3;
            int[] counts = new int[k];
            foreach (int l in labels) counts[l]++;
            int[] order = new int[k];
            for (int i = 0; i < k; i++) order[i] = i;
            for (int i = 0; i < k; i++) {
                for (int j = i + 1; j < k; j++) {
                    if (counts[order[j]] > counts[order[i]]) {
                        int t = order[i];
                        order[i] = order[j];
                        order[j] = t;
                    }
                }
            }
            if (opts.mode == "bw") order = { 1, 0 };
            int[] rank = new int[k];
            for (int i = 0; i < k; i++) rank[order[i]] = i;
            bool[] mask = new bool[n];
            for (int pos = 0; pos < k; pos++) {
                int label = order[pos];
                if (counts[label] == 0) continue;
                double r = palette[label * 3], g = palette[label * 3 + 1], b = palette[label * 3 + 2];
                bool white = r > 0.96 && g > 0.96 && b > 0.96;
                if (opts.ignore_white && white) continue;
                if (opts.mode == "bw" && label == 1) continue;
                int on = 0;
                for (int i = 0; i < n; i++) {
                    int li = labels[i];
                    bool v = opts.mode == "bw" ? li == label : rank[li] >= pos;
                    if (opts.ignore_white && palette[li * 3] > 0.96 && palette[li * 3 + 1] > 0.96 && palette[li * 3 + 2] > 0.96) v = false;
                    mask[i] = v;
                    if (v) on++;
                }
                var layer = new TraceLayer (r, g, b);
                layer.pixels = counts[label];
                layer.path = contours (mask, width, height, opts);
                if (!layer.path.is_empty ()) layers.add (layer);
            }
            return layers;
        }

        public static double[] quantize (uint8[] rgba, int width, int height, int stride, int k, int[] labels) {
            var rand = new GLib.Rand.with_seed (7);
            int n = width * height;
            int step = int.max (1, (int) Math.sqrt (n / 20000.0));
            double[] samples = {};
            for (int y = 0; y < height; y += step) {
                for (int x = 0; x < width; x += step) {
                    int o = y * stride + x * 4;
                    double a = rgba[o + 3] / 255.0;
                    samples += (rgba[o] / 255.0) * a + (1 - a);
                    samples += (rgba[o + 1] / 255.0) * a + (1 - a);
                    samples += (rgba[o + 2] / 255.0) * a + (1 - a);
                }
            }
            int m = samples.length / 3;
            k = int.min (k, m);
            double[] centers = new double[k * 3];
            int first = rand.int_range (0, m);
            for (int c = 0; c < 3; c++) centers[c] = samples[first * 3 + c];
            double[] dist = new double[m];
            for (int ci = 1; ci < k; ci++) {
                double total = 0;
                for (int i = 0; i < m; i++) {
                    double best = double.INFINITY;
                    for (int j = 0; j < ci; j++) best = double.min (best, d2 (samples, i, centers, j));
                    dist[i] = best;
                    total += best;
                }
                double pick = rand.next_double () * total;
                int chosen = m - 1;
                for (int i = 0; i < m; i++) {
                    pick -= dist[i];
                    if (pick <= 0) {
                        chosen = i;
                        break;
                    }
                }
                for (int c = 0; c < 3; c++) centers[ci * 3 + c] = samples[chosen * 3 + c];
            }
            int[] assign = new int[m];
            for (int iter = 0; iter < 16; iter++) {
                double[] sum = new double[k * 3];
                int[] cnt = new int[k];
                for (int i = 0; i < m; i++) {
                    int best = 0;
                    double bd = double.INFINITY;
                    for (int j = 0; j < k; j++) {
                        double d = d2 (samples, i, centers, j);
                        if (d < bd) {
                            bd = d;
                            best = j;
                        }
                    }
                    assign[i] = best;
                    cnt[best]++;
                    for (int c = 0; c < 3; c++) sum[best * 3 + c] += samples[i * 3 + c];
                }
                for (int j = 0; j < k; j++) if (cnt[j] > 0) for (int c = 0; c < 3; c++) centers[j * 3 + c] = sum[j * 3 + c] / cnt[j];
            }
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    int o = y * stride + x * 4;
                    double a = rgba[o + 3] / 255.0;
                    double r = (rgba[o] / 255.0) * a + (1 - a), g = (rgba[o + 1] / 255.0) * a + (1 - a), b = (rgba[o + 2] / 255.0) * a + (1 - a);
                    int best = 0;
                    double bd = double.INFINITY;
                    for (int j = 0; j < k; j++) {
                        double d = (r - centers[j * 3]) * (r - centers[j * 3]) + (g - centers[j * 3 + 1]) * (g - centers[j * 3 + 1]) + (b - centers[j * 3 + 2]) * (b - centers[j * 3 + 2]);
                        if (d < bd) {
                            bd = d;
                            best = j;
                        }
                    }
                    labels[y * width + x] = best;
                }
            }
            return centers;
        }

        private static double d2 (double[] s, int i, double[] c, int j) {
            double dr = s[i * 3] - c[j * 3], dg = s[i * 3 + 1] - c[j * 3 + 1], db = s[i * 3 + 2] - c[j * 3 + 2];
            return dr * dr + dg * dg + db * db;
        }

        public static PathData contours (bool[] mask, int width, int height, TraceOptions opts) {
            int vw = width + 1;
            var next = new Gee.HashMap<int, Gee.ArrayList<int>> ();
            int edges = 0;
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    if (!mask[y * width + x]) continue;
                    if (y == 0 || !mask[(y - 1) * width + x]) add_edge (next, y * vw + x, y * vw + x + 1, ref edges);
                    if (x == width - 1 || !mask[y * width + x + 1]) add_edge (next, y * vw + x + 1, (y + 1) * vw + x + 1, ref edges);
                    if (y == height - 1 || !mask[(y + 1) * width + x]) add_edge (next, (y + 1) * vw + x + 1, (y + 1) * vw + x, ref edges);
                    if (x == 0 || !mask[y * width + x - 1]) add_edge (next, (y + 1) * vw + x, y * vw + x, ref edges);
                }
            }
            var result = new PathData ();
            var starts = new Gee.ArrayList<int> ();
            starts.add_all (next.keys);
            starts.sort ();
            foreach (int s in starts) {
                while (next.has_key (s) && next[s].size > 0) {
                    Point[] loop = {};
                    int cur = s;
                    int prev_dir = -1;
                    int guard = 0;
                    while (true) {
                        loop += Point (cur % vw, cur / vw);
                        var outs = next[cur];
                        int pick = 0;
                        if (outs.size > 1 && prev_dir >= 0) {
                            int best = 99;
                            for (int i = 0; i < outs.size; i++) {
                                int d = dir_of (cur, outs[i], vw);
                                int turn = (d - prev_dir + 4) % 4;
                                int pref = turn == 1 ? 0 : (turn == 0 ? 1 : (turn == 3 ? 2 : 3));
                                if (pref < best) {
                                    best = pref;
                                    pick = i;
                                }
                            }
                        }
                        int to = outs[pick];
                        outs.remove_at (pick);
                        prev_dir = dir_of (cur, to, vw);
                        cur = to;
                        if (cur == s || ++guard > edges) break;
                    }
                    double area = 0;
                    for (int i = 0; i < loop.length; i++) {
                        var a = loop[i];
                        var b = loop[(i + 1) % loop.length];
                        area += a.x * b.y - b.x * a.y;
                    }
                    if ((area / 2).abs () < opts.noise) continue;
                    result.append (smooth_loop (loop, opts));
                }
            }
            return result;
        }

        private static int dir_of (int a, int b, int vw) {
            int dx = b % vw - a % vw;
            int dy = b / vw - a / vw;
            if (dx > 0) return 0;
            if (dy > 0) return 1;
            if (dx < 0) return 2;
            return 3;
        }

        private static void add_edge (Gee.HashMap<int, Gee.ArrayList<int>> next, int a, int b, ref int count) {
            if (!next.has_key (a)) next[a] = new Gee.ArrayList<int> ();
            next[a].add (b);
            count++;
        }

        private static PathData smooth_loop (Point[] loop, TraceOptions opts) {
            int n = loop.length;
            Point[] mids = new Point[n];
            for (int i = 0; i < n; i++) mids[i] = PathOps.mix (loop[i], loop[(i + 1) % n], 0.5);
            var reduced = PolyOps.simplify (close_ring (mids), 0.6 / double.max (opts.accuracy, 0.1));
            if (reduced.length > 1) reduced = reduced[0:reduced.length - 1];
            if (opts.straight || reduced.length < 4) return PathOps.polygon_path (reduced, true);
            int m = reduced.length;
            double limit = opts.corner * Math.PI / 180;
            var corners = new Gee.ArrayList<int> ();
            for (int i = 0; i < m; i++) {
                var a = reduced[(i - 1 + m) % m];
                var b = reduced[i];
                var c = reduced[(i + 1) % m];
                double t = Math.atan2 ((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x), (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y)).abs ();
                if (t > limit) corners.add (i);
            }
            if (corners.size == 0) {
                var sm = PolyOps.catmull (reduced, true, 1.0);
                var bb = sm.bounds ();
                var hb = Rect (reduced[0].x, reduced[0].y, 0, 0);
                foreach (var q in reduced) hb = hb.include (q.x, q.y);
                if (bb.x < hb.x - 2 || bb.y < hb.y - 2 || bb.x + bb.w > hb.x + hb.w + 2 || bb.y + bb.h > hb.y + hb.h + 2) return PathOps.polygon_path (reduced, true);
                return sm;
            }
            var path = new PathData ();
            var start = reduced[corners[0]];
            path.move_to (start.x, start.y);
            double err = 0.5 / double.max (opts.accuracy, 0.1);
            for (int ci = 0; ci < corners.size; ci++) {
                int a = corners[ci];
                int b = corners[(ci + 1) % corners.size];
                Point[] run = {};
                int i = a;
                while (true) {
                    run += reduced[i];
                    if (i == b && run.length > 1) break;
                    i = (i + 1) % m;
                    if (run.length > m + 1) break;
                }
                if (run.length == 2) {
                    path.line_to (run[1].x, run[1].y);
                    continue;
                }
                var fitted = CurveFit.fit (run, err);
                bool sane = true;
                var hull = Rect (run[0].x, run[0].y, 0, 0);
                foreach (var q in run) hull = hull.include (q.x, q.y);
                hull = hull.inflate (err * 2 + 0.5);
                foreach (var c in fitted) {
                    for (int k = 1; k < 8 && sane; k++) {
                        var q = c.at (k / 8.0);
                        if (!hull.contains (q.x, q.y)) sane = false;
                        double best = double.INFINITY;
                        for (int j = 0; j + 1 < run.length; j++) best = double.min (best, PathData.segment_distance (run[j], run[j + 1], q.x, q.y));
                        if (best > err * 3 + 0.75) sane = false;
                    }
                }
                if (sane) {
                    foreach (var c in fitted) path.curve_to (c.p1.x, c.p1.y, c.p2.x, c.p2.y, c.p3.x, c.p3.y);
                } else {
                    for (int j = 1; j < run.length; j++) path.line_to (run[j].x, run[j].y);
                }
            }
            path.close ();
            return path;
        }

        private static Point[] close_ring (Point[] pts) {
            Point[] r = pts;
            if (pts.length > 0) r += pts[0];
            return r;
        }
    }
}
