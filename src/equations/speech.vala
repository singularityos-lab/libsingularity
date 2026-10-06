namespace Singularity.Equations {

    public class Speech : Object {
        private const string[] SYMBOLS = {
            "002b", N_("plus"), "2212", N_("minus"), "002d", N_("minus"), "00b1", N_("plus or minus"),
            "2213", N_("minus or plus"), "00d7", N_("times"), "22c5", N_("times"), "00b7", N_("dot"),
            "2217", N_("asterisk"), "00f7", N_("divided by"), "002f", N_("divided by"), "2215", N_("divided by"),
            "003d", N_("equals"), "2260", N_("is not equal to"), "003c", N_("is less than"), "003e", N_("is greater than"),
            "2264", N_("is less than or equal to"), "2265", N_("is greater than or equal to"),
            "2a7d", N_("is less than or equal to"), "2a7e", N_("is greater than or equal to"),
            "2248", N_("is approximately equal to"), "2261", N_("is identical to"), "2245", N_("is congruent to"),
            "223c", N_("is similar to"), "2243", N_("is asymptotically equal to"), "221d", N_("is proportional to"),
            "226a", N_("is much less than"), "226b", N_("is much greater than"), "2254", N_("is defined as"),
            "225c", N_("is defined as"), "2208", N_("is an element of"), "2209", N_("is not an element of"),
            "220b", N_("contains"), "2282", N_("is a subset of"), "2286", N_("is a subset of or equal to"),
            "2283", N_("is a superset of"), "2287", N_("is a superset of or equal to"), "2284", N_("is not a subset of"),
            "222a", N_("union"), "2229", N_("intersection"), "2216", N_("set minus"), "2205", N_("the empty set"),
            "2192", N_("tends to"), "2190", N_("left arrow"), "2194", N_("left right arrow"), "21d2", N_("implies"),
            "21d0", N_("is implied by"), "21d4", N_("if and only if"), "27f9", N_("implies"), "27fa", N_("if and only if"),
            "21a6", N_("maps to"), "27f6", N_("tends to"), "221e", N_("infinity"), "2202", N_("partial"),
            "2207", N_("nabla"), "2200", N_("for all"), "2203", N_("there exists"), "2204", N_("there does not exist"),
            "00ac", N_("not"), "2227", N_("and"), "2228", N_("or"), "22a5", N_("is perpendicular to"),
            "2225", N_("is parallel to"), "2223", N_("divides"), "2224", N_("does not divide"), "2032", N_("prime"),
            "2033", N_("double prime"), "2034", N_("triple prime"), "2026", N_("dot dot dot"), "22ef", N_("dot dot dot"),
            "22ee", N_("vertical dots"), "22f1", N_("diagonal dots"), "0021", N_("factorial"), "0025", N_("percent"),
            "00b0", N_("degrees"), "2220", N_("angle"), "25b3", N_("triangle"), "2211", N_("sum"), "220f", N_("product"),
            "2210", N_("coproduct"), "222b", N_("integral"), "222c", N_("double integral"), "222d", N_("triple integral"),
            "222e", N_("contour integral"), "222f", N_("surface integral"), "2230", N_("volume integral"),
            "22c3", N_("union"), "22c2", N_("intersection"), "2295", N_("circled plus"), "2297", N_("circled times"),
            "2218", N_("composed with"), "210f", N_("h bar"), "2113", N_("script l"), "2135", N_("aleph"),
            "211d", N_("the real numbers"), "2115", N_("the natural numbers"), "2124", N_("the integers"),
            "211a", N_("the rational numbers"), "2102", N_("the complex numbers"), "002c", N_("comma"),
            "003b", N_("semicolon"), "003a", N_("colon"), "2234", N_("therefore"), "2235", N_("because"),
            "22a2", N_("proves"), "22a8", N_("models"), "2016", N_("double bar"), "007c", N_("vertical bar"),
            "0028", N_("open paren"), "0029", N_("close paren"), "005b", N_("open bracket"), "005d", N_("close bracket"),
            "007b", N_("open brace"), "007d", N_("close brace"), "27e8", N_("open angle bracket"),
            "27e9", N_("close angle bracket"), "2147", N_("e"), "2146", N_("d"), "2148", N_("i")
        };

        private const string[] GREEK = {
            "03b1", N_("alpha"), "03b2", N_("beta"), "03b3", N_("gamma"), "03b4", N_("delta"), "03b5", N_("epsilon"),
            "03f5", N_("epsilon"), "03b6", N_("zeta"), "03b7", N_("eta"), "03b8", N_("theta"), "03d1", N_("theta"),
            "03b9", N_("iota"), "03ba", N_("kappa"), "03bb", N_("lambda"), "03bc", N_("mu"), "03bd", N_("nu"),
            "03be", N_("xi"), "03bf", N_("omicron"), "03c0", N_("pi"), "03c1", N_("rho"), "03c3", N_("sigma"),
            "03c2", N_("final sigma"), "03c4", N_("tau"), "03c5", N_("upsilon"), "03c6", N_("phi"), "03d5", N_("phi"),
            "03c7", N_("chi"), "03c8", N_("psi"), "03c9", N_("omega"), "0393", N_("capital gamma"),
            "0394", N_("capital delta"), "0398", N_("capital theta"), "039b", N_("capital lambda"),
            "039e", N_("capital xi"), "03a0", N_("capital pi"), "03a3", N_("capital sigma"),
            "03a5", N_("capital upsilon"), "03a6", N_("capital phi"), "03a8", N_("capital psi"), "03a9", N_("capital omega")
        };

        private const string[] FUNCTIONS = {
            "sin", N_("sine"), "cos", N_("cosine"), "tan", N_("tangent"), "cot", N_("cotangent"), "sec", N_("secant"),
            "csc", N_("cosecant"), "sinh", N_("hyperbolic sine"), "cosh", N_("hyperbolic cosine"),
            "tanh", N_("hyperbolic tangent"), "arcsin", N_("arc sine"), "arccos", N_("arc cosine"),
            "arctan", N_("arc tangent"), "log", N_("log"), "ln", N_("natural log"), "lg", N_("log base 10"),
            "exp", N_("exponential"), "lim", N_("limit"), "max", N_("maximum"), "min", N_("minimum"),
            "det", N_("determinant"), "sup", N_("supremum"), "inf", N_("infimum"), "gcd", N_("greatest common divisor"),
            "lcm", N_("least common multiple"), "mod", N_("modulo"), "deg", N_("degree"), "dim", N_("dimension"),
            "ker", N_("kernel"), "arg", N_("argument")
        };

        private static string? lookup(string[] table, string key, bool hexkey) {
            for (int i = 0; i + 1 < table.length; i += 2) {
                string k = hexkey ? MathXml.hex(table[i]) : table[i];
                if (k == key) return _(table[i + 1]);
            }
            return null;
        }

        public static string symbol_name(string ch) {
            string? g = lookup(GREEK, ch, true);
            if (g != null) return g;
            string? s = lookup(SYMBOLS, ch, true);
            if (s != null) return s;
            return ch;
        }

        public static string describe(string mathml) {
            var root = MathXml.parse(mathml);
            if (root == null) return "";
            var math = root.find("math") ?? root;
            var sp = new Speech();
            string text = sp.node(math);
            return tidy(text);
        }

        public static string tidy(string text) {
            var sb = new StringBuilder();
            bool space = false;
            int i = 0;
            unichar c;
            string t = text.strip();
            while (t.get_next_char(ref i, out c)) {
                if (c == ' ' || c == '\n' || c == '\t') {
                    if (!space) sb.append_c(' ');
                    space = true;
                    continue;
                }
                if (c == ',' && space && sb.len > 0) sb.truncate(sb.len - 1);
                space = false;
                sb.append_unichar(c);
            }
            return sb.str.replace(", ,", ",").strip();
        }

        private static string simple_text(MathNode n) {
            var m = n;
            while ((m.local == "mrow" || m.local == "mstyle") && m.children.size == 1) m = m.children[0];
            if (m.local == "mi" || m.local == "mn" || m.local == "mo") return m.all_text().strip();
            return "";
        }

        private static bool is_simple(MathNode n) {
            var m = n;
            while ((m.local == "mrow" || m.local == "mstyle") && m.children.size == 1) m = m.children[0];
            if (m.local == "mi" || m.local == "mn") return true;
            if (m.local == "mo" && m.all_text().strip().char_count() == 1) return true;
            return false;
        }

        private string seq(Gee.List<MathNode> items) {
            var parts = new Gee.ArrayList<string>();
            foreach (var c in items) {
                string s = node(c);
                if (s.strip() != "") parts.add(s);
            }
            return string.joinv(" ", parts.to_array());
        }

        private string kids(MathNode n) {
            return seq(n.children);
        }

        private string token(MathNode n) {
            string t = n.all_text().strip();
            if (t == "") return "";
            if (n.local == "mn" || n.local == "mtext" || n.local == "ms") return t;
            if (n.local == "mi" && t.char_count() > 1) {
                string? f = lookup(FUNCTIONS, t, false);
                return f ?? t;
            }
            if (t == MathXml.uc(0x2061) || t == MathXml.uc(0x2062) || t == MathXml.uc(0x2063)) return "";
            if (t.char_count() == 1) {
                unichar c = t.get_char(0);
                if (c.isupper() && c < 0x370) return _("capital %s").printf(c.tolower().to_string());
                return symbol_name(t);
            }
            var sb = new StringBuilder();
            int i = 0;
            unichar c;
            while (t.get_next_char(ref i, out c)) sb.append(symbol_name(c.to_string())).append_c(' ');
            return sb.str;
        }

        private string fence(MathNode n) {
            if (n.children.size < 2) return kids(n);
            var first = n.children[0];
            var last = n.children[n.children.size - 1];
            if (first.local != "mo" || last.local != "mo") return kids(n);
            string o = first.all_text().strip();
            string c = last.all_text().strip();
            var inner = new Gee.ArrayList<MathNode>();
            for (int i = 1; i < n.children.size - 1; i++) inner.add(n.children[i]);
            string body = seq(inner);
            if (o == "|" && c == "|") return _("absolute value of %s, end absolute value").printf(body);
            if (o == MathXml.uc(0x2016) && c == MathXml.uc(0x2016)) return _("norm of %s, end norm").printf(body);
            if (o == MathXml.uc(0x230a) && c == MathXml.uc(0x230b)) return _("floor of %s, end floor").printf(body);
            if (o == MathXml.uc(0x2308) && c == MathXml.uc(0x2309)) return _("ceiling of %s, end ceiling").printf(body);
            if (o == "(" && c == ")") return _("open paren %s close paren").printf(body);
            if (o == "[" && c == "]") return _("open bracket %s close bracket").printf(body);
            if (o == "{" && c == "}") return _("open brace %s close brace").printf(body);
            if (o == MathXml.uc(0x27e8) && c == MathXml.uc(0x27e9)) return _("open angle bracket %s close angle bracket").printf(body);
            return kids(n);
        }

        private string nary_name(MathNode op) {
            string t = op.all_text().strip();
            if (op.local == "mi" && t.char_count() > 1) {
                string? f = lookup(FUNCTIONS, t, false);
                return f ?? t;
            }
            return symbol_name(t);
        }

        private static bool large(MathNode n) {
            var m = n;
            while (m.local == "mrow" && m.children.size == 1) m = m.children[0];
            if (m.local == "mo") return Omml.is_nary(m.all_text().strip());
            if (m.local == "mi") {
                string t = m.all_text().strip();
                return t == "lim" || t == "max" || t == "min" || t == "sup" || t == "inf" || t == "limsup" || t == "liminf";
            }
            return false;
        }

        private string power(MathNode b, MathNode s) {
            string st = simple_text(s);
            string base_text = node(b);
            if (st == "2") return _("%s squared").printf(base_text);
            if (st == "3") return _("%s cubed").printf(base_text);
            if (st == MathXml.uc(0x2032) || st == "'") return _("%s prime").printf(base_text);
            if (st == MathXml.uc(0x2033)) return _("%s double prime").printf(base_text);
            if (st == "T" || st == "⊤") return _("%s transpose").printf(base_text);
            if (is_simple(s)) return _("%s to the power %s").printf(base_text, node(s));
            return _("%s to the power %s, end power").printf(base_text, node(s));
        }

        private string accent(MathNode b, string mark, bool under) {
            string m = Omml.combining_accent(mark);
            string body = node(b);
            if (!under) {
                if (m == MathXml.uc(0x0302)) return _("%s hat").printf(body);
                if (m == MathXml.uc(0x0303)) return _("%s tilde").printf(body);
                if (m == MathXml.uc(0x0304) || m == MathXml.uc(0x203e) || m == MathXml.uc(0x0305)) return _("%s bar").printf(body);
                if (m == MathXml.uc(0x0307)) return _("%s dot").printf(body);
                if (m == MathXml.uc(0x0308)) return _("%s double dot").printf(body);
                if (m == MathXml.uc(0x20db)) return _("%s triple dot").printf(body);
                if (m == MathXml.uc(0x20d7) || m == MathXml.uc(0x2192)) return _("vector %s").printf(body);
                if (m == MathXml.uc(0x030c)) return _("%s check").printf(body);
                if (m == MathXml.uc(0x0306)) return _("%s breve").printf(body);
                if (m == MathXml.uc(0x23de)) return _("%s with a brace above").printf(body);
                return _("%s with %s above").printf(body, symbol_name(mark));
            }
            if (mark == "_" || m == MathXml.uc(0x0332)) return _("%s underlined").printf(body);
            if (m == MathXml.uc(0x23df)) return _("%s with a brace below").printf(body);
            return _("%s with %s below").printf(body, symbol_name(mark));
        }

        private string node(MathNode n) {
            switch (n.local) {
                case "math":
                case "mstyle":
                case "mpadded":
                case "merror":
                case "mtd":
                    return kids(n);
                case "mrow":
                    return fence(n);
                case "semantics":
                    return n.children.size > 0 ? node(n.children[0]) : "";
                case "annotation":
                case "annotation-xml":
                case "mphantom":
                case "none":
                case "mprescripts":
                case "mspace":
                    return "";
                case "mi":
                case "mn":
                case "mo":
                case "mtext":
                case "ms":
                    return token(n);
                case "mfrac":
                    if (n.children.size < 2) return kids(n);
                    if (n.attr("linethickness").strip() == "0") return _("%s choose %s").printf(node(n.children[0]), node(n.children[1]));
                    if (is_simple(n.children[0]) && is_simple(n.children[1])) return _("%s over %s").printf(node(n.children[0]), node(n.children[1]));
                    return _("fraction, %s, over, %s, end fraction").printf(node(n.children[0]), node(n.children[1]));
                case "msqrt":
                    string body = kids(n);
                    return n.children.size == 1 && is_simple(n.children[0]) ? _("square root of %s").printf(body) : _("square root of %s, end root").printf(body);
                case "mroot":
                    if (n.children.size < 2) return kids(n);
                    string idx = simple_text(n.children[1]);
                    if (idx == "3") return _("cube root of %s, end root").printf(node(n.children[0]));
                    if (idx == "2") return _("square root of %s, end root").printf(node(n.children[0]));
                    return _("root of order %s of %s, end root").printf(node(n.children[1]), node(n.children[0]));
                case "msup":
                    if (n.children.size < 2) return kids(n);
                    if (large(n.children[0])) return _("%s to %s of").printf(nary_name(n.children[0]), node(n.children[1]));
                    return power(n.children[0], n.children[1]);
                case "msub":
                    if (n.children.size < 2) return kids(n);
                    if (large(n.children[0])) return _("%s over %s of").printf(nary_name(n.children[0]), node(n.children[1]));
                    return _("%s sub %s").printf(node(n.children[0]), node(n.children[1]));
                case "msubsup":
                    if (n.children.size < 3) return kids(n);
                    if (large(n.children[0])) return _("%s from %s to %s of").printf(nary_name(n.children[0]), node(n.children[1]), node(n.children[2]));
                    return _("%s sub %s, to the power %s").printf(node(n.children[0]), node(n.children[1]), node(n.children[2]));
                case "munder":
                    if (n.children.size < 2) return kids(n);
                    if (large(n.children[0])) {
                        string op = n.children[0].all_text().strip();
                        if (op == "lim") return _("limit as %s of").printf(node(n.children[1]));
                        return _("%s over %s of").printf(nary_name(n.children[0]), node(n.children[1]));
                    }
                    if (is_simple(n.children[1]) && (n.attr("accentunder") == "true" || simple_text(n.children[1]) == MathXml.uc(0x23df) || simple_text(n.children[1]) == "_")) return accent(n.children[0], simple_text(n.children[1]), true);
                    return _("%s with %s below").printf(node(n.children[0]), node(n.children[1]));
                case "mover":
                    if (n.children.size < 2) return kids(n);
                    if (large(n.children[0])) return _("%s to %s of").printf(nary_name(n.children[0]), node(n.children[1]));
                    string om = simple_text(n.children[1]);
                    if (om.char_count() == 1 && (n.attr("accent") == "true" || Omml.combining_accent(om) != om || om == MathXml.uc(0x203e) || om == MathXml.uc(0x23de))) return accent(n.children[0], om, false);
                    return _("%s with %s above").printf(node(n.children[0]), node(n.children[1]));
                case "munderover":
                    if (n.children.size < 3) return kids(n);
                    if (large(n.children[0])) return _("%s from %s to %s of").printf(nary_name(n.children[0]), node(n.children[1]), node(n.children[2]));
                    return _("%s with %s below and %s above").printf(node(n.children[0]), node(n.children[1]), node(n.children[2]));
                case "mmultiscripts":
                    return multiscripts(n);
                case "mtable":
                    return table(n);
                case "menclose":
                    string notation = n.attr("notation");
                    string inner = kids(n);
                    if (notation.contains("strike")) return _("%s crossed out").printf(inner);
                    if (notation.contains("circle")) return _("circle around %s").printf(inner);
                    return _("box around %s").printf(inner);
                case "mfenced":
                    string o = n.get_attr("open") ?? "(";
                    string c = n.get_attr("close") ?? ")";
                    return "%s %s %s".printf(symbol_name(o), kids(n), symbol_name(c));
                default:
                    return kids(n);
            }
        }

        private string multiscripts(MathNode n) {
            if (n.children.size == 0) return "";
            string b = node(n.children[0]);
            var pre = new Gee.ArrayList<MathNode>();
            var post = new Gee.ArrayList<MathNode>();
            bool in_pre = false;
            for (int i = 1; i < n.children.size; i++) {
                if (n.children[i].local == "mprescripts") {
                    in_pre = true;
                    continue;
                }
                if (in_pre) pre.add(n.children[i]);
                else post.add(n.children[i]);
            }
            var sb = new StringBuilder(b);
            if (pre.size >= 2) {
                if (pre[0].local != "none") sb.append(", ").append(_("left subscript %s").printf(node(pre[0])));
                if (pre[1].local != "none") sb.append(", ").append(_("left superscript %s").printf(node(pre[1])));
            }
            if (post.size >= 2) {
                if (post[0].local != "none") sb.append(", ").append(_("sub %s").printf(node(post[0])));
                if (post[1].local != "none") sb.append(", ").append(_("to the power %s").printf(node(post[1])));
            }
            return sb.str;
        }

        private string table(MathNode t) {
            var rows = new Gee.ArrayList<MathNode>();
            foreach (var r in t.children) if (r.local == "mtr" || r.local == "mlabeledtr") rows.add(r);
            int cols = 0;
            foreach (var r in rows) {
                int c = 0;
                foreach (var d in r.children) if (d.local == "mtd") c++;
                if (r.local == "mlabeledtr") c--;
                cols = int.max(cols, c);
            }
            string ca = t.attr("columnalign");
            bool lines = t.attr("displaystyle") == "true" || ca.has_prefix("right left");
            var sb = new StringBuilder();
            if (lines) sb.append(ngettext("%d line", "%d lines", rows.size).printf(rows.size));
            else sb.append(_("%d by %d matrix").printf(rows.size, cols));
            for (int i = 0; i < rows.size; i++) {
                var r = rows[i];
                sb.append(", ");
                var cells = new Gee.ArrayList<string>();
                string? label = null;
                bool first = r.local == "mlabeledtr";
                foreach (var d in r.children) {
                    if (d.local != "mtd") continue;
                    if (first) {
                        label = d.all_text().strip();
                        first = false;
                        continue;
                    }
                    string s = node(d);
                    if (s.strip() != "") cells.add(s);
                }
                if (lines) {
                    sb.append(_("line %d").printf(i + 1)).append(": ").append(string.joinv(" ", cells.to_array()));
                    if (label != null) sb.append(", ").append(_("equation %s").printf(label));
                } else {
                    sb.append(_("row %d").printf(i + 1)).append(": ").append(string.joinv(", ", cells.to_array()));
                }
            }
            if (!lines) sb.append(", ").append(_("end matrix"));
            return sb.str;
        }
    }
}
