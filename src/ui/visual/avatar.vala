using Gtk;

namespace Singularity.Widgets {

    public class Avatar : Gtk.Widget {
        private Gdk.Texture? texture;
        private int pixel_size;
        public bool selected { get; set; default = false; }
        public bool add_mode { get; set; default = false; }

        public Avatar (int size = 56) {
            pixel_size = size;
            add_css_class ("singularity-avatar");
            notify["selected"].connect (queue_draw);
        }

        private static Gee.HashMap<string, Gdk.Texture?>? _cache;

        public void set_from_file (string path) {
            if (_cache == null)
                _cache = new Gee.HashMap<string, Gdk.Texture?> ();
            if (_cache.has_key (path)) {
                texture = _cache.get (path);
                queue_draw ();
                return;
            }
            try {
                texture = Gdk.Texture.from_filename (path);
            } catch (Error e) {
                texture = null;
            }
            _cache.set (path, texture);
            queue_draw ();
        }

        public override void measure (Gtk.Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum = natural = pixel_size;
            minimum_baseline = natural_baseline = -1;
        }

        public override void snapshot (Gtk.Snapshot snap) {
            int w = get_width ();
            int h = get_height ();
            float size = (float) (w < h ? w : h);
            float x = (w - size) / 2.0f;
            float y = (h - size) / 2.0f;

            var rect = Graphene.Rect ();
            rect.init (x, y, size, size);
            var clip = Gsk.RoundedRect ();
            clip.init_from_rect (rect, size / 2.0f);

            snap.push_rounded_clip (clip);
            if (texture != null) {
                snap.append_texture (texture, rect);
            } else if (add_mode) {
                var bg = Gdk.RGBA ();
                bg.parse ("rgba(255,255,255,0.08)");
                snap.append_color (bg, rect);
                var col = Gdk.RGBA ();
                col.parse ("rgba(255,255,255,0.75)");
                float cx = x + size / 2.0f;
                float cy = y + size / 2.0f;
                float arm = size * 0.20f;
                float th = size * 0.07f;
                var hbar = Graphene.Rect ();
                hbar.init (cx - arm, cy - th / 2.0f, arm * 2.0f, th);
                var vbar = Graphene.Rect ();
                vbar.init (cx - th / 2.0f, cy - arm, th, arm * 2.0f);
                snap.append_color (col, hbar);
                snap.append_color (col, vbar);
            } else {
                var c = Gdk.RGBA ();
                c.parse ("rgba(255,255,255,0.12)");
                snap.append_color (c, rect);
            }
            snap.pop ();

            if (selected) {
                var col = Gdk.RGBA ();
                col.parse ("#ffffff");
                float[] widths = { 3, 3, 3, 3 };
                Gdk.RGBA[] colors = { col, col, col, col };
                snap.append_border (clip, widths, colors);
            }
        }
    }
}
