namespace Singularity.Charts {

    public class DrawingML : Object {
        public const string NS_C = "http://schemas.openxmlformats.org/drawingml/2006/chart";
        public const string NS_A = "http://schemas.openxmlformats.org/drawingml/2006/main";
        public const string NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        public const string NS_CX = "http://schemas.microsoft.com/office/drawing/2014/chartex";
        public const string CHART_CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml";
        public const string CHART_REL_TYPE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart";
        public const string CHARTEX_CONTENT_TYPE = "application/vnd.ms-office.chartex+xml";
        public const string CHARTEX_REL_TYPE = "http://schemas.microsoft.com/office/2014/relationships/chartEx";

        private static string esc(string s) {
            return XmlText.esc(s);
        }

        private static string hex_upper(string color) {
            return color.length == 7 ? color.substring(1).up() : "";
        }

        private static string rich(string text) {
            var sb = new StringBuilder("<c:tx><c:rich><a:bodyPr/><a:lstStyle/>");
            foreach (string line in text.split("\n")) sb.append("<a:p><a:r><a:t>%s</a:t></a:r></a:p>".printf(esc(line)));
            sb.append("</c:rich></c:tx>");
            return sb.str;
        }

        private static string title_xml(string text) {
            return "<c:title>" + rich(text) + "<c:overlay val=\"0\"/></c:title>";
        }

        private static string str_ref(string f, string[] values) {
            var sb = new StringBuilder();
            if (f != "") sb.append("<c:strRef><c:f>%s</c:f><c:strCache>".printf(esc(f)));
            else sb.append("<c:strLit>");
            sb.append("<c:ptCount val=\"%d\"/>".printf(values.length));
            for (int i = 0; i < values.length; i++) sb.append("<c:pt idx=\"%d\"><c:v>%s</c:v></c:pt>".printf(i, esc(values[i])));
            sb.append(f != "" ? "</c:strCache></c:strRef>" : "</c:strLit>");
            return sb.str;
        }

        private static string num_ref(string f, double[] values, string fmt) {
            var sb = new StringBuilder();
            if (f != "") sb.append("<c:numRef><c:f>%s</c:f><c:numCache>".printf(esc(f)));
            else sb.append("<c:numLit>");
            sb.append("<c:formatCode>%s</c:formatCode><c:ptCount val=\"%d\"/>".printf(esc(fmt == "" ? "General" : fmt), values.length));
            for (int i = 0; i < values.length; i++) {
                if (values[i].is_nan()) continue;
                sb.append("<c:pt idx=\"%d\"><c:v>%s</c:v></c:pt>".printf(i, XmlText.num(values[i])));
            }
            sb.append(f != "" ? "</c:numCache></c:numRef>" : "</c:numLit>");
            return sb.str;
        }

        private static string group_element(ChartType t) {
            switch (t) {
                case ChartType.BAR: case ChartType.COLUMN: return "barChart";
                case ChartType.LINE: return "lineChart";
                case ChartType.AREA: return "areaChart";
                case ChartType.PIE: return "pieChart";
                case ChartType.DOUGHNUT: return "doughnutChart";
                case ChartType.SCATTER: return "scatterChart";
                case ChartType.BUBBLE: return "bubbleChart";
                case ChartType.RADAR: return "radarChart";
                case ChartType.STOCK: return "stockChart";
                default: return "barChart";
            }
        }

        private class Group {
            public ChartType kind;
            public bool secondary;
            public Gee.ArrayList<int> members = new Gee.ArrayList<int>();
        }

        private static string sppr(ChartSpec spec, Series s, ChartType t) {
            string c = hex_upper(s.color);
            if (t == ChartType.LINE || t == ChartType.SCATTER || t == ChartType.RADAR || t == ChartType.STOCK) {
                if (t == ChartType.STOCK) return "<c:spPr><a:ln w=\"19050\"><a:noFill/></a:ln></c:spPr>";
                bool scatter_no_line = t == ChartType.SCATTER && !spec.lines_on_scatter && !s.smooth;
                string w = "%d".printf((int) (s.line_width * 12700));
                if (scatter_no_line) return "<c:spPr><a:ln w=\"19050\"><a:noFill/></a:ln></c:spPr>";
                if (c == "") return "<c:spPr><a:ln w=\"%s\" cap=\"rnd\"><a:round/></a:ln></c:spPr>".printf(w);
                return "<c:spPr><a:ln w=\"%s\" cap=\"rnd\"><a:solidFill><a:srgbClr val=\"%s\"/></a:solidFill><a:round/></a:ln></c:spPr>".printf(w, c);
            }
            if (c == "") return "";
            return "<c:spPr><a:solidFill><a:srgbClr val=\"%s\"/></a:solidFill></c:spPr>".printf(c);
        }

        private static string marker_xml(ChartSpec spec, Series s, ChartType t) {
            if (t != ChartType.LINE && t != ChartType.SCATTER && t != ChartType.RADAR && t != ChartType.STOCK) return "";
            if (t == ChartType.STOCK) return "<c:marker><c:symbol val=\"none\"/></c:marker>";
            if (s.marker == MarkerStyle.NONE || (!spec.markers && s.marker == MarkerStyle.AUTO && t == ChartType.LINE)) return "<c:marker><c:symbol val=\"none\"/></c:marker>";
            if (s.marker == MarkerStyle.AUTO) return "";
            return "<c:marker><c:symbol val=\"%s\"/><c:size val=\"6\"/></c:marker>".printf(s.marker.to_id());
        }

        private static string labels_xml(bool on, bool percent) {
            if (!on) return "";
            return "<c:dLbls><c:showLegendKey val=\"0\"/><c:showVal val=\"%d\"/><c:showCatName val=\"0\"/><c:showSerName val=\"0\"/><c:showPercent val=\"%d\"/><c:showBubbleSize val=\"0\"/></c:dLbls>".printf(percent ? 0 : 1, percent ? 1 : 0);
        }

        private static string trend_xml(Trendline? t) {
            if (t == null || t.kind == TrendType.NONE) return "";
            var sb = new StringBuilder("<c:trendline>");
            if (t.name != "") sb.append("<c:name>%s</c:name>".printf(esc(t.name)));
            sb.append("<c:trendlineType val=\"%s\"/>".printf(t.kind.to_id()));
            if (t.kind == TrendType.POLYNOMIAL) sb.append("<c:order val=\"%d\"/>".printf(t.order.clamp(2, 6)));
            if (t.kind == TrendType.MOVING_AVERAGE) sb.append("<c:period val=\"%d\"/>".printf(int.max(2, t.period)));
            if (t.forward > 0) sb.append("<c:forward val=\"%s\"/>".printf(XmlText.num(t.forward)));
            if (t.backward > 0) sb.append("<c:backward val=\"%s\"/>".printf(XmlText.num(t.backward)));
            if (t.kind != TrendType.MOVING_AVERAGE) sb.append("<c:dispRSqr val=\"%d\"/><c:dispEq val=\"%d\"/>".printf(t.show_r2 ? 1 : 0, t.show_equation ? 1 : 0));
            sb.append("</c:trendline>");
            return sb.str;
        }

        private static string err_xml(ErrorBars? e) {
            if (e == null || e.kind == ErrorBarType.NONE) return "";
            var sb = new StringBuilder("<c:errBars><c:errDir val=\"y\"/><c:errBarType val=\"both\"/>");
            sb.append("<c:errValType val=\"%s\"/><c:noEndCap val=\"0\"/>".printf(e.kind.to_id()));
            if (e.kind != ErrorBarType.STDERR) sb.append("<c:val val=\"%s\"/>".printf(XmlText.num(e.amount)));
            sb.append("</c:errBars>");
            return sb.str;
        }

        private static string series_xml(ChartSpec spec, Series s, int idx, ChartType t, string[] cats) {
            var sb = new StringBuilder("<c:ser><c:idx val=\"%d\"/><c:order val=\"%d\"/>".printf(idx, idx));
            if (s.name != "" || s.name_ref != "") sb.append("<c:tx>%s</c:tx>".printf(s.name_ref != "" ? str_ref(s.name_ref, { s.name }) : "<c:v>" + esc(s.name) + "</c:v>"));
            sb.append(sppr(spec, s, t));
            if (t == ChartType.COLUMN || t == ChartType.BAR || t == ChartType.BUBBLE) sb.append("<c:invertIfNegative val=\"0\"/>");
            sb.append(marker_xml(spec, s, t));
            sb.append(labels_xml(s.labels || spec.data_labels, t == ChartType.PIE || t == ChartType.DOUGHNUT));
            if (t != ChartType.PIE && t != ChartType.DOUGHNUT && t != ChartType.RADAR) {
                sb.append(trend_xml(s.trendline));
                sb.append(err_xml(s.error_bars));
            }
            string[] c = s.categories.length > 0 ? s.categories : cats;
            if (t == ChartType.SCATTER || t == ChartType.BUBBLE) {
                if (s.x_ref != "" || s.xvalues.length > 0) sb.append("<c:xVal>%s</c:xVal>".printf(num_ref(s.x_ref, s.xvalues, spec.x_axis.number_format)));
                else if (s.categories_ref != "" || c.length > 0) sb.append("<c:xVal>%s</c:xVal>".printf(str_ref(s.categories_ref, c)));
                sb.append("<c:yVal>%s</c:yVal>".printf(num_ref(s.values_ref, s.values, spec.y_axis.number_format)));
                if (t == ChartType.BUBBLE) {
                    double[] sizes = s.sizes;
                    if (sizes.length == 0) {
                        sizes = new double[s.values.length];
                        for (int i = 0; i < sizes.length; i++) sizes[i] = 1;
                    }
                    sb.append("<c:bubbleSize>%s</c:bubbleSize><c:bubble3D val=\"0\"/>".printf(num_ref(s.sizes_ref, sizes, "")));
                } else {
                    sb.append("<c:smooth val=\"%d\"/>".printf(s.smooth ? 1 : 0));
                }
            } else {
                if (s.categories_ref != "" || c.length > 0) sb.append("<c:cat>%s</c:cat>".printf(str_ref(s.categories_ref, c)));
                sb.append("<c:val>%s</c:val>".printf(num_ref(s.values_ref, s.values, spec.y_axis.number_format)));
                if (t == ChartType.LINE || t == ChartType.STOCK) sb.append("<c:smooth val=\"%d\"/>".printf(s.smooth || spec.smooth ? 1 : 0));
            }
            sb.append("</c:ser>");
            return sb.str;
        }

        private static string axis_title(Axis a) {
            return a.title != "" ? title_xml(a.title) : "";
        }

        private static string scaling(Axis a) {
            var sb = new StringBuilder("<c:scaling>");
            if (a.log_base > 1) sb.append("<c:logBase val=\"%s\"/>".printf(XmlText.num(a.log_base)));
            sb.append("<c:orientation val=\"%s\"/>".printf(a.reverse ? "maxMin" : "minMax"));
            if (!a.max.is_nan()) sb.append("<c:max val=\"%s\"/>".printf(XmlText.num(a.max)));
            if (!a.min.is_nan()) sb.append("<c:min val=\"%s\"/>".printf(XmlText.num(a.min)));
            sb.append("</c:scaling>");
            return sb.str;
        }

        private static string num_fmt(Axis a) {
            if (a.number_format == "") return "<c:numFmt formatCode=\"General\" sourceLinked=\"1\"/>";
            return "<c:numFmt formatCode=\"%s\" sourceLinked=\"0\"/>".printf(esc(a.number_format));
        }

        private static string cat_ax(int id, int cross, Axis a, string pos, bool deleted) {
            return "<c:catAx><c:axId val=\"%d\"/>%s<c:delete val=\"%d\"/><c:axPos val=\"%s\"/>%s%s<c:majorTickMark val=\"none\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"%d\"/><c:crosses val=\"autoZero\"/><c:auto val=\"1\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/></c:catAx>".printf(
                id, scaling(a), deleted || !a.visible ? 1 : 0, pos, axis_title(a), num_fmt(a), cross);
        }

        private static string val_ax(int id, int cross, Axis a, string pos, bool crosses_max, bool deleted, bool percent) {
            string grid = a.gridlines && !crosses_max ? "<c:majorGridlines/>" : "";
            string fmt = percent && a.number_format == "" ? "<c:numFmt formatCode=\"0%\" sourceLinked=\"1\"/>" : num_fmt(a);
            string unit = !a.major_unit.is_nan() && a.major_unit > 0 ? "<c:majorUnit val=\"%s\"/>".printf(XmlText.num(a.major_unit)) : "";
            return "<c:valAx><c:axId val=\"%d\"/>%s<c:delete val=\"%d\"/><c:axPos val=\"%s\"/>%s%s%s<c:majorTickMark val=\"none\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"%d\"/><c:crosses val=\"%s\"/><c:crossBetween val=\"between\"/>%s</c:valAx>".printf(
                id, scaling(a), deleted || !a.visible ? 1 : 0, pos, grid, axis_title(a), fmt, cross, crosses_max ? "max" : "autoZero", unit);
        }

        public static string write_chart(ChartSpec spec) {
            var sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
            sb.append("<c:chartSpace xmlns:c=\"%s\" xmlns:a=\"%s\" xmlns:r=\"%s\"><c:date1904 val=\"0\"/><c:roundedCorners val=\"0\"/>".printf(NS_C, NS_A, NS_R));
            if (spec.style > 0) sb.append("<c:style val=\"%d\"/>".printf(spec.style.clamp(1, 48)));
            sb.append("<c:chart>");
            if (spec.title != "") sb.append(title_xml(spec.title) + "<c:autoTitleDeleted val=\"0\"/>");
            else sb.append("<c:autoTitleDeleted val=\"1\"/>");
            sb.append("<c:plotArea><c:layout/>");
            var cats = spec.category_labels();
            var groups = new Gee.ArrayList<Group>();
            ChartType main = spec.kind.is_extended() ? ChartType.COLUMN : spec.kind;
            for (int i = 0; i < spec.series.size; i++) {
                var s = spec.series[i];
                ChartType t = s.has_type && !s.kind.is_extended() ? s.kind : main;
                if (t == ChartType.STOCK && spec.series.size < 3) t = ChartType.LINE;
                bool sec = s.secondary && !t.is_radial();
                Group? g = null;
                foreach (var e in groups) if (group_element(e.kind) == group_element(t) && (e.kind == ChartType.BAR) == (t == ChartType.BAR) && e.secondary == sec) g = e;
                if (g == null) {
                    g = new Group();
                    g.kind = t;
                    g.secondary = sec;
                    groups.add(g);
                }
                g.members.add(i);
            }
            bool any_radial = false, any_xy = false, any_cat = false, any_bar_h = false, any_secondary = false;
            foreach (var g in groups) {
                if (g.kind.is_radial()) any_radial = true;
                else if (g.kind == ChartType.SCATTER || g.kind == ChartType.BUBBLE) any_xy = true;
                else any_cat = true;
                if (g.kind == ChartType.BAR) any_bar_h = true;
                if (g.secondary) any_secondary = true;
            }
            string grouping = spec.grouping == Grouping.STACKED ? "stacked" : (spec.grouping == Grouping.PERCENT ? "percentStacked" : "clustered");
            foreach (var g in groups) {
                string el = group_element(g.kind);
                sb.append("<c:%s>".printf(el));
                switch (g.kind) {
                    case ChartType.BAR:
                    case ChartType.COLUMN:
                        sb.append("<c:barDir val=\"%s\"/><c:grouping val=\"%s\"/>".printf(g.kind == ChartType.BAR ? "bar" : "col", grouping));
                        break;
                    case ChartType.LINE:
                    case ChartType.AREA:
                        sb.append("<c:grouping val=\"%s\"/>".printf(spec.grouping == Grouping.CLUSTERED ? "standard" : grouping));
                        break;
                    case ChartType.SCATTER:
                        sb.append("<c:scatterStyle val=\"%s\"/>".printf(spec.lines_on_scatter ? (spec.smooth ? "smoothMarker" : "lineMarker") : "lineMarker"));
                        break;
                    case ChartType.RADAR:
                        sb.append("<c:radarStyle val=\"%s\"/>".printf(spec.filled_radar ? "filled" : "marker"));
                        break;
                    default:
                        break;
                }
                if (g.kind != ChartType.STOCK) sb.append("<c:varyColors val=\"%d\"/>".printf(g.kind.is_radial() || spec.vary_colors ? 1 : 0));
                foreach (int i in g.members) sb.append(series_xml(spec, spec.series[i], i, g.kind, cats));
                if (g.kind == ChartType.COLUMN || g.kind == ChartType.BAR) {
                    int overlap = spec.grouping != Grouping.CLUSTERED ? 100 : spec.overlap;
                    sb.append("<c:gapWidth val=\"%d\"/>".printf(spec.gap_width.clamp(0, 500)));
                    if (overlap != 0) sb.append("<c:overlap val=\"%d\"/>".printf(overlap.clamp(-100, 100)));
                } else if (g.kind == ChartType.LINE) {
                    sb.append("<c:marker val=\"1\"/>");
                } else if (g.kind == ChartType.STOCK) {
                    sb.append("<c:hiLowLines/>");
                    if (g.members.size >= 4) sb.append("<c:upDownBars><c:gapWidth val=\"150\"/><c:upBars/><c:downBars/></c:upDownBars>");
                } else if (g.kind == ChartType.PIE) {
                    sb.append("<c:firstSliceAng val=\"%d\"/>".printf(spec.first_slice_angle.clamp(0, 360)));
                } else if (g.kind == ChartType.DOUGHNUT) {
                    sb.append("<c:firstSliceAng val=\"%d\"/><c:holeSize val=\"%d\"/>".printf(spec.first_slice_angle.clamp(0, 360), spec.hole_size.clamp(10, 90)));
                } else if (g.kind == ChartType.BUBBLE) {
                    sb.append("<c:bubbleScale val=\"100\"/><c:showNegBubbles val=\"0\"/>");
                }
                if (!g.kind.is_radial()) sb.append("<c:axId val=\"%d\"/><c:axId val=\"%d\"/>".printf(g.secondary ? 1003 : 1001, g.secondary ? 1004 : 1002));
                sb.append("</c:%s>".printf(el));
            }
            if (!any_radial || any_cat || any_xy) {
                bool percent = spec.grouping == Grouping.PERCENT;
                if (any_xy && !any_cat) {
                    sb.append(val_ax(1001, 1002, spec.x_axis, "b", false, false, false));
                    sb.append(val_ax(1002, 1001, spec.y_axis, "l", false, false, false));
                } else if (groups.size > 0 && !(any_radial && !any_cat)) {
                    sb.append(cat_ax(1001, 1002, spec.x_axis, any_bar_h ? "l" : "b", false));
                    sb.append(val_ax(1002, 1001, spec.y_axis, any_bar_h ? "b" : "l", false, false, percent));
                }
                if (any_secondary) {
                    if (any_xy && !any_cat) sb.append(val_ax(1003, 1004, spec.x_axis, "b", false, true, false));
                    else sb.append(cat_ax(1003, 1004, spec.x_axis, "b", true));
                    sb.append(val_ax(1004, 1003, spec.y2_axis, "r", true, false, false));
                }
            }
            sb.append("</c:plotArea>");
            if (spec.legend != LegendPosition.NONE) sb.append("<c:legend><c:legendPos val=\"%s\"/><c:overlay val=\"0\"/></c:legend>".printf(spec.legend.to_id()));
            sb.append("<c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/></c:chart>");
            sb.append("<c:extLst><c:ext uri=\"{5C6A2E3B-7F48-4D1A-9E2B-3A51D0C7B9F4}\" xmlns:sc=\"urn:singularity:chart\"><sc:options kind=\"%s\" markers=\"%d\" lines=\"%d\" bins=\"%d\" palette=\"%s\"/></c:ext></c:extLst>".printf(
                spec.kind.to_id(), spec.markers ? 1 : 0, spec.lines_on_scatter ? 1 : 0, spec.bins, esc(spec.palette)));
            sb.append("</c:chartSpace>");
            return sb.str;
        }

        private static string layout_id(ChartType t) {
            switch (t) {
                case ChartType.HISTOGRAM: return "clusteredColumn";
                case ChartType.PARETO: return "clusteredColumn";
                case ChartType.BOX_WHISKER: return "boxWhisker";
                case ChartType.WATERFALL: return "waterfall";
                case ChartType.FUNNEL: return "funnel";
                case ChartType.TREEMAP: return "treemap";
                case ChartType.SUNBURST: return "sunburst";
                default: return "clusteredColumn";
            }
        }

        private static string cx_str_dim(string f, string[] cats) {
            var sb = new StringBuilder("<cx:strDim type=\"cat\">");
            if (f != "") sb.append("<cx:f>%s</cx:f>".printf(esc(f)));
            int depth = 1;
            foreach (string c in cats) depth = int.max(depth, c.split("\x1f").length);
            for (int level = depth - 1; level >= 0; level--) {
                sb.append("<cx:lvl ptCount=\"%d\">".printf(cats.length));
                for (int i = 0; i < cats.length; i++) {
                    var parts = cats[i].split("\x1f");
                    int off = depth - parts.length;
                    string v = level - off >= 0 && level - off < parts.length ? parts[level - off] : "";
                    sb.append("<cx:pt idx=\"%d\">%s</cx:pt>".printf(i, esc(v)));
                }
                sb.append("</cx:lvl>");
            }
            sb.append("</cx:strDim>");
            return sb.str;
        }

        private static string cx_num_dim(string f, double[] vals) {
            var sb = new StringBuilder("<cx:numDim type=\"val\">");
            if (f != "") sb.append("<cx:f>%s</cx:f>".printf(esc(f)));
            sb.append("<cx:lvl ptCount=\"%d\" formatCode=\"General\">".printf(vals.length));
            for (int i = 0; i < vals.length; i++) if (!vals[i].is_nan()) sb.append("<cx:pt idx=\"%d\">%s</cx:pt>".printf(i, XmlText.num(vals[i])));
            sb.append("</cx:lvl></cx:numDim>");
            return sb.str;
        }

        public static string write_chart_ex(ChartSpec spec) {
            var sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
            sb.append("<cx:chartSpace xmlns:a=\"%s\" xmlns:r=\"%s\" xmlns:cx=\"%s\"><cx:chartData>".printf(NS_A, NS_R, NS_CX));
            var cats = spec.category_labels();
            for (int i = 0; i < spec.series.size; i++) {
                var s = spec.series[i];
                sb.append("<cx:data id=\"%d\">".printf(i));
                if (spec.kind != ChartType.HISTOGRAM && spec.kind != ChartType.BOX_WHISKER) sb.append(cx_str_dim(s.categories_ref, s.categories.length > 0 ? s.categories : cats));
                sb.append(cx_num_dim(s.values_ref, s.values));
                sb.append("</cx:data>");
            }
            sb.append("</cx:chartData><cx:chart>");
            if (spec.title != "") sb.append("<cx:title pos=\"t\" align=\"ctr\" overlay=\"0\"><cx:tx><cx:txData><cx:v>%s</cx:v></cx:txData></cx:tx></cx:title>".printf(esc(spec.title)));
            sb.append("<cx:plotArea><cx:plotAreaRegion>");
            string lid = layout_id(spec.kind);
            for (int i = 0; i < spec.series.size; i++) {
                var s = spec.series[i];
                sb.append("<cx:series layoutId=\"%s\" uniqueId=\"{00000000-0000-4000-8000-%012d}\">".printf(lid, i + 1));
                if (s.name != "" || s.name_ref != "") {
                    sb.append("<cx:tx><cx:txData>");
                    if (s.name_ref != "") sb.append("<cx:f>%s</cx:f>".printf(esc(s.name_ref)));
                    sb.append("<cx:v>%s</cx:v></cx:txData></cx:tx>".printf(esc(s.name)));
                }
                if (s.color.length == 7) sb.append("<cx:spPr><a:solidFill><a:srgbClr val=\"%s\"/></a:solidFill></cx:spPr>".printf(hex_upper(s.color)));
                if (spec.data_labels || s.labels) sb.append("<cx:dataLabels pos=\"outEnd\"><cx:visibility seriesName=\"0\" categoryName=\"0\" value=\"1\"/></cx:dataLabels>");
                sb.append("<cx:dataId val=\"%d\"/>".printf(i));
                if (spec.kind == ChartType.HISTOGRAM || (spec.kind == ChartType.PARETO && cats.length == 0)) {
                    sb.append("<cx:layoutPr><cx:binning intervalClosed=\"r\">");
                    if (spec.bins > 0) sb.append("<cx:binCount val=\"%d\"/>".printf(spec.bins));
                    else if (!spec.bin_width.is_nan() && spec.bin_width > 0) sb.append("<cx:binSize val=\"%s\"/>".printf(XmlText.num(spec.bin_width)));
                    sb.append("</cx:binning></cx:layoutPr>");
                } else if (spec.kind == ChartType.PARETO) {
                    sb.append("<cx:layoutPr><cx:aggregation/></cx:layoutPr>");
                } else if (spec.kind == ChartType.BOX_WHISKER) {
                    sb.append("<cx:layoutPr><cx:visibility meanLine=\"0\" meanMarker=\"1\" nonoutliers=\"0\" outliers=\"1\"/><cx:statistics quartileMethod=\"exclusive\"/></cx:layoutPr>");
                } else if (spec.kind == ChartType.WATERFALL) {
                    sb.append("<cx:layoutPr><cx:visibility connectorLines=\"1\"/></cx:layoutPr>");
                } else if (spec.kind == ChartType.TREEMAP) {
                    sb.append("<cx:layoutPr><cx:parentLabelLayout val=\"overlapping\"/></cx:layoutPr>");
                }
                sb.append("</cx:series>");
                if (spec.kind == ChartType.PARETO && i == 0) {
                    sb.append("<cx:series layoutId=\"paretoLine\" ownerIdx=\"0\" uniqueId=\"{00000000-0000-4000-8000-%012d}\"><cx:axisId val=\"2\"/></cx:series>".printf(900 + i));
                }
            }
            sb.append("</cx:plotAreaRegion>");
            bool axes = spec.kind != ChartType.TREEMAP && spec.kind != ChartType.SUNBURST;
            if (axes) {
                if (spec.kind == ChartType.FUNNEL) {
                    sb.append("<cx:axis id=\"0\"><cx:catScaling gapWidth=\"0.06\"/><cx:tickLabels/></cx:axis>");
                } else {
                    sb.append("<cx:axis id=\"0\"><cx:catScaling gapWidth=\"%s\"/>%s<cx:tickLabels/></cx:axis>".printf(
                        spec.kind == ChartType.HISTOGRAM || spec.kind == ChartType.PARETO ? "0" : "0.5",
                        spec.x_axis.title != "" ? "<cx:title><cx:tx><cx:txData><cx:v>%s</cx:v></cx:txData></cx:tx></cx:title>".printf(esc(spec.x_axis.title)) : ""));
                    sb.append("<cx:axis id=\"1\"><cx:valScaling/>%s<cx:majorGridlines/><cx:tickLabels/></cx:axis>".printf(
                        spec.y_axis.title != "" ? "<cx:title><cx:tx><cx:txData><cx:v>%s</cx:v></cx:txData></cx:tx></cx:title>".printf(esc(spec.y_axis.title)) : ""));
                    if (spec.kind == ChartType.PARETO) sb.append("<cx:axis id=\"2\"><cx:valScaling max=\"1\" min=\"0\"/><cx:units unit=\"percentage\"/><cx:tickLabels/></cx:axis>");
                }
            }
            sb.append("</cx:plotArea>");
            if (spec.legend != LegendPosition.NONE) sb.append("<cx:legend pos=\"%s\" align=\"ctr\" overlay=\"0\"/>".printf(spec.legend.to_id()));
            sb.append("</cx:chart></cx:chartSpace>");
            return sb.str;
        }

        public static string write_any(ChartSpec spec, out bool extended) {
            extended = spec.kind.is_extended();
            return extended ? write_chart_ex(spec) : write_chart(spec);
        }

        private static string rich_text(XmlElement? tx) {
            if (tx == null) return "";
            var rich_el = tx.find("rich");
            if (rich_el != null) {
                string[] lines = {};
                foreach (var p in rich_el.all("p")) {
                    var ts = new Gee.ArrayList<XmlElement>();
                    p.find_all("t", ts);
                    var sb = new StringBuilder();
                    foreach (var t in ts) sb.append(t.text);
                    lines += sb.str;
                }
                return string.joinv("\n", lines);
            }
            var v = tx.find("v");
            if (v != null) return v.text;
            return "";
        }

        private static string ref_formula(XmlElement? e) {
            if (e == null) return "";
            var f = e.find("f");
            return f != null ? f.text.strip() : "";
        }

        private static string[] str_cache(XmlElement? e) {
            if (e == null) return {};
            var cache = e.find("strCache") ?? e.find("strLit") ?? e.find("numCache") ?? e.find("numLit");
            var multi = e.find("multiLvlStrCache");
            if (multi != null) {
                var lvls = multi.all("lvl");
                int count = int.parse(multi.val("ptCount", "0"));
                string[] out_c = new string[count];
                for (int i = 0; i < count; i++) out_c[i] = "";
                for (int li = lvls.size - 1; li >= 0; li--) {
                    string last = "";
                    string[] level = new string[count];
                    foreach (var pt in lvls[li].all("pt")) {
                        int idx = int.parse(pt.attr("idx"));
                        if (idx >= 0 && idx < count) level[idx] = pt.child("v") != null ? pt.child("v").text : "";
                    }
                    for (int i = 0; i < count; i++) {
                        if (level[i] != null && level[i] != "") last = level[i];
                        string v = li == 0 ? (level[i] ?? "") : last;
                        out_c[i] = out_c[i] == "" ? v : out_c[i] + "\x1f" + v;
                    }
                }
                return out_c;
            }
            if (cache == null) return {};
            int count = int.parse(cache.val("ptCount", "0"));
            var pts = cache.all("pt");
            foreach (var pt in pts) count = int.max(count, int.parse(pt.attr("idx")) + 1);
            string[] out_s = new string[count];
            for (int i = 0; i < count; i++) out_s[i] = "";
            foreach (var pt in pts) {
                int idx = int.parse(pt.attr("idx"));
                var v = pt.child("v");
                if (idx >= 0 && idx < count && v != null) out_s[idx] = v.text;
            }
            return out_s;
        }

        private static double[] num_cache(XmlElement? e) {
            if (e == null) return {};
            var cache = e.find("numCache") ?? e.find("numLit") ?? e.find("strCache");
            if (cache == null) return {};
            int count = int.parse(cache.val("ptCount", "0"));
            var pts = cache.all("pt");
            foreach (var pt in pts) count = int.max(count, int.parse(pt.attr("idx")) + 1);
            double[] out_v = new double[count];
            for (int i = 0; i < count; i++) out_v[i] = double.NAN;
            foreach (var pt in pts) {
                int idx = int.parse(pt.attr("idx"));
                var v = pt.child("v");
                if (idx >= 0 && idx < count && v != null) out_v[idx] = XmlText.parse_num(v.text);
            }
            return out_v;
        }

        private static string color_of(XmlElement? sppr) {
            if (sppr == null) return "";
            var clr = sppr.find("srgbClr");
            if (clr == null) return "";
            string v = clr.attr("val");
            return v.length == 6 ? "#" + v.down() : "";
        }

        private static ChartType type_from_group(string local, XmlElement g) {
            switch (local) {
                case "barChart":
                case "bar3DChart":
                    return g.val("barDir", "col") == "bar" ? ChartType.BAR : ChartType.COLUMN;
                case "lineChart":
                case "line3DChart":
                    return ChartType.LINE;
                case "areaChart":
                case "area3DChart":
                    return ChartType.AREA;
                case "pieChart":
                case "pie3DChart":
                case "ofPieChart":
                    return ChartType.PIE;
                case "doughnutChart":
                    return ChartType.DOUGHNUT;
                case "scatterChart":
                    return ChartType.SCATTER;
                case "bubbleChart":
                    return ChartType.BUBBLE;
                case "radarChart":
                    return ChartType.RADAR;
                case "stockChart":
                    return ChartType.STOCK;
                default:
                    return ChartType.COLUMN;
            }
        }

        private static void read_axis(XmlElement ax, Axis a) {
            var t = ax.child("title");
            if (t != null) a.title = rich_text(t.child("tx"));
            var sc = ax.child("scaling");
            if (sc != null) {
                if (sc.child("logBase") != null) a.log_base = XmlText.parse_num(sc.val("logBase"));
                if (sc.child("max") != null) a.max = XmlText.parse_num(sc.val("max"));
                if (sc.child("min") != null) a.min = XmlText.parse_num(sc.val("min"));
                a.reverse = sc.val("orientation") == "maxMin";
            }
            a.visible = ax.val("delete", "0") != "1" && ax.val("delete", "0") != "true";
            a.gridlines = ax.child("majorGridlines") != null;
            var nf = ax.child("numFmt");
            if (nf != null && nf.attr("sourceLinked") != "1" && nf.attr("formatCode") != "General") a.number_format = nf.attr("formatCode");
            if (ax.child("majorUnit") != null) a.major_unit = XmlText.parse_num(ax.val("majorUnit"));
        }

        public static ChartSpec? read_chart(string xml) {
            var root = XmlElement.parse(xml);
            if (root == null) return null;
            if (root.local == "chartSpace" && root.find("chartData") != null) return read_chart_ex(root);
            var chart = root.child("chart");
            if (chart == null) return null;
            var spec = new ChartSpec();
            spec.style = int.parse(root.val("style", "0"));
            var title = chart.child("title");
            if (title != null) {
                spec.title = rich_text(title.child("tx"));
                if (spec.title == "" && chart.val("autoTitleDeleted", "0") != "1") spec.title = "";
            }
            var legend = chart.child("legend");
            spec.legend = legend != null ? LegendPosition.from_id(legend.val("legendPos", "r")) : LegendPosition.NONE;
            var plot = chart.child("plotArea");
            if (plot == null) return spec;
            var axis_by_id = new Gee.HashMap<string, XmlElement>();
            foreach (var c in plot.children) {
                if (c.local == "catAx" || c.local == "valAx" || c.local == "dateAx" || c.local == "serAx") axis_by_id[c.val("axId")] = c;
            }
            string primary_val = "";
            bool first_group = true;
            int idx_offset = 0;
            foreach (var g in plot.children) {
                if (!g.local.has_suffix("Chart")) continue;
                ChartType t = type_from_group(g.local, g);
                string[] ax_ids = {};
                foreach (var a in g.all("axId")) ax_ids += a.attr("val");
                bool secondary = false;
                if (ax_ids.length >= 2) {
                    XmlElement? val_ax = null;
                    foreach (string id in ax_ids) {
                        var ax = axis_by_id[id];
                        if (ax != null && ax.local == "valAx" && (t != ChartType.SCATTER && t != ChartType.BUBBLE || ax.val("axPos") == "l" || ax.val("axPos") == "r")) val_ax = ax;
                    }
                    string vid = val_ax != null ? val_ax.val("axId") : ax_ids[1];
                    if (primary_val == "") primary_val = vid;
                    else if (vid != primary_val) secondary = true;
                    if (val_ax != null) {
                        read_axis(val_ax, secondary ? spec.y2_axis : spec.y_axis);
                        if (!secondary) {
                            foreach (string id in ax_ids) {
                                var ax = axis_by_id[id];
                                if (ax != null && ax != val_ax) read_axis(ax, spec.x_axis);
                            }
                        }
                    }
                }
                if (first_group) {
                    spec.kind = t;
                    string gr = g.val("grouping", "clustered");
                    if (gr == "stacked") spec.grouping = Grouping.STACKED;
                    else if (gr == "percentStacked") spec.grouping = Grouping.PERCENT;
                    if (g.child("gapWidth") != null) spec.gap_width = int.parse(g.val("gapWidth"));
                    if (g.child("overlap") != null && spec.grouping == Grouping.CLUSTERED) spec.overlap = int.parse(g.val("overlap"));
                    if (g.child("holeSize") != null) spec.hole_size = int.parse(g.val("holeSize"));
                    if (g.child("firstSliceAng") != null) spec.first_slice_angle = int.parse(g.val("firstSliceAng"));
                    spec.vary_colors = g.val("varyColors", "0") == "1" && !t.is_radial();
                    if (t == ChartType.RADAR) spec.filled_radar = g.val("radarStyle") == "filled";
                    if (g.find("dLbls") != null && g.child("dLbls") != null && g.child("dLbls").val("showVal", "0") == "1") spec.data_labels = true;
                }
                foreach (var ser in g.all("ser")) {
                    var s = new Series();
                    if (!first_group) {
                        s.has_type = true;
                        s.kind = t;
                    }
                    s.secondary = secondary;
                    var tx = ser.child("tx");
                    if (tx != null) {
                        s.name_ref = ref_formula(tx);
                        var names = str_cache(tx);
                        s.name = names.length > 0 ? names[0] : (tx.child("v") != null ? tx.child("v").text : "");
                    }
                    s.color = color_of(ser.child("spPr"));
                    var mk = ser.child("marker");
                    if (mk != null && mk.child("symbol") != null) s.marker = MarkerStyle.from_id(mk.val("symbol"));
                    s.smooth = ser.val("smooth", "0") == "1";
                    var dl = ser.child("dLbls");
                    if (dl != null && (dl.val("showVal", "0") == "1" || dl.val("showPercent", "0") == "1")) s.labels = true;
                    var tr = ser.child("trendline");
                    if (tr != null) {
                        var tl = new Trendline();
                        tl.kind = TrendType.from_id(tr.val("trendlineType", "linear"));
                        tl.order = int.parse(tr.val("order", "2"));
                        tl.period = int.parse(tr.val("period", "2"));
                        tl.show_equation = tr.val("dispEq", "0") == "1";
                        tl.show_r2 = tr.val("dispRSqr", "0") == "1";
                        tl.forward = double.parse(tr.val("forward", "0"));
                        tl.backward = double.parse(tr.val("backward", "0"));
                        var nm = tr.child("name");
                        if (nm != null) tl.name = nm.text;
                        s.trendline = tl;
                    }
                    var eb = ser.child("errBars");
                    if (eb != null) {
                        var e = new ErrorBars();
                        e.kind = ErrorBarType.from_id(eb.val("errValType", "fixedVal"));
                        e.amount = double.parse(eb.val("val", "1"));
                        s.error_bars = e;
                    }
                    if (t == ChartType.SCATTER || t == ChartType.BUBBLE) {
                        var xv = ser.child("xVal");
                        s.x_ref = ref_formula(xv);
                        if (xv != null && (xv.find("numRef") != null || xv.find("numLit") != null)) s.xvalues = num_cache(xv);
                        else if (xv != null) {
                            s.categories = str_cache(xv);
                            s.categories_ref = s.x_ref;
                            s.x_ref = "";
                        }
                        var yv = ser.child("yVal");
                        s.values_ref = ref_formula(yv);
                        s.values = num_cache(yv);
                        var bs = ser.child("bubbleSize");
                        if (bs != null) {
                            s.sizes_ref = ref_formula(bs);
                            s.sizes = num_cache(bs);
                        }
                    } else {
                        var cat = ser.child("cat");
                        s.categories_ref = ref_formula(cat);
                        s.categories = str_cache(cat);
                        var v = ser.child("val");
                        s.values_ref = ref_formula(v);
                        s.values = num_cache(v);
                    }
                    if (t == ChartType.LINE && first_group && mk != null && mk.val("symbol") == "none") spec.markers = false;
                    if (t == ChartType.SCATTER) {
                        var sp = ser.child("spPr");
                        var ln = sp != null ? sp.child("ln") : null;
                        if (ln == null || ln.child("noFill") == null) spec.lines_on_scatter = true;
                    }
                    spec.series.add(s);
                }
                idx_offset++;
                first_group = false;
            }
            if (spec.series.size > 0 && spec.series[0].categories.length > 0) spec.categories = spec.series[0].categories;
            var ext = root.find("options");
            if (ext != null && ext.attr("kind") != "") {
                var k = ChartType.from_id(ext.attr("kind"));
                if (k.is_extended()) spec.kind = k;
                spec.markers = ext.attr("markers", "1") == "1";
                spec.lines_on_scatter = ext.attr("lines", "0") == "1";
                spec.bins = int.parse(ext.attr("bins", "0"));
                spec.palette = ext.attr("palette");
            }
            return spec;
        }

        private static ChartSpec read_chart_ex(XmlElement root) {
            var spec = new ChartSpec();
            var data_by_id = new Gee.HashMap<string, XmlElement>();
            var cd = root.child("chartData");
            if (cd != null) foreach (var d in cd.all("data")) data_by_id[d.attr("id")] = d;
            var chart = root.child("chart");
            if (chart == null) return spec;
            var title = chart.child("title");
            if (title != null) {
                var v = title.find("v");
                if (v != null) spec.title = v.text;
                else spec.title = rich_text(title);
            }
            var legend = chart.child("legend");
            spec.legend = legend != null ? LegendPosition.from_id(legend.attr("pos", "r")) : LegendPosition.NONE;
            var list = new Gee.ArrayList<XmlElement>();
            chart.find_all("series", list);
            bool first = true;
            foreach (var ser in list) {
                string lid = ser.attr("layoutId");
                if (lid == "paretoLine") {
                    spec.kind = ChartType.PARETO;
                    continue;
                }
                if (first) {
                    switch (lid) {
                        case "clusteredColumn": spec.kind = ChartType.HISTOGRAM; break;
                        case "boxWhisker": spec.kind = ChartType.BOX_WHISKER; break;
                        case "waterfall": spec.kind = ChartType.WATERFALL; break;
                        case "funnel": spec.kind = ChartType.FUNNEL; break;
                        case "treemap": spec.kind = ChartType.TREEMAP; break;
                        case "sunburst": spec.kind = ChartType.SUNBURST; break;
                        default: spec.kind = ChartType.COLUMN; break;
                    }
                    var bc = ser.find("binCount");
                    if (bc != null) spec.bins = int.parse(bc.attr("val"));
                    var bsz = ser.find("binSize");
                    if (bsz != null) spec.bin_width = XmlText.parse_num(bsz.attr("val"));
                    if (ser.find("aggregation") != null) spec.kind = ChartType.PARETO;
                }
                first = false;
                var s = new Series();
                var tx = ser.child("tx");
                if (tx != null) {
                    var f = tx.find("f");
                    if (f != null) s.name_ref = f.text.strip();
                    var v = tx.find("v");
                    if (v != null) s.name = v.text;
                }
                s.color = color_of(ser.child("spPr"));
                if (ser.find("dataLabels") != null) s.labels = true;
                var did = ser.child("dataId");
                var d = did != null ? data_by_id[did.attr("val")] : null;
                if (d != null) {
                    foreach (var dim in d.children) {
                        var f = dim.child("f");
                        var lvls = dim.all("lvl");
                        if (dim.local == "numDim") {
                            if (f != null) s.values_ref = f.text.strip();
                            if (lvls.size > 0) {
                                int count = int.parse(lvls[0].attr("ptCount", "0"));
                                double[] vals = new double[count];
                                for (int i = 0; i < count; i++) vals[i] = double.NAN;
                                foreach (var pt in lvls[0].all("pt")) {
                                    int idx = int.parse(pt.attr("idx"));
                                    if (idx >= 0 && idx < count) vals[idx] = XmlText.parse_num(pt.text);
                                }
                                s.values = vals;
                            }
                        } else if (dim.local == "strDim") {
                            if (f != null) s.categories_ref = f.text.strip();
                            if (lvls.size > 0) {
                                int count = int.parse(lvls[0].attr("ptCount", "0"));
                                string[] cats = new string[count];
                                for (int i = 0; i < count; i++) cats[i] = "";
                                for (int li = lvls.size - 1; li >= 0; li--) {
                                    string[] level = new string[count];
                                    foreach (var pt in lvls[li].all("pt")) {
                                        int idx = int.parse(pt.attr("idx"));
                                        if (idx >= 0 && idx < count) level[idx] = pt.text;
                                    }
                                    string last = "";
                                    for (int i = 0; i < count; i++) {
                                        if (level[i] != null && level[i] != "") last = level[i];
                                        string v = li == 0 ? (level[i] ?? "") : last;
                                        cats[i] = cats[i] == "" ? v : cats[i] + "\x1f" + v;
                                    }
                                }
                                s.categories = cats;
                            }
                        }
                    }
                }
                spec.series.add(s);
            }
            if (spec.series.size > 0) spec.categories = spec.series[0].categories;
            return spec;
        }
    }
}
