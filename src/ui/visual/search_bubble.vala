using Gtk;

namespace Singularity.Widgets {

    /**
     * A search input shaped like a bubble. Use via
     * `window.add_bubble_search()` rather than instantiating directly,
     * so the styling pulls automatically from the bubble bar.
     *
     * Emits `search_changed` whenever the entry text changes.
     */
    public class SearchBubble : Box {

        public signal void search_changed (string text);

        private Singularity.Widgets.SearchEntry _entry;

        public string text {
            get { return _entry.text; }
            set { _entry.text = value; }
        }

        public string placeholder {
            owned get { return _entry.placeholder_text; }
            set { _entry.placeholder_text = value; }
        }

        public Gtk.SearchEntry entry { get { return _entry.entry; } }

        public SearchBubble (string? placeholder = null) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0);
            add_css_class ("singularity-search-bubble");

            _entry = new Singularity.Widgets.SearchEntry ();
            _entry.placeholder_text = placeholder ?? _("Search…");
            _entry.entry.width_chars = 20;
            _entry.entry.max_width_chars = 24;
            _entry.hexpand = false;
            _entry.entry.hexpand = false;
            hexpand = false;
            halign = Align.END;
            _entry.entry.add_css_class ("flat");
            // Match the path-bubble pattern: kill the entry's own chrome
            // so the SURROUNDING bubble (from .singularity-hover-btn) is
            // what carries border / radius / bg.
            _entry.entry.remove_css_class ("text-button");
            _entry.search_changed.connect (() => search_changed (_entry.text));
            _entry.entry.stop_search.connect (() => clear ());

            append (_entry);
        }

        public void grab_focus_entry () { _entry.grab_focus (); }
        public void clear () { _entry.text = ""; }

        internal void set_expanded (bool expanded) {
            halign = expanded ? Align.FILL : Align.END;
            _entry.hexpand = expanded;
            _entry.entry.hexpand = expanded;
            _entry.entry.max_width_chars = expanded ? -1 : 24;
        }
    }
}
