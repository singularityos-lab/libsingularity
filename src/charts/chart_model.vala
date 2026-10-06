namespace Singularity.Charts {

    public enum ChartType {
        COLUMN,
        BAR,
        LINE,
        AREA,
        PIE,
        DOUGHNUT,
        SCATTER,
        BUBBLE,
        RADAR,
        STOCK,
        HISTOGRAM,
        PARETO,
        BOX_WHISKER,
        WATERFALL,
        FUNNEL,
        TREEMAP,
        SUNBURST;

        public string to_id() {
            switch (this) {
                case BAR: return "bar";
                case LINE: return "line";
                case AREA: return "area";
                case PIE: return "pie";
                case DOUGHNUT: return "doughnut";
                case SCATTER: return "scatter";
                case BUBBLE: return "bubble";
                case RADAR: return "radar";
                case STOCK: return "stock";
                case HISTOGRAM: return "histogram";
                case PARETO: return "pareto";
                case BOX_WHISKER: return "box";
                case WATERFALL: return "waterfall";
                case FUNNEL: return "funnel";
                case TREEMAP: return "treemap";
                case SUNBURST: return "sunburst";
                default: return "column";
            }
        }

        public static ChartType from_id(string id) {
            switch (id) {
                case "bar": return BAR;
                case "line": return LINE;
                case "area": return AREA;
                case "pie": return PIE;
                case "doughnut": return DOUGHNUT;
                case "scatter": return SCATTER;
                case "bubble": return BUBBLE;
                case "radar": return RADAR;
                case "stock": return STOCK;
                case "histogram": return HISTOGRAM;
                case "pareto": return PARETO;
                case "box": return BOX_WHISKER;
                case "waterfall": return WATERFALL;
                case "funnel": return FUNNEL;
                case "treemap": return TREEMAP;
                case "sunburst": return SUNBURST;
                default: return COLUMN;
            }
        }

        public bool is_extended() {
            return this == HISTOGRAM || this == PARETO || this == BOX_WHISKER || this == WATERFALL || this == FUNNEL || this == TREEMAP || this == SUNBURST;
        }

        public bool is_radial() {
            return this == PIE || this == DOUGHNUT;
        }

        public bool has_axes() {
            return !is_radial() && this != TREEMAP && this != SUNBURST && this != FUNNEL && this != RADAR;
        }
    }

    public enum Grouping {
        CLUSTERED,
        STACKED,
        PERCENT;

        public string to_id() {
            switch (this) {
                case STACKED: return "stacked";
                case PERCENT: return "percent";
                default: return "clustered";
            }
        }

        public static Grouping from_id(string id) {
            switch (id) {
                case "stacked": return STACKED;
                case "percent": case "percentStacked": return PERCENT;
                default: return CLUSTERED;
            }
        }
    }

    public enum LegendPosition {
        NONE,
        TOP,
        BOTTOM,
        LEFT,
        RIGHT;

        public string to_id() {
            switch (this) {
                case NONE: return "none";
                case TOP: return "t";
                case BOTTOM: return "b";
                case LEFT: return "l";
                default: return "r";
            }
        }

        public static LegendPosition from_id(string id) {
            switch (id) {
                case "none": return NONE;
                case "t": case "top": return TOP;
                case "b": case "bottom": return BOTTOM;
                case "l": case "left": return LEFT;
                default: return RIGHT;
            }
        }
    }

    public enum TrendType {
        NONE,
        LINEAR,
        EXPONENTIAL,
        LOGARITHMIC,
        POLYNOMIAL,
        POWER,
        MOVING_AVERAGE;

        public string to_id() {
            switch (this) {
                case LINEAR: return "linear";
                case EXPONENTIAL: return "exp";
                case LOGARITHMIC: return "log";
                case POLYNOMIAL: return "poly";
                case POWER: return "power";
                case MOVING_AVERAGE: return "movingAvg";
                default: return "none";
            }
        }

        public static TrendType from_id(string id) {
            switch (id) {
                case "linear": return LINEAR;
                case "exp": case "exponential": return EXPONENTIAL;
                case "log": case "logarithmic": return LOGARITHMIC;
                case "poly": case "polynomial": return POLYNOMIAL;
                case "power": return POWER;
                case "movingAvg": case "moving-average": return MOVING_AVERAGE;
                default: return NONE;
            }
        }
    }

    public enum ErrorBarType {
        NONE,
        FIXED,
        PERCENT,
        STDDEV,
        STDERR;

        public string to_id() {
            switch (this) {
                case FIXED: return "fixedVal";
                case PERCENT: return "percentage";
                case STDDEV: return "stdDev";
                case STDERR: return "stdErr";
                default: return "none";
            }
        }

        public static ErrorBarType from_id(string id) {
            switch (id) {
                case "fixedVal": case "constant": return FIXED;
                case "percentage": case "percent": return PERCENT;
                case "stdDev": case "standard-deviation": return STDDEV;
                case "stdErr": case "standard-error": return STDERR;
                default: return NONE;
            }
        }
    }

    public enum MarkerStyle {
        AUTO,
        NONE,
        CIRCLE,
        SQUARE,
        DIAMOND,
        TRIANGLE;

        public string to_id() {
            switch (this) {
                case NONE: return "none";
                case CIRCLE: return "circle";
                case SQUARE: return "square";
                case DIAMOND: return "diamond";
                case TRIANGLE: return "triangle";
                default: return "auto";
            }
        }

        public static MarkerStyle from_id(string id) {
            switch (id) {
                case "none": return NONE;
                case "circle": return CIRCLE;
                case "square": return SQUARE;
                case "diamond": return DIAMOND;
                case "triangle": return TRIANGLE;
                default: return AUTO;
            }
        }
    }

    public class Trendline : Object {
        public TrendType kind = TrendType.LINEAR;
        public int order = 2;
        public int period = 2;
        public bool show_equation;
        public bool show_r2;
        public string name = "";
        public double forward;
        public double backward;

        public Trendline copy() {
            var t = new Trendline();
            t.kind = kind;
            t.order = order;
            t.period = period;
            t.show_equation = show_equation;
            t.show_r2 = show_r2;
            t.name = name;
            t.forward = forward;
            t.backward = backward;
            return t;
        }
    }

    public class ErrorBars : Object {
        public ErrorBarType kind = ErrorBarType.FIXED;
        public double amount = 1;

        public ErrorBars copy() {
            var e = new ErrorBars();
            e.kind = kind;
            e.amount = amount;
            return e;
        }
    }

    public class Axis : Object {
        public string title = "";
        public double min = double.NAN;
        public double max = double.NAN;
        public double major_unit = double.NAN;
        public double log_base;
        public string number_format = "";
        public bool visible = true;
        public bool gridlines = true;
        public bool reverse;

        public Axis copy() {
            var a = new Axis();
            a.title = title;
            a.min = min;
            a.max = max;
            a.major_unit = major_unit;
            a.log_base = log_base;
            a.number_format = number_format;
            a.visible = visible;
            a.gridlines = gridlines;
            a.reverse = reverse;
            return a;
        }
    }

    public class Series : Object {
        public string name = "";
        public string name_ref = "";
        public string values_ref = "";
        public string categories_ref = "";
        public string x_ref = "";
        public string sizes_ref = "";
        public double[] values = {};
        public string[] categories = {};
        public double[] xvalues = {};
        public double[] sizes = {};
        public bool has_type;
        public ChartType kind = ChartType.COLUMN;
        public bool secondary;
        public bool smooth;
        public MarkerStyle marker = MarkerStyle.AUTO;
        public string color = "";
        public double line_width = 2;
        public bool labels;
        public Trendline? trendline;
        public ErrorBars? error_bars;

        public Series copy() {
            var s = new Series();
            s.name = name;
            s.name_ref = name_ref;
            s.values_ref = values_ref;
            s.categories_ref = categories_ref;
            s.x_ref = x_ref;
            s.sizes_ref = sizes_ref;
            s.values = values;
            s.categories = categories;
            s.xvalues = xvalues;
            s.sizes = sizes;
            s.has_type = has_type;
            s.kind = kind;
            s.secondary = secondary;
            s.smooth = smooth;
            s.marker = marker;
            s.color = color;
            s.line_width = line_width;
            s.labels = labels;
            s.trendline = trendline != null ? trendline.copy() : null;
            s.error_bars = error_bars != null ? error_bars.copy() : null;
            return s;
        }
    }

    public class ChartSpec : Object {
        public ChartType kind = ChartType.COLUMN;
        public Grouping grouping = Grouping.CLUSTERED;
        public string title = "";
        public LegendPosition legend = LegendPosition.RIGHT;
        public Axis x_axis = new Axis();
        public Axis y_axis = new Axis();
        public Axis y2_axis = new Axis();
        public Gee.ArrayList<Series> series = new Gee.ArrayList<Series>();
        public string[] categories = {};
        public int gap_width = 150;
        public int overlap;
        public int hole_size = 50;
        public bool markers = true;
        public bool smooth;
        public bool data_labels;
        public bool vary_colors;
        public bool lines_on_scatter;
        public bool filled_radar;
        public int bins;
        public double bin_width = double.NAN;
        public int first_slice_angle;
        public int style;
        public string palette = "";

        public ChartSpec copy() {
            var c = new ChartSpec();
            c.kind = kind;
            c.grouping = grouping;
            c.title = title;
            c.legend = legend;
            c.x_axis = x_axis.copy();
            c.y_axis = y_axis.copy();
            c.y2_axis = y2_axis.copy();
            foreach (var s in series) c.series.add(s.copy());
            c.categories = categories;
            c.gap_width = gap_width;
            c.overlap = overlap;
            c.hole_size = hole_size;
            c.markers = markers;
            c.smooth = smooth;
            c.data_labels = data_labels;
            c.vary_colors = vary_colors;
            c.lines_on_scatter = lines_on_scatter;
            c.filled_radar = filled_radar;
            c.bins = bins;
            c.bin_width = bin_width;
            c.first_slice_angle = first_slice_angle;
            c.style = style;
            c.palette = palette;
            return c;
        }

        public ChartType type_of(Series s) {
            return s.has_type ? s.kind : kind;
        }

        public bool has_secondary() {
            foreach (var s in series) if (s.secondary) return true;
            return false;
        }

        public bool is_combo() {
            foreach (var s in series) if (s.has_type && s.kind != kind) return true;
            return false;
        }

        public string[] category_labels() {
            if (categories.length > 0) return categories;
            foreach (var s in series) if (s.categories.length > 0) return s.categories;
            int n = 0;
            foreach (var s in series) n = int.max(n, s.values.length);
            string[] out_c = {};
            for (int i = 0; i < n; i++) out_c += (i + 1).to_string();
            return out_c;
        }
    }
}
