using Gtk;

namespace Singularity.Widgets {

    /**
     * Overlay bubble bar that replaces the standard titlebar.
     * Window-control bubbles follow `gtk_decoration_layout`; app
     * bubbles (`add*()`) always go on the right. SSD bypasses to
     * `window.toolbar`.
     */
    public class HoverControls : Box {

        public delegate void CloseMenuAction ();

        private bool        _ssd_bypass = false;
        private Gtk.Window? _ssd_target_window = null;

        private Overlay? _overlay;
        private Box      _left_box;
        private Box      _right_box;
        private Box      _custom_box;
        private Gtk.Window? _bubble_window = null;
        private bool _bubble_with_drag = true;
        private bool _bubble_with_close = true;
        private GLib.Settings? _wm_layout_settings = null;

        private Button?     _close_btn          = null;
        private Gtk.Window? _close_target_window = null;

        private struct CloseMenuEntry {
            public bool   is_separator;
            public string label;
            public string? icon;
            public CloseMenuAction action;
        }
        private GenericArray<CloseMenuEntry?> _close_menu_entries
            = new GenericArray<CloseMenuEntry?> ();
        private Singularity.Widgets.ContextMenu? _close_menu = null;

        public HoverControls () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
        }

        // Built in construct so .ui/vetro instances are assembled too; content
        // and controls are set imperatively via set_content / add_control.
        construct {
            orientation = Orientation.VERTICAL;
            spacing = 0;
            hexpand = true;
            vexpand = true;

            _left_box   = new Box (Orientation.HORIZONTAL, 4);
            _right_box  = new Box (Orientation.HORIZONTAL, 4);
            _custom_box = new Box (Orientation.HORIZONTAL, 4);

            _overlay = new Overlay ();
            _overlay.hexpand = true;
            _overlay.vexpand = true;
            _overlay.add_css_class ("singularity-hover-overlay");

            var row = new Box (Orientation.HORIZONTAL, 4);
            row.halign      = Align.FILL;
            row.valign      = Align.START;
            row.hexpand     = true;
            row.margin_top   = 10;
            row.margin_start = 10;
            row.margin_end   = 10;
            row.add_css_class ("singularity-hover-row");
            row.add_css_class ("singularity-hover-controls");

            var spacer = new Box (Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;

            row.append (_left_box);
            row.append (spacer);
            row.append (_right_box);

            _right_box.append (_custom_box);

            _overlay.add_overlay (row);
            append (_overlay);
        }

        internal HoverControls.empty_passthrough () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            hexpand = true;
            vexpand = true;
            _left_box   = new Box (Orientation.HORIZONTAL, 4);
            _right_box  = new Box (Orientation.HORIZONTAL, 4);
            _custom_box = new Box (Orientation.HORIZONTAL, 4);
        }

        public bool is_ssd_bypass { get { return _ssd_bypass; } }

        public void set_content (Widget w) {
            if (_ssd_bypass) {
                Widget? old = get_first_child ();
                while (old != null) { var n = old.get_next_sibling (); remove (old); old = n; }
                append (w);
                return;
            }
            _overlay.set_child (w);
        }

        public void add (Widget w) {
            if (_ssd_bypass && _ssd_target_window is Singularity.Widgets.Window) {
                var sw = (Singularity.Widgets.Window) _ssd_target_window;
                sw.toolbar.pack_start (w);
                sw.toolbar.visible = true;
                return;
            }
            w.add_css_class ("singularity-hover-btn");
            if (w is Button) {
                var child = ((Button) w).get_child ();
                if (child is Image) {
                    w.add_css_class ("image-button");
                    ((Image) child).pixel_size = -1;
                }
                w.set_size_request (20, 20);
            }
            w.valign = Align.CENTER;
            _custom_box.append (w);
        }

        public void add_control (Widget w) { add (w); }

        public delegate void ButtonAction ();

        public Button add_text_button (string label, owned ButtonAction action) {
            var btn = new Button.with_label (label);
            btn.add_css_class ("flat");
            btn.clicked.connect (() => action ());
            add (btn);
            return btn;
        }

        public Button add_suggested_button (string label, owned ButtonAction action) {
            var btn = new Button.with_label (label);
            btn.add_css_class ("flat");
            btn.add_css_class ("suggested-action");
            btn.clicked.connect (() => action ());
            add (btn);
            return btn;
        }

        public void add_separator () {
            var sep = new Box (Orientation.HORIZONTAL, 0);
            sep.add_css_class ("singularity-hover-sep");
            _custom_box.append (sep);
        }

        public static HoverControls with_window_bubbles (Gtk.Window window,
                                                         bool with_drag  = true,
                                                         bool with_close = true) {
            if (window is Singularity.Widgets.Window
                && (((Singularity.Widgets.Window) window).force_ssd
                    || ((Singularity.Widgets.Window) window).legacy_titlebar)) {
                // SSD and the legacy titlebar both want app buttons routed into
                // the static toolbar instead of a floating bubble bar.
                var hc = new HoverControls.empty_passthrough ();
                hc._ssd_bypass        = true;
                hc._ssd_target_window = window;
                return hc;
            }

            var hc = new HoverControls ();

            if (window is Singularity.Widgets.Window) {
                var sw = (Singularity.Widgets.Window) window;
                sw.flat       = true;
                sw.show_close = false;
            }

            hc._bubble_window     = window;
            hc._bubble_with_drag  = with_drag;
            hc._bubble_with_close = with_close;
            hc._build_bubbles ();

            // Rebuild live when the user changes the button-layout in Settings.
            var src = GLib.SettingsSchemaSource.get_default ();
            if (src != null && src.lookup ("org.gnome.desktop.wm.preferences", true) != null) {
                hc._wm_layout_settings = new GLib.Settings ("org.gnome.desktop.wm.preferences");
                hc._wm_layout_settings.changed["button-layout"].connect ((k) => hc._build_bubbles ());
            }

            return hc;
        }

        // (Re)build the window-control bubbles from the current button-layout.
        // _custom_box (app buttons) lives inside _right_box, so it is preserved.
        private void _build_bubbles () {
            if (_bubble_window == null) return;
            var window = _bubble_window;
            bool with_drag  = _bubble_with_drag;
            bool with_close = _bubble_with_close;

            Widget? c = _left_box.get_first_child ();
            while (c != null) { Widget? n = c.get_next_sibling (); _left_box.remove (c); c = n; }
            c = _right_box.get_first_child ();
            while (c != null) {
                Widget? n = c.get_next_sibling ();
                if (c != _custom_box) _right_box.remove (c);
                c = n;
            }

            // Parse the GTK decoration layout: "left:right" with each
            // side a comma-separated list of control names. We honour
            // close, minimize, maximize; ignore "icon", "menu",
            // "appmenu" and anything else.
            string layout = _resolve_decoration_layout ();
            string[] parts = layout.split (":");
            string left_str  = parts.length > 0 ? parts[0] : "";
            string right_str = parts.length > 1 ? parts[1] : "";

            bool close_left = left_str.contains ("close");
            bool min_left   = left_str.contains ("minimize");
            bool max_left   = left_str.contains ("maximize");
            bool close_right = right_str.contains ("close");
            bool min_right   = right_str.contains ("minimize");
            bool max_right   = right_str.contains ("maximize");

            Box target = _right_box;
            bool cluster_on_left = close_left || (!close_right && (min_left || max_left));
            if (cluster_on_left) target = _left_box;

            if (cluster_on_left) {
                if (with_close && (close_left || close_right))
                    _install_close_bubble (window, target);
                if (max_left || max_right)
                    _install_maximize_bubble (window, target);
                if (min_left || min_right)
                    _install_minimize_bubble (window, target);
                if (with_drag)
                    _install_drag_bubble (window, target);
            } else {
                if (with_drag)
                    _install_drag_bubble (window, target);
                if (min_left || min_right)
                    _install_minimize_bubble (window, target);
                if (max_left || max_right)
                    _install_maximize_bubble (window, target);
                if (with_close && (close_left || close_right))
                    _install_close_bubble (window, target);
            }
        }

        // Resolve the decoration layout, preferring the host's
        // org.gnome.desktop.wm.preferences button-layout (so first-party apps
        // honour the minimize/maximize preference directly) and falling back to
        // GTK's gtk_decoration_layout, which sandboxed apps receive over the
        // settings portal.
        private static string _resolve_decoration_layout () {
            var src = GLib.SettingsSchemaSource.get_default ();
            if (src != null
                    && src.lookup ("org.gnome.desktop.wm.preferences", true) != null) {
                var wm = new GLib.Settings ("org.gnome.desktop.wm.preferences");
                string bl = wm.get_string ("button-layout");
                if (bl != null && bl != "") return bl;
            }
            return Gtk.Settings.get_default ().gtk_decoration_layout ?? ":close";
        }

        private void _install_drag_bubble (Gtk.Window window, Box target) {
            var drag_btn = new Button ();
            drag_btn.add_css_class ("flat");
            drag_btn.add_css_class ("singularity-hover-btn");
            drag_btn.add_css_class ("image-button");
            drag_btn.set_size_request (20, 20);
            drag_btn.valign = Align.CENTER;
            drag_btn.tooltip_text = _("Drag Window");
            var grip = new Image.from_icon_name ("list-drag-handle-symbolic");
            grip.pixel_size = -1;
            drag_btn.set_child (grip);
            var drag = new Gtk.GestureDrag ();
            drag.drag_begin.connect ((x, y) => {
                var surface = window.get_surface ();
                if (surface is Gdk.Toplevel) {
                    ((Gdk.Toplevel) surface).begin_move (
                        drag.get_device (), 1, x, y, Gdk.CURRENT_TIME);
                }
            });
            drag_btn.add_controller (drag);
            target.append (drag_btn);
        }

        private void _install_minimize_bubble (Gtk.Window window, Box target) {
            var btn = new Button.from_icon_name ("window-minimize-symbolic");
            btn.add_css_class ("flat");
            btn.add_css_class ("singularity-hover-btn");
            btn.set_size_request (20, 20);
            btn.valign = Align.CENTER;
            btn.tooltip_text = _("Minimize Window");
            btn.clicked.connect (() => window.minimize ());
            target.append (btn);
        }

        private void _install_maximize_bubble (Gtk.Window window, Box target) {
            var btn = new Button.from_icon_name ("window-maximize-symbolic");
            btn.add_css_class ("flat");
            btn.add_css_class ("singularity-hover-btn");
            btn.set_size_request (20, 20);
            btn.valign = Align.CENTER;
            btn.tooltip_text = _("Maximize Window");
            btn.clicked.connect (() => {
                if (window.maximized) window.unmaximize ();
                else                  window.maximize ();
            });
            target.append (btn);
        }

        private void _install_close_bubble (Gtk.Window window, Box target) {
            _close_target_window = window;
            _close_btn = new Button.from_icon_name ("window-close-symbolic");
            _close_btn.add_css_class ("singularity-hover-btn");
            _close_btn.set_size_request (20, 20);
            _close_btn.valign = Align.CENTER;
            _close_btn.tooltip_text = _("Close Window");
            _close_btn.clicked.connect (_on_close_clicked);
            target.append (_close_btn);
        }

        private void _on_close_clicked () {
            if (_close_menu_entries.length == 0) {
                if (_close_target_window != null) _close_target_window.close ();
                return;
            }
            _close_menu = new Singularity.Widgets.ContextMenu (_close_btn);
            Gdk.Rectangle rect = { 0, 0, 1, 1 };
            _close_menu.set_pointing_to (rect);
            for (int i = 0; i < _close_menu_entries.length; i++) {
                var e = _close_menu_entries[i];
                if (e.is_separator) {
                    _close_menu.add_separator ();
                } else {
                    var act = e.action;
                    _close_menu.add_item (e.label, e.icon, () => act ());
                }
            }
            _close_menu.closed.connect (() => {
                _close_menu.unparent ();
                _close_menu = null;
            });
            _close_menu.popup ();
        }

        public void add_close_menu_item (string label,
                                         string? icon_name,
                                         owned CloseMenuAction action) {
            CloseMenuEntry e = CloseMenuEntry ();
            e.is_separator = false;
            e.label  = label;
            e.icon   = icon_name;
            e.action = (owned) action;
            _close_menu_entries.add (e);
        }

        public void add_close_menu_separator () {
            CloseMenuEntry e = CloseMenuEntry ();
            e.is_separator = true;
            e.label = "";
            e.icon  = null;
            e.action = () => {};
            _close_menu_entries.add (e);
        }
    }
}
