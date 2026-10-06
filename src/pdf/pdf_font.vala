namespace Singularity.Pdf {

    public struct Code {
        public int code;
        public int length;
    }

    public class CMap {
        public Gee.ArrayList<int> range_lengths = new Gee.ArrayList<int>();
        public Gee.ArrayList<uint> range_low = new Gee.ArrayList<uint>();
        public Gee.ArrayList<uint> range_high = new Gee.ArrayList<uint>();
        public Gee.HashMap<int, string> unicode = new Gee.HashMap<int, string>();
        public Gee.HashMap<int, int> cids = new Gee.HashMap<int, int>();
        public bool has_cid_ranges = false;

        private static uint to_uint(uint8[] b) {
            uint v = 0;
            foreach (uint8 c in b) v = (v << 8) | c;
            return v;
        }

        private static string utf16(uint8[] b) {
            if (b.length == 1) return ((unichar) b[0]).to_string();
            var tmp = new uint8[b.length + 2];
            tmp[0] = 0xfe;
            tmp[1] = 0xff;
            for (int i = 0; i < b.length; i++) tmp[i + 2] = b[i];
            return Obj.decode_text(tmp);
        }

        private static uint8[] increment(uint8[] b, uint delta) {
            var r = b[0 : b.length];
            uint carry = delta;
            for (int i = r.length - 1; i >= 0 && carry > 0; i--) {
                uint v = r[i] + carry;
                r[i] = (uint8) (v & 0xff);
                carry = v >> 8;
            }
            return r;
        }

        public static CMap parse(uint8[] data) {
            var map = new CMap();
            var lx = new Lexer(data);
            var stack = new Gee.ArrayList<Obj>();
            while (!lx.at_end()) {
                Obj o;
                try {
                    o = lx.parse();
                } catch (Error e) {
                    break;
                }
                if (o.kind != ObjKind.KEYWORD) {
                    stack.add(o);
                    if (stack.size > 4096) stack.remove_at(0);
                    continue;
                }
                switch (o.name) {
                    case "endcodespacerange":
                        for (int i = 0; i + 1 < stack.size; i += 2) {
                            if (!stack[i].is_string() || !stack[i + 1].is_string()) continue;
                            map.range_lengths.add(stack[i].bytes.length);
                            map.range_low.add(to_uint(stack[i].bytes));
                            map.range_high.add(to_uint(stack[i + 1].bytes));
                        }
                        break;
                    case "endbfchar":
                        for (int i = 0; i + 1 < stack.size; i += 2) {
                            if (!stack[i].is_string()) continue;
                            var dst = stack[i + 1];
                            if (dst.is_string()) map.unicode[(int) to_uint(stack[i].bytes)] = utf16(dst.bytes);
                            else if (dst.is_name()) map.unicode[(int) to_uint(stack[i].bytes)] = ((unichar) Encodings.glyph_to_unicode(dst.name)).to_string();
                        }
                        break;
                    case "endbfrange":
                        for (int i = 0; i + 2 < stack.size; i += 3) {
                            if (!stack[i].is_string() || !stack[i + 1].is_string()) continue;
                            uint lo = to_uint(stack[i].bytes), hi = to_uint(stack[i + 1].bytes);
                            if (hi < lo || hi - lo > 65535) continue;
                            var dst = stack[i + 2];
                            for (uint c = lo; c <= hi; c++) {
                                if (dst.is_string()) {
                                    map.unicode[(int) c] = utf16(increment(dst.bytes, c - lo));
                                } else if (dst.is_array() && (int) (c - lo) < dst.length && dst.at((int) (c - lo)).is_string()) {
                                    map.unicode[(int) c] = utf16(dst.at((int) (c - lo)).bytes);
                                }
                            }
                        }
                        break;
                    case "endcidchar":
                        for (int i = 0; i + 1 < stack.size; i += 2) {
                            if (stack[i].is_string()) map.cids[(int) to_uint(stack[i].bytes)] = stack[i + 1].as_int();
                        }
                        map.has_cid_ranges = true;
                        break;
                    case "endcidrange":
                        for (int i = 0; i + 2 < stack.size; i += 3) {
                            if (!stack[i].is_string() || !stack[i + 1].is_string()) continue;
                            uint lo = to_uint(stack[i].bytes), hi = to_uint(stack[i + 1].bytes);
                            if (hi < lo || hi - lo > 65535) continue;
                            int base_cid = stack[i + 2].as_int();
                            for (uint c = lo; c <= hi; c++) map.cids[(int) c] = base_cid + (int) (c - lo);
                        }
                        map.has_cid_ranges = true;
                        break;
                    default:
                        break;
                }
                if (o.name.has_prefix("begin") || o.name.has_prefix("end") || o.name == "def") stack.clear();
            }
            return map;
        }

        public int code_length(uint8[] s, int pos) {
            if (range_lengths.size == 0) return 2;
            for (int len = 1; len <= 4; len++) {
                if (pos + len > s.length) break;
                uint v = 0;
                for (int k = 0; k < len; k++) v = (v << 8) | s[pos + k];
                for (int r = 0; r < range_lengths.size; r++) {
                    if (range_lengths[r] == len && v >= range_low[r] && v <= range_high[r]) return len;
                }
            }
            int shortest = 4;
            foreach (int l in range_lengths) shortest = int.min(shortest, l);
            return shortest;
        }
    }

    public class FontInfo {
        public string resource_name = "";
        public string subtype = "";
        public string base_font = "";
        public bool is_cid = false;
        public bool is_type3 = false;
        public bool embedded = false;
        public bool subset = false;
        public bool symbolic = false;
        public CMap? encoding_cmap = null;
        public bool identity = true;
        public CMap? to_unicode = null;
        public string[] code_names = new string[256];
        public unichar[] code_unicode = new unichar[256];
        public Gee.HashMap<int, double?> widths = new Gee.HashMap<int, double?>();
        public double default_width = 0;
        public double missing_width = 0;
        public double ascent = 0.8;
        public double descent = -0.2;
        public double[] font_matrix = { 0.001, 0, 0, 0.001, 0, 0 };
        internal Native.FontFile? metrics_file = null;
        public Obj? dict = null;
        internal Native.FontFile? program = null;

        public static FontInfo load(Document doc, Obj font_ref, string name) {
            var f = new FontInfo();
            f.resource_name = name;
            var d = doc.resolve(font_ref);
            f.dict = d;
            if (!d.is_dict()) return f;
            var st = doc.lookup(d, "Subtype");
            f.subtype = st.is_name() ? st.name : "";
            var bf = doc.lookup(d, "BaseFont");
            f.base_font = bf.is_name() ? bf.name : "";
            f.subset = f.base_font.length > 7 && f.base_font[6] == '+';
            var tu = doc.lookup(d, "ToUnicode");
            if (tu.is_stream()) f.to_unicode = CMap.parse(doc.stream_data(tu));
            if (f.subtype == "Type0") {
                f.is_cid = true;
                var enc = doc.lookup(d, "Encoding");
                if (enc.is_stream()) {
                    f.encoding_cmap = CMap.parse(doc.stream_data(enc));
                    f.identity = !f.encoding_cmap.has_cid_ranges;
                } else if (enc.is_name()) {
                    f.identity = enc.name == "Identity-H" || enc.name == "Identity-V";
                }
                var descendants = doc.lookup(d, "DescendantFonts");
                var cid = descendants.is_array() ? doc.resolve(descendants.at(0)) : Obj.none();
                if (cid.is_dict()) {
                    f.default_width = doc.lookup(cid, "DW").as_number(1000);
                    var w = doc.lookup(cid, "W");
                    if (w.is_array()) {
                        int i = 0;
                        while (i < w.length) {
                            int first = doc.resolve(w.at(i)).as_int();
                            var next = doc.resolve(w.at(i + 1));
                            if (next.is_array()) {
                                for (int k = 0; k < next.length; k++) f.widths[first + k] = doc.resolve(next.at(k)).as_number();
                                i += 2;
                            } else {
                                int last = next.as_int();
                                double width = doc.resolve(w.at(i + 2)).as_number();
                                for (int c = first; c <= last && c - first < 65536; c++) f.widths[c] = width;
                                i += 3;
                            }
                        }
                    }
                    f.read_descriptor(doc, doc.lookup(cid, "FontDescriptor"));
                }
            } else {
                f.is_type3 = f.subtype == "Type3";
                if (f.is_type3) {
                    var fm = doc.lookup(d, "FontMatrix");
                    if (fm.is_array() && fm.length >= 6) {
                        for (int i = 0; i < 6; i++) f.font_matrix[i] = doc.resolve(fm.at(i)).as_number();
                    }
                }
                int first = doc.lookup(d, "FirstChar").as_int(0);
                var widths = doc.lookup(d, "Widths");
                if (widths.is_array()) {
                    for (int i = 0; i < widths.length; i++) f.widths[first + i] = doc.resolve(widths.at(i)).as_number();
                }
                f.read_descriptor(doc, doc.lookup(d, "FontDescriptor"));
                f.build_simple_encoding(doc, d);
                if (!widths.is_array() && !f.is_type3) f.load_standard_metrics();
            }
            return f;
        }

        private void read_descriptor(Document doc, Obj fd) {
            if (!fd.is_dict()) return;
            missing_width = doc.lookup(fd, "MissingWidth").as_number(0);
            double a = doc.lookup(fd, "Ascent").as_number(0), de = doc.lookup(fd, "Descent").as_number(0);
            if (a > 0) ascent = a / 1000;
            if (de < 0) descent = de / 1000;
            int flags = doc.lookup(fd, "Flags").as_int(0);
            symbolic = (flags & 4) != 0 && (flags & 32) == 0;
            foreach (var key in new string[] { "FontFile", "FontFile2", "FontFile3" }) {
                var ff = doc.lookup(fd, key);
                if (ff.is_stream()) {
                    embedded = true;
                    if (key == "FontFile2" || (key == "FontFile3" && doc.lookup(ff, "Subtype").is_name("OpenType"))) {
                        program = Native.FontFile.open_data(doc.stream_data(ff), 0);
                    }
                }
            }
        }

        private void build_simple_encoding(Document doc, Obj d) {
            var enc = doc.lookup(d, "Encoding");
            string base_enc = "";
            Obj? diffs = null;
            if (enc.is_name()) base_enc = enc.name;
            else if (enc.is_dict()) {
                var be = doc.lookup(enc, "BaseEncoding");
                if (be.is_name()) base_enc = be.name;
                var df = doc.lookup(enc, "Differences");
                if (df.is_array()) diffs = df;
            }
            for (int c = 0; c < 256; c++) {
                unichar u;
                switch (base_enc) {
                    case "WinAnsiEncoding": u = Encodings.win_to_unicode((uint8) c); break;
                    case "MacRomanEncoding": u = Encodings.mac_to_unicode((uint8) c); break;
                    case "StandardEncoding": u = Encodings.standard_to_unicode((uint8) c); break;
                    default:
                        u = symbolic || is_type3 ? (unichar) c : (base_font.contains("Symbol") || base_font.contains("Dingbats") ? (unichar) c : Encodings.standard_to_unicode((uint8) c));
                        if (base_enc == "" && !symbolic && !embedded) u = Encodings.win_to_unicode((uint8) c);
                        break;
                }
                code_unicode[c] = u;
            }
            if (diffs != null) {
                int code = 0;
                for (int i = 0; i < diffs.length; i++) {
                    var item = doc.resolve(diffs.at(i));
                    if (item.is_number()) {
                        code = item.as_int();
                    } else if (item.is_name() && code >= 0 && code < 256) {
                        code_names[code] = item.name;
                        unichar u = Encodings.glyph_to_unicode(item.name);
                        if (u != 0) code_unicode[code] = u;
                        code++;
                    }
                }
            }
        }

        public static string? standard_family(string base_name) {
            string b = base_name.length > 7 && base_name[6] == '+' ? base_name.substring(7) : base_name;
            string l = b.down();
            bool bold = l.contains("bold");
            bool italic = l.contains("italic") || l.contains("oblique");
            string style = bold && italic ? ":bold:italic" : (bold ? ":bold" : (italic ? ":italic" : ""));
            if (l.has_prefix("helvetica") || l.has_prefix("arial")) return "Liberation Sans,Arimo,Arial,Nimbus Sans,Helvetica" + style;
            if (l.has_prefix("times")) return "Liberation Serif,Tinos,Times New Roman,Nimbus Roman,Times" + style;
            if (l.has_prefix("courier")) return "Liberation Mono,Cousine,Courier New,Nimbus Mono PS,Courier" + style;
            if (l.has_prefix("symbol")) return "Standard Symbols PS,Symbol";
            if (l.has_prefix("zapfdingbats")) return "D050000L,Dingbats";
            return null;
        }

        private void load_standard_metrics() {
            string? family = standard_family(base_font);
            if (family == null) family = "sans-serif";
            int index;
            string? path = Native.font_match(family.split(",")[0] + (family.contains(":") ? family.substring(family.index_of(":")) : ""), out index);
            if (path == null) return;
            metrics_file = Native.FontFile.open(path, index);
        }

        public Gee.ArrayList<Code?> decode(uint8[] s) {
            var list = new Gee.ArrayList<Code?>();
            int i = 0;
            while (i < s.length) {
                int len = 1;
                if (is_cid) len = encoding_cmap != null ? encoding_cmap.code_length(s, i) : 2;
                if (i + len > s.length) len = s.length - i;
                int code = 0;
                for (int k = 0; k < len; k++) code = (code << 8) | s[i + k];
                list.add({ code, len });
                i += len;
            }
            return list;
        }

        public int cid_for(int code) {
            if (!is_cid || identity || encoding_cmap == null) return code;
            return encoding_cmap.cids.has_key(code) ? encoding_cmap.cids[code] : 0;
        }

        public double width(int code) {
            int key = is_cid ? cid_for(code) : code;
            if (widths.has_key(key)) {
                double w = widths[key];
                return is_type3 ? w * font_matrix[0] * 1000 : w;
            }
            if (is_cid) return default_width;
            if (metrics_file != null) {
                unichar u = code_unicode[code & 0xff];
                uint g = metrics_file.glyph(u);
                if (g != 0) return metrics_file.advance(g) * 1000.0 / metrics_file.upem();
                if (base_font.down().contains("courier")) return 600;
            }
            if (base_font.down().contains("courier")) return 600;
            return missing_width > 0 ? missing_width : (widths.size == 0 && metrics_file == null ? 500 : missing_width);
        }

        public string unicode(int code) {
            if (to_unicode != null && to_unicode.unicode.has_key(code)) return to_unicode.unicode[code];
            if (is_cid) return "";
            unichar u = code_unicode[code & 0xff];
            if (u == 0) return "";
            return u.to_string();
        }

        public int encode_char(unichar u) {
            if (is_cid) {
                if (to_unicode != null) {
                    foreach (var e in to_unicode.unicode.entries) {
                        if (e.value == u.to_string()) return e.key;
                    }
                }
                if (program != null && identity) {
                    uint g = program.glyph(u);
                    if (g != 0) return (int) g;
                }
                return -1;
            }
            if (to_unicode != null) {
                foreach (var e in to_unicode.unicode.entries) {
                    if (e.value == u.to_string() && e.key < 256) return e.key;
                }
            }
            for (int c = 0; c < 256; c++) {
                if (code_unicode[c] == u && u != 0) return c;
            }
            return -1;
        }

        public bool has_glyph(unichar u) {
            int code = encode_char(u);
            if (code < 0) return false;
            if (u == ' ') return true;
            if (is_cid) {
                int cid = cid_for(code);
                if (widths.size > 0 && !widths.has_key(cid) && subset) return false;
                return true;
            }
            if (widths.size > 0) {
                if (!widths.has_key(code)) return false;
                if (widths[code] <= 0 && subset) return false;
            }
            if (subset && program != null) {
                uint g = program.glyph(u);
                if (g == 0 && to_unicode != null && !to_unicode.unicode.has_key(code)) return false;
            }
            return true;
        }

        public uint8[] encode(string text, out bool complete) {
            var b = new ByteArray();
            complete = true;
            int i = 0;
            unichar u;
            while (text.get_next_char(ref i, out u)) {
                int code = has_glyph(u) ? encode_char(u) : -1;
                if (code < 0) {
                    complete = false;
                    continue;
                }
                if (is_cid) b.append({ (uint8) (code >> 8), (uint8) code });
                else b.append({ (uint8) code });
            }
            return b.steal();
        }

        public string family_hint() {
            string b = subset ? base_font.substring(7) : base_font;
            string l = b.down();
            string style = "";
            if (l.contains("bold") || l.contains("black") || l.contains("heavy")) style += ":bold";
            if (l.contains("italic") || l.contains("oblique")) style += ":italic";
            var std = standard_family(b);
            if (std != null) return std.split(",")[0] + style;
            int dash = b.index_of_char('-');
            int comma = b.index_of_char(',');
            int cut = dash > 0 ? dash : (comma > 0 ? comma : b.length);
            string fam = b.substring(0, cut);
            foreach (var suffix in new string[] { "MT", "PS", "Std", "Pro", "LT" }) {
                if (fam.has_suffix(suffix) && fam.length > suffix.length + 2) fam = fam.substring(0, fam.length - suffix.length);
            }
            string? found = Native.font_find_family(fam);
            if (found != null) return found + style;
            var spaced = new StringBuilder();
            for (int i = 0; i < fam.length; i++) {
                if (i > 0 && fam[i].isupper() && fam[i - 1].islower()) spaced.append_c(' ');
                spaced.append_c(fam[i]);
            }
            string serif = symbolic ? "" : (l.contains("serif") && !l.contains("sans") ? ",serif" : "");
            return spaced.str + serif + style;
        }
    }

    public class EmbeddedFont {
        internal Native.FontFile file;
        public string postscript_name;
        public string resource_name = "";
        public Obj font_ref;
        public Gee.TreeMap<uint, unichar> used = new Gee.TreeMap<uint, unichar>();
        public bool cff;
        public double ascent;
        public double descent;
        public double cap_height;
        public double[] bbox;
        public string path;

        public static EmbeddedFont? for_pattern(Document doc, string pattern) {
            int index;
            string? path = Native.font_match(pattern, out index);
            if (path == null) return null;
            var f = Native.FontFile.open(path, index);
            if (f == null) return null;
            var e = new EmbeddedFont();
            e.path = path;
            e.file = (owned) f;
            e.cff = e.file.is_cff();
            e.postscript_name = e.file.postscript_name();
            int a, d, c, x1, y1, x2, y2;
            e.file.metrics(out a, out d, out c, out x1, out y1, out x2, out y2);
            double k = 1000.0 / e.file.upem();
            e.ascent = a * k;
            e.descent = d * k;
            e.cap_height = c * k;
            e.bbox = { x1 * k, y1 * k, x2 * k, y2 * k };
            e.font_ref = doc.add_ref(Obj.dictionary());
            doc.register_font(e);
            return e;
        }

        public double advance(unichar u) {
            uint g = file.glyph(u);
            if (g == 0) return 0;
            return file.advance(g) * 1000.0 / file.upem();
        }

        public bool covers(string text) {
            int i = 0;
            unichar u;
            while (text.get_next_char(ref i, out u)) {
                if (u == ' ' || u == '\t' || u == '\n') continue;
                if (file.glyph(u) == 0) return false;
            }
            return true;
        }

        public double measure(string text, double size) {
            double w = 0;
            int i = 0;
            unichar u;
            while (text.get_next_char(ref i, out u)) w += advance(u);
            return w * size / 1000;
        }

        public uint8[] encode(string text) {
            var b = new ByteArray();
            int i = 0;
            unichar u;
            while (text.get_next_char(ref i, out u)) {
                uint g = file.glyph(u);
                if (g == 0 && u != ' ') g = file.glyph('?');
                if (!used.has_key(g)) used[g] = u;
                b.append({ (uint8) (g >> 8), (uint8) g });
            }
            return b.steal();
        }

        public string hex(string text) {
            var s = new StringBuilder("<");
            foreach (uint8 c in encode(text)) s.append_printf("%02X", c);
            s.append_c('>');
            return s.str;
        }

        public void finish(Document doc) {
            var glyphs = new uint[used.size];
            int n = 0;
            foreach (uint g in used.keys) glyphs[n++] = g;
            var sub = file.subset(glyphs);
            uint8[] program = sub != null ? sub.get_data() : file.data().get_data();
            string tag = "";
            uint32 hash = str_hash(postscript_name + n.to_string() + program.length.to_string());
            for (int i = 0; i < 6; i++) {
                tag += ((char) ('A' + hash % 26)).to_string();
                hash /= 26;
            }
            string name = tag + "+" + postscript_name;
            var fd = Obj.dictionary();
            fd.set("Type", Obj.name_obj("FontDescriptor"));
            fd.set("FontName", Obj.name_obj(name));
            fd.set("Flags", Obj.integer(32));
            fd.set("FontBBox", Obj.numbers(bbox));
            fd.set("ItalicAngle", Obj.integer(0));
            fd.set("Ascent", Obj.number(Math.round(ascent)));
            fd.set("Descent", Obj.number(Math.round(descent)));
            fd.set("CapHeight", Obj.number(Math.round(cap_height)));
            fd.set("StemV", Obj.integer(80));
            var ff = doc.make_stream(program, true);
            if (cff) {
                ff.set("Subtype", Obj.name_obj("OpenType"));
                fd.set("FontFile3", doc.add_ref(ff));
            } else {
                ff.set("Length1", Obj.integer(program.length));
                fd.set("FontFile2", doc.add_ref(ff));
            }
            var cid = Obj.dictionary();
            cid.set("Type", Obj.name_obj("Font"));
            cid.set("Subtype", Obj.name_obj(cff ? "CIDFontType0" : "CIDFontType2"));
            cid.set("BaseFont", Obj.name_obj(name));
            var info = Obj.dictionary();
            info.set("Registry", Obj.str("Adobe".data));
            info.set("Ordering", Obj.str("Identity".data));
            info.set("Supplement", Obj.integer(0));
            cid.set("CIDSystemInfo", info);
            cid.set("FontDescriptor", doc.add_ref(fd));
            cid.set("DW", Obj.integer(1000));
            var w = Obj.array();
            foreach (uint g in used.keys) {
                w.add(Obj.integer(g));
                var one = Obj.array();
                one.add(Obj.number(Math.round(file.advance(g) * 1000.0 / file.upem())));
                w.add(one);
            }
            cid.set("W", w);
            if (!cff) cid.set("CIDToGIDMap", Obj.name_obj("Identity"));
            var font = doc.resolve(font_ref);
            font.set("Type", Obj.name_obj("Font"));
            font.set("Subtype", Obj.name_obj("Type0"));
            font.set("BaseFont", Obj.name_obj(name));
            font.set("Encoding", Obj.name_obj("Identity-H"));
            var desc = Obj.array();
            desc.add(doc.add_ref(cid));
            font.set("DescendantFonts", desc);
            var cmap = new StringBuilder();
            cmap.append("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n");
            cmap.append("/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
            var entries = new Gee.ArrayList<uint>();
            entries.add_all(used.keys);
            for (int start = 0; start < entries.size; start += 100) {
                int end = int.min(entries.size, start + 100);
                cmap.append_printf("%d beginbfchar\n", end - start);
                for (int i = start; i < end; i++) {
                    uint g = entries[i];
                    unichar u = used[g];
                    string utf16 = "";
                    if (u > 0xffff) {
                        uint v = u - 0x10000;
                        utf16 = "%04X%04X".printf(0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff));
                    } else {
                        utf16 = "%04X".printf((uint) u);
                    }
                    cmap.append_printf("<%04X> <%s>\n", g, utf16);
                }
                cmap.append("endbfchar\n");
            }
            cmap.append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
            font.set("ToUnicode", doc.add_ref(doc.make_stream(cmap.str.data)));
        }
    }
}
