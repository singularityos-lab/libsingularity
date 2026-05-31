using Gtk;
using GLib;
using Cairo;

namespace Singularity.Widgets {

    // Internal helper: resolve the system accent color from the active GTK
    // style context, falling back to a sensible default if unavailable. We
    // re-read on every draw call so themes that recolour at runtime stay
    // in sync without explicit listener wiring.
    internal Gdk.RGBA _resolve_accent_rgba(Gtk.Widget widget) {
        var sc = widget.get_style_context();
        Gdk.RGBA c = Gdk.RGBA();
        if (sc.lookup_color("accent_color", out c)) return c;
        if (sc.lookup_color("accent_bg_color", out c)) return c;
        c = Gdk.RGBA();
        c.red = 0.357f; c.green = 0.310f; c.blue = 0.851f; c.alpha = 1.0f;
        return c;
    }

    // -- Sparkline widget ----------------------------------------------------

    /**
     * A compact sparkline graph that plots a rolling history of normalised values.
     *
     * Values pushed via `push()` must be in the range [0, 1]. The widget
     * draws a filled area chart and a solid line on top. When `color` is
     * null the system accent colour is used (re-read on every draw so
     * runtime accent changes propagate automatically).
     */
    public class SparkLine : DrawingArea {
        public double[] history;
        public int      history_size;
        private string?  color_hex;
        private string?  fill_hex;
        private int     _head  = 0;
        private int     _count = 0;
        private Gdk.RGBA _col_rgba;
        private Gdk.RGBA _fill_rgba;

        /**
         * Creates a new sparkline.
         *
         * @param size  Number of data points in the rolling history.
         * @param color Line colour as a CSS hex string (e.g. `"#3584e4"`),
         *              or null to track the system accent colour.
         * @param fill  Optional fill colour under the line. Pass `null` to
         *              derive it from the line colour with 18% alpha.
         */
        public SparkLine(int size, string? color = null, string? fill = null) {
            history_size = size;
            history      = new double[size];
            color_hex    = color;
            fill_hex     = fill;
            _col_rgba    = Gdk.RGBA();
            _fill_rgba   = Gdk.RGBA();
            if (color != null) _col_rgba.parse(color);
            if (fill  != null) _fill_rgba.parse(fill);
            hexpand = true;
            vexpand = true;
            set_draw_func(draw);
        }

        /**
         * Override the line colour at runtime. Pass null to revert to the
         * system accent colour.
         */
        public void set_color(string? hex) {
            color_hex = hex;
            if (hex != null) _col_rgba.parse(hex);
            queue_draw();
        }

        /**
         * Pushes a new data point into the rolling history and redraws.
         *
         * @param val Normalised value in the range [0, 1].
         */
        public void push(double val) {
            if (_count < history_size) {
                history[_count] = val.clamp(0, 1);
                _count++;
            } else {
                history[_head] = val.clamp(0, 1);
                _head = (_head + 1) % history_size;
            }
            queue_draw();
        }

        private void draw(DrawingArea a, Context cr, int w, int h) {
            if (_count < 2) return;

            Gdk.RGBA line_col;
            if (color_hex != null) line_col = _col_rgba;
            else                    line_col = _resolve_accent_rgba(this);

            Gdk.RGBA fill_col;
            if (fill_hex != null) {
                fill_col = _fill_rgba;
            } else {
                fill_col = line_col;
                fill_col.alpha = 0.18f;
            }

            int n = _count;
            double step = (double)w / (double)(n - 1);

            cr.move_to(0, h);
            for (int i = 0; i < n; i++) {
                int idx = (_head + i) % history_size;
                cr.line_to(i * step, h - history[idx] * h);
            }
            cr.line_to((n - 1) * step, h);
            cr.close_path();
            Gdk.cairo_set_source_rgba(cr, fill_col);
            cr.fill();

            bool first = true;
            for (int i = 0; i < n; i++) {
                int idx = (_head + i) % history_size;
                double x = i * step;
                double y = h - history[idx] * h;
                if (first) { cr.move_to(x, y); first = false; }
                else        cr.line_to(x, y);
            }
            var stroke = line_col;
            stroke.alpha = 1.0f;
            Gdk.cairo_set_source_rgba(cr, stroke);
            cr.set_line_width(2);
            cr.set_line_join(LineJoin.ROUND);
            cr.stroke();
        }
    }

    // -- Mini bar (for per-core CPU) -----------------------------------------

    /**
     * A vertical bar chart widget for displaying a single normalised value,
     * intended for per-core CPU or per-partition usage visualisations.
     */
    public class MiniBar : DrawingArea {
        private double  _value = 0;
        private string? _color;
        private Gdk.RGBA _col_rgba;

        /**
         * Creates a new mini bar.
         *
         * @param color Bar fill colour as a CSS hex string, or null to
         *              track the system accent colour.
         */
        public MiniBar(string? color = null) {
            _color    = color;
            _col_rgba = Gdk.RGBA();
            if (color != null) _col_rgba.parse(color);
            set_size_request(18, -1);
            vexpand = true;
            set_draw_func(draw);
        }

        /**
         * Override the bar colour at runtime. Pass null to revert to the
         * system accent colour.
         */
        public void set_color(string? hex) {
            _color = hex;
            if (hex != null) _col_rgba.parse(hex);
            queue_draw();
        }

        /**
         * Sets the bar fill level and triggers a redraw.
         *
         * @param v Normalised value in the range [0, 1].
         */
        public void set_value(double v) {
            _value = v.clamp(0, 1);
            queue_draw();
        }

        private void draw(DrawingArea a, Context cr, int w, int h) {
            cr.rectangle(0, 0, w, h);
            cr.set_source_rgba(1, 1, 1, 0.06);
            cr.fill();

            double bh = _value * h;
            cr.rectangle(0, h - bh, w, bh);
            Gdk.RGBA col = (_color != null) ? _col_rgba : _resolve_accent_rgba(this);
            Gdk.cairo_set_source_rgba(cr, col);
            cr.fill();
        }
    }
}
