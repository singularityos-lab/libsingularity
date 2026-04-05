using Gtk;
using Cairo;

namespace Singularity.Widgets {

    /**
     * A horizontal ruler widget for document editors.
     *
     * Renders a millimetre scale across the full page width and draws two
     * draggable margin handles. Drag the handles to resize margins; the
     * widget emits `margins_changed` when a drag ends.
     */
    public class RulerWidget : DrawingArea {
        private double _page_width_mm = 210.0;
        private double _left_margin_mm = 25.0;
        private double _right_margin_mm = 25.0;
        private bool _dragging_left = false;
        private bool _dragging_right = false;
        private double _drag_start_x = 0;
        private double _drag_start_margin = 0;

        /** Total page width in millimetres. Changing this redraws the ruler. */
        public double page_width_mm {
            get { return _page_width_mm; }
            set { _page_width_mm = value; queue_draw(); }
        }
        /** Left margin in millimetres. Changing this redraws the ruler. */
        public double left_margin_mm {
            get { return _left_margin_mm; }
            set { _left_margin_mm = value; queue_draw(); }
        }
        /** Right margin in millimetres. Changing this redraws the ruler. */
        public double right_margin_mm {
            get { return _right_margin_mm; }
            set { _right_margin_mm = value; queue_draw(); }
        }

        /**
         * Emitted when the user finishes dragging a margin handle.
         *
         * @param left_mm  New left margin in millimetres.
         * @param right_mm New right margin in millimetres.
         */
        public signal void margins_changed(double left_mm, double right_mm);

        public RulerWidget() {
            Object();
            set_size_request(-1, 22);
            hexpand = true;
            add_css_class("write-ruler");
            set_draw_func(on_draw);

            var drag = new GestureDrag();
            drag.drag_begin.connect(on_drag_begin);
            drag.drag_update.connect(on_drag_update);
            drag.drag_end.connect(on_drag_end);
            add_controller(drag);

            var motion = new EventControllerMotion();
            motion.motion.connect(on_motion);
            add_controller(motion);
        }

        private double scale(int widget_w) {
            return widget_w / _page_width_mm;
        }
        private double left_handle_x(int w)  { return _left_margin_mm * scale(w); }
        private double right_handle_x(int w) { return w - _right_margin_mm * scale(w); }

        private void on_draw(DrawingArea da, Context cr, int w, int h) {
            double sc = scale(w);
            double lx = left_handle_x(w);
            double rx = right_handle_x(w);

            // full page area: slightly lighter than window bg
            cr.set_source_rgba(0.20, 0.20, 0.20, 1);
            cr.rectangle(0, 0, w, h);
            cr.fill();

            // margin zones: even darker
            cr.set_source_rgba(0.13, 0.13, 0.13, 1);
            cr.rectangle(0, 0, lx, h);
            cr.fill();
            cr.rectangle(rx, 0, w - rx, h);
            cr.fill();

            // Ticks
            for (double mm = 0; mm <= _page_width_mm + 0.5; mm += 1.0) {
                double x = mm * sc;
                int imm = (int)mm;
                double tick_h;
                if (imm % 10 == 0)       tick_h = h * 0.65;
                else if (imm % 5 == 0)   tick_h = h * 0.45;
                else                      tick_h = h * 0.25;

                cr.set_source_rgba(0.58, 0.58, 0.58, 1.0);
                cr.set_line_width(1.0);
                cr.move_to((int)x + 0.5, 0);
                cr.line_to((int)x + 0.5, tick_h);
                cr.stroke();

                if (imm % 10 == 0 && imm > 0 && mm < _page_width_mm) {
                    cr.set_source_rgba(0.50, 0.50, 0.50, 1.0);
                    cr.select_font_face("Sans", FontSlant.NORMAL, FontWeight.NORMAL);
                    cr.set_font_size(7.5);
                    cr.move_to((int)x + 2, h - 2);
                    cr.show_text(imm.to_string());
                }
            }

            // Margin lines
            cr.set_source_rgba(0.78, 0.45, 0.10, 0.6);
            cr.set_line_width(1.0);
            cr.move_to(lx + 0.5, 0); cr.line_to(lx + 0.5, h); cr.stroke();
            cr.move_to(rx + 0.5, 0); cr.line_to(rx + 0.5, h); cr.stroke();

            // Handles (filled triangles)
            draw_handle(cr, lx, h, true);
            draw_handle(cr, rx, h, false);
        }

        private void draw_handle(Context cr, double x, int h, bool is_left) {
            double sz = 6;
            cr.set_source_rgba(0.90, 0.52, 0.15, 1.0);
            cr.move_to(x, 0);
            if (is_left) {
                cr.line_to(x + sz, 0);
                cr.line_to(x, sz);
            } else {
                cr.line_to(x - sz, 0);
                cr.line_to(x, sz);
            }
            cr.close_path();
            cr.fill();
        }

        private void on_drag_begin(double x, double y) {
            int aw = get_allocated_width();
            _drag_start_x = x;
            double lx = left_handle_x(aw);
            double rx = right_handle_x(aw);
            if (GLib.Math.fabs(x - lx) < 12) {
                _dragging_left = true;
                _drag_start_margin = _left_margin_mm;
            } else if (GLib.Math.fabs(x - rx) < 12) {
                _dragging_right = true;
                _drag_start_margin = _right_margin_mm;
            }
        }

        private void on_drag_update(double dx, double dy) {
            int aw = get_allocated_width();
            double sc = scale(aw);
            double delta_mm = dx / sc;
            if (_dragging_left) {
                _left_margin_mm = (_drag_start_margin + delta_mm)
                    .clamp(0, _page_width_mm - _right_margin_mm - 10);
                queue_draw();
                margins_changed(_left_margin_mm, _right_margin_mm);
            } else if (_dragging_right) {
                _right_margin_mm = (_drag_start_margin - delta_mm)
                    .clamp(0, _page_width_mm - _left_margin_mm - 10);
                queue_draw();
                margins_changed(_left_margin_mm, _right_margin_mm);
            }
        }

        private void on_drag_end(double dx, double dy) {
            _dragging_left = false;
            _dragging_right = false;
        }

        private void on_motion(double x, double y) {
            int aw = get_allocated_width();
            if (GLib.Math.fabs(x - left_handle_x(aw)) < 12 ||
                GLib.Math.fabs(x - right_handle_x(aw)) < 12) {
                cursor = new Gdk.Cursor.from_name("col-resize", null);
            } else {
                cursor = null;
            }
        }
    }
}
