using Gtk;

namespace Singularity.Widgets {

    public class EdgeSheet : Widget {
        private Widget _scrim;
        private Widget? _child = null;

        public EdgeSwipe swipe { get; private set; }
        public PackType edge { get; private set; }
        public int gap { get; set; default = 0; }
        public int edge_zone { get; set; default = 24; }
        public bool can_open { get; set; default = true; }

        public bool revealed {
            get { return swipe.target >= 1.0; }
            set { swipe.set_open (value); }
        }

        public EdgeSheet (Widget host, PackType edge) {
            this.edge = edge;
            overflow = Overflow.HIDDEN;
            _scrim = new Box (Orientation.VERTICAL, 0);
            _scrim.add_css_class ("window-drawer-scrim");
            _scrim.set_parent (this);
            var click = new GestureClick ();
            click.released.connect (() => swipe.set_open (false));
            _scrim.add_controller (click);
            swipe = new EdgeSwipe (host);
            swipe.direction = edge == PackType.START ? 1 : -1;
            swipe.set_accept ((x, y) => accepts (x));
            swipe.notify["progress"].connect (sync_progress);
            notify["gap"].connect (() => queue_allocate ());
            sync_progress ();
        }

        public void set_child (Widget? child) {
            if (_child == child) return;
            if (_child != null) _child.unparent ();
            _child = child;
            if (child != null) child.set_parent (this);
            sync_progress ();
            queue_resize ();
        }

        private bool accepts (double x) {
            if (_child == null) return false;
            if (swipe.progress > 0.0 || swipe.settling) return true;
            if (!can_open) return false;
            int width = get_width ();
            return edge == PackType.START ? x <= edge_zone : x >= width - edge_zone;
        }

        private void sync_progress () {
            bool shown = swipe.progress > 0.0 && _child != null;
            can_target = shown;
            _scrim.set_child_visible (shown);
            if (_child != null) _child.set_child_visible (shown);
            queue_allocate ();
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum = natural = 0;
            minimum_baseline = natural_baseline = -1;
        }

        public override void size_allocate (int width, int height, int baseline) {
            double p = swipe.progress;
            _scrim.opacity = p;
            _scrim.allocate (width, height, baseline, null);
            if (_child == null) return;
            int min, nat;
            _child.measure (Orientation.HORIZONTAL, height, out min, out nat, null, null);
            int sheet = int.max (min, int.min (nat, width - gap));
            swipe.distance = int.max (sheet, 1);
            double x = edge == PackType.START ? -sheet * (1.0 - p) : width - sheet * p;
            var t = new Gsk.Transform ().translate ({ (float) Math.round (x), 0 });
            _child.allocate (sheet, height, baseline, t);
        }

        public override void dispose () {
            if (swipe != null) swipe.detach ();
            if (_child != null) _child.unparent ();
            _child = null;
            if (_scrim != null) _scrim.unparent ();
            _scrim = null;
            base.dispose ();
        }
    }
}
