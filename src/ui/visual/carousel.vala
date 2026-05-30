using Gtk;

namespace Singularity.Widgets {

    /**
     * A page-at-a-time carousel built on Gtk primitives, with an optional
     * dot indicator strip underneath. API: append_page, get_nth_page,
     * scroll_to_index, n_pages, position, plus a page_changed signal.
     */
    public class Carousel : Box {

        public signal void page_changed(uint index);

        private Gtk.Stack _stack;
        private Gtk.Box?  _dots;
        private uint      _n   = 0;
        private uint      _pos = 0;
        private bool      _show_indicator     = true;
        private uint      _transition_duration = 280;

        public uint n_pages  { get { return _n; } }
        public uint position { get { return _pos; } }

        public bool show_indicator {
            get { return _show_indicator; }
            set {
                _show_indicator = value;
                if (_dots != null) _dots.visible = value;
            }
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
