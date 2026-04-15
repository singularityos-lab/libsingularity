using Gtk;

namespace Singularity.Widgets {

    /**
     * An Overlay subclass that clips all of its children to a rounded rectangle.
     *
     * GTK4 only applies CSS border-radius to a widget's OWN background paint;
     * children still render rectangularly on top. Overriding snapshot() to push
     * a GskRoundedClipNode before the base paint is the correct way to clip the
     * whole subtree, as used by libadwaita internally.
     *
     * The box-shadow for the CSD shadow lives on the parent window CSS node
     * (so GTK4 can extend the Wayland surface for it), while background and
     * border-radius live here.
     */
    private class RoundedFrame : Gtk.Box {
        private const float CORNER_RADIUS = 12.0f;

        public RoundedFrame() {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        }

        public override void snapshot(Gtk.Snapshot snap) {
            float radius = CORNER_RADIUS;

            // Disable rounding in states that need sharp/full edges
            var root = get_root() as Gtk.Widget;
            if (root != null && (
                root.has_css_class("maximized")     ||
                root.has_css_class("fullscreen")    ||
                root.has_css_class("tiled")         ||
                root.has_css_class("tiled-left")    ||
                root.has_css_class("tiled-right")   ||
                root.has_css_class("tiled-top")     ||
                root.has_css_class("tiled-bottom")  ||
                root.has_css_class("no-rounded-corners") ||
                root.has_css_class("ssd-mode")
            )) {
                radius = 0.0f;
            }

            float w = (float) get_width();
            float h = (float) get_height();

            if (radius <= 0.0f || w <= 0 || h <= 0) {
                base.snapshot(snap);
                return;
            }

            Graphene.Rect bounds = Graphene.Rect();
            bounds.init(0.0f, 0.0f, w, h);

            Gsk.RoundedRect rounded = Gsk.RoundedRect();
            rounded.init_from_rect(bounds, radius);

            snap.push_rounded_clip(rounded);
            base.snapshot(snap);
            snap.pop();
        }
    }



    /**
     * Base window class for Singularity apps.
     *
     * Provides an opinionated Gtk.ApplicationWindow with:
     * - An integrated ToolBar rendered as a floating overlay or as a
     * static SSD title bar depending on the desktop decoration preference.
     * - An animated Gtk.Revealer-based sidebar.
     * - Automatic save and restore of window size and maximised state across
     * launches (stored in the desktop's `window-states` GSettings key).
     * - Rounded-corners and shadow CSS classes toggled in real time.
     *
     * The main layout areas exposed for subclasses and callers:
     * - `toolbar`       – the top toolbar widget.
     * - `content_area`  – the primary content area (fills remaining space).
     * - `sidebar_area`  – optional side panel; hidden by default.
     * - `main_container` – horizontal box containing sidebar + content.
     */
    public class Window : Gtk.ApplicationWindow {

        /** The application toolbar shown at the top of the window. */
        public ToolBar toolbar { get; private set; }

        /** Horizontal box that contains the sidebar revealer and the content area. */
        public Box main_container { get; private set; }

        /** Primary content area; fills all available horizontal and vertical space. */
        public Box content_area { get; private set; }

        /**
         * Sidebar area container. Populate it via `set_sidebar()` and
         * show/hide it with `set_sidebar_visible()`.
         */
        public Box sidebar_area { get; private set; }

        /**
         * Flat mode: hides the toolbar and replaces it with an invisible drag
         * strip at the top and a close button overlay at the top-right corner.
         *
         * Use for content-first apps (Music, Videos, Photos) that show their
         * own hover-activated controls and don't need a persistent toolbar bar.
         * Has no effect in SSD mode (server-side decorations).
         */
        public bool flat {
            get { return _flat; }
            set {
                _flat = value;
                _update_flat_mode();
            }
        }

        public bool show_close {
            get { return _show_close; }
            set {
                _show_close = value;
                _update_flat_mode();
            }
        }

        private Revealer sidebar_revealer;
        private ScrolledWindow sidebar_scroll_wrap;
        private int _sidebar_width = 180;
        private GLib.Settings desktop_settings;
        private bool _flat = false;
        private bool _show_close = true;
        private bool _force_ssd = false;
        private WindowHandle? _flat_drag_handle  = null;
        private Button?       _flat_close_btn    = null;
        private ulong _rounded_corners_handler = 0;
        private ulong _toolbar_static_handler  = 0;
        private ulong _map_restore_handler     = 0;
        private ulong _map_clamp_handler       = 0;
        private ulong _close_handler           = 0;
        private ulong _maximized_handler       = 0;

        public Window(Gtk.Application app) {
            Object(application: app);
        }

        construct {
            add_css_class("singularity");
            add_css_class("singularity-app");

            desktop_settings = new GLib.Settings(Singularity.Runtime.desktop_settings_schema);
            _force_ssd = desktop_settings.get_boolean("force-ssd");

            if (_force_ssd) {
                add_css_class("ssd-mode");
            }

            _apply_rounded_corners_setting();
            _rounded_corners_handler = desktop_settings.changed["window-rounded-corners"].connect(
                _apply_rounded_corners_setting
            );

            if (!_force_ssd) {
                var hidden_titlebar = new Box(Orientation.VERTICAL, 0);
                hidden_titlebar.visible = false;
                set_titlebar(hidden_titlebar);
            }

            var app_frame = new RoundedFrame();
            app_frame.add_css_class("singularity-app-frame");
            app_frame.hexpand = true;
            app_frame.vexpand = true;
            set_child(app_frame);

            var overlay = new Overlay();
            overlay.hexpand = true;
            overlay.vexpand = true;
            app_frame.append(overlay);

            var outer_box = new Box(Orientation.VERTICAL, 0);
            overlay.set_child(outer_box);

            toolbar = new ToolBar();
            if (_force_ssd) {
                toolbar.set_ssd_mode(true);
                toolbar.add_css_class("ssd-mode");
                outer_box.append(toolbar);
            }

            main_container = new Box(Orientation.HORIZONTAL, 0);
            main_container.add_css_class("singularity");
            main_container.vexpand = true;
            outer_box.append(main_container);

            sidebar_area = new Box(Orientation.VERTICAL, 0);
            sidebar_area.add_css_class("window-sidebar");

            sidebar_scroll_wrap = new ScrolledWindow();
            sidebar_scroll_wrap.set_size_request(180, -1);
            sidebar_scroll_wrap.hexpand = false;
            sidebar_scroll_wrap.hscrollbar_policy = PolicyType.NEVER;
            sidebar_scroll_wrap.vscrollbar_policy = PolicyType.AUTOMATIC;
            sidebar_scroll_wrap.set_child(sidebar_area);

            sidebar_revealer = new Revealer();
            sidebar_revealer.transition_type = RevealerTransitionType.SLIDE_RIGHT;
            sidebar_revealer.transition_duration = 200;
            sidebar_revealer.reveal_child = false;
            sidebar_revealer.set_child(sidebar_scroll_wrap);
            sidebar_revealer.hexpand = false;
            main_container.append(sidebar_revealer);

            content_area = new Box(Orientation.VERTICAL, 0);
            content_area.hexpand = true;
            content_area.vexpand = true;
            main_container.append(content_area);

            if (!_force_ssd) {
                // Regular toolbar overlay (drag handle = toolbar itself)
                var handle = new WindowHandle();
                handle.set_child(toolbar);
                handle.valign = Align.START;
                overlay.add_overlay(handle);

                // Flat-mode: invisible drag strip at the very top
                _flat_drag_handle = new WindowHandle();
                var drag_strip = new Box(Orientation.HORIZONTAL, 0);
                drag_strip.add_css_class("flat-drag-strip");
                drag_strip.set_size_request(-1, 24);
                _flat_drag_handle.set_child(drag_strip);
                _flat_drag_handle.valign = Align.START;
                _flat_drag_handle.hexpand = true;
                _flat_drag_handle.visible = false;
                overlay.add_overlay(_flat_drag_handle);

                // Flat-mode: close button at top-right corner
                _flat_close_btn = new Singularity.Widgets.CloseButton();
                _flat_close_btn.add_css_class("flat-close-btn");
                _flat_close_btn.valign = Align.START;
                _flat_close_btn.halign = Align.END;
                _flat_close_btn.margin_top = 8;
                _flat_close_btn.margin_end = 8;
                _flat_close_btn.visible = false;
                _flat_close_btn.clicked.connect(() => close());
                overlay.add_overlay(_flat_close_btn);
            }

            _toolbar_static_handler = toolbar.notify["is-static"].connect(update_layout);
            update_layout();

            _map_restore_handler = map.connect(restore_window_state);
            _map_clamp_handler   = map.connect(clamp_to_work_area);
            _close_handler       = close_request.connect(() => { save_window_state(); return false; });
            _maximized_handler   = notify["maximized"].connect(() => save_window_state());
        }

        // ── Window state persistence ───────────────────────────────────

        public override void dispose() {
            if (_rounded_corners_handler != 0) {
                desktop_settings.disconnect(_rounded_corners_handler);
                _rounded_corners_handler = 0;
            }
            if (_toolbar_static_handler != 0) {
                toolbar.disconnect(_toolbar_static_handler);
                _toolbar_static_handler = 0;
            }
            if (_map_restore_handler != 0) {
                disconnect(_map_restore_handler);
                _map_restore_handler = 0;
            }
            if (_map_clamp_handler != 0) {
                disconnect(_map_clamp_handler);
                _map_clamp_handler = 0;
            }
            if (_close_handler != 0) {
                disconnect(_close_handler);
                _close_handler = 0;
            }
            if (_maximized_handler != 0) {
                disconnect(_maximized_handler);
                _maximized_handler = 0;
            }
            base.dispose();
        }

        private void _apply_rounded_corners_setting() {
            if (desktop_settings.get_boolean("window-rounded-corners")) {
                remove_css_class("no-rounded-corners");
            } else {
                add_css_class("no-rounded-corners");
            }
        }

        private void restore_window_state() {
            var app_id = application?.application_id;
            if (app_id == null) return;

            var states = desktop_settings.get_value("window-states");
            var state  = states.lookup_value(app_id, new GLib.VariantType("(iib)"));
            if (state == null) return;

            int w, h;
            bool m;
            state.get("(iib)", out w, out h, out m);

            if (m) {
                maximize();
            } else if (w >= 100 && w <= 65535 && h >= 100 && h <= 65535) {
                set_default_size(w, h);
            }
        }

        // Clamp window to monitor work area so it never opens taller/wider than
        // the available screen space (accounting for the ~46 px top panel).
        private void clamp_to_work_area() {
            if (maximized) return;

            var surface = get_surface();
            if (surface == null) return;
            var display = get_display();
            if (display == null) return;

            Gdk.Monitor? monitor = display.get_monitor_at_surface(surface);
            if (monitor == null) {
                var list = display.get_monitors();
                monitor = list.get_item(0) as Gdk.Monitor;
            }
            if (monitor == null) return;

            Gdk.Rectangle geom = monitor.get_geometry();

            // Reserve space for the top panel (~46 px) and a small margin (8 px each side)
            const int PANEL_H  = 46;
            const int MARGIN   = 8;
            int max_w = geom.width  - MARGIN * 2;
            int max_h = geom.height - PANEL_H - MARGIN * 2;

            int cur_w = get_width();
            int cur_h = get_height();

            if (cur_w > max_w || cur_h > max_h) {
                set_default_size(
                    int.min(cur_w, max_w),
                    int.min(cur_h, max_h)
                );
            }
        }

        private void save_window_state() {
            var app_id = application?.application_id;
            if (app_id == null) return;

            int  w = get_width();
            int  h = get_height();
            bool m = maximized;

            // When maximized, save the restored (pre-maximize) size so it
            // comes back at the right size when unmaximized next launch.
            if (m) {
                var states = desktop_settings.get_value("window-states");
                var prev   = states.lookup_value(app_id, new GLib.VariantType("(iib)"));
                if (prev != null) {
                    int pw, ph; bool pm;
                    prev.get("(iib)", out pw, out ph, out pm);
                    w = pw; h = ph;
                }
            }

            var builder = new GLib.VariantBuilder(new GLib.VariantType("a{s(iib)}"));
            var iter    = desktop_settings.get_value("window-states").iterator();
            string k; int ew, eh; bool em;
            while (iter.next("{s(iib)}", out k, out ew, out eh, out em)) {
                if (k != app_id)
                    builder.add("{s(iib)}", k, ew, eh, em);
            }
            builder.add("{s(iib)}", app_id, w, h, m);
            desktop_settings.set_value("window-states", builder.end());
        }

        // ── Layout / helpers ──────────────────────────────────────────

        private void _update_flat_mode() {
            if (_force_ssd) return;
            toolbar.visible = !_flat;
            if (_flat) main_container.margin_top = 0;
            if (_flat_drag_handle != null) _flat_drag_handle.visible = _flat;
            if (_flat_close_btn  != null) _flat_close_btn.visible  = _flat && _show_close;
        }

        private void update_layout() {
            if (_force_ssd) {
                main_container.margin_top = 0;
                return;
            }
            if (toolbar.is_static) {
                main_container.margin_top = toolbar.toolbar_height;
            } else {
                main_container.margin_top = 0;
            }
        }

        /**
         * Sets the window title in both the OS title bar and the toolbar.
         *
         * @param title Human-readable title string.
         */
        public new void set_title(string title) {
            base.title = title;
            toolbar.set_title(title);
        }

        /**
         * Replaces the entire content area with the given widget.
         *
         * Any previously set content widget is removed. The widget is
         * automatically set to expand both horizontally and vertically.
         *
         * @param widget Widget to display as the main content.
         */
        public void set_content(Widget widget) {
            Widget? child = content_area.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                content_area.remove(child);
                child = next;
            }

            widget.hexpand = true;
            widget.vexpand = true;
            content_area.append(widget);
        }

        /**
         * Replaces the sidebar area with the given widget.
         *
         * The widget expands vertically to fill the sidebar height. Call
         * `set_sidebar_visible(true)` to make the sidebar appear.
         *
         * @param widget Widget to display inside the sidebar.
         */
        public void set_sidebar(Widget widget) {
            Widget child = sidebar_area.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                sidebar_area.remove(child);
                child = next;
            }

            sidebar_revealer.set_child(sidebar_scroll_wrap);
            widget.vexpand = true;
            sidebar_area.append(widget);
        }

        /**
         * Shows or hides the sidebar with a slide-in/out animation.
         *
         * @param visible `true` to reveal the sidebar, `false` to hide it.
         */
        public void set_sidebar_visible(bool visible) {
            sidebar_revealer.reveal_child = visible;
        }

        /** Returns `true` if the sidebar is currently visible. */
        public bool get_sidebar_visible() {
            return sidebar_revealer.reveal_child;
        }

        /**
         * Sets the minimum width of the sidebar panel.
         *
         * @param width Width in pixels; default is 180.
         */
        public void set_sidebar_width(int width) {
            _sidebar_width = width;
            sidebar_scroll_wrap.set_size_request(width, -1);
        }
    }
}
