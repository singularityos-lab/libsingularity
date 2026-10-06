namespace Singularity.Charts {

    public class OdfChart : Object {
        public const string MEDIA_TYPE = "application/vnd.oasis.opendocument.chart";
        private const string NS = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" xmlns:chart=\"urn:oasis:names:tc:opendocument:xmlns:chart:1.0\" xmlns:number=\"urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0\" xmlns:loext=\"urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0\" xmlns:sc=\"urn:singularity:chart\"";

        private static string esc(string s) {
            return XmlText.esc(s);
        }

        private static string odf_class(ChartType t, bool filled) {
            switch (t) {
                case ChartType.LINE: return "chart:line";
                case ChartType.AREA: return "chart:area";
                case ChartType.PIE: return "chart:circle";
                case ChartType.DOUGHNUT: return "chart:ring";
                case ChartType.SCATTER: return "chart:scatter";
                case ChartType.BUBBLE: return "chart:bubble";
                case ChartType.RADAR: return filled ? "chart:filled-radar" : "chart:radar";
                case ChartType.STOCK: return "chart:stock";
                default: return "chart:bar";
            }
        }

        private static ChartType from_class(string c, out bool filled) {
            filled = false;
            string k = c.has_prefix("chart:") ? c.substring(6) : c;
            switch (k) {
                case "line": return ChartType.LINE;
                case "area": return ChartType.AREA;
                case "circle": return ChartType.PIE;
                case "ring": return ChartType.DOUGHNUT;
                case "scatter": return ChartType.SCATTER;
                case "bubble": return ChartType.BUBBLE;
                case "radar": return ChartType.RADAR;
                case "filled-radar":
                    filled = true;
                    return ChartType.RADAR;
                case "stock": return ChartType.STOCK;
                default: return ChartType.COLUMN;
            }
        }

        private static string col_name(int c) {
            var sb = new StringBuilder();
            int n = c + 1;
            while (n > 0) {
                int rem = (n - 1) % 26;
                sb.prepend_c((char) ('A' + rem));
                n = (n - 1) / 26;
            }
            return sb.str;
        }

        private static string local_ref(int c1, int r1, int c2, int r2) {
            return "local-table.$%s$%d:.$%s$%d".printf(col_name(c1), r1 + 1, col_name(c2), r2 + 1);
        }

        private static string regression_name(TrendType t) {
            switch (t) {
                case TrendType.LINEAR: return "linear";
                case TrendType.EXPONENTIAL: return "exponential";
                case TrendType.LOGARITHMIC: return "logarithmic";
                case TrendType.POLYNOMIAL: return "polynomial";
                case TrendType.POWER: return "power";
                case TrendType.MOVING_AVERAGE: return "moving-average";
                default: return "none";
            }
        }

        private static string error_name(ErrorBarType t) {
            switch (t) {
                case ErrorBarType.FIXED: return "constant";
                case ErrorBarType.PERCENT: return "percentage";
                case ErrorBarType.STDDEV: return "standard-deviation";
                case ErrorBarType.STDERR: return "standard-error";
                default: return "none";
            }
        }

        private static string axis_style(string name, Axis a, bool visible) {
            var sb = new StringBuilder("<style:style style:name=\"%s\" style:family=\"chart\"><style:chart-properties chart:display-label=\"%s\"".printf(name, visible && a.visible ? "true" : "false"));
            if (a.log_base > 1) sb.append(" chart:logarithmic=\"true\"");
            if (!a.min.is_nan()) sb.append(" chart:minimum=\"%s\"".printf(XmlText.num(a.min)));
            if (!a.max.is_nan()) sb.append(" chart:maximum=\"%s\"".printf(XmlText.num(a.max)));
            if (!a.major_unit.is_nan() && a.major_unit > 0) sb.append(" chart:interval-major=\"%s\"".printf(XmlText.num(a.major_unit)));
            if (a.reverse) sb.append(" chart:reverse-direction=\"true\"");
            sb.append("/></style:style>");
            return sb.str;
        }

        public static string write_content(ChartSpec spec, double width_cm = 16, double height_cm = 9) {
            var cats = spec.category_labels();
            int ns = spec.series.size;
            int rows = cats.length;
            foreach (var s in spec.series) rows = int.max(rows, s.values.length);
            bool xy = spec.kind == ChartType.SCATTER || spec.kind == ChartType.BUBBLE;
            var styles = new StringBuilder("<office:automatic-styles>");
            var plot = new StringBuilder();
            styles.append("<style:style style:name=\"ch1\" style:family=\"chart\"><style:chart-properties");
            if (spec.kind == ChartType.BAR) styles.append(" chart:vertical=\"true\"");
            if (spec.grouping == Grouping.STACKED) styles.append(" chart:stacked=\"true\"");
            if (spec.grouping == Grouping.PERCENT) styles.append(" chart:percentage=\"true\"");
            if (spec.kind == ChartType.COLUMN || spec.kind == ChartType.BAR) styles.append(" chart:gap-width=\"%d\" chart:overlap=\"%d\"".printf(spec.gap_width, spec.grouping != Grouping.CLUSTERED ? 100 : spec.overlap));
            if (spec.smooth) styles.append(" chart:interpolation=\"cubic-spline\"");
            if (spec.kind == ChartType.STOCK && ns >= 4) styles.append(" chart:japanese-candle-stick=\"true\"");
            if (spec.kind == ChartType.LINE || spec.kind == ChartType.SCATTER) styles.append(" chart:symbol-type=\"%s\"".printf(spec.markers ? "automatic" : "none"));
            if (spec.kind == ChartType.SCATTER) styles.append(" chart:lines=\"%s\"".printf(spec.lines_on_scatter ? "true" : "false"));
            if (spec.data_labels) styles.append(" chart:data-label-number=\"%s\"".printf(spec.kind.is_radial() ? "percentage" : "value"));
            if (spec.kind == ChartType.DOUGHNUT) styles.append(" chart:angle-offset=\"%d\"".printf(90 - spec.first_slice_angle));
            styles.append("/></style:style>");
            styles.append(axis_style("Ax", spec.x_axis, true));
            styles.append(axis_style("Ay", spec.y_axis, true));
            styles.append(axis_style("Ay2", spec.y2_axis, true));
            plot.append("<chart:plot-area chart:style-name=\"ch1\" table:cell-range-address=\"%s\" chart:data-source-has-labels=\"both\">".printf(esc(local_ref(0, 0, ns, rows))));
            if (spec.kind.has_axes() || spec.kind == ChartType.RADAR) {
                plot.append("<chart:axis chart:dimension=\"x\" chart:name=\"primary-x\" chart:style-name=\"Ax\">");
                if (spec.x_axis.title != "") plot.append("<chart:title><text:p>%s</text:p></chart:title>".printf(esc(spec.x_axis.title)));
                if (!xy) {
                    string cref = spec.series.size > 0 && spec.series[0].categories_ref != "" ? spec.series[0].categories_ref : local_ref(0, 1, 0, rows);
                    plot.append("<chart:categories table:cell-range-address=\"%s\"/>".printf(esc(cref)));
                }
                if (spec.x_axis.gridlines && xy) plot.append("<chart:grid chart:class=\"major\"/>");
                plot.append("</chart:axis><chart:axis chart:dimension=\"y\" chart:name=\"primary-y\" chart:style-name=\"Ay\">");
                if (spec.y_axis.title != "") plot.append("<chart:title><text:p>%s</text:p></chart:title>".printf(esc(spec.y_axis.title)));
                if (spec.y_axis.gridlines) plot.append("<chart:grid chart:class=\"major\"/>");
                plot.append("</chart:axis>");
                if (spec.has_secondary()) {
                    plot.append("<chart:axis chart:dimension=\"y\" chart:name=\"secondary-y\" chart:style-name=\"Ay2\">");
                    if (spec.y2_axis.title != "") plot.append("<chart:title><text:p>%s</text:p></chart:title>".printf(esc(spec.y2_axis.title)));
                    plot.append("</chart:axis>");
                }
            }
            for (int i = 0; i < ns; i++) {
                var s = spec.series[i];
                string sname = "S%d".printf(i);
                styles.append("<style:style style:name=\"%s\" style:family=\"chart\"><style:chart-properties".printf(sname));
                if (s.labels) styles.append(" chart:data-label-number=\"value\"");
                if (s.smooth) styles.append(" chart:interpolation=\"cubic-spline\"");
                if (s.marker != MarkerStyle.AUTO) styles.append(s.marker == MarkerStyle.NONE ? " chart:symbol-type=\"none\"" : " chart:symbol-type=\"named-symbol\" chart:symbol-name=\"%s\"".printf(s.marker == MarkerStyle.CIRCLE ? "circle" : (s.marker == MarkerStyle.SQUARE ? "square" : (s.marker == MarkerStyle.DIAMOND ? "diamond" : "arrow-up"))));
                styles.append("/>");
                if (s.color.length == 7) styles.append("<style:graphic-properties draw:fill=\"solid\" draw:fill-color=\"%s\" svg:stroke-color=\"%s\"/>".printf(s.color, s.color));
                styles.append("</style:style>");
                string vref = s.values_ref != "" ? s.values_ref : local_ref(i + 1, 1, i + 1, rows);
                string lref = s.name_ref != "" ? s.name_ref : "local-table.$%s$1".printf(col_name(i + 1));
                plot.append("<chart:series chart:style-name=\"%s\" chart:values-cell-range-address=\"%s\" chart:label-cell-address=\"%s\"".printf(sname, esc(vref), esc(lref)));
                if (s.has_type) plot.append(" chart:class=\"%s\"".printf(odf_class(s.kind, false)));
                if (s.secondary) plot.append(" chart:attached-axis=\"secondary-y\"");
                else if (spec.kind.has_axes()) plot.append(" chart:attached-axis=\"primary-y\"");
                plot.append(">");
                if (xy && s.x_ref != "") plot.append("<chart:domain table:cell-range-address=\"%s\"/>".printf(esc(s.x_ref)));
                if (s.trendline != null && s.trendline.kind != TrendType.NONE) {
                    var t = s.trendline;
                    styles.append("<style:style style:name=\"R%d\" style:family=\"chart\"><style:chart-properties chart:regression-type=\"%s\" loext:regression-max-degree=\"%d\" loext:regression-period=\"%d\" loext:regression-extrapolate-forward=\"%s\" loext:regression-extrapolate-backward=\"%s\"%s/></style:style>".printf(
                        i, regression_name(t.kind), t.order, t.period, XmlText.num(t.forward), XmlText.num(t.backward), t.name != "" ? " loext:regression-name=\"%s\"".printf(esc(t.name)) : ""));
                    plot.append("<chart:regression-curve chart:style-name=\"R%d\">".printf(i));
                    if (t.show_equation || t.show_r2) plot.append("<chart:equation chart:display-equation=\"%s\" chart:display-r-square=\"%s\"/>".printf(t.show_equation ? "true" : "false", t.show_r2 ? "true" : "false"));
                    plot.append("</chart:regression-curve>");
                }
                if (s.error_bars != null && s.error_bars.kind != ErrorBarType.NONE) {
                    var e = s.error_bars;
                    styles.append("<style:style style:name=\"E%d\" style:family=\"chart\"><style:chart-properties chart:error-category=\"%s\" chart:error-upper-indicator=\"true\" chart:error-lower-indicator=\"true\"%s/></style:style>".printf(
                        i, error_name(e.kind), e.kind == ErrorBarType.FIXED ? " chart:error-upper-limit=\"%s\" chart:error-lower-limit=\"%s\"".printf(XmlText.num(e.amount), XmlText.num(e.amount)) : (e.kind == ErrorBarType.PERCENT ? " chart:error-percentage=\"%s\"".printf(XmlText.num(e.amount)) : (e.kind == ErrorBarType.STDDEV ? " chart:error-margin=\"%s\"".printf(XmlText.num(e.amount)) : ""))));
                    plot.append("<chart:error-indicator chart:style-name=\"E%d\" chart:dimension=\"y\"/>".printf(i));
                }
                plot.append("<chart:data-point chart:repeated=\"%d\"/></chart:series>".printf(int.max(rows, 1)));
            }
            plot.append("</chart:plot-area>");
            styles.append("</office:automatic-styles>");
            var sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
            sb.append("<office:document-content %s office:version=\"1.3\">".printf(NS));
            sb.append(styles.str);
            sb.append("<office:body><office:chart><chart:chart svg:width=\"%scm\" svg:height=\"%scm\" chart:class=\"%s\" sc:kind=\"%s\" sc:bins=\"%d\" sc:hole=\"%d\">".printf(
                XmlText.num(width_cm), XmlText.num(height_cm), odf_class(spec.kind, spec.filled_radar), spec.kind.to_id(), spec.bins, spec.hole_size));
            if (spec.title != "") sb.append("<chart:title><text:p>%s</text:p></chart:title>".printf(esc(spec.title)));
            if (spec.legend != LegendPosition.NONE) {
                string pos = spec.legend == LegendPosition.TOP ? "top" : (spec.legend == LegendPosition.BOTTOM ? "bottom" : (spec.legend == LegendPosition.LEFT ? "start" : "end"));
                sb.append("<chart:legend chart:legend-position=\"%s\" style:legend-expansion=\"high\"/>".printf(pos));
            }
            sb.append(plot.str);
            sb.append("<table:table table:name=\"local-table\"><table:table-header-columns><table:table-column/></table:table-header-columns><table:table-columns><table:table-column table:number-columns-repeated=\"%d\"/></table:table-columns>".printf(int.max(ns, 1)));
            sb.append("<table:table-header-rows><table:table-row><table:table-cell><text:p/></table:table-cell>");
            foreach (var s in spec.series) sb.append("<table:table-cell office:value-type=\"string\"><text:p>%s</text:p></table:table-cell>".printf(esc(s.name)));
            sb.append("</table:table-row></table:table-header-rows><table:table-rows>");
            for (int r = 0; r < rows; r++) {
                sb.append("<table:table-row>");
                if (xy && ns > 0 && r < spec.series[0].xvalues.length) {
                    double xv = spec.series[0].xvalues[r];
                    sb.append("<table:table-cell office:value-type=\"float\" office:value=\"%s\"><text:p>%s</text:p></table:table-cell>".printf(XmlText.num(xv), XmlText.num(xv)));
                } else {
                    sb.append("<table:table-cell office:value-type=\"string\"><text:p>%s</text:p></table:table-cell>".printf(esc(r < cats.length ? cats[r].replace("\x1f", " ") : "")));
                }
                foreach (var s in spec.series) {
                    double v = r < s.values.length ? s.values[r] : double.NAN;
                    if (v.is_nan()) sb.append("<table:table-cell office:value-type=\"float\" office:value=\"NaN\"><text:p>NaN</text:p></table:table-cell>");
                    else sb.append("<table:table-cell office:value-type=\"float\" office:value=\"%s\"><text:p>%s</text:p></table:table-cell>".printf(XmlText.num(v), XmlText.num(v)));
                }
                sb.append("</table:table-row>");
            }
            sb.append("</table:table-rows></table:table></chart:chart></office:chart></office:body></office:document-content>");
            return sb.str;
        }

        public static string write_styles() {
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-styles %s office:version=\"1.3\"><office:styles/></office:document-styles>".printf(NS);
        }

        private static string text_of(XmlElement? e) {
            if (e == null) return "";
            string[] parts = {};
            foreach (var p in e.all("p")) parts += p.all_text();
            return string.joinv("\n", parts);
        }

        private static Gee.HashMap<string, XmlElement> props_by_style(XmlElement root) {
            var map = new Gee.HashMap<string, XmlElement>();
            var auto = root.child("automatic-styles");
            if (auto == null) return map;
            foreach (var st in auto.all("style")) map[st.attr("name")] = st;
            return map;
        }

        private static string prop(Gee.HashMap<string, XmlElement> styles, string style, string key, string def = "") {
            var st = styles[style];
            if (st == null) return def;
            var cp = st.child("chart-properties");
            if (cp != null) {
                string v = cp.attr(key, "\x01");
                if (v != "\x01") return v;
            }
            var gp = st.child("graphic-properties");
            if (gp != null) {
                string v = gp.attr(key, "\x01");
                if (v != "\x01") return v;
            }
            return def;
        }

        private static int col_index(string letters) {
            int n = 0;
            for (int i = 0; i < letters.length; i++) {
                char c = letters[i].toupper();
                if (c < 'A' || c > 'Z') return -1;
                n = n * 26 + (c - 'A' + 1);
            }
            return n - 1;
        }

        private static bool parse_local(string r, out int c1, out int r1, out int c2, out int r2) {
            c1 = r1 = c2 = r2 = -1;
            if (!r.has_prefix("local-table.")) return false;
            string body = r.substring(12).replace("$", "").replace(".", "");
            string[] parts = body.split(":");
            if (!split_cell(parts[0], out c1, out r1)) return false;
            if (parts.length > 1) return split_cell(parts[1], out c2, out r2);
            c2 = c1;
            r2 = r1;
            return true;
        }

        private static bool split_cell(string s, out int c, out int r) {
            int i = 0;
            while (i < s.length && s[i].isalpha()) i++;
            c = col_index(s.substring(0, i));
            r = int.parse(s.substring(i)) - 1;
            return c >= 0 && r >= 0;
        }

        public static ChartSpec? read_content(string xml) {
            var root = XmlElement.parse(xml);
            if (root == null) return null;
            var chart = root.find("chart");
            while (chart != null && chart.local == "chart" && chart.child("plot-area") == null && chart.find("plot-area") != null) {
                XmlElement? inner = null;
                foreach (var c in chart.children) if (c.local == "chart") inner = c;
                if (inner == null) break;
                chart = inner;
            }
            if (chart == null) return null;
            var styles = props_by_style(root);
            var spec = new ChartSpec();
            bool filled;
            spec.kind = from_class(chart.attr("class"), out filled);
            spec.filled_radar = filled;
            string sk = chart.attr("kind");
            if (sk != "") spec.kind = ChartType.from_id(sk);
            spec.bins = int.parse(chart.attr("bins", "0"));
            if (chart.attr("hole") != "") spec.hole_size = int.parse(chart.attr("hole"));
            spec.title = text_of(chart.child("title"));
            var legend = chart.child("legend");
            if (legend == null) spec.legend = LegendPosition.NONE;
            else {
                string pos = legend.attr("legend-position", "end");
                spec.legend = pos == "top" ? LegendPosition.TOP : (pos == "bottom" ? LegendPosition.BOTTOM : (pos == "start" ? LegendPosition.LEFT : LegendPosition.RIGHT));
            }
            var plot = chart.child("plot-area");
            if (plot == null) return spec;
            string ps = plot.attr("style-name");
            if (prop(styles, ps, "vertical") == "true" && spec.kind == ChartType.COLUMN) spec.kind = ChartType.BAR;
            if (prop(styles, ps, "percentage") == "true") spec.grouping = Grouping.PERCENT;
            else if (prop(styles, ps, "stacked") == "true") spec.grouping = Grouping.STACKED;
            if (prop(styles, ps, "gap-width") != "") spec.gap_width = int.parse(prop(styles, ps, "gap-width"));
            if (prop(styles, ps, "interpolation", "none") != "none") spec.smooth = true;
            if (prop(styles, ps, "symbol-type") == "none") spec.markers = false;
            if (prop(styles, ps, "lines") == "true") spec.lines_on_scatter = true;
            if (prop(styles, ps, "data-label-number", "none") != "none") spec.data_labels = true;
            string cat_ref = "";
            foreach (var ax in plot.all("axis")) {
                string name = ax.attr("name");
                string dim = ax.attr("dimension");
                Axis a = dim == "x" ? spec.x_axis : (name == "secondary-y" ? spec.y2_axis : spec.y_axis);
                a.title = text_of(ax.child("title"));
                a.gridlines = ax.child("grid") != null;
                string st = ax.attr("style-name");
                if (prop(styles, st, "logarithmic") == "true") a.log_base = 10;
                if (prop(styles, st, "minimum") != "") a.min = XmlText.parse_num(prop(styles, st, "minimum"));
                if (prop(styles, st, "maximum") != "") a.max = XmlText.parse_num(prop(styles, st, "maximum"));
                if (prop(styles, st, "interval-major") != "") a.major_unit = XmlText.parse_num(prop(styles, st, "interval-major"));
                if (prop(styles, st, "display-label") == "false") a.visible = false;
                var cats = ax.child("categories");
                if (cats != null) cat_ref = cats.attr("cell-range-address");
            }
            var table = chart.child("table");
            var grid = new Gee.ArrayList<Gee.ArrayList<string>>();
            var nums = new Gee.ArrayList<Gee.ArrayList<double?>>();
            if (table != null) {
                var rows = new Gee.ArrayList<XmlElement>();
                table.find_all("table-row", rows);
                foreach (var row in rows) {
                    var srow = new Gee.ArrayList<string>();
                    var nrow = new Gee.ArrayList<double?>();
                    foreach (var cell in row.all("table-cell")) {
                        int rep = int.max(1, int.parse(cell.attr("number-columns-repeated", "1")));
                        for (int k = 0; k < rep && k < 256; k++) {
                            srow.add(text_of(cell));
                            string v = cell.attr("value", "\x01");
                            nrow.add(v != "\x01" ? XmlText.parse_num(v) : XmlText.parse_num(text_of(cell)));
                        }
                    }
                    grid.add(srow);
                    nums.add(nrow);
                }
            }
            int si = 0;
            foreach (var ser in plot.all("series")) {
                var s = new Series();
                string sn = ser.attr("style-name");
                string cls = ser.attr("class");
                if (cls != "") {
                    bool f2;
                    var t = from_class(cls, out f2);
                    if (t != spec.kind) {
                        s.has_type = true;
                        s.kind = t;
                    }
                }
                s.secondary = ser.attr("attached-axis") == "secondary-y";
                string vref = ser.attr("values-cell-range-address");
                string lref = ser.attr("label-cell-address");
                int c1, r1, c2, r2;
                if (parse_local(vref, out c1, out r1, out c2, out r2)) {
                    double[] vals = {};
                    for (int r = r1; r <= r2; r++) vals += r < nums.size && c1 < nums[r].size ? nums[r][c1] : double.NAN;
                    s.values = vals;
                } else {
                    s.values_ref = vref;
                    int col = si + 1;
                    double[] vals = {};
                    for (int r = 1; r < nums.size; r++) vals += col < nums[r].size ? nums[r][col] : double.NAN;
                    s.values = vals;
                }
                if (parse_local(lref, out c1, out r1, out c2, out r2)) {
                    s.name = r1 < grid.size && c1 < grid[r1].size ? grid[r1][c1] : "";
                } else {
                    s.name_ref = lref;
                    s.name = grid.size > 0 && si + 1 < grid[0].size ? grid[0][si + 1] : "";
                }
                var dom = ser.child("domain");
                if (dom != null) {
                    string dref = dom.attr("cell-range-address");
                    if (parse_local(dref, out c1, out r1, out c2, out r2)) {
                        double[] xs = {};
                        for (int r = r1; r <= r2; r++) xs += r < nums.size && c1 < nums[r].size ? nums[r][c1] : double.NAN;
                        s.xvalues = xs;
                    } else {
                        s.x_ref = dref;
                        double[] xs = {};
                        for (int r = 1; r < nums.size; r++) xs += nums[r].size > 0 ? nums[r][0] : double.NAN;
                        s.xvalues = xs;
                    }
                }
                if (cat_ref != "" && !cat_ref.has_prefix("local-table.")) s.categories_ref = cat_ref;
                if (prop(styles, sn, "interpolation", "none") != "none") s.smooth = true;
                string fc = prop(styles, sn, "fill-color");
                if (fc.length == 7) s.color = fc.down();
                if (prop(styles, sn, "data-label-number", "none") != "none") s.labels = true;
                string sym = prop(styles, sn, "symbol-type");
                if (sym == "none") s.marker = MarkerStyle.NONE;
                var rc = ser.child("regression-curve");
                if (rc != null) {
                    string rs = rc.attr("style-name");
                    var t = new Trendline();
                    string rt = prop(styles, rs, "regression-type", "linear");
                    t.kind = TrendType.from_id(rt);
                    t.order = int.parse(prop(styles, rs, "regression-max-degree", "2"));
                    t.period = int.parse(prop(styles, rs, "regression-period", "2"));
                    t.forward = double.parse(prop(styles, rs, "regression-extrapolate-forward", "0"));
                    t.backward = double.parse(prop(styles, rs, "regression-extrapolate-backward", "0"));
                    t.name = prop(styles, rs, "regression-name");
                    var eq = rc.child("equation");
                    if (eq != null) {
                        t.show_equation = eq.attr("display-equation") == "true";
                        t.show_r2 = eq.attr("display-r-square") == "true";
                    }
                    if (t.kind != TrendType.NONE) s.trendline = t;
                }
                var ei = ser.child("error-indicator");
                if (ei != null) {
                    string es = ei.attr("style-name");
                    var e = new ErrorBars();
                    e.kind = ErrorBarType.from_id(prop(styles, es, "error-category", "constant"));
                    if (e.kind == ErrorBarType.FIXED) e.amount = XmlText.parse_num(prop(styles, es, "error-upper-limit", "1"));
                    else if (e.kind == ErrorBarType.PERCENT) e.amount = XmlText.parse_num(prop(styles, es, "error-percentage", "5"));
                    else if (e.kind == ErrorBarType.STDDEV) e.amount = XmlText.parse_num(prop(styles, es, "error-margin", "1"));
                    if (e.kind != ErrorBarType.NONE) s.error_bars = e;
                }
                spec.series.add(s);
                si++;
            }
            string[] cats_out = {};
            int cc1, cr1, cc2, cr2;
            if (parse_local(cat_ref, out cc1, out cr1, out cc2, out cr2)) {
                for (int r = cr1; r <= cr2; r++) cats_out += r < grid.size && cc1 < grid[r].size ? grid[r][cc1] : "";
            } else {
                for (int r = 1; r < grid.size; r++) cats_out += grid[r].size > 0 ? grid[r][0] : "";
            }
            spec.categories = cats_out;
            return spec;
        }
    }
}
