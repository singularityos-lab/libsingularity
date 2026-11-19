namespace Singularity.Style {

    public class IconColor {
        private const int SIZE = 32;

        private static HashTable<string, string>? _cache = null;
        private static Gsk.Renderer? _renderer = null;

        public static bool sample(GLib.Icon icon, out Gdk.RGBA color) {
            color = Gdk.RGBA() { red = 0.5f, green = 0.5f, blue = 0.5f, alpha = 1 };
            if (_cache == null) _cache = new HashTable<string, string>(str_hash, str_equal);
            string? key = icon.to_string();
            if (key != null) {
                string? known = _cache.lookup(key);
                if (known != null) return known != "" && color.parse(known);
            }
            string hex = compute(icon) ?? "";
            if (key != null) _cache.insert(key, hex);
            return hex != "" && color.parse(hex);
        }

        private static string? compute(GLib.Icon icon) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var paintable = Gtk.IconTheme.get_for_display(display).lookup_by_gicon(icon, SIZE, 1, Gtk.TextDirection.NONE, 0);
            var snapshot = new Gtk.Snapshot();
            paintable.snapshot(snapshot, SIZE, SIZE);
            var node = snapshot.to_node();
            if (node == null) return null;
            if (_renderer == null) {
                var renderer = new Gsk.CairoRenderer();
                try {
                    renderer.realize_for_display(display);
                } catch (Error e) {
                    return null;
                }
                _renderer = renderer;
            }
            var texture = _renderer.render_texture(node, Graphene.Rect().init(0, 0, SIZE, SIZE));
            var pixels = new uint8[SIZE * SIZE * 4];
            texture.download(pixels, SIZE * 4);
            return average(pixels);
        }

        private static string? average(uint8[] px) {
            double vivid_w = 0, vivid_r = 0, vivid_g = 0, vivid_b = 0;
            double all_w = 0, all_r = 0, all_g = 0, all_b = 0;
            for (int i = 0; i + 3 < px.length; i += 4) {
                double a = px[i + 3] / 255.0;
                if (a < 0.5) continue;
                double b = px[i] / 255.0 / a;
                double g = px[i + 1] / 255.0 / a;
                double r = px[i + 2] / 255.0 / a;
                double h, s, v;
                Singularity.ColorUtil.rgb_to_hsv(r, g, b, out h, out s, out v);
                all_w += a;
                all_r += r * a;
                all_g += g * a;
                all_b += b * a;
                if (s < 0.25 || v < 0.2) continue;
                double w = a * s * s * v;
                vivid_w += w;
                vivid_r += r * w;
                vivid_g += g * w;
                vivid_b += b * w;
            }
            if (all_w <= 0) return null;
            bool vivid = vivid_w > all_w * 0.04;
            double r = (vivid ? vivid_r / vivid_w : all_r / all_w).clamp(0, 1);
            double g = (vivid ? vivid_g / vivid_w : all_g / all_w).clamp(0, 1);
            double b = (vivid ? vivid_b / vivid_w : all_b / all_w).clamp(0, 1);
            return "#%02x%02x%02x".printf((uint) (r * 255 + 0.5), (uint) (g * 255 + 0.5), (uint) (b * 255 + 0.5));
        }
    }
}
