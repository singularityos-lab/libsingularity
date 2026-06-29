using Gtk;

namespace Singularity.Widgets {

    public class FloatingPanel : Gtk.Box {
        private unowned Gtk.Overlay _overlay;
        private int _x = 0;
        private int _y = 0;
        private int _grab_dx = 0;
        private int _grab_dy = 0;
        private const int MIN_W = 200;
        private const int MIN_H = 120;

        private Gtk.Overlay _body;
        private Gtk.Box      _titlebar;
        private Gtk.Label    _title_lbl;

        public signal void close_requested ();

        public string title {
            owned get { return _title_lbl.label; }
            set {
                _title_lbl.label = value;
                _titlebar.visible = value != "";
            }
        }

        public FloatingPanel (Gtk.Overlay overlay) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            _overlay = overlay;
            add_css_class ("floating-panel");
            set_size_request (360, 220);
            halign = Gtk.Align.START;
            valign = Gtk.Align.START;

            var drag_strip = new Gtk.Box (Orientation.HORIZONTAL, 0);
            drag_strip.add_css_class ("floating-panel-drag");
            drag_strip.set_size_request (-1, 14);
            drag_strip.hexpand = true;
            drag_strip.halign = Gtk.Align.FILL;
            drag_strip.valign = Gtk.Align.START;
            drag_strip.set_cursor_from_name ("move");

            var close_btn = new Singularity.Widgets.CloseButton ();
            close_btn.add_css_class ("singularity-hover-btn");
            close_btn.halign = Gtk.Align.END;
            close_btn.valign = Gtk.Align.START;
            close_btn.margin_top = 6;
            close_btn.margin_end = 6;
            close_btn.clicked.connect (() => { dismiss (); close_requested (); });

            var grip = new Gtk.Box (Orientation.HORIZONTAL, 0);
            grip.add_css_class ("floating-panel-grip");
            grip.set_size_request (16, 16);
            grip.halign = Gtk.Align.END;
            grip.valign = Gtk.Align.END;
            grip.set_cursor_from_name ("nwse-resize");

            _titlebar = new Gtk.Box (Orientation.HORIZONTAL, 0);
            _titlebar.add_css_class ("floating-panel-titlebar");
            _titlebar.halign = Gtk.Align.START;
            _titlebar.valign = Gtk.Align.START;
            _titlebar.can_target = false;
            _titlebar.visible = false;
            _title_lbl = new Gtk.Label ("");
            _title_lbl.add_css_class ("floating-panel-title");
            _title_lbl.ellipsize = Pango.EllipsizeMode.END;
            _titlebar.append (_title_lbl);

            _body = new Gtk.Overlay ();
            _body.hexpand = true;
            _body.vexpand = true;
            _body.add_overlay (drag_strip);
            _body.add_overlay (close_btn);
            _body.add_overlay (grip);
            _body.add_overlay (_titlebar);
            append (_body);

            var drag = new Gtk.GestureDrag ();
            drag.drag_begin.connect ((sx, sy) => {
                double gx, gy;
                if (drag_strip.translate_coordinates (_overlay, sx, sy, out gx, out gy)) {
                    _grab_dx = (int) gx - _x;
                    _grab_dy = (int) gy - _y;
                }
            });
            drag.drag_update.connect ((ox, oy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                double gx, gy;
                if (drag_strip.translate_coordinates (_overlay, sx + ox, sy + oy, out gx, out gy))
                    move_to ((int) gx - _grab_dx, (int) gy - _grab_dy);
            });
            drag_strip.add_controller (drag);

            var rsz = new Gtk.GestureDrag ();
            rsz.drag_update.connect ((ox, oy) => {
                double sx, sy;
                rsz.get_start_point (out sx, out sy);
                double gx, gy;
                if (grip.translate_coordinates (_overlay, sx + ox, sy + oy, out gx, out gy))
                    resize_to ((int) gx - _x, (int) gy - _y);
            });
            grip.add_controller (rsz);

            var focus_ctrl = new Gtk.EventControllerFocus ();
            focus_ctrl.enter.connect (() => raise_to_top ());
            add_controller (focus_ctrl);
        }

        public void set_content (Gtk.Widget w) {
            w.hexpand = true;
            w.vexpand = true;
            _body.set_child (w);
        }

        public void set_panel_size (int w, int h) {
            set_size_request (w, h);
        }

        public void place (int x, int y) {
            _x = x;
            _y = y;
            margin_start = x;
            margin_top = y;
            _overlay.add_overlay (this);
            _overlay.set_clip_overlay (this, true);
            var content = _body.get_child ();
            if (content != null) content.grab_focus ();
        }

        public void dismiss () {
            if (get_parent () != null) _overlay.remove_overlay (this);
        }

        private void move_to (int x, int y) {
            int max_x = int.max (0, _overlay.get_width () - get_width ());
            int max_y = int.max (0, _overlay.get_height () - get_height ());
            _x = x.clamp (0, max_x);
            _y = y.clamp (0, max_y);
            margin_start = _x;
            margin_top = _y;
        }

        private void resize_to (int w, int h) {
            int max_w = int.max (MIN_W, _overlay.get_width () - _x);
            int max_h = int.max (MIN_H, _overlay.get_height () - _y);
            set_size_request (w.clamp (MIN_W, max_w), h.clamp (MIN_H, max_h));
        }

        private void raise_to_top () {
            var last = _overlay.get_last_child ();
            if (last != null && last != this)
                insert_after (_overlay, last);
        }
    }
}
