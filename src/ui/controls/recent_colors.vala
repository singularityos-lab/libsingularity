using Gtk;

namespace Singularity.Widgets {
    public class RecentColorsRow : Box {
        public signal void picked(string hex);

        private Box swatches;

        public RecentColorsRow(int max = 10) {
            Object(orientation: Orientation.VERTICAL, spacing: 4);
            add_css_class("recent-colors");
            visible = false;
            var title = new Label(_("From Color Picker"));
            title.add_css_class("caption");
            title.add_css_class("dim-label");
            title.xalign = 0;
            append(title);
            swatches = new Box(Orientation.HORIZONTAL, 4);
            append(swatches);
            if (!Capabilities.available(Contracts.COLORS)) return;
            Capabilities.call.begin(Contracts.COLORS, "RecentColors", new Variant("(i)", max), new VariantType("(as)"), 5000, (obj, res) => {
                try {
                    fill(Capabilities.call.end(res).get_child_value(0).get_strv());
                } catch (Error e) {
                    debug("Recent colors: %s", e.message);
                }
            });
        }

        private void fill(string[] colors) {
            foreach (string hex in colors) {
                var rgba = Gdk.RGBA();
                if (!rgba.parse(hex)) continue;
                string c = hex.length > 7 ? hex.substring(0, 7) : hex;
                var b = new Button();
                b.add_css_class("flat");
                b.add_css_class("recent-color-swatch");
                b.tooltip_text = c;
                b.update_property(AccessibleProperty.LABEL, c, -1);
                var dot = new DrawingArea();
                dot.set_size_request(20, 20);
                dot.set_draw_func((a, cr, w, h) => {
                    var color = Gdk.RGBA();
                    color.parse(c);
                    cr.arc(w / 2.0, h / 2.0, w / 2.0 - 1, 0, 2 * Math.PI);
                    cr.set_source_rgba(color.red, color.green, color.blue, 1);
                    cr.fill_preserve();
                    var fg = a.get_color();
                    cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.25);
                    cr.set_line_width(1);
                    cr.stroke();
                });
                b.child = dot;
                b.clicked.connect(() => picked(c));
                swatches.append(b);
            }
            visible = swatches.get_first_child() != null;
        }
    }
}
