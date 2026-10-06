namespace Singularity.Widgets {

    /**
     * Keeps a single child at a comfortable reading width.
     *
     * The child grows with the available space up to `maximum` pixels and is
     * centered horizontally beyond that. It never shrinks below the child's
     * own minimum width. Height is measured for the clamped width, so
     * wrapping labels inside a scrolled page lay out correctly.
     */
    public class Clamp : Gtk.Widget {
        /** Largest width, in pixels, given to the child. */
        public int maximum { get; set; default = 680; }

        private Gtk.Widget child;

        public Clamp (Gtk.Widget child, int maximum = 680) {
            this.child = child;
            this.maximum = maximum;
            child.set_parent (this);
            notify["maximum"].connect (queue_resize);
        }

        public override void dispose () {
            if (child != null) child.unparent ();
            child = null;
            base.dispose ();
        }

        public override Gtk.SizeRequestMode get_request_mode () {
            return Gtk.SizeRequestMode.HEIGHT_FOR_WIDTH;
        }

        public override void measure (Gtk.Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            int w = for_size;
            if (orientation == Gtk.Orientation.VERTICAL && for_size >= 0) w = int.min (for_size, maximum);
            child.measure (orientation, w, out minimum, out natural, null, null);
            if (orientation == Gtk.Orientation.HORIZONTAL) natural = int.max (minimum, maximum);
        }

        public override void size_allocate (int width, int height, int baseline) {
            int min, nat;
            child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            int w = int.max (min, int.min (width, maximum));
            var t = new Gsk.Transform ().translate (Graphene.Point () { x = (width - w) / 2, y = 0 });
            child.allocate (w, height, baseline, t);
        }
    }
}
