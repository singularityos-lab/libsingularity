namespace Singularity.Charts {

    public class XmlElement : Object {
        public string name;
        public string text = "";
        public weak XmlElement? parent;
        public Gee.ArrayList<XmlElement> children = new Gee.ArrayList<XmlElement>();
        public Gee.ArrayList<string> attr_names = new Gee.ArrayList<string>();
        public Gee.ArrayList<string> attr_values = new Gee.ArrayList<string>();

        public XmlElement(string name) {
            this.name = name;
        }

        public string local {
            owned get {
                int c = name.index_of_char(':');
                return c >= 0 ? name.substring(c + 1) : name;
            }
        }

        public string attr(string key, string def = "") {
            for (int i = 0; i < attr_names.size; i++) {
                string n = attr_names[i];
                if (n == key) return attr_values[i];
                int c = n.index_of_char(':');
                if (c >= 0 && !n.has_prefix("xmlns") && n.substring(c + 1) == key) return attr_values[i];
            }
            return def;
        }

        public XmlElement? child(string local_name) {
            foreach (var c in children) if (c.local == local_name) return c;
            return null;
        }

        public Gee.ArrayList<XmlElement> all(string local_name) {
            var list = new Gee.ArrayList<XmlElement>();
            foreach (var c in children) if (c.local == local_name) list.add(c);
            return list;
        }

        public XmlElement? find(string local_name) {
            foreach (var c in children) {
                if (c.local == local_name) return c;
                var f = c.find(local_name);
                if (f != null) return f;
            }
            return null;
        }

        public void find_all(string local_name, Gee.ArrayList<XmlElement> out_list) {
            foreach (var c in children) {
                if (c.local == local_name) out_list.add(c);
                c.find_all(local_name, out_list);
            }
        }

        public string val(string local_name, string def = "") {
            var c = child(local_name);
            return c != null ? c.attr("val", def) : def;
        }

        public string all_text() {
            var sb = new StringBuilder(text);
            foreach (var c in children) sb.append(c.all_text());
            return sb.str;
        }

        public static XmlElement? parse(owned string xml) {
            var b = new XmlBuilder();
            if (xml.has_prefix("\xef\xbb\xbf")) xml = xml.substring(3);
            var ctx = new MarkupParseContext(XmlBuilder.PARSER, MarkupParseFlags.TREAT_CDATA_AS_TEXT, b, null);
            try {
                ctx.parse(xml, xml.length);
                ctx.end_parse();
            } catch (MarkupError e) {
                return null;
            }
            return b.root.children.size > 0 ? b.root.children[0] : null;
        }
    }

    internal class XmlBuilder : Object {
        internal const MarkupParser PARSER = { on_start, on_end, on_text, null, null };
        public XmlElement root = new XmlElement("#document");
        private XmlElement current;

        construct {
            current = root;
        }

        internal void on_start(MarkupParseContext context, string element_name, string[] attribute_names, string[] attribute_values) throws MarkupError {
            var e = new XmlElement(element_name);
            for (int i = 0; attribute_names[i] != null; i++) {
                e.attr_names.add(attribute_names[i]);
                e.attr_values.add(attribute_values[i]);
            }
            e.parent = current;
            current.children.add(e);
            current = e;
        }

        internal void on_end(MarkupParseContext context, string element_name) throws MarkupError {
            if (current.parent != null) current = current.parent;
        }

        internal void on_text(MarkupParseContext context, string text, size_t text_len) throws MarkupError {
            current.text += text.substring(0, (long) text_len);
        }
    }

    public class XmlText : Object {
        public static string esc(string s) {
            var sb = new StringBuilder();
            unichar c;
            for (int i = 0; s.get_next_char(ref i, out c);) {
                switch (c) {
                    case '&': sb.append("&amp;"); break;
                    case '<': sb.append("&lt;"); break;
                    case '>': sb.append("&gt;"); break;
                    case '"': sb.append("&quot;"); break;
                    default:
                        if (c < 0x20 && c != '\t' && c != '\n' && c != '\r') break;
                        sb.append_unichar(c);
                        break;
                }
            }
            return sb.str;
        }

        public static string num(double v) {
            if (v.is_nan()) return "";
            char[] buf = new char[64];
            string s = v.format(buf, "%.15g");
            if (double.parse(s) != v) s = v.format(buf, "%.17g");
            return s;
        }

        public static double parse_num(string s) {
            string t = s.strip();
            if (t == "") return double.NAN;
            double d;
            if (double.try_parse(t, out d)) return d;
            return double.NAN;
        }
    }
}
