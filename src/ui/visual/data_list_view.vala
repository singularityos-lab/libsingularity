using Gtk;

namespace Singularity.Widgets {

    /**
     * A scrollable columnar list view. Bakes the libsingularity
     * defaults (singularity-view-edge wrapper, singularity-data-view
     * styling on the ColumnView, no column separators, row separators
     * on, both axes expanded) so apps stop assembling
     * ScrolledWindow + ColumnView by hand.
     *
     * The host fills the view with columns and a SelectionModel; data
     * + behaviour (row activation, context menus, drag/drop) stay in
     * the app, the chrome lives here.
     *
     * Public sub-widgets `scroll` and `column_view` are exposed so the
     * host can attach gesture controllers, configure sort behaviour,
     * etc. without bloating this widget's API.
     */
    public class DataListView : Box {

        public ScrolledWindow scroll      { get; private set; }
        public ColumnView     column_view { get; private set; }

        /** Forwarded from ColumnView.activate. */
        public signal void row_activated (uint position);

        /** Right-click on the empty area of the scroll surface. */
        public signal void background_right_clicked (double x, double y);

        construct {
            orientation = Orientation.VERTICAL;
            spacing = 0;
            hexpand = true;
            vexpand = true;

            scroll = new ScrolledWindow ();
            scroll.hexpand = true;
            scroll.vexpand = true;
            Singularity.Widgets.apply_view_edge (scroll);

            column_view = new ColumnView (null);
            column_view.add_css_class ("singularity-data-view");
            column_view.show_column_separators = false;
            column_view.show_row_separators    = true;
            column_view.hexpand = true;
            column_view.vexpand = true;
            column_view.activate.connect ((pos) => row_activated (pos));

            scroll.set_child (column_view);
            append (scroll);

            var bg = new Gtk.GestureClick ();
            bg.button = 3;
            bg.pressed.connect ((n, x, y) => background_right_clicked (x, y));
            scroll.add_controller (bg);
        }

        /** Install the SelectionModel that drives the view. */
        public void set_selection_model (Gtk.SelectionModel model) {
            column_view.model = model;
        }

        /** Append a column built from a Gtk.ListItemFactory. */
        public ColumnViewColumn add_column (string title, ListItemFactory factory) {
            var col = new ColumnViewColumn (title, factory);
            column_view.append_column (col);
            return col;
        }
    }

    /**
     * Variant of DataListView for flat lists that render group +
     * member rows with an inline expander (Monitor's process panel
     * pattern, where the model exposes both ProcessGroup and
     * ProcessInfo items in a single ListModel and toggles expansion
     * via the model itself).
     *
     * Adds:
     *   - `.singularity-grouped-data-view` class for CSS hooks on
     *     group rows.
     *   - `make_expander_image()` helper so apps stop hand-rolling
     *     the inline expander widget.
     *   - `group_toggle_requested` signal apps can wire to their
     *     model's toggle method.
     */
    public class GroupedDataListView : DataListView {

        /** Emitted when the row factory should toggle a group's expand state. */
        public signal void group_toggle_requested (GLib.Object group_item);

        construct {
            column_view.add_css_class ("singularity-grouped-data-view");
        }

        /**
         * Build the standard inline expander image used at the start
         * of a group row. Hidden by default; the bind step of the
         * factory should toggle visibility and swap the icon for
         * expanded (go-down) / collapsed (go-next) state.
         */
        public static Image make_expander_image () {
            var img = new Image ();
            img.pixel_size = 12;
            img.visible = false;
            return img;
        }

        /** Apps call this from their row click handler when the click
         *  lands on a group row, instead of calling model.toggle_group
         *  directly, so the view stays the single owner of the signal. */
        public void emit_group_toggle (GLib.Object group_item) {
            group_toggle_requested (group_item);
        }
    }
}
