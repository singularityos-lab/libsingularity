namespace Singularity.Charts {

    public class TrendFit : Object {
        public TrendType kind;
        public double[] coeffs = {};
        public double r2;
        public bool valid;

        public double predict(double x) {
            switch (kind) {
                case TrendType.LINEAR:
                    return coeffs[0] + coeffs[1] * x;
                case TrendType.EXPONENTIAL:
                    return coeffs[0] * Math.exp(coeffs[1] * x);
                case TrendType.LOGARITHMIC:
                    return x > 0 ? coeffs[0] + coeffs[1] * Math.log(x) : double.NAN;
                case TrendType.POWER:
                    return x > 0 ? coeffs[0] * Math.pow(x, coeffs[1]) : double.NAN;
                case TrendType.POLYNOMIAL:
                    double y = 0;
                    for (int i = coeffs.length - 1; i >= 0; i--) y = y * x + coeffs[i];
                    return y;
                default:
                    return double.NAN;
            }
        }

        private static string num(double v) {
            char[] buf = new char[48];
            string s = v.format(buf, "%.4g");
            return s.replace("e+0", "E+").replace("e-0", "E-").replace("e+", "E+").replace("e-", "E-");
        }

        private static string signed(double v) {
            return v < 0 ? " - " + num(-v) : " + " + num(v);
        }

        public string equation() {
            if (!valid) return "";
            switch (kind) {
                case TrendType.LINEAR:
                    return "y = " + num(coeffs[1]) + "x" + signed(coeffs[0]);
                case TrendType.EXPONENTIAL:
                    return "y = " + num(coeffs[0]) + "e^" + num(coeffs[1]) + "x";
                case TrendType.LOGARITHMIC:
                    return "y = " + num(coeffs[1]) + "ln(x)" + signed(coeffs[0]);
                case TrendType.POWER:
                    return "y = " + num(coeffs[0]) + "x^" + num(coeffs[1]);
                case TrendType.POLYNOMIAL:
                    var sb = new StringBuilder("y =");
                    bool first = true;
                    for (int i = coeffs.length - 1; i >= 0; i--) {
                        double c = coeffs[i];
                        string term = i == 0 ? "" : (i == 1 ? "x" : "x^" + i.to_string());
                        if (first) {
                            sb.append(" " + num(c) + term);
                            first = false;
                        } else {
                            sb.append(signed(c) + term);
                        }
                    }
                    return sb.str;
                default:
                    return "";
            }
        }

        public static TrendFit fit(TrendType kind, double[] xs, double[] ys, int order = 2) {
            var f = new TrendFit();
            f.kind = kind;
            double[] px = {};
            double[] py = {};
            for (int i = 0; i < xs.length && i < ys.length; i++) {
                if (xs[i].is_nan() || ys[i].is_nan()) continue;
                double x = xs[i], y = ys[i];
                if ((kind == TrendType.LOGARITHMIC || kind == TrendType.POWER) && x <= 0) continue;
                if ((kind == TrendType.EXPONENTIAL || kind == TrendType.POWER) && y <= 0) continue;
                px += kind == TrendType.LOGARITHMIC || kind == TrendType.POWER ? Math.log(x) : x;
                py += kind == TrendType.EXPONENTIAL || kind == TrendType.POWER ? Math.log(y) : y;
            }
            int deg = kind == TrendType.POLYNOMIAL ? order.clamp(2, 6) : 1;
            if (px.length <= deg) return f;
            double[] c = least_squares(px, py, deg);
            if (c.length == 0) return f;
            double mean = 0;
            foreach (double y in py) mean += y;
            mean /= py.length;
            double ss_tot = 0, ss_res = 0;
            for (int i = 0; i < px.length; i++) {
                double yh = 0;
                for (int k = c.length - 1; k >= 0; k--) yh = yh * px[i] + c[k];
                ss_res += (py[i] - yh) * (py[i] - yh);
                ss_tot += (py[i] - mean) * (py[i] - mean);
            }
            f.r2 = ss_tot > 0 ? 1 - ss_res / ss_tot : 1;
            if (kind == TrendType.EXPONENTIAL || kind == TrendType.POWER) f.coeffs = { Math.exp(c[0]), c[1] };
            else f.coeffs = c;
            f.valid = true;
            return f;
        }

        public static double[] least_squares(double[] xs, double[] ys, int deg) {
            int n = deg + 1;
            var m = new double[n, n + 1];
            for (int i = 0; i < n; i++) {
                for (int j = 0; j < n; j++) {
                    double s = 0;
                    for (int k = 0; k < xs.length; k++) s += Math.pow(xs[k], i + j);
                    m[i, j] = s;
                }
                double t = 0;
                for (int k = 0; k < xs.length; k++) t += ys[k] * Math.pow(xs[k], i);
                m[i, n] = t;
            }
            for (int col = 0; col < n; col++) {
                int piv = col;
                for (int r = col + 1; r < n; r++) if (Math.fabs(m[r, col]) > Math.fabs(m[piv, col])) piv = r;
                if (Math.fabs(m[piv, col]) < 1e-300) return {};
                if (piv != col) {
                    for (int j = 0; j <= n; j++) {
                        double tmp = m[col, j];
                        m[col, j] = m[piv, j];
                        m[piv, j] = tmp;
                    }
                }
                for (int r = 0; r < n; r++) {
                    if (r == col) continue;
                    double factor = m[r, col] / m[col, col];
                    for (int j = col; j <= n; j++) m[r, j] -= factor * m[col, j];
                }
            }
            double[] out_c = new double[n];
            for (int i = 0; i < n; i++) out_c[i] = m[i, n] / m[i, i];
            return out_c;
        }

        public static double[] moving_average(double[] ys, int period) {
            double[] out_v = new double[ys.length];
            for (int i = 0; i < ys.length; i++) {
                if (i + 1 < period) {
                    out_v[i] = double.NAN;
                    continue;
                }
                double s = 0;
                int n = 0;
                for (int k = i - period + 1; k <= i; k++) {
                    if (ys[k].is_nan()) continue;
                    s += ys[k];
                    n++;
                }
                out_v[i] = n > 0 ? s / n : double.NAN;
            }
            return out_v;
        }
    }

    public class Stats : Object {
        public static double[] finite(double[] v) {
            double[] o = {};
            foreach (double d in v) if (!d.is_nan() && d.is_finite()) o += d;
            return o;
        }

        public static double[] sorted(double[] v) {
            double[] o = finite(v);
            var list = new Gee.ArrayList<double?>();
            foreach (double d in o) list.add(d);
            list.sort((a, b) => a < b ? -1 : (a > b ? 1 : 0));
            double[] r = {};
            foreach (var d in list) r += d;
            return r;
        }

        public static double mean(double[] v) {
            double s = 0;
            int n = 0;
            foreach (double d in v) if (!d.is_nan()) {
                s += d;
                n++;
            }
            return n > 0 ? s / n : double.NAN;
        }

        public static double stdev(double[] v) {
            double m = mean(v);
            double s = 0;
            int n = 0;
            foreach (double d in v) if (!d.is_nan()) {
                s += (d - m) * (d - m);
                n++;
            }
            return n > 1 ? Math.sqrt(s / (n - 1)) : 0;
        }

        public static double quartile_exc(double[] sorted_v, double p) {
            int n = sorted_v.length;
            if (n == 0) return double.NAN;
            double pos = p * (n + 1) - 1;
            if (pos <= 0) return sorted_v[0];
            if (pos >= n - 1) return sorted_v[n - 1];
            int lo = (int) Math.floor(pos);
            return sorted_v[lo] + (pos - lo) * (sorted_v[lo + 1] - sorted_v[lo]);
        }

        public static double[] bin_edges(double[] v, int bins, double width) {
            double[] s = sorted(v);
            if (s.length == 0) return {};
            double lo = s[0], hi = s[s.length - 1];
            if (hi <= lo) hi = lo + 1;
            double w = width;
            if (w.is_nan() || w <= 0) {
                if (bins > 0) {
                    w = (hi - lo) / bins;
                } else {
                    double sd = stdev(s);
                    w = sd > 0 ? 3.5 * sd / Math.cbrt(s.length) : (hi - lo);
                }
            }
            if (w <= 0) w = 1;
            double[] edges = { lo };
            double e = lo;
            int guard = 0;
            while (e < hi && guard++ < 500) {
                e += w;
                edges += e;
            }
            if (edges.length < 2) edges += lo + w;
            return edges;
        }

        public static int[] histogram(double[] v, double[] edges) {
            int nb = int.max(edges.length - 1, 0);
            int[] counts = new int[nb];
            foreach (double d in finite(v)) {
                for (int b = 0; b < nb; b++) {
                    bool last = b == nb - 1;
                    if ((b == 0 ? d >= edges[b] : d > edges[b]) && (d <= edges[b + 1] || last)) {
                        counts[b]++;
                        break;
                    }
                }
            }
            return counts;
        }
    }
}
