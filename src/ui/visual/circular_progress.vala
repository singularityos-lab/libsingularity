using Gtk;

namespace Singularity.Widgets {

    /**
     * Small circular progress indicator with a centered label.
     * Used by dock item suffix widgets (e.g. CPU/RAM gauges, download progress).
     *
     * The ring is drawn in the CSS `color` (foreground) and the track in
     * the CSS color of class `.dock-circular-track` when present, otherwise
     * a translucent variant of `color`.
     */
    public class CircularProgress : Gtk.Widget {
        private double _fraction = 0.0;
        private string _label = "";
        private string? _color_css = null;
        private int _diameter = 30;
        private double _stroke = 3.0;

        public double fraction {
            get { return _fraction; }
            set {
                double v = value;
                if (v < 0) v = 0;
                if (v > 1) v = 1;
                if (Math.fabs(v - _fraction) < 0.001) return;
                _fraction = v;
                queue_draw();
            }
        }

        public string label {
            get { return _label; }
            set {
                if (_label == value) return;
                _label = value ?? "";
                queue_draw();
            }
        }

        /** Optional override colour ("#RRGGBB" or "rgba(...)") for the ring. */
        public string? color {
            get { return _color_css; }
            set {
                _color_css = value;
                queue_draw();
            }
        }

        public int diameter {
            get { return _diameter; }
            set {
                if (value < 12) value = 12;
                if (_diameter == value) return;
                _diameter = value;
                _stroke = double.max(2.0, value / 10.0);
                queue_resize();
            }
        }

        public CircularProgress(int diameter = 30) {
            this.diameter = diameter;
            add_css_class("dock-circular-progress");
            valign = Align.CENTER;
            halign = Align.CENTER;
        }

        public override void measure(Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum = _diameter;
            natural = _diameter;
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        private static bool parse_rgba(string css, out Gdk.RGBA rgba) {
            rgba = Gdk.RGBA();
            return rgba.parse(css);
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            int w = get_width();
            int h = get_height();
            double size = double.min(w, h);
            double cx = w / 2.0;
            double cy = h / 2.0;
            double radius = (size - _stroke) / 2.0;

            var bounds = Graphene.Rect();
            bounds.init(0, 0, w, h);
            var cr = snapshot.append_cairo(bounds);

            var fg = get_color();
            Gdk.RGBA ring_rgba = fg;
            if (_color_css != null && _color_css != "") {
                Gdk.RGBA parsed;
                if (parse_rgba(_color_css, out parsed)) ring_rgba = parsed;
            }

            // Track
            cr.set_line_width(_stroke);
            cr.set_line_cap(Cairo.LineCap.ROUND);
            cr.set_source_rgba(ring_rgba.red, ring_rgba.green, ring_rgba.blue, 0.18);
            cr.arc(cx, cy, radius, 0, 2 * Math.PI);
            cr.stroke();

            // Filled arc starting from -90deg (12 o'clock), going clockwise.
            if (_fraction > 0.0) {
                cr.set_source_rgba(ring_rgba.red, ring_rgba.green, ring_rgba.blue, ring_rgba.alpha);
                double start = -Math.PI / 2.0;
                double end = start + 2 * Math.PI * _fraction;
                cr.arc(cx, cy, radius, start, end);
                cr.stroke();
            }

            if (_label != "") {
                var layout = create_pango_layout(_label);
                var font = new Pango.FontDescription();
                font.set_family("sans");
                font.set_absolute_size((int)(size * 0.40 * Pango.SCALE));
                font.set_weight(Pango.Weight.SEMIBOLD);
                layout.set_font_description(font);
                int tw, th;
                layout.get_pixel_size(out tw, out th);
                cr.move_to(cx - tw / 2.0, cy - th / 2.0);
                cr.set_source_rgba(fg.red, fg.green, fg.blue, fg.alpha);
                Pango.cairo_show_layout(cr, layout);
            }
        }
    }
}
