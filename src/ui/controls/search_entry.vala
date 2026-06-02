using Gtk;

namespace Singularity.Widgets {

    /**
     * The Singularity search-entry primitive. Wraps a Gtk.SearchEntry
     * and shifts the inner GtkText right by 10% so the placeholder /
     * text isn't glued to the search icon. Every Singularity app
     * uses this in place of Gtk.SearchEntry for a uniform visual.
     *
     * GtkSearchEntry can't be subclassed (its class struct is not
     * public), so this widget is a Box composition with proxied
     * `text`, `placeholder_text`, the underlying `entry`, and a
     * forwarded `search_changed` signal.
     */
    public class SearchEntry : Box {

        /** The underlying Gtk.SearchEntry - exposed for callers that
         *  need direct access (e.g. focus chain, gesture controllers). */
        public Gtk.SearchEntry entry { get; private set; }

        public string text {
            get { return entry.text; }
            set { entry.text = value; }
        }

        public string? placeholder_text {
            owned get { return entry.placeholder_text; }
            set { entry.placeholder_text = value; }
        }

        /** Forwarded from Gtk.SearchEntry.search_changed. */
        public signal void search_changed ();

        construct {
            orientation = Orientation.HORIZONTAL;
            spacing = 0;

            entry = new Gtk.SearchEntry ();
            entry.hexpand = true;
            entry.search_changed.connect (() => search_changed ());
            append (entry);

            _apply_xalign ();
            entry.realize.connect (_apply_xalign);
        }

        public override bool grab_focus () {
            return entry.grab_focus ();
        }

        private bool _menu_attached = false;

        private void _setup_text (Gtk.Text text) {
            text.xalign = 0.10f;
            if (!_menu_attached) {
                _menu_attached = true;
                ContextMenu.attach_editable (text);
            }
        }

        private void _apply_xalign () {
            Widget? child = entry.get_first_child ();
            while (child != null) {
                if (child is Gtk.Text) {
                    _setup_text ((Gtk.Text) child);
                    return;
                }
                Widget? grand = child.get_first_child ();
                while (grand != null) {
                    if (grand is Gtk.Text) {
                        _setup_text ((Gtk.Text) grand);
                        return;
                    }
                    grand = grand.get_next_sibling ();
                }
                child = child.get_next_sibling ();
            }
        }
    }
}
