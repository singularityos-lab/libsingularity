namespace Singularity.Pdf {

    public class Entry {
        public int num;
        public int gen;
        public int type;
        public int64 offset;
        public int container;
        public int index;
        public Obj? obj;
        public string? original;
        public bool deleted;

        public Entry(int num, int gen) {
            this.num = num;
            this.gen = gen;
        }
    }

    public enum SaveMode {
        FULL,
        INCREMENTAL,
        COMPACT
    }

    public class SaveOptions {
        public SaveMode mode = SaveMode.FULL;
        public bool compress_streams = false;
        public bool garbage_collect = false;
        public bool keep_encryption = true;
        public SecurityHandler? new_security = null;
        public bool remove_security = false;
        public string? version = null;
        public int deflate_level = 6;
    }

    public class Document : Object {
        public uint8[] data;
        public Gee.HashMap<int, Entry> entries = new Gee.HashMap<int, Entry>();
        public Obj trailer = Obj.dictionary();
        public string version = "1.7";
        public SecurityHandler? security = null;
        public int encrypt_num = -1;
        public bool repaired = false;
        public int64 last_xref = -1;
        public bool uses_xref_stream = false;
        public Gee.ArrayList<EmbeddedFont> fonts = new Gee.ArrayList<EmbeddedFont>();
        private Gee.ArrayList<Obj>? page_cache = null;

        public Document() {
            var catalog = Obj.dictionary();
            catalog.set("Type", Obj.name_obj("Catalog"));
            var pages = Obj.dictionary();
            pages.set("Type", Obj.name_obj("Pages"));
            pages.set("Kids", Obj.array());
            pages.set("Count", Obj.integer(0));
            int pages_num = add(pages);
            catalog.set("Pages", Obj.reference(pages_num));
            int cat = add(catalog);
            trailer.set("Root", Obj.reference(cat));
            data = new uint8[0];
        }

        public static Document open_file(string path, string password = "") throws Error {
            uint8[] bytes;
            FileUtils.get_data(path, out bytes);
            return open_bytes(bytes, password);
        }

        public static Document open_bytes(uint8[] bytes, string password = "") throws Error {
            var doc = new Document.empty();
            doc.data = bytes;
            doc.load(password);
            return doc;
        }

        private Document.empty() {
        }

        private void load(string password) throws Error {
            int header = Lexer.find(data, "%PDF-", 0, int.min(data.length, 4096));
            if (header < 0) header = Lexer.find(data, "%FDF-", 0, int.min(data.length, 4096));
            if (header < 0) throw new PdfError.MALFORMED("this is not a PDF file");
            var lx = new Lexer(data, header + 5);
            string v = lx.word();
            if (v.length >= 3) version = v.substring(0, 3);
            bool ok = false;
            try {
                ok = read_xref_chain();
            } catch (Error e) {
                ok = false;
            }
            if (!ok || trailer.get("Root") == null || !resolve(trailer.get("Root")).is_dict()) {
                entries.clear();
                trailer = Obj.dictionary();
                reconstruct();
                repaired = true;
            }
            var enc = trailer.get("Encrypt");
            if (enc != null && !enc.is_none()) {
                if (enc.is_ref()) encrypt_num = enc.num;
                var encrypt = resolve(enc);
                uint8[] id0 = {};
                var ids = trailer.get("ID");
                if (ids != null && ids.is_array() && ids.length > 0) id0 = ids.at(0).bytes;
                security = SecurityHandler.open(encrypt, id0, password);
            }
            var root = catalog();
            var cat_version = root.get("Version");
            if (cat_version != null && cat_version.is_name() && cat_version.name > version) version = cat_version.name;
        }

        private int64 find_startxref() {
            int pos = Lexer.rfind(data, "startxref", data.length - 1);
            if (pos < 0) return -1;
            var lx = new Lexer(data, pos + 9);
            int64 off;
            if (!Lexer.parse_int(lx.word(), out off)) return -1;
            return off;
        }

        private bool read_xref_chain() throws Error {
            int64 offset = find_startxref();
            if (offset < 0 || offset >= data.length) return false;
            last_xref = offset;
            var seen = new Gee.HashSet<int64?>();
            bool first = true;
            while (offset >= 0 && offset < data.length && !seen.contains(offset)) {
                seen.add(offset);
                Obj section_trailer;
                if (!read_xref_at(offset, out section_trailer)) {
                    if (first) return false;
                    break;
                }
                if (first) {
                    foreach (var k in section_trailer.dict.keys) {
                        if (k != "Prev" && k != "XRefStm" && k != "Type" && k != "W" && k != "Index" && k != "Filter"
                                && k != "DecodeParms" && k != "Length") {
                            trailer.set(k, section_trailer.get(k));
                        }
                    }
                    first = false;
                } else {
                    foreach (var k in section_trailer.dict.keys) {
                        if (!trailer.has(k) && (k == "Root" || k == "Info" || k == "ID" || k == "Encrypt")) trailer.set(k, section_trailer.get(k));
                    }
                }
                var stm = section_trailer.get("XRefStm");
                if (stm != null && stm.is_number()) {
                    Obj ignored;
                    read_xref_at(stm.as_int(), out ignored);
                }
                var prev = section_trailer.get("Prev");
                offset = prev != null && prev.is_number() ? (int64) prev.as_number() : -1;
            }
            return trailer.get("Root") != null;
        }

        private bool read_xref_at(int64 offset, out Obj section_trailer) throws Error {
            section_trailer = Obj.dictionary();
            var lx = new Lexer(data, (int) offset);
            lx.skip_space();
            int start = lx.pos;
            string w = lx.word();
            if (w == "xref") {
                while (true) {
                    lx.skip_space();
                    int save = lx.pos;
                    string a = lx.word();
                    if (a == "trailer") break;
                    int64 first = 0, count = 0;
                    if (!Lexer.parse_int(a, out first) || !Lexer.parse_int(lx.word(), out count)) {
                        lx.pos = save;
                        int t = Lexer.find(data, "trailer", save);
                        if (t < 0) return false;
                        lx.pos = t + 7;
                        break;
                    }
                    for (int64 i = 0; i < count; i++) {
                        string off_s = lx.word();
                        string gen_s = lx.word();
                        string type_s = lx.word();
                        int64 off = 0, gen = 0;
                        if (!Lexer.parse_int(off_s, out off) || !Lexer.parse_int(gen_s, out gen)) return false;
                        int num = (int) (first + i);
                        if (entries.has_key(num)) continue;
                        var e = new Entry(num, (int) gen);
                        if (type_s == "n") {
                            e.type = 1;
                            e.offset = off;
                            if (off == 0 && num != 0) e.type = 0;
                        } else {
                            e.type = 0;
                        }
                        entries[num] = e;
                    }
                }
                var t = lx.parse();
                if (!t.is_dict()) return false;
                section_trailer = t;
                return true;
            }
            lx.pos = start;
            int64 num;
            if (!Lexer.parse_int(lx.word(), out num)) return false;
            lx.word();
            if (lx.word() != "obj") return false;
            var obj = lx.parse();
            if (!obj.is_dict() || obj.get("Type") == null || !obj.get("Type").is_name("XRef")) return false;
            var stream = read_stream_body(obj, lx, (int) num, 0, false);
            uses_xref_stream = true;
            uint8[] decoded = Filters.decode(stream, stream.get("Filter"), stream.get("DecodeParms"));
            var wobj = stream.get("W");
            if (wobj == null || !wobj.is_array() || wobj.length < 3) return false;
            int w0 = wobj.at(0).as_int(), w1 = wobj.at(1).as_int(), w2 = wobj.at(2).as_int();
            int row = w0 + w1 + w2;
            if (row <= 0) return false;
            int size = stream.get("Size") != null ? stream.get("Size").as_int() : 0;
            var index = stream.get("Index");
            int[] ranges = {};
            if (index != null && index.is_array()) {
                for (int i = 0; i + 1 < index.length; i += 2) {
                    ranges += index.at(i).as_int();
                    ranges += index.at(i + 1).as_int();
                }
            } else {
                ranges = { 0, size };
            }
            int pos = 0;
            for (int r = 0; r + 1 < ranges.length; r += 2) {
                for (int i = 0; i < ranges[r + 1]; i++) {
                    if (pos + row > decoded.length) break;
                    int64 f0 = w0 == 0 ? 1 : read_be(decoded, pos, w0);
                    int64 f1 = read_be(decoded, pos + w0, w1);
                    int64 f2 = read_be(decoded, pos + w0 + w1, w2);
                    pos += row;
                    int n = ranges[r] + i;
                    if (entries.has_key(n)) continue;
                    var e = new Entry(n, 0);
                    e.type = (int) f0;
                    if (f0 == 1) {
                        e.offset = f1;
                        e.gen = (int) f2;
                    } else if (f0 == 2) {
                        e.container = (int) f1;
                        e.index = (int) f2;
                    }
                    entries[n] = e;
                }
            }
            section_trailer = stream;
            return true;
        }

        private static int64 read_be(uint8[] d, int pos, int width) {
            int64 v = 0;
            for (int i = 0; i < width; i++) v = (v << 8) | d[pos + i];
            return v;
        }

        private void reconstruct() throws Error {
            int pos = 0;
            Obj? last_trailer = null;
            while (pos < data.length) {
                int next = Lexer.find(data, "obj", pos);
                int tpos = Lexer.find(data, "trailer", pos);
                if (tpos >= 0 && (next < 0 || tpos < next)) {
                    var lx = new Lexer(data, tpos + 7);
                    try {
                        var t = lx.parse();
                        if (t.is_dict()) last_trailer = t;
                    } catch (Error e) {
                    }
                    pos = tpos + 7;
                    continue;
                }
                if (next < 0) break;
                pos = next + 3;
                if (next + 3 < data.length && Lexer.is_regular(data[next + 3])) continue;
                int p = next - 1;
                while (p >= 0 && Lexer.is_space(data[p])) p--;
                int gen_end = p + 1;
                while (p >= 0 && data[p] >= '0' && data[p] <= '9') p--;
                int gen_start = p + 1;
                if (gen_start == gen_end) continue;
                while (p >= 0 && Lexer.is_space(data[p])) p--;
                int num_end = p + 1;
                while (p >= 0 && data[p] >= '0' && data[p] <= '9') p--;
                int num_start = p + 1;
                if (num_start == num_end) continue;
                var lx = new Lexer(data);
                int64 num, gen;
                Lexer.parse_int(lx.slice(num_start, num_end), out num);
                Lexer.parse_int(lx.slice(gen_start, gen_end), out gen);
                var e = new Entry((int) num, (int) gen);
                e.type = 1;
                e.offset = num_start;
                entries[(int) num] = e;
            }
            if (last_trailer != null) {
                foreach (var k in last_trailer.dict.keys) {
                    if (k != "Prev" && k != "XRefStm") trailer.set(k, last_trailer.get(k));
                }
            }
            var nums = new Gee.ArrayList<int>();
            nums.add_all(entries.keys);
            foreach (int n in nums) {
                Obj? o = null;
                try {
                    o = fetch(n);
                } catch (Error e) {
                }
                if (o == null || !o.is_dict()) continue;
                var type = o.get("Type");
                if (type != null && type.is_name("ObjStm")) {
                    try {
                        index_object_stream(n);
                    } catch (Error e) {
                    }
                }
                if (type != null && type.is_name("XRef")) {
                    foreach (var k in o.dict.keys) {
                        if ((k == "Root" || k == "Info" || k == "ID" || k == "Encrypt") && !trailer.has(k)) trailer.set(k, o.get(k));
                    }
                }
            }
            if (trailer.get("Root") == null || !resolve(trailer.get("Root")).is_dict()) {
                foreach (var e in entries.values) {
                    Obj? o = null;
                    try {
                        o = fetch(e.num);
                    } catch (Error err) {
                    }
                    if (o != null && o.is_dict() && o.get("Type") != null && o.get("Type").is_name("Catalog")) {
                        trailer.set("Root", Obj.reference(e.num, e.gen));
                        break;
                    }
                }
            }
            if (trailer.get("Root") == null) throw new PdfError.MALFORMED("the document catalog is missing");
        }

        private void index_object_stream(int container) throws Error {
            var stm = fetch(container);
            uint8[] decoded = decode_stream(stm, container);
            int n = stm.get("N") != null ? stm.get("N").as_int() : 0;
            var lx = new Lexer(decoded);
            for (int i = 0; i < n; i++) {
                int64 num = 0, off = 0;
                if (!Lexer.parse_int(lx.word(), out num) || !Lexer.parse_int(lx.word(), out off)) break;
                if (entries.has_key((int) num) && entries[(int) num].type == 1) continue;
                var e = new Entry((int) num, 0);
                e.type = 2;
                e.container = container;
                e.index = i;
                entries[(int) num] = e;
            }
        }

        private Obj read_stream_body(Obj dict, Lexer lx, int num, int gen, bool decrypt) throws Error {
            lx.skip_space();
            int save = lx.pos;
            if (lx.word() != "stream") {
                lx.pos = save;
                return dict;
            }
            int pos = lx.pos;
            if (pos < data.length && data[pos] == '\r') pos++;
            if (pos < data.length && data[pos] == '\n') pos++;
            int length = -1;
            var len_obj = dict.get("Length");
            if (len_obj != null) {
                if (len_obj.is_ref()) {
                    if (len_obj.num != num) {
                        try {
                            length = resolve(len_obj).as_int(-1);
                        } catch (Error e) {
                            length = -1;
                        }
                    }
                } else {
                    length = len_obj.as_int(-1);
                }
            }
            bool valid = length >= 0 && pos + length <= data.length;
            if (valid) {
                var check = new Lexer(data, pos + length);
                check.skip_space();
                if (!(check.pos + 9 <= data.length && Lexer.find(data, "endstream", check.pos, check.pos + 9) == check.pos)) valid = false;
            }
            if (!valid) {
                int endpos = Lexer.find(data, "endstream", pos);
                if (endpos < 0) endpos = data.length;
                int e = endpos;
                if (e > pos && data[e - 1] == '\n') e--;
                if (e > pos && data[e - 1] == '\r') e--;
                length = e - pos;
            }
            var s = Obj.stream(dict.dict, data[pos : pos + length]);
            if (decrypt && security != null && num != encrypt_num) {
                bool skip = false;
                var type = dict.get("Type");
                if (type != null && type.is_name("XRef")) skip = true;
                if (type != null && type.is_name("Metadata") && !security.encrypt_metadata) skip = true;
                var filter = dict.get("Filter");
                if (filter != null && ((filter.is_name("Crypt")) || (filter.is_array() && filter.length > 0 && filter.at(0).is_name("Crypt")))) skip = true;
                if (!skip) s.bytes = security.decrypt(s.bytes, num, gen, false);
            }
            return s;
        }

        private void decrypt_strings(Obj o, int num, int gen) {
            switch (o.kind) {
                case ObjKind.STRING:
                    o.bytes = security.decrypt(o.bytes, num, gen, true);
                    break;
                case ObjKind.ARRAY:
                    foreach (var i in o.items) decrypt_strings(i, num, gen);
                    break;
                case ObjKind.DICT:
                case ObjKind.STREAM:
                    foreach (var k in o.dict.keys) decrypt_strings(o.dict.get(k), num, gen);
                    break;
                default:
                    break;
            }
        }

        public Obj? fetch(int num) throws Error {
            var e = entries[num];
            if (e == null || e.deleted) return null;
            if (e.obj != null) return e.obj;
            if (e.type == 1) {
                if (e.offset < 0 || e.offset >= data.length) return null;
                var lx = new Lexer(data, (int) e.offset);
                int64 n;
                if (!Lexer.parse_int(lx.word(), out n)) {
                    int alt = Lexer.find(data, "%d %d obj".printf(num, e.gen), int.max(0, (int) e.offset - 64), (int) e.offset + 64);
                    if (alt < 0) return null;
                    lx.pos = alt;
                    lx.word();
                }
                lx.word();
                if (lx.word() != "obj") return null;
                var obj = lx.parse();
                if (security != null && num != encrypt_num) decrypt_strings(obj, num, e.gen);
                if (obj.kind == ObjKind.DICT) obj = read_stream_body(obj, lx, num, e.gen, true);
                e.obj = obj;
            } else if (e.type == 2) {
                load_from_object_stream(e);
            } else {
                return null;
            }
            if (e.obj != null) e.original = e.obj.to_pdf_string() + (e.obj.is_stream() ? Checksum.compute_for_data(ChecksumType.MD5, e.obj.bytes) : "");
            return e.obj;
        }

        private void load_from_object_stream(Entry e) throws Error {
            var stm = fetch(e.container);
            if (stm == null || !stm.is_stream()) return;
            uint8[] decoded = decode_stream(stm, e.container);
            int n = stm.get("N") != null ? stm.get("N").as_int() : 0;
            int first = stm.get("First") != null ? stm.get("First").as_int() : 0;
            var lx = new Lexer(decoded);
            int[] nums = new int[n];
            int[] offs = new int[n];
            for (int i = 0; i < n; i++) {
                int64 num = 0, off = 0;
                if (!Lexer.parse_int(lx.word(), out num) || !Lexer.parse_int(lx.word(), out off)) break;
                nums[i] = (int) num;
                offs[i] = (int) off;
            }
            for (int i = 0; i < n; i++) {
                var target = entries[nums[i]];
                if (target == null || target.type != 2 || target.container != e.container || target.obj != null) continue;
                var olx = new Lexer(decoded, first + offs[i]);
                target.obj = olx.parse();
                target.original = target.obj.to_pdf_string();
            }
        }

        public uint8[] decode_stream(Obj stream, int num = -1) throws Error {
            return Filters.decode(stream, resolve(stream.get("Filter")), resolve(stream.get("DecodeParms")));
        }

        public uint8[] stream_data(Obj? o) {
            var s = resolve(o);
            if (!s.is_stream()) return new uint8[0];
            try {
                return decode_stream(s);
            } catch (Error e) {
                return new uint8[0];
            }
        }

        public Obj resolve(Obj? o) {
            var cur = o;
            int depth = 0;
            while (cur != null && cur.is_ref() && depth++ < 32) {
                try {
                    cur = fetch(cur.num);
                } catch (Error e) {
                    cur = null;
                }
            }
            return cur ?? Obj.none();
        }

        public Obj lookup(Obj? dict, string key) {
            var d = resolve(dict);
            if (!d.is_dict()) return Obj.none();
            return resolve(d.get(key));
        }

        public int next_number() {
            int max = 0;
            foreach (int n in entries.keys) max = int.max(max, n);
            int size = trailer.get("Size") != null ? trailer.get("Size").as_int() : 0;
            return int.max(max + 1, size);
        }

        public int add(Obj o) {
            int n = next_number();
            var e = new Entry(n, 0);
            e.type = 1;
            e.obj = o;
            e.original = null;
            entries[n] = e;
            trailer.set("Size", Obj.integer(n + 1));
            return n;
        }

        public Obj add_ref(Obj o) {
            return Obj.reference(add(o));
        }

        public void replace(int num, Obj o) {
            var e = entries[num];
            if (e == null) {
                e = new Entry(num, 0);
                e.type = 1;
                entries[num] = e;
            }
            e.obj = o;
            e.deleted = false;
            if (e.type == 0) e.type = 1;
        }

        public void delete_object(int num) {
            var e = entries[num];
            if (e != null) {
                e.deleted = true;
                e.obj = null;
            }
        }

        public Obj catalog() {
            return resolve(trailer.get("Root"));
        }

        public Obj info() {
            var i = resolve(trailer.get("Info"));
            if (!i.is_dict()) {
                i = Obj.dictionary();
                trailer.set("Info", add_ref(i));
            }
            return i;
        }

        public Obj? info_if_present() {
            var i = resolve(trailer.get("Info"));
            return i.is_dict() ? i : null;
        }

        public void invalidate_pages() {
            page_cache = null;
        }

        public Gee.ArrayList<Obj> page_refs() {
            if (page_cache != null) return page_cache;
            page_cache = new Gee.ArrayList<Obj>();
            var visited = new Gee.HashSet<int>();
            collect_pages(catalog().get("Pages"), visited, 0);
            return page_cache;
        }

        private void collect_pages(Obj? node, Gee.HashSet<int> visited, int depth) {
            if (node == null || depth > 64) return;
            if (node.is_ref()) {
                if (visited.contains(node.num)) return;
                visited.add(node.num);
            }
            var d = resolve(node);
            if (!d.is_dict()) return;
            var type = d.get("Type");
            var kids = resolve(d.get("Kids"));
            if ((type != null && type.is_name("Pages")) || (kids.is_array() && (type == null || !type.is_name("Page")))) {
                for (int i = 0; i < kids.length; i++) collect_pages(kids.at(i), visited, depth + 1);
            } else {
                page_cache.add(node.is_ref() ? node : add_ref(d));
            }
        }

        public int page_count() {
            return page_refs().size;
        }

        public Obj page(int index) {
            return resolve(page_refs()[index]);
        }

        public Obj page_attr(Obj page_dict, string key) {
            var cur = page_dict;
            for (int depth = 0; depth < 32 && cur.is_dict(); depth++) {
                var v = cur.get(key);
                if (v != null) return resolve(v);
                cur = resolve(cur.get("Parent"));
            }
            return Obj.none();
        }

        public double[] page_box(int index, string key = "MediaBox") {
            var p = page(index);
            var box = page_attr(p, key);
            if (!box.is_array() || box.length < 4) {
                if (key != "MediaBox") return page_box(index, "MediaBox");
                return { 0, 0, 612, 792 };
            }
            double x1 = resolve(box.at(0)).as_number(), y1 = resolve(box.at(1)).as_number();
            double x2 = resolve(box.at(2)).as_number(), y2 = resolve(box.at(3)).as_number();
            return { double.min(x1, x2), double.min(y1, y2), double.max(x1, x2), double.max(y1, y2) };
        }

        public int page_rotation(int index) {
            int r = page_attr(page(index), "Rotate").as_int(0) % 360;
            return r < 0 ? r + 360 : r;
        }

        public int page_number_of(int num) {
            var refs = page_refs();
            for (int i = 0; i < refs.size; i++) if (refs[i].num == num) return i;
            return -1;
        }

        public Obj page_resources(int index, bool create = true) {
            var p = page(index);
            var res = p.get("Resources");
            if (res != null) {
                var r = resolve(res);
                if (r.is_dict()) return r;
            }
            var inherited = page_attr(p, "Resources");
            if (inherited.is_dict()) {
                if (!create) return inherited;
                var copy = inherited.clone();
                p.set("Resources", copy);
                return copy;
            }
            var fresh = Obj.dictionary();
            if (create) p.set("Resources", fresh);
            return fresh;
        }

        public Obj sub_dict(Obj parent, string key) {
            var v = parent.get(key);
            if (v != null) {
                var r = resolve(v);
                if (r.is_dict()) return r;
            }
            var d = Obj.dictionary();
            parent.set(key, d);
            return d;
        }

        public Obj sub_array(Obj parent, string key) {
            var v = parent.get(key);
            if (v != null) {
                var r = resolve(v);
                if (r.is_array()) return r;
            }
            var a = Obj.array();
            parent.set(key, a);
            return a;
        }

        public uint8[] page_content(int index) {
            var p = page(index);
            var contents = resolve(p.get("Contents"));
            var b = new ByteArray();
            if (contents.is_stream()) {
                b.append(stream_data(contents));
            } else if (contents.is_array()) {
                for (int i = 0; i < contents.length; i++) {
                    b.append(stream_data(contents.at(i)));
                    b.append({ '\n' });
                }
            }
            return b.steal();
        }

        public Obj make_stream(uint8[] content, bool compress = true, Dict? dict = null) {
            var s = Obj.stream(dict, content);
            if (compress && content.length > 64) {
                try {
                    s.bytes = Filters.deflate(content);
                    s.set("Filter", Obj.name_obj("FlateDecode"));
                } catch (Error e) {
                    s.bytes = content;
                }
            }
            s.set("Length", Obj.integer(s.bytes.length));
            return s;
        }

        public void set_stream_data(Obj stream, uint8[] content, bool compress = true) {
            stream.remove("DecodeParms");
            stream.remove("Filter");
            stream.remove("DL");
            stream.bytes = content;
            if (compress && content.length > 64) {
                try {
                    stream.bytes = Filters.deflate(content);
                    stream.set("Filter", Obj.name_obj("FlateDecode"));
                } catch (Error e) {
                    stream.bytes = content;
                }
            }
            stream.set("Length", Obj.integer(stream.bytes.length));
        }

        public void set_page_content(int index, uint8[] content) {
            var p = page(index);
            p.set("Contents", add_ref(make_stream(content)));
        }

        public void append_page_content(int index, uint8[] content, bool prepend = false) {
            var p = page(index);
            var existing = p.get("Contents");
            var list = Obj.array();
            var q = add_ref(make_stream("q\n".data, false));
            var qq = add_ref(make_stream("\nQ\n".data, false));
            var extra = add_ref(make_stream(content));
            if (prepend) list.add(extra);
            if (existing != null) {
                var r = resolve(existing);
                if (!prepend) list.add(q);
                if (r.is_array()) {
                    for (int i = 0; i < r.length; i++) list.add(r.at(i));
                } else if (existing.is_ref() || r.is_stream()) {
                    list.add(existing);
                }
                if (!prepend) list.add(qq);
            }
            if (!prepend) list.add(extra);
            p.set("Contents", list);
        }

        public void load_all() {
            var nums = new Gee.ArrayList<int>();
            nums.add_all(entries.keys);
            foreach (int n in nums) {
                try {
                    fetch(n);
                } catch (Error e) {
                }
            }
        }

        private void collect_reachable(Obj? o, Gee.HashSet<int> seen) {
            if (o == null) return;
            var stack = new Gee.ArrayList<Obj>();
            stack.add(o);
            while (stack.size > 0) {
                var cur = stack.remove_at(stack.size - 1);
                switch (cur.kind) {
                    case ObjKind.REF:
                        if (seen.contains(cur.num)) break;
                        var e = entries[cur.num];
                        if (e == null || e.deleted) break;
                        seen.add(cur.num);
                        Obj? target = null;
                        try {
                            target = fetch(cur.num);
                        } catch (Error err) {
                        }
                        if (target != null) stack.add(target);
                        break;
                    case ObjKind.ARRAY:
                        stack.add_all(cur.items);
                        break;
                    case ObjKind.DICT:
                    case ObjKind.STREAM:
                        foreach (var k in cur.dict.keys) stack.add(cur.dict.get(k));
                        break;
                    default:
                        break;
                }
            }
        }

        public Gee.HashSet<int> reachable() {
            var seen = new Gee.HashSet<int>();
            collect_reachable(trailer, seen);
            return seen;
        }

        private void encrypt_strings(Obj o, int num, int gen, SecurityHandler sec) {
            switch (o.kind) {
                case ObjKind.STRING:
                    o.bytes = sec.encrypt(o.bytes, num, gen, true);
                    break;
                case ObjKind.ARRAY:
                    foreach (var i in o.items) encrypt_strings(i, num, gen, sec);
                    break;
                case ObjKind.DICT:
                case ObjKind.STREAM:
                    foreach (var k in o.dict.keys) encrypt_strings(o.dict.get(k), num, gen, sec);
                    break;
                default:
                    break;
            }
        }

        private void write_object(ByteArray b, int num, int gen, Obj obj, SecurityHandler? sec, bool compress, int level) {
            var o = obj;
            bool is_meta = o.is_stream() && o.get("Type") != null && o.get("Type").is_name("Metadata");
            bool compress_this = compress && o.is_stream() && o.get("Filter") == null && o.bytes.length > 32;
            if (sec != null || compress_this) o = obj.clone();
            if (compress_this) {
                try {
                    o.bytes = Filters.deflate(o.bytes, level);
                    o.set("Filter", Obj.name_obj("FlateDecode"));
                } catch (Error e) {
                }
            }
            if (sec != null && num != encrypt_num) {
                encrypt_strings(o, num, gen, sec);
                if (o.is_stream() && !(is_meta && !sec.encrypt_metadata)) o.bytes = sec.encrypt(o.bytes, num, gen, false);
            }
            Obj.append(b, "%d %d obj\n".printf(num, gen));
            if (o.is_stream()) {
                o.set("Length", Obj.integer(o.bytes.length));
                o.write(b);
                Obj.append(b, "\nstream\n");
                b.append(o.bytes);
                Obj.append(b, "\nendstream");
            } else {
                o.write(b);
            }
            Obj.append(b, "\nendobj\n");
        }

        private bool changed(Entry e) {
            if (e.obj == null) return e.deleted;
            if (e.original == null) return true;
            string now = e.obj.to_pdf_string() + (e.obj.is_stream() ? Checksum.compute_for_data(ChecksumType.MD5, e.obj.bytes) : "");
            return now != e.original;
        }

        public bool has_changes() {
            foreach (var e in entries.values) {
                if (changed(e)) return true;
            }
            return false;
        }

        private Obj ensure_id() {
            var ids = trailer.get("ID");
            var fresh = Crypto.random_bytes(16);
            if (ids != null && ids.is_array() && ids.length >= 2) {
                var out_ids = Obj.array();
                out_ids.add(ids.at(0));
                out_ids.add(Obj.str(fresh, true));
                return out_ids;
            }
            var created = Obj.array();
            created.add(Obj.str(fresh, true));
            created.add(Obj.str(fresh, true));
            return created;
        }

        public void register_font(EmbeddedFont font) {
            fonts.add(font);
        }

        public void finish_fonts() {
            foreach (var f in fonts) {
                if (f.used.size > 0) f.finish(this);
            }
        }

        public uint8[] save(SaveOptions? options = null) throws Error {
            var opts = options ?? new SaveOptions();
            finish_fonts();
            if (opts.mode == SaveMode.INCREMENTAL && data.length > 0 && opts.new_security == null && !opts.remove_security) return save_incremental();
            return save_full(opts);
        }

        public void save_to_file(string path, SaveOptions? options = null) throws Error {
            uint8[] bytes = save(options);
            string tmp = path + ".part-" + Uuid.string_random().substring(0, 8);
            FileUtils.set_data(tmp, bytes);
            if (FileUtils.rename(tmp, path) != 0) {
                FileUtils.unlink(tmp);
                throw new PdfError.FAILED("could not replace %s", path);
            }
        }

        private uint8[] save_incremental() throws Error {
            var b = new ByteArray();
            b.append(data);
            if (data.length > 0 && data[data.length - 1] != '\n') Obj.append(b, "\n");
            var changed_nums = new Gee.ArrayList<int>();
            foreach (var e in entries.values) {
                if (changed(e)) changed_nums.add(e.num);
            }
            changed_nums.sort((a, c) => a - c);
            var offsets = new Gee.HashMap<int, int64?>();
            foreach (int n in changed_nums) {
                var e = entries[n];
                if (e.deleted || e.obj == null) continue;
                offsets[n] = b.len;
                write_object(b, n, e.gen, e.obj, security, false, 6);
                e.original = e.obj.to_pdf_string() + (e.obj.is_stream() ? Checksum.compute_for_data(ChecksumType.MD5, e.obj.bytes) : "");
            }
            int size = next_number();
            var t = Obj.dictionary();
            foreach (var k in trailer.dict.keys) {
                if (k != "Prev" && k != "XRefStm" && k != "Size") t.set(k, trailer.get(k));
            }
            t.set("Size", Obj.integer(size));
            if (last_xref >= 0) t.set("Prev", Obj.integer(last_xref));
            int64 xref_pos = b.len;
            if (uses_xref_stream) {
                int xnum = size;
                size++;
                t.set("Size", Obj.integer(size));
                offsets[xnum] = xref_pos;
                var nums = new Gee.ArrayList<int>();
                nums.add_all(offsets.keys);
                foreach (int n in changed_nums) if (!nums.contains(n)) nums.add(n);
                nums.sort((a, c) => a - c);
                var rows = new ByteArray();
                var index = Obj.array();
                int i = 0;
                while (i < nums.size) {
                    int start = nums[i];
                    int count = 1;
                    while (i + count < nums.size && nums[i + count] == start + count) count++;
                    index.add(Obj.integer(start));
                    index.add(Obj.integer(count));
                    for (int k = 0; k < count; k++) {
                        int n = nums[i + k];
                        if (offsets.has_key(n)) {
                            int64 off = offsets[n];
                            int g = n == xnum ? 0 : entries[n].gen;
                            rows.append({ 1, (uint8) (off >> 24), (uint8) (off >> 16), (uint8) (off >> 8), (uint8) off, (uint8) g });
                        } else {
                            rows.append({ 0, 0, 0, 0, 0, 1 });
                        }
                    }
                    i += count;
                }
                t.set("Type", Obj.name_obj("XRef"));
                t.set("W", Obj.numbers({ 1, 4, 1 }));
                t.set("Index", index);
                var xs = Obj.stream(t.dict, rows.steal());
                Obj.append(b, "%d 0 obj\n".printf(xnum));
                xs.set("Length", Obj.integer(xs.bytes.length));
                xs.write(b);
                Obj.append(b, "\nstream\n");
                b.append(xs.bytes);
                Obj.append(b, "\nendstream\nendobj\n");
                last_xref = xref_pos;
            } else {
                var nums = new Gee.ArrayList<int>();
                nums.add_all(changed_nums);
                nums.sort((a, c) => a - c);
                Obj.append(b, "xref\n");
                int i = 0;
                if (nums.size == 0) Obj.append(b, "0 0\n");
                while (i < nums.size) {
                    int start = nums[i];
                    int count = 1;
                    while (i + count < nums.size && nums[i + count] == start + count) count++;
                    Obj.append(b, "%d %d\n".printf(start, count));
                    for (int k = 0; k < count; k++) {
                        int n = nums[i + k];
                        if (offsets.has_key(n)) Obj.append(b, "%010lld %05d n \n".printf((int64) offsets[n], entries[n].gen));
                        else Obj.append(b, "%010d %05d f \n".printf(0, int.min(65535, entries[n].gen + 1)));
                    }
                    i += count;
                }
                Obj.append(b, "trailer\n");
                t.write(b);
                Obj.append(b, "\n");
                last_xref = xref_pos;
            }
            Obj.append(b, "startxref\n%lld\n%%%%EOF\n".printf(xref_pos));
            data = b.data;
            return b.steal();
        }

        private uint8[] save_full(SaveOptions opts) throws Error {
            load_all();
            SecurityHandler? sec = null;
            if (opts.new_security != null) sec = opts.new_security;
            else if (!opts.remove_security && opts.keep_encryption && security != null) sec = security;
            Gee.Collection<int> nums;
            if (opts.garbage_collect) nums = reachable();
            else {
                var all = new Gee.ArrayList<int>();
                foreach (var e in entries.values) if (!e.deleted && e.obj != null) all.add(e.num);
                nums = all;
            }
            var sorted = new Gee.ArrayList<int>();
            foreach (int n in nums) {
                if (n == encrypt_num) continue;
                var e = entries[n];
                if (e == null || e.deleted || e.obj == null) continue;
                var type = e.obj.get("Type");
                if (e.obj.is_stream() && type != null && (type.is_name("XRef") || type.is_name("ObjStm"))) continue;
                sorted.add(n);
            }
            sorted.sort((a, c) => a - c);
            var renumber = new Gee.HashMap<int, int>();
            int next = 1;
            foreach (int n in sorted) renumber[n] = next++;
            var remapped = new Gee.HashMap<int, Obj>();
            foreach (int n in sorted) remapped[renumber[n]] = remap(entries[n].obj, renumber);
            var new_trailer = remap(trailer, renumber);
            new_trailer.remove("Prev");
            new_trailer.remove("XRefStm");
            new_trailer.remove("Encrypt");
            new_trailer.remove("DecodeParms");
            new_trailer.remove("Filter");
            new_trailer.remove("Type");
            new_trailer.remove("W");
            new_trailer.remove("Index");
            new_trailer.remove("Length");
            new_trailer.set("ID", ensure_id());
            int enc_new = -1;
            string ver = opts.version ?? version;
            if (sec != null) {
                enc_new = next++;
                if (sec.revision >= 5 && ver < "1.7") ver = "1.7";
                else if (sec.version == 4 && ver < "1.6") ver = "1.6";
                var ids = new_trailer.get("ID");
                sec.id0 = ids.at(0).bytes;
                if (sec != security && sec.revision < 5 && !sec.public_key) {
                    throw new PdfError.UNSUPPORTED("new encryption must use AES-256");
                }
            }
            var saved_enc = encrypt_num;
            encrypt_num = enc_new;
            var b = new ByteArray();
            Obj.append(b, "%PDF-" + ver + "\n");
            b.append({ '%', 0xe2, 0xe3, 0xcf, 0xd3, '\n' });
            var offsets = new int64[next];
            bool use_objstm = opts.mode == SaveMode.COMPACT;
            var in_stream = new Gee.HashMap<int, int>();
            var stream_index = new Gee.HashMap<int, int>();
            int total = next;
            if (use_objstm) {
                var candidates = new Gee.ArrayList<int>();
                for (int n = 1; n < next; n++) {
                    if (n == enc_new) continue;
                    var o = remapped[n];
                    if (o == null || o.is_stream()) continue;
                    candidates.add(n);
                }
                int chunk = 0;
                while (chunk < candidates.size) {
                    int end = int.min(candidates.size, chunk + 100);
                    var head = new StringBuilder();
                    var body = new ByteArray();
                    int container = total++;
                    for (int i = chunk; i < end; i++) {
                        int n = candidates[i];
                        head.append_printf("%d %d ", n, (int) body.len);
                        var ob = new ByteArray();
                        remapped[n].write(ob);
                        body.append(ob.data);
                        body.append({ '\n' });
                        in_stream[n] = container;
                        stream_index[n] = i - chunk;
                    }
                    var content = new ByteArray();
                    content.append(head.str.data);
                    int first = (int) content.len;
                    content.append(body.data);
                    var d = new Dict();
                    d.set("Type", Obj.name_obj("ObjStm"));
                    d.set("N", Obj.integer(end - chunk));
                    d.set("First", Obj.integer(first));
                    remapped[container] = Obj.stream(d, content.steal());
                    chunk = end;
                }
                offsets = new int64[total + 1];
            }
            for (int n = 1; n < total; n++) {
                if (in_stream.has_key(n)) continue;
                Obj? o = n == enc_new ? sec.to_dict() : remapped[n];
                if (o == null) continue;
                offsets[n] = b.len;
                bool is_container = use_objstm && o.is_stream() && o.get("Type") != null && o.get("Type").is_name("ObjStm");
                if (is_container) {
                    var copy = o.clone();
                    try {
                        copy.bytes = Filters.deflate(copy.bytes, opts.deflate_level);
                        copy.set("Filter", Obj.name_obj("FlateDecode"));
                    } catch (Error e) {
                    }
                    if (sec != null) copy.bytes = sec.encrypt(copy.bytes, n, 0, false);
                    Obj.append(b, "%d 0 obj\n".printf(n));
                    copy.set("Length", Obj.integer(copy.bytes.length));
                    copy.write(b);
                    Obj.append(b, "\nstream\n");
                    b.append(copy.bytes);
                    Obj.append(b, "\nendstream\nendobj\n");
                } else {
                    write_object(b, n, 0, o, n == enc_new ? null : sec, opts.compress_streams || use_objstm, opts.deflate_level);
                }
            }
            if (enc_new > 0) new_trailer.set("Encrypt", Obj.reference(enc_new));
            int64 xref_pos = b.len;
            if (use_objstm) {
                int xnum = total;
                total++;
                var rows = new ByteArray();
                var fin = new int64[total];
                for (int n = 0; n < offsets.length && n < total; n++) fin[n] = offsets[n];
                fin[xnum] = xref_pos;
                for (int n = 0; n < total; n++) {
                    if (n == 0) {
                        rows.append({ 0, 0, 0, 0, 0, 0xff, 0xff });
                    } else if (in_stream.has_key(n)) {
                        int c = in_stream[n];
                        int idx = stream_index[n];
                        rows.append({ 2, (uint8) (c >> 24), (uint8) (c >> 16), (uint8) (c >> 8), (uint8) c, (uint8) (idx >> 8), (uint8) idx });
                    } else {
                        int64 off = fin[n];
                        rows.append({ 1, (uint8) (off >> 24), (uint8) (off >> 16), (uint8) (off >> 8), (uint8) off, 0, 0 });
                    }
                }
                new_trailer.set("Type", Obj.name_obj("XRef"));
                new_trailer.set("Size", Obj.integer(total));
                new_trailer.set("W", Obj.numbers({ 1, 4, 2 }));
                uint8[] packed = Filters.deflate(rows.data, 9);
                new_trailer.set("Filter", Obj.name_obj("FlateDecode"));
                new_trailer.set("Length", Obj.integer(packed.length));
                Obj.append(b, "%d 0 obj\n".printf(xnum));
                new_trailer.write(b);
                Obj.append(b, "\nstream\n");
                b.append(packed);
                Obj.append(b, "\nendstream\nendobj\n");
            } else {
                Obj.append(b, "xref\n0 %d\n".printf(total));
                Obj.append(b, "0000000000 65535 f \n");
                for (int n = 1; n < total; n++) {
                    if (offsets[n] > 0) Obj.append(b, "%010lld 00000 n \n".printf(offsets[n]));
                    else Obj.append(b, "0000000000 00001 f \n");
                }
                new_trailer.set("Size", Obj.integer(total));
                Obj.append(b, "trailer\n");
                new_trailer.write(b);
                Obj.append(b, "\n");
            }
            Obj.append(b, "startxref\n%lld\n%%%%EOF\n".printf(xref_pos));
            encrypt_num = saved_enc;
            return b.steal();
        }

        private Obj remap(Obj o, Gee.HashMap<int, int> table) {
            switch (o.kind) {
                case ObjKind.REF:
                    if (table.has_key(o.num)) return Obj.reference(table[o.num]);
                    return Obj.none();
                case ObjKind.ARRAY:
                    var a = Obj.array();
                    foreach (var i in o.items) a.items.add(remap(i, table));
                    return a;
                case ObjKind.DICT:
                case ObjKind.STREAM:
                    var d = new Obj(o.kind);
                    d.dict = new Dict();
                    foreach (var k in o.dict.keys) d.dict.set(k, remap(o.dict.get(k), table));
                    if (o.kind == ObjKind.STREAM) d.bytes = o.bytes;
                    return d;
                default:
                    return o;
            }
        }

        public Obj import_object(Document source, Obj o, Gee.HashMap<int, int> map) {
            switch (o.kind) {
                case ObjKind.REF:
                    if (map.has_key(o.num)) return Obj.reference(map[o.num]);
                    var target = source.resolve(o);
                    int n = add(Obj.none());
                    map[o.num] = n;
                    Obj copy;
                    if (target.is_dict() && target.get("Type") != null && target.get("Type").is_name("Page") && target.has("Parent")) {
                        var shallow = new Obj(target.kind);
                        shallow.dict = new Dict();
                        foreach (var k in target.dict.keys) {
                            if (k == "Parent") continue;
                            shallow.dict.set(k, target.dict.get(k));
                        }
                        shallow.bytes = target.bytes;
                        copy = import_object(source, shallow, map);
                    } else {
                        copy = import_object(source, target, map);
                    }
                    if (copy.is_stream() && source.security != null) {
                        copy.bytes = target.bytes[0 : target.bytes.length];
                    }
                    replace(n, copy);
                    return Obj.reference(n);
                case ObjKind.ARRAY:
                    var a = Obj.array();
                    foreach (var i in o.items) a.items.add(import_object(source, i, map));
                    return a;
                case ObjKind.DICT:
                case ObjKind.STREAM:
                    var d = new Obj(o.kind);
                    d.dict = new Dict();
                    foreach (var k in o.dict.keys) d.dict.set(k, import_object(source, o.dict.get(k), map));
                    if (o.kind == ObjKind.STREAM) d.bytes = o.bytes[0 : o.bytes.length];
                    return d;
                default:
                    return o.clone();
            }
        }
    }
}
