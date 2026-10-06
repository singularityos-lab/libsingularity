namespace Singularity.Animation {

    public class MotionBin : Gtk.Widget {

        private Gtk.Widget? _child = null;
        private double _translate_x = 0.0;
        private double _translate_y = 0.0;
        private double _scale_x = 1.0;
        private double _scale_y = 1.0;
        private double _origin_x = 0.5;
        private double _origin_y = 0.5;

        public Gtk.Widget? child {
            get { return _child; }
            set {
                if (_child == value) return;
                if (_child != null) _child.unparent();
                _child = value;
                if (_child != null) _child.set_parent(this);
                queue_resize();
            }
        }

        public double translate_x {
            get { return _translate_x; }
            set { if (_translate_x != value) { _translate_x = value; queue_draw(); } }
        }

        public double translate_y {
            get { return _translate_y; }
            set { if (_translate_y != value) { _translate_y = value; queue_draw(); } }
        }

        public double scale_x {
            get { return _scale_x; }
            set { if (_scale_x != value) { _scale_x = value; queue_draw(); } }
        }

        public double scale_y {
            get { return _scale_y; }
            set { if (_scale_y != value) { _scale_y = value; queue_draw(); } }
        }

        public double scale {
            get { return _scale_x; }
            set {
                if (_scale_x == value && _scale_y == value) return;
                _scale_x = value;
                _scale_y = value;
                queue_draw();
            }
        }

        public double origin_x {
            get { return _origin_x; }
            set { if (_origin_x != value) { _origin_x = value; queue_draw(); } }
        }

        public double origin_y {
            get { return _origin_y; }
            set { if (_origin_y != value) { _origin_y = value; queue_draw(); } }
        }

        public bool is_identity {
            get { return _translate_x == 0.0 && _translate_y == 0.0 && _scale_x == 1.0 && _scale_y == 1.0; }
        }

        static construct {
            set_css_name("motionbin");
        }

        public MotionBin(Gtk.Widget? child = null) {
            Object();
            this.child = child;
        }

        public void reset_transform() {
            _translate_x = 0.0;
            _translate_y = 0.0;
            _scale_x = 1.0;
            _scale_y = 1.0;
            queue_draw();
        }

        public override void dispose() {
            if (_child != null) {
                _child.unparent();
                _child = null;
            }
            base.dispose();
        }

        public override Gtk.SizeRequestMode get_request_mode() {
            return _child != null ? _child.get_request_mode() : Gtk.SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Gtk.Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum = 0;
            natural = 0;
            minimum_baseline = -1;
            natural_baseline = -1;
            if (_child == null || !_child.visible) return;
            _child.measure(orientation, for_size, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
        }

        public override void size_allocate(int width, int height, int baseline) {
            if (_child != null && _child.visible) _child.allocate(width, height, baseline, null);
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            if (_child == null) return;
            if (is_identity) {
                snapshot_child(_child, snapshot);
                return;
            }
            float ox = (float) (get_width() * _origin_x);
            float oy = (float) (get_height() * _origin_y);
            snapshot.save();
            Graphene.Point origin = { ox + (float) _translate_x, oy + (float) _translate_y };
            snapshot.translate(origin);
            snapshot.scale((float) _scale_x, (float) _scale_y);
            Graphene.Point back = { -ox, -oy };
            snapshot.translate(back);
            snapshot_child(_child, snapshot);
            snapshot.restore();
        }
    }
}
