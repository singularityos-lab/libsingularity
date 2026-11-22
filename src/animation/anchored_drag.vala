namespace Singularity.Animation {

    public class AnchoredDrag : Object {

        private const string DATA_KEY = "singularity-anchored-drag";

        private double _start_x = 0.0;
        private double _start_y = 0.0;

        public double travel_x { get; private set; default = 0.0; }
        public double travel_y { get; private set; default = 0.0; }

        public unowned Gtk.GestureDrag gesture { get; construct; }

        private AnchoredDrag(Gtk.GestureDrag gesture) {
            Object(gesture: gesture);
        }

        public static AnchoredDrag attach(Gtk.GestureDrag gesture) {
            var anchored = new AnchoredDrag(gesture);
            gesture.set_data<AnchoredDrag>(DATA_KEY, anchored);
            return anchored;
        }

        construct {
            gesture.drag_begin.connect(() => {
                travel_x = 0.0;
                travel_y = 0.0;
                surface_point(out _start_x, out _start_y);
            });
            gesture.drag_update.connect(() => track());
            gesture.drag_end.connect(() => track());
        }

        private bool surface_point(out double x, out double y) {
            x = 0.0;
            y = 0.0;
            var event = gesture.get_last_event(gesture.get_current_sequence());
            return event != null && event.get_position(out x, out y);
        }

        private void track() {
            double x, y;
            if (!surface_point(out x, out y)) return;
            travel_x = x - _start_x;
            travel_y = y - _start_y;
        }
    }
}
