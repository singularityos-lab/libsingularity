namespace Singularity.Charts {

    public delegate string NumberFormatter(double value, string format);

    public class ChartPainter : Object {
        private const string[] LIGHT = { "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948" };
        private const string[] DARK = { "#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767" };

        public bool dark;
        public bool selected;
        public bool frame = true;
        public double font_scale = 1;
        public string font_family = "Sans";
        private NumberFormatter? formatter;

        private string surface;
        private string ink;
        private string ink2;
        private string grid;

        public void set_formatter(owned NumberFormatter f) {
            formatter = (owned) f;
        }

        public static string palette_color(int i, bool dark) {
            return (dark ? DARK : LIGHT)[i % 8];
        }

        public string series_color(ChartSpec spec, int i) {
            if (i >= 0 && i < spec.series.size && spec.series[i].color.length == 7) return spec.series[i].color;
            return palette_color(i, dark);
        }

        public static int hex2(string hex, int at) {
            if (hex.length < at + 2) return 0;
            return (int) ((hexval(hex[at]) << 4) | hexval(hex[at + 1]));
        }

        private static uint hexval(char c) {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return 0;
        }

        private static void rgb(Cairo.Context cr, string hex, double alpha = 1) {
            if (hex.length != 7) {
                cr.set_source_rgba(0.5, 0.5, 0.5, alpha);
                return;
            }
            cr.set_source_rgba(hex2(hex, 1) / 255.0, hex2(hex, 3) / 255.0, hex2(hex, 5) / 255.0, alpha);
        }

        private static void rrect(Cairo.Context cr, double x, double y, double w, double h, double r) {
            r = double.min(r, double.min(w, h) / 2);
            if (r <= 0) {
                cr.rectangle(x, y, w, h);
                return;
            }
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }

        private static void end_rounded(Cairo.Context cr, double x, double y, double w, double h, double r, bool horizontal, bool positive) {
            r = double.min(r, double.min(w, h) / 2);
            if (r <= 0.5) {
                cr.rectangle(x, y, w, h);
                return;
            }
            cr.new_sub_path();
            if (!horizontal && positive) {
                cr.move_to(x, y + h);
                cr.line_to(x, y + r);
                cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
                cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
                cr.line_to(x + w, y + h);
            } else if (!horizontal) {
                cr.move_to(x, y);
                cr.line_to(x + w, y);
                cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
                cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            } else if (positive) {
                cr.move_to(x, y);
                cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
                cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
                cr.line_to(x, y + h);
            } else {
                cr.move_to(x + w, y);
                cr.line_to(x + w, y + h);
                cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
                cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            }
            cr.close_path();
        }

        private Pango.Layout text(Cairo.Context cr, string s, double size, bool bold = false) {
            var layout = Pango.cairo_create_layout(cr);
            var font = Pango.FontDescription.from_string(font_family);
            font.set_absolute_size(size * font_scale * Pango.SCALE);
            if (bold) font.set_weight(Pango.Weight.SEMIBOLD);
            layout.set_font_description(font);
            layout.set_text(s, -1);
            return layout;
        }

        private void show_text(Cairo.Context cr, string s, double size, double x, double y, string color, bool bold = false, double align = 0, double valign = 0) {
            var l = text(cr, s, size, bold);
            int tw, th;
            l.get_pixel_size(out tw, out th);
            cr.move_to(x - tw * align, y - th * valign);
            rgb(cr, color);
            Pango.cairo_show_layout(cr, l);
        }

        private static double nice_step(double span, int target) {
            if (span <= 0) return 1;
            double raw = span / target;
            double mag = Math.pow(10, Math.floor(Math.log10(raw)));
            double n = raw / mag;
            double step = n <= 1 ? 1 : (n <= 2 ? 2 : (n <= 2.5 ? 2.5 : (n <= 5 ? 5 : 10)));
            return step * mag;
        }

        private static string trim_zeros(string s) {
            if (!s.contains(".")) return s;
            string r = s;
            while (r.has_suffix("0")) r = r.substring(0, r.length - 1);
            if (r.has_suffix(".")) r = r.substring(0, r.length - 1);
            return r;
        }

        private static string fixed(double v, int d) {
            char[] buf = new char[64];
            return v.format(buf, "%." + d.to_string() + "f");
        }

        public string format_value(double v, string fmt) {
            if (fmt != "" && fmt != "General" && formatter != null) return formatter(v, fmt);
            double a = Math.fabs(v);
            if (a >= 1e9) return trim_zeros(fixed(v / 1e9, 1)) + "B";
            if (a >= 1e6) return trim_zeros(fixed(v / 1e6, 1)) + "M";
            if (a >= 1e4) return trim_zeros(fixed(v / 1e3, 1)) + "K";
            if (a != 0 && a < 1e-4) {
                char[] buf = new char[64];
                return v.format(buf, "%.2e");
            }
            string s = trim_zeros(fixed(v, 6));
            return s == "-0" ? "0" : s;
        }

        private void set_theme() {
            surface = dark ? "#1a1a19" : "#fcfcfb";
            ink = dark ? "#ffffff" : "#0b0b0b";
            ink2 = dark ? "#c3c2b7" : "#52514e";
            grid = dark ? "#34332f" : "#e6e5e0";
        }

        private class Box {
            public double x;
            public double y;
            public double w;
            public double h;

            public Box(double x, double y, double w, double h) {
                this.x = x;
                this.y = y;
                this.w = w;
                this.h = h;
            }
        }

        public void draw(Cairo.Context cr, ChartSpec spec, double w, double h) {
            set_theme();
            cr.save();
            if (frame) {
                rrect(cr, 0, 0, w, h, 12);
                rgb(cr, surface);
                cr.fill_preserve();
                if (selected) {
                    rgb(cr, palette_color(0, dark));
                    cr.set_line_width(2);
                } else {
                    rgb(cr, ink, 0.12);
                    cr.set_line_width(1);
                }
                cr.stroke();
                rrect(cr, 0, 0, w, h, 12);
                cr.clip();
            }
            var box = new Box(16, 14, w - 32, h - 26);
            if (spec.title != "") {
                var tl = text(cr, spec.title, 14, true);
                tl.set_width((int) (box.w * Pango.SCALE));
                tl.set_alignment(Pango.Alignment.CENTER);
                tl.set_ellipsize(Pango.EllipsizeMode.END);
                int tw, th;
                tl.get_pixel_size(out tw, out th);
                cr.move_to(box.x, box.y);
                rgb(cr, ink);
                Pango.cairo_show_layout(cr, tl);
                box.y += th + 8;
                box.h -= th + 8;
            }
            if (!has_data(spec)) {
                show_text(cr, _("No numbers to chart in the selected cells"), 12, w / 2, h / 2, ink2, false, 0.5, 0.5);
                cr.restore();
                return;
            }
            draw_legend(cr, spec, box);
            if (box.w < 30 || box.h < 30) {
                cr.restore();
                return;
            }
            switch (spec.kind) {
                case ChartType.PIE:
                case ChartType.DOUGHNUT:
                    draw_pie(cr, spec, box);
                    break;
                case ChartType.RADAR:
                    draw_radar(cr, spec, box);
                    break;
                case ChartType.TREEMAP:
                    draw_treemap(cr, spec, box);
                    break;
                case ChartType.SUNBURST:
                    draw_sunburst(cr, spec, box);
                    break;
                case ChartType.FUNNEL:
                    draw_funnel(cr, spec, box);
                    break;
                case ChartType.HISTOGRAM:
                case ChartType.PARETO:
                    draw_histogram(cr, spec, box);
                    break;
                case ChartType.BOX_WHISKER:
                    draw_box(cr, spec, box);
                    break;
                case ChartType.WATERFALL:
                    draw_waterfall(cr, spec, box);
                    break;
                case ChartType.STOCK:
                    draw_stock(cr, spec, box);
                    break;
                default:
                    draw_cartesian(cr, spec, box);
                    break;
            }
            cr.restore();
        }

        private static bool has_data(ChartSpec spec) {
            foreach (var s in spec.series) {
                foreach (double v in s.values) if (!v.is_nan()) return true;
            }
            return false;
        }

        private string[] legend_labels(ChartSpec spec, out string[] colors) {
            string[] labels = {};
            string[] cols = {};
            bool by_point = spec.kind == ChartType.PIE || spec.kind == ChartType.DOUGHNUT || spec.kind == ChartType.FUNNEL || spec.kind == ChartType.TREEMAP || spec.kind == ChartType.SUNBURST || (spec.vary_colors && spec.series.size == 1);
            if (spec.kind == ChartType.WATERFALL) {
                labels = { _("Increase"), _("Decrease") };
                cols = { palette_color(2, dark), palette_color(7, dark) };
                colors = cols;
                return labels;
            }
            if (by_point) {
                var cats = spec.category_labels();
                string[] seen = {};
                for (int i = 0; i < cats.length; i++) {
                    string c = cats[i];
                    if (spec.kind == ChartType.TREEMAP || spec.kind == ChartType.SUNBURST) {
                        c = top_level(c);
                        bool dup = false;
                        foreach (string s in seen) if (s == c) dup = true;
                        if (dup) continue;
                    }
                    seen += c;
                    labels += c;
                    cols += palette_color(labels.length - 1, dark);
                }
            } else {
                for (int i = 0; i < spec.series.size; i++) {
                    string n = spec.series[i].name != "" ? spec.series[i].name : _("Series %d").printf(i + 1);
                    labels += n;
                    cols += series_color(spec, i);
                    var t = spec.series[i].trendline;
                    if (t != null && t.kind != TrendType.NONE) {
                        labels += t.name != "" ? t.name : trend_name(t, n);
                        cols += series_color(spec, i);
                    }
                }
                if (spec.kind == ChartType.PARETO) {
                    labels += _("Cumulative %");
                    cols += palette_color(1, dark);
                }
            }
            colors = cols;
            return labels;
        }

        private static string trend_name(Trendline t, string series) {
            switch (t.kind) {
                case TrendType.LINEAR: return _("Linear (%s)").printf(series);
                case TrendType.EXPONENTIAL: return _("Expon. (%s)").printf(series);
                case TrendType.LOGARITHMIC: return _("Log. (%s)").printf(series);
                case TrendType.POLYNOMIAL: return _("Poly. (%s)").printf(series);
                case TrendType.POWER: return _("Power (%s)").printf(series);
                case TrendType.MOVING_AVERAGE: return _("%d per. Mov. Avg. (%s)").printf(t.period, series);
                default: return series;
            }
        }

        private static string top_level(string c) {
            int i = c.index_of_char('\x1f');
            return i >= 0 ? c.substring(0, i) : c;
        }

        private static string leaf_level(string c) {
            int i = c.last_index_of_char('\x1f');
            return i >= 0 ? c.substring(i + 1) : c;
        }

        private void draw_legend(Cairo.Context cr, ChartSpec spec, Box box) {
            if (spec.legend == LegendPosition.NONE) return;
            string[] colors;
            var labels = legend_labels(spec, out colors);
            bool single_series = spec.series.size == 1 && labels.length <= 1;
            if (labels.length == 0 || single_series) return;
            int limit = 12;
            bool vertical = spec.legend == LegendPosition.LEFT || spec.legend == LegendPosition.RIGHT;
            if (vertical) {
                double maxw = 0;
                double lh = 0;
                for (int i = 0; i < labels.length && i < limit; i++) {
                    var l = text(cr, labels[i], 11);
                    int tw, th;
                    l.get_pixel_size(out tw, out th);
                    maxw = double.max(maxw, double.min(tw, box.w * 0.3));
                    lh = th;
                }
                double lw = maxw + 20;
                double total_h = double.min(labels.length, limit) * (lh + 6);
                double lx = spec.legend == LegendPosition.RIGHT ? box.x + box.w - lw : box.x;
                double ly = box.y + double.max(0, (box.h - total_h) / 2);
                for (int i = 0; i < labels.length && i < limit; i++) {
                    rrect(cr, lx, ly + lh / 2 - 4, 8, 8, 2);
                    rgb(cr, colors[i]);
                    cr.fill();
                    var l = text(cr, labels[i], 11);
                    l.set_width((int) (maxw * Pango.SCALE));
                    l.set_ellipsize(Pango.EllipsizeMode.END);
                    cr.move_to(lx + 13, ly);
                    rgb(cr, ink2);
                    Pango.cairo_show_layout(cr, l);
                    ly += lh + 6;
                }
                if (spec.legend == LegendPosition.RIGHT) box.w -= lw + 10;
                else {
                    box.x += lw + 10;
                    box.w -= lw + 10;
                }
                return;
            }
            double lx = box.x;
            double row_h = 0;
            double used = 0;
            var rows = new Gee.ArrayList<double?>();
            double[] xs = {};
            double[] ys = {};
            double ly = 0;
            for (int i = 0; i < labels.length && i < limit; i++) {
                var l = text(cr, labels[i], 11);
                int tw, th;
                l.get_pixel_size(out tw, out th);
                row_h = th;
                if (lx + 14 + tw > box.x + box.w && lx > box.x) {
                    rows.add(lx - box.x);
                    lx = box.x;
                    ly += th + 6;
                }
                xs += lx;
                ys += ly;
                lx += 13 + tw + 14;
            }
            rows.add(lx - box.x);
            used = ly + row_h + 8;
            double base_y = spec.legend == LegendPosition.TOP ? box.y : box.y + box.h - used + 8;
            for (int i = 0; i < xs.length; i++) {
                int row = (int) (ys[i] / (row_h + 6) + 0.5);
                double row_w = row < rows.size ? rows[row] : 0;
                double shift = double.max(0, (box.w - row_w) / 2);
                double x = xs[i] + shift;
                double y = base_y + ys[i];
                rrect(cr, x, y + row_h / 2 - 4, 8, 8, 2);
                rgb(cr, colors[i]);
                cr.fill();
                show_text(cr, labels[i], 11, x + 13, y, ink2);
            }
            if (spec.legend == LegendPosition.TOP) box.y += used;
            box.h -= used;
        }

        private void draw_pie(Cairo.Context cr, ChartSpec spec, Box box) {
            var s = spec.series[0];
            var cats = spec.category_labels();
            double total = 0;
            foreach (double v in s.values) if (!v.is_nan() && v > 0) total += v;
            if (total <= 0) return;
            double r = double.min(box.w, box.h) / 2 - 4;
            double cx = box.x + box.w / 2, cy = box.y + box.h / 2;
            double angle = -Math.PI / 2 + spec.first_slice_angle * Math.PI / 180;
            bool doughnut = spec.kind == ChartType.DOUGHNUT;
            double hole = doughnut ? r * spec.hole_size.clamp(10, 90) / 100.0 : 0;
            for (int i = 0; i < s.values.length; i++) {
                double v = s.values[i];
                if (v.is_nan() || v <= 0) continue;
                double sweep = v / total * 2 * Math.PI;
                cr.new_path();
                if (doughnut) {
                    cr.arc(cx, cy, r, angle, angle + sweep);
                    cr.arc_negative(cx, cy, hole, angle + sweep, angle);
                } else {
                    cr.move_to(cx, cy);
                    cr.arc(cx, cy, r, angle, angle + sweep);
                }
                cr.close_path();
                rgb(cr, palette_color(i, dark));
                cr.fill_preserve();
                rgb(cr, surface);
                cr.set_line_width(2);
                cr.stroke();
                if (spec.data_labels || s.labels) {
                    double mid = angle + sweep / 2;
                    double lr = doughnut ? (r + hole) / 2 : r * 0.65;
                    string label = "%.0f%%".printf(v / total * 100);
                    if (i < cats.length && sweep > 0.5) label = cats[i] + "\n" + label;
                    var l = text(cr, label, 10, true);
                    l.set_alignment(Pango.Alignment.CENTER);
                    int tw, th;
                    l.get_pixel_size(out tw, out th);
                    cr.move_to(cx + Math.cos(mid) * lr - tw / 2.0, cy + Math.sin(mid) * lr - th / 2.0);
                    rgb(cr, "#ffffff");
                    Pango.cairo_show_layout(cr, l);
                }
                angle += sweep;
            }
        }

        private class Range {
            public double lo;
            public double hi;
            public double step;
            public bool log;
            public double log_base;

            public double frac(double v) {
                if (log) {
                    if (v <= 0) return 0;
                    double a = Math.log(lo) / Math.log(log_base), b = Math.log(hi) / Math.log(log_base);
                    return (Math.log(v) / Math.log(log_base) - a) / (b - a);
                }
                return (v - lo) / (hi - lo);
            }
        }

        private static Range make_range(double lo, double hi, Axis axis, int target, bool zero_based) {
            var r = new Range();
            if (lo == double.INFINITY) {
                lo = 0;
                hi = 1;
            }
            if (axis.log_base > 1) {
                r.log = true;
                r.log_base = axis.log_base;
                double b = axis.log_base;
                double mn = lo > 0 ? lo : 1;
                r.lo = axis.min.is_nan() ? Math.pow(b, Math.floor(Math.log(mn) / Math.log(b))) : axis.min;
                r.hi = axis.max.is_nan() ? Math.pow(b, Math.ceil(Math.log(double.max(hi, r.lo * b)) / Math.log(b))) : axis.max;
                if (r.hi <= r.lo) r.hi = r.lo * b;
                r.step = b;
                return r;
            }
            if (zero_based) {
                if (lo > 0) lo = 0;
                if (hi < 0) hi = 0;
            }
            if (!axis.min.is_nan()) lo = axis.min;
            if (!axis.max.is_nan()) hi = axis.max;
            if (hi <= lo) hi = lo + 1;
            double step = axis.major_unit.is_nan() || axis.major_unit <= 0 ? nice_step(hi - lo, target) : axis.major_unit;
            if ((hi - lo) / step > 200) step = nice_step(hi - lo, target);
            r.lo = axis.min.is_nan() ? Math.floor(lo / step) * step : lo;
            r.hi = axis.max.is_nan() ? Math.ceil(hi / step - 1e-9) * step : hi;
            if (r.hi <= r.lo) r.hi = r.lo + step;
            r.step = step;
            return r;
        }

        private double[] ticks(Range r) {
            double[] t = {};
            if (r.log) {
                for (double v = r.lo; v <= r.hi * 1.0001 && t.length < 40; v *= r.log_base) t += v;
                return t;
            }
            for (int i = 0; ; i++) {
                double v = r.lo + i * r.step;
                if (v > r.hi + r.step * 1e-6 || t.length > 60) break;
                t += Math.fabs(v) < r.step * 1e-9 ? 0 : v;
            }
            return t;
        }

        private void stack_extent(ChartSpec spec, bool secondary, Grouping grouping, out double lo, out double hi, bool bars_only) {
            lo = double.INFINITY;
            hi = -double.INFINITY;
            int n = spec.category_labels().length;
            bool stacked = grouping != Grouping.CLUSTERED;
            if (grouping == Grouping.PERCENT) {
                lo = 0;
                hi = 1;
                bool neg = false;
                foreach (var s in spec.series) if (s.secondary == secondary) foreach (double v in s.values) if (v < 0) neg = true;
                if (neg) lo = -1;
                return;
            }
            for (int j = 0; j < n; j++) {
                double pos = 0, negs = 0;
                foreach (var s in spec.series) {
                    if (s.secondary != secondary) continue;
                    var t = spec.type_of(s);
                    if (bars_only && !(t == ChartType.COLUMN || t == ChartType.BAR || t == ChartType.AREA)) continue;
                    if (j >= s.values.length) continue;
                    double v = s.values[j];
                    if (v.is_nan()) continue;
                    bool st = stacked && (t == ChartType.COLUMN || t == ChartType.BAR || t == ChartType.AREA);
                    if (st) {
                        if (v >= 0) pos += v;
                        else negs += v;
                    } else {
                        double eb = error_amount(s, j);
                        lo = double.min(lo, v - eb);
                        hi = double.max(hi, v + eb);
                    }
                }
                if (pos != 0 || negs != 0) {
                    lo = double.min(lo, negs);
                    hi = double.max(hi, pos);
                }
            }
        }

        private double error_amount(Series s, int j) {
            var e = s.error_bars;
            if (e == null || e.kind == ErrorBarType.NONE) return 0;
            double v = j < s.values.length ? s.values[j] : 0;
            switch (e.kind) {
                case ErrorBarType.FIXED: return e.amount;
                case ErrorBarType.PERCENT: return Math.fabs(v) * e.amount / 100;
                case ErrorBarType.STDDEV: return Stats.stdev(s.values) * e.amount;
                case ErrorBarType.STDERR:
                    var f = Stats.finite(s.values);
                    return f.length > 0 ? Stats.stdev(s.values) / Math.sqrt(f.length) : 0;
                default: return 0;
            }
        }

        private int text_width(Cairo.Context cr, string s, double size) {
            var l = text(cr, s, size);
            int tw, th;
            l.get_pixel_size(out tw, out th);
            return tw;
        }

        private void draw_axis_title(Cairo.Context cr, string t, double x, double y, bool vertical) {
            if (t == "") return;
            var l = text(cr, t, 11, true);
            int tw, th;
            l.get_pixel_size(out tw, out th);
            cr.save();
            if (vertical) {
                cr.translate(x, y);
                cr.rotate(-Math.PI / 2);
                cr.move_to(-tw / 2.0, 0);
            } else {
                cr.move_to(x - tw / 2.0, y);
            }
            rgb(cr, ink2);
            Pango.cairo_show_layout(cr, l);
            cr.restore();
        }

        private void draw_cartesian(Cairo.Context cr, ChartSpec spec, Box box) {
            bool horizontal = spec.kind == ChartType.BAR;
            bool xy = spec.kind == ChartType.SCATTER || spec.kind == ChartType.BUBBLE;
            var cats = spec.category_labels();
            int n = int.max(cats.length, 1);
            bool has_bars = false;
            foreach (var s in spec.series) {
                var t = spec.type_of(s);
                if (t == ChartType.COLUMN || t == ChartType.BAR) has_bars = true;
            }
            bool secondary = spec.has_secondary();
            double lo1, hi1, lo2 = 0, hi2 = 0;
            stack_extent(spec, false, spec.grouping, out lo1, out hi1, false);
            if (secondary) stack_extent(spec, true, spec.grouping, out lo2, out hi2, false);
            if (xy) {
                foreach (var s in spec.series) {
                    if (s.secondary) continue;
                    foreach (double v in s.values) if (!v.is_nan()) {
                        lo1 = double.min(lo1, v);
                        hi1 = double.max(hi1, v);
                    }
                }
            }
            if (lo1 == double.INFINITY) {
                lo1 = 0;
                hi1 = 1;
            }
            bool zero = has_bars || spec.kind == ChartType.AREA;
            if (!zero && lo1 > 0 && (hi1 - lo1) > hi1 * 0.5) lo1 = 0;
            var r1 = make_range(lo1, hi1, spec.y_axis, horizontal ? 4 : 5, zero);
            Range? r2 = secondary ? make_range(lo2 == double.INFINITY ? 0 : lo2, hi2 == -double.INFINITY ? 1 : hi2, spec.y2_axis, 5, has_bars) : null;
            Range? rx = null;
            if (xy) {
                double xl = double.INFINITY, xh = -double.INFINITY;
                foreach (var s in spec.series) {
                    for (int j = 0; j < s.values.length; j++) {
                        double xv = j < s.xvalues.length ? s.xvalues[j] : j + 1;
                        if (xv.is_nan()) continue;
                        xl = double.min(xl, xv);
                        xh = double.max(xh, xv);
                    }
                }
                if (xl != double.INFINITY && xl > 0 && (xh - xl) > xh * 0.5) xl = 0;
                rx = make_range(xl, xh == -double.INFINITY ? 1 : xh, spec.x_axis, 5, false);
            }
            string fmt1 = spec.y_axis.number_format;
            if (spec.grouping == Grouping.PERCENT && fmt1 == "") fmt1 = "0%";
            var t1 = ticks(r1);
            double[] t2 = r2 != null ? ticks(r2) : new double[0];
            int label_w = 0, label_w2 = 0;
            foreach (double t in t1) label_w = int.max(label_w, text_width(cr, value_label(t, fmt1), 10));
            foreach (double t in t2) label_w2 = int.max(label_w2, text_width(cr, value_label(t, spec.y2_axis.number_format), 10));
            int cat_w = 0;
            if (horizontal) foreach (string c in cats) cat_w = int.max(cat_w, int.min(text_width(cr, c, 10), 120));
            double left = box.x + (horizontal ? cat_w + 8 : label_w + 8) + (spec.y_axis.title != "" ? 18 : 0);
            double right = box.x + box.w - (r2 != null ? label_w2 + 10 + (spec.y2_axis.title != "" ? 18 : 0) : 4);
            double top = box.y + 4;
            double bottom = box.y + box.h - 22 - (spec.x_axis.title != "" ? 18 : 0);
            double pw = right - left, ph = bottom - top;
            if (pw < 20 || ph < 20) return;
            draw_axis_title(cr, spec.y_axis.title, box.x + 2, top + ph / 2, !horizontal);
            if (horizontal && spec.y_axis.title != "") draw_axis_title(cr, spec.y_axis.title, left + pw / 2, box.y + box.h - 16, false);
            if (spec.x_axis.title != "") {
                if (horizontal) draw_axis_title(cr, spec.x_axis.title, box.x + 2, top + ph / 2, true);
                else draw_axis_title(cr, spec.x_axis.title, left + pw / 2, box.y + box.h - 16, false);
            }
            if (r2 != null && spec.y2_axis.title != "") draw_axis_title(cr, spec.y2_axis.title, box.x + box.w - 14, top + ph / 2, true);
            foreach (double t in t1) {
                double f = r1.frac(t);
                var tl = text(cr, value_label(t, fmt1), 10);
                int tw, th;
                tl.get_pixel_size(out tw, out th);
                if (horizontal) {
                    double gx = Math.round(left + f * pw) + 0.5;
                    if (spec.y_axis.gridlines || t == 0) {
                        cr.move_to(gx, top);
                        cr.line_to(gx, bottom);
                        rgb(cr, t == 0 ? ink2 : grid, t == 0 ? 0.5 : 1);
                        cr.set_line_width(1);
                        cr.stroke();
                    }
                    if (spec.y_axis.visible) cr.move_to(gx - tw / 2.0, bottom + 6);
                } else {
                    double gy = Math.round(bottom - f * ph) + 0.5;
                    if (spec.y_axis.gridlines || t == 0) {
                        cr.move_to(left, gy);
                        cr.line_to(right, gy);
                        rgb(cr, t == 0 ? ink2 : grid, t == 0 ? 0.5 : 1);
                        cr.set_line_width(1);
                        cr.stroke();
                    }
                    if (spec.y_axis.visible) cr.move_to(left - tw - 8, gy - th / 2.0);
                }
                if (spec.y_axis.visible) {
                    rgb(cr, ink2);
                    Pango.cairo_show_layout(cr, tl);
                }
                cr.new_path();
            }
            if (r2 != null) {
                foreach (double t in t2) {
                    double gy = Math.round(bottom - r2.frac(t) * ph) + 0.5;
                    show_text(cr, value_label(t, spec.y2_axis.number_format), 10, right + 8, gy, ink2, false, 0, 0.5);
                }
            }
            if (xy) {
                foreach (double t in ticks(rx)) {
                    double gx = Math.round(left + rx.frac(t) * pw) + 0.5;
                    if (spec.x_axis.gridlines) {
                        cr.move_to(gx, top);
                        cr.line_to(gx, bottom);
                        rgb(cr, grid);
                        cr.set_line_width(1);
                        cr.stroke();
                    }
                    show_text(cr, value_label(t, spec.x_axis.number_format), 10, gx, bottom + 6, ink2, false, 0.5, 0);
                }
            } else {
                double band0 = (horizontal ? ph : pw) / n;
                int every = int.max(1, (int) Math.ceil(n * 46.0 / (horizontal ? ph : pw)));
                for (int j = 0; j < cats.length; j += (horizontal ? 1 : every)) {
                    int jj = spec.x_axis.reverse ? cats.length - 1 - j : j;
                    var cl = text(cr, leaf_level(cats[jj]), 10);
                    cl.set_ellipsize(Pango.EllipsizeMode.END);
                    cl.set_width((int) ((horizontal ? cat_w : band0 * every - 4) * Pango.SCALE));
                    int cw, ch;
                    cl.get_pixel_size(out cw, out ch);
                    if (horizontal) cr.move_to(box.x + (spec.y_axis.title != "" ? 0 : 0), top + band0 * j + (band0 - ch) / 2);
                    else cr.move_to(left + band0 * j + (band0 - cw) / 2, bottom + 6);
                    rgb(cr, ink2);
                    Pango.cairo_show_layout(cr, cl);
                }
            }
            double band = (horizontal ? ph : pw) / n;
            var bar_series = new Gee.ArrayList<int>();
            for (int i = 0; i < spec.series.size; i++) {
                var t = spec.type_of(spec.series[i]);
                if (!xy && (t == ChartType.COLUMN || t == ChartType.BAR)) bar_series.add(i);
            }
            for (int pass = 0; pass < 3; pass++) {
                for (int i = 0; i < spec.series.size; i++) {
                    var s = spec.series[i];
                    var t = xy ? spec.kind : spec.type_of(s);
                    var rr = s.secondary && r2 != null ? r2 : r1;
                    if (pass == 0 && t == ChartType.AREA) draw_area_series(cr, spec, i, rr, left, bottom, pw, ph, band, n);
                    if (pass == 1 && (t == ChartType.COLUMN || t == ChartType.BAR) && !xy) draw_bar_series(cr, spec, i, bar_series, rr, left, top, bottom, pw, ph, band, n, horizontal);
                    if (pass == 2 && (t == ChartType.LINE || xy)) draw_line_series(cr, spec, i, rr, rx, left, bottom, pw, ph, band, n, xy);
                }
            }
            for (int i = 0; i < spec.series.size; i++) {
                var s = spec.series[i];
                var rr = s.secondary && r2 != null ? r2 : r1;
                if (s.trendline != null && s.trendline.kind != TrendType.NONE && !horizontal) draw_trend(cr, spec, i, rr, rx, left, top, bottom, pw, ph, band, n, xy);
                if (s.error_bars != null && s.error_bars.kind != ErrorBarType.NONE && !horizontal && spec.grouping == Grouping.CLUSTERED) draw_error_bars(cr, spec, i, bar_series, rr, rx, left, bottom, pw, ph, band, n, xy);
            }
        }

        private string value_label(double v, string fmt) {
            if (fmt.has_suffix("%") && (formatter == null || fmt == "0%")) return "%.0f%%".printf(v * 100);
            return format_value(v, fmt);
        }

        private double stacked_base(ChartSpec spec, int series_index, int j, bool positive) {
            double base_v = 0;
            var me = spec.series[series_index];
            var mt = spec.type_of(me);
            for (int k = 0; k < series_index; k++) {
                var s = spec.series[k];
                if (s.secondary != me.secondary || spec.type_of(s) != mt || j >= s.values.length) continue;
                double v = s.values[j];
                if (v.is_nan()) continue;
                if ((v >= 0) == positive) base_v += v;
            }
            return base_v;
        }

        private double stack_total(ChartSpec spec, int series_index, int j) {
            double tot = 0;
            var me = spec.series[series_index];
            var mt = spec.type_of(me);
            foreach (var s in spec.series) {
                if (s.secondary != me.secondary || spec.type_of(s) != mt || j >= s.values.length) continue;
                double v = s.values[j];
                if (!v.is_nan()) tot += Math.fabs(v);
            }
            return tot;
        }

        private void draw_bar_series(Cairo.Context cr, ChartSpec spec, int i, Gee.ArrayList<int> bars, Range r, double left, double top, double bottom, double pw, double ph, double band, int n, bool horizontal) {
            var s = spec.series[i];
            bool stacked = spec.grouping != Grouping.CLUSTERED;
            bool percent = spec.grouping == Grouping.PERCENT;
            int ns = stacked ? 1 : bars.size;
            int idx = stacked ? 0 : bars.index_of(i);
            double inner = band / (1 + spec.gap_width.clamp(0, 500) / 100.0);
            double ov = spec.overlap.clamp(-100, 100) / 100.0;
            double bw = ns <= 1 ? inner : inner / (ns - (ns - 1) * ov);
            string color = series_color(spec, i);
            for (int j = 0; j < n && j < s.values.length; j++) {
                double v = s.values[j];
                if (v.is_nan()) continue;
                double base_v = stacked ? stacked_base(spec, i, j, v >= 0) : 0;
                double end_v = base_v + v;
                if (percent) {
                    double tot = stack_total(spec, i, j);
                    if (tot == 0) continue;
                    base_v /= tot;
                    end_v /= tot;
                }
                double f0 = r.frac(r.log ? (base_v <= 0 ? r.lo : base_v) : double.max(base_v, r.lo));
                double f1 = r.frac(end_v);
                f0 = f0.clamp(0, 1);
                f1 = f1.clamp(0, 1);
                int jj = spec.x_axis.reverse ? n - 1 - j : j;
                double start = band * jj + (band - inner) / 2 + idx * bw * (1 - ov);
                rgb(cr, color);
                bool top_seg = !stacked || is_top_segment(spec, i, j, v >= 0);
                if (horizontal) {
                    double x0 = left + double.min(f0, f1) * pw;
                    double x1 = left + double.max(f0, f1) * pw;
                    end_rounded(cr, x0, top + start, double.max(x1 - x0, 1), bw, top_seg ? 3 : 0, true, v >= 0);
                } else {
                    double y0 = bottom - double.max(f0, f1) * ph;
                    double y1 = bottom - double.min(f0, f1) * ph;
                    end_rounded(cr, left + start, y0, bw, double.max(y1 - y0, 1), top_seg ? 3 : 0, false, v >= 0);
                }
                cr.fill();
                if (spec.data_labels || s.labels) {
                    string lab = percent ? "%.0f%%".printf((end_v - base_v) * 100) : format_value(v, spec.y_axis.number_format);
                    if (horizontal) show_text(cr, lab, 9, left + double.max(f0, f1) * pw + 4, top + start + bw / 2, ink2, false, 0, 0.5);
                    else show_text(cr, lab, 9, left + start + bw / 2, bottom - double.max(f0, f1) * ph - 2, ink2, false, 0.5, 1);
                }
            }
        }

        private bool is_top_segment(ChartSpec spec, int i, int j, bool positive) {
            var me = spec.series[i];
            for (int k = i + 1; k < spec.series.size; k++) {
                var s = spec.series[k];
                if (s.secondary != me.secondary || spec.type_of(s) != spec.type_of(me) || j >= s.values.length) continue;
                double v = s.values[j];
                if (!v.is_nan() && v != 0 && (v >= 0) == positive) return false;
            }
            return true;
        }

        private void marker(Cairo.Context cr, MarkerStyle m, double x, double y, double size, string color) {
            if (m == MarkerStyle.NONE) return;
            cr.new_path();
            switch (m) {
                case MarkerStyle.SQUARE:
                    cr.rectangle(x - size, y - size, size * 2, size * 2);
                    break;
                case MarkerStyle.DIAMOND:
                    cr.move_to(x, y - size * 1.3);
                    cr.line_to(x + size * 1.3, y);
                    cr.line_to(x, y + size * 1.3);
                    cr.line_to(x - size * 1.3, y);
                    cr.close_path();
                    break;
                case MarkerStyle.TRIANGLE:
                    cr.move_to(x, y - size * 1.3);
                    cr.line_to(x + size * 1.2, y + size);
                    cr.line_to(x - size * 1.2, y + size);
                    cr.close_path();
                    break;
                default:
                    cr.arc(x, y, size, 0, 2 * Math.PI);
                    break;
            }
            rgb(cr, color);
            cr.fill_preserve();
            rgb(cr, surface);
            cr.set_line_width(1.5);
            cr.stroke();
        }

        private double point_x(ChartSpec spec, Series s, int j, Range? rx, double left, double pw, double band, int n, bool xy) {
            if (xy) {
                double xv = j < s.xvalues.length ? s.xvalues[j] : j + 1;
                return left + rx.frac(xv) * pw;
            }
            int jj = spec.x_axis.reverse ? n - 1 - j : j;
            return left + band * jj + band / 2;
        }

        private void draw_line_series(Cairo.Context cr, ChartSpec spec, int i, Range r, Range? rx, double left, double bottom, double pw, double ph, double band, int n, bool xy) {
            var s = spec.series[i];
            string color = series_color(spec, i);
            bool bubble = spec.kind == ChartType.BUBBLE;
            bool stacked = spec.grouping != Grouping.CLUSTERED && !xy;
            bool draw_line = !xy || spec.lines_on_scatter || s.smooth;
            if (bubble) draw_line = false;
            double[] px = {};
            double[] py = {};
            int count = xy ? s.values.length : int.min(n, s.values.length);
            for (int j = 0; j < count; j++) {
                double v = s.values[j];
                if (v.is_nan()) {
                    px += double.NAN;
                    py += double.NAN;
                    continue;
                }
                if (stacked) {
                    double b = stacked_base(spec, i, j, v >= 0);
                    v += b;
                    if (spec.grouping == Grouping.PERCENT) {
                        double tot = stack_total(spec, i, j);
                        v = tot != 0 ? v / tot : 0;
                    }
                }
                double x = point_x(spec, s, j, rx, left, pw, band, n, xy);
                if (x.is_nan()) {
                    px += double.NAN;
                    py += double.NAN;
                    continue;
                }
                px += x;
                py += bottom - r.frac(v).clamp(-0.05, 1.05) * ph;
            }
            if (draw_line) {
                cr.new_path();
                bool started = false;
                for (int j = 0; j < px.length; j++) {
                    if (px[j].is_nan()) {
                        started = false;
                        continue;
                    }
                    if (!started) {
                        cr.move_to(px[j], py[j]);
                        started = true;
                    } else if (s.smooth || spec.smooth) {
                        int p = j - 1;
                        while (p > 0 && px[p].is_nan()) p--;
                        double cx1 = px[p] + (px[j] - px[p]) / 2;
                        cr.curve_to(cx1, py[p], cx1, py[j], px[j], py[j]);
                    } else {
                        cr.line_to(px[j], py[j]);
                    }
                }
                rgb(cr, color);
                cr.set_line_width(s.line_width > 0 ? s.line_width : 2);
                cr.set_line_join(Cairo.LineJoin.ROUND);
                cr.set_line_cap(Cairo.LineCap.ROUND);
                cr.stroke();
            }
            if (bubble) {
                double maxs = 0;
                foreach (double z in s.sizes) if (!z.is_nan()) maxs = double.max(maxs, Math.fabs(z));
                foreach (var other in spec.series) foreach (double z in other.sizes) if (!z.is_nan()) maxs = double.max(maxs, Math.fabs(z));
                for (int j = 0; j < px.length; j++) {
                    if (px[j].is_nan()) continue;
                    double z = j < s.sizes.length && !s.sizes[j].is_nan() ? Math.fabs(s.sizes[j]) : 1;
                    double rad = maxs > 0 ? 4 + Math.sqrt(z / maxs) * double.min(pw, ph) * 0.08 : 6;
                    cr.new_path();
                    cr.arc(px[j], py[j], rad, 0, 2 * Math.PI);
                    rgb(cr, color, 0.55);
                    cr.fill_preserve();
                    rgb(cr, color);
                    cr.set_line_width(1.5);
                    cr.stroke();
                }
                return;
            }
            var m = s.marker;
            bool show_markers = m != MarkerStyle.NONE && (xy || (spec.markers && px.length <= 60) || (m != MarkerStyle.AUTO));
            if (show_markers) {
                MarkerStyle ms = m == MarkerStyle.AUTO ? (MarkerStyle) (MarkerStyle.CIRCLE + i % 4) : m;
                if (m == MarkerStyle.AUTO && !xy) ms = MarkerStyle.CIRCLE;
                for (int j = 0; j < px.length; j++) if (!px[j].is_nan()) marker(cr, ms, px[j], py[j], 3.5, color);
            }
            if (spec.data_labels || s.labels) {
                for (int j = 0; j < px.length; j++) {
                    if (px[j].is_nan()) continue;
                    show_text(cr, format_value(s.values[j], spec.y_axis.number_format), 9, px[j], py[j] - 6, ink2, false, 0.5, 1);
                }
            }
        }

        private void draw_area_series(Cairo.Context cr, ChartSpec spec, int i, Range r, double left, double bottom, double pw, double ph, double band, int n) {
            var s = spec.series[i];
            bool stacked = spec.grouping != Grouping.CLUSTERED;
            string color = series_color(spec, i);
            double[] tops = {};
            double[] bases = {};
            double[] xs = {};
            for (int j = 0; j < n && j < s.values.length; j++) {
                double v = s.values[j].is_nan() ? 0 : s.values[j];
                double b = stacked ? stacked_base(spec, i, j, true) + stacked_base(spec, i, j, false) : 0;
                double tv = b + v;
                if (spec.grouping == Grouping.PERCENT) {
                    double tot = stack_total(spec, i, j);
                    b = tot != 0 ? b / tot : 0;
                    tv = tot != 0 ? tv / tot : 0;
                }
                xs += point_x(spec, s, j, null, left, pw, band, n, false);
                tops += bottom - r.frac(tv).clamp(0, 1) * ph;
                bases += bottom - r.frac(r.log ? r.lo : double.max(b, r.lo)).clamp(0, 1) * ph;
            }
            if (xs.length == 0) return;
            cr.new_path();
            cr.move_to(xs[0], tops[0]);
            for (int j = 1; j < xs.length; j++) cr.line_to(xs[j], tops[j]);
            for (int j = xs.length - 1; j >= 0; j--) cr.line_to(xs[j], bases[j]);
            cr.close_path();
            rgb(cr, color, stacked ? 0.75 : 0.35);
            cr.fill();
            cr.move_to(xs[0], tops[0]);
            for (int j = 1; j < xs.length; j++) cr.line_to(xs[j], tops[j]);
            rgb(cr, color);
            cr.set_line_width(2);
            cr.stroke();
        }

        private void draw_trend(Cairo.Context cr, ChartSpec spec, int i, Range r, Range? rx, double left, double top, double bottom, double pw, double ph, double band, int n, bool xy) {
            var s = spec.series[i];
            var t = s.trendline;
            double[] xs = {};
            for (int j = 0; j < s.values.length; j++) xs += xy ? (j < s.xvalues.length ? s.xvalues[j] : j + 1) : j + 1;
            string color = series_color(spec, i);
            cr.save();
            cr.rectangle(left, top, pw, bottom - top);
            cr.clip();
            cr.new_path();
            if (t.kind == TrendType.MOVING_AVERAGE) {
                var ma = TrendFit.moving_average(s.values, int.max(2, t.period));
                bool started = false;
                for (int j = 0; j < ma.length; j++) {
                    if (ma[j].is_nan()) continue;
                    double x = point_x(spec, s, j, rx, left, pw, band, n, xy);
                    double y = bottom - r.frac(ma[j]) * ph;
                    if (!started) cr.move_to(x, y);
                    else cr.line_to(x, y);
                    started = true;
                }
            } else {
                var fit = TrendFit.fit(t.kind, xs, s.values, t.order);
                if (!fit.valid) {
                    cr.restore();
                    return;
                }
                double x0 = double.INFINITY, x1 = -double.INFINITY;
                foreach (double x in xs) {
                    x0 = double.min(x0, x);
                    x1 = double.max(x1, x);
                }
                x0 -= t.backward;
                x1 += t.forward;
                bool started = false;
                for (int k = 0; k <= 80; k++) {
                    double xv = x0 + (x1 - x0) * k / 80.0;
                    double yv = fit.predict(xv);
                    if (yv.is_nan()) continue;
                    double px = xy ? left + rx.frac(xv) * pw : left + band * (xv - 1) + band / 2;
                    double py = bottom - r.frac(yv) * ph;
                    if (!started) cr.move_to(px, py);
                    else cr.line_to(px, py);
                    started = true;
                }
                if (t.show_equation || t.show_r2) {
                    string label = "";
                    if (t.show_equation) label = fit.equation();
                    if (t.show_r2) label += (label != "" ? "\n" : "") + "R² = %.4f".printf(fit.r2);
                    var l = text(cr, label, 10);
                    int tw, th;
                    l.get_pixel_size(out tw, out th);
                    double lx = left + 8;
                    double ly = top + 4 + i * (th + 4);
                    var path = cr.copy_path();
                    cr.new_path();
                    rrect(cr, lx - 4, ly - 2, tw + 8, th + 4, 4);
                    rgb(cr, surface, 0.85);
                    cr.fill();
                    cr.move_to(lx, ly);
                    rgb(cr, color);
                    Pango.cairo_show_layout(cr, l);
                    cr.new_path();
                    cr.append_path(path);
                }
            }
            rgb(cr, color);
            cr.set_line_width(1.5);
            double[] dash = { 5, 4 };
            cr.set_dash(dash, 0);
            cr.stroke();
            cr.restore();
        }

        private void draw_error_bars(Cairo.Context cr, ChartSpec spec, int i, Gee.ArrayList<int> bars, Range r, Range? rx, double left, double bottom, double pw, double ph, double band, int n, bool xy) {
            var s = spec.series[i];
            int bi = bars.index_of(i);
            double inner = band / (1 + spec.gap_width.clamp(0, 500) / 100.0);
            double bw = bars.size > 0 ? inner / bars.size : 0;
            rgb(cr, ink2);
            cr.set_line_width(1);
            for (int j = 0; j < s.values.length && (xy || j < n); j++) {
                double v = s.values[j];
                if (v.is_nan()) continue;
                double e = error_amount(s, j);
                double x = bi >= 0 ? left + band * j + (band - inner) / 2 + bi * bw + bw / 2 : point_x(spec, s, j, rx, left, pw, band, n, xy);
                double y0 = bottom - r.frac(v - e) * ph;
                double y1 = bottom - r.frac(v + e) * ph;
                cr.move_to(x, y0);
                cr.line_to(x, y1);
                cr.move_to(x - 4, y0);
                cr.line_to(x + 4, y0);
                cr.move_to(x - 4, y1);
                cr.line_to(x + 4, y1);
                cr.stroke();
            }
        }

        private void simple_value_axis(Cairo.Context cr, Range r, string fmt, double left, double right, double top, double bottom) {
            double ph = bottom - top;
            foreach (double t in ticks(r)) {
                double gy = Math.round(bottom - r.frac(t) * ph) + 0.5;
                cr.move_to(left, gy);
                cr.line_to(right, gy);
                rgb(cr, t == 0 ? ink2 : grid, t == 0 ? 0.5 : 1);
                cr.set_line_width(1);
                cr.stroke();
                show_text(cr, value_label(t, fmt), 10, left - 8, gy, ink2, false, 1, 0.5);
            }
        }

        private int axis_label_width(Cairo.Context cr, Range r, string fmt) {
            int w = 0;
            foreach (double t in ticks(r)) w = int.max(w, text_width(cr, value_label(t, fmt), 10));
            return w;
        }

        private void category_labels(Cairo.Context cr, string[] cats, double left, double pw, double bottom) {
            int n = int.max(cats.length, 1);
            double band = pw / n;
            int every = int.max(1, (int) Math.ceil(n * 46.0 / pw));
            for (int j = 0; j < cats.length; j += every) {
                var cl = text(cr, cats[j], 10);
                cl.set_ellipsize(Pango.EllipsizeMode.END);
                cl.set_width((int) ((band * every - 4) * Pango.SCALE));
                int cw, ch;
                cl.get_pixel_size(out cw, out ch);
                cr.move_to(left + band * j + (band - cw) / 2, bottom + 6);
                rgb(cr, ink2);
                Pango.cairo_show_layout(cr, cl);
            }
        }

        private void draw_histogram(Cairo.Context cr, ChartSpec spec, Box box) {
            double[] all = {};
            foreach (var s in spec.series) foreach (double v in s.values) all += v;
            var edges = Stats.bin_edges(all, spec.bins, spec.bin_width);
            if (edges.length < 2) return;
            var counts = Stats.histogram(all, edges);
            string[] cats = {};
            for (int b = 0; b < counts.length; b++) {
                cats += (b == 0 ? "[" : "(") + format_value(edges[b], spec.x_axis.number_format) + ", " + format_value(edges[b + 1], spec.x_axis.number_format) + "]";
            }
            int[] order = new int[counts.length];
            for (int b = 0; b < counts.length; b++) order[b] = b;
            bool pareto = spec.kind == ChartType.PARETO;
            if (pareto) {
                var cats_p = spec.category_labels();
                if (spec.series.size > 0 && cats_p.length == spec.series[0].values.length) {
                    draw_pareto_categories(cr, spec, box);
                    return;
                }
                for (int a = 0; a < order.length; a++) for (int b2 = a + 1; b2 < order.length; b2++) if (counts[order[b2]] > counts[order[a]]) {
                    int t = order[a];
                    order[a] = order[b2];
                    order[b2] = t;
                }
            }
            double[] vals = {};
            string[] labels = {};
            foreach (int b in order) {
                vals += counts[b];
                labels += cats[b];
            }
            draw_simple_columns(cr, spec, box, vals, labels, 0, pareto);
        }

        private void draw_pareto_categories(Cairo.Context cr, ChartSpec spec, Box box) {
            var s = spec.series[0];
            var cats = spec.category_labels();
            int[] order = {};
            for (int j = 0; j < s.values.length; j++) order += j;
            for (int a = 0; a < order.length; a++) for (int b = a + 1; b < order.length; b++) {
                double va = s.values[order[a]].is_nan() ? 0 : s.values[order[a]];
                double vb = s.values[order[b]].is_nan() ? 0 : s.values[order[b]];
                if (vb > va) {
                    int t = order[a];
                    order[a] = order[b];
                    order[b] = t;
                }
            }
            double[] vals = {};
            string[] labels = {};
            foreach (int j in order) {
                vals += s.values[j].is_nan() ? 0 : s.values[j];
                labels += j < cats.length ? cats[j] : (j + 1).to_string();
            }
            draw_simple_columns(cr, spec, box, vals, labels, 0, true);
        }

        private void draw_simple_columns(Cairo.Context cr, ChartSpec spec, Box box, double[] vals, string[] labels, int color_index, bool cumulative) {
            double hi = 0;
            foreach (double v in vals) hi = double.max(hi, v);
            var r = make_range(0, hi, spec.y_axis, 5, true);
            int lw = axis_label_width(cr, r, spec.y_axis.number_format);
            double left = box.x + lw + 8;
            double right = box.x + box.w - (cumulative ? 40 : 4);
            double top = box.y + 4;
            double bottom = box.y + box.h - 22;
            double pw = right - left, ph = bottom - top;
            if (pw < 20 || ph < 20) return;
            simple_value_axis(cr, r, spec.y_axis.number_format, left, right, top, bottom);
            category_labels(cr, labels, left, pw, bottom);
            int n = int.max(vals.length, 1);
            double band = pw / n;
            double gap = spec.kind == ChartType.HISTOGRAM || spec.kind == ChartType.PARETO ? band * 0.04 : band * 0.2;
            for (int j = 0; j < vals.length; j++) {
                double y0 = bottom - r.frac(vals[j]) * ph;
                rgb(cr, series_color(spec, color_index));
                end_rounded(cr, left + band * j + gap / 2, y0, band - gap, bottom - y0, 2, false, true);
                cr.fill();
                if (spec.data_labels) show_text(cr, format_value(vals[j], ""), 9, left + band * j + band / 2, y0 - 2, ink2, false, 0.5, 1);
            }
            if (cumulative) {
                double total = 0;
                foreach (double v in vals) total += v;
                if (total <= 0) return;
                double acc = 0;
                cr.new_path();
                double[] ptx = {};
                double[] pty = {};
                for (int j = 0; j < vals.length; j++) {
                    acc += vals[j];
                    double x = left + band * j + band / 2;
                    double y = bottom - acc / total * ph;
                    if (j == 0) cr.move_to(x, y);
                    else cr.line_to(x, y);
                    ptx += x;
                    pty += y;
                }
                string c2 = palette_color(1, dark);
                rgb(cr, c2);
                cr.set_line_width(2);
                cr.stroke();
                for (int j = 0; j < ptx.length; j++) marker(cr, MarkerStyle.CIRCLE, ptx[j], pty[j], 3, c2);
                for (int k = 0; k <= 4; k++) show_text(cr, "%d%%".printf(k * 25), 10, right + 8, bottom - k / 4.0 * ph, ink2, false, 0, 0.5);
            }
        }

        private void draw_waterfall(Cairo.Context cr, ChartSpec spec, Box box) {
            var s = spec.series[0];
            var cats = spec.category_labels();
            double run = 0, lo = 0, hi = 0;
            foreach (double v in s.values) {
                if (v.is_nan()) continue;
                run += v;
                lo = double.min(lo, run);
                hi = double.max(hi, run);
            }
            var r = make_range(lo, hi, spec.y_axis, 5, true);
            int lw = axis_label_width(cr, r, spec.y_axis.number_format);
            double left = box.x + lw + 8, right = box.x + box.w - 4, top = box.y + 4, bottom = box.y + box.h - 22;
            double pw = right - left, ph = bottom - top;
            if (pw < 20 || ph < 20) return;
            simple_value_axis(cr, r, spec.y_axis.number_format, left, right, top, bottom);
            category_labels(cr, cats, left, pw, bottom);
            int n = int.max(s.values.length, 1);
            double band = pw / n;
            double gap = band / (1 + spec.gap_width.clamp(0, 500) / 100.0);
            run = 0;
            double prev_y = double.NAN;
            for (int j = 0; j < s.values.length; j++) {
                double v = s.values[j];
                if (v.is_nan()) continue;
                double start = run;
                run += v;
                double y0 = bottom - r.frac(double.max(start, run)) * ph;
                double y1 = bottom - r.frac(double.min(start, run)) * ph;
                double x = left + band * j + (band - gap) / 2;
                rgb(cr, v >= 0 ? palette_color(2, dark) : palette_color(7, dark));
                cr.rectangle(x, y0, gap, double.max(y1 - y0, 1));
                cr.fill();
                if (!prev_y.is_nan()) {
                    cr.move_to(x - (band - gap), Math.round(prev_y) + 0.5);
                    cr.line_to(x, Math.round(prev_y) + 0.5);
                    rgb(cr, ink2, 0.6);
                    cr.set_line_width(1);
                    cr.stroke();
                }
                prev_y = bottom - r.frac(run) * ph;
                if (spec.data_labels) show_text(cr, format_value(v, spec.y_axis.number_format), 9, x + gap / 2, y0 - 2, ink2, false, 0.5, 1);
            }
        }

        private void draw_funnel(Cairo.Context cr, ChartSpec spec, Box box) {
            var s = spec.series[0];
            var cats = spec.category_labels();
            double mx = 0;
            foreach (double v in s.values) if (!v.is_nan()) mx = double.max(mx, v);
            if (mx <= 0) return;
            int n = s.values.length;
            int cat_w = 0;
            foreach (string c in cats) cat_w = int.max(cat_w, int.min(text_width(cr, c, 10), 120));
            double left = box.x + cat_w + 10;
            double pw = box.w - cat_w - 10;
            double band = box.h / int.max(n, 1);
            for (int j = 0; j < n; j++) {
                double v = s.values[j];
                if (v.is_nan() || v < 0) continue;
                double bw = v / mx * pw;
                double y = box.y + band * j + band * 0.1;
                rgb(cr, palette_color(spec.vary_colors ? j : 0, dark));
                rrect(cr, left + (pw - bw) / 2, y, double.max(bw, 1), band * 0.8, 3);
                cr.fill();
                show_text(cr, format_value(v, spec.y_axis.number_format), 10, left + pw / 2, y + band * 0.4, "#ffffff", true, 0.5, 0.5);
                if (j < cats.length) show_text(cr, cats[j], 10, box.x, y + band * 0.4, ink2, false, 0, 0.5);
            }
        }

        private void draw_box(Cairo.Context cr, ChartSpec spec, Box box) {
            double lo = double.INFINITY, hi = -double.INFINITY;
            foreach (var s in spec.series) foreach (double v in s.values) if (!v.is_nan()) {
                lo = double.min(lo, v);
                hi = double.max(hi, v);
            }
            if (lo == double.INFINITY) return;
            var r = make_range(lo, hi, spec.y_axis, 5, false);
            int lw = axis_label_width(cr, r, spec.y_axis.number_format);
            double left = box.x + lw + 8, right = box.x + box.w - 4, top = box.y + 4, bottom = box.y + box.h - 22;
            double pw = right - left, ph = bottom - top;
            if (pw < 20 || ph < 20) return;
            simple_value_axis(cr, r, spec.y_axis.number_format, left, right, top, bottom);
            string[] names = {};
            for (int i = 0; i < spec.series.size; i++) names += spec.series[i].name != "" ? spec.series[i].name : _("Series %d").printf(i + 1);
            category_labels(cr, names, left, pw, bottom);
            double band = pw / int.max(spec.series.size, 1);
            for (int i = 0; i < spec.series.size; i++) {
                var sv = Stats.sorted(spec.series[i].values);
                if (sv.length == 0) continue;
                double q1 = Stats.quartile_exc(sv, 0.25), q2 = Stats.quartile_exc(sv, 0.5), q3 = Stats.quartile_exc(sv, 0.75);
                double iqr = q3 - q1;
                double wl = q1, wh = q3;
                foreach (double v in sv) {
                    if (v >= q1 - 1.5 * iqr && v < wl) wl = v;
                    if (v <= q3 + 1.5 * iqr && v > wh) wh = v;
                }
                double cx = left + band * i + band / 2;
                double bw = band * 0.45;
                string c = series_color(spec, i);
                double y1 = bottom - r.frac(q1) * ph, y3 = bottom - r.frac(q3) * ph, y2 = bottom - r.frac(q2) * ph;
                rgb(cr, c, 0.3);
                cr.rectangle(cx - bw / 2, y3, bw, y1 - y3);
                cr.fill_preserve();
                rgb(cr, c);
                cr.set_line_width(1.5);
                cr.stroke();
                cr.move_to(cx - bw / 2, y2);
                cr.line_to(cx + bw / 2, y2);
                cr.move_to(cx, y3);
                cr.line_to(cx, bottom - r.frac(wh) * ph);
                cr.move_to(cx, y1);
                cr.line_to(cx, bottom - r.frac(wl) * ph);
                cr.move_to(cx - bw / 4, bottom - r.frac(wh) * ph);
                cr.line_to(cx + bw / 4, bottom - r.frac(wh) * ph);
                cr.move_to(cx - bw / 4, bottom - r.frac(wl) * ph);
                cr.line_to(cx + bw / 4, bottom - r.frac(wl) * ph);
                cr.stroke();
                double mean = Stats.mean(sv);
                double my = bottom - r.frac(mean) * ph;
                cr.move_to(cx - 4, my - 4);
                cr.line_to(cx + 4, my + 4);
                cr.move_to(cx + 4, my - 4);
                cr.line_to(cx - 4, my + 4);
                cr.stroke();
                foreach (double v in sv) if (v < wl || v > wh) marker(cr, MarkerStyle.CIRCLE, cx, bottom - r.frac(v) * ph, 2.5, c);
            }
        }

        private void draw_stock(Cairo.Context cr, ChartSpec spec, Box box) {
            int ns = spec.series.size;
            bool ohlc = ns >= 4;
            if (ns < 3) {
                draw_cartesian(cr, spec, box);
                return;
            }
            var cats = spec.category_labels();
            double lo = double.INFINITY, hi = -double.INFINITY;
            foreach (var s in spec.series) foreach (double v in s.values) if (!v.is_nan()) {
                lo = double.min(lo, v);
                hi = double.max(hi, v);
            }
            var r = make_range(lo, hi, spec.y_axis, 5, false);
            int lw = axis_label_width(cr, r, spec.y_axis.number_format);
            double left = box.x + lw + 8, right = box.x + box.w - 4, top = box.y + 4, bottom = box.y + box.h - 22;
            double pw = right - left, ph = bottom - top;
            if (pw < 20 || ph < 20) return;
            simple_value_axis(cr, r, spec.y_axis.number_format, left, right, top, bottom);
            category_labels(cr, cats, left, pw, bottom);
            int n = int.max(cats.length, 1);
            double band = pw / n;
            var o = ohlc ? spec.series[0].values : null;
            var hs = spec.series[ohlc ? 1 : 0].values;
            var ls = spec.series[ohlc ? 2 : 1].values;
            var cs = spec.series[ohlc ? 3 : 2].values;
            for (int j = 0; j < n; j++) {
                double x = left + band * j + band / 2;
                if (j < hs.length && j < ls.length && !hs[j].is_nan() && !ls[j].is_nan()) {
                    cr.move_to(Math.round(x) + 0.5, bottom - r.frac(hs[j]) * ph);
                    cr.line_to(Math.round(x) + 0.5, bottom - r.frac(ls[j]) * ph);
                    rgb(cr, ink2);
                    cr.set_line_width(1);
                    cr.stroke();
                }
                if (j >= cs.length || cs[j].is_nan()) continue;
                if (ohlc && j < o.length && !o[j].is_nan()) {
                    double yo = bottom - r.frac(o[j]) * ph, yc = bottom - r.frac(cs[j]) * ph;
                    double bw = band * 0.5;
                    cr.rectangle(x - bw / 2, double.min(yo, yc), bw, double.max(Math.fabs(yc - yo), 1));
                    bool up = cs[j] >= o[j];
                    rgb(cr, up ? palette_color(2, dark) : palette_color(7, dark));
                    cr.fill();
                } else {
                    double yc = bottom - r.frac(cs[j]) * ph;
                    cr.move_to(x, yc);
                    cr.line_to(x + band * 0.25, yc);
                    rgb(cr, palette_color(0, dark));
                    cr.set_line_width(2);
                    cr.stroke();
                }
            }
        }

        private void draw_radar(Cairo.Context cr, ChartSpec spec, Box box) {
            var cats = spec.category_labels();
            int n = cats.length;
            if (n < 3) {
                draw_cartesian(cr, spec, box);
                return;
            }
            double hi = 0, lo = 0;
            foreach (var s in spec.series) foreach (double v in s.values) if (!v.is_nan()) {
                hi = double.max(hi, v);
                lo = double.min(lo, v);
            }
            var r = make_range(lo, hi, spec.y_axis, 4, true);
            double rad = double.min(box.w, box.h) / 2 - 22;
            double cx = box.x + box.w / 2, cy = box.y + box.h / 2;
            foreach (double t in ticks(r)) {
                double rr = r.frac(t) * rad;
                cr.new_path();
                for (int j = 0; j <= n; j++) {
                    double a = -Math.PI / 2 + 2 * Math.PI * (j % n) / n;
                    if (j == 0) cr.move_to(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr);
                    else cr.line_to(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr);
                }
                rgb(cr, grid);
                cr.set_line_width(1);
                cr.stroke();
                show_text(cr, value_label(t, spec.y_axis.number_format), 9, cx + 3, cy - rr, ink2, false, 0, 0.5);
            }
            for (int j = 0; j < n; j++) {
                double a = -Math.PI / 2 + 2 * Math.PI * j / n;
                cr.move_to(cx, cy);
                cr.line_to(cx + Math.cos(a) * rad, cy + Math.sin(a) * rad);
                rgb(cr, grid);
                cr.stroke();
                double lx = cx + Math.cos(a) * (rad + 10), ly = cy + Math.sin(a) * (rad + 10);
                show_text(cr, cats[j], 10, lx, ly, ink2, false, Math.cos(a) < -0.3 ? 1 : (Math.cos(a) > 0.3 ? 0 : 0.5), 0.5);
            }
            for (int i = 0; i < spec.series.size; i++) {
                var s = spec.series[i];
                string c = series_color(spec, i);
                cr.new_path();
                for (int j = 0; j <= n; j++) {
                    int jj = j % n;
                    double v = jj < s.values.length && !s.values[jj].is_nan() ? s.values[jj] : r.lo;
                    double a = -Math.PI / 2 + 2 * Math.PI * jj / n;
                    double rr = r.frac(v) * rad;
                    if (j == 0) cr.move_to(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr);
                    else cr.line_to(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr);
                }
                if (spec.filled_radar) {
                    rgb(cr, c, 0.3);
                    cr.fill_preserve();
                }
                rgb(cr, c);
                cr.set_line_width(2);
                cr.stroke();
            }
        }

        private class TreeItem {
            public string label;
            public double value;
            public int color;
            public double x;
            public double y;
            public double w;
            public double h;
        }

        private static void squarify(Gee.ArrayList<TreeItem> items, double x, double y, double w, double h) {
            double total = 0;
            foreach (var it in items) total += it.value;
            if (total <= 0 || items.size == 0) return;
            int i = 0;
            while (i < items.size) {
                double remaining = 0;
                for (int k = i; k < items.size; k++) remaining += items[k].value;
                bool wide = w >= h;
                double side = wide ? h : w;
                double area_scale = w * h / remaining;
                int end = i;
                double row_sum = 0;
                double best = double.INFINITY;
                while (end < items.size) {
                    double trial = row_sum + items[end].value;
                    double row_len = trial * area_scale / side;
                    double worst = 0;
                    for (int k = i; k <= end; k++) {
                        double len = items[k].value * area_scale / row_len;
                        double ratio = double.max(row_len / len, len / row_len);
                        worst = double.max(worst, ratio);
                    }
                    if (worst > best) break;
                    best = worst;
                    row_sum = trial;
                    end++;
                }
                double thickness = row_sum * area_scale / side;
                double off = 0;
                for (int k = i; k < end; k++) {
                    double len = items[k].value * area_scale / thickness;
                    if (wide) {
                        items[k].x = x;
                        items[k].y = y + off;
                        items[k].w = thickness;
                        items[k].h = len;
                    } else {
                        items[k].x = x + off;
                        items[k].y = y;
                        items[k].w = len;
                        items[k].h = thickness;
                    }
                    off += len;
                }
                if (wide) {
                    x += thickness;
                    w -= thickness;
                } else {
                    y += thickness;
                    h -= thickness;
                }
                i = end;
            }
        }

        private void draw_treemap(Cairo.Context cr, ChartSpec spec, Box box) {
            var s = spec.series[0];
            var cats = spec.category_labels();
            var items = new Gee.ArrayList<TreeItem>();
            string[] parents = {};
            for (int j = 0; j < s.values.length; j++) {
                double v = s.values[j];
                if (v.is_nan() || v <= 0) continue;
                var it = new TreeItem();
                string c = j < cats.length ? cats[j] : (j + 1).to_string();
                it.label = leaf_level(c);
                it.value = v;
                string p = top_level(c);
                int pi = -1;
                for (int k = 0; k < parents.length; k++) if (parents[k] == p) pi = k;
                if (pi < 0) {
                    parents += p;
                    pi = parents.length - 1;
                }
                it.color = pi;
                items.add(it);
            }
            items.sort((a, b) => a.value > b.value ? -1 : (a.value < b.value ? 1 : 0));
            squarify(items, box.x, box.y, box.w, box.h);
            foreach (var it in items) {
                rgb(cr, palette_color(it.color, dark));
                cr.rectangle(it.x + 1, it.y + 1, double.max(it.w - 2, 0), double.max(it.h - 2, 0));
                cr.fill();
                if (it.w > 30 && it.h > 16) {
                    cr.save();
                    cr.rectangle(it.x, it.y, it.w, it.h);
                    cr.clip();
                    show_text(cr, it.label + "\n" + format_value(it.value, spec.y_axis.number_format), 10, it.x + 5, it.y + 4, "#ffffff", true);
                    cr.restore();
                }
            }
        }

        private void draw_sunburst(Cairo.Context cr, ChartSpec spec, Box box) {
            var s = spec.series[0];
            var cats = spec.category_labels();
            double total = 0;
            foreach (double v in s.values) if (!v.is_nan() && v > 0) total += v;
            if (total <= 0) return;
            double rad = double.min(box.w, box.h) / 2 - 4;
            double cx = box.x + box.w / 2, cy = box.y + box.h / 2;
            bool two = false;
            foreach (string c in cats) if (c.index_of_char('\x1f') >= 0) two = true;
            double inner0 = rad * 0.2, mid = two ? rad * 0.58 : rad;
            string[] parents = {};
            double[] psum = {};
            for (int j = 0; j < s.values.length; j++) {
                double v = s.values[j];
                if (v.is_nan() || v <= 0) continue;
                string p = top_level(j < cats.length ? cats[j] : (j + 1).to_string());
                int pi = -1;
                for (int k = 0; k < parents.length; k++) if (parents[k] == p) pi = k;
                if (pi < 0) {
                    parents += p;
                    psum += v;
                } else {
                    psum[pi] += v;
                }
            }
            double angle = -Math.PI / 2;
            for (int k = 0; k < parents.length; k++) {
                double sweep = psum[k] / total * 2 * Math.PI;
                cr.new_path();
                cr.arc(cx, cy, mid, angle, angle + sweep);
                cr.arc_negative(cx, cy, inner0, angle + sweep, angle);
                cr.close_path();
                rgb(cr, palette_color(k, dark));
                cr.fill_preserve();
                rgb(cr, surface);
                cr.set_line_width(2);
                cr.stroke();
                if (sweep > 0.3) {
                    double m = angle + sweep / 2, lr = (mid + inner0) / 2;
                    show_text(cr, parents[k], 10, cx + Math.cos(m) * lr, cy + Math.sin(m) * lr, "#ffffff", true, 0.5, 0.5);
                }
                if (two) {
                    double a2 = angle;
                    for (int j = 0; j < s.values.length; j++) {
                        double v = s.values[j];
                        if (v.is_nan() || v <= 0) continue;
                        string c = j < cats.length ? cats[j] : "";
                        if (top_level(c) != parents[k]) continue;
                        double sw = v / total * 2 * Math.PI;
                        cr.new_path();
                        cr.arc(cx, cy, rad, a2, a2 + sw);
                        cr.arc_negative(cx, cy, mid, a2 + sw, a2);
                        cr.close_path();
                        rgb(cr, palette_color(k, dark), 0.7);
                        cr.fill_preserve();
                        rgb(cr, surface);
                        cr.stroke();
                        if (sw > 0.25) {
                            double m2 = a2 + sw / 2, lr2 = (rad + mid) / 2;
                            show_text(cr, leaf_level(c), 9, cx + Math.cos(m2) * lr2, cy + Math.sin(m2) * lr2, "#ffffff", false, 0.5, 0.5);
                        }
                        a2 += sw;
                    }
                }
                angle += sweep;
            }
        }

        public Cairo.ImageSurface render_image(ChartSpec spec, int width, int height, double scale = 1) {
            var surf = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int) (width * scale), (int) (height * scale));
            var cr = new Cairo.Context(surf);
            cr.scale(scale, scale);
            draw(cr, spec, width, height);
            return surf;
        }
    }
}
