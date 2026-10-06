namespace Singularity.Remote {

    public errordomain SessionError {
        FAILED,
        AUTH_FAILED,
        UNSUPPORTED,
        UNTRUSTED
    }

    public class Framebuffer : Object {
        public int width { get; private set; }
        public int height { get; private set; }
        public int stride { get; private set; }
        public uint8[] data;
        private Gdk.Texture? last;
        private Cairo.Region damage = new Cairo.Region ();

        public void resize (int w, int h) {
            width = int.max (w, 1);
            height = int.max (h, 1);
            stride = width * 4;
            data = new uint8[stride * height];
            last = null;
            damage = new Cairo.Region ();
            damage.union_rectangle ({ 0, 0, width, height });
        }

        public void add_damage (int x, int y, int w, int h) {
            damage.union_rectangle ({ x, y, w, h });
        }

        public void fill (int x, int y, int w, int h, uint8 b, uint8 g, uint8 r) {
            if (x < 0 || y < 0 || x + w > width || y + h > height) return;
            for (int row = y; row < y + h; row++) {
                int o = row * stride + x * 4;
                for (int col = 0; col < w; col++) {
                    data[o] = b;
                    data[o + 1] = g;
                    data[o + 2] = r;
                    data[o + 3] = 255;
                    o += 4;
                }
            }
        }

        public void copy_rect (int sx, int sy, int dx, int dy, int w, int h) {
            if (sx < 0 || sy < 0 || dx < 0 || dy < 0) return;
            if (sx + w > width || sy + h > height || dx + w > width || dy + h > height) return;
            var tmp = new uint8[w * 4 * h];
            for (int row = 0; row < h; row++) Memory.copy (&tmp[row * w * 4], &data[(sy + row) * stride + sx * 4], w * 4);
            for (int row = 0; row < h; row++) Memory.copy (&data[(dy + row) * stride + dx * 4], &tmp[row * w * 4], w * 4);
        }

        public Gdk.Texture? commit () {
            if (last != null && damage.is_empty ()) return null;
#if !HAVE_TEXTURE_BUILDER
            last = new Gdk.MemoryTexture (width, height, Gdk.MemoryFormat.B8G8R8X8, new Bytes (data), stride);
            damage = new Cairo.Region ();
            return last;
#else
            var builder = new GdkExtra.MemoryTextureBuilder ();
            builder.set_bytes (new Bytes (data));
            builder.set_format (Gdk.MemoryFormat.B8G8R8X8);
            builder.set_width (width);
            builder.set_height (height);
            builder.set_stride (stride);
            if (last != null) {
                builder.set_update_texture (last);
                builder.set_update_region (damage);
            }
            last = builder.build ();
            damage = new Cairo.Region ();
            return last;
#endif
        }

        public Gdk.Texture? current () {
            return last;
        }
    }

    public abstract class RemoteSession : Object {
        public string host { get; construct; }
        public int port { get; construct; }
        public string username { get; set; default = ""; }
        public string password { get; set; default = ""; }
        public string domain { get; set; default = ""; }
        public string trusted_fingerprint { get; set; default = ""; }
        public string pending_fingerprint { get; protected set; default = ""; }
        public bool view_only { get; set; }
        public string desktop_name { get; protected set; default = ""; }
        public bool can_resize { get; protected set; }
        public bool active { get; protected set; }
        public Gdk.Texture? texture { get; protected set; }
        public int width { get; protected set; }
        public int height { get; protected set; }

        public signal void credentials_needed (bool want_username, string? reason);
        public signal void ready ();
        public signal void frame ();
        public signal void closed (Error? error);
        public signal void cursor_changed (Gdk.Cursor? cursor);
        public signal void remote_clipboard (string text);
        public signal void bell ();

        public abstract void start ();
        public abstract void stop ();
        public abstract void provide_credentials (string username, string password, string domain);
        public abstract void send_pointer (int x, int y, uint buttons);
        public abstract void send_scroll (int x, int y, double dx, double dy);
        public abstract void send_key (uint keyval, uint keycode, bool pressed);
        public abstract void send_clipboard (string text);
        public virtual void request_size (int w, int h) {
        }

        public void send_combo (uint[] keyvals) {
            foreach (uint k in keyvals) send_key (k, 0, true);
            for (int i = keyvals.length - 1; i >= 0; i--) send_key (keyvals[i], 0, false);
        }

        public static string fingerprint_of (uint8[] der) {
            var sum = Checksum.compute_for_data (ChecksumType.SHA256, der);
            var sb = new StringBuilder ();
            for (int i = 0; i < sum.length; i += 2) {
                if (sb.len > 0) sb.append_c (':');
                sb.append (sum.substring (i, 2).up ());
            }
            return sb.str;
        }
    }
}
