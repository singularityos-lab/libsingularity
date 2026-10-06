namespace Singularity.Equations {

    public class MathNode : Object {
        public string name { get; set; }
        public string text { get; set; default = ""; }
        public weak MathNode? parent;
        public Gee.ArrayList<MathNode> children = new Gee.ArrayList<MathNode>();
        private Gee.ArrayList<string> attr_names = new Gee.ArrayList<string>();
        private Gee.ArrayList<string> attr_values = new Gee.ArrayList<string>();

        public MathNode(string name) {
            Object(name: name);
        }

        public string local {
            owned get {
                int colon = name.index_of_char(':');
                return colon >= 0 ? name.substring(colon + 1) : name;
            }
        }

        public string prefix {
            owned get {
                int colon = name.index_of_char(':');
                return colon >= 0 ? name.substring(0, colon) : "";
            }
        }

        public MathNode append(MathNode child) {
            child.parent = this;
            children.add(child);
            return child;
        }

        public MathNode add(string child_name, string? content = null) {
            var n = new MathNode(child_name);
            if (content != null) n.text = content;
            return append(n);
        }

        public void set_attr(string attr, string value) {
            for (int i = 0; i < attr_names.size; i++) {
                if (attr_names[i] == attr) {
                    attr_values[i] = value;
                    return;
                }
            }
            attr_names.add(attr);
            attr_values.add(value);
        }

        public string? get_attr(string attr) {
            for (int i = 0; i < attr_names.size; i++) {
                string n = attr_names[i];
                if (n == attr) return attr_values[i];
                int colon = n.index_of_char(':');
                if (colon >= 0 && n.substring(colon + 1) == attr && !n.has_prefix("xmlns")) return attr_values[i];
            }
            return null;
        }

        public string attr(string attr_name) {
            return get_attr(attr_name) ?? "";
        }

        public bool has_attr(string attr_name) {
            return get_attr(attr_name) != null;
        }

        public string[] attribute_names() {
            return attr_names.to_array();
        }

        public MathNode? child(string local_name) {
            foreach (var c in children) if (c.local == local_name) return c;
            return null;
        }

        public Gee.ArrayList<MathNode> children_named(string local_name) {
            var list = new Gee.ArrayList<MathNode>();
            foreach (var c in children) if (c.local == local_name) list.add(c);
            return list;
        }

        public MathNode? find(string local_name) {
            if (local == local_name) return this;
            foreach (var c in children) {
                var f = c.find(local_name);
                if (f != null) return f;
            }
            return null;
        }

        public string all_text() {
            var sb = new StringBuilder(text);
            foreach (var c in children) sb.append(c.all_text());
            return sb.str;
        }

        public MathNode copy() {
            var n = new MathNode(name);
            n.text = text;
            for (int i = 0; i < attr_names.size; i++) n.set_attr(attr_names[i], attr_values[i]);
            foreach (var c in children) n.append(c.copy());
            return n;
        }

        public string to_xml(bool pretty = false) {
            var sb = new StringBuilder();
            write_into(sb, pretty, 0);
            return sb.str;
        }

        private void write_into(StringBuilder sb, bool pretty, int level) {
            if (pretty) for (int i = 0; i < level; i++) sb.append("  ");
            sb.append_c('<').append(name);
            for (int i = 0; i < attr_names.size; i++) {
                sb.append_c(' ').append(attr_names[i]).append("=\"").append(MathXml.escape(attr_values[i])).append_c('"');
            }
            if (children.size == 0 && text == "") {
                sb.append("/>");
                if (pretty) sb.append_c('\n');
                return;
            }
            sb.append_c('>');
            if (children.size == 0) {
                sb.append(MathXml.escape(text));
            } else {
                if (text.strip() != "") sb.append(MathXml.escape(text));
                if (pretty) sb.append_c('\n');
                foreach (var c in children) c.write_into(sb, pretty, level + 1);
                if (pretty) for (int i = 0; i < level; i++) sb.append("  ");
            }
            sb.append("</").append(name).append_c('>');
            if (pretty) sb.append_c('\n');
        }
    }

    public class MathXml : Object {
        private const MarkupParser PARSER = { on_start, on_end, on_text, null, null };

        private const string[] ENTITIES = {
            "nbsp", "00a0", "NonBreakingSpace", "00a0", "InvisibleTimes", "2062", "it", "2062",
            "ApplyFunction", "2061", "af", "2061", "InvisibleComma", "2063", "ic", "2063",
            "ThinSpace", "2009", "thinsp", "2009", "MediumSpace", "205f", "ThickSpace", "2005",
            "VeryThinSpace", "200a", "hairsp", "200a", "minus", "2212", "times", "00d7",
            "div", "00f7", "divide", "00f7", "plusmn", "00b1", "pm", "00b1", "PlusMinus", "00b1",
            "le", "2264", "leq", "2264", "ge", "2265", "geq", "2265", "ne", "2260", "infin", "221e",
            "int", "222b", "Integral", "222b", "sum", "2211", "Sum", "2211", "prod", "220f", "Product", "220f",
            "rarr", "2192", "rightarrow", "2192", "RightArrow", "2192", "larr", "2190", "leftarrow", "2190",
            "LeftArrow", "2190", "rArr", "21d2", "Rightarrow", "21d2", "Implies", "21d2", "hArr", "21d4",
            "iff", "21d4", "sdot", "22c5", "cdot", "22c5", "middot", "00b7", "centerdot", "00b7",
            "prime", "2032", "Prime", "2033", "part", "2202", "PartialD", "2202", "nabla", "2207", "Del", "2207",
            "isin", "2208", "Element", "2208", "notin", "2209", "sub", "2282", "subset", "2282", "sube", "2286",
            "cup", "222a", "cap", "2229", "forall", "2200", "ForAll", "2200", "exist", "2203", "Exists", "2203",
            "empty", "2205", "emptyset", "2205", "asymp", "2248", "approx", "2248", "equiv", "2261",
            "Congruent", "2261", "radic", "221a", "Sqrt", "221a", "hellip", "2026", "mldr", "2026",
            "ctdot", "22ef", "cdots", "22ef", "vellip", "22ee", "dtdot", "22f1", "lang", "27e8",
            "langle", "27e8", "LeftAngleBracket", "27e8", "rang", "27e9", "rangle", "27e9",
            "RightAngleBracket", "27e9", "lceil", "2308", "rceil", "2309", "lfloor", "230a", "rfloor", "230b",
            "Vert", "2016", "DoubleVerticalBar", "2016", "verbar", "007c", "vert", "007c", "VerticalBar", "007c",
            "OverBar", "203e", "UnderBar", "005f", "OverBrace", "23de", "UnderBrace", "23df", "Hat", "005e",
            "tilde", "007e", "Tilde", "007e", "alpha", "03b1", "beta", "03b2", "gamma", "03b3", "delta", "03b4",
            "epsi", "03b5", "epsilon", "03b5", "theta", "03b8", "lambda", "03bb", "mu", "03bc", "pi", "03c0",
            "sigma", "03c3", "phi", "03c6", "omega", "03c9", "Delta", "0394", "Sigma", "03a3", "Omega", "03a9"
        };

        private MathNode? root;
        private Gee.ArrayList<MathNode> stack = new Gee.ArrayList<MathNode>();

        public static string uc(uint code) {
            return ((unichar) code).to_string();
        }

        public static string hex(string code) {
            uint64 v = 0;
            uint64.try_parse(code, out v, null, 16);
            return uc((uint) v);
        }

        public static string escape(string s) {
            var sb = new StringBuilder();
            int i = 0;
            unichar c;
            while (s.get_next_char(ref i, out c)) {
                switch (c) {
                    case '&': sb.append("&amp;"); break;
                    case '<': sb.append("&lt;"); break;
                    case '>': sb.append("&gt;"); break;
                    case '"': sb.append("&quot;"); break;
                    default:
                        if (c < 0x20 && c != '\n' && c != '\t' && c != '\r') break;
                        sb.append_unichar(c);
                        break;
                }
            }
            return sb.str;
        }

        public static MathNode? parse(string xml) {
            var p = new MathXml();
            string text = prepare(xml);
            var ctx = new MarkupParseContext(PARSER, MarkupParseFlags.TREAT_CDATA_AS_TEXT, p, null);
            try {
                ctx.parse(text, text.length);
                ctx.end_parse();
            } catch (MarkupError e) {
                if (p.root == null) return null;
            }
            return p.root;
        }

        private static string prepare(string xml) {
            string s = xml;
            if (s.has_prefix("\xef\xbb\xbf")) s = s.substring(3);
            int doctype = s.index_of("<!DOCTYPE");
            if (doctype >= 0) {
                int end = s.index_of(">", doctype);
                int bracket = s.index_of("[", doctype);
                if (bracket >= 0 && bracket < end) {
                    int close = s.index_of("]>", bracket);
                    if (close > 0) end = close + 1;
                }
                if (end > doctype) s = s.substring(0, doctype) + s.substring(end + 1);
            }
            if (!s.contains("&")) return s;
            var sb = new StringBuilder();
            int i = 0;
            while (i < s.length) {
                char c = s[i];
                if (c != '&') {
                    sb.append_c(c);
                    i++;
                    continue;
                }
                int semi = s.index_of_char(';', i);
                if (semi < 0 || semi - i > 40) {
                    sb.append("&amp;");
                    i++;
                    continue;
                }
                string ent = s.substring(i + 1, semi - i - 1);
                switch (ent) {
                    case "lt": case "gt": case "amp": case "quot": case "apos":
                        sb.append(s.substring(i, semi - i + 1));
                        break;
                    default:
                        if (ent.has_prefix("#")) {
                            sb.append(s.substring(i, semi - i + 1));
                        } else {
                            string? named = named_entity(ent);
                            if (named != null) sb.append(escape(named));
                        }
                        break;
                }
                i = semi + 1;
            }
            return sb.str;
        }

        public static string? named_entity(string name) {
            for (int i = 0; i + 1 < ENTITIES.length; i += 2) {
                if (ENTITIES[i] == name) return hex(ENTITIES[i + 1]);
            }
            return null;
        }

        private void on_start(MarkupParseContext context, string element_name, string[] attribute_names, string[] attribute_values) throws MarkupError {
            var n = new MathNode(element_name);
            for (int i = 0; i < attribute_names.length; i++) n.set_attr(attribute_names[i], attribute_values[i]);
            if (stack.size > 0) stack[stack.size - 1].append(n);
            else if (root == null) root = n;
            stack.add(n);
        }

        private void on_end(MarkupParseContext context, string element_name) throws MarkupError {
            if (stack.size > 0) stack.remove_at(stack.size - 1);
        }

        private void on_text(MarkupParseContext context, string text, size_t text_len) throws MarkupError {
            if (stack.size == 0) return;
            var top = stack[stack.size - 1];
            top.text = top.text + text.substring(0, (long) text_len);
        }
    }
}
