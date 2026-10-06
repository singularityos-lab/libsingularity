using Gtk;

namespace Singularity.Widgets {

    public class ToolPalette : Box {
        public signal void tool_selected (string id);

        private Grid grid;
        private Box footer;
        private Gee.ArrayList<Widget> items = new Gee.ArrayList<Widget> ();
        private Gee.HashMap<string, ToggleButton> buttons = new Gee.HashMap<string, ToggleButton> ();
        private int columns = 1;
        private string active = "";

        public ToolPalette () {
            Object (orientation: Orientation.VERTICAL, spacing: 4);
            add_css_class ("sx-tool-palette");
            halign = Align.START;
            valign = Align.CENTER;
            grid = new Grid ();
            grid.row_spacing = 2;
            grid.column_spacing = 2;
            append (grid);
            footer = new Box (Orientation.VERTICAL, 4);
            footer.visible = false;
            var sep = new Box (Orientation.HORIZONTAL, 0);
            sep.add_css_class ("sx-tool-separator");
            footer.append (sep);
            append (footer);
        }

        public void inset (int edge) {
            margin_start = edge + 10;
            margin_top = 10;
            margin_bottom = edge + 10;
        }

        private ToggleButton make_button (string icon_name, string tooltip) {
            var b = new ToggleButton ();
            b.icon_name = icon_name;
            b.tooltip_text = tooltip;
            b.add_css_class ("flat");
            b.add_css_class ("sx-tool");
            b.update_property (AccessibleProperty.LABEL, tooltip, -1);
            return b;
        }

        public ToggleButton add_tool (string icon_name, string tooltip) {
            var b = make_button (icon_name, tooltip);
            items.add (b);
            relayout ();
            return b;
        }

        public ToggleButton add_tool_id (string id, string icon_name, string label) {
            var b = make_button (icon_name, label);
            b.toggled.connect (() => {
                if (b.active && active != id) {
                    active = id;
                    sync ();
                    tool_selected (id);
                } else if (!b.active && active == id) {
                    b.active = true;
                }
            });
            buttons[id] = b;
            items.add (b);
            relayout ();
            return b;
        }

        public void add_separator () {
            var sep = new Box (Orientation.HORIZONTAL, 0);
            sep.add_css_class ("sx-tool-separator");
            items.add (sep);
            relayout ();
        }

        public void set_tooltip (string id, string tooltip, string label) {
            if (!buttons.has_key (id)) return;
            buttons[id].tooltip_text = tooltip;
            buttons[id].update_property (AccessibleProperty.LABEL, label, -1);
        }

        public void set_active (string id) {
            if (active == id) return;
            active = id;
            sync ();
        }

        private void sync () {
            foreach (var e in buttons.entries) {
                bool on = e.key == active;
                if (e.value.active != on) e.value.active = on;
            }
        }

        public void append_footer (Widget w) {
            footer.append (w);
            footer.visible = true;
        }

        public void set_columns (int n) {
            if (n == columns || n < 1) return;
            columns = n;
            relayout ();
        }

        public int rows_for (int n) {
            int count = 0;
            foreach (var w in items) if (w is ToggleButton) count++;
            return (count + n - 1) / n;
        }

        private void relayout () {
            foreach (var w in items) if (w.get_parent () == grid) grid.remove (w);
            int row = 0, col = 0;
            foreach (var w in items) {
                if (w is ToggleButton) {
                    grid.attach (w, col, row, 1, 1);
                    col++;
                    if (col >= columns) {
                        col = 0;
                        row++;
                    }
                } else {
                    if (col != 0) row++;
                    grid.attach (w, 0, row, columns, 1);
                    row++;
                    col = 0;
                }
            }
        }
    }
}
