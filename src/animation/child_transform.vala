namespace Singularity.Animation {

    public delegate void ChildPlacement(out int width, out int height, out double x, out double y);

    /**
     * Moves and scales a widget that another container owns and allocates.
     *
     * `MotionBin` needs to wrap the widget; ChildTransform works on a widget
     * in place, such as a `Gtk.Stack` page or the knob of a `Gtk.Switch`.
     * After every layout it allocates the child again at the place its
     * parent chose, given by `placement`, with the transform on top. Only
     * the transform changes from frame to frame, so nothing is measured
     * again.
     */
    public class ChildTransform : Object {

        private const string DATA_KEY = "singularity-child-transform";

        private ChildPlacement? _placement = null;
        private Gdk.FrameClock? _clock = null;
        private ulong _layout_handler = 0;
        private ulong _unmap_handler = 0;

        public Gtk.Widget child { get; construct; }

        public double translate_x { get; set; default = 0.0; }

        public double translate_y { get; set; default = 0.0; }

        public double scale_x { get; set; default = 1.0; }

        public double scale_y { get; set; default = 1.0; }

        public double origin_x { get; set; default = 0.5; }

        public double origin_y { get; set; default = 0.5; }

        public bool hold { get; set; default = false; }

        public bool is_identity {
            get { return translate_x == 0.0 && translate_y == 0.0 && scale_x == 1.0 && scale_y == 1.0; }
        }

        private ChildTransform(Gtk.Widget child) {
            Object(child: child);
        }

        construct {
            notify.connect((pspec) => {
                if (pspec.name != "child") update();
            });
        }

        public static ChildTransform for_widget(Gtk.Widget child, owned ChildPlacement? placement = null) {
            var existing = child.get_data<ChildTransform>(DATA_KEY);
            if (existing == null) {
                existing = new ChildTransform(child);
                child.set_data<ChildTransform>(DATA_KEY, existing);
            }
            if (placement != null) existing._placement = (owned) placement;
            return existing;
        }

        public static ChildTransform? lookup(Gtk.Widget child) {
            return child.get_data<ChildTransform>(DATA_KEY);
        }

        public void reset_transform() {
            freeze_notify();
            translate_x = 0.0;
            translate_y = 0.0;
            scale_x = 1.0;
            scale_y = 1.0;
            thaw_notify();
        }

        private void update() {
            var parent = child.get_parent();
            if (is_identity && !hold) {
                release();
                if (parent != null) parent.queue_allocate();
                return;
            }
            if (!hook()) return;
            parent.queue_allocate();
        }

        private bool hook() {
            if (_layout_handler != 0) return true;
            var clock = child.get_frame_clock();
            if (clock == null || child.get_parent() == null) return false;
            _clock = clock;
            _layout_handler = clock.layout.connect_after(apply);
            _unmap_handler = child.unmap.connect(() => {
                reset_transform();
                release();
            });
            return true;
        }

        private void release() {
            if (_layout_handler != 0 && _clock != null) _clock.disconnect(_layout_handler);
            _layout_handler = 0;
            _clock = null;
            if (_unmap_handler != 0) child.disconnect(_unmap_handler);
            _unmap_handler = 0;
        }

        public Gsk.Transform? build_transform(int width, int height, double x, double y) {
            var transform = new Gsk.Transform();
            Graphene.Point base_point = { (float) (x + translate_x + width * origin_x),
                                          (float) (y + translate_y + height * origin_y) };
            transform = transform.translate(base_point);
            if (scale_x != 1.0 || scale_y != 1.0) transform = transform.scale((float) scale_x, (float) scale_y);
            Graphene.Point back = { (float) (-width * origin_x), (float) (-height * origin_y) };
            return transform.translate(back);
        }

        private void apply() {
            var parent = child.get_parent();
            if (parent == null || !child.get_visible() || !child.get_mapped()) return;
            int width, height;
            double x = 0.0, y = 0.0;
            if (_placement != null) {
                _placement(out width, out height, out x, out y);
            } else {
                width = parent.get_width();
                height = parent.get_height();
            }
            if (width <= 0 || height <= 0) return;
            child.allocate(width, height, -1, build_transform(width, height, x, y));
        }
    }
}
