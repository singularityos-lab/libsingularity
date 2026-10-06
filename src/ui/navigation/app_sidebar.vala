using Gtk;

namespace Singularity.Widgets {

    /**
     * A standard navigation sidebar for Singularity apps.
     *
     * ScrolledWindow -> Box(navigation-sidebar). Append children to
     * `box` to populate the sidebar: buttons, separators, labels, etc.
     *
     * Toolbar-like controls go in the sidebar's own bubble row through
     * `add_bubble_*`, which work like the window's. The row sits above the
     * scrolling content, in the band the titlebar inset reserves, and moves
     * bubbles into a more bubble when the sidebar gets narrow.
     *
     * Example:
     * {{{
     *   var sidebar = new AppSidebar();
     *   Singularity.Widgets.apply_titlebar_inset (sidebar.box);
     *   sidebar.box.append(new Button.with_label(_("Home")));
     *   sidebar.add_bubble_icon("list-add-symbolic", _("New"), () => add());
     *   window.set_sidebar(sidebar);
     * }}}
     */
    public class AppSidebar : Box, Gtk.Buildable {

        /** The inner content box. Append your rows here. */
        public Box box { get; private set; }

        internal ScrolledWindow _scroll;
        private int _width = 200;
        private BubbleBox? _bubbles = null;
        private bool _welcome = false;

        private const int BUBBLE_ROW_GAP = 10;

        /** Preferred width in pixels. Safe to set after construction. */
        public int sidebar_width {
            get { return _width; }
            set {
                _width = value;
                if (_scroll != null) _scroll.set_size_request(_width, -1);
            }
        }

        /**
         * Creates a new AppSidebar with default 200 px width.
         *
         * @param width Preferred width in pixels (default 200).
         */
        public AppSidebar(int width = 200) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.sidebar_width = width;
        }

        construct {
            orientation = Orientation.VERTICAL;
            spacing = 0;
            _scroll = new ScrolledWindow();
            _scroll.set_size_request(_width, -1);
            _scroll.hscrollbar_policy = PolicyType.NEVER;
            _scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            _scroll.vexpand = true;
            // ScrolledWindow draws its own frame by default in GTK4;
            // that gave the AppSidebar a visible inner right border
            // that Files (which uses a raw scroll) doesn't have.
            _scroll.has_frame = false;

            box = new Box(Orientation.VERTICAL, 2);
            box.add_css_class("navigation-sidebar");
            // No own margins: the Window.sidebar_area already supplies
            // the 10px padding gutter via `.window-sidebar` CSS.

            _scroll.set_child(box);
            append(_scroll);
        }

        /** True if any bubble has been added. */
        public bool has_bubbles { get { return _bubbles != null; } }

        private BubbleBox _ensure_bubbles () {
            if (_bubbles == null) {
                _bubbles = new BubbleBox ();
                _bubbles.add_css_class ("singularity-sidebar-bubbles");
                _bubbles.hexpand = true;
                _bubbles.pack_start = true;
                _bubbles.margin_bottom = BUBBLE_ROW_GAP;
                _bubbles.set_welcome (_welcome);
                _bubbles.search_activated.connect (_expand_search);
                _bubbles.search_close_requested.connect (() => _close_search (true));
                _bubbles.search_fits.connect (() => _close_search (false));
                prepend (_bubbles);
                box.set_data<bool> ("singularity-sidebar-bubbles", true);
                if (box.get_data<bool> ("singularity-titlebar-inset-installed")) box.margin_top = 0;
            }
            return _bubbles;
        }

        private T _add_bubble<T> (Widget bubble) {
            BubbleBox.prepare (bubble);
            _ensure_bubbles ().add_item (bubble);
            return (T) bubble;
        }

        /**
         * Adds an icon-only bubble to the sidebar's bubble row.
         * Returns the Button so callers can flip visibility / sensitivity.
         */
        public Button add_bubble_icon (string icon_name,
                                       string tooltip,
                                       owned Window.BubbleAction action) {
            var btn = new Button.from_icon_name (icon_name);
            btn.add_css_class ("flat");
            btn.tooltip_text = tooltip;
            btn.clicked.connect (() => action ());
            return _add_bubble<Button> (btn);
        }

        /** Neutral pill text bubble. Use for plain actions. */
        public Button add_bubble_text (string label, owned Window.BubbleAction action) {
            var btn = new Button.with_label (label);
            btn.add_css_class ("flat");
            btn.clicked.connect (() => action ());
            return _add_bubble<Button> (btn);
        }

        /** Accent suggested-action pill. Reserve for the primary action. */
        public Button add_bubble_suggested (string label, owned Window.BubbleAction action) {
            var btn = new Button.with_label (label);
            btn.add_css_class ("flat");
            btn.add_css_class ("suggested-action");
            btn.clicked.connect (() => action ());
            return _add_bubble<Button> (btn);
        }

        /**
         * Injects an arbitrary widget as a bubble (use sparingly).
         *
         * A segmented control gets the bubble-row segmented style and, like
         * a view switcher, collapses to a single bubble showing the current
         * option when the row gets narrow. Buttons and menu buttons move
         * into the more bubble like any other bubble; other widgets stay in
         * the row and give up width down to nothing.
         */
        public void add_bubble_widget (Widget w) {
            _add_bubble<Widget> (w);
        }

        /**
         * Adds a label bubble for status text. `dimmed` keeps the GTK
         * `dim-label` + `caption` look.
         */
        public Label add_bubble_label (string text, bool dimmed = false) {
            var lbl = new Label (text);
            lbl.add_css_class ("singularity-hover-label");
            if (dimmed) {
                lbl.add_css_class ("dim-label");
                lbl.add_css_class ("caption");
            }
            return _add_bubble<Label> (lbl);
        }

        /**
         * Adds a menu bubble: an icon button that pops up the given
         * popover on click.
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
            _add_bubble<Button> (btn);
            _bubbles.mark_app_menu (btn);
            return btn;
        }

        /**
         * Adds a search bubble. The `action` is invoked on every
         * search_changed. On a narrow sidebar the search collapses to an
         * icon that expands across the row when clicked.
         */
        public SearchBubble add_bubble_search (string placeholder,
                                               owned Window.BubbleSearchAction action) {
            var sb = new SearchBubble (placeholder);
            sb.search_changed.connect ((t) => action (t));
            return _add_bubble<SearchBubble> (sb);
        }

        /**
         * Tunes when a bubble moves into the more bubble on a narrow
         * sidebar, like `Window.set_bubble_priority`.
         *
         * @param bubble   A widget previously added with `add_bubble_*`.
         * @param priority Higher values stay in the row longer.
         */
        public void set_bubble_priority (Widget bubble, int priority) {
            if (_bubbles != null) _bubbles.set_priority (bubble, priority);
        }

        internal void set_welcome (bool welcome) {
            _welcome = welcome;
            if (_bubbles == null) return;
            if (welcome) _close_search (true);
            _bubbles.set_welcome (welcome);
        }

        public void focus_search (SearchBubble search) {
            if (_bubbles == null) return;
            if (_bubbles.expanded_search == search || search.get_child_visible ()) search.grab_focus_entry ();
            else _expand_search (search);
        }

        private void _expand_search (SearchBubble search) {
            _bubbles.set_expanded (search, 0);
            search.grab_focus_entry ();
            if (search.get_data<string> ("singularity-stop-search") == null) {
                search.set_data<string> ("singularity-stop-search", "1");
                search.entry.stop_search.connect (() => _close_search (true));
            }
        }

        private void _close_search (bool clear) {
            var search = _bubbles.expanded_search;
            if (search == null) return;
            _bubbles.set_expanded (null, 0);
            if (clear) search.clear ();
        }

        // Buildable: nested <child> widgets populate the inner content box.
        public void add_child(Gtk.Builder builder, GLib.Object child, string? type) {
            if (child is Widget && box != null) {
                box.append((Widget) child);
            } else {
                base.add_child(builder, child, type);
            }
        }
    }
}