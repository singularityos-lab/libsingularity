using Gtk;

namespace Singularity.Widgets {

    /**
     * A scrollable card grid. Bakes in the libsingularity defaults
     * (ScrolledWindow, GridView with sane min/max column bounds,
     * `singularity-data-grid` class for CSS hooks) so apps stop
     * assembling ScrolledWindow + GridView by hand.
     *
     * Unlike DataListView the grid does NOT carry the
     * singularity-view-edge reserve: cards scroll under the bubble
     * bar by design. CSS gives `.singularity-data-grid` a 60px
     * padding-top in CSD so the first row isn't covered.
     *
     * Public sub-widgets `scroll` and `grid_view` are exposed so the
     * host can attach gestures, configure factory and selection,
     * etc.
     */
    public class DataGridView : Box {

        public ScrolledWindow scroll    { get; private set; }
        public GridView       grid_view { get; private set; }

        /** Forwarded from GridView.activate. */
        public signal void item_activated (uint position);

        /** Right-click on the empty area of the scroll surface. */
        public signal void background_right_clicked (double x, double y);

        public int min_columns {
            get { return (int) grid_view.min_columns; }
            set { grid_view.min_columns = value; }
        }

        public int max_columns {
            get { return (int) grid_view.max_columns; }
            set { grid_view.max_columns = value; }
        }

        construct {
            orientation = Orientation.VERTICAL;
            spacing = 0;
            hexpand = true;
            vexpand = true;

            scroll = new ScrolledWindow ();
            scroll.hexpand = true;
            scroll.vexpand = true;

            grid_view = new GridView (null, null);
            grid_view.add_css_class ("singularity-data-grid");
            grid_view.max_columns = 8;
            grid_view.min_columns = 2;
            grid_view.hexpand = true;
            grid_view.vexpand = true;
            grid_view.activate.connect ((pos) => item_activated (pos));

            scroll.set_child (grid_view);
            append (scroll);

            var bg = new Gtk.GestureClick ();
            bg.button = 3;
            bg.pressed.connect ((n, x, y) => background_right_clicked (x, y));
            scroll.add_controller (bg);
        }

        public void set_selection_model (Gtk.SelectionModel model) {
            grid_view.model = model;
        }

        public void set_factory (Gtk.ListItemFactory factory) {
            grid_view.factory = factory;
        }
    }
}
