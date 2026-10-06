namespace Singularity.Equations {

    public enum Justification {
        CENTER_GROUP,
        CENTER,
        LEFT,
        RIGHT;

        public string to_omml() {
            switch (this) {
                case CENTER: return "center";
                case LEFT: return "left";
                case RIGHT: return "right";
                default: return "centerGroup";
            }
        }

        public static Justification from_omml(string v) {
            switch (v) {
                case "center": return CENTER;
                case "left": return LEFT;
                case "right": return RIGHT;
                default: return CENTER_GROUP;
            }
        }

        public string to_mathml() {
            switch (this) {
                case CENTER: return "center";
                case LEFT: return "left";
                case RIGHT: return "right";
                default: return "center-group";
            }
        }

        public static Justification from_mathml(string v) {
            switch (v) {
                case "center": return CENTER;
                case "left": return LEFT;
                case "right": return RIGHT;
                default: return CENTER_GROUP;
            }
        }
    }

    public class Omml : Object {
        public const string NS = "http://schemas.openxmlformats.org/officeDocument/2006/math";
        public const string HTML_NS = "http://schemas.microsoft.com/office/2004/12/omml";
        public const string W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        public const string MATHML_NS = "http://www.w3.org/1998/Math/MathML";

        private const string[] NARY = { "2211", "220f", "2210", "22c2", "22c3", "22c0", "22c1", "2a00", "2a01", "2a02", "2a04", "2a06", "222b", "222c", "222d", "2a0c", "222e", "222f", "2230", "2231", "2232", "2233" };
        private const string[] INTEGRALS = { "222b", "222c", "222d", "2a0c", "222e", "222f", "2230", "2231", "2232", "2233" };
        private const string[] RELATIONS = {
            "003d", "003c", "003e", "2264", "2265", "2260", "2248", "2261", "2245", "2243", "223c", "221d", "226a", "226b",
            "2208", "2209", "2282", "2283", "2286", "2287", "2192", "2190", "2194", "21d2", "21d0", "21d4", "27f6", "27f5",
            "27f9", "27f8", "27fa", "21a6", "2254", "225c", "2250", "227a", "227b", "2aaf", "2ab0", "22a5", "2225", "2223",
            "22a2", "22a8", "2a7d", "2a7e", "2272", "2273", "2262", "2270", "2271", "226e", "226f", "2284", "2285", "2288", "2289"
        };
        private const string[] ADDITIVE = { "002b", "002d", "2212", "00b1", "2213" };
        private const string[] OPENERS = { "0028", "005b", "007b", "27e8", "230a", "2308", "27e6", "27ee", "2329" };
        private const string[] CLOSERS = { "0029", "005d", "007d", "27e9", "230b", "2309", "27e7", "27ef", "232a" };
        private const string[] ACCENT_PAIRS = {
            "005e", "0302", "02c6", "0302", "007e", "0303", "02dc", "0303", "00af", "0304", "02c9", "0304",
            "02d8", "0306", "02d9", "0307", "00a8", "0308", "02c7", "030c", "00b4", "0301", "0060", "0300",
            "02da", "030a", "2192", "20d7", "2190", "20d6", "2194", "20e1", "20db", "20db", "20dc", "20dc"
        };
        private const string[] GROUP_CHARS = { "23de", "23df", "23dc", "23dd", "23b4", "23b5", "23e0", "23e1" };
        private const string[] BAR_CHARS = { "203e", "00af", "005f", "0332", "0305", "2015" };
        private const string[] FUNCTIONS = {
            "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "arccot", "arcsec", "arccsc",
            "sinh", "cosh", "tanh", "coth", "sech", "csch", "arsinh", "arcosh", "artanh", "arcsinh", "arccosh", "arctanh",
            "log", "ln", "lg", "exp", "det", "dim", "ker", "hom", "deg", "arg", "gcd", "lcm", "max", "min", "sup", "inf",
            "lim", "liminf", "limsup", "Pr", "sgn", "tr", "rank", "mod", "def"
        };

        private StringBuilder sb = new StringBuilder();
        private bool html;
        private Gee.ArrayList<string> colors = new Gee.ArrayList<string>();

        private static bool in_set(string ch, string[] set) {
            if (ch.char_count() != 1) return false;
            uint c = (uint) ch.get_char(0);
            foreach (var h in set) {
                uint64 v = 0;
                uint64.try_parse(h, out v, null, 16);
                if ((uint) v == c) return true;
            }
            return false;
        }

        public static bool is_nary(string ch) {
            return in_set(ch.strip(), NARY);
        }

        public static bool is_integral(string ch) {
            return in_set(ch.strip(), INTEGRALS);
        }

        public static bool is_relation(string ch) {
            return in_set(ch.strip(), RELATIONS);
        }

        public static bool is_known_function(string name) {
            foreach (var f in FUNCTIONS) if (f == name) return true;
            return AutoCorrect.get_default().is_function(name);
        }

        public static string combining_accent(string mark) {
            string m = mark.strip();
            for (int i = 0; i + 1 < ACCENT_PAIRS.length; i += 2) {
                if (m == MathXml.hex(ACCENT_PAIRS[i]) || m == MathXml.hex(ACCENT_PAIRS[i + 1])) return MathXml.hex(ACCENT_PAIRS[i + 1]);
            }
            return m;
        }

        public static string spacing_accent(string mark) {
            string m = mark.strip();
            for (int i = 0; i + 1 < ACCENT_PAIRS.length; i += 2) {
                if (m == MathXml.hex(ACCENT_PAIRS[i + 1])) return MathXml.hex(ACCENT_PAIRS[i]);
            }
            return m;
        }

        public static string from_mathml(string mathml, bool display = true, Justification jc = Justification.CENTER_GROUP, bool html = false) {
            var root = MathXml.parse(mathml);
            var math = root != null ? root.find("math") : null;
            var w = new Omml();
            w.html = html;
            string ns = " xmlns:m=\"" + (html ? HTML_NS : NS) + "\"" + (html ? "" : " xmlns:w=\"" + W_NS + "\"");
            if (display) {
                w.sb.append("<m:oMathPara").append(ns).append(">");
                w.sb.append("<m:oMathParaPr><m:jc m:val=\"").append(jc.to_omml()).append("\"/></m:oMathParaPr>");
                w.sb.append("<m:oMath>");
            } else {
                w.sb.append("<m:oMath").append(ns).append(">");
            }
            if (math != null) {
                var items = w.flat(math);
                w.seq(items);
            }
            w.sb.append("</m:oMath>");
            if (display) w.sb.append("</m:oMathPara>");
            return w.sb.str;
        }

        private Gee.ArrayList<MathNode> flat(MathNode n) {
            var list = new Gee.ArrayList<MathNode>();
            flat_into(n, list);
            return list;
        }

        private void flat_into(MathNode n, Gee.ArrayList<MathNode> list) {
            foreach (var c in n.children) {
                switch (c.local) {
                    case "annotation":
                    case "annotation-xml":
                    case "none":
                    case "mprescripts":
                        break;
                    case "semantics":
                        if (c.children.size > 0) {
                            var first = c.children[0];
                            if (first.local == "mrow" && !fence_group(first) && first.attr("mathcolor") == "") flat_into(first, list);
                            else list.add(first);
                        }
                        break;
                    case "maction":
                        if (c.children.size > 0) list.add(c.children[0]);
                        break;
                    case "mrow":
                    case "mstyle":
                    case "mpadded":
                        if (c.local != "mpadded" && (fence_group(c) || c.attr("mathcolor") != "" || c.attr("color") != "")) list.add(c);
                        else flat_into(c, list);
                        break;
                    default:
                        list.add(c);
                        break;
                }
            }
        }

        private static string token_text(MathNode n) {
            return n.all_text().strip();
        }

        private static MathNode? script_base(MathNode n) {
            switch (n.local) {
                case "msub": case "msup": case "msubsup": case "munder": case "mover": case "munderover":
                    return n.children.size > 0 ? n.children[0] : null;
                default:
                    return null;
            }
        }

        private static bool nary_head(MathNode n) {
            if (n.local == "mo") return is_nary(token_text(n));
            var b = script_base(n);
            if (b == null) return false;
            while (b.local == "mrow" && b.children.size == 1) b = b.children[0];
            return b.local == "mo" && is_nary(token_text(b));
        }

        private static bool function_name(MathNode n) {
            var b = n;
            var sb2 = script_base(n);
            if (sb2 != null) b = sb2;
            while (b.local == "mrow" && b.children.size == 1) b = b.children[0];
            if (b.local != "mi") return false;
            string t = token_text(b);
            return t.char_count() > 1 || is_known_function(t);
        }

        private static bool is_apply(MathNode n) {
            if (n.local != "mo") return false;
            string t = token_text(n);
            return t == MathXml.uc(0x2061);
        }

        private static bool invisible(MathNode n) {
            if (n.local != "mo") return false;
            string t = token_text(n);
            return t == MathXml.uc(0x2061) || t == MathXml.uc(0x2062) || t == MathXml.uc(0x2063) || t == MathXml.uc(0x2064);
        }

        private static bool stops_operand(MathNode n, bool additive) {
            if (n.local != "mo") return false;
            string t = token_text(n);
            if (is_relation(t)) return true;
            if (additive && in_set(t, ADDITIVE)) return true;
            return t == "," || t == ";";
        }

        private void seq(Gee.List<MathNode> items) {
            int i = 0;
            while (i < items.size) {
                var n = items[i];
                if (nary_head(n)) {
                    int j = i + 1;
                    var body = new Gee.ArrayList<MathNode>();
                    while (j < items.size && !stops_operand(items[j], true)) {
                        body.add(items[j]);
                        j++;
                    }
                    nary(n, body);
                    i = j;
                    continue;
                }
                if (function_name(n) && i + 1 < items.size && is_apply(items[i + 1])) {
                    int j = i + 2;
                    var body = new Gee.ArrayList<MathNode>();
                    while (j < items.size) {
                        var c = items[j];
                        if (c.local == "mo" && !fence_group(c)) {
                            string t = token_text(c);
                            if (!in_set(t, OPENERS) || body.size > 0) break;
                        }
                        if (nary_head(c) || (function_name(c) && body.size > 0)) break;
                        body.add(c);
                        j++;
                        if (fence_group(c)) break;
                    }
                    func(n, body);
                    i = j;
                    continue;
                }
                if (invisible(n)) {
                    i++;
                    continue;
                }
                emit(n);
                i++;
            }
        }

        private void open(string tag) {
            sb.append("<m:").append(tag).append(">");
        }

        private void close(string tag) {
            sb.append("</m:").append(tag).append(">");
        }

        private void prop(string tag, string val) {
            sb.append("<m:").append(tag).append(" m:val=\"").append(MathXml.escape(val)).append("\"/>");
        }

        private void slot(string tag, MathNode? n) {
            open(tag);
            if (n != null) {
                if (n.local == "mrow" && !fence_group(n) && n.attr("mathcolor") == "") seq(flat(n));
                else seq(single(n));
            }
            close(tag);
        }

        private void slot_list(string tag, Gee.List<MathNode> items) {
            open(tag);
            seq(items);
            close(tag);
        }

        private static Gee.ArrayList<MathNode> single(MathNode n) {
            var l = new Gee.ArrayList<MathNode>();
            l.add(n);
            return l;
        }

        private void run(string text, string kind, string variant) {
            if (text == "") return;
            sb.append("<m:r>");
            var p = new StringBuilder();
            if (kind == "mtext" || kind == "ms") {
                p.append("<m:nor/>");
            } else {
                string scr = "";
                string sty = "";
                style_of(kind, text, variant, out scr, out sty);
                if (scr != "") p.append("<m:scr m:val=\"").append(scr).append("\"/>");
                if (sty != "") p.append("<m:sty m:val=\"").append(sty).append("\"/>");
            }
            if (p.len > 0) sb.append("<m:rPr>").append(p.str).append("</m:rPr>");
            if (colors.size > 0 && !html) {
                string col = colors[colors.size - 1];
                sb.append("<w:rPr><w:color w:val=\"").append(col).append("\"/></w:rPr>");
            }
            string escaped = MathXml.escape(text);
            if (html) {
                sb.append(escaped);
            } else {
                bool spaces = text.has_prefix(" ") || text.has_suffix(" ");
                sb.append(spaces ? "<m:t xml:space=\"preserve\">" : "<m:t>").append(escaped).append("</m:t>");
            }
            sb.append("</m:r>");
        }

        private static void style_of(string kind, string text, string variant, out string scr, out string sty) {
            scr = "";
            sty = "";
            switch (variant) {
                case "normal": sty = "p"; break;
                case "bold": sty = "b"; break;
                case "italic": sty = "i"; break;
                case "bold-italic": sty = "bi"; break;
                case "double-struck": scr = "double-struck"; sty = "p"; break;
                case "script": scr = "script"; sty = "p"; break;
                case "bold-script": scr = "script"; sty = "b"; break;
                case "fraktur": scr = "fraktur"; sty = "p"; break;
                case "bold-fraktur": scr = "fraktur"; sty = "b"; break;
                case "sans-serif": scr = "sans-serif"; sty = "p"; break;
                case "bold-sans-serif": scr = "sans-serif"; sty = "b"; break;
                case "sans-serif-italic": scr = "sans-serif"; sty = "i"; break;
                case "sans-serif-bold-italic": scr = "sans-serif"; sty = "bi"; break;
                case "monospace": scr = "monospace"; sty = "p"; break;
                default:
                    if (kind == "mi" && text.char_count() > 1) sty = "p";
                    break;
            }
            if (kind == "mn" || kind == "mo") {
                if (sty == "p" && scr == "") sty = "";
            }
        }

        private static string css_to_hex(string c) {
            string s = c.strip();
            bool hash = s.has_prefix("#");
            if (hash) s = s.substring(1);
            bool hexdigits = s.length > 0;
            for (int i = 0; i < s.length; i++) if (!s[i].isxdigit()) hexdigits = false;
            if (hexdigits && s.length == 3) s = "%c%c%c%c%c%c".printf(s[0], s[0], s[1], s[1], s[2], s[2]);
            if (hexdigits && s.length == 6) return s.up();
            switch (s.down()) {
                case "red": return "D62828";
                case "blue": return "1C5FD6";
                case "green": return "1F8A3A";
                case "orange": return "E8740C";
                case "purple": return "7B3FB5";
                case "gray": case "grey": return "808080";
                case "cyan": return "00A6C0";
                case "magenta": return "C42A9C";
                case "yellow": return "D4A800";
                case "brown": return "8A5A2B";
                case "black": return "000000";
                case "white": return "FFFFFF";
                default: return "000000";
            }
        }

        private void emit(MathNode n) {
            switch (n.local) {
                case "mi":
                case "mn":
                case "mo":
                case "mtext":
                case "ms":
                    string t = n.all_text();
                    if (n.local != "mtext" && n.local != "ms") t = t.strip();
                    if (n.local == "ms") t = "\"" + t + "\"";
                    if (n.local == "mo" && t == "-") t = MathXml.uc(0x2212);
                    run(t, n.local, n.attr("mathvariant"));
                    return;
                case "mspace":
                    double w = em_of(n.attr("width"));
                    if (w <= 0) return;
                    run(space_for(w), "mo", "");
                    return;
                case "mfrac":
                    if (n.children.size < 2) return;
                    open("f");
                    string lt = n.attr("linethickness").strip();
                    bool nobar = lt == "0" || lt == "0px" || lt == "0em" || lt == "0pt";
                    if (n.attr("bevelled") == "true") {
                        sb.append("<m:fPr><m:type m:val=\"skw\"/></m:fPr>");
                    } else if (nobar) {
                        sb.append("<m:fPr><m:type m:val=\"noBar\"/></m:fPr>");
                    }
                    slot("num", n.children[0]);
                    slot("den", n.children[1]);
                    close("f");
                    return;
                case "msqrt":
                    open("rad");
                    sb.append("<m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/>");
                    slot_list("e", flat(n));
                    close("rad");
                    return;
                case "mroot":
                    if (n.children.size < 2) return;
                    open("rad");
                    slot("deg", n.children[1]);
                    slot("e", n.children[0]);
                    close("rad");
                    return;
                case "msub":
                case "msup":
                case "msubsup":
                    scripts(n);
                    return;
                case "munder":
                case "mover":
                case "munderover":
                    underover(n);
                    return;
                case "mtable":
                    table(n);
                    return;
                case "menclose":
                    enclose(n);
                    return;
                case "mphantom":
                    open("phant");
                    sb.append("<m:phantPr><m:show m:val=\"0\"/></m:phantPr>");
                    slot_list("e", flat(n));
                    close("phant");
                    return;
                case "mmultiscripts":
                    multiscripts(n);
                    return;
                case "mfenced":
                    mfenced(n);
                    return;
                case "mrow":
                case "mstyle":
                    string col = n.attr("mathcolor");
                    if (col == "") col = n.attr("color");
                    if (col != "") colors.add(css_to_hex(col));
                    if (fence_group(n)) delimited(n);
                    else seq(flat(n));
                    if (col != "") colors.remove_at(colors.size - 1);
                    return;
                case "merror":
                case "mpadded":
                case "math":
                    seq(flat(n));
                    return;
                case "mglyph":
                    run(n.attr("alt"), "mtext", "");
                    return;
                default:
                    if (n.children.size > 0) seq(flat(n));
                    else if (n.text.strip() != "") run(n.text.strip(), "mtext", "");
                    return;
            }
        }

        private static double em_of(string v) {
            string s = v.strip();
            if (s == "") return 0;
            switch (s) {
                case "veryverythinmathspace": return 1.0 / 18.0;
                case "verythinmathspace": return 2.0 / 18.0;
                case "thinmathspace": return 3.0 / 18.0;
                case "mediummathspace": return 4.0 / 18.0;
                case "thickmathspace": return 5.0 / 18.0;
                case "verythickmathspace": return 6.0 / 18.0;
                case "veryverythickmathspace": return 7.0 / 18.0;
                default: break;
            }
            double num = double.parse(s);
            if (s.has_suffix("em")) return num;
            if (s.has_suffix("ex")) return num * 0.43;
            if (s.has_suffix("pt")) return num / 10.0;
            if (s.has_suffix("px")) return num / 13.0;
            if (s.has_suffix("mu")) return num / 18.0;
            return num;
        }

        private static string space_for(double em) {
            if (em >= 0.95) {
                var s = new StringBuilder();
                for (int i = 0; i < (int) Math.round(em); i++) s.append(MathXml.uc(0x2003));
                return s.str;
            }
            if (em >= 0.45) return MathXml.uc(0x2002);
            if (em >= 0.27) return MathXml.uc(0x2005);
            if (em >= 0.2) return MathXml.uc(0x205f);
            if (em >= 0.14) return MathXml.uc(0x2009);
            return MathXml.uc(0x200a);
        }

        private void scripts(MathNode n) {
            if (n.children.size < 2) return;
            var b = n.children[0];
            switch (n.local) {
                case "msub":
                    open("sSub");
                    slot("e", b);
                    slot("sub", n.children[1]);
                    close("sSub");
                    return;
                case "msup":
                    open("sSup");
                    slot("e", b);
                    slot("sup", n.children[1]);
                    close("sSup");
                    return;
                default:
                    open("sSubSup");
                    slot("e", b);
                    slot("sub", n.children[1]);
                    slot("sup", n.children.size > 2 ? n.children[2] : null);
                    close("sSubSup");
                    return;
            }
        }

        private void nary(MathNode head, Gee.List<MathNode> body) {
            MathNode op = head;
            MathNode? lower = null;
            MathNode? upper = null;
            bool under_over = false;
            if (head.local != "mo") {
                op = head.children[0];
                while (op.local == "mrow" && op.children.size == 1) op = op.children[0];
                switch (head.local) {
                    case "msub": lower = head.children[1]; break;
                    case "msup": upper = head.children[1]; break;
                    case "msubsup": lower = head.children[1]; if (head.children.size > 2) upper = head.children[2]; break;
                    case "munder": lower = head.children[1]; under_over = true; break;
                    case "mover": upper = head.children[1]; under_over = true; break;
                    default: lower = head.children[1]; if (head.children.size > 2) upper = head.children[2]; under_over = true; break;
                }
            } else {
                under_over = !is_integral(token_text(op));
            }
            string chr = token_text(op);
            open("nary");
            open("naryPr");
            prop("chr", chr);
            prop("limLoc", under_over ? "undOvr" : "subSup");
            if (lower == null) prop("subHide", "1");
            if (upper == null) prop("supHide", "1");
            close("naryPr");
            slot("sub", lower);
            slot("sup", upper);
            slot_list("e", body);
            close("nary");
        }

        private void func(MathNode head, Gee.List<MathNode> body) {
            open("func");
            open("fName");
            var b = head;
            if (head.local == "munder" || head.local == "mover" || head.local == "munderover") {
                underover(head);
            } else if (head.local == "msub" || head.local == "msup" || head.local == "msubsup") {
                scripts(head);
            } else {
                emit(b);
            }
            close("fName");
            slot_list("e", body);
            close("func");
        }

        private static string? single_mark(MathNode? n) {
            if (n == null) return null;
            var m = n;
            while (m.local == "mrow" && m.children.size == 1) m = m.children[0];
            if (m.local != "mo" && m.local != "mi" && m.local != "mtext") return null;
            string t = token_text(m);
            return t.char_count() == 1 ? t : null;
        }

        private void underover(MathNode n) {
            if (n.children.size < 2) return;
            var b = n.children[0];
            MathNode? under = null;
            MathNode? over = null;
            if (n.local == "munder") under = n.children[1];
            else if (n.local == "mover") over = n.children[1];
            else {
                under = n.children[1];
                if (n.children.size > 2) over = n.children[2];
            }
            string? om = single_mark(over);
            string? um = single_mark(under);
            bool accent = n.attr("accent") == "true";
            bool accentunder = n.attr("accentunder") == "true";
            if (over != null && under == null && om != null) {
                if (in_set(om, GROUP_CHARS)) {
                    group_chr(b, om, true);
                    return;
                }
                if (in_set(om, BAR_CHARS)) {
                    bar(b, true);
                    return;
                }
                string comb = combining_accent(om);
                if (accent || comb != om || (om.get_char(0) >= 0x300 && om.get_char(0) <= 0x36f) || (om.get_char(0) >= 0x20d0 && om.get_char(0) <= 0x20ff)) {
                    open("acc");
                    sb.append("<m:accPr>");
                    prop("chr", comb);
                    sb.append("</m:accPr>");
                    slot("e", b);
                    close("acc");
                    return;
                }
            }
            if (under != null && over == null && um != null) {
                if (in_set(um, GROUP_CHARS)) {
                    group_chr(b, um, false);
                    return;
                }
                if (in_set(um, BAR_CHARS)) {
                    bar(b, false);
                    return;
                }
                if (accentunder) {
                    group_chr(b, um, false);
                    return;
                }
            }
            if (under != null && over != null) {
                open("limUpp");
                open("e");
                open("limLow");
                slot("e", b);
                slot("lim", under);
                close("limLow");
                close("e");
                slot("lim", over);
                close("limUpp");
                return;
            }
            if (under != null) {
                var inner = b;
                while (inner.local == "mrow" && inner.children.size == 1) inner = inner.children[0];
                string? bm = single_mark(inner);
                if (bm != null && in_set(bm, GROUP_CHARS) && inner.local == "mo") {
                    open("limLow");
                    slot("e", b);
                    slot("lim", under);
                    close("limLow");
                    return;
                }
                open("limLow");
                slot("e", b);
                slot("lim", under);
                close("limLow");
                return;
            }
            open("limUpp");
            slot("e", b);
            slot("lim", over);
            close("limUpp");
        }

        private void group_chr(MathNode body, string chr, bool top) {
            open("groupChr");
            sb.append("<m:groupChrPr>");
            prop("chr", chr);
            prop("pos", top ? "top" : "bot");
            prop("vertJc", top ? "bot" : "top");
            sb.append("</m:groupChrPr>");
            slot("e", body);
            close("groupChr");
        }

        private void bar(MathNode body, bool top) {
            open("bar");
            sb.append("<m:barPr>");
            prop("pos", top ? "top" : "bot");
            sb.append("</m:barPr>");
            slot("e", body);
            close("bar");
        }

        private static bool fence_group(MathNode n) {
            if (n.local != "mrow" || n.children.size < 1) return false;
            var first = n.children[0];
            var last = n.children[n.children.size - 1];
            bool open_fence = first.local == "mo" && (first.attr("fence") == "true" && first.attr("form") != "postfix" && first.attr("form") != "infix" || (in_set(token_text(first), OPENERS) && first.attr("stretchy") != "false"));
            bool close_fence = last.local == "mo" && n.children.size > 1 && (last.attr("fence") == "true" && last.attr("form") != "prefix" && last.attr("form") != "infix" || (in_set(token_text(last), CLOSERS) && last.attr("stretchy") != "false"));
            if (first.local == "mo" && token_text(first) == "|" && first.attr("stretchy") != "false" && n.children.size > 1 && last.local == "mo" && token_text(last) == "|") return true;
            if (first.local == "mo" && token_text(first) == MathXml.uc(0x2016) && last.local == "mo" && token_text(last) == MathXml.uc(0x2016) && n.children.size > 1) return true;
            if (open_fence && close_fence) return true;
            if (open_fence && first.attr("fence") == "true" && n.children.size > 1) return true;
            if (close_fence && last.attr("fence") == "true" && n.children.size > 1) return true;
            return false;
        }

        private void delimited(MathNode n) {
            var kids = n.children;
            var first = kids[0];
            var last = kids[kids.size - 1];
            bool has_open = first.local == "mo" && (first.attr("fence") == "true" && first.attr("form") != "postfix" || in_set(token_text(first), OPENERS) || ((token_text(first) == "|" || token_text(first) == MathXml.uc(0x2016)) && first.attr("form") != "postfix"));
            bool has_close = last.local == "mo" && last != first && (last.attr("fence") == "true" && last.attr("form") != "prefix" || in_set(token_text(last), CLOSERS) || token_text(last) == "|" || token_text(last) == MathXml.uc(0x2016));
            string beg = has_open ? token_text(first) : "";
            string end = has_close ? token_text(last) : "";
            int from = has_open ? 1 : 0;
            int to = has_close ? kids.size - 1 : kids.size;
            var parts = new Gee.ArrayList<Gee.ArrayList<MathNode>>();
            var cur = new Gee.ArrayList<MathNode>();
            string sep = "";
            for (int i = from; i < to; i++) {
                var c = kids[i];
                if (c.local == "mo" && (c.attr("separator") == "true" || (c.attr("fence") == "true" && c.attr("form") == "infix"))) {
                    if (sep == "") sep = token_text(c);
                    parts.add(cur);
                    cur = new Gee.ArrayList<MathNode>();
                    continue;
                }
                if (c.local == "mrow" && !fence_group(c) && c.attr("mathcolor") == "") {
                    foreach (var x in flat(c)) cur.add(x);
                } else {
                    cur.add(c);
                }
            }
            parts.add(cur);
            if (beg == "{" && end == "" && parts.size == 1 && parts[0].size == 1 && parts[0][0].local == "mtable") {
                open("d");
                sb.append("<m:dPr>");
                prop("begChr", "{");
                prop("endChr", "");
                sb.append("</m:dPr>");
                open("e");
                eq_array(parts[0][0], true);
                close("e");
                close("d");
                return;
            }
            open("d");
            if (beg != "(" || end != ")" || (sep != "" && sep != "|")) {
                sb.append("<m:dPr>");
                if (beg != "(") prop("begChr", beg);
                if (sep != "" && sep != "|") prop("sepChr", sep);
                if (end != ")") prop("endChr", end);
                sb.append("</m:dPr>");
            }
            foreach (var p in parts) slot_list("e", p);
            close("d");
        }

        private void mfenced(MathNode n) {
            string beg = n.get_attr("open") ?? "(";
            string end = n.get_attr("close") ?? ")";
            string seps = (n.get_attr("separators") ?? ",").replace(" ", "");
            open("d");
            sb.append("<m:dPr>");
            prop("begChr", beg);
            if (seps != "") prop("sepChr", seps.get_char(0).to_string());
            prop("endChr", end);
            sb.append("</m:dPr>");
            foreach (var c in n.children) slot("e", c);
            close("d");
        }

        private static string[] column_aligns(MathNode t) {
            string ca = t.attr("columnalign").strip();
            if (ca == "") return {};
            return ca.split(" ");
        }

        private static bool aligned_table(MathNode t) {
            var aligns = column_aligns(t);
            if (aligns.length < 2) return false;
            for (int i = 0; i < aligns.length; i++) {
                if (aligns[i] != (i % 2 == 0 ? "right" : "left")) return false;
            }
            return true;
        }

        private static bool gather_table(MathNode t) {
            bool labeled = false;
            int cols = 0;
            foreach (var r in t.children) {
                if (r.local == "mlabeledtr") labeled = true;
                int c = 0;
                foreach (var d in r.children) if (d.local == "mtd") c++;
                if (r.local == "mlabeledtr") c--;
                cols = int.max(cols, c);
            }
            if (cols <= 1 && (t.attr("displaystyle") == "true" || labeled)) return true;
            return false;
        }

        private void table(MathNode t) {
            if (aligned_table(t) || gather_table(t)) {
                eq_array(t, false);
                return;
            }
            int cols = 0;
            foreach (var r in t.children) {
                int c = 0;
                foreach (var d in r.children) if (d.local == "mtd") c++;
                if (r.local == "mlabeledtr") c--;
                cols = int.max(cols, c);
            }
            if (cols == 0) cols = 1;
            var aligns = column_aligns(t);
            open("m");
            sb.append("<m:mPr>");
            string rs = t.attr("rowspacing").strip();
            string cs = t.attr("columnspacing").strip();
            if (rs != "") prop("rSpRule", "3");
            if (cs != "") prop("cGpRule", "3");
            if (rs != "") prop("rSp", ((int) Math.round(em_of(rs.split(" ")[0]) * 220)).to_string());
            if (cs != "") prop("cGp", ((int) Math.round(em_of(cs.split(" ")[0]) * 220)).to_string());
            sb.append("<m:mcs>");
            int ci = 0;
            while (ci < cols) {
                string jc = ci < aligns.length ? aligns[ci] : (aligns.length > 0 ? aligns[aligns.length - 1] : "center");
                int count = 1;
                while (ci + count < cols) {
                    int k = ci + count;
                    string jk = k < aligns.length ? aligns[k] : (aligns.length > 0 ? aligns[aligns.length - 1] : "center");
                    if (jk != jc) break;
                    count++;
                }
                sb.append("<m:mc><m:mcPr>");
                prop("count", count.to_string());
                prop("mcJc", jc == "left" || jc == "right" ? jc : "center");
                sb.append("</m:mcPr></m:mc>");
                ci += count;
            }
            sb.append("</m:mcs></m:mPr>");
            foreach (var r in t.children) {
                if (r.local != "mtr" && r.local != "mlabeledtr") continue;
                open("mr");
                int written = 0;
                bool skip = r.local == "mlabeledtr";
                foreach (var d in r.children) {
                    if (d.local != "mtd") continue;
                    if (skip) {
                        skip = false;
                        continue;
                    }
                    slot_list("e", flat(d));
                    written++;
                }
                while (written < cols) {
                    sb.append("<m:e/>");
                    written++;
                }
                close("mr");
            }
            close("m");
        }

        private void eq_array(MathNode t, bool cases) {
            open("eqArr");
            bool amp = aligned_table(t) || cases;
            foreach (var r in t.children) {
                if (r.local != "mtr" && r.local != "mlabeledtr") continue;
                open("e");
                bool first_cell = true;
                string? label = null;
                bool labeled = r.local == "mlabeledtr";
                foreach (var d in r.children) {
                    if (d.local != "mtd") continue;
                    if (labeled && label == null) {
                        label = d.all_text().strip();
                        continue;
                    }
                    if (!first_cell && amp) run("&", "mo", "");
                    first_cell = false;
                    seq(flat(d));
                }
                if (label != null && label != "") {
                    run("#", "mo", "");
                    string l = label;
                    if (!l.has_prefix("(")) l = "(" + l + ")";
                    run(l, "mtext", "");
                }
                close("e");
            }
            close("eqArr");
        }

        private void enclose(MathNode n) {
            string notation = n.attr("notation").strip();
            if (notation == "") notation = "longdiv";
            var notes = new Gee.HashSet<string>();
            foreach (var w in notation.split(" ")) if (w != "") notes.add(w);
            bool all = notes.contains("box") || notes.contains("roundedbox") || notes.contains("circle");
            bool top = all || notes.contains("top") || notes.contains("longdiv") || notes.contains("actuarial");
            bool bottom = all || notes.contains("bottom") || notes.contains("madruwb");
            bool left = all || notes.contains("left") || notes.contains("longdiv");
            bool right = all || notes.contains("right") || notes.contains("actuarial") || notes.contains("madruwb");
            open("borderBox");
            var p = new StringBuilder();
            if (!top) p.append("<m:hideTop m:val=\"1\"/>");
            if (!bottom) p.append("<m:hideBot m:val=\"1\"/>");
            if (!left) p.append("<m:hideLeft m:val=\"1\"/>");
            if (!right) p.append("<m:hideRight m:val=\"1\"/>");
            if (notes.contains("horizontalstrike")) p.append("<m:strikeH m:val=\"1\"/>");
            if (notes.contains("verticalstrike")) p.append("<m:strikeV m:val=\"1\"/>");
            if (notes.contains("updiagonalstrike")) p.append("<m:strikeBLTR m:val=\"1\"/>");
            if (notes.contains("downdiagonalstrike")) p.append("<m:strikeTLBR m:val=\"1\"/>");
            if (p.len > 0) sb.append("<m:borderBoxPr>").append(p.str).append("</m:borderBoxPr>");
            slot_list("e", flat(n));
            close("borderBox");
        }

        private void multiscripts(MathNode n) {
            if (n.children.size == 0) return;
            var b = n.children[0];
            var post = new Gee.ArrayList<MathNode>();
            var pre = new Gee.ArrayList<MathNode>();
            bool in_pre = false;
            for (int i = 1; i < n.children.size; i++) {
                var c = n.children[i];
                if (c.local == "mprescripts") {
                    in_pre = true;
                    continue;
                }
                if (in_pre) pre.add(c);
                else post.add(c);
            }
            bool has_post = post.size >= 2 && (post[0].local != "none" || post[1].local != "none");
            if (pre.size >= 2) {
                open("sPre");
                slot("sub", pre[0].local == "none" ? null : pre[0]);
                slot("sup", pre[1].local == "none" ? null : pre[1]);
                open("e");
                if (has_post) post_scripts(b, post);
                else seq(single(b));
                close("e");
                close("sPre");
                return;
            }
            if (has_post) post_scripts(b, post);
            else seq(single(b));
        }

        private void post_scripts(MathNode b, Gee.List<MathNode> post) {
            bool sub = post[0].local != "none";
            bool sup = post[1].local != "none";
            if (sub && sup) {
                open("sSubSup");
                slot("e", b);
                slot("sub", post[0]);
                slot("sup", post[1]);
                close("sSubSup");
            } else if (sub) {
                open("sSub");
                slot("e", b);
                slot("sub", post[0]);
                close("sSub");
            } else {
                open("sSup");
                slot("e", b);
                slot("sup", post[1]);
                close("sSup");
            }
        }

        public static string to_mathml(string omml, out bool display, out Justification jc) {
            display = false;
            jc = Justification.CENTER_GROUP;
            var root = MathXml.parse(omml);
            var math = new MathNode("math");
            math.set_attr("xmlns", MATHML_NS);
            if (root == null) return math.to_xml();
            var para = root.find("oMathPara");
            var reader = new OmmlReader();
            if (para != null) {
                display = true;
                var ppr = para.child("oMathParaPr");
                if (ppr != null) {
                    var j = ppr.child("jc");
                    if (j != null) jc = Justification.from_omml(j.attr("val"));
                }
                var maths = para.children_named("oMath");
                if (maths.size > 1) {
                    var t = new MathNode("mtable");
                    t.set_attr("displaystyle", "true");
                    foreach (var m in maths) {
                        var tr = t.add("mtr");
                        var td = tr.add("mtd");
                        foreach (var x in reader.container(m)) td.append(x);
                    }
                    math.append(t);
                } else if (maths.size == 1) {
                    append_row(math, reader.container(maths[0]));
                }
            } else {
                var m = root.find("oMath");
                if (m != null) append_row(math, reader.container(m));
            }
            if (display) math.set_attr("display", "block");
            if (display && jc != Justification.CENTER_GROUP) math.set_attr("data-justification", jc.to_mathml());
            return math.to_xml();
        }

        private static void append_row(MathNode parent, Gee.List<MathNode> items) {
            if (items.size == 1) {
                parent.append(items[0]);
                return;
            }
            var row = parent.add("mrow");
            foreach (var x in items) row.append(x);
        }
    }

    private class OmmlReader : Object {
        private static MathNode row_of(Gee.List<MathNode> items) {
            if (items.size == 1) return items[0];
            var r = new MathNode("mrow");
            foreach (var x in items) r.append(x);
            return r;
        }

        private MathNode slot(MathNode? n) {
            if (n == null) return new MathNode("mrow");
            return row_of(container(n));
        }

        private static string val(MathNode? pr, string name, string def) {
            if (pr == null) return def;
            var c = pr.child(name);
            if (c == null) return def;
            return c.get_attr("val") ?? "1";
        }

        private static bool flag(MathNode? pr, string name) {
            if (pr == null) return false;
            var c = pr.child(name);
            if (c == null) return false;
            string v = c.get_attr("val") ?? "1";
            return v == "1" || v == "on" || v == "true";
        }

        public Gee.ArrayList<MathNode> container(MathNode n) {
            var list = new Gee.ArrayList<MathNode>();
            foreach (var c in n.children) element(c, list, false);
            return list;
        }

        private Gee.ArrayList<MathNode> fname(MathNode n) {
            var list = new Gee.ArrayList<MathNode>();
            foreach (var c in n.children) element(c, list, true);
            return list;
        }

        private void element(MathNode c, Gee.ArrayList<MathNode> list, bool fn) {
            switch (c.local) {
                case "r":
                    run(c, list, fn, false);
                    return;
                case "f":
                    var fpr = c.child("fPr");
                    string type = val(fpr, "type", "bar");
                    if (type == "lin") {
                        list.add(slot(c.child("num")));
                        var slash = new MathNode("mo");
                        slash.text = "/";
                        list.add(slash);
                        list.add(slot(c.child("den")));
                        return;
                    }
                    var f = new MathNode("mfrac");
                    if (type == "noBar") f.set_attr("linethickness", "0");
                    if (type == "skw") f.set_attr("bevelled", "true");
                    f.append(slot(c.child("num")));
                    f.append(slot(c.child("den")));
                    list.add(f);
                    return;
                case "rad":
                    var rpr = c.child("radPr");
                    var deg = c.child("deg");
                    bool hide = flag(rpr, "degHide") || deg == null || deg.children.size == 0;
                    if (hide) {
                        var sq = new MathNode("msqrt");
                        foreach (var x in container_or_empty(c.child("e"))) sq.append(x);
                        list.add(sq);
                    } else {
                        var rt = new MathNode("mroot");
                        rt.append(slot(c.child("e")));
                        rt.append(slot(deg));
                        list.add(rt);
                    }
                    return;
                case "sSub":
                case "sSup":
                case "sSubSup":
                    var s = new MathNode(c.local == "sSub" ? "msub" : (c.local == "sSup" ? "msup" : "msubsup"));
                    s.append(slot(c.child("e")));
                    if (c.local != "sSup") s.append(slot(c.child("sub")));
                    if (c.local != "sSub") s.append(slot(c.child("sup")));
                    list.add(s);
                    return;
                case "sPre":
                    var ms = new MathNode("mmultiscripts");
                    ms.append(slot(c.child("e")));
                    ms.add("mprescripts");
                    var psub = c.child("sub");
                    var psup = c.child("sup");
                    if (psub == null || psub.children.size == 0) ms.add("none");
                    else ms.append(slot(psub));
                    if (psup == null || psup.children.size == 0) ms.add("none");
                    else ms.append(slot(psup));
                    list.add(ms);
                    return;
                case "nary":
                    nary(c, list);
                    return;
                case "d":
                    delimiter(c, list);
                    return;
                case "func":
                    foreach (var x in fname(c.child("fName") ?? new MathNode("fName"))) list.add(x);
                    var ap = new MathNode("mo");
                    ap.text = MathXml.uc(0x2061);
                    list.add(ap);
                    var arg = container_or_empty(c.child("e"));
                    if (arg.size == 1) list.add(arg[0]);
                    else if (arg.size > 1) list.add(row_of(arg));
                    return;
                case "limLow":
                case "limUpp":
                    var lu = new MathNode(c.local == "limLow" ? "munder" : "mover");
                    var le = c.child("e");
                    lu.append(le != null ? row_of(fn ? fname(le) : container(le)) : new MathNode("mrow"));
                    lu.append(slot(c.child("lim")));
                    list.add(lu);
                    return;
                case "acc":
                    var apr = c.child("accPr");
                    string chr = val(apr, "chr", MathXml.uc(0x0302));
                    var acc = new MathNode("mover");
                    acc.set_attr("accent", "true");
                    var body = container_or_empty(c.child("e"));
                    acc.append(row_of(body.size > 0 ? body : single_empty()));
                    var mark = new MathNode("mo");
                    string sp = Omml.spacing_accent(chr);
                    mark.text = sp;
                    bool wide = body.size > 1 || (body.size == 1 && body[0].local != "mi" && body[0].local != "mn");
                    mark.set_attr("stretchy", (chr == MathXml.uc(0x20d7) || chr == MathXml.uc(0x20d6) || chr == MathXml.uc(0x20e1)) && wide ? "true" : "false");
                    acc.append(mark);
                    list.add(acc);
                    return;
                case "bar":
                    string pos = val(c.child("barPr"), "pos", "bot");
                    var bar = new MathNode(pos == "top" ? "mover" : "munder");
                    bar.set_attr(pos == "top" ? "accent" : "accentunder", "true");
                    bar.append(slot(c.child("e")));
                    var line = new MathNode("mo");
                    line.text = pos == "top" ? MathXml.uc(0x203e) : "_";
                    line.set_attr("stretchy", "true");
                    bar.append(line);
                    list.add(bar);
                    return;
                case "groupChr":
                    var gpr = c.child("groupChrPr");
                    string gc = val(gpr, "chr", MathXml.uc(0x23df));
                    string gpos = val(gpr, "pos", "bot");
                    var g = new MathNode(gpos == "top" ? "mover" : "munder");
                    g.append(slot(c.child("e")));
                    var gm = new MathNode("mo");
                    gm.text = gc;
                    gm.set_attr("stretchy", "true");
                    g.append(gm);
                    list.add(g);
                    return;
                case "borderBox":
                    var bpr = c.child("borderBoxPr");
                    var notes = new Gee.ArrayList<string>();
                    bool top = !flag(bpr, "hideTop");
                    bool bot = !flag(bpr, "hideBot");
                    bool left = !flag(bpr, "hideLeft");
                    bool right = !flag(bpr, "hideRight");
                    if (top && bot && left && right) {
                        notes.add("box");
                    } else {
                        if (top) notes.add("top");
                        if (bot) notes.add("bottom");
                        if (left) notes.add("left");
                        if (right) notes.add("right");
                    }
                    if (flag(bpr, "strikeH")) notes.add("horizontalstrike");
                    if (flag(bpr, "strikeV")) notes.add("verticalstrike");
                    if (flag(bpr, "strikeBLTR")) notes.add("updiagonalstrike");
                    if (flag(bpr, "strikeTLBR")) notes.add("downdiagonalstrike");
                    var en = new MathNode("menclose");
                    en.set_attr("notation", notes.size > 0 ? string.joinv(" ", notes.to_array()) : "none");
                    foreach (var x in container_or_empty(c.child("e"))) en.append(x);
                    if (notes.size == 0) {
                        foreach (var x in en.children) list.add(x);
                        return;
                    }
                    list.add(en);
                    return;
                case "box":
                case "e":
                case "oMath":
                    foreach (var x in container(c)) list.add(x);
                    return;
                case "phant":
                    var ph = c.child("phantPr");
                    bool show = ph == null || ph.child("show") == null || flag(ph, "show");
                    var inner = container_or_empty(c.child("e"));
                    if (show) {
                        foreach (var x in inner) list.add(x);
                        return;
                    }
                    var p = new MathNode("mphantom");
                    foreach (var x in inner) p.append(x);
                    list.add(p);
                    return;
                case "eqArr":
                    list.add(eq_array(c, false));
                    return;
                case "m":
                    list.add(matrix(c));
                    return;
                default:
                    return;
            }
        }

        private static Gee.ArrayList<MathNode> single_empty() {
            var l = new Gee.ArrayList<MathNode>();
            l.add(new MathNode("mrow"));
            return l;
        }

        private Gee.ArrayList<MathNode> container_or_empty(MathNode? n) {
            if (n == null) return new Gee.ArrayList<MathNode>();
            return container(n);
        }

        private void nary(MathNode c, Gee.ArrayList<MathNode> list) {
            var pr = c.child("naryPr");
            string chr = val(pr, "chr", MathXml.uc(0x222b));
            if (chr == "") chr = MathXml.uc(0x222b);
            string loc = val(pr, "limLoc", Omml.is_integral(chr) ? "subSup" : "undOvr");
            bool sub_hide = flag(pr, "subHide");
            bool sup_hide = flag(pr, "supHide");
            var sub = c.child("sub");
            var sup = c.child("sup");
            bool has_sub = !sub_hide && sub != null && sub.children.size > 0;
            bool has_sup = !sup_hide && sup != null && sup.children.size > 0;
            var op = new MathNode("mo");
            op.text = chr;
            MathNode head = op;
            bool uo = loc == "undOvr";
            if (has_sub && has_sup) {
                head = new MathNode(uo ? "munderover" : "msubsup");
                head.append(op);
                head.append(slot(sub));
                head.append(slot(sup));
            } else if (has_sub) {
                head = new MathNode(uo ? "munder" : "msub");
                head.append(op);
                head.append(slot(sub));
            } else if (has_sup) {
                head = new MathNode(uo ? "mover" : "msup");
                head.append(op);
                head.append(slot(sup));
            }
            if (head != op && uo && Omml.is_integral(chr)) op.set_attr("movablelimits", "false");
            list.add(head);
            var body = container_or_empty(c.child("e"));
            if (body.size > 0) list.add(row_of(body));
        }

        private void delimiter(MathNode c, Gee.ArrayList<MathNode> list) {
            var pr = c.child("dPr");
            string beg = val(pr, "begChr", "(");
            string end = val(pr, "endChr", ")");
            string sep = val(pr, "sepChr", "|");
            var es = c.children_named("e");
            if (beg == "{" && end == "" && es.size == 1) {
                var only = es[0];
                if (only.children.size == 1 && only.children[0].local == "eqArr") {
                    var mrow = new MathNode("mrow");
                    var o = mrow.add("mo", "{");
                    o.set_attr("fence", "true");
                    o.set_attr("form", "prefix");
                    var t = eq_array(only.children[0], true);
                    t.set_attr("columnalign", "left left");
                    t.set_attr("displaystyle", "false");
                    mrow.append(t);
                    list.add(mrow);
                    return;
                }
            }
            var row = new MathNode("mrow");
            if (beg != "") {
                var o = row.add("mo", beg);
                o.set_attr("fence", "true");
                o.set_attr("form", "prefix");
            }
            for (int i = 0; i < es.size; i++) {
                if (i > 0) {
                    var s = row.add("mo", sep);
                    s.set_attr("fence", "true");
                    s.set_attr("form", "infix");
                    s.set_attr("separator", "true");
                }
                foreach (var x in container(es[i])) row.append(x);
            }
            if (end != "") {
                var cl = row.add("mo", end);
                cl.set_attr("fence", "true");
                cl.set_attr("form", "postfix");
            }
            list.add(row);
        }

        private MathNode matrix(MathNode c) {
            var t = new MathNode("mtable");
            var mpr = c.child("mPr");
            var aligns = new Gee.ArrayList<string>();
            if (mpr != null) {
                var mcs = mpr.child("mcs");
                if (mcs != null) {
                    foreach (var mc in mcs.children_named("mc")) {
                        var mcpr = mc.child("mcPr");
                        int count = int.parse(val(mcpr, "count", "1"));
                        string jc = val(mcpr, "mcJc", "center");
                        for (int k = 0; k < int.max(1, count); k++) aligns.add(jc);
                    }
                }
            }
            if (mpr != null) {
                if (val(mpr, "cGpRule", "") == "3") t.set_attr("columnspacing", "%.4fem".printf(int.parse(val(mpr, "cGp", "0")) / 220.0).replace(",", "."));
                if (val(mpr, "rSpRule", "") == "3") t.set_attr("rowspacing", "%.4fem".printf(int.parse(val(mpr, "rSp", "0")) / 220.0).replace(",", "."));
            }
            bool uniform = true;
            foreach (var a in aligns) if (a != "center") uniform = false;
            if (!uniform) t.set_attr("columnalign", string.joinv(" ", aligns.to_array()));
            foreach (var mr in c.children_named("mr")) {
                var tr = t.add("mtr");
                foreach (var e in mr.children_named("e")) {
                    var td = tr.add("mtd");
                    foreach (var x in container(e)) td.append(x);
                }
            }
            return t;
        }

        private MathNode eq_array(MathNode c, bool cases) {
            var t = new MathNode("mtable");
            var rows = new Gee.ArrayList<Gee.ArrayList<Gee.ArrayList<MathNode>>>();
            var labels = new Gee.ArrayList<string?>();
            bool any_amp = false;
            foreach (var e in c.children_named("e")) {
                var items = new Gee.ArrayList<MathNode>();
                foreach (var x in e.children) {
                    if (x.local == "r") run(x, items, false, true);
                    else element(x, items, false);
                }
                var cells = new Gee.ArrayList<Gee.ArrayList<MathNode>>();
                var cur = new Gee.ArrayList<MathNode>();
                string? label = null;
                bool in_label = false;
                var label_sb = new StringBuilder();
                foreach (var x in items) {
                    if (in_label) {
                        label_sb.append(x.all_text());
                        continue;
                    }
                    if (x.local == "#amp") {
                        any_amp = true;
                        cells.add(cur);
                        cur = new Gee.ArrayList<MathNode>();
                        continue;
                    }
                    if (x.local == "#hash") {
                        in_label = true;
                        continue;
                    }
                    cur.add(x);
                }
                cells.add(cur);
                if (in_label) {
                    label = label_sb.str.strip();
                    if (label.has_prefix("(") && label.has_suffix(")") && label.length > 2) label = label.substring(1, label.length - 2);
                }
                rows.add(cells);
                labels.add(label);
            }
            int cols = 1;
            foreach (var r in rows) cols = int.max(cols, r.size);
            if (any_amp && !cases) {
                var al = new StringBuilder();
                for (int i = 0; i < cols; i++) al.append(i > 0 ? " " : "").append(i % 2 == 0 ? "right" : "left");
                t.set_attr("columnalign", al.str);
            }
            t.set_attr("displaystyle", "true");
            for (int i = 0; i < rows.size; i++) {
                var tr = t.add(labels[i] != null ? "mlabeledtr" : "mtr");
                if (labels[i] != null) {
                    var ltd = tr.add("mtd");
                    ltd.add("mtext", "(" + labels[i] + ")");
                }
                foreach (var cell in rows[i]) {
                    var td = tr.add("mtd");
                    foreach (var x in cell) td.append(x);
                }
                for (int k = rows[i].size; k < cols; k++) tr.add("mtd");
            }
            return t;
        }

        private static string variant_of(string scr, string sty) {
            switch (scr) {
                case "double-struck": return "double-struck";
                case "script": return sty == "b" || sty == "bi" ? "bold-script" : "script";
                case "fraktur": return sty == "b" || sty == "bi" ? "bold-fraktur" : "fraktur";
                case "sans-serif":
                    if (sty == "b") return "bold-sans-serif";
                    if (sty == "i") return "sans-serif-italic";
                    if (sty == "bi") return "sans-serif-bold-italic";
                    return "sans-serif";
                case "monospace": return "monospace";
                default: break;
            }
            switch (sty) {
                case "p": return "normal";
                case "b": return "bold";
                case "bi": return "bold-italic";
                case "i": return "italic";
                default: return "";
            }
        }

        private static bool digit_like(unichar c) {
            return c.isdigit();
        }

        private void run(MathNode r, Gee.ArrayList<MathNode> list, bool fn, bool markers) {
            var rpr = r.child("rPr");
            bool nor = rpr != null && rpr.child("nor") != null && flag(rpr, "nor");
            string scr = val(rpr, "scr", "");
            string sty = val(rpr, "sty", "");
            string color = "";
            foreach (var c in r.children) {
                if (c.local == "rPr" && c.prefix == "w") {
                    var col = c.child("color");
                    if (col != null) {
                        string v = col.attr("val");
                        if (v != "" && v != "auto") color = "#" + v;
                    }
                }
            }
            var sb = new StringBuilder();
            bool found = false;
            foreach (var c in r.children) {
                if (c.local == "t") {
                    sb.append(c.all_text());
                    found = true;
                }
            }
            if (!found) sb.append(r.text);
            string text = sb.str;
            var out_list = new Gee.ArrayList<MathNode>();
            if (nor) {
                var mt = new MathNode("mtext");
                mt.text = text;
                out_list.add(mt);
            } else {
                string variant = variant_of(scr, sty);
                var letters = new StringBuilder();
                var digits = new StringBuilder();
                int i = 0;
                unichar c;
                while (true) {
                    bool more = text.get_next_char(ref i, out c);
                    bool letter = more && (c.isalpha() || (c >= 0x1d400 && c <= 0x1d7ff));
                    bool digit = more && (digit_like(c) || ((c == '.' || c == ',') && digits.len > 0 && i < text.length && text.get_char(i).isdigit()));
                    if (!letter && letters.len > 0) {
                        flush_letters(letters.str, variant, sty, fn, out_list);
                        letters.truncate();
                    }
                    if (!digit && digits.len > 0) {
                        var mn = new MathNode("mn");
                        mn.text = digits.str;
                        if (variant != "" && variant != "normal") mn.set_attr("mathvariant", variant);
                        out_list.add(mn);
                        digits.truncate();
                    }
                    if (!more) break;
                    if (letter) {
                        letters.append_unichar(c);
                        continue;
                    }
                    if (digit) {
                        digits.append_unichar(c);
                        continue;
                    }
                    if (c == ' ' || c == 0xa0) continue;
                    if (c == '&' && markers) {
                        out_list.add(new MathNode("#amp"));
                        continue;
                    }
                    if (c == '#' && markers) {
                        out_list.add(new MathNode("#hash"));
                        continue;
                    }
                    if (c == 0x2003 || c == 0x2002 || c == 0x2005 || c == 0x2009 || c == 0x200a || c == 0x205f || c == 0x2004) {
                        var sp = new MathNode("mspace");
                        double w = c == 0x2003 ? 1.0 : (c == 0x2002 ? 0.5 : (c == 0x2005 || c == 0x2004 ? 5.0 / 18.0 : (c == 0x205f ? 4.0 / 18.0 : (c == 0x2009 ? 3.0 / 18.0 : 1.0 / 18.0))));
                        sp.set_attr("width", "%.4fem".printf(w).replace(",", "."));
                        out_list.add(sp);
                        continue;
                    }
                    var mo = new MathNode("mo");
                    mo.text = c.to_string();
                    if (sty == "b") mo.set_attr("mathvariant", "bold");
                    out_list.add(mo);
                }
            }
            if (color != "") {
                var st = new MathNode("mstyle");
                st.set_attr("mathcolor", color);
                foreach (var x in out_list) st.append(x);
                list.add(st);
                return;
            }
            foreach (var x in out_list) list.add(x);
        }

        private static void flush_letters(string word, string variant, string sty, bool fn, Gee.ArrayList<MathNode> out_list) {
            bool upright = sty == "p" || variant == "normal";
            if (fn || (upright && word.char_count() > 1 && Omml.is_known_function(word))) {
                var mi = new MathNode("mi");
                mi.text = word;
                out_list.add(mi);
                return;
            }
            int i = 0;
            unichar c;
            while (word.get_next_char(ref i, out c)) {
                var mi = new MathNode("mi");
                mi.text = c.to_string();
                if (variant != "" && variant != "italic") mi.set_attr("mathvariant", variant);
                out_list.add(mi);
            }
        }
    }
}
