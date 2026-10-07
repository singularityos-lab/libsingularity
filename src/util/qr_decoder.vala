namespace Singularity {
    public class QrDecoder : Object {
        [CCode (cname = "singularity_qr_decode_gray", array_length = false, array_null_terminated = true)]
        private static extern string[] native_decode([CCode (array_length_pos = 1.1)] uint8[] gray, int width, int height);

        [CCode (cname = "singularity_qr_decode_available")]
        private static extern bool native_available();

        public static bool available {
            get { return native_available(); }
        }

        public static string[] decode_gray(uint8[] gray, int width, int height) {
            return native_decode(gray, width, height);
        }

        public static string[] decode_texture(Gdk.Texture texture, int max_side = 960) {
            int w = texture.get_width();
            int h = texture.get_height();
            if (w <= 0 || h <= 0 || !available) return {};
            int step = int.max(1, (int.max(w, h) + max_side - 1) / max_side);
            int stride = w * 4;
            var rgba = new uint8[stride * h];
            texture.download(rgba, stride);
            int gw = w / step;
            int gh = h / step;
            var gray = new uint8[gw * gh];
            for (int y = 0; y < gh; y++) {
                for (int x = 0; x < gw; x++) {
                    int o = (y * step) * stride + (x * step) * 4;
                    gray[y * gw + x] = (uint8) ((rgba[o] * 29 + rgba[o + 1] * 150 + rgba[o + 2] * 77) >> 8);
                }
            }
            return native_decode(gray, gw, gh);
        }
    }
}
