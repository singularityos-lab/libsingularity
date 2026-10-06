namespace Singularity.Pdf {

    public errordomain PdfError {
        MALFORMED,
        UNSUPPORTED,
        PASSWORD,
        FAILED
    }

    public enum ObjKind {
        NONE,
        BOOL,
        INT,
        REAL,
        STRING,
        NAME,
        ARRAY,
        DICT,
        STREAM,
        REF,
        KEYWORD
    }

    public class Dict {
        public Gee.ArrayList<string> keys = new Gee.ArrayList<string>();
        private Gee.HashMap<string, Obj> map = new Gee.HashMap<string, Obj>();

        public Obj? get(string key) {
            return map[key];
        }

        public void set(string key, Obj value) {
            if (!map.has_key(key)) keys.add(key);
            map[key] = value;
        }

        public bool has(string key) {
            return map.has_key(key);
        }

        public void remove(string key) {
            if (map.has_key(key)) {
                map.unset(key);
                keys.remove(key);
            }
        }

        public int size {
            get { return keys.size; }
        }
    }

    public class Obj {
        public ObjKind kind;
        public bool bool_value;
        public int64 int_value;
        public double real_value;
        public uint8[] bytes;
        public bool hex;
        public string name;
        public Gee.ArrayList<Obj>? items;
        public Dict? dict;
        public int num;
        public int gen;

        public Obj(ObjKind kind) {
            this.kind = kind;
        }

        public static Obj none() {
            return new Obj(ObjKind.NONE);
        }

        public static Obj boolean(bool v) {
            var o = new Obj(ObjKind.BOOL);
            o.bool_value = v;
            return o;
        }

        public static Obj integer(int64 v) {
            var o = new Obj(ObjKind.INT);
            o.int_value = v;
            return o;
        }

        public static Obj real(double v) {
            var o = new Obj(ObjKind.REAL);
            o.real_value = v;
            return o;
        }

        public static Obj number(double v) {
            if (v == Math.floor(v) && v.abs() < 1e15) return integer((int64) v);
            return real(v);
        }

        public static Obj name_obj(string n) {
            var o = new Obj(ObjKind.NAME);
            o.name = n;
            return o;
        }

        public static Obj keyword(string k) {
            var o = new Obj(ObjKind.KEYWORD);
            o.name = k;
            return o;
        }

        public bool is_keyword(string? k = null) {
            return kind == ObjKind.KEYWORD && (k == null || name == k);
        }

        public static Obj str(uint8[] data, bool hex = false) {
            var o = new Obj(ObjKind.STRING);
            o.bytes = data;
            o.hex = hex;
            return o;
        }

        public static Obj text(string s) {
            bool ascii = true;
            for (int i = 0; i < s.length; i++) {
                if (s.data[i] >= 0x80) {
                    ascii = false;
                    break;
                }
            }
            if (ascii) return str(s.data);
            var buf = new ByteArray();
            buf.append({ 0xfe, 0xff });
            int index = 0;
            unichar c;
            while (s.get_next_char(ref index, out c)) {
                if (c > 0xffff) {
                    uint v = c - 0x10000;
                    uint hi = 0xd800 + (v >> 10), lo = 0xdc00 + (v & 0x3ff);
                    buf.append({ (uint8) (hi >> 8), (uint8) hi, (uint8) (lo >> 8), (uint8) lo });
                } else {
                    buf.append({ (uint8) (c >> 8), (uint8) c });
                }
            }
            return str(buf.data);
        }

        public static Obj array() {
            var o = new Obj(ObjKind.ARRAY);
            o.items = new Gee.ArrayList<Obj>();
            return o;
        }

        public static Obj numbers(double[] values) {
            var o = array();
            foreach (var v in values) o.items.add(number(v));
            return o;
        }

        public static Obj names(string[] values) {
            var o = array();
            foreach (var v in values) o.items.add(name_obj(v));
            return o;
        }

        public static Obj dictionary() {
            var o = new Obj(ObjKind.DICT);
            o.dict = new Dict();
            return o;
        }

        public static Obj stream(Dict? d, uint8[] data) {
            var o = new Obj(ObjKind.STREAM);
            o.dict = d ?? new Dict();
            o.bytes = data;
            return o;
        }

        public static Obj reference(int num, int gen = 0) {
            var o = new Obj(ObjKind.REF);
            o.num = num;
            o.gen = gen;
            return o;
        }

        public bool is_none() { return kind == ObjKind.NONE; }
        public bool is_dict() { return kind == ObjKind.DICT || kind == ObjKind.STREAM; }
        public bool is_array() { return kind == ObjKind.ARRAY; }
        public bool is_ref() { return kind == ObjKind.REF; }
        public bool is_number() { return kind == ObjKind.INT || kind == ObjKind.REAL; }
        public bool is_string() { return kind == ObjKind.STRING; }
        public bool is_stream() { return kind == ObjKind.STREAM; }

        public bool is_name(string? n = null) {
            return kind == ObjKind.NAME && (n == null || name == n);
        }

        public double as_number(double fallback = 0) {
            if (kind == ObjKind.INT) return (double) int_value;
            if (kind == ObjKind.REAL) return real_value;
            return fallback;
        }

        public int as_int(int fallback = 0) {
            if (kind == ObjKind.INT) return (int) int_value;
            if (kind == ObjKind.REAL) return (int) real_value;
            return fallback;
        }

        public bool as_bool(bool fallback = false) {
            return kind == ObjKind.BOOL ? bool_value : fallback;
        }

        public Obj? get(string key) {
            return dict != null ? dict.get(key) : null;
        }

        public void set(string key, Obj value) {
            if (dict != null) dict.set(key, value);
        }

        public void remove(string key) {
            if (dict != null) dict.remove(key);
        }

        public bool has(string key) {
            return dict != null && dict.has(key);
        }

        public int length {
            get { return items != null ? items.size : 0; }
        }

        public Obj at(int i) {
            return items != null && i >= 0 && i < items.size ? items[i] : none();
        }

        public void add(Obj v) {
            if (items != null) items.add(v);
        }

        public string text_value() {
            if (kind == ObjKind.NAME) return name;
            if (kind != ObjKind.STRING) return "";
            return decode_text(bytes);
        }

        public static string decode_text(uint8[] b) {
            if (b.length >= 2 && b[0] == 0xfe && b[1] == 0xff) {
                var s = new StringBuilder();
                for (int i = 2; i + 1 < b.length; i += 2) {
                    uint c = ((uint) b[i] << 8) | b[i + 1];
                    if (c >= 0xd800 && c < 0xdc00 && i + 3 < b.length) {
                        uint lo = ((uint) b[i + 2] << 8) | b[i + 3];
                        c = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
                        i += 2;
                    }
                    if (c != 0) s.append_unichar((unichar) c);
                }
                return s.str;
            }
            if (b.length >= 3 && b[0] == 0xef && b[1] == 0xbb && b[2] == 0xbf) {
                var tail = new uint8[b.length - 3 + 1];
                Memory.copy(tail, (uint8*) b + 3, b.length - 3);
                tail[b.length - 3] = 0;
                string s = (string) tail;
                return s.validate() ? s : s.make_valid();
            }
            var s = new StringBuilder();
            foreach (uint8 c in b) s.append_unichar(Encodings.pdfdoc_to_unicode(c));
            return s.str;
        }

        public Obj clone() {
            var o = new Obj(kind);
            o.bool_value = bool_value;
            o.int_value = int_value;
            o.real_value = real_value;
            o.hex = hex;
            o.name = name;
            o.num = num;
            o.gen = gen;
            if (bytes != null) o.bytes = bytes[0 : bytes.length];
            if (items != null) {
                o.items = new Gee.ArrayList<Obj>();
                foreach (var i in items) o.items.add(i.clone());
            }
            if (dict != null) {
                o.dict = new Dict();
                foreach (var k in dict.keys) o.dict.set(k, dict.get(k).clone());
            }
            return o;
        }

        public static string format_number(double v) {
            if (v == Math.floor(v) && v.abs() < 1e15) return "%lld".printf((int64) v);
            if (v.abs() < 0.000001) return "0";
            char[] buf = new char[64];
            string s = v.format(buf, "%.6f");
            if (s.contains(",")) s = s.replace(",", ".");
            while (s.has_suffix("0")) s = s.substring(0, s.length - 1);
            if (s.has_suffix(".")) s = s.substring(0, s.length - 1);
            if (s == "-0") s = "0";
            return s;
        }

        public static string encode_name(string n) {
            var s = new StringBuilder("/");
            for (int i = 0; i < n.length; i++) {
                uint8 c = n.data[i];
                if (c < 0x21 || c > 0x7e || c == '#' || Lexer.is_delimiter(c)) s.append_printf("#%02X", c);
                else s.append_c((char) c);
            }
            return s.str;
        }

        public void write(ByteArray b) {
            switch (kind) {
                case ObjKind.NONE:
                    append(b, "null");
                    break;
                case ObjKind.BOOL:
                    append(b, bool_value ? "true" : "false");
                    break;
                case ObjKind.INT:
                    append(b, int_value.to_string());
                    break;
                case ObjKind.REAL:
                    append(b, format_number(real_value));
                    break;
                case ObjKind.NAME:
                    append(b, encode_name(name));
                    break;
                case ObjKind.KEYWORD:
                    append(b, name);
                    break;
                case ObjKind.STRING:
                    write_string(b, bytes, hex);
                    break;
                case ObjKind.REF:
                    append(b, "%d %d R".printf(num, gen));
                    break;
                case ObjKind.ARRAY:
                    append(b, "[");
                    for (int i = 0; i < items.size; i++) {
                        if (i > 0) append(b, " ");
                        items[i].write(b);
                    }
                    append(b, "]");
                    break;
                case ObjKind.DICT:
                case ObjKind.STREAM:
                    append(b, "<<");
                    foreach (var k in dict.keys) {
                        append(b, encode_name(k));
                        var v = dict.get(k);
                        if (v.kind != ObjKind.ARRAY && v.kind != ObjKind.DICT && v.kind != ObjKind.STRING && v.kind != ObjKind.NAME) append(b, " ");
                        v.write(b);
                    }
                    append(b, ">>");
                    break;
            }
        }

        public static void append(ByteArray b, string s) {
            b.append(s.data);
        }

        public static void write_string(ByteArray b, uint8[] data, bool as_hex) {
            if (as_hex) {
                var s = new StringBuilder("<");
                foreach (uint8 c in data) s.append_printf("%02X", c);
                s.append_c('>');
                append(b, s.str);
                return;
            }
            var out_bytes = new ByteArray();
            out_bytes.append({ '(' });
            foreach (uint8 c in data) {
                switch (c) {
                    case '(':
                    case ')':
                    case '\\':
                        out_bytes.append({ '\\', c });
                        break;
                    case '\n':
                        out_bytes.append({ '\\', 'n' });
                        break;
                    case '\r':
                        out_bytes.append({ '\\', 'r' });
                        break;
                    default:
                        out_bytes.append({ c });
                        break;
                }
            }
            out_bytes.append({ ')' });
            b.append(out_bytes.data);
        }

        public string to_pdf_string() {
            var b = new ByteArray();
            write(b);
            b.append({ 0 });
            return (string) b.data;
        }
    }
}
