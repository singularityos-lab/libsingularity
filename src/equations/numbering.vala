namespace Singularity.Equations {

    public enum NumberStyle {
        PARENS,
        BRACKETS,
        PLAIN;

        public string to_string() {
            switch (this) {
                case BRACKETS: return "brackets";
                case PLAIN: return "plain";
                default: return "parens";
            }
        }

        public static NumberStyle parse(string s) {
            switch (s) {
                case "brackets": return BRACKETS;
                case "plain": return PLAIN;
                default: return PARENS;
            }
        }
    }

    public class NumberFormat : Object {
        public NumberStyle style { get; set; default = NumberStyle.PARENS; }
        public string prefix { get; set; default = ""; }
        public bool with_chapter { get; set; default = false; }
        public string separator { get; set; default = "."; }
        public int start { get; set; default = 1; }

        public string bare(int number, int chapter = 0) {
            var sb = new StringBuilder(prefix);
            if (with_chapter && chapter > 0) sb.append(chapter.to_string()).append(separator);
            sb.append(number.to_string());
            return sb.str;
        }

        public string wrap(string label) {
            switch (style) {
                case NumberStyle.BRACKETS: return "[" + label + "]";
                case NumberStyle.PLAIN: return label;
                default: return "(" + label + ")";
            }
        }

        public string format(int number, int chapter = 0) {
            return wrap(bare(number, chapter));
        }

        public static string unwrap(string label) {
            string l = label.strip();
            if (l.length >= 2 && ((l.has_prefix("(") && l.has_suffix(")")) || (l.has_prefix("[") && l.has_suffix("]")))) return l.substring(1, l.length - 2);
            return l;
        }
    }

    public class Numbering : Object {
        public static string?[] assign(Equation[] equations, NumberFormat format, int[]? chapters = null) {
            var labels = new string?[equations.length];
            int n = format.start;
            int last_chapter = -1;
            for (int i = 0; i < equations.length; i++) {
                var eq = equations[i];
                int ch = chapters != null && i < chapters.length ? chapters[i] : 0;
                if (format.with_chapter && ch != last_chapter) {
                    n = format.start;
                    last_chapter = ch;
                }
                if (!eq.display || !eq.numbered) {
                    labels[i] = null;
                    continue;
                }
                labels[i] = format.format(n, ch);
                n++;
            }
            return labels;
        }

        public static Gee.HashMap<string, string> references(Equation[] equations, NumberFormat format, int[]? chapters = null) {
            var map = new Gee.HashMap<string, string>();
            var labels = assign(equations, format, chapters);
            for (int i = 0; i < equations.length; i++) {
                string? id = equations[i].label;
                if (id != null && id != "" && labels[i] != null) map[id] = labels[i];
            }
            return map;
        }

        public static string new_label() {
            return "eq-%08x".printf(Random.next_int());
        }
    }
}
