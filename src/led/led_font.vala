namespace Singularity {

    public class LedFont : Object {
        public const int HEIGHT = 5;
        public const int SPACE_WIDTH = 2;

        private static HashTable<unichar, string>? glyphs = null;

        private const string[] TABLE = {
            "0", "111101101101111", "1", "010110010010111", "2", "111001111100111",
            "3", "111001111001111", "4", "101101111001001", "5", "111100111001111",
            "6", "111100111101111", "7", "111001010010010", "8", "111101111101111",
            "9", "111101111001111", "A", "010101111101101", "B", "110101110101110",
            "C", "011100100100011", "D", "110101101101110", "E", "111100110100111",
            "F", "111100110100100", "G", "011100101101011", "H", "101101111101101",
            "I", "111010010010111", "J", "001001001101010", "K", "101101110101101",
            "L", "100100100100111", "M", "101111111101101", "N", "110101101101101",
            "O", "010101101101010", "P", "110101110100100", "Q", "010101101110011",
            "R", "110101110101101", "S", "011100010001110", "T", "111010010010010",
            "U", "101101101101111", "V", "101101101101010", "W", "101101111111101",
            "X", "101101010101101", "Y", "101101010010010", "Z", "111001010100111",
            ":", "000010000010000", ".", "000000000000010", ",", "000000000010100",
            "-", "000000111000000", "+", "000010111010000", "%", "101001010100101",
            "/", "001001010100100", "!", "010010010000010", "?", "111001011000010",
            "'", "010010000000000", "°", "010101010000000", "(", "001010010010001",
            ")", "100010010010100", "#", "101111101111101", "=", "000111000111000",
            ">", "100010001010100", "<", "001010100010001", "_", "000000000000111",
            "&", "010101010101011", "*", "101010101000000"
        };

        private static unowned HashTable<unichar, string> table() {
            if (glyphs == null) {
                glyphs = new HashTable<unichar, string>(direct_hash, direct_equal);
                for (int i = 0; i + 1 < TABLE.length; i += 2) glyphs.insert(TABLE[i].get_char(), TABLE[i + 1]);
            }
            return glyphs;
        }

        private static string? bits_for(unichar c) {
            if (c == ' ') return null;
            var t = table();
            string? bits = t.lookup(c.toupper());
            if (bits == null) {
                string plain = c.to_string().to_ascii();
                if (plain.length > 0) bits = t.lookup(plain.get_char().toupper());
            }
            return bits ?? t.lookup('?');
        }

        private static void columns(string bits, out int first, out int last) {
            first = 3;
            last = -1;
            for (int col = 0; col < 3; col++) {
                for (int row = 0; row < HEIGHT; row++) {
                    if (bits[row * 3 + col] == '1') {
                        if (col < first) first = col;
                        if (col > last) last = col;
                    }
                }
            }
        }

        public static int glyph_width(unichar c) {
            string? bits = bits_for(c);
            if (bits == null) return SPACE_WIDTH;
            if (c.isdigit()) return 3;
            int first, last;
            columns(bits, out first, out last);
            return last < first ? SPACE_WIDTH : last - first + 1;
        }

        public static int text_width(string text, int tracking = 1) {
            int w = 0;
            int i = 0;
            unichar c;
            bool first = true;
            while (text.get_next_char(ref i, out c)) {
                if (!first) w += tracking;
                w += glyph_width(c);
                first = false;
            }
            return w;
        }

        public delegate void PixelFunc(int x, int y, bool alternate);

        public static int draw_glyph(unichar c, int x, int y, bool alternate, PixelFunc plot) {
            string? bits = bits_for(c);
            if (bits == null) return SPACE_WIDTH;
            int first = 0, last = 2;
            if (!c.isdigit()) columns(bits, out first, out last);
            if (last < first) return SPACE_WIDTH;
            for (int row = 0; row < HEIGHT; row++) {
                for (int col = first; col <= last; col++) {
                    if (bits[row * 3 + col] == '1') plot(x + col - first, y + row, alternate);
                }
            }
            return last - first + 1;
        }

        public static void draw_text(string text, int x, int y, PixelFunc plot, int tracking = 1) {
            int i = 0;
            unichar c;
            int pen = x;
            int run = 0;
            while (text.get_next_char(ref i, out c)) {
                bool alternate = c.isdigit() && run % 2 == 1;
                run = c.isdigit() ? run + 1 : 0;
                pen += draw_glyph(c, pen, y, alternate, plot) + tracking;
            }
        }
    }
}
