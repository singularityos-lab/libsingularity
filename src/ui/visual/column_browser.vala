using Gtk;

namespace Singularity.Widgets {

    /**
     * One pane in a ColumnBrowser. Owns its own scroll, list and
     * the in-pane empty-state slot. Apps populate `list_box` and
     * either call `set_empty()` (StatusPage replaces the scroll
     * entirely so nothing constrains it) or `set_filled()` to switch
     * back.
     *
     * The pane keeps its preferred width fixed; ColumnBrowser
     * arranges multiple panes horizontally.
     */
    public class ColumnBrowserPane : Box {

        public ListBox        list_box { get; private set; }
        public ScrolledWindow scroll   { get; private set; }

        private StatusPage? _empty = null;

        public ColumnBrowserPane (int width = 240) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("singularity-column-pane");
            set_size_request (width, -1);
            hexpand = false;
            vexpand = true;

            scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            scroll.hexpand = false;
            scroll.vexpand = true;

            list_box = new ListBox ();
            list_box.add_css_class ("singularity-column-list");
            list_box.selection_mode = SelectionMode.SINGLE;
            scroll.set_child (list_box);
            append (scroll);
        }

        /**
         * Replace the list scroll with a StatusPage filling the pane.
         * The scroll is detached entirely (not hidden) so its
         * allocation can no longer constrain the placeholder.
         */
        public void set_empty (string icon_name, string title, string description) {
            if (scroll.parent == this) remove (scroll);
            if (_empty != null && _empty.parent == this) remove (_empty);
            _empty = new StatusPage ();
            _empty.icon_name   = icon_name;
            _empty.title       = title;
            _empty.description = description;
            _empty.add_css_class ("singularity-column-pane-empty");
            _empty.hexpand = true;
            _empty.vexpand = true;
            _empty.halign  = Align.FILL;
            _empty.valign  = Align.FILL;
            append (_empty);
        }

        /** Restore the list scroll, removing any active empty state. */
        public void set_filled () {
            if (_empty != null && _empty.parent == this) {
                remove (_empty);
                _empty = null;
            }
            if (scroll.parent != this) append (scroll);
        }
    }

    /**
     * Horizontal multi-pane browser (Files column mode). Owns the
     * outer scroll, the pane container, the per-pane separators and
     * the view-edge reserve. Apps push/pop panes and populate each
     * pane's `list_box`.
     */
    public class ColumnBrowser : Box {

        public signal void pane_added   (int idx, ColumnBrowserPane pane);
        public signal void pane_removed (int idx);

        private ScrolledWindow _scroll;
        private Box            _panes_box;
        private ColumnBrowserPane[] _panes = {};
        private Separator?[]        _seps  = {};

        public int pane_count { get { return _panes.length; } }

        construct {
            orientation = Orientation.VERTICAL;
            spacing = 0;
            add_css_class ("singularity-column-browser");
            Singularity.Widgets.apply_view_edge (this);
            hexpand = true;
            vexpand = true;

            _scroll = new ScrolledWindow ();
            _scroll.hscrollbar_policy = PolicyType.AUTOMATIC;
            _scroll.vscrollbar_policy = PolicyType.NEVER;
            _scroll.vexpand = true;

            _panes_box = new Box (Orientation.HORIZONTAL, 0);
            _panes_box.add_css_class ("singularity-column-browser-strip");
            _panes_box.hexpand = true;
            _panes_box.vexpand = true;
            _scroll.set_child (_panes_box);
            append (_scroll);
        }

        /** Append a new pane to the right of the existing ones. */
        public ColumnBrowserPane push_pane (int width = 240) {
            var pane = new ColumnBrowserPane (width);
            Separator? sep = null;
            if (_panes.length > 0) {
                sep = new Separator (Orientation.VERTICAL);
                sep.add_css_class ("singularity-column-browser-sep");
                _panes_box.append (sep);
            }
            _panes_box.append (pane);
            _panes += pane;
            _seps  += sep;
            int idx = _panes.length - 1;
            pane_added (idx, pane);
            return pane;
        }

        /** Remove every pane after (and not including) `index`. */
        public void pop_to (int index) {
            if (index < 0) index = -1;
            while (_panes.length > index + 1) {
                int last = _panes.length - 1;
                var pane = _panes[last];
                if (_seps[last] != null) _panes_box.remove (_seps[last]);
                _panes_box.remove (pane);
                _panes.resize (last);
                _seps.resize  (last);
                pane_removed (last);
            }
        }

        /** Pane at the given index, or null when out of range. */
        public ColumnBrowserPane? get_pane (int idx) {
            if (idx < 0 || idx >= _panes.length) return null;
            return _panes[idx];
        }

        /** Remove every pane. */
        public void clear () {
            pop_to (-1);
        }

        /**
         * Sliding viewport: hide every pane outside [start, start+size).
         * Pass -1 for size to show all panes from start onward. Inter-pane
         * separators are auto-adjusted so the leading visible pane never
         * carries a separator on its left.
         */
        public void set_viewport (int start, int size) {
            int end = (size < 0) ? _panes.length : int.min (start + size, _panes.length);
            bool prev_visible = false;
            for (int i = 0; i < _panes.length; i++) {
                bool visible = (i >= start && i < end);
                _panes[i].visible = visible;
                if (i < _seps.length && _seps[i] != null) {
                    _seps[i].visible = visible && prev_visible;
                }
                prev_visible = visible;
            }
        }

        /**
         * Horizontal adjustment of the outer scroll, exposed so apps
         * can scroll-to-end after pushing a pane.
         */
        public Gtk.Adjustment hadjustment {
            get { return _scroll.get_hadjustment (); }
        }
    }
}
