namespace Singularity.Pdf {

    public class Lexer {
        public unowned uint8[] data;
        public int pos;
        public int end;

        public Lexer(uint8[] data, int pos = 0, int end = -1) {
            this.data = data;
            this.pos = pos;
            this.end = end < 0 ? data.length : int.min(end, data.length);
        }

        public static bool is_space(uint8 c) {
            return c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == '\f' || c == 0;
        }

        public static bool is_delimiter(uint8 c) {
            return c == '(' || c == ')' || c == '<' || c == '>' || c == '[' || c == ']' || c == '{' || c == '}' || c == '/' || c == '%';
        }

        public static bool is_regular(uint8 c) {
            return !is_space(c) && !is_delimiter(c);
        }

        public bool at_end() {
            return pos >= end;
        }

        public void skip_space() {
            while (pos < end) {
                uint8 c = data[pos];
                if (is_space(c)) {
                    pos++;
                } else if (c == '%') {
                    while (pos < end && data[pos] != '\n' && data[pos] != '\r') pos++;
                } else {
                    break;
                }
            }
        }

        public string peek_word() {
            int save = pos;
            string w = word();
            pos = save;
            return w;
        }

        public string word() {
            skip_space();
            int start = pos;
            while (pos < end && is_regular(data[pos])) pos++;
            return slice(start, pos);
        }

        public string slice(int start, int stop) {
            if (stop <= start) return "";
            var buf = new uint8[stop - start + 1];
            Memory.copy(buf, (uint8*) data + start, stop - start);
            buf[stop - start] = 0;
            string s = (string) buf;
            return s.validate() ? s : s.make_valid();
        }

        public static bool parse_int(string s, out int64 value) {
            value = 0;
            if (s.length == 0) return false;
            int i = 0;
            bool neg = false;
            if (s[0] == '+' || s[0] == '-') {
                neg = s[0] == '-';
                i = 1;
                if (s.length == 1) return false;
            }
            for (; i < s.length; i++) {
                if (s[i] < '0' || s[i] > '9') return false;
                value = value * 10 + (s[i] - '0');
            }
            if (neg) value = -value;
            return true;
        }

        public static bool parse_real(string s, out double value) {
            value = 0;
            if (s.length == 0) return false;
            bool digit = false;
            int dots = 0;
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                if (c >= '0' && c <= '9') digit = true;
                else if (c == '.') dots++;
                else if ((c == '-' || c == '+') && i == 0) continue;
                else if (c == '-' && i > 0) continue;
                else return false;
            }
            if (!digit || dots > 1) {
                if (dots >= 1 && !digit) {
                    value = 0;
                    return true;
                }
                return false;
            }
            string clean = s;
            int second_minus = clean.index_of_char('-', 1);
            if (second_minus > 0) clean = clean.substring(0, second_minus);
            value = double.parse(clean);
            return true;
        }

        public Obj parse() throws PdfError {
            skip_space();
            if (pos >= end) throw new PdfError.MALFORMED("unexpected end of data");
            uint8 c = data[pos];
            switch (c) {
                case '/':
                    pos++;
                    return Obj.name_obj(read_name());
                case '(':
                    return Obj.str(read_literal());
                case '<':
                    if (pos + 1 < end && data[pos + 1] == '<') {
                        pos += 2;
                        return read_dict();
                    }
                    return Obj.str(read_hex(), true);
                case '[':
                    pos++;
                    var arr = Obj.array();
                    while (true) {
                        skip_space();
                        if (pos >= end) break;
                        if (data[pos] == ']') {
                            pos++;
                            break;
                        }
                        int before = pos;
                        arr.items.add(parse());
                        if (pos == before) pos++;
                    }
                    return arr;
                case ']':
                case ')':
                case '>':
                case '{':
                case '}':
                    pos++;
                    return Obj.none();
                default:
                    break;
            }
            int start = pos;
            string w = word();
            if (w == "") {
                pos = start + 1;
                return Obj.none();
            }
            if (w == "true") return Obj.boolean(true);
            if (w == "false") return Obj.boolean(false);
            if (w == "null") return Obj.none();
            int64 n;
            if (parse_int(w, out n)) {
                int save = pos;
                string w2 = word();
                int64 g;
                if (parse_int(w2, out g) && g >= 0 && n >= 0) {
                    string w3 = word();
                    if (w3 == "R") return Obj.reference((int) n, (int) g);
                }
                pos = save;
                return Obj.integer(n);
            }
            double r;
            if (parse_real(w, out r)) return Obj.real(r);
            return Obj.keyword(w);
        }

        private Obj read_dict() throws PdfError {
            var d = Obj.dictionary();
            while (true) {
                skip_space();
                if (pos >= end) break;
                if (data[pos] == '>') {
                    pos++;
                    if (pos < end && data[pos] == '>') pos++;
                    break;
                }
                if (data[pos] != '/') {
                    int before = pos;
                    parse();
                    if (pos == before) pos++;
                    continue;
                }
                pos++;
                string key = read_name();
                skip_space();
                if (pos < end && data[pos] == '>') {
                    d.set(key, Obj.none());
                    continue;
                }
                var value = parse();
                if (value.kind == ObjKind.KEYWORD) {
                    if (value.name == "endobj" || value.name == "stream") {
                        pos -= value.name.length;
                        break;
                    }
                    value = Obj.none();
                }
                d.set(key, value);
            }
            return d;
        }

        public string read_name() {
            var b = new ByteArray();
            while (pos < end && is_regular(data[pos])) {
                uint8 c = data[pos];
                if (c == '#' && pos + 2 < end && hexval(data[pos + 1]) >= 0 && hexval(data[pos + 2]) >= 0) {
                    b.append({ (uint8) (hexval(data[pos + 1]) * 16 + hexval(data[pos + 2])) });
                    pos += 3;
                } else {
                    b.append({ c });
                    pos++;
                }
            }
            b.append({ 0 });
            string s = (string) b.data;
            return s.validate() ? s : s.make_valid();
        }

        public static int hexval(uint8 c) {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        }

        public uint8[] read_hex() {
            pos++;
            var b = new ByteArray();
            int hi = -1;
            while (pos < end && data[pos] != '>') {
                int v = hexval(data[pos++]);
                if (v < 0) continue;
                if (hi < 0) {
                    hi = v;
                } else {
                    b.append({ (uint8) (hi * 16 + v) });
                    hi = -1;
                }
            }
            if (hi >= 0) b.append({ (uint8) (hi * 16) });
            if (pos < end) pos++;
            return b.data;
        }

        public uint8[] read_literal() {
            pos++;
            var b = new ByteArray();
            int depth = 1;
            while (pos < end) {
                uint8 c = data[pos++];
                if (c == '\\') {
                    if (pos >= end) break;
                    uint8 e = data[pos++];
                    switch (e) {
                        case 'n': b.append({ '\n' }); break;
                        case 'r': b.append({ '\r' }); break;
                        case 't': b.append({ '\t' }); break;
                        case 'b': b.append({ 8 }); break;
                        case 'f': b.append({ 12 }); break;
                        case '\r':
                            if (pos < end && data[pos] == '\n') pos++;
                            break;
                        case '\n':
                            break;
                        default:
                            if (e >= '0' && e <= '7') {
                                int v = e - '0';
                                for (int k = 0; k < 2 && pos < end && data[pos] >= '0' && data[pos] <= '7'; k++) v = v * 8 + (data[pos++] - '0');
                                b.append({ (uint8) (v & 0xff) });
                            } else {
                                b.append({ e });
                            }
                            break;
                    }
                } else if (c == '(') {
                    depth++;
                    b.append({ c });
                } else if (c == ')') {
                    depth--;
                    if (depth == 0) break;
                    b.append({ c });
                } else {
                    b.append({ c });
                }
            }
            return b.data;
        }

        public static int find(uint8[] d, string needle, int from, int limit = -1) {
            int n = needle.length;
            int stop = (limit < 0 ? d.length : int.min(limit, d.length)) - n;
            uint8 first = needle.data[0];
            for (int i = int.max(0, from); i <= stop; i++) {
                if (d[i] != first) continue;
                bool ok = true;
                for (int k = 1; k < n; k++) {
                    if (d[i + k] != needle.data[k]) {
                        ok = false;
                        break;
                    }
                }
                if (ok) return i;
            }
            return -1;
        }

        public static int rfind(uint8[] d, string needle, int from) {
            int n = needle.length;
            for (int i = int.min(from, d.length - n); i >= 0; i--) {
                bool ok = true;
                for (int k = 0; k < n; k++) {
                    if (d[i + k] != needle.data[k]) {
                        ok = false;
                        break;
                    }
                }
                if (ok) return i;
            }
            return -1;
        }
    }
}
