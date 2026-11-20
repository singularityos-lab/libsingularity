using Gtk;

namespace Singularity.Widgets {

    public class LedMatrixView : DrawingArea {
        public int columns { get; private set; default = 13; }
        public int rows { get; private set; default = 8; }
        public bool editable { get; set; default = false; }
        public bool show_grid { get; set; default = false; }
        public Gdk.RGBA color { get; set; }
        public int cell_size { get; set; default = 0; }
        public int padding { get; set; default = 12; }

        private uint8[] pixels = new uint8[13 * 8];
        private int hover_x = -1;
        private int hover_y = -1;
        private int last_x = -1;
        private int last_y = -1;

        public signal void paint(int x, int y, bool erase, bool first);
        public signal void stroke_finished();

        public LedMatrixView() {
            var c = Gdk.RGBA();
            c.parse("#ff5a3c");
            color = c;
            add_css_class("led-matrix-view");
            set_draw_func(draw);
            hexpand = true;
            vexpand = true;
            notify["color"].connect(queue_draw);
            notify["show-grid"].connect(queue_draw);
            notify["cell-size"].connect(queue_resize);
            notify["padding"].connect(queue_resize);

            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => {
                int cx, cy;
                bool inside = cell_at(x, y, out cx, out cy);
                int nx = inside ? cx : -1;
                int ny = inside ? cy : -1;
                if (nx != hover_x || ny != hover_y) {
                    hover_x = nx;
                    hover_y = ny;
                    if (editable) queue_draw();
                }
            });
            motion.leave.connect(() => {
                hover_x = -1;
                hover_y = -1;
                if (editable) queue_draw();
            });
            add_controller(motion);

            var drag = new GestureDrag();
            drag.button = 0;
            drag.drag_begin.connect((x, y) => {
                if (!editable) return;
                last_x = -1;
                last_y = -1;
                stroke(x, y, drag.get_current_button() == Gdk.BUTTON_SECONDARY, true);
            });
            drag.drag_update.connect((dx, dy) => {
                if (!editable) return;
                double sx, sy;
                drag.get_start_point(out sx, out sy);
                stroke(sx + dx, sy + dy, drag.get_current_button() == Gdk.BUTTON_SECONDARY, false);
            });
            drag.drag_end.connect(() => {
                if (editable) stroke_finished();
            });
            add_controller(drag);
        }

        public void set_size(int columns, int rows) {
            if (columns == this.columns && rows == this.rows) return;
            this.columns = int.max(columns, 1);
            this.rows = int.max(rows, 1);
            pixels = new uint8[this.columns * this.rows];
            queue_resize();
            queue_draw();
        }

        public void set_pixels(uint8[] data) {
            if (data.length != pixels.length) return;
            if (Memory.cmp(data, pixels, data.length) == 0) return;
            Memory.copy(pixels, data, data.length);
            queue_draw();
        }

        private void stroke(double x, double y, bool erase, bool first) {
            int cx, cy;
            if (!cell_at(x, y, out cx, out cy)) return;
            if (!first && cx == last_x && cy == last_y) return;
            last_x = cx;
            last_y = cy;
            paint(cx, cy, erase, first);
        }

        private void geometry(out double pitch, out double ox, out double oy) {
            int w = get_width();
            int h = get_height();
            double pad = padding;
            pitch = cell_size > 0 ? cell_size : double.min((w - pad * 2) / columns, (h - pad * 2) / rows);
            if (pitch < 2) pitch = 2;
            ox = (w - pitch * columns) / 2;
            oy = (h - pitch * rows) / 2;
        }

        private bool cell_at(double x, double y, out int cx, out int cy) {
            double pitch, ox, oy;
            geometry(out pitch, out ox, out oy);
            cx = (int) Math.floor((x - ox) / pitch);
            cy = (int) Math.floor((y - oy) / pitch);
            return cx >= 0 && cy >= 0 && cx < columns && cy < rows;
        }

        protected override void measure(Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            int cells = orientation == Orientation.HORIZONTAL ? columns : rows;
            if (cell_size > 0) {
                minimum = natural = cells * cell_size + padding * 2;
                minimum_baseline = -1;
                natural_baseline = -1;
                return;
            }
            minimum = cells * 2 + padding * 2;
            natural = cells * 28 + padding * 2;
            if (for_size > 0) {
                int other = orientation == Orientation.HORIZONTAL ? rows : columns;
                natural = int.max(minimum, (int) ((for_size - padding * 2) * (double) cells / other) + padding * 2);
            }
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        protected override SizeRequestMode get_request_mode() {
            return SizeRequestMode.HEIGHT_FOR_WIDTH;
        }

        private void draw(DrawingArea area, Cairo.Context cr, int width, int height) {
            double pitch, ox, oy;
            geometry(out pitch, out ox, out oy);
            double radius = pitch * 0.34;

            if (radius < 1.2) radius = pitch * 0.45;
            cr.save();
            rounded(cr, ox - pitch * 0.25, oy - pitch * 0.25, pitch * (columns + 0.5), pitch * (rows + 0.5), pitch * 0.45);
            cr.set_source_rgb(0.105, 0.125, 0.16);
            cr.fill();
            cr.restore();

            double r = color.red, g = color.green, b = color.blue;
            for (int y = 0; y < rows; y++) {
                for (int x = 0; x < columns; x++) {
                    double cx = ox + (x + 0.5) * pitch;
                    double cy = oy + (y + 0.5) * pitch;
                    uint8 v = pixels[y * columns + x];
                    if (v == 0) {
                        cr.arc(cx, cy, radius, 0, Math.PI * 2);
                        cr.set_source_rgb(0.17, 0.195, 0.24);
                        cr.fill();
                        continue;
                    }
                    double a = 0.18 + 0.82 * (v / 7.0);
                    var glow = new Cairo.Pattern.radial(cx, cy, 0, cx, cy, pitch * 0.7);
                    glow.add_color_stop_rgba(0, r, g, b, 0.45 * a);
                    glow.add_color_stop_rgba(1, r, g, b, 0);
                    cr.set_source(glow);
                    cr.arc(cx, cy, pitch * 0.7, 0, Math.PI * 2);
                    cr.fill();
                    var core = new Cairo.Pattern.radial(cx - radius * 0.3, cy - radius * 0.3, 0, cx, cy, radius);
                    core.add_color_stop_rgba(0, double.min(1, r + 0.45 * a), double.min(1, g + 0.45 * a), double.min(1, b + 0.45 * a), a);
                    core.add_color_stop_rgba(1, r, g, b, a);
                    cr.arc(cx, cy, radius, 0, Math.PI * 2);
                    cr.set_source_rgb(0.17, 0.195, 0.24);
                    cr.fill_preserve();
                    cr.set_source(core);
                    cr.fill();
                }
            }

            if (show_grid) {
                cr.set_line_width(1);
                cr.set_source_rgba(1, 1, 1, 0.06);
                for (int x = 1; x < columns; x++) {
                    cr.move_to(Math.round(ox + x * pitch) + 0.5, oy);
                    cr.line_to(Math.round(ox + x * pitch) + 0.5, oy + rows * pitch);
                }
                for (int y = 1; y < rows; y++) {
                    cr.move_to(ox, Math.round(oy + y * pitch) + 0.5);
                    cr.line_to(ox + columns * pitch, Math.round(oy + y * pitch) + 0.5);
                }
                cr.stroke();
            }

            if (editable && hover_x >= 0) {
                cr.set_line_width(2);
                cr.set_source_rgba(1, 1, 1, 0.55);
                cr.arc(ox + (hover_x + 0.5) * pitch, oy + (hover_y + 0.5) * pitch, radius + 3, 0, Math.PI * 2);
                cr.stroke();
            }
        }

        private static void rounded(Cairo.Context cr, double x, double y, double w, double h, double r) {
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, Math.PI * 1.5);
            cr.close_path();
        }
    }
}
