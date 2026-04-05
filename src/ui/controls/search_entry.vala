using Gtk;

namespace Singularity.Widgets {

    /**
     * A styled search-entry widget that wraps Gtk.SearchEntry.
     *
     * Emits `search_changed` on every keystroke so callers can filter their data
     * in real time. Gain input focus programmatically via the overridden `grab_focus()`.
     */
    public class SearchEntry : Box {
        private Gtk.SearchEntry entry;

        /** The current text in the search field. */
        public string text {
            get { return entry.text; }
            set { entry.text = value; }
        }

        public string? placeholder_text {
            owned get { return entry.placeholder_text; }
            set { entry.placeholder_text = value; }
        }

        /** Emitted when the text in the entry changes. */
        public signal void search_changed(SearchEntry sender);

        public SearchEntry() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);

            entry = new Gtk.SearchEntry();
            entry.hexpand = true;
            entry.add_css_class("search-entry");
            entry.add_css_class("singularity-search");

            entry.search_changed.connect(() => {
                search_changed(this);
            });

            append(entry);
        }

        public override bool grab_focus() {
            return entry.grab_focus();
        }
    }
}
