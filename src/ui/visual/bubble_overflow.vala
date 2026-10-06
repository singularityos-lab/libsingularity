using Gtk;

namespace Singularity.Widgets {

    internal enum BubbleKind {
        BUTTON,
        SEARCH,
        SWITCHER,
        LABEL,
        SEPARATOR,
        OTHER
    }

    internal class BubbleItem : Object {
        public Widget widget;
        public BubbleKind kind;
        public int order;
        public int priority = 0;
        public bool app_menu = false;
        public bool trailing = false;
        public Button? proxy = null;
        public Label? proxy_label = null;
        public bool compact = false;
        public bool overflowed = false;
        public bool parked = false;
        public bool saved_focusable = true;
        public int width = 0;
    }

    /**
     * The app bubble group of a HoverControls row.
     *
     * Bubbles are laid out left to right at their natural width, exactly
     * like a horizontal Gtk.Box. When the group gets less room than that,
     * search bubbles collapse to an icon, view switchers collapse to a
     * single bubble showing the current value, and then bubbles move into
     * an automatic more bubble: lowest priority first, and among equal
     * priorities the last added first. Suggested actions, search bubbles,
     * sidebar toggles and widgets that cannot be shown as a menu row never
     * move into the more bubble.
     */
    internal class BubbleBox : Widget {

        private const int SPACING = 4;
        private const int HYSTERESIS = 12;

        public signal void search_activated (SearchBubble search);
        public signal void search_close_requested ();
        public signal void search_fits ();

        private GenericArray<BubbleItem> _items = new GenericArray<BubbleItem> ();
        private int _next_order = 0;
        private int _level = 0;
        private bool _welcome = false;
        private SearchBubble? _expanded = null;
        private int _expanded_overhead = 0;
        private int _expanded_width = -1;
        private bool _search_fits_queued = false;
        private bool _resize_queued = false;
        private Button _more_btn;
        private Button _search_close_btn;
        private ContextMenu? _more_menu = null;
        private BubbleItem? _trailing = null;

        static construct {
            set_css_name ("box");
        }

        public BubbleBox () {
            Object ();
        }

        construct {
            _more_btn = new Button.from_icon_name ("view-more-symbolic");
            _style_bubble (_more_btn);
            _more_btn.tooltip_text = _("More");
            _more_btn.clicked.connect (_show_more_menu);
            _more_btn.set_child_visible (false);
            _more_btn.set_parent (this);

            _search_close_btn = new Button.from_icon_name ("window-close-symbolic");
            _style_bubble (_search_close_btn);
            _search_close_btn.tooltip_text = _("Close Search");
            _search_close_btn.clicked.connect (() => search_close_requested ());
            _search_close_btn.set_child_visible (false);
            _search_close_btn.set_parent (this);
        }

        public override void dispose () {
            Widget? child = get_first_child ();
            while (child != null) {
                Widget? next = child.get_next_sibling ();
                child.unparent ();
                child = next;
            }
            base.dispose ();
        }

        /** Keeps the bubbles at the start of the row while some overflow. */
        public bool pack_start { get; set; default = false; }

        /** True while a collapsed search bubble is shown across the row. */
        public bool expanded { get { return _expanded != null; } }

        /** The search bubble currently expanded across the row, if any. */
        public SearchBubble? expanded_search { get { return _expanded; } }

        public void add_item (Widget w) {
            var item = new BubbleItem ();
            item.widget = w;
            item.order = _next_order++;
            item.kind = _kind_of (w);
            w.insert_before (this, _trailing != null ? _trailing.widget : _more_btn);

            if (item.kind == BubbleKind.SEARCH) {
                var search = (SearchBubble) w;
                var proxy = new Button.from_icon_name ("system-search-symbolic");
                _style_bubble (proxy);
                proxy.tooltip_text = search.placeholder;
                proxy.clicked.connect (() => search_activated (search));
                item.proxy = proxy;
            } else if (item.kind == BubbleKind.SWITCHER) {
                _build_switcher_proxy (item);
            }
            if (item.proxy != null) {
                item.proxy.set_child_visible (false);
                item.proxy.insert_after (this, w);
            }
            _items.add (item);
            queue_resize ();
        }

        public void set_priority (Widget w, int priority) {
            var item = _find (w);
            if (item == null) return;
            item.priority = priority;
            queue_resize ();
        }

        public void mark_app_menu (Widget w) {
            var item = _find (w);
            if (item != null) item.app_menu = true;
        }

        public void mark_trailing (Widget w) {
            var item = _find (w);
            if (item == null) return;
            if (_trailing != null) _trailing.trailing = false;
            item.trailing = true;
            _trailing = item;
            w.insert_before (this, _more_btn);
            queue_resize ();
        }

        public void set_welcome (bool welcome) {
            if (_welcome == welcome) return;
            _welcome = welcome;
            queue_resize ();
        }

        public void set_expanded (SearchBubble? search, int overhead) {
            var previous = _expanded;
            if (_expanded != null) _expanded.set_expanded (false);
            _expanded = search;
            _expanded_overhead = overhead;
            _expanded_width = -1;
            if (search != null) search.set_expanded (true);
            queue_resize ();
            if (search == null && previous != null) {
                var item = _find (previous);
                if (item != null && item.proxy != null) {
                    var proxy = item.proxy;
                    Idle.add (() => {
                        if (proxy.get_mapped ()) proxy.grab_focus ();
                        return false;
                    });
                }
            }
        }

        private BubbleItem? _find (Widget w) {
            for (int i = 0; i < _items.length; i++) {
                if (_items[i].widget == w) return _items[i];
            }
            return null;
        }

        private static BubbleKind _kind_of (Widget w) {
            if (w is SearchBubble) return BubbleKind.SEARCH;
            if (w is BubbleSwitcher || w is SegmentedControl) return BubbleKind.SWITCHER;
            if (w is Button || w is MenuButton) return BubbleKind.BUTTON;
            if (w is Label) return BubbleKind.LABEL;
            if (w.has_css_class ("singularity-hover-sep")) return BubbleKind.SEPARATOR;
            return BubbleKind.OTHER;
        }

        /**
         * Gives a widget the look of a bubble in a bubble row: the bubble
         * shell, icon sizing and, for a segmented control, the bubble-row
         * segmented style.
         */
        public static void prepare (Widget w) {
            w.add_css_class ("singularity-hover-btn");
            if (w is Button) {
                var child = ((Button) w).get_child ();
                if (child is Image) {
                    w.add_css_class ("image-button");
                    ((Image) child).pixel_size = -1;
                }
                w.set_size_request (20, 20);
            }
            if (w is SegmentedControl) w.add_css_class ("singularity-hover-segmented");
            w.valign = Align.CENTER;
        }

        private static void _style_bubble (Button btn) {
            btn.add_css_class ("flat");
            btn.add_css_class ("singularity-hover-btn");
            var child = btn.get_child ();
            if (child is Image) {
                btn.add_css_class ("image-button");
                ((Image) child).pixel_size = -1;
            }
            btn.set_size_request (20, 20);
            btn.valign = Align.CENTER;
        }

        // -- View switcher proxy ------------------------------------------

        private void _build_switcher_proxy (BubbleItem item) {
            var proxy = new Button ();
            var box = new Box (Orientation.HORIZONTAL, 4);
            var lbl = new Label ("");
            box.append (lbl);
            box.append (new Image.from_icon_name ("pan-down-symbolic"));
            proxy.set_child (box);
            _style_bubble (proxy);
            proxy.add_css_class ("text-button");
            item.proxy = proxy;
            item.proxy_label = lbl;

            var w = item.widget;
            _sync_switcher_proxy (item);
            w.notify["active-option"].connect (() => _sync_switcher_proxy (item));
            proxy.clicked.connect (() => {
                var menu = new ContextMenu (proxy);
                menu.set_position (PositionType.BOTTOM);
                _add_switcher_rows (menu, w);
                menu.closed.connect (() => Idle.add (() => { menu.unparent (); return false; }));
                menu.popup ();
            });
        }

        private static void _sync_switcher_proxy (BubbleItem item) {
            string? current = _switcher_current (item.widget);
            item.proxy_label.label = current != null ? _switcher_label (item.widget, current) : "";
            item.proxy.tooltip_text = item.proxy_label.label;
        }

        private static string? _switcher_current (Widget w) {
            if (w is BubbleSwitcher) return ((BubbleSwitcher) w).active_option;
            return ((SegmentedControl) w).current_option ();
        }

        private static Gee.List<string> _switcher_names (Widget w) {
            if (w is BubbleSwitcher) return ((BubbleSwitcher) w).option_names ();
            return ((SegmentedControl) w).option_names ();
        }

        private static string _switcher_label (Widget w, string name) {
            if (w is BubbleSwitcher) return ((BubbleSwitcher) w).option_label (name);
            return ((SegmentedControl) w).option_label (name);
        }

        private static void _switcher_select (Widget w, string name) {
            if (w is BubbleSwitcher) ((BubbleSwitcher) w).set_active (name);
            else ((SegmentedControl) w).set_active (name);
        }

        private static void _add_switcher_rows (ContextMenu menu, Widget w) {
            string? current = _switcher_current (w);
            foreach (string name in _switcher_names (w)) {
                string option = name;
                menu.add_widget (_menu_row (_switcher_label (w, name), null, name == current,
                                            true, menu, () => _switcher_select (w, option)));
            }
        }

        // -- More menu ------------------------------------------------------

        private delegate void RowAction ();

        private static MenuRow _menu_row (string label, string? icon, bool checked,
                                          bool sensitive, ContextMenu menu,
                                          owned RowAction action) {
            var row = new MenuRow (label, icon);
            row.halign = Align.FILL;
            row.sensitive = sensitive;
            if (checked) {
                var box = row.get_child () as Box;
                if (box != null) {
                    box.halign = Align.FILL;
                    var spacer = new Box (Orientation.HORIZONTAL, 0);
                    spacer.hexpand = true;
                    box.append (spacer);
                    box.append (new Image.from_icon_name ("object-select-symbolic"));
                }
            }
            row.clicked.connect (() => {
                menu.popdown ();
                action ();
            });
            return row;
        }

        private void _show_more_menu () {
            if (_more_menu != null) {
                _more_menu.popdown ();
                return;
            }
            var menu = new ContextMenu (_more_btn);
            menu.set_position (PositionType.BOTTOM);
            bool first = true;
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                if (!item.overflowed) continue;
                switch (item.kind) {
                    case BubbleKind.BUTTON:
                        _add_button_row (menu, item.widget);
                        first = false;
                        break;
                    case BubbleKind.SWITCHER:
                        if (!first) menu.add_separator ();
                        _add_switcher_rows (menu, item.widget);
                        menu.add_separator ();
                        first = true;
                        break;
                    case BubbleKind.LABEL:
                        var info = new Label (((Label) item.widget).label);
                        info.halign = Align.START;
                        info.xalign = 0;
                        info.ellipsize = Pango.EllipsizeMode.END;
                        info.add_css_class ("dim-label");
                        info.margin_start = 12;
                        info.margin_end = 12;
                        info.margin_top = 6;
                        info.margin_bottom = 6;
                        menu.add_widget (info);
                        first = false;
                        break;
                    default:
                        break;
                }
            }
            Widget? last = menu.get_child ().get_last_child ();
            if (last is Separator) ((Box) menu.get_child ()).remove (last);
            _more_menu = menu;
            menu.closed.connect (() => {
                _more_menu = null;
                Idle.add (() => { menu.unparent (); return false; });
            });
            menu.popup ();
        }

        private static void _add_button_row (ContextMenu menu, Widget w) {
            string? icon = null;
            string? label = w.tooltip_text;
            bool checked = false;
            if (w is MenuButton) {
                var mb = (MenuButton) w;
                icon = mb.icon_name;
                if (label == null || label == "") label = mb.label;
                checked = mb.active;
            } else {
                var btn = (Button) w;
                var child = btn.get_child ();
                if (child is Image) icon = ((Image) child).icon_name;
                if (icon == null) icon = btn.icon_name;
                if (label == null || label == "") label = btn.label;
                if (label == null || label == "") label = _first_label (btn);
                if (btn is ToggleButton) checked = ((ToggleButton) btn).active;
                else checked = (btn.get_state_flags () & StateFlags.CHECKED) != 0;
            }
            if (label == null || label == "") label = icon ?? "";
            menu.add_widget (_menu_row (label, icon, checked, w.sensitive, menu, () => {
                if (w is MenuButton) ((MenuButton) w).popup ();
                else ((Button) w).clicked ();
            }));
        }

        private static string? _first_label (Widget w) {
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) {
                if (c is Label) return ((Label) c).label;
                string? inner = _first_label (c);
                if (inner != null) return inner;
            }
            return null;
        }

        // -- Layout ---------------------------------------------------------

        private bool _shown (BubbleItem item) {
            if (!item.widget.visible || item.widget.get_parent () != this) return false;
            return !_welcome || item.app_menu;
        }

        private static bool _pinned (BubbleItem item) {
            if (item.priority == Window.BUBBLE_PRIORITY_PINNED) return true;
            switch (item.kind) {
                case BubbleKind.SEARCH:
                case BubbleKind.OTHER:
                    return true;
                case BubbleKind.BUTTON:
                    return item.widget.has_css_class ("suggested-action")
                        || is_sidebar_toggle (item.widget);
                default:
                    return false;
            }
        }

        /** True for a bubble that toggles the window sidebar. */
        public static bool is_sidebar_toggle (Widget w) {
            string? icon = null;
            if (w is Button) {
                var child = ((Button) w).get_child ();
                if (child is Image) icon = ((Image) child).icon_name;
                if (icon == null) icon = ((Button) w).icon_name;
                string? action = ((Button) w).action_name;
                if (action != null && action.has_suffix ("toggle-sidebar")) return true;
            }
            return icon != null && icon.has_prefix ("sidebar-show");
        }

        public bool has_sidebar_toggle () {
            for (int i = 0; i < _items.length; i++) {
                if (_items[i].kind == BubbleKind.BUTTON && is_sidebar_toggle (_items[i].widget))
                    return true;
            }
            return false;
        }

        private static int _natural_width (Widget w) {
            int min, nat;
            w.measure (Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            return nat;
        }

        private static int _minimum_width (Widget w) {
            int min, nat;
            w.measure (Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            return min;
        }

        private void _collect_steps (GenericArray<BubbleItem> compacts,
                                     GenericArray<BubbleItem> overflows) {
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                if (_shown (item) && item.kind == BubbleKind.SEARCH) compacts.add (item);
            }
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                if (_shown (item) && item.kind == BubbleKind.SWITCHER) compacts.add (item);
            }
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                if (_shown (item) && !_pinned (item)) overflows.add (item);
            }
            overflows.sort ((a, b) => {
                if (a.priority != b.priority) return a.priority < b.priority ? -1 : 1;
                return b.order - a.order;
            });
        }

        private int _required (GenericArray<BubbleItem> compacts,
                               GenericArray<BubbleItem> overflows,
                               int level, int more_width) {
            int n_compact = int.min (level, compacts.length);
            int n_over = level - n_compact;
            int total = 0;
            int count = 0;
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                if (!_shown (item)) continue;
                if (_index_of (overflows, item) < n_over && _index_of (overflows, item) >= 0) continue;
                int idx = _index_of (compacts, item);
                bool compact = idx >= 0 && idx < n_compact;
                total += compact ? _natural_width (item.proxy) : _natural_width (item.widget);
                count++;
            }
            if (n_over > 0) {
                total += more_width;
                count++;
            }
            if (count > 1) total += SPACING * (count - 1);
            return total;
        }

        private static int _index_of (GenericArray<BubbleItem> list, BubbleItem item) {
            for (int i = 0; i < list.length; i++) {
                if (list[i] == item) return i;
            }
            return -1;
        }

        private bool _in_row (Widget c) {
            if (c == _search_close_btn) return false;
            if (c == _more_btn) return _level > 0;
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                if (item.widget == c) return _shown (item);
                if (item.proxy == c) return _shown (item) && _level > 0;
            }
            return true;
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            if (orientation == Orientation.VERTICAL) {
                minimum = 0;
                natural = 0;
                for (var c = get_first_child (); c != null; c = c.get_next_sibling ()) {
                    if (!c.visible) continue;
                    if (_expanded == null && !_in_row (c)) continue;
                    int cmin, cnat;
                    c.measure (Orientation.VERTICAL, -1, out cmin, out cnat, null, null);
                    minimum = int.max (minimum, cmin);
                    natural = int.max (natural, cnat);
                }
                return;
            }

            if (_expanded != null) {
                minimum = _natural_width (_search_close_btn) + SPACING;
                natural = _natural_width (_expanded) + SPACING + _natural_width (_search_close_btn);
                return;
            }

            var compacts = new GenericArray<BubbleItem> ();
            var overflows = new GenericArray<BubbleItem> ();
            _collect_steps (compacts, overflows);
            int more_width = _natural_width (_more_btn);
            natural = _required (compacts, overflows, 0, more_width);
            int max_level = compacts.length + overflows.length;
            int least = _required (compacts, overflows, max_level, more_width);
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                if (_shown (item) && item.kind == BubbleKind.OTHER)
                    least -= _natural_width (item.widget);
            }
            minimum = least.clamp (0, natural);
        }

        public override void size_allocate (int width, int height, int baseline) {
            if (_expanded != null) {
                _allocate_expanded (width, height);
                return;
            }
            _search_close_btn.set_child_visible (false);

            var compacts = new GenericArray<BubbleItem> ();
            var overflows = new GenericArray<BubbleItem> ();
            _collect_steps (compacts, overflows);
            int more_width = _natural_width (_more_btn);
            int max_level = compacts.length + overflows.length;

            int level = 0;
            while (level < max_level && _required (compacts, overflows, level, more_width) > width)
                level++;
            if (level > 0 && level < _level) {
                int relaxed = level;
                while (relaxed < int.min (_level, max_level)
                       && _required (compacts, overflows, relaxed, more_width) + HYSTERESIS > width)
                    relaxed++;
                level = relaxed;
            }
            if ((level == 0) != (_level == 0)) _queue_resize_later ();
            _level = level;

            int n_compact = int.min (level, compacts.length);
            int n_over = level - n_compact;
            bool any_over = n_over > 0;
            int used = 0;
            int count = 0;
            int others = 0;
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                int ci = _index_of (compacts, item);
                int oi = _index_of (overflows, item);
                item.compact = ci >= 0 && ci < n_compact;
                item.overflowed = oi >= 0 && oi < n_over;
                if (!_shown (item) || item.overflowed) continue;
                item.width = item.compact ? _natural_width (item.proxy) : _natural_width (item.widget);
                if (item.kind == BubbleKind.OTHER) others++;
                used += item.width;
                count++;
            }
            if (any_over) {
                used += more_width;
                count++;
            }
            if (count > 1) used += SPACING * (count - 1);
            if (used > width && others > 0) used = width + _shrink_others (used - width);

            bool rtl = get_direction () == TextDirection.RTL;
            int x = level > 0 && !pack_start ? int.max (0, width - used) : 0;
            x = _place_items (false, rtl, width, height, x);
            int more_x = x;
            if (any_over) x += more_width + SPACING;
            _place_items (true, rtl, width, height, x);

            _more_btn.set_child_visible (any_over);
            if (any_over) {
                x = more_x;
                _place (_more_btn, rtl, width, x, more_width, height);
                for (int i = 0; i < _items.length; i++) {
                    var item = _items[i];
                    if (!item.overflowed || !_shown (item)) continue;
                    if (item.kind == BubbleKind.BUTTON) {
                        item.widget.set_child_visible (true);
                        _park (item);
                        _place (item.widget, rtl, width, x, more_width, height);
                    } else {
                        item.widget.set_child_visible (false);
                    }
                }
            } else if (_more_menu != null) {
                _more_menu.popdown ();
            }
        }

        private int _place_items (bool trailing, bool rtl, int width, int height, int x) {
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                if (item.trailing != trailing) continue;
                bool shown = _shown (item);
                if (item.proxy != null) item.proxy.set_child_visible (shown && item.compact && !item.overflowed);
                if (!shown) {
                    item.widget.set_child_visible (false);
                    _unpark (item);
                    continue;
                }
                if (item.overflowed) continue;
                _unpark (item);
                Widget target = item.compact ? item.proxy : item.widget;
                item.widget.set_child_visible (!item.compact);
                _place (target, rtl, width, x, item.width, height);
                x += item.width + SPACING;
            }
            return x;
        }

        private int _shrink_others (int excess) {
            for (int pass = 0; pass < 2 && excess > 0; pass++) {
                for (int i = 0; i < _items.length && excess > 0; i++) {
                    var item = _items[i];
                    if (!_shown (item) || item.kind != BubbleKind.OTHER) continue;
                    int floor = pass == 0 ? int.min (_minimum_width (item.widget), item.width) : 0;
                    int cut = int.min (excess, item.width - floor);
                    item.width -= cut;
                    excess -= cut;
                }
            }
            return excess;
        }

        private void _allocate_expanded (int width, int height) {
            bool rtl = get_direction () == TextDirection.RTL;
            _more_btn.set_child_visible (false);
            for (int i = 0; i < _items.length; i++) {
                var item = _items[i];
                _unpark (item);
                if (item.proxy != null) item.proxy.set_child_visible (false);
                item.widget.set_child_visible (item.widget == _expanded);
            }
            int close_w = _natural_width (_search_close_btn);
            int search_w = int.max (0, width - close_w - SPACING);
            _place (_expanded, rtl, width, 0, search_w, height);
            _search_close_btn.set_child_visible (true);
            _place (_search_close_btn, rtl, width, search_w + SPACING, close_w, height);

            if (_expanded_width < 0) _expanded_width = width;
            if (!_search_fits_queued && width >= _expanded_width + HYSTERESIS) {
                var compacts = new GenericArray<BubbleItem> ();
                var overflows = new GenericArray<BubbleItem> ();
                _collect_steps (compacts, overflows);
                int normal = width - _expanded_overhead;
                int full = _required (compacts, overflows, 0, _natural_width (_more_btn));
                if (normal >= full + HYSTERESIS) {
                    _search_fits_queued = true;
                    Idle.add (() => {
                        _search_fits_queued = false;
                        search_fits ();
                        return false;
                    });
                }
            }
        }

        private static void _place (Widget w, bool rtl, int width, int x, int w_width, int height) {
            Graphene.Point origin = { rtl ? width - x - w_width : x, 0 };
            w.allocate (w_width, height, -1, new Gsk.Transform ().translate (origin));
        }

        private void _park (BubbleItem item) {
            if (item.parked) return;
            item.parked = true;
            item.saved_focusable = item.widget.focusable;
            item.widget.focusable = false;
            item.widget.can_target = false;
            Singularity.Motion.cancel (item.widget, "opacity");
            item.widget.opacity = 0.0;
        }

        private void _unpark (BubbleItem item) {
            if (!item.parked) return;
            item.parked = false;
            item.widget.focusable = item.saved_focusable;
            item.widget.can_target = true;
            Singularity.Motion.tween (item.widget, "opacity", 1.0, Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
        }

        private void _queue_resize_later () {
            if (_resize_queued) return;
            _resize_queued = true;
            Idle.add (() => {
                _resize_queued = false;
                queue_resize ();
                return false;
            });
        }
    }

    /**
     * Single-child container that lets the window shrink below the
     * content's minimum width. While there is room the child is laid out
     * exactly as before; below its minimum the child keeps that minimum
     * and is clipped instead of forcing the whole window wider.
     */
    internal class ContentBin : Widget {

        public const int FLOOR = 320;

        private Widget? _child = null;

        public Widget? child {
            get { return _child; }
            set {
                if (_child == value) return;
                if (_child != null) _child.unparent ();
                _child = value;
                if (_child != null) _child.set_parent (this);
                queue_resize ();
            }
        }

        public ContentBin () {
            Object ();
        }

        construct {
            hexpand = true;
            vexpand = true;
        }

        /** The child's own minimum width, ignoring the relief. */
        public int child_minimum_width () {
            if (_child == null || !_child.visible) return 0;
            int min, nat;
            _child.measure (Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            return min;
        }

        public override void dispose () {
            if (_child != null) {
                _child.unparent ();
                _child = null;
            }
            base.dispose ();
        }

        public override SizeRequestMode get_request_mode () {
            return _child != null ? _child.get_request_mode () : SizeRequestMode.CONSTANT_SIZE;
        }

        public override void compute_expand_internal (out bool hexpand_p, out bool vexpand_p) {
            hexpand_p = true;
            vexpand_p = true;
        }

        public override void measure (Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum = 0;
            natural = 0;
            minimum_baseline = -1;
            natural_baseline = -1;
            if (_child == null || !_child.visible) return;
            if (orientation == Orientation.HORIZONTAL) {
                _child.measure (orientation, for_size, out minimum, out natural,
                                out minimum_baseline, out natural_baseline);
                minimum = int.min (minimum, FLOOR);
                return;
            }
            int size = for_size;
            if (size >= 0) size = int.max (size, child_minimum_width ());
            _child.measure (orientation, size, out minimum, out natural,
                            out minimum_baseline, out natural_baseline);
        }

        public override void size_allocate (int width, int height, int baseline) {
            if (_child == null || !_child.visible) return;
            int min, nat;
            _child.measure (Orientation.HORIZONTAL, height, out min, out nat, null, null);
            int child_width = int.max (width, min);
            overflow = child_width > width ? Overflow.HIDDEN : Overflow.VISIBLE;
            _child.allocate (child_width, height, baseline, null);
        }
    }
}
