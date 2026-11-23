namespace Singularity.Widgets {

    public class ShadeBin : Gtk.Widget {
        private Gtk.Widget child;
        private double _shade = 0.0;

        public double shade {
            get { return _shade; }
            set {
                double v = value.clamp (0.0, 1.0);
                if (v == _shade) return;
                _shade = v;
                queue_draw ();
            }
        }

        public ShadeBin (Gtk.Widget child) {
            this.child = child;
            child.set_parent (this);
            set_layout_manager (new Gtk.BinLayout ());
        }

        public override void dispose () {
            if (child != null) child.unparent ();
            child = null;
            base.dispose ();
        }

        public override void snapshot (Gtk.Snapshot snapshot) {
            if (_shade > 0.0) {
                var rect = Graphene.Rect ().init (0, 0, get_width (), get_height ());
                snapshot.append_color ({ 0.0f, 0.0f, 0.0f, (float) _shade }, rect);
            }
            snapshot_child (child, snapshot);
        }
    }
}
