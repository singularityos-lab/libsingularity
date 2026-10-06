namespace Singularity {

    public errordomain QrEncodeError {
        TOO_LONG,
        INVALID
    }

    public enum QrEcLevel {
        LOW,
        MEDIUM,
        QUARTILE,
        HIGH;

        public int format_bits () {
            switch (this) {
                case LOW: return 1;
                case MEDIUM: return 0;
                case QUARTILE: return 3;
                default: return 2;
            }
        }

        public string id () {
            switch (this) {
                case LOW: return "L";
                case MEDIUM: return "M";
                case QUARTILE: return "Q";
                default: return "H";
            }
        }

        public string label () {
            switch (this) {
                case LOW: return _("Low (7%)");
                case MEDIUM: return _("Medium (15%)");
                case QUARTILE: return _("Quartile (25%)");
                default: return _("High (30%)");
            }
        }

        public static QrEcLevel from_id (string? id) {
            switch (id) {
                case "L": return LOW;
                case "Q": return QUARTILE;
                case "H": return HIGH;
                default: return MEDIUM;
            }
        }

        public static QrEcLevel[] all () {
            return { LOW, MEDIUM, QUARTILE, HIGH };
        }
    }

    public class QrCode : Object {
        public const int MIN_VERSION = 1;
        public const int MAX_VERSION = 40;

        private const int8[] ECC_PER_BLOCK = {
            -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
            -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
            -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
            -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30
        };

        private const int8[] BLOCKS = {
            -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
            -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49,
            -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68,
            -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81
        };

        private const int PENALTY_N1 = 3;
        private const int PENALTY_N2 = 3;
        private const int PENALTY_N3 = 40;
        private const int PENALTY_N4 = 10;

        public int version { get; private set; }
        public int size { get; private set; }
        public QrEcLevel level { get; private set; }
        public int mask { get; private set; }

        private bool[] modules;
        private bool[] function;

        public bool get_module (int x, int y) {
            if (x < 0 || y < 0 || x >= size || y >= size) return false;
            return modules[y * size + x];
        }

        public static QrCode encode_text (string text, QrEcLevel level, int force_mask = -1) throws QrEncodeError {
            return encode_bytes (text.data, level, MIN_VERSION, MAX_VERSION, force_mask);
        }

        public static QrCode encode_bytes (uint8[] data, QrEcLevel level, int min_version = MIN_VERSION, int max_version = MAX_VERSION, int force_mask = -1) throws QrEncodeError {
            if (min_version < MIN_VERSION || max_version > MAX_VERSION || min_version > max_version || force_mask < -1 || force_mask > 7) {
                throw new QrEncodeError.INVALID ("invalid encoder parameters");
            }
            int version = min_version;
            int used = 0;
            while (true) {
                int capacity = data_codewords (version, level) * 8;
                used = 4 + char_count_bits (version) + data.length * 8;
                if (data.length < (1 << char_count_bits (version)) && used <= capacity) break;
                if (version >= max_version) throw new QrEncodeError.TOO_LONG (_("The text is too long for a QR code."));
                version++;
            }

            var bits = new QrBitBuffer ();
            bits.append (0x4, 4);
            bits.append (data.length, char_count_bits (version));
            foreach (uint8 b in data) bits.append (b, 8);
            int capacity_bits = data_codewords (version, level) * 8;
            bits.append (0, int.min (4, capacity_bits - bits.length));
            bits.append (0, (8 - bits.length % 8) % 8);
            for (uint8 pad = 0xEC; bits.length < capacity_bits; pad ^= 0xEC ^ 0x11) bits.append (pad, 8);

            var codewords = bits.to_bytes ();
            var qr = new QrCode ();
            qr.build (version, level, add_ecc_and_interleave (codewords, version, level), force_mask);
            return qr;
        }

        private void build (int ver, QrEcLevel ecl, uint8[] all_codewords, int force_mask) {
            version = ver;
            level = ecl;
            size = ver * 4 + 17;
            modules = new bool[size * size];
            function = new bool[size * size];
            draw_function_patterns ();
            draw_codewords (all_codewords);
            int chosen = force_mask;
            if (chosen == -1) {
                int best = int.MAX;
                for (int m = 0; m < 8; m++) {
                    apply_mask (m);
                    draw_format_bits (m);
                    int penalty = penalty_score ();
                    if (penalty < best) {
                        chosen = m;
                        best = penalty;
                    }
                    apply_mask (m);
                }
            }
            mask = chosen;
            apply_mask (chosen);
            draw_format_bits (chosen);
        }

        private void set_function (int x, int y, bool dark) {
            modules[y * size + x] = dark;
            function[y * size + x] = true;
        }

        private void draw_function_patterns () {
            for (int i = 0; i < size; i++) {
                set_function (6, i, i % 2 == 0);
                set_function (i, 6, i % 2 == 0);
            }
            draw_finder (3, 3);
            draw_finder (size - 4, 3);
            draw_finder (3, size - 4);
            var align = alignment_positions (version);
            int n = align.length;
            for (int i = 0; i < n; i++) {
                for (int j = 0; j < n; j++) {
                    if ((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0)) continue;
                    draw_alignment (align[i], align[j]);
                }
            }
            draw_format_bits (0);
            draw_version ();
        }

        private void draw_finder (int x, int y) {
            for (int dy = -4; dy <= 4; dy++) {
                for (int dx = -4; dx <= 4; dx++) {
                    int dist = int.max (dx.abs (), dy.abs ());
                    int xx = x + dx, yy = y + dy;
                    if (xx >= 0 && xx < size && yy >= 0 && yy < size) set_function (xx, yy, dist != 2 && dist != 4);
                }
            }
        }

        private void draw_alignment (int x, int y) {
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) set_function (x + dx, y + dy, int.max (dx.abs (), dy.abs ()) != 1);
            }
        }

        public static int format_word (QrEcLevel ecl, int mask) {
            int data = ecl.format_bits () << 3 | mask;
            int rem = data;
            for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
            return (data << 10 | rem) ^ 0x5412;
        }

        private static bool bit (int x, int i) {
            return ((x >> i) & 1) != 0;
        }

        private void draw_format_bits (int m) {
            int bits = format_word (level, m);
            for (int i = 0; i <= 5; i++) set_function (8, i, bit (bits, i));
            set_function (8, 7, bit (bits, 6));
            set_function (8, 8, bit (bits, 7));
            set_function (7, 8, bit (bits, 8));
            for (int i = 9; i < 15; i++) set_function (14 - i, 8, bit (bits, i));
            for (int i = 0; i < 8; i++) set_function (size - 1 - i, 8, bit (bits, i));
            for (int i = 8; i < 15; i++) set_function (8, size - 15 + i, bit (bits, i));
            set_function (8, size - 8, true);
        }

        private void draw_version () {
            if (version < 7) return;
            int rem = version;
            for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
            int bits = version << 12 | rem;
            for (int i = 0; i < 18; i++) {
                bool dark = bit (bits, i);
                int a = size - 11 + i % 3;
                int b = i / 3;
                set_function (a, b, dark);
                set_function (b, a, dark);
            }
        }

        private void draw_codewords (uint8[] data) {
            int i = 0;
            int total = data.length * 8;
            for (int right = size - 1; right >= 1; right -= 2) {
                if (right == 6) right = 5;
                for (int vert = 0; vert < size; vert++) {
                    for (int j = 0; j < 2; j++) {
                        int x = right - j;
                        bool upward = ((right + 1) & 2) == 0;
                        int y = upward ? size - 1 - vert : vert;
                        if (!function[y * size + x] && i < total) {
                            modules[y * size + x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) != 0;
                            i++;
                        }
                    }
                }
            }
        }

        public static bool mask_bit (int m, int x, int y) {
            switch (m) {
                case 0: return (x + y) % 2 == 0;
                case 1: return y % 2 == 0;
                case 2: return x % 3 == 0;
                case 3: return (x + y) % 3 == 0;
                case 4: return (x / 3 + y / 2) % 2 == 0;
                case 5: return x * y % 2 + x * y % 3 == 0;
                case 6: return (x * y % 2 + x * y % 3) % 2 == 0;
                default: return ((x + y) % 2 + x * y % 3) % 2 == 0;
            }
        }

        private void apply_mask (int m) {
            for (int y = 0; y < size; y++) {
                for (int x = 0; x < size; x++) {
                    int k = y * size + x;
                    if (!function[k] && mask_bit (m, x, y)) modules[k] = !modules[k];
                }
            }
        }

        public int penalty_score () {
            int result = 0;
            var history = new int[7];
            for (int pass = 0; pass < 2; pass++) {
                for (int a = 0; a < size; a++) {
                    bool run_color = false;
                    int run = 0;
                    for (int i = 0; i < 7; i++) history[i] = 0;
                    for (int b = 0; b < size; b++) {
                        bool c = pass == 0 ? modules[a * size + b] : modules[b * size + a];
                        if (c == run_color) {
                            run++;
                            if (run == 5) result += PENALTY_N1;
                            else if (run > 5) result++;
                        } else {
                            add_history (run, history);
                            if (!run_color) result += count_finder_patterns (history) * PENALTY_N3;
                            run_color = c;
                            run = 1;
                        }
                    }
                    if (run_color) {
                        add_history (run, history);
                        run = 0;
                    }
                    run += size;
                    add_history (run, history);
                    result += count_finder_patterns (history) * PENALTY_N3;
                }
            }
            for (int y = 0; y < size - 1; y++) {
                for (int x = 0; x < size - 1; x++) {
                    bool c = modules[y * size + x];
                    if (c == modules[y * size + x + 1] && c == modules[(y + 1) * size + x] && c == modules[(y + 1) * size + x + 1]) result += PENALTY_N2;
                }
            }
            int dark = 0;
            foreach (bool m in modules) if (m) dark++;
            int total = size * size;
            int k = ((dark * 20 - total * 10).abs () + total - 1) / total - 1;
            result += k * PENALTY_N4;
            return result;
        }

        private void add_history (int run, int[] history) {
            if (history[0] == 0) run += size;
            for (int i = 6; i > 0; i--) history[i] = history[i - 1];
            history[0] = run;
        }

        private static int count_finder_patterns (int[] h) {
            int n = h[1];
            bool core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n;
            return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0);
        }

        public static int[] alignment_positions (int ver) {
            if (ver == 1) return {};
            int count = ver / 7 + 2;
            int step = (ver * 8 + count * 3 + 5) / (count * 4 - 4) * 2;
            var result = new int[count];
            result[0] = 6;
            int pos = ver * 4 + 17 - 7;
            for (int i = count - 1; i >= 1; i--, pos -= step) result[i] = pos;
            return result;
        }

        public static int raw_data_modules (int ver) {
            int result = (16 * ver + 128) * ver + 64;
            if (ver >= 2) {
                int align = ver / 7 + 2;
                result -= (25 * align - 10) * align - 55;
                if (ver >= 7) result -= 36;
            }
            return result;
        }

        public static int data_codewords (int ver, QrEcLevel ecl) {
            int idx = (int) ecl * 41 + ver;
            return raw_data_modules (ver) / 8 - ECC_PER_BLOCK[idx] * BLOCKS[idx];
        }

        public static int max_bytes (int ver, QrEcLevel ecl) {
            return (data_codewords (ver, ecl) * 8 - 4 - char_count_bits (ver)) / 8;
        }

        private static int char_count_bits (int ver) {
            return ver <= 9 ? 8 : 16;
        }

        private static uint8[] add_ecc_and_interleave (uint8[] data, int ver, QrEcLevel ecl) {
            int idx = (int) ecl * 41 + ver;
            int num_blocks = BLOCKS[idx];
            int ecc_len = ECC_PER_BLOCK[idx];
            int raw = raw_data_modules (ver) / 8;
            int num_short = num_blocks - raw % num_blocks;
            int short_len = raw / num_blocks;
            var divisor = QrReedSolomon.divisor (ecc_len);
            var blocks = new uint8[num_blocks, short_len + 1];
            int k = 0;
            for (int i = 0; i < num_blocks; i++) {
                int dat_len = short_len - ecc_len + (i < num_short ? 0 : 1);
                var dat = data[k:k + dat_len];
                k += dat_len;
                var ecc = QrReedSolomon.remainder (dat, divisor);
                int pos = 0;
                for (int j = 0; j < dat_len; j++) blocks[i, pos++] = dat[j];
                if (i < num_short) blocks[i, pos++] = 0;
                for (int j = 0; j < ecc_len; j++) blocks[i, pos++] = ecc[j];
            }
            var result = new uint8[raw];
            int r = 0;
            for (int i = 0; i <= short_len; i++) {
                for (int j = 0; j < num_blocks; j++) {
                    if (i != short_len - ecc_len || j >= num_short) result[r++] = blocks[j, i];
                }
            }
            return result;
        }

        public const int QUIET = 4;

        public void draw (Cairo.Context cr, double x, double y, double module) {
            int n = size + QUIET * 2;
            cr.save ();
            if (module == Math.floor (module)) cr.set_antialias (Cairo.Antialias.NONE);
            cr.set_source_rgb (1, 1, 1);
            cr.rectangle (x, y, n * module, n * module);
            cr.fill ();
            cr.set_source_rgb (0, 0, 0);
            for (int my = 0; my < size; my++) {
                int mx = 0;
                while (mx < size) {
                    if (!get_module (mx, my)) {
                        mx++;
                        continue;
                    }
                    int start = mx;
                    while (mx < size && get_module (mx, my)) mx++;
                    cr.rectangle (x + (start + QUIET) * module, y + (my + QUIET) * module, (mx - start) * module, module);
                }
            }
            cr.fill ();
            cr.restore ();
        }

        public Cairo.ImageSurface to_surface (int module) {
            int px = (size + QUIET * 2) * module;
            var s = new Cairo.ImageSurface (Cairo.Format.RGB24, px, px);
            var cr = new Cairo.Context (s);
            draw (cr, 0, 0, module);
            s.flush ();
            return s;
        }

        public uint8[] to_png (int module) throws Error {
            var buffer = new ByteArray ();
            var status = to_surface (module).write_to_png_stream ((data) => {
                buffer.append (data);
                return Cairo.Status.SUCCESS;
            });
            if (status != Cairo.Status.SUCCESS) throw new IOError.FAILED (_("The image could not be created."));
            return buffer.steal ();
        }

        public Gdk.Texture to_texture (int module) throws Error {
            return Gdk.Texture.from_bytes (new Bytes (to_png (module)));
        }
    }

    namespace QrReedSolomon {
        internal uint8 multiply (uint8 x, uint8 y) {
            int z = 0;
            for (int i = 7; i >= 0; i--) {
                z = (z << 1) ^ ((z >> 7) * 0x11D);
                z ^= ((y >> i) & 1) * x;
            }
            return (uint8) z;
        }

        internal uint8[] divisor (int degree) {
            var result = new uint8[degree];
            result[degree - 1] = 1;
            uint8 root = 1;
            for (int i = 0; i < degree; i++) {
                for (int j = 0; j < degree; j++) {
                    result[j] = multiply (result[j], root);
                    if (j + 1 < degree) result[j] ^= result[j + 1];
                }
                root = multiply (root, 0x02);
            }
            return result;
        }

        internal uint8[] remainder (uint8[] data, uint8[] div) {
            var result = new uint8[div.length];
            foreach (uint8 b in data) {
                uint8 factor = b ^ result[0];
                for (int i = 0; i < result.length - 1; i++) result[i] = result[i + 1];
                result[result.length - 1] = 0;
                for (int i = 0; i < result.length; i++) result[i] ^= multiply (div[i], factor);
            }
            return result;
        }
    }

    private class QrBitBuffer {
        private uint8[] bits = new uint8[0];
        public int length { get { return bits.length; } }

        public void append (uint value, int count) {
            for (int i = count - 1; i >= 0; i--) bits += (uint8) ((value >> i) & 1);
        }

        public uint8[] to_bytes () {
            var out_bytes = new uint8[bits.length / 8];
            for (int i = 0; i < bits.length; i++) out_bytes[i >> 3] |= (uint8) (bits[i] << (7 - (i & 7)));
            return out_bytes;
        }
    }
}
