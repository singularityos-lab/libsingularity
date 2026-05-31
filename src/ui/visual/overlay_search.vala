using Gtk;
using GLib;

namespace Singularity.Widgets {

    /**
     * A single entry to feed an OverlaySearch.
     *
     * Apps build a list of these and hand them to `set_items()`; the widget
     * renders them, filters by the entry text, and emits `item_activated`
     * with the entry id when the user picks one.
     */
    public class OverlaySearchItem : Object {
        public string  id;
        public string  icon_name;
        public string  title;
        public string? subtitle;
        public string? hotkey;
        public string? category;

        public OverlaySearchItem(string id,
                                 string icon_name,
                                 string title,
                                 string? subtitle = null,
                                 string? hotkey   = null,
                                 string? category = null) {
            this.id        = id;
            this.icon_name = icon_name;
            this.title     = title;
            this.subtitle  = subtitle;
            this.hotkey    = hotkey;
            this.category  = category;
        }
    }

    /**
     * Shared floating search card used by command palettes, address bars,
     * and any other "press a key to focus a query box" interaction.
     *
     * Visual: pill-shaped card centered horizontally, top-anchored to the
     * content overlay (margin_top configurable). Inside: a SearchEntry plus
     * an optional ListBox of results. Esc closes, Up/Down navigate, Enter
     * activates the selected row (or emits `entry_activated` with the raw
     * query when no list rows are shown).
     *
     * Wiring:
     *   - For static result sets feed once with `set_items`, the widget
     *     filters internally on `title` + `subtitle` substring match.
     *   - For dynamic/async result sets (browser bookmarks, fuzzy fetch)
     *     set `internal_filter = false` and listen to `query_changed`,
     *     then call `set_items` again with the new candidates.
     *   - For pure text inputs (photo search, find bar) set
     *     `show_list = false`; the widget collapses to just the entry.
     */
    public class OverlaySearch : Box {

        public signal void close_requested();
        public signal void query_changed(string query);
        public signal void item_activated(string id);
        public signal void entry_activated(string query);

        private Singularity.Widgets.SearchEntry _entry;
        private ListBox     _list;
        private ScrolledWindow _scroll;
        private Stack       _stack;
        private Label       _empty_lbl;
        private Box         _card;

        private GenericArray<OverlaySearchItem> _all;
        private GenericArray<OverlaySearchItem> _shown;

        private string _placeholder      = "Search...";
        private int    _top_offset       = 80;
        private bool   _show_list        = true;
        private bool   _internal_filter  = true;
        private string _empty_text       = "No results";

        public string placeholder {
            get { return _placeholder; }
            set {
                _placeholder = value;
                _entry.placeholder_text = value;
            }
        }

        public int top_offset {
            get { return _top_offset; }
            set {
                _top_offset = value;
                margin_top  = value;
            }
        }

        public bool show_list {
            get { return _show_list; }
            set {
                _show_list = value;
                _stack.visible = value;
            }
        }

        public bool internal_filter {
            get { return _internal_filter; }
            set { _internal_filter = value; refresh(); }
        }

        public string empty_text {
            get { return _empty_text; }
            set { _empty_text = value; _empty_lbl.label = value; }
        }

        /** Raw text in the entry. */
        public string text {
            get { return _entry.text; }
        }

        public OverlaySearch() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("singularity-overlay-search");
            halign     = Align.CENTER;
            valign     = Align.START;
            margin_top = _top_offset;
            visible    = false;

            _all   = new GenericArray<OverlaySearchItem>();
            _shown = new GenericArray<OverlaySearchItem>();

            _card = new Box(Orientation.VERTICAL, 0);
            _card.add_css_class("singularity-overlay-search-card");

            _entry = new Singularity.Widgets.SearchEntry();
            _entry.add_css_class("singularity-overlay-search-entry");
            _entry.placeholder_text = _placeholder;
            _entry.hexpand = true;
            _entry.search_changed.connect(on_search_changed);
            _entry.entry.activate.connect(on_entry_activate);

            var entry_key = new EventControllerKey();
            entry_key.key_pressed.connect(on_entry_key);
            _entry.entry.add_controller(entry_key);

            _list = new ListBox();
            _list.add_css_class("singularity-overlay-search-list");
            _list.selection_mode = SelectionMode.SINGLE;
            _list.row_activated.connect((_r) => activate_selected());

            _scroll = new ScrolledWindow();
            _scroll.hscrollbar_policy = PolicyType.NEVER;
            _scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            _scroll.set_child(_list);
            _scroll.height_request = 320;

            _empty_lbl = new Label(_empty_text);
            _empty_lbl.add_css_class("dim-label");
            _empty_lbl.margin_top    = 24;
            _empty_lbl.margin_bottom = 24;

            _stack = new Stack();
            _stack.transition_type     = StackTransitionType.CROSSFADE;
            _stack.transition_duration = 100;
            _stack.add_named(_scroll, "list");
            _stack.add_named(_empty_lbl, "empty");

            _card.append(_entry);
            _card.append(_stack);
            append(_card);

            var esc = new EventControllerKey();
            esc.key_pressed.connect((kv, _c, _s) => {
                if (kv == Gdk.Key.Escape) { close_requested(); return true; }
                return false;
            });
            ((Gtk.Widget)this).add_controller(esc);
        }

        public void open(string? prefill = null) {
            visible = true;
            if (prefill != null) _entry.text = prefill;
            refresh();
            _entry.grab_focus();
            _entry.entry.select_region(0, -1);
        }

        public void close() { visible = false; }

        public void set_items(OverlaySearchItem[] items) {
            _all.remove_range(0, _all.length);
            foreach (var it in items) _all.add(it);
            refresh();
        }

        public void clear_items() {
            _all.remove_range(0, _all.length);
            refresh();
        }

        public void clear_text() { _entry.text = ""; }

        private void on_search_changed() {
            query_changed(_entry.text);
            if (_internal_filter) refresh();
        }

        private void on_entry_activate() {
            if (_show_list && _shown.length > 0) {
                activate_selected();
            } else {
                entry_activated(_entry.text);
            }
        }

        private bool on_entry_key(uint keyval, uint kc, Gdk.ModifierType state) {
            switch (keyval) {
                case Gdk.Key.Escape:    close_requested(); return true;
                case Gdk.Key.Down:      move_selection(1);  return true;
                case Gdk.Key.Up:        move_selection(-1); return true;
                case Gdk.Key.Page_Down: move_selection(8);  return true;
                case Gdk.Key.Page_Up:   move_selection(-8); return true;
                default: return false;
            }
        }

        private void move_selection(int delta) {
            var current = _list.get_selected_row();
            int idx = (current != null) ? current.get_index() : -1;
            int target = idx + delta;
            if (target < 0) target = 0;
            ListBoxRow? row = _list.get_row_at_index(target);
            if (row == null) {
                int last = 0;
                while (_list.get_row_at_index(last + 1) != null) last++;
                row = _list.get_row_at_index(last);
            }
            if (row != null) _list.select_row(row);
        }

        private void refresh() {
            _shown.remove_range(0, _shown.length);
            string q = _entry.text.strip().down();
            for (int i = 0; i < _all.length; i++) {
                var it = _all[i];
                if (!_internal_filter || q.length == 0 || matches(it, q)) {
                    _shown.add(it);
                }
            }
            render_list();
        }

        private bool matches(OverlaySearchItem it, string q) {
            if (it.title.down().contains(q)) return true;
            if (it.subtitle != null && it.subtitle.down().contains(q)) return true;
            return false;
        }

        private void render_list() {
            ListBoxRow? row = _list.get_first_child() as ListBoxRow;
            while (row != null) {
                var next = row.get_next_sibling() as ListBoxRow;
                _list.remove(row);
                row = next;
            }
            if (!_show_list) { _stack.visible = false; return; }
            _stack.visible = true;
            if (_shown.length == 0) {
                _stack.visible_child_name = "empty";
                return;
            }
            for (int i = 0; i < _shown.length; i++) {
                var it = _shown[i];
                var rbox = new Box(Orientation.HORIZONTAL, 10);
                rbox.margin_start  = 12;
                rbox.margin_end    = 12;
                rbox.margin_top    = 8;
                rbox.margin_bottom = 8;

                var icon = new Image.from_icon_name(it.icon_name);
                icon.pixel_size = 16;
                rbox.append(icon);

                var tbox = new Box(Orientation.VERTICAL, 1);
                tbox.hexpand = true;
                var title = new Label(it.title);
                title.xalign = 0;
                title.ellipsize = Pango.EllipsizeMode.END;
                tbox.append(title);
                if (it.subtitle != null && it.subtitle != "") {
                    var sub = new Label(it.subtitle);
                    sub.xalign = 0;
                    sub.ellipsize = Pango.EllipsizeMode.END;
                    sub.add_css_class("dim-label");
                    sub.add_css_class("caption");
                    tbox.append(sub);
                }
                rbox.append(tbox);

                if (it.hotkey != null && it.hotkey != "") {
                    var hk = new Label(it.hotkey);
                    hk.add_css_class("dim-label");
                    hk.add_css_class("caption");
                    rbox.append(hk);
                }

                var lr = new ListBoxRow();
                lr.set_child(rbox);
                lr.set_data<int>("item-index", i);
                _list.append(lr);
            }
            _stack.visible_child_name = "list";
            var first = _list.get_row_at_index(0);
            if (first != null) _list.select_row(first);
        }

        private void activate_selected() {
            var row = _list.get_selected_row();
            if (row == null) row = _list.get_row_at_index(0);
            if (row == null) return;
            int i = row.get_data<int>("item-index");
            if (i < 0 || i >= _shown.length) return;
            item_activated(_shown[i].id);
        }
    }
}
