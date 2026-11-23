namespace Singularity.Animation {

    public class MotionBin : Gtk.Widget {

        [CCode (cname = "singularity_widget_set_visual_transform", cheader_filename = "wayland/surface_effect.h")]
        private static extern bool set_native_visual_transform(Gtk.Widget widget, Gsk.Transform? transform);

        [CCode (cname = "singularity_widget_set_visual_opacity", cheader_filename = "wayland/surface_effect.h")]
        private static extern bool set_native_visual_opacity(Gtk.Widget widget, double opacity);
        [CCode (cname = "singularity_widget_set_visual_clip", cheader_filename = "wayland/surface_effect.h")]
        private static extern bool set_native_visual_clip(Gtk.Widget widget, Gsk.RoundedRect? clip);

        private bool _native_transform = false;
        internal bool uses_native_transform { get { return _native_transform; } }
        private Gtk.Widget? _child = null;
        private double _translate_x = 0.0;
        private double _translate_y = 0.0;
        private double _scale_x = 1.0;
        private double _scale_y = 1.0;
        private double _squash = 0.0;
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
            set { if (_translate_x != value) { _translate_x = value; update_transform(); } }
        }

        public double translate_y {
            get { return _translate_y; }
            set { if (_translate_y != value) { _translate_y = value; update_transform(); } }
        }

        public double scale_x {
            get { return _scale_x; }
            set { if (_scale_x != value) { _scale_x = value; update_transform(); } }
        }

        public double scale_y {
            get { return _scale_y; }
            set { if (_scale_y != value) { _scale_y = value; update_transform(); } }
        }

        public double squash {
            get { return _squash; }
            set { if (_squash != value) { _squash = value; update_transform(); } }
        }

        public double scale {
            get { return _scale_x; }
            set {
                if (_scale_x == value && _scale_y == value) return;
                _scale_x = value;
                _scale_y = value;
                update_transform();
            }
        }

        public double origin_x {
            get { return _origin_x; }
            set { if (_origin_x != value) { _origin_x = value; update_transform(); } }
        }

        public double origin_y {
            get { return _origin_y; }
            set { if (_origin_y != value) { _origin_y = value; update_transform(); } }
        }

        public bool is_identity {
            get { return _translate_x == 0.0 && _translate_y == 0.0 && _scale_x == 1.0 && _scale_y == 1.0 && _squash == 0.0; }
        }

        static construct {
            set_css_name("motionbin");
        }

        public MotionBin(Gtk.Widget? child = null) {
            Object();
            _native_transform = set_native_visual_transform(this, null);
            if (_native_transform) set_native_visual_opacity(this, opacity);
            this.child = child;
        }

        private bool _transform_input = false;

        public bool transform_input {
            get { return _transform_input; }
            set {
                if (_transform_input == value) return;
                _transform_input = value;
                if (_native_transform) set_native_visual_transform(this, value ? null : get_visual_transform());
                queue_allocate();
            }
        }

        private void update_transform() {
            if (_transform_input) {
                queue_allocate();
                return;
            }
            if (_native_transform && set_native_visual_transform(this, get_visual_transform())) return;
            queue_draw();
        }

        public bool set_visual_clip(Gsk.RoundedRect? clip) {
            return set_native_visual_clip(this, clip);
        }

        public void reset_transform() {
            _translate_x = 0.0;
            _translate_y = 0.0;
            _scale_x = 1.0;
            _scale_y = 1.0;
            _squash = 0.0;
            update_transform();
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
            if (_transform_input) {
                if (_child != null && _child.visible) _child.allocate(width, height, baseline, get_visual_transform());
                return;
            }
            if (_child != null && _child.visible) _child.allocate(width, height, baseline, null);
            update_transform();
        }

        public override bool contains(double x, double y) {
            if (!_transform_input || _child == null) return base.contains(x, y);
            if (!_child.visible) return false;
            Graphene.Rect bounds;
            if (!_child.compute_bounds(this, out bounds)) return false;
            return bounds.contains_point(Graphene.Point() { x = (float) x, y = (float) y });
        }

        public Gsk.Transform? get_visual_transform() {
            if (is_identity) return null;
            float ox = (float) (get_width() * _origin_x);
            float oy = (float) (get_height() * _origin_y);
            Graphene.Point origin = { ox + (float) _translate_x, oy + (float) _translate_y };
            Graphene.Point back = { -ox, -oy };
            return new Gsk.Transform().translate(origin)
                .scale((float) (_scale_x * (1.0 + _squash * 0.5)), (float) (_scale_y * (1.0 - _squash)))
                .translate(back);
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            if (_child == null) return;
            if (_transform_input || _native_transform || is_identity) {
                snapshot_child(_child, snapshot);
                return;
            }
            snapshot.save();
            snapshot.transform(get_visual_transform());
            snapshot_child(_child, snapshot);
            snapshot.restore();
        }
    }
}
