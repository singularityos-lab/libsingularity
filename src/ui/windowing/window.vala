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
     * - `toolbar`       - the top toolbar widget.
     * - `content_area`  - the primary content area (fills remaining space).
     * - `sidebar_area`  - optional side panel; hidden by default.
     * - `main_container` - horizontal box containing sidebar + content.
     */
    public class Window : Gtk.ApplicationWindow {

        /** Priority that keeps a bubble in the row at any width. */
        public const int BUBBLE_PRIORITY_PINNED = int.MAX;

        private const int NARROW_CONTENT_WIDTH = 360;
        private const int PHONE_WIDTH = 500;
        private const int ADAPTIVE_HYSTERESIS = 24;
        private const int DRAWER_GAP = 48;

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
        private GLib.Settings? desktop_settings;
        private ulong _background_effect_handler = 0;
        private ulong _blur_strength_handler = 0;
        private bool _flat = false;
        private bool _show_close = true;
        private bool _force_ssd = false;
        /** True when the user has opted into server-side decorations.
            HoverControls reads this to switch to its SSD fallback. */
        public bool force_ssd { get { return _force_ssd; } }
        private bool _legacy_titlebar = false;
        /** True when the user prefers the classic static titlebar over the
            floating hover controls. HoverControls redirects app bubbles into
            the toolbar (same bypass path as SSD). Ignored while force_ssd is on. */
        public bool legacy_titlebar { get { return _legacy_titlebar; } }

        public bool floating_bubbles { get { return !_force_ssd && !_legacy_titlebar; } }
        private WindowHandle? _flat_drag_handle  = null;
        private Button?       _flat_close_btn    = null;
        private RoundedFrame? _app_frame         = null;
        private ulong _rounded_corners_handler = 0;
        private ulong _toolbar_static_handler  = 0;
        private ulong _map_restore_handler     = 0;
        private ulong _map_clamp_handler       = 0;
        private ulong _close_handler           = 0;
        private ulong _maximized_handler       = 0;

        private ContentBin? _content_bin     = null;
        private Revealer    _drawer_revealer;
        private Revealer    _scrim_revealer;
        private Box         _drawer_box;
        private Button?     _auto_sidebar_toggle = null;
        private bool _narrow              = false;
        private bool _phone               = false;
        private bool _drawer_open         = false;
        private bool _sidebar_wanted      = false;
        private bool _sidebar_user_hidden = false;
        private bool _toggle_probe        = false;
        private uint _toggle_probe_source = 0;
        private uint _adaptive_source     = 0;
        private int  _welcome_pages       = 0;

        private Overlay?         _root_overlay        = null;
        private ToastHost?       _toast_host          = null;
        private Button?          _app_menu_btn        = null;
        private PopoverMenu?     _app_menu_popover    = null;
        private bool             _menubar_hidden      = false;
        private bool             _shell_present       = false;
        private uint             _shell_watch         = 0;
        private ulong            _global_menu_handler = 0;
        private Gtk.Application? _menubar_app         = null;
        private ulong            _menubar_handler     = 0;
        private Singularity.Shell.GlobalMenuBar? _classic_menubar = null;
        private ScrolledWindow? _tool_row = null;
        private Box? _tool_start = null;
        private Box? _tool_end = null;

        /**
         * The tool row under the classic titlebar, or null with floating
         * bubbles. In the classic titlebar and with server-side decorations
         * the widgets added with `add_bubble_*` go here, so the titlebar only
         * holds the menu bar, the title and the window controls.
         */
        public Widget? tool_row { get { return _tool_row; } }

        internal void add_tool(Widget w, bool trailing = false, bool first = false) {
            if (_tool_row == null) return;
            var parent = w.get_parent();
            if (parent is Box) ((Box) parent).remove(w);
            else if (parent != null) w.unparent();
            var box = trailing ? _tool_end : _tool_start;
            if (first) box.prepend(w);
            else box.append(w);
            w.notify["visible"].connect(_sync_tool_row);
            _sync_tool_row();
        }

        private void _sync_tool_row() {
            if (_tool_row == null) return;
            bool any = false;
            foreach (var box in new Box[] { _tool_start, _tool_end }) {
                for (var c = box.get_first_child(); c != null; c = c.get_next_sibling()) {
                    if (c.visible) {
                        any = true;
                        break;
                    }
                }
            }
            _tool_row.visible = any;
        }
        private MenuModel?       _classic_menubar_model = null;

        public Window(Gtk.Application app) {
            Object(application: app);
        }

        construct {
            add_css_class("singularity");
            add_css_class("singularity-app");

            desktop_settings = Singularity.Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
            _force_ssd = desktop_settings != null && desktop_settings.get_boolean("force-ssd");
            // Legacy titlebar is a CSD mode, so it only applies when SSD is off.
            _legacy_titlebar = !_force_ssd && desktop_settings != null
                && desktop_settings.get_boolean("legacy-titlebar");

            if (_force_ssd) {
                add_css_class("ssd-mode");
            }
            if (_legacy_titlebar) add_css_class("legacy-titlebar");
            add_css_class(_force_ssd || _legacy_titlebar ? "static-titlebar" : "floating-bubbles");

            _apply_rounded_corners_setting();
            if (desktop_settings != null) {
                _rounded_corners_handler = desktop_settings.changed["window-rounded-corners"].connect(
                    _apply_rounded_corners_setting
                );
            }

            if (!_force_ssd) {
                var hidden_titlebar = new Box(Orientation.VERTICAL, 0);
                hidden_titlebar.visible = false;
                set_titlebar(hidden_titlebar);
            }

            var app_frame = new RoundedFrame();
            app_frame.add_css_class("singularity-app-frame");
            app_frame.hexpand = true;
            app_frame.vexpand = true;
            // No widget margin here: the shadow lives in CSS on the
            // .singularity-app rule (window node), which lets GTK4 read
            // the shadow extents and call gdk_surface_set_shadow_width()
            // so the compositor sees the card as the real window.
            set_child(app_frame);
            _app_frame = app_frame;

            _apply_background_effect();
            if (desktop_settings != null
                    && desktop_settings.settings_schema.has_key("background-effect")) {
                _background_effect_handler = desktop_settings.changed["background-effect"].connect(
                    _apply_background_effect
                );
                if (desktop_settings.settings_schema.has_key("blur-strength")) {
                    _blur_strength_handler = desktop_settings.changed["blur-strength"].connect(
                        _apply_background_effect
                    );
                }
            }
            this.map.connect(_apply_background_effect);

            var overlay = new Overlay();
            overlay.hexpand = true;
            overlay.vexpand = true;
            app_frame.append(overlay);
            _root_overlay = overlay;

            var outer_box = new Box(Orientation.VERTICAL, 0);
            overlay.set_child(outer_box);

            toolbar = new ToolBar();
            if (_force_ssd) {
                toolbar.set_ssd_mode(true);
                toolbar.add_css_class("ssd-mode");
                // Start hidden in SSD mode: labwc already draws the title
                // strip, our toolbar only re-emerges when HoverControls
                // (SSD bypass) packs buttons into it.
                toolbar.visible = false;
                outer_box.append(toolbar);
            } else if (_legacy_titlebar) {
                // Classic static titlebar: a real toolbar at the top of the
                // window flow with its own close button and centred title.
                // App bubbles get redirected into it by HoverControls.
                toolbar.is_static = true;
                toolbar.visible = true;
                toolbar.enable_window_controls();
                var legacy_handle = new WindowHandle();
                legacy_handle.set_child(toolbar);
                legacy_handle.valign = Align.START;
                outer_box.append(legacy_handle);
            }

            if (_force_ssd || _legacy_titlebar) {
                _tool_start = new Box(Orientation.HORIZONTAL, 6);
                _tool_end = new Box(Orientation.HORIZONTAL, 6);
                _tool_end.hexpand = true;
                _tool_end.halign = Align.END;
                var tools = new Box(Orientation.HORIZONTAL, 6);
                tools.append(_tool_start);
                tools.append(_tool_end);
                _tool_row = new ScrolledWindow();
                _tool_row.add_css_class("singularity-tool-row");
                _tool_row.hscrollbar_policy = PolicyType.EXTERNAL;
                _tool_row.vscrollbar_policy = PolicyType.NEVER;
                _tool_row.propagate_natural_height = true;
                _tool_row.child = tools;
                _tool_row.visible = false;
                outer_box.append(_tool_row);
            }

            main_container = new Box(Orientation.HORIZONTAL, 0);
            main_container.add_css_class("singularity");
            main_container.vexpand = true;
            outer_box.append(main_container);

            sidebar_area = new Box(Orientation.VERTICAL, 0);
            sidebar_area.add_css_class("window-sidebar");
            // 10px padding (in `.window-sidebar` CSS rule) gives every
            // app's sidebar content a uniform inner gutter on all sides.

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

            if (!_force_ssd && !_legacy_titlebar) {
                // Regular toolbar overlay (drag handle = toolbar itself)
                var handle = new WindowHandle();
                handle.set_child(toolbar);
                handle.valign = Align.START;
                overlay.add_overlay(handle);

                // Flat-mode drag is provided by the HoverControls bubble
                // bar (drag grip). A full-width invisible WindowHandle here
                // would sit on top of the overlay and intercept clicks on
                // the upper half of the bubbles, so we skip it. Apps that
                // use flat mode without HoverControls must add their own
                // drag region.
                _flat_drag_handle = null;

                // Flat-mode close is provided by the bubble bar (close
                // bubble auto-added by HoverControls.with_window_bubbles).
                // The legacy corner-pinned close button was rendering as
                // a random rogue widget in welcome states; killed.
                _flat_close_btn = null;
            }

            _scrim_revealer = new Revealer();
            _scrim_revealer.transition_type = RevealerTransitionType.CROSSFADE;
            _scrim_revealer.transition_duration = 200;
            _scrim_revealer.visible = false;
            var scrim = new Box(Orientation.VERTICAL, 0);
            scrim.add_css_class("window-drawer-scrim");
            scrim.hexpand = true;
            scrim.vexpand = true;
            var scrim_click = new GestureClick();
            scrim_click.released.connect(_on_scrim_released);
            scrim.add_controller(scrim_click);
            _scrim_revealer.set_child(scrim);
            overlay.add_overlay(_scrim_revealer);

            _drawer_box = new Box(Orientation.VERTICAL, 0);
            _drawer_box.add_css_class("window-drawer");
            _drawer_revealer = new Revealer();
            _drawer_revealer.transition_type = RevealerTransitionType.SLIDE_RIGHT;
            _drawer_revealer.transition_duration = 200;
            _drawer_revealer.halign = Align.START;
            _drawer_revealer.valign = Align.FILL;
            _drawer_revealer.margin_end = DRAWER_GAP;
            _drawer_revealer.visible = false;
            _drawer_revealer.set_child(_drawer_box);
            _drawer_revealer.notify["child-revealed"].connect(_on_drawer_revealed);
            overlay.add_overlay(_drawer_revealer);
            Singularity.Animation.FocusRing.install(this, overlay);

            var adaptive_keys = new EventControllerKey();
            adaptive_keys.propagation_phase = PropagationPhase.CAPTURE;
            adaptive_keys.key_pressed.connect(_on_adaptive_key);
            ((Widget) this).add_controller(adaptive_keys);

            _toolbar_static_handler = toolbar.notify["is-static"].connect(update_layout);
            update_layout();

            _map_restore_handler = map.connect(restore_window_state);
            _map_clamp_handler   = map.connect(clamp_to_work_area);
            _close_handler       = close_request.connect(() => { save_window_state(); return false; });
            _maximized_handler   = notify["maximized"].connect(() => {
                save_window_state();
                _update_shadow_margin();
            });
            notify["fullscreened"].connect(_update_shadow_margin);
            _update_shadow_margin();

            _shell_present = Singularity.Runtime.is_shell_running();
            if (desktop_settings != null
                    && desktop_settings.settings_schema.has_key("global-menu-enabled")) {
                _global_menu_handler = desktop_settings.changed["global-menu-enabled"].connect(
                    _sync_app_menu
                );
            }
            _shell_watch = Bus.watch_name(BusType.SESSION, Singularity.Runtime.SHELL_BUS_NAME,
                BusNameWatcherFlags.NONE,
                () => { _shell_present = true; _sync_app_menu(); },
                () => { _shell_present = false; _sync_app_menu(); });
            notify["application"].connect(_track_menubar);
            _track_menubar();
        }

        private void _update_shadow_margin() {
            // Kept for state-class management; the actual shadow extents
            // come from CSS on .singularity-app and are reset by the
            // .maximized / .tiled / .ssd-mode rules in style.css.
        }

        // -- Window state persistence -----------------------------------

        public override void dispose() {
            if (_background_effect_handler != 0 && desktop_settings != null) {
                desktop_settings.disconnect(_background_effect_handler);
                _background_effect_handler = 0;
            }
            if (_blur_strength_handler != 0 && desktop_settings != null) {
                desktop_settings.disconnect(_blur_strength_handler);
                _blur_strength_handler = 0;
            }
            if (_rounded_corners_handler != 0 && desktop_settings != null) {
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
            if (_adaptive_source != 0) {
                Source.remove(_adaptive_source);
                _adaptive_source = 0;
            }
            if (_toggle_probe_source != 0) {
                Source.remove(_toggle_probe_source);
                _toggle_probe_source = 0;
            }
            if (_shell_watch != 0) {
                Bus.unwatch_name(_shell_watch);
                _shell_watch = 0;
            }
            if (_global_menu_handler != 0 && desktop_settings != null) {
                desktop_settings.disconnect(_global_menu_handler);
                _global_menu_handler = 0;
            }
            if (_menubar_handler != 0 && _menubar_app != null) {
                _menubar_app.disconnect(_menubar_handler);
                _menubar_handler = 0;
            }
            _menubar_app = null;
            if (_app_menu_popover != null && _app_menu_btn == null
                    && _app_menu_popover.get_parent() != null) {
                _app_menu_popover.unparent();
                _app_menu_popover = null;
            }
            base.dispose();
        }

        private void _apply_rounded_corners_setting() {
            if (desktop_settings == null || desktop_settings.get_boolean("window-rounded-corners")) {
                remove_css_class("no-rounded-corners");
            } else {
                add_css_class("no-rounded-corners");
            }
        }

        private void _apply_background_effect() {
            var mode = Singularity.Style.BackgroundEffect.read(desktop_settings);
            if (!get_mapped() || mode == Singularity.Style.BackgroundEffectMode.DISABLED
                    || _app_frame == null) {
                Singularity.Style.BackgroundEffect.apply(this, mode);
                return;
            }

            Graphene.Rect bounds;
            if (_app_frame.compute_bounds(this, out bounds)) {
                Singularity.Style.BackgroundEffect.apply(this, mode,
                    (int) bounds.origin.x, (int) bounds.origin.y,
                    (int) bounds.size.width, (int) bounds.size.height);
            }
        }

        public override void size_allocate(int width, int height, int baseline) {
            base.size_allocate(width, height, baseline);
            _apply_background_effect();
            _queue_adaptive_update();
        }

        private void restore_window_state() {
            var app_id = application?.application_id;
            if (app_id == null) return;
            if (desktop_settings == null) return;

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
            if (desktop_settings == null) return;

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

        // -- Layout / helpers ------------------------------------------

        private void _update_flat_mode() {
            // Legacy/SSD keep the toolbar in the box flow and never go flat.
            if (_force_ssd || _legacy_titlebar) return;
            toolbar.visible = !_flat;
            if (_flat) main_container.margin_top = 0;
        }

        private void update_layout() {
            // Legacy/SSD toolbars take real layout space, so the content needs
            // no top margin (only the overlay hover toolbar is pushed down).
            if (_force_ssd || _legacy_titlebar) {
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
            // In SSD mode labwc's decoration already shows the title;
            // duplicating it in our custom toolbar is redundant noise.
            toolbar.set_title(_force_ssd ? "" : title);
        }

        /**
         * Replaces the entire content area with the given widget.
         *
         * Any previously set content widget is removed. The widget is
         * automatically set to expand both horizontally and vertically.
         *
         * @param widget Widget to display as the main content.
         */
        // Last widget passed to set_content; we keep a reference so we
        // can re-wrap it later if add_bubble_* triggers lazy bubble-bar
        // creation after set_content has already run.
        private Widget? _user_content = null;

        public void set_content(Widget widget) {
            _user_content = widget;
            _install_content();
        }

        private void _install_content() {
            if (_user_content == null) return;

            Widget? child = content_area.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                content_area.remove(child);
                child = next;
            }

            _user_content.add_css_class("singularity-content");

            if (_content_bin == null) _content_bin = new ContentBin();
            if (_user_content.get_parent() != _content_bin) {
                var parent = _user_content.get_parent();
                if (parent is Box) ((Box) parent).remove(_user_content);
                _content_bin.child = _user_content;
            }

            Widget actual = _content_bin;
            if (_bubble_bar != null) {
                if (_content_bin.get_parent() == null) _bubble_bar.set_content(_content_bin);
                actual = _bubble_bar;
            }

            actual.hexpand = true;
            actual.vexpand = true;
            content_area.append(actual);
            _queue_adaptive_update();
        }

        // ===================================================================
        // Bubble bar API
        //
        // The window owns its HoverControls. Apps call `add_bubble_*` to
        // register actions; the bar is created lazily on the first call,
        // flips the window into flat mode, and any subsequent `set_content`
        // wraps the supplied widget so the bubbles overlay it. Apps must
        // not instantiate HoverControls directly.
        // ===================================================================

        private Singularity.Widgets.HoverControls? _bubble_bar = null;

        public delegate void BubbleAction ();
        public delegate void BubbleSearchAction (string text);

        private Singularity.Widgets.HoverControls _ensure_bubble_bar () {
            if (_bubble_bar == null) {
                _bubble_bar = Singularity.Widgets.HoverControls.with_window_bubbles (this);
                _bubble_bar.set_compact_controls (_phone);
                _bubble_bar.set_welcome (_welcome_pages > 0);
                // If set_content ran before the first bubble was registered,
                // re-wrap the user content now so the bar overlays it.
                if (_user_content != null) {
                    if (_content_bin != null && _content_bin.get_parent () != null)
                        content_area.remove (_content_bin);
                    _install_content ();
                }
                _sync_app_menu ();
            }
            return _bubble_bar;
        }

        private T _bubble_added<T> (T bubble) {
            _sync_sidebar_toggle ();
            return bubble;
        }

        /**
         * Add an icon-only bubble (preferred for toolbar-style actions).
         * Returns the Button so callers can flip visibility / sensitivity.
         */
        public Button add_bubble_icon (string icon_name,
                                       string tooltip,
                                       owned BubbleAction action) {
            var btn = new Button.from_icon_name (icon_name);
            btn.add_css_class ("flat");
            btn.tooltip_text = tooltip;
            btn.clicked.connect (() => action ());
            _ensure_bubble_bar ().add (btn);
            return _bubble_added<Button> (btn);
        }

        /** Neutral pill text bubble. Use for plain actions (e.g. Cancel). */
        public Button add_bubble_text (string label, owned BubbleAction action) {
            return _bubble_added<Button> (_ensure_bubble_bar ().add_text_button (label, (owned) action));
        }

        /** Accent suggested-action pill. Reserve for the primary CTA. */
        public Button add_bubble_suggested (string label, owned BubbleAction action) {
            return _bubble_added<Button> (_ensure_bubble_bar ().add_suggested_button (label, (owned) action));
        }

        /**
         * Inject an arbitrary widget as a bubble (use sparingly).
         *
         * Buttons and menu buttons move into the more bubble like any other
         * bubble when the row gets narrow. Other widgets stay in the row and
         * give up width down to nothing, so they should clip their content.
         */
        public void add_bubble_widget (Widget w) {
            _ensure_bubble_bar ().add (w);
            _bubble_added<Widget> (w);
        }

        /**
         * Tunes when a bubble moves into the automatic more bubble on narrow
         * windows.
         *
         * Bubbles with a lower priority move first and, among equal
         * priorities, the last added moves first. Every bubble starts at 0.
         * `BUBBLE_PRIORITY_PINNED` keeps the bubble in the row.
         *
         * @param bubble   A widget previously added with `add_bubble_*`.
         * @param priority Higher values stay in the row longer.
         */
        public void set_bubble_priority (Widget bubble, int priority) {
            if (_bubble_bar != null) _bubble_bar.set_bubble_priority (bubble, priority);
        }

        /**
         * Add a label bubble. Used for status text (word count, etc).
         * `dimmed` keeps the GTK `dim-label` + `caption` look. Leave
         * it off for bubble mode (white-on-accent labels read better
         * full-strength), on for SSD mode where the label sits inside
         * the regular toolbar background.
         */
        public Label add_bubble_label (string text, bool dimmed = false) {
            var lbl = new Label (text);
            lbl.add_css_class ("singularity-hover-label");
            if (dimmed) {
                lbl.add_css_class ("dim-label");
                lbl.add_css_class ("caption");
            }
            _ensure_bubble_bar ().add (lbl);
            return _bubble_added<Label> (lbl);
        }

        /**
         * Add a menu bubble: an icon button that pops up the given
         * popover on click. Avoids the awkward MenuButton arrow + flat
         * toggle visual.
         */
        public Button add_bubble_menu (string icon_name,
                                       string tooltip,
                                       Popover popover) {
            var btn = new Button.from_icon_name (icon_name);
            btn.add_css_class ("flat");
            btn.tooltip_text = tooltip;
            popover.set_parent (btn);
            popover.set_position (PositionType.BOTTOM);
            popover.has_arrow = false;
            btn.clicked.connect (() => {
                if (popover.visible) popover.popdown ();
                else popover.popup ();
            });
            _ensure_bubble_bar ().add (btn);
            _bubble_bar.mark_app_menu (btn);
            return _bubble_added<Button> (btn);
        }

        /**
         * Add a search bubble. Returns the underlying SearchEntry for any
         * extra setup (placeholder tweaks, key bindings, etc.). The
         * `action` is invoked on every search_changed.
         */
        public Singularity.Widgets.SearchBubble add_bubble_search (
                string placeholder,
                owned BubbleSearchAction action) {
            var sb = new Singularity.Widgets.SearchBubble (placeholder);
            sb.search_changed.connect ((t) => action (t));
            _ensure_bubble_bar ().add (sb);
            return _bubble_added<Singularity.Widgets.SearchBubble> (sb);
        }

        /** True if any bubble has been added. */
        public bool has_bubbles { get { return _bubble_bar != null; } }

        public bool bubbles_hidden {
            get { return _bubbles_hidden; }
            set {
                _bubbles_hidden = value;
                if (_bubble_bar != null) _bubble_bar.set_row_hidden (value);
            }
        }
        private bool _bubbles_hidden = false;

        /**
         * Toggle hover-to-reveal mode on the bubble bar. Use for
         * scenic content (video playback, fullscreen photo viewer) so
         * the bubbles fade out and reappear on hover. Welcome/idle
         * states should pass false so bubbles stay always visible.
         */
        public void set_bubbles_on_hover (bool on_hover) {
            if (_bubble_bar == null) return;
            if (on_hover) _bubble_bar.add_css_class ("singularity-hover-on-content");
            else          _bubble_bar.remove_css_class ("singularity-hover-on-content");
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

            if (!_narrow) sidebar_revealer.set_child(sidebar_scroll_wrap);
            widget.vexpand = true;
            sidebar_area.append(widget);
            if (_welcome_pages > 0) _apply_sidebar_welcome(sidebar_area);
            _sync_sidebar_toggle();
            _queue_adaptive_update();
        }

        /**
         * Shows or hides the sidebar with a slide-in/out animation.
         *
         * On narrow windows the sidebar is not docked: a call that follows
         * `get_sidebar_visible()` or comes from user input (a toggle button,
         * a shortcut) opens or closes it as a drawer over the content, any
         * other call only records whether the sidebar belongs on screen.
         *
         * @param visible `true` to reveal the sidebar, `false` to hide it.
         */
        public void set_sidebar_visible(bool visible) {
            bool from_user = _take_toggle_probe() || _in_input_dispatch();
            if (!_narrow) {
                _sidebar_wanted = visible;
                _sidebar_user_hidden = from_user && !visible;
                sidebar_revealer.reveal_child = visible;
            } else if (from_user) {
                _set_drawer_open(visible);
            } else {
                _sidebar_wanted = visible;
                if (!visible) {
                    _sidebar_user_hidden = false;
                    _set_drawer_open(false);
                }
            }
            _sync_sidebar_toggle();
        }

        /**
         * Returns `true` if the sidebar is currently visible, docked or,
         * on narrow windows, open as a drawer.
         */
        public bool get_sidebar_visible() {
            _arm_toggle_probe();
            return _narrow ? _drawer_open : sidebar_revealer.reveal_child;
        }

        /**
         * Sets the minimum width of the sidebar panel.
         *
         * @param width Width in pixels; default is 180.
         */
        public void set_sidebar_width(int width) {
            _sidebar_width = width;
            sidebar_scroll_wrap.set_size_request(width, -1);
            _queue_adaptive_update();
        }

        // -- Adaptive layout -------------------------------------------

        internal void welcome_page_shown() {
            _welcome_pages++;
            if (_welcome_pages == 1) _apply_welcome();
        }

        internal void welcome_page_hidden() {
            if (_welcome_pages == 0) return;
            _welcome_pages--;
            if (_welcome_pages == 0) _apply_welcome();
        }

        private void _apply_welcome() {
            if (_bubble_bar != null) _bubble_bar.set_welcome(_welcome_pages > 0);
            _apply_sidebar_welcome(sidebar_area);
            _sync_sidebar_toggle();
        }

        private void _apply_sidebar_welcome(Widget root) {
            for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
                if (c is AppSidebar) ((AppSidebar) c).set_welcome(_welcome_pages > 0);
                else _apply_sidebar_welcome(c);
            }
        }

        private bool _has_sidebar() {
            return sidebar_area.get_first_child() != null;
        }

        private void _arm_toggle_probe() {
            _toggle_probe = true;
            if (_toggle_probe_source != 0) return;
            _toggle_probe_source = Idle.add(() => {
                _toggle_probe = false;
                _toggle_probe_source = 0;
                return false;
            });
        }

        private bool _take_toggle_probe() {
            bool probed = _toggle_probe;
            _toggle_probe = false;
            return probed;
        }

        private static bool _in_input_dispatch() {
            unowned GLib.Source? source = MainContext.current_source();
            if (source == null) return false;
            unowned string? name = source.get_name();
            return name != null && name.has_prefix("GDK") && name.contains("Event source");
        }

        private void _queue_adaptive_update() {
            if (_adaptive_source != 0) return;
            _adaptive_source = Idle.add(() => {
                _adaptive_source = 0;
                _update_adaptive();
                return false;
            });
        }

        private int _narrow_threshold() {
            int min, nat;
            sidebar_area.measure(Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            int sidebar = int.max(_sidebar_width, min);
            int content = _content_bin != null ? _content_bin.child_minimum_width() : 0;
            return sidebar + int.max(NARROW_CONTENT_WIDTH, content);
        }

        private void _update_adaptive() {
            int width = get_width();
            if (width <= 0) return;

            bool phone = _phone ? width < PHONE_WIDTH + ADAPTIVE_HYSTERESIS : width < PHONE_WIDTH;
            if (phone != _phone) {
                _phone = phone;
                if (_bubble_bar != null) _bubble_bar.set_compact_controls(phone);
            }

            bool narrow = false;
            if (_has_sidebar()) {
                int threshold = _narrow_threshold();
                narrow = _narrow ? width < threshold + ADAPTIVE_HYSTERESIS : width < threshold;
            }
            if (narrow != _narrow) _set_narrow(narrow);
        }

        private void _set_narrow(bool narrow) {
            _narrow = narrow;
            if (narrow) {
                sidebar_revealer.reveal_child = false;
                sidebar_revealer.set_child(null);
                sidebar_scroll_wrap.hscrollbar_policy = PolicyType.AUTOMATIC;
                sidebar_scroll_wrap.propagate_natural_width = true;
                _drawer_box.append(sidebar_scroll_wrap);
            } else {
                _drawer_open = false;
                _drawer_revealer.reveal_child = false;
                _drawer_revealer.visible = false;
                _scrim_revealer.reveal_child = false;
                _scrim_revealer.visible = false;
                _drawer_box.remove(sidebar_scroll_wrap);
                sidebar_scroll_wrap.hscrollbar_policy = PolicyType.NEVER;
                sidebar_scroll_wrap.propagate_natural_width = false;
                sidebar_revealer.set_child(sidebar_scroll_wrap);
                sidebar_revealer.reveal_child = _sidebar_wanted;
            }
            _sync_sidebar_toggle();
        }

        private void _set_drawer_open(bool open) {
            if (!_narrow) open = false;
            if (_drawer_open == open) return;
            _drawer_open = open;
            if (open) {
                _hook_sidebar_items(sidebar_area);
                _scrim_revealer.visible = true;
                _drawer_revealer.visible = true;
            }
            _scrim_revealer.reveal_child = open;
            _drawer_revealer.reveal_child = open;
        }

        private void _on_drawer_revealed() {
            if (_drawer_open || _drawer_revealer.child_revealed) return;
            _drawer_revealer.visible = false;
            _scrim_revealer.visible = false;
        }

        private void _on_scrim_released(int n_press, double x, double y) {
            _set_drawer_open(false);
        }

        private void _hook_sidebar_items(Widget root) {
            for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
                if (c.get_data<string>("singularity-drawer-hook") == null) {
                    if (c is Button && c.has_css_class("singularity-sidebar-row")) {
                        c.set_data<string>("singularity-drawer-hook", "1");
                        ((Button) c).clicked.connect(_on_sidebar_item_activated);
                    } else if (c is ListBox && c.has_css_class("navigation-sidebar")) {
                        c.set_data<string>("singularity-drawer-hook", "1");
                        ((ListBox) c).row_activated.connect(_on_sidebar_row_activated);
                    }
                }
                _hook_sidebar_items(c);
            }
        }

        private void _on_sidebar_item_activated() {
            if (_drawer_open) _set_drawer_open(false);
        }

        private void _on_sidebar_row_activated(ListBoxRow row) {
            if (_drawer_open) _set_drawer_open(false);
        }

        private void _toggle_sidebar_from_user() {
            if (_narrow) {
                _set_drawer_open(!_drawer_open);
            } else {
                bool reveal = !sidebar_revealer.reveal_child;
                _sidebar_wanted = reveal;
                _sidebar_user_hidden = !reveal;
                sidebar_revealer.reveal_child = reveal;
            }
            _sync_sidebar_toggle();
        }

        private void _sync_sidebar_toggle() {
            if (_bubble_bar == null) return;
            bool show = _has_sidebar() && _welcome_pages == 0
                && !_bubble_bar.has_own_sidebar_toggle()
                && (_narrow ? (_sidebar_wanted || _sidebar_user_hidden) : _sidebar_user_hidden);
            if (!show && _auto_sidebar_toggle == null) return;
            if (_auto_sidebar_toggle == null) {
                _auto_sidebar_toggle = new Button.from_icon_name("sidebar-show-symbolic");
                _auto_sidebar_toggle.tooltip_text = _("Toggle Sidebar");
                _auto_sidebar_toggle.clicked.connect(_toggle_sidebar_from_user);
                _bubble_bar.set_sidebar_toggle(_auto_sidebar_toggle);
            }
            _auto_sidebar_toggle.visible = show;
        }

        private bool _on_adaptive_key(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (keyval == Gdk.Key.Escape) {
                if (_drawer_open) {
                    _set_drawer_open(false);
                    return true;
                }
                if (_bubble_bar != null && _bubble_bar.search_expanded) {
                    _bubble_bar.collapse_search();
                    return true;
                }
                return false;
            }
            var held = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK
                | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK;
            bool plain = (state & held) == 0;
            if (keyval == Gdk.Key.F10 && plain && _app_menu_popover != null) {
                if (application != null && application.get_actions_for_accel("F10").length > 0)
                    return false;
                return popup_app_menu();
            }
            if (keyval == Gdk.Key.F9 && plain && _has_sidebar()) {
                if (application != null && application.get_actions_for_accel("F9").length > 0)
                    return false;
                _toggle_sidebar_from_user();
                return true;
            }
            return false;
        }

        /**
         * Shows a toast at the bottom of the window. Toasts added while
         * another one is visible wait in a queue.
         *
         * @param toast The toast to show.
         */
        public void add_toast(Toast toast) {
            if (_toast_host == null) {
                _toast_host = new ToastHost();
                _root_overlay.add_overlay(_toast_host.slot);
            }
            _toast_host.add_toast(toast);
        }

        /**
         * True while the window offers the application menu bar in an App
         * Menu bubble, because the desktop does not show it in its top panel.
         */
        public bool has_app_menu { get { return _app_menu_offered; } }

        /**
         * True while the desktop shows the application menus in its top
         * panel, so the window offers no App Menu of its own. Notifies when
         * the shell starts or stops or the user switches the setting.
         */
        public bool global_menu_in_use { get { return _global_menu_in_use; } }

        private bool _app_menu_offered = false;
        private bool _global_menu_in_use = false;

        private void _set_app_menu_state(bool offered, bool global_menu) {
            if (_global_menu_in_use != global_menu) {
                _global_menu_in_use = global_menu;
                notify_property("global-menu-in-use");
            }
            if (_app_menu_offered != offered) {
                _app_menu_offered = offered;
                notify_property("has-app-menu");
            }
        }

        /**
         * Opens the App Menu bubble. The same happens when the user presses
         * F10 and no application action uses that accelerator.
         *
         * @return `false` when the window has no App Menu, because the app
         *         has no menu bar or the desktop shows it in its top panel.
         */
        public bool popup_app_menu() {
            if (_classic_menubar != null && _classic_menubar.visible && _app_menu_offered) {
                var first = _classic_menubar.get_first_child();
                if (first == null) return false;
                first.activate();
                return true;
            }
            if (_app_menu_popover == null || !_app_menu_offered) return false;
            if (_bubble_bar != null && _bubble_bar.search_expanded) _bubble_bar.collapse_search();
            if (_app_menu_btn == null) {
                int w = content_area.get_width();
                Gdk.Rectangle rect = { int.max(0, w - 24), 8, 1, 1 };
                _app_menu_popover.set_pointing_to(rect);
            }
            _app_menu_popover.popup();
            return true;
        }

        private void _track_menubar() {
            if (_menubar_app != application) {
                if (_menubar_handler != 0 && _menubar_app != null)
                    _menubar_app.disconnect(_menubar_handler);
                _menubar_handler = 0;
                _menubar_app = application;
                if (_menubar_app != null)
                    _menubar_handler = _menubar_app.notify["menubar"].connect(_sync_app_menu);
            }
            _sync_app_menu();
        }

        private void _show_classic_menubar(MenuModel model) {
            if (_classic_menubar == null) {
                _classic_menubar = new Singularity.Shell.GlobalMenuBar();
                _classic_menubar.add_css_class("singularity-classic-menubar");
                _classic_menubar.valign = Align.CENTER;
                _classic_menubar.register_action_group("win", this);
                Widget? after = null;
                for (var c = toolbar.start_box.get_first_child(); c != null; c = c.get_next_sibling()) {
                    if (c != toolbar.minimize_btn && c != toolbar.maximize_btn && c != toolbar.close_btn) break;
                    after = c;
                }
                toolbar.start_box.insert_child_after(_classic_menubar, after);
            }
            if (application != null) _classic_menubar.register_action_group("app", application);
            if (_classic_menubar_model != model) {
                _classic_menubar_model = model;
                _classic_menubar.update_model(model);
            }
            _classic_menubar.visible = true;
            toolbar.visible = true;
        }

        private bool _global_menu_active() {
            return _shell_present && Singularity.Runtime.global_menu_enabled();
        }

        private void _sync_app_menu() {
            bool global_menu = _global_menu_active();
            if (!global_menu) {
                if (show_menubar) {
                    show_menubar = false;
                    _menubar_hidden = true;
                }
            } else if (_menubar_hidden) {
                _menubar_hidden = false;
                show_menubar = true;
            }

            MenuModel? model = application != null ? application.menubar : null;
            if (global_menu || model == null) {
                if (_app_menu_popover != null) _app_menu_popover.popdown();
                if (_app_menu_btn != null) _app_menu_btn.visible = false;
                if (_classic_menubar != null) _classic_menubar.visible = false;
                if (_force_ssd) toolbar.visible = false;
                _set_app_menu_state(false, global_menu);
                return;
            }

            if (_app_menu_popover == null) {
                _app_menu_popover = new PopoverMenu.from_model(model);
                _app_menu_popover.add_css_class("singularity-app-menu");
                if (_app_menu_btn == null && _bubble_bar == null) {
                    _app_menu_popover.set_parent(content_area);
                    _app_menu_popover.set_position(PositionType.BOTTOM);
                    _app_menu_popover.has_arrow = false;
                }
            } else if (_app_menu_popover.menu_model != model) {
                _app_menu_popover.menu_model = model;
            }

            _set_app_menu_state(true, false);
            if (_force_ssd || _legacy_titlebar) {
                _show_classic_menubar(model);
                return;
            }
            if (_bubble_bar == null) return;
            if (_app_menu_btn == null) {
                if (_app_menu_popover.get_parent() != null) _app_menu_popover.unparent();
                _app_menu_btn = add_bubble_menu("open-menu-symbolic", _("App Menu"), _app_menu_popover);
                _app_menu_btn.add_css_class("singularity-app-menu-bubble");
                _bubble_bar.set_bubble_priority(_app_menu_btn, BUBBLE_PRIORITY_PINNED);
                _bubble_bar.mark_trailing(_app_menu_btn);
            }
            _app_menu_btn.visible = true;
        }
    }

    /**
     * The application menu for windows that are not a
     * Singularity.Widgets.Window, such as a terminal with its own
     * controls. Window offers the same menu by itself.
     */
    public class AppMenu : Object {
        private static AppMenu? _instance = null;
        private bool _shell_present = false;
        private uint _shell_watch = 0;
        private GLib.Settings? _settings = null;

        /**
         * True while the desktop shows the application menus in its top
         * panel: the shell is running and `global-menu-enabled` is on. The
         * app should then offer no menu button of its own.
         */
        public bool global_menu_in_use { get; private set; default = false; }

        /** The shared monitor. */
        public static AppMenu get_default() {
            if (_instance == null) _instance = new AppMenu();
            return _instance;
        }

        private AppMenu() {
            _shell_present = Singularity.Runtime.is_shell_running();
            _settings = Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
            if (_settings != null && _settings.settings_schema.has_key("global-menu-enabled"))
                _settings.changed["global-menu-enabled"].connect(() => update());
            _shell_watch = Bus.watch_name(BusType.SESSION, Singularity.Runtime.SHELL_BUS_NAME,
                BusNameWatcherFlags.NONE,
                () => { _shell_present = true; update(); },
                () => { _shell_present = false; update(); });
            update();
        }

        private void update() {
            bool active = _shell_present && Singularity.Runtime.global_menu_enabled();
            if (global_menu_in_use != active) global_menu_in_use = active;
        }

        /**
         * Builds the popover of the application menu from the menu bar of
         * `app`, styled like the App Menu bubble, or returns null when the
         * app has no menu bar.
         */
        public static Gtk.PopoverMenu? create_popover(Gtk.Application app) {
            if (app.menubar == null) return null;
            var popover = new Gtk.PopoverMenu.from_model(app.menubar);
            popover.add_css_class("singularity-app-menu");
            return popover;
        }

        /**
         * Opens the application menu of `app` below `anchor`. The popover is
         * removed when it closes.
         *
         * @return false when the app has no menu bar.
         */
        public static bool popup(Gtk.Application app, Gtk.Widget anchor) {
            var popover = create_popover(app);
            if (popover == null) return false;
            popover.set_parent(anchor);
            popover.closed.connect(() => Idle.add(() => {
                popover.unparent();
                return Source.REMOVE;
            }));
            popover.popup();
            return true;
        }
    }
}
