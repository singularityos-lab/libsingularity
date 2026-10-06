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
        private Box      _row;
        private Box      _left_box;
        private Box      _spacer;
        private Box      _right_box;
        private BubbleBox _custom_box;
        private Button?  _sidebar_toggle = null;
        private bool     _compact_controls = false;
        private Gtk.Window? _bubble_window = null;
        private bool _bubble_with_drag = true;
        private bool _bubble_with_close = true;
        private GLib.Settings? _wm_layout_settings = null;

        private Button?     _close_btn          = null;
        private Button?     _max_btn            = null;
        private Gtk.Window? _close_target_window = null;

        private class CloseMenuEntry {
            public bool   is_separator;
            public string label;
            public string? icon;
            public CloseMenuAction action;
        }
        private GenericArray<CloseMenuEntry> _close_menu_entries
            = new GenericArray<CloseMenuEntry> ();
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
            _custom_box = new BubbleBox ();
            _custom_box.search_activated.connect (_expand_search);
            _custom_box.search_close_requested.connect (collapse_search);
            _custom_box.search_fits.connect (() => _close_search (false));

            _overlay = new Overlay ();
            _overlay.hexpand = true;
            _overlay.vexpand = true;
            _overlay.add_css_class ("singularity-hover-overlay");

            var row = new Box (Orientation.HORIZONTAL, 4);
            _row = row;
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
            _spacer = spacer;

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
            _custom_box = new BubbleBox ();
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
                ((Singularity.Widgets.Window) _ssd_target_window).add_tool (w);
                return;
            }
            BubbleBox.prepare (w);
            _custom_box.add_item (w);
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
            _custom_box.add_item (sep);
        }

        /**
         * Sets how early a bubble moves into the more bubble when the row
         * gets narrow. Bubbles with a lower priority move first; among
         * equal priorities the last added moves first. The default is 0,
         * and `Window.BUBBLE_PRIORITY_PINNED` keeps a bubble in the row.
         */
        public void set_bubble_priority (Widget bubble, int priority) {
            _custom_box.set_priority (bubble, priority);
        }

        internal void mark_app_menu (Widget bubble) {
            _custom_box.mark_app_menu (bubble);
        }

        internal void mark_trailing (Widget bubble) {
            if (_ssd_bypass && _ssd_target_window is Singularity.Widgets.Window) {
                ((Singularity.Widgets.Window) _ssd_target_window).add_tool (bubble, true);
                return;
            }
            _custom_box.mark_trailing (bubble);
        }

        internal bool has_own_sidebar_toggle () {
            return _custom_box.has_sidebar_toggle ();
        }

        internal void set_welcome (bool welcome) {
            if (welcome && _custom_box.expanded) collapse_search ();
            _custom_box.set_welcome (welcome);
        }

        internal void set_sidebar_toggle (Button toggle) {
            _sidebar_toggle = toggle;
            if (_ssd_bypass && _ssd_target_window is Singularity.Widgets.Window) {
                ((Singularity.Widgets.Window) _ssd_target_window).add_tool (toggle, false, true);
                return;
            }
            toggle.add_css_class ("flat");
            toggle.add_css_class ("singularity-hover-btn");
            toggle.add_css_class ("image-button");
            var child = toggle.get_child ();
            if (child is Image) ((Image) child).pixel_size = -1;
            toggle.set_size_request (20, 20);
            toggle.valign = Align.CENTER;
            _left_box.prepend (toggle);
        }

        /** Reduces the window controls to the close bubble (phone width). */
        internal void set_row_hidden (bool hidden) {
            if (_row == null) return;
            if (hidden) {
                Singularity.Motion.tween (_row, "opacity", 0.0, Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.EXIT)
                    .done.connect (() => { if (_row.opacity == 0.0) _row.visible = false; });
                _row.can_target = false;
            } else {
                _row.visible = true;
                _row.can_target = true;
                Singularity.Motion.tween (_row, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            }
        }

        internal void set_compact_controls (bool compact) {
            if (_compact_controls == compact) return;
            _compact_controls = compact;
            _apply_controls_visibility ();
        }

        /** True while a collapsed search is expanded across the row. */
        internal bool search_expanded { get { return _custom_box.expanded; } }

        /** Closes the expanded search, clearing its text. */
        internal void collapse_search () {
            _close_search (true);
        }

        private void _expand_search (SearchBubble search) {
            int overhead = _row.get_width () - _custom_box.get_width ();
            _custom_box.set_expanded (search, int.max (0, overhead));
            _apply_controls_visibility ();
            search.grab_focus_entry ();
            if (search.get_data<string> ("singularity-stop-search") == null) {
                search.set_data<string> ("singularity-stop-search", "1");
                search.entry.stop_search.connect (() => {
                    if (_custom_box.expanded) collapse_search ();
                });
            }
        }

        private void _close_search (bool clear) {
            var search = _custom_box.expanded_search;
            if (search == null) return;
            _custom_box.set_expanded (null, 0);
            _apply_controls_visibility ();
            if (clear) search.clear ();
        }

        private void _apply_controls_visibility () {
            if (_ssd_bypass) return;
            bool expanded = _custom_box.expanded;
            _left_box.visible = !expanded;
            _spacer.visible = !expanded;
            _custom_box.hexpand = expanded;
            foreach (var box in new Box[] { _left_box, _right_box }) {
                for (var c = box.get_first_child (); c != null; c = c.get_next_sibling ()) {
                    if (c == _custom_box || c == _sidebar_toggle) continue;
                    c.visible = !expanded && (!_compact_controls || c == _close_btn || c == _max_btn);
                }
            }
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
            while (c != null) {
                Widget? n = c.get_next_sibling ();
                if (c != _sidebar_toggle) _left_box.remove (c);
                c = n;
            }
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
            _max_btn = null;
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
            _apply_controls_visibility ();
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
            SnapLayouts.attach_maximize_button (btn);
            _max_btn = btn;
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
                    var entry = e;
                    _close_menu.add_item (e.label, e.icon, () => entry.action ());
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
            var e = new CloseMenuEntry ();
            e.is_separator = false;
            e.label  = label;
            e.icon   = icon_name;
            e.action = (owned) action;
            _close_menu_entries.add (e);
        }

        public void add_close_menu_separator () {
            var e = new CloseMenuEntry ();
            e.is_separator = true;
            e.label = "";
            e.icon  = null;
            e.action = () => {};
            _close_menu_entries.add (e);
        }
    }
}
