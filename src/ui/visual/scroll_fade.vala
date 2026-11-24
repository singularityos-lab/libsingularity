namespace Singularity.Widgets {

    public class ScrollFade : Gtk.Widget {
        private Gtk.ScrolledWindow scrolled;
        private Gtk.Adjustment? adjustment = null;
        private ulong value_handler = 0;
        private ulong changed_handler = 0;
        private int _fade_size = 48;
        private int _top_offset = 0;

        public int top_offset {
            get { return _top_offset; }
            set {
                int v = int.max (0, value);
                if (v == _top_offset) return;
                _top_offset = v;
                queue_draw ();
            }
        }

        public int fade_size {
            get { return _fade_size; }
            set {
                int v = int.max (0, value);
                if (v == _fade_size) return;
                _fade_size = v;
                queue_draw ();
            }
        }

        public ScrollFade (Gtk.ScrolledWindow scrolled) {
            this.scrolled = scrolled;
            scrolled.set_parent (this);
            set_layout_manager (new Gtk.BinLayout ());
            scrolled.notify["vadjustment"].connect (track_adjustment);
            track_adjustment ();
        }

        public override void dispose () {
            release_adjustment ();
            if (scrolled != null) scrolled.unparent ();
            scrolled = null;
            base.dispose ();
        }

        private void track_adjustment () {
            release_adjustment ();
            adjustment = scrolled.vadjustment;
            if (adjustment == null) return;
            value_handler = adjustment.value_changed.connect (queue_draw);
            changed_handler = adjustment.changed.connect (queue_draw);
            queue_draw ();
        }

        private void release_adjustment () {
            if (adjustment == null) return;
            adjustment.disconnect (value_handler);
            adjustment.disconnect (changed_handler);
            value_handler = 0;
            changed_handler = 0;
            adjustment = null;
        }

        public override void snapshot (Gtk.Snapshot snapshot) {
            float w = get_width ();
            float h = get_height ();
            bool top = false;
            bool bottom = false;
            if (adjustment != null && _fade_size > 0 && h > 2 * _fade_size + _top_offset) {
                top = adjustment.value > 0.5;
                bottom = adjustment.value + adjustment.page_size < adjustment.upper - 0.5;
            }
            if (!top && !bottom) {
                snapshot_child (scrolled, snapshot);
                return;
            }
            float edge = _fade_size / h;
            float start = _top_offset / h;
            Gsk.ColorStop[] stops = {};
            if (top) {
                stops += Gsk.ColorStop () { offset = 0, color = { 0, 0, 0, 0 } };
                if (start > 0) stops += Gsk.ColorStop () { offset = start, color = { 0, 0, 0, 0 } };
                stops += Gsk.ColorStop () { offset = start + edge, color = { 0, 0, 0, 1 } };
            } else {
                stops += Gsk.ColorStop () { offset = 0, color = { 0, 0, 0, 1 } };
            }
            if (bottom) {
                stops += Gsk.ColorStop () { offset = 1 - edge, color = { 0, 0, 0, 1 } };
                stops += Gsk.ColorStop () { offset = 1, color = { 0, 0, 0, 0 } };
            } else {
                stops += Gsk.ColorStop () { offset = 1, color = { 0, 0, 0, 1 } };
            }
            var bounds = Graphene.Rect ().init (0, 0, w, h);
            snapshot.push_mask (Gsk.MaskMode.ALPHA);
            snapshot.append_linear_gradient (bounds, Graphene.Point ().init (0, 0), Graphene.Point ().init (0, h), stops);
            snapshot.pop ();
            snapshot_child (scrolled, snapshot);
            snapshot.pop ();
        }
    }
}
