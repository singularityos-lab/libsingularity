using Gtk;

namespace Singularity.Widgets {

    public class DetailPane : Widget {
        private const int BACK_ZONE = 32;

        private Widget _main;
        private Widget? _panel = null;
        private Box _frame;
        private Widget _scrim;
        private EdgeSwipe _swipe;
        private Button? _back = null;
        private bool _overlay = false;
        private bool _edge_claimed = false;
        private uint _sync_source = 0;

        public int panel_width { get; set; default = 400; }
        public int main_min_width { get; set; default = 360; }

        public bool overlay_mode {
            get { return _overlay; }
        }

        public bool reveal_panel {
            get { return _swipe.target >= 1.0; }
            set {
                if (value && _panel == null) return;
                _swipe.set_open (value);
                sync_back ();
            }
        }

        public bool panel_revealed {
            get { return _swipe.progress > 0.0; }
        }

        public signal void panel_closed ();

        public DetailPane (Widget main) {
            add_css_class ("singularity-detail-pane");
            overflow = Overflow.HIDDEN;
            _main = main;
            _main.set_parent (this);
            _scrim = new Box (Orientation.VERTICAL, 0);
            _scrim.add_css_class ("window-drawer-scrim");
            _scrim.set_parent (this);
            var click = new GestureClick ();
            click.released.connect (() => reveal_panel = false);
            _scrim.add_controller (click);
            _frame = new Box (Orientation.VERTICAL, 0);
            _frame.add_css_class ("detail-pane-panel");
            _frame.set_parent (this);
            _swipe = new EdgeSwipe (this);
            _swipe.direction = -1;
            _swipe.distance = panel_width;
            _swipe.set_accept ((x, y) => accepts (x));
            _swipe.notify["progress"].connect (on_progress);
            _swipe.settled.connect ((open) => {
                sync_back ();
                if (!open) panel_closed ();
            });
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape || !reveal_panel) return false;
                reveal_panel = false;
                return true;
            });
            add_controller (keys);
            notify["panel-width"].connect (() => queue_resize ());
            notify["main-min-width"].connect (() => queue_resize ());
            unrealize.connect (() => claim_edge (false));
            on_progress ();
        }

        public void set_panel (Widget? panel) {
            if (_panel == panel) return;
            if (_panel != null) _frame.remove (_panel);
            _panel = panel;
            if (panel != null) {
                panel.vexpand = true;
                _frame.append (panel);
            }
            on_progress ();
            queue_resize ();
        }

        public void attach_back_bubble (Singularity.Widgets.Window window) {
            if (_back != null) return;
            _back = window.add_bubble_icon ("go-previous-symbolic", _("Back"), () => reveal_panel = false);
            sync_back ();
        }

        private bool accepts (double x) {
            if (_panel == null || !(_swipe.progress > 0.0 || _swipe.settling)) return false;
            double left = panel_left (get_width (), _swipe.progress);
            return x >= left && x <= left + BACK_ZONE;
        }

        private double panel_left (int width, double p) {
            return _overlay ? width * (1.0 - p) : width - panel_width * p;
        }

        private void on_progress () {
            bool shown = _swipe.progress > 0.0 && _panel != null;
            _frame.set_child_visible (shown);
            _scrim.set_child_visible (shown && _overlay);
            claim_edge (shown && _overlay);
            if (_overlay) queue_allocate ();
            else queue_resize ();
            notify_property ("panel-revealed");
        }

        private void claim_edge (bool claim) {
            if (_edge_claimed == claim) return;
            var window = get_root () as Singularity.Widgets.Window;
            if (window == null && claim) return;
            _edge_claimed = claim;
            if (window != null) window.claim_start_edge (claim);
        }

        private void sync_back () {
            if (_back != null) _back.visible = _overlay && reveal_panel;
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            int mmin, mnat;
            _main.measure (orientation, -1, out mmin, out mnat, null, null);
            minimum = mmin;
            natural = mnat;
            if (_panel == null) return;
            int pmin, pnat;
            _frame.measure (orientation, -1, out pmin, out pnat, null, null);
            if (orientation == Orientation.VERTICAL) {
                minimum = int.max (minimum, pmin);
                natural = int.max (natural, pnat);
            } else if (!_overlay && _swipe.progress > 0.0) {
                natural += (int) (panel_width * _swipe.progress);
            }
        }

        public override void size_allocate (int width, int height, int baseline) {
            bool overlay = width < main_min_width + panel_width;
            if (overlay != _overlay) {
                _overlay = overlay;
                if (overlay) add_css_class ("overlay");
                else remove_css_class ("overlay");
                claim_edge (_overlay && _swipe.progress > 0.0);
                if (_sync_source == 0) _sync_source = Idle.add (() => {
                    _sync_source = 0;
                    notify_property ("overlay-mode");
                    sync_back ();
                    return Source.REMOVE;
                });
            }
            double p = _panel != null ? _swipe.progress : 0.0;
            _swipe.distance = _overlay ? int.max (width, 1) : panel_width;
            _scrim.set_child_visible (_overlay && p > 0.0);
            if (_overlay) {
                _main.allocate (width, height, baseline, null);
                _scrim.opacity = p;
                _scrim.allocate (width, height, baseline, null);
            } else {
                int visible = (int) Math.round (panel_width * p);
                _main.allocate (int.max (0, width - visible), height, baseline, null);
            }
            if (_panel == null || p <= 0.0) return;
            int panel_w = _overlay ? width : panel_width;
            var t = new Gsk.Transform ().translate ({ (float) Math.round (panel_left (width, p)), 0 });
            _frame.allocate (panel_w, height, baseline, t);
        }

        public override void dispose () {
            if (_sync_source != 0) {
                Source.remove (_sync_source);
                _sync_source = 0;
            }
            if (_swipe != null) _swipe.detach ();
            _panel = null;
            if (_frame != null) _frame.unparent ();
            _frame = null;
            if (_main != null) _main.unparent ();
            _main = null;
            if (_scrim != null) _scrim.unparent ();
            _scrim = null;
            base.dispose ();
        }
    }
}
