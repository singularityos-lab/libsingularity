namespace Singularity.Pdf {

    public class ScriptValue {
        public bool is_string;
        public double number;
        public string text;
        public string[]? list = null;

        public ScriptValue.num(double v) {
            is_string = false;
            number = v;
            text = Obj.format_number(v);
        }

        public ScriptValue.str(string s) {
            is_string = true;
            text = s;
            double d;
            number = Script.parse_number(s, out d) ? d : 0;
        }

        public double to_number() {
            if (!is_string) return number;
            double d;
            return Script.parse_number(text, out d) ? d : 0;
        }

        public bool truthy() {
            return is_string ? text != "" : number != 0;
        }

        public string to_display() {
            if (is_string) return text;
            if (number == Math.floor(number) && number.abs() < 1e15) return "%lld".printf((int64) number);
            string s = "%.10g".printf(number);
            return s.replace(",", ".");
        }
    }

    public class Script {
        private string src;
        private int pos;
        private Gee.Map<string, string> fields;
        private Gee.HashMap<string, ScriptValue> vars = new Gee.HashMap<string, ScriptValue>();
        private ScriptValue event_value;
        private ScriptValue event_rc;
        private int steps = 0;

        private Script(string src, Gee.Map<string, string> fields, string value) {
            this.src = src;
            this.fields = fields;
            this.event_value = new ScriptValue.str(value);
            this.event_rc = new ScriptValue.num(1);
        }

        public static bool parse_number(string s, out double value) {
            value = 0;
            string t = s.strip().replace(" ", "").replace(" ", "");
            foreach (var cur in new string[] { "€", "$", "£", "%", "¥" }) t = t.replace(cur, "");
            if (t == "") return false;
            bool neg = false;
            if (t.has_prefix("(") && t.has_suffix(")")) {
                neg = true;
                t = t.substring(1, t.length - 2);
            }
            int last_comma = t.last_index_of_char(','), last_dot = t.last_index_of_char('.');
            if (last_comma >= 0 && last_dot >= 0) {
                if (last_comma > last_dot) t = t.replace(".", "").replace(",", ".");
                else t = t.replace(",", "");
            } else if (last_comma >= 0) {
                int count = t.split(",").length - 1;
                if (count == 1 && t.length - last_comma - 1 != 3) t = t.replace(",", ".");
                else t = t.replace(",", "");
            }
            double d;
            if (!double.try_parse(t, out d)) return false;
            value = neg ? -d : d;
            return true;
        }

        private static string[] call_args(string js, string fname) {
            int i = js.index_of(fname + "(");
            if (i < 0) return {};
            int start = i + fname.length + 1;
            int depth = 1;
            int j = start;
            bool quoted = false;
            char q = 0;
            while (j < js.length && depth > 0) {
                char c = js[j];
                if (quoted) {
                    if (c == '\\') j++;
                    else if (c == q) quoted = false;
                } else if (c == '"' || c == '\'') {
                    quoted = true;
                    q = c;
                } else if (c == '(' || c == '[') {
                    depth++;
                } else if (c == ')' || c == ']') {
                    depth--;
                }
                j++;
            }
            string inner = js.substring(start, int.max(0, j - start - 1));
            string[] args = {};
            var cur = new StringBuilder();
            depth = 0;
            quoted = false;
            for (int k = 0; k < inner.length; k++) {
                char c = inner[k];
                if (quoted) {
                    cur.append_c(c);
                    if (c == q) quoted = false;
                    continue;
                }
                if (c == '"' || c == '\'') {
                    quoted = true;
                    q = c;
                } else if (c == '(' || c == '[') {
                    depth++;
                } else if (c == ')' || c == ']') {
                    depth--;
                } else if (c == ',' && depth == 0) {
                    args += cur.str.strip();
                    cur.truncate();
                    continue;
                }
                cur.append_c(c);
            }
            if (cur.str.strip() != "") args += cur.str.strip();
            return args;
        }

        private static string unquote(string s) {
            string t = s.strip();
            if (t.length >= 2 && (t[0] == '"' || t[0] == '\'') && t[t.length - 1] == t[0]) return t.substring(1, t.length - 2).replace("\\\"", "\"");
            return t;
        }

        private static string group_digits(string digits, string sep) {
            var s = new StringBuilder();
            int n = digits.length;
            for (int i = 0; i < n; i++) {
                if (i > 0 && (n - i) % 3 == 0) s.append(sep);
                s.append_c(digits[i]);
            }
            return s.str;
        }

        public static string number_format(double v, int decimals, int sep_style) {
            string fixed_s = "%.*f".printf(decimals, v.abs()).replace(",", ".");
            string int_part = fixed_s, frac = "";
            int dot = fixed_s.index_of_char('.');
            if (dot >= 0) {
                int_part = fixed_s.substring(0, dot);
                frac = fixed_s.substring(dot + 1);
            }
            string group = ",", dec = ".";
            switch (sep_style) {
                case 1: group = ""; break;
                case 2: group = "."; dec = ","; break;
                case 3: group = ""; dec = ","; break;
                case 4: group = "'"; break;
                default: break;
            }
            string result = group != "" ? group_digits(int_part, group) : int_part;
            if (decimals > 0) result += dec + frac;
            return result;
        }

        public static bool format(string js, string raw, out string formatted) {
            formatted = raw;
            if (raw.strip() == "") return true;
            if (js.contains("AFNumber_Format(")) {
                var a = call_args(js, "AFNumber_Format");
                double v;
                if (!parse_number(raw, out v)) return false;
                int dec = a.length > 0 ? int.parse(a[0]) : 2;
                int sep = a.length > 1 ? int.parse(a[1]) : 0;
                int neg = a.length > 2 ? int.parse(a[2]) : 0;
                string cur = a.length > 4 ? unquote(a[4]) : "";
                bool prepend = a.length > 5 ? a[5].strip() == "true" : true;
                string body = number_format(v, dec, sep);
                if (cur != "") body = prepend ? cur + body : body + cur;
                if (v < 0) {
                    if (neg == 2 || neg == 3) body = "(" + body + ")";
                    else body = "-" + body;
                }
                formatted = body;
                return true;
            }
            if (js.contains("AFPercent_Format(")) {
                var a = call_args(js, "AFPercent_Format");
                double v;
                if (!parse_number(raw, out v)) return false;
                formatted = number_format(v * 100, a.length > 0 ? int.parse(a[0]) : 0, a.length > 1 ? int.parse(a[1]) : 0) + "%";
                if (v < 0) formatted = "-" + formatted;
                return true;
            }
            if (js.contains("AFDate_FormatEx(") || js.contains("AFDate_Format(")) {
                string fmt = "mm/dd/yyyy";
                if (js.contains("AFDate_FormatEx(")) {
                    var a = call_args(js, "AFDate_FormatEx");
                    if (a.length > 0) fmt = unquote(a[0]);
                } else {
                    string[] formats = { "m/d", "m/d/yy", "mm/dd/yy", "mm/yy", "d-mmm", "d-mmm-yy", "dd-mmm-yy", "yy-mm-dd", "mmm-yy", "mmmm-yy", "mmm d, yyyy", "mmmm d, yyyy", "m/d/yy h:MM tt", "m/d/yy HH:MM" };
                    var a = call_args(js, "AFDate_Format");
                    int idx = a.length > 0 ? int.parse(a[0]) : 0;
                    if (idx >= 0 && idx < formats.length) fmt = formats[idx];
                }
                var dt = parse_date(raw);
                if (dt == null) return false;
                formatted = date_format(dt, fmt);
                return true;
            }
            if (js.contains("AFSpecial_Format(")) {
                var a = call_args(js, "AFSpecial_Format");
                int kind = a.length > 0 ? int.parse(a[0]) : 0;
                var digits = new StringBuilder();
                for (int i = 0; i < raw.length; i++) if (raw[i].isdigit()) digits.append_c(raw[i]);
                string d = digits.str;
                switch (kind) {
                    case 0: formatted = d.length >= 5 ? d.substring(0, 5) : d; break;
                    case 1: formatted = d.length >= 9 ? d.substring(0, 5) + "-" + d.substring(5, 4) : d; break;
                    case 2: formatted = d.length >= 10 ? "(%s) %s-%s".printf(d.substring(0, 3), d.substring(3, 3), d.substring(6, 4)) : d; break;
                    case 3: formatted = d.length >= 9 ? "%s-%s-%s".printf(d.substring(0, 3), d.substring(3, 2), d.substring(5, 4)) : d; break;
                    default: break;
                }
                return true;
            }
            return false;
        }

        public static DateTime? parse_date(string raw) {
            string t = raw.strip();
            var parts = new Gee.ArrayList<int>();
            var cur = new StringBuilder();
            for (int i = 0; i <= t.length; i++) {
                if (i < t.length && t[i].isdigit()) {
                    cur.append_c(t[i]);
                } else if (cur.len > 0) {
                    parts.add(int.parse(cur.str));
                    cur.truncate();
                }
            }
            if (parts.size < 3) return null;
            int y, m, d;
            if (parts[0] > 31) {
                y = parts[0]; m = parts[1]; d = parts[2];
            } else if (parts[0] > 12) {
                d = parts[0]; m = parts[1]; y = parts[2];
            } else {
                m = parts[0]; d = parts[1]; y = parts[2];
            }
            if (y < 100) y += y < 50 ? 2000 : 1900;
            if (m < 1 || m > 12 || d < 1 || d > 31) return null;
            return new DateTime.local(y, m, d, 0, 0, 0);
        }

        public static string date_format(DateTime dt, string fmt) {
            string[] months = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
            var s = new StringBuilder();
            int i = 0;
            while (i < fmt.length) {
                int run = 1;
                while (i + run < fmt.length && fmt[i + run] == fmt[i]) run++;
                char c = fmt[i];
                switch (c) {
                    case 'y':
                        s.append(run >= 4 ? "%04d".printf(dt.get_year()) : "%02d".printf(dt.get_year() % 100));
                        break;
                    case 'm':
                        if (run >= 4) s.append(months[dt.get_month() - 1]);
                        else if (run == 3) s.append(months[dt.get_month() - 1].substring(0, 3));
                        else if (run == 2) s.append("%02d".printf(dt.get_month()));
                        else s.append(dt.get_month().to_string());
                        break;
                    case 'd':
                        s.append(run >= 2 ? "%02d".printf(dt.get_day_of_month()) : dt.get_day_of_month().to_string());
                        break;
                    default:
                        for (int k = 0; k < run; k++) s.append_c(c);
                        break;
                }
                i += run;
            }
            return s.str;
        }

        private static string[] field_list(string arg) {
            string a = arg.strip();
            string[] names = {};
            if (a.has_prefix("new Array(")) a = a.substring(10, a.length - 11);
            else if (a.has_prefix("[")) a = a.substring(1, a.length - 2);
            else {
                foreach (var part in unquote(a).split(",")) names += part.strip();
                return names;
            }
            foreach (var part in a.split(",")) names += unquote(part);
            return names;
        }

        public static bool calculate(string js, Gee.Map<string, string> values, out string result) {
            result = "";
            if (js.contains("AFSimple_Calculate(")) {
                var a = call_args(js, "AFSimple_Calculate");
                if (a.length < 2) return false;
                string op = unquote(a[0]).up();
                double acc = op == "PRD" ? 1 : 0;
                int count = 0;
                double min = double.MAX, max = -double.MAX;
                foreach (var name in field_list(a[1])) {
                    double v = 0;
                    if (values.has_key(name)) parse_number(values[name], out v);
                    count++;
                    switch (op) {
                        case "SUM":
                        case "AVG":
                            acc += v;
                            break;
                        case "PRD":
                            acc *= v;
                            break;
                        default:
                            break;
                    }
                    min = double.min(min, v);
                    max = double.max(max, v);
                }
                double r = acc;
                if (op == "AVG") r = count > 0 ? acc / count : 0;
                else if (op == "MIN") r = count > 0 ? min : 0;
                else if (op == "MAX") r = count > 0 ? max : 0;
                result = new ScriptValue.num(r).to_display();
                return true;
            }
            var s = new Script(js, values, "");
            if (!s.run()) return false;
            result = s.event_value.to_display();
            return true;
        }

        public static bool validate(string js, string value, out string message) {
            message = "";
            if (js.contains("AFRange_Validate(")) {
                var a = call_args(js, "AFRange_Validate");
                double v;
                if (value.strip() == "") return true;
                if (!parse_number(value, out v)) {
                    message = _("Enter a number");
                    return false;
                }
                if (a.length >= 4) {
                    bool gt = a[0].strip() == "true", lt = a[2].strip() == "true";
                    double lo = double.parse(a[1]), hi = double.parse(a[3]);
                    if ((gt && v < lo) || (lt && v > hi)) {
                        if (gt && lt) message = _("The value must be between %s and %s").printf(a[1], a[3]);
                        else if (gt) message = _("The value must be at least %s").printf(a[1]);
                        else message = _("The value must be at most %s").printf(a[3]);
                        return false;
                    }
                }
                return true;
            }
            var s = new Script(js, new Gee.HashMap<string, string>(), value);
            if (!s.run()) return true;
            if (!s.event_rc.truthy()) {
                message = _("The value is not valid");
                return false;
            }
            return true;
        }

        private bool run() {
            try {
                while (true) {
                    skip();
                    if (pos >= src.length) break;
                    statement();
                    if (steps++ > 10000) return false;
                }
            } catch (PdfError e) {
                return false;
            }
            return true;
        }

        private void skip() {
            while (pos < src.length) {
                char c = src[pos];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ';') {
                    pos++;
                } else if (c == '/' && pos + 1 < src.length && src[pos + 1] == '/') {
                    while (pos < src.length && src[pos] != '\n') pos++;
                } else if (c == '/' && pos + 1 < src.length && src[pos + 1] == '*') {
                    int end = src.index_of("*/", pos + 2);
                    pos = end < 0 ? src.length : end + 2;
                } else {
                    break;
                }
            }
        }

        private void skip_ws() {
            while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n' || src[pos] == '\r')) pos++;
        }

        private bool accept(string token) {
            skip_ws();
            if (src.substring(pos).has_prefix(token)) {
                if (token[0].isalpha() && pos + token.length < src.length && (src[pos + token.length].isalnum() || src[pos + token.length] == '_')) return false;
                pos += token.length;
                return true;
            }
            return false;
        }

        private void expect(string token) throws PdfError {
            if (!accept(token)) throw new PdfError.UNSUPPORTED("expected %s", token);
        }

        private string identifier() throws PdfError {
            skip_ws();
            int start = pos;
            while (pos < src.length && (src[pos].isalnum() || src[pos] == '_' || src[pos] == '$')) pos++;
            if (start == pos) throw new PdfError.UNSUPPORTED("identifier expected");
            return src.substring(start, pos - start);
        }

        private void block_or_statement(bool execute) throws PdfError {
            skip();
            if (accept("{")) {
                int depth = 1;
                if (!execute) {
                    while (pos < src.length && depth > 0) {
                        if (src[pos] == '{') depth++;
                        else if (src[pos] == '}') depth--;
                        pos++;
                    }
                    return;
                }
                while (true) {
                    skip();
                    if (accept("}")) return;
                    if (pos >= src.length) throw new PdfError.UNSUPPORTED("unterminated block");
                    statement();
                }
            }
            if (execute) {
                statement();
            } else {
                while (pos < src.length && src[pos] != ';' && src[pos] != '\n') pos++;
            }
        }

        private void statement() throws PdfError {
            skip();
            if (accept("if")) {
                expect("(");
                var cond = expression();
                expect(")");
                bool t = cond.truthy();
                block_or_statement(t);
                skip();
                if (accept("else")) block_or_statement(!t);
                return;
            }
            if (accept("var") || accept("let") || accept("const")) {
                string name = identifier();
                if (accept("=")) vars[name] = expression();
                else vars[name] = new ScriptValue.str("");
                return;
            }
            int save = pos;
            if (accept("event")) {
                expect(".");
                string prop = identifier();
                expect("=");
                var v = expression();
                if (prop == "value") event_value = v;
                else if (prop == "rc") event_rc = v;
                return;
            }
            pos = save;
            string name = identifier();
            if (accept("=")) {
                vars[name] = expression();
                return;
            }
            throw new PdfError.UNSUPPORTED("unsupported statement");
        }

        private ScriptValue expression() throws PdfError {
            var cond = logical_or();
            if (accept("?")) {
                var a = expression();
                expect(":");
                var b = expression();
                return cond.truthy() ? a : b;
            }
            return cond;
        }

        private ScriptValue logical_or() throws PdfError {
            var l = logical_and();
            while (accept("||")) {
                var r = logical_and();
                l = l.truthy() ? l : r;
            }
            return l;
        }

        private ScriptValue logical_and() throws PdfError {
            var l = comparison();
            while (accept("&&")) {
                var r = comparison();
                l = !l.truthy() ? l : r;
            }
            return l;
        }

        private ScriptValue comparison() throws PdfError {
            var l = additive();
            while (true) {
                string? op = null;
                foreach (var candidate in new string[] { "===", "!==", "==", "!=", "<=", ">=", "<", ">" }) {
                    if (accept(candidate)) {
                        op = candidate;
                        break;
                    }
                }
                if (op == null) return l;
                var r = additive();
                bool res;
                bool as_text = l.is_string && r.is_string;
                switch (op) {
                    case "===":
                    case "==":
                        res = as_text ? l.text == r.text : l.to_number() == r.to_number();
                        break;
                    case "!==":
                    case "!=":
                        res = as_text ? l.text != r.text : l.to_number() != r.to_number();
                        break;
                    case "<=": res = l.to_number() <= r.to_number(); break;
                    case ">=": res = l.to_number() >= r.to_number(); break;
                    case "<": res = l.to_number() < r.to_number(); break;
                    default: res = l.to_number() > r.to_number(); break;
                }
                l = new ScriptValue.num(res ? 1 : 0);
            }
        }

        private ScriptValue additive() throws PdfError {
            var l = term();
            while (true) {
                if (accept("+")) {
                    var r = term();
                    if (l.is_string && !is_numeric(l.text) || r.is_string && !is_numeric(r.text)) l = new ScriptValue.str(l.to_display() + r.to_display());
                    else l = new ScriptValue.num(l.to_number() + r.to_number());
                } else if (accept("-")) {
                    l = new ScriptValue.num(l.to_number() - term().to_number());
                } else {
                    return l;
                }
            }
        }

        private static bool is_numeric(string s) {
            double d;
            return s.strip() == "" || parse_number(s, out d);
        }

        private ScriptValue term() throws PdfError {
            var l = unary();
            while (true) {
                if (accept("*")) l = new ScriptValue.num(l.to_number() * unary().to_number());
                else if (accept("/")) {
                    double d = unary().to_number();
                    l = new ScriptValue.num(d == 0 ? 0 : l.to_number() / d);
                } else if (accept("%")) {
                    double d = unary().to_number();
                    l = new ScriptValue.num(d == 0 ? 0 : Math.fmod(l.to_number(), d));
                } else {
                    return l;
                }
            }
        }

        private ScriptValue unary() throws PdfError {
            if (accept("-")) return new ScriptValue.num(-unary().to_number());
            if (accept("+")) return new ScriptValue.num(unary().to_number());
            if (accept("!")) return new ScriptValue.num(unary().truthy() ? 0 : 1);
            return postfix(primary());
        }

        private ScriptValue postfix(ScriptValue v) throws PdfError {
            var cur = v;
            while (true) {
                int save = pos;
                if (accept(".")) {
                    string prop = identifier();
                    if (prop == "toFixed") {
                        expect("(");
                        int n = (int) expression().to_number();
                        expect(")");
                        cur = new ScriptValue.str("%.*f".printf(n, cur.to_number()).replace(",", "."));
                    } else if (prop == "length") {
                        cur = new ScriptValue.num(cur.to_display().char_count());
                    } else {
                        pos = save;
                        return cur;
                    }
                } else {
                    return cur;
                }
            }
        }

        private ScriptValue field_value(string name) {
            if (fields.has_key(name)) return new ScriptValue.str(fields[name]);
            return new ScriptValue.str("");
        }

        private ScriptValue primary() throws PdfError {
            skip_ws();
            if (pos >= src.length) throw new PdfError.UNSUPPORTED("unexpected end");
            char c = src[pos];
            if (accept("(")) {
                var v = expression();
                expect(")");
                return v;
            }
            if (c == '"' || c == '\'') {
                pos++;
                var s = new StringBuilder();
                while (pos < src.length && src[pos] != c) {
                    if (src[pos] == '\\' && pos + 1 < src.length) {
                        pos++;
                        char e = src[pos];
                        s.append_c(e == 'n' ? '\n' : e);
                    } else {
                        s.append_c(src[pos]);
                    }
                    pos++;
                }
                pos++;
                return new ScriptValue.str(s.str);
            }
            if (c.isdigit() || c == '.') {
                int start = pos;
                while (pos < src.length && (src[pos].isdigit() || src[pos] == '.' || src[pos] == 'e' || src[pos] == 'E')) pos++;
                return new ScriptValue.num(double.parse(src.substring(start, pos - start)));
            }
            string id = identifier();
            switch (id) {
                case "this":
                    expect(".");
                    return primary_member();
                case "getField":
                    return get_field_call();
                case "event":
                    expect(".");
                    string prop = identifier();
                    return prop == "value" ? event_value : (prop == "rc" ? event_rc : new ScriptValue.str(""));
                case "true":
                    return new ScriptValue.num(1);
                case "false":
                    return new ScriptValue.num(0);
                case "Math":
                    expect(".");
                    return math_call(identifier());
                case "Number":
                case "parseFloat":
                case "AFMakeNumber":
                    expect("(");
                    var v = expression();
                    expect(")");
                    return new ScriptValue.num(v.to_number());
                case "parseInt":
                    expect("(");
                    var iv = expression();
                    expect(")");
                    return new ScriptValue.num(Math.trunc(iv.to_number()));
                case "String":
                    expect("(");
                    var sv = expression();
                    expect(")");
                    return new ScriptValue.str(sv.to_display());
                default:
                    if (vars.has_key(id)) return vars[id];
                    throw new PdfError.UNSUPPORTED("unknown name %s", id);
            }
        }

        private ScriptValue primary_member() throws PdfError {
            string id = identifier();
            if (id == "getField") return get_field_call();
            throw new PdfError.UNSUPPORTED("unsupported member %s", id);
        }

        private ScriptValue get_field_call() throws PdfError {
            expect("(");
            var name = expression();
            expect(")");
            int save = pos;
            if (accept(".")) {
                string prop = identifier();
                if (prop == "value" || prop == "valueAsString") return field_value(name.to_display());
                pos = save;
            }
            return field_value(name.to_display());
        }

        private ScriptValue math_call(string fname) throws PdfError {
            if (fname == "PI") return new ScriptValue.num(Math.PI);
            expect("(");
            double[] args = {};
            skip_ws();
            if (!accept(")")) {
                args += expression().to_number();
                while (accept(",")) args += expression().to_number();
                expect(")");
            }
            double a = args.length > 0 ? args[0] : 0, b = args.length > 1 ? args[1] : 0;
            switch (fname) {
                case "round": return new ScriptValue.num(Math.round(a));
                case "floor": return new ScriptValue.num(Math.floor(a));
                case "ceil": return new ScriptValue.num(Math.ceil(a));
                case "abs": return new ScriptValue.num(a.abs());
                case "sqrt": return new ScriptValue.num(Math.sqrt(a));
                case "pow": return new ScriptValue.num(Math.pow(a, b));
                case "min":
                    double mn = double.MAX;
                    foreach (var x in args) mn = double.min(mn, x);
                    return new ScriptValue.num(args.length > 0 ? mn : 0);
                case "max":
                    double mx = -double.MAX;
                    foreach (var x in args) mx = double.max(mx, x);
                    return new ScriptValue.num(args.length > 0 ? mx : 0);
                default:
                    throw new PdfError.UNSUPPORTED("Math.%s is not supported", fname);
            }
        }
    }
}
