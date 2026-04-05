using Gtk;

namespace Singularity.Widgets {

    /**
     * A simple screenshot carousel widget.
     *
     * Shows one screenshot at a time with prev/next navigation and dot
     * indicators. Image loading is intentionally delegated to the caller:
     * create the widget with the screenshot URL array (used only for count
     * and ordering), then call `set_image()` as each texture becomes available.
     */
    public class ScreenshotCarousel : Gtk.Box {

        private Gtk.Picture    _picture;
        private Gtk.Spinner    _spinner;
        private Gtk.Button     _prev;
        private Gtk.Button     _next;
        private Gtk.Box        _dots_box;
        private Gtk.Widget[]   _dot_widgets;

        private Gdk.Paintable?[] _images;
        private int _current = 0;

        public int count { get; private set; }

        public ScreenshotCarousel (string[] urls) {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 8);

            count   = urls.length;
            _images = new Gdk.Paintable?[count];

            if (count == 0) {
                visible = false;
                return;
            }

            // ── Image area ────────────────────────────────────────────────
            var frame = new Gtk.Frame (null);
            frame.add_css_class ("screenshot-carousel-frame");
            frame.hexpand = true;
            frame.height_request = 300;

            var overlay = new Gtk.Overlay ();
            frame.set_child (overlay);

            _spinner = new Gtk.Spinner ();
            _spinner.spinning = true;
            _spinner.halign   = Gtk.Align.CENTER;
            _spinner.valign   = Gtk.Align.CENTER;
            _spinner.set_size_request (32, 32);
            overlay.set_child (_spinner);

            _picture = new Gtk.Picture ();
            _picture.content_fit = Gtk.ContentFit.CONTAIN;
            _picture.hexpand     = true;
            _picture.vexpand     = true;
            _picture.visible     = false;
            overlay.add_overlay (_picture);

            if (count > 1) {
                _prev = make_nav_button ("go-previous-symbolic", Gtk.Align.START);
                _next = make_nav_button ("go-next-symbolic",     Gtk.Align.END);
                overlay.add_overlay (_prev);
                overlay.add_overlay (_next);

                _prev.clicked.connect (() => navigate (-1));
                _next.clicked.connect (() => navigate (1));
            }

            append (frame);

            // ── Dot indicators ────────────────────────────────────────────
            if (count > 1) {
                _dots_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
                _dots_box.halign = Gtk.Align.CENTER;
                _dot_widgets = new Gtk.Widget[count];

                for (int i = 0; i < count; i++) {
                    var dot = new Gtk.Label ("");
                    dot.add_css_class ("carousel-dot");
                    _dots_box.append (dot);
                    _dot_widgets[i] = dot;
                }
                update_dots ();
                append (_dots_box);
            }
        }

        /** Provide a loaded texture for slot @index. */
        public void set_image (int index, Gdk.Paintable paintable) {
            if (index < 0 || index >= count) return;
            _images[index] = paintable;
            if (index == _current)
                show_current ();
        }

        // ── Private helpers ───────────────────────────────────────────────

        private Gtk.Button make_nav_button (string icon, Gtk.Align align) {
            var btn = new Gtk.Button.from_icon_name (icon);
            btn.add_css_class ("screenshot-carousel-nav");
            btn.add_css_class ("circular");
            btn.halign = align;
            btn.valign = Gtk.Align.CENTER;
            btn.margin_start = 8;
            btn.margin_end   = 8;
            return btn;
        }

        private void navigate (int delta) {
            _current = (_current + delta + count) % count;
            show_current ();
            update_dots ();
            update_nav_sensitivity ();
        }

        private void show_current () {
            var p = _images[_current];
            if (p != null) {
                _picture.set_paintable (p);
                _picture.visible  = true;
                _spinner.spinning = false;
                _spinner.visible  = false;
            } else {
                _picture.visible  = false;
                _spinner.spinning = true;
                _spinner.visible  = true;
            }
        }

        private void update_dots () {
            if (_dot_widgets == null) return;
            for (int i = 0; i < count; i++) {
                if (i == _current)
                    _dot_widgets[i].add_css_class ("active");
                else
                    _dot_widgets[i].remove_css_class ("active");
            }
        }

        private void update_nav_sensitivity () {
            // Navigation is circular, so always sensitive when count > 1.
            // Override here if you want a non-wrapping carousel.
        }
    }
}
