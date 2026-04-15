using Gtk;
using GLib;
using Cairo;

namespace Singularity.Widgets {

    // ── Sparkline widget ────────────────────────────────────────────────────

    /**
     * A compact sparkline graph that plots a rolling history of normalised values.
     *
     * Values pushed via `push()` must be in the range [0, 1].
     * The widget draws a filled area chart and a solid line on top.
     */
    public class SparkLine : DrawingArea {
        public double[] history;
        public int      history_size;
        private string  color_hex;
        private string? fill_hex;
        private int     _head = 0;
        private int     _count = 0;
        private Gdk.RGBA _col_rgba;
        private Gdk.RGBA _fill_rgba;


        /**
         * Creates a new sparkline.
         *
         * @param size  Number of data points in the rolling history.
         * @param color Line colour as a CSS hex string (e.g. `"#3584e4"`).
         * @param fill  Optional fill colour under the line (e.g. `"#3584e430"`).
         *              Pass `null` to disable the fill area.
         */
        public SparkLine(int size, string color, string? fill = null) {
            history_size = size;
            history      = new double[size];
            color_hex    = color;
            fill_hex     = fill;
            _col_rgba = {};
            _col_rgba.parse(color);
            _fill_rgba = {};
            if (fill != null) _fill_rgba.parse(fill);
            hexpand      = true;
            vexpand      = true;
            set_draw_func(draw);
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
            int n = _count;
            double step = (double)w / (double)(n - 1);

            // Fill
            if (fill_hex != null) {
                cr.move_to(0, h);
                for (int i = 0; i < n; i++) {
                    int idx = (_head + i) % history_size;
                    cr.line_to(i * step, h - history[idx] * h);
                }
                cr.line_to((n - 1) * step, h);
                cr.close_path();
                _fill_rgba.alpha = 0.18f;
                Gdk.cairo_set_source_rgba(cr, _fill_rgba);
                cr.fill();
            }

            // Line
            bool first = true;
            for (int i = 0; i < n; i++) {
                int idx = (_head + i) % history_size;
                double x = i * step;
                double y = h - history[idx] * h;
                if (first) { cr.move_to(x, y); first = false; }
                else        cr.line_to(x, y);
            }
            _col_rgba.alpha = 1.0f;
            Gdk.cairo_set_source_rgba(cr, _col_rgba);
            cr.set_line_width(2);
            cr.set_line_join(LineJoin.ROUND);
            cr.stroke();
        }
    }

    // ── Mini bar (for per-core CPU) ─────────────────────────────────────────

    /**
     * A vertical bar chart widget for displaying a single normalised value,
     * intended for per-core CPU or per-partition usage visualisations.
     */
    public class MiniBar : DrawingArea {
        private double _value = 0;
        private string _color;
        private Gdk.RGBA _col_rgba;

        /**
         * Creates a new mini bar.
         *
         * @param color Bar fill colour as a CSS hex string.
         */
        public MiniBar(string color) {
            _color = color;
            _col_rgba = {};
            _col_rgba.parse(color);
            set_size_request(18, -1);
            vexpand = true;
            set_draw_func(draw);
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
            // Background
            cr.rectangle(0, 0, w, h);
            cr.set_source_rgba(1, 1, 1, 0.06);
            cr.fill();
            double bh = _value * h;
            cr.rectangle(0, h - bh, w, bh);
            Gdk.cairo_set_source_rgba(cr, _col_rgba);
            cr.fill();
        }
    }

}
