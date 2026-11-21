using Gtk;

namespace Singularity.Widgets {

    public class PatternPad : Widget {
        private const int SIDE = 264;
        private const int MIN_DOTS = 4;

        private int[] path = {};
        private bool tracking = false;
        private bool error = false;
        private double finger_x;
        private double finger_y;
        private double origin_x;
        private double origin_y;

        public signal void drawn(string sequence);
        public signal void too_short();
        public signal void node_added();

        public PatternPad() {
            add_css_class("singularity-pattern-pad");
            halign = Align.CENTER;
            var drag = new GestureDrag();
            drag.drag_begin.connect((x, y) => {
                origin_x = x;
                origin_y = y;
                int node = node_at(x, y);
                if (node < 0) {
                    drag.set_state(EventSequenceState.DENIED);
                    return;
                }
                drag.set_state(EventSequenceState.CLAIMED);
                path = {};
                error = false;
                tracking = true;
                finger_x = x;
                finger_y = y;
                add(node);
                queue_draw();
            });
            drag.drag_update.connect((dx, dy) => {
                if (!tracking) return;
                finger_x = origin_x + dx;
                finger_y = origin_y + dy;
                int node = node_at(finger_x, finger_y);
                if (node >= 0) add(node);
                queue_draw();
            });
            drag.drag_end.connect(() => {
                if (!tracking) return;
                tracking = false;
                if (path.length < MIN_DOTS) {
                    error = true;
                    queue_draw();
                    too_short();
                    return;
                }
                var sb = new StringBuilder();
                foreach (int n in path) sb.append_c((char) ('1' + n));
                queue_draw();
                drawn(sb.str);
            });
            add_controller(drag);
        }

        public void reset() {
            path = {};
            error = false;
            tracking = false;
            queue_draw();
        }

        public void show_error() {
            error = true;
            queue_draw();
        }

        public override void measure(Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum = natural = SIDE;
            minimum_baseline = natural_baseline = -1;
        }

        private double cell() {
            return double.min(get_width(), get_height()) / 3.0;
        }

        private void center(int node, out double x, out double y) {
            double c = cell();
            double left = (get_width() - c * 3) / 2.0;
            double top = (get_height() - c * 3) / 2.0;
            x = left + c * (node % 3) + c / 2.0;
            y = top + c * (node / 3) + c / 2.0;
        }

        private int node_at(double x, double y) {
            double hit = cell() * 0.3;
            for (int i = 0; i < 9; i++) {
                double cx, cy;
                center(i, out cx, out cy);
                if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= hit * hit) return i;
            }
            return -1;
        }

        private bool visited(int node) {
            foreach (int n in path) if (n == node) return true;
            return false;
        }

        private void add(int node) {
            if (visited(node) || path.length >= 9) return;
            if (path.length > 0) {
                int last = path[path.length - 1];
                int r1 = last / 3, c1 = last % 3, r2 = node / 3, c2 = node % 3;
                if ((r1 + r2) % 2 == 0 && (c1 + c2) % 2 == 0) {
                    int mid = ((r1 + r2) / 2) * 3 + (c1 + c2) / 2;
                    if (mid != last && mid != node && !visited(mid)) path += mid;
                }
            }
            path += node;
            node_added();
        }

        public override void snapshot(Snapshot snapshot) {
            var bounds = Graphene.Rect().init(0, 0, get_width(), get_height());
            var cr = snapshot.append_cairo(bounds);
            Gdk.RGBA ink = get_color();
            if (error) {
                ink = Gdk.RGBA();
                ink.parse("#e5534b");
            }
            double radius = cell() * 0.12;
            if (path.length > 0) {
                cr.set_line_width(4);
                cr.set_line_cap(Cairo.LineCap.ROUND);
                cr.set_line_join(Cairo.LineJoin.ROUND);
                double x, y;
                center(path[0], out x, out y);
                cr.move_to(x, y);
                for (int i = 1; i < path.length; i++) {
                    center(path[i], out x, out y);
                    cr.line_to(x, y);
                }
                if (tracking) cr.line_to(finger_x, finger_y);
                cr.set_source_rgba(ink.red, ink.green, ink.blue, 0.5);
                cr.stroke();
            }
            for (int i = 0; i < 9; i++) {
                double x, y;
                center(i, out x, out y);
                bool on = visited(i);
                cr.arc(x, y, radius * 2, 0, 2 * Math.PI);
                cr.set_source_rgba(ink.red, ink.green, ink.blue, on ? 0.2 : 0.07);
                cr.fill();
                cr.arc(x, y, on ? radius : radius * 0.6, 0, 2 * Math.PI);
                cr.set_source_rgba(ink.red, ink.green, ink.blue, on ? 1.0 : 0.75);
                cr.fill();
            }
        }
    }
}
