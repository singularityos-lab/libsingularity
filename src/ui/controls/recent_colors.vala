using Gtk;

namespace Singularity {
    public class RecentColors : Object {
        public static string path() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "colorpicker", "history.json");
        }

        public static string[] list(int max = 10) {
            string[] result = {};
            if (!FileUtils.test(path(), FileTest.EXISTS)) return result;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path());
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return result;
                foreach (var node in root.get_array().get_elements()) {
                    if (result.length >= max) break;
                    if (node.get_value_type() != typeof(string)) continue;
                    var rgba = Gdk.RGBA();
                    string hex = node.get_string();
                    if (rgba.parse(hex)) result += hex.length > 7 ? hex.substring(0, 7) : hex;
                }
            } catch (Error e) {
                warning("RecentColors: %s", e.message);
            }
            return result;
        }
    }
}

namespace Singularity.Widgets {
    public class RecentColorsRow : Box {
        public signal void picked(string hex);

        public RecentColorsRow(int max = 10) {
            Object(orientation: Orientation.VERTICAL, spacing: 4);
            add_css_class("recent-colors");
            string[] colors = RecentColors.list(max);
            visible = colors.length > 0;
            var title = new Label(_("From Color Picker"));
            title.add_css_class("caption");
            title.add_css_class("dim-label");
            title.xalign = 0;
            append(title);
            var row = new Box(Orientation.HORIZONTAL, 4);
            foreach (string hex in colors) {
                string c = hex;
                var b = new Button();
                b.add_css_class("flat");
                b.add_css_class("recent-color-swatch");
                b.tooltip_text = c;
                b.update_property(AccessibleProperty.LABEL, c, -1);
                var dot = new DrawingArea();
                dot.set_size_request(20, 20);
                dot.set_draw_func((a, cr, w, h) => {
                    var rgba = Gdk.RGBA();
                    rgba.parse(c);
                    cr.arc(w / 2.0, h / 2.0, w / 2.0 - 1, 0, 2 * Math.PI);
                    cr.set_source_rgba(rgba.red, rgba.green, rgba.blue, 1);
                    cr.fill_preserve();
                    var fg = a.get_color();
                    cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.25);
                    cr.set_line_width(1);
                    cr.stroke();
                });
                b.child = dot;
                b.clicked.connect(() => picked(c));
                row.append(b);
            }
            append(row);
        }
    }
}
