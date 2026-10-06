namespace Singularity.Imaging {

    namespace Transfer {

        private float[]? decode_table = null;

        public float srgb_to_linear(float v) {
            float a = v.abs();
            float r = a <= 0.04045f ? a / 12.92f : (float) Math.pow((a + 0.055) / 1.055, 2.4);
            return v < 0 ? -r : r;
        }

        public float linear_to_srgb(float v) {
            float a = v.abs();
            float r = a <= 0.0031308f ? a * 12.92f : (float) (1.055 * Math.pow(a, 1.0 / 2.4) - 0.055);
            return v < 0 ? -r : r;
        }

        public unowned float[] srgb_decode_table() {
            if (decode_table == null) {
                var t = new float[256];
                for (int i = 0; i < 256; i++) t[i] = srgb_to_linear(i / 255.0f);
                decode_table = t;
            }
            return decode_table;
        }

        public uint8 encode_byte(float linear) {
            float v = linear_to_srgb(linear.clamp(0.0f, 1.0f));
            return (uint8) (v * 255.0f + 0.5f);
        }

        public uint16 encode_word(float linear) {
            float v = linear_to_srgb(linear.clamp(0.0f, 1.0f));
            return (uint16) (v * 65535.0f + 0.5f);
        }
    }
}
