using Gtk;

namespace Singularity.Widgets {

    /**
     * Page-at-a-time carousel with optional dot indicator and
     * horizontal touchpad/swipe/wheel paging when `interactive`.
     */
    public class Carousel : Box {

        public signal void page_changed(uint index);

        private Gtk.Stack _stack;
        private Gtk.Box?  _dots;
        private uint      _n   = 0;
        private uint      _pos = 0;
        private bool      _show_indicator     = true;
        private uint      _transition_duration = 280;
        private bool      _interactive        = true;

        private double _scroll_dx = 0.0;
        private const double SCROLL_PAGE_DELTA = 1.0;

        public uint n_pages  { get { return _n; } }
        public uint position { get { return _pos; } }

        public bool show_indicator {
            get { return _show_indicator; }
            set {
                _show_indicator = value;
                if (_dots != null) _dots.visible = value;
            }
        }

        public bool interactive {
            get { return _interactive; }
            set { _interactive = value; }
        }

        public uint transition_duration {
            get { return _transition_duration; }
            set {
                _transition_duration = value;
                _stack.transition_duration = value;
            }
        }

        public Carousel() {
            Object(orientation: Orientation.VERTICAL, spacing: 4);

            _stack = new Gtk.Stack();
            _stack.hexpand = true;
            _stack.vexpand = true;
            _stack.transition_type     = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
            _stack.transition_duration = _transition_duration;
            append(_stack);

            _dots = new Gtk.Box(Orientation.HORIZONTAL, 4);
            _dots.add_css_class("singularity-carousel-dots");
            _dots.halign        = Align.CENTER;
            _dots.margin_top    = 4;
            _dots.margin_bottom = 2;
            append(_dots);

            _install_gestures();
        }

        private const double SWIPE_MIN_VELOCITY = 250.0;

        private void _install_gestures() {
            var scroll = new Gtk.EventControllerScroll(
                Gtk.EventControllerScrollFlags.HORIZONTAL);
            scroll.scroll_begin.connect(() => { _scroll_dx = 0; });
            scroll.scroll.connect((dx, dy) => {
                if (!_interactive) return false;
                _scroll_dx += dx;
                if (_scroll_dx >= SCROLL_PAGE_DELTA) {
                    _scroll_dx = 0;
                    if (_pos + 1 < _n) scroll_to_index(_pos + 1, true);
                    return true;
                }
                if (_scroll_dx <= -SCROLL_PAGE_DELTA) {
                    _scroll_dx = 0;
                    if (_pos > 0) scroll_to_index(_pos - 1, true);
                    return true;
                }
                return false;
            });
            scroll.scroll_end.connect(() => { _scroll_dx = 0; });
            add_controller(scroll);

            var swipe = new Gtk.GestureSwipe();
            swipe.swipe.connect((vx, vy) => {
                if (!_interactive) return;
                if (vx <= -SWIPE_MIN_VELOCITY && _pos + 1 < _n) {
                    scroll_to_index(_pos + 1, true);
                } else if (vx >= SWIPE_MIN_VELOCITY && _pos > 0) {
                    scroll_to_index(_pos - 1, true);
                }
            });
            add_controller(swipe);
        }

        public void append_page(Gtk.Widget page) {
            _stack.add_named(page, _n.to_string());
            if (_n == 0) {
                _stack.visible_child_name = "0";
                _pos = 0;
            }
            _n++;
            rebuild_dots();
        }

        public Gtk.Widget? get_nth_page(uint idx) {
            return _stack.get_child_by_name(idx.to_string());
        }

        public void scroll_to_index(uint idx, bool animate) {
            if (idx >= _n) return;
            uint saved = _stack.transition_duration;
            _stack.transition_duration = animate ? _transition_duration : 0;
            _stack.visible_child_name  = idx.to_string();
            _stack.transition_duration = saved;
            _pos = idx;
            rebuild_dots();
            page_changed(idx);
        }

        public void scroll_to_page(Gtk.Widget page, bool animate) {
            for (uint i = 0; i < _n; i++) {
                if (get_nth_page(i) == page) {
                    scroll_to_index(i, animate);
                    return;
                }
            }
        }

        public void clear() {
            Widget? c = _stack.get_first_child();
            while (c != null) {
                var next = c.get_next_sibling();
                _stack.remove(c);
                c = next;
            }
            _n   = 0;
            _pos = 0;
            rebuild_dots();
        }

        private void rebuild_dots() {
            if (_dots == null) return;
            Widget? c = _dots.get_first_child();
            while (c != null) {
                var next = c.get_next_sibling();
                _dots.remove(c);
                c = next;
            }
            if (!_show_indicator) return;
            for (uint i = 0; i < _n; i++) {
                var dot = new Gtk.Box(Orientation.HORIZONTAL, 0);
                dot.add_css_class("singularity-carousel-dot");
                if (i == _pos) dot.add_css_class("active");
                dot.set_size_request(8, 8);
                _dots.append(dot);
            }
        }
    }
}
