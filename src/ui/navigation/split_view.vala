using Gtk;

namespace Singularity.Widgets {

    public class SplitView : Widget {
        private Widget _list;
        private Widget _detail;
        private Separator _separator;
        private bool _collapsed = false;
        private bool _show_detail = false;
        private uint _sync_source = 0;
        private Button? _back = null;

        public int list_width { get; set; default = 320; }
        public double list_fraction { get; set; default = 0.0; }
        public int detail_min_width { get; set; default = 360; }

        public bool collapsed { get { return _collapsed; } }

        public bool show_detail {
            get { return _show_detail; }
            set {
                if (_show_detail == value) return;
                _show_detail = value;
                _sync_back ();
                queue_allocate ();
            }
        }

        public signal void back_requested ();

        public SplitView (Widget list, Widget detail) {
            _list = list;
            _detail = detail;
            _separator = new Separator (Orientation.VERTICAL);
            _list.set_parent (this);
            _separator.set_parent (this);
            _detail.set_parent (this);
            add_css_class ("singularity-split-view");
            notify["list-width"].connect (() => queue_resize ());
            notify["list-fraction"].connect (() => queue_resize ());
            notify["detail-min-width"].connect (() => queue_resize ());
        }

        public void attach_back_bubble (Singularity.Widgets.Window window) {
            if (_back != null) return;
            _back = window.add_bubble_icon ("go-previous-symbolic", _("Back"), () => go_back ());
            _sync_back ();
        }

        public void go_back () {
            if (!_show_detail) return;
            show_detail = false;
            back_requested ();
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            int lmin, lnat, dmin, dnat, smin, snat;
            _list.measure (orientation, -1, out lmin, out lnat, null, null);
            _detail.measure (orientation, -1, out dmin, out dnat, null, null);
            _separator.measure (orientation, -1, out smin, out snat, null, null);
            if (orientation == Orientation.HORIZONTAL) {
                minimum = int.max (lmin, dmin);
                natural = int.max (lnat, list_width) + snat + int.max (dnat, detail_min_width);
            } else {
                minimum = int.max (lmin, dmin);
                natural = int.max (lnat, dnat);
            }
        }

        public override void size_allocate (int width, int height, int baseline) {
            int smin, snat;
            _separator.measure (Orientation.HORIZONTAL, -1, out smin, out snat, null, null);
            int lmin, lnat;
            _list.measure (Orientation.HORIZONTAL, -1, out lmin, out lnat, null, null);
            int list_w = int.max (lmin, list_width);
            if (list_fraction > 0.0) list_w = int.max (lmin, (int) Math.round (width * list_fraction));
            bool collapsed = width < list_w + snat + detail_min_width;

            if (collapsed) {
                _list.set_child_visible (!_show_detail);
                _separator.set_child_visible (false);
                _detail.set_child_visible (_show_detail);
                if (_show_detail) _detail.allocate (width, height, baseline, null);
                else _list.allocate (width, height, baseline, null);
            } else {
                _list.set_child_visible (true);
                _separator.set_child_visible (true);
                _detail.set_child_visible (true);
                _list.allocate (list_w, height, baseline, null);
                var t = new Gsk.Transform ().translate ({ list_w, 0 });
                _separator.allocate (snat, height, baseline, t);
                t = new Gsk.Transform ().translate ({ list_w + snat, 0 });
                _detail.allocate (int.max (0, width - list_w - snat), height, baseline, t);
            }

            if (collapsed != _collapsed) {
                _collapsed = collapsed;
                if (_sync_source == 0) _sync_source = Idle.add (() => {
                    _sync_source = 0;
                    notify_property ("collapsed");
                    _sync_back ();
                    return Source.REMOVE;
                });
            }
        }

        private void _sync_back () {
            if (_back != null) _back.visible = _collapsed && _show_detail;
        }

        public override void dispose () {
            if (_sync_source != 0) {
                Source.remove (_sync_source);
                _sync_source = 0;
            }
            if (_list != null) _list.unparent ();
            if (_separator != null) _separator.unparent ();
            if (_detail != null) _detail.unparent ();
            _list = null;
            _separator = null;
            _detail = null;
            base.dispose ();
        }
    }
}
