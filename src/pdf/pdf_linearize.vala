namespace Singularity.Pdf {

    private class BitWriter {
        public ByteArray bytes = new ByteArray();
        private uint8 cur = 0;
        private int used = 0;

        public void write(int64 value, int bits) {
            for (int i = bits - 1; i >= 0; i--) {
                cur = (uint8) ((cur << 1) | ((value >> i) & 1));
                used++;
                if (used == 8) {
                    bytes.append({ cur });
                    cur = 0;
                    used = 0;
                }
            }
        }

        public void align() {
            if (used > 0) {
                cur = (uint8) (cur << (8 - used));
                bytes.append({ cur });
                cur = 0;
                used = 0;
            }
        }
    }

    public class Linearizer {
        private static int bits_for(int64 v) {
            int b = 0;
            while (v > 0) {
                b++;
                v >>= 1;
            }
            return b;
        }

        private static void reach(Document doc, Obj? o, Gee.HashSet<int> into, Gee.HashSet<int> stop) {
            if (o == null) return;
            var stack = new Gee.ArrayList<Obj>();
            stack.add(o);
            while (stack.size > 0) {
                var cur = stack.remove_at(stack.size - 1);
                switch (cur.kind) {
                    case ObjKind.REF:
                        if (into.contains(cur.num) || stop.contains(cur.num)) break;
                        into.add(cur.num);
                        Obj? t = null;
                        try {
                            t = doc.fetch(cur.num);
                        } catch (Error e) {
                        }
                        if (t != null) stack.add(t);
                        break;
                    case ObjKind.ARRAY:
                        stack.add_all(cur.items);
                        break;
                    case ObjKind.DICT:
                    case ObjKind.STREAM:
                        foreach (var k in cur.dict.keys) {
                            if (k == "Parent" || k == "P" || k == "IRT" || k == "Popup") continue;
                            stack.add(cur.dict.get(k));
                        }
                        break;
                    default:
                        break;
                }
            }
        }

        private static Obj remap(Obj o, Gee.HashMap<int, int> table) {
            switch (o.kind) {
                case ObjKind.REF:
                    return table.has_key(o.num) ? Obj.reference(table[o.num]) : Obj.none();
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

        private static uint8[] serialize(int num, Obj o) {
            var b = new ByteArray();
            Obj.append(b, "%d 0 obj\n".printf(num));
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
            return b.steal();
        }

        public static uint8[] write(Document source) throws Error {
            if (source.security != null) throw new PdfError.UNSUPPORTED("remove the password protection before saving for fast web view");
            var clean_opts = new SaveOptions();
            clean_opts.garbage_collect = true;
            clean_opts.compress_streams = true;
            var doc = Document.open_bytes(source.save(clean_opts));
            doc.load_all();
            var refs = doc.page_refs();
            int npages = refs.size;
            if (npages == 0) throw new PdfError.MALFORMED("the document has no pages");
            var root_ref = doc.trailer.get("Root");
            var cat = doc.catalog();
            var pages_ref = cat.get("Pages");
            var page_nums = new Gee.HashSet<int>();
            foreach (var r in refs) page_nums.add(r.num);
            var assigned = new Gee.HashSet<int>();
            var part4 = new Gee.ArrayList<int>();
            part4.add(root_ref.num);
            assigned.add(root_ref.num);
            if (pages_ref != null && pages_ref.is_ref()) {
                part4.add(pages_ref.num);
                assigned.add(pages_ref.num);
            }
            foreach (var key in new string[] { "ViewerPreferences", "PageMode", "OpenAction", "AcroForm", "Threads" }) {
                var v = cat.get(key);
                if (v == null) continue;
                var found = new Gee.HashSet<int>();
                var stop = new Gee.HashSet<int>();
                stop.add_all(page_nums);
                stop.add_all(assigned);
                reach(doc, v, found, stop);
                foreach (int n in found) {
                    part4.add(n);
                    assigned.add(n);
                }
            }
            var page_objects = new Gee.ArrayList<Gee.ArrayList<int>>();
            for (int i = 0; i < npages; i++) {
                var found = new Gee.HashSet<int>();
                var stop = new Gee.HashSet<int>();
                stop.add_all(assigned);
                foreach (int pn in page_nums) if (pn != refs[i].num) stop.add(pn);
                reach(doc, refs[i], found, stop);
                var list = new Gee.ArrayList<int>();
                list.add(refs[i].num);
                foreach (int n in found) if (n != refs[i].num) list.add(n);
                foreach (int n in list) assigned.add(n);
                page_objects.add(list);
            }
            var rest = new Gee.ArrayList<int>();
            foreach (int n in doc.reachable()) {
                if (!assigned.contains(n)) rest.add(n);
            }
            rest.sort((a, b) => a - b);
            var first_section = new Gee.ArrayList<int>();
            first_section.add_all(part4);
            first_section.add_all(page_objects[0]);
            var second = new Gee.ArrayList<int>();
            for (int i = 1; i < npages; i++) second.add_all(page_objects[i]);
            second.add_all(rest);
            var table = new Gee.HashMap<int, int>();
            int next = 1;
            foreach (int n in second) table[n] = next++;
            int main_size = next;
            int lin_num = next++;
            foreach (int n in part4) table[n] = next++;
            int hint_num = next++;
            foreach (int n in page_objects[0]) table[n] = next++;
            int total = next;
            var t = Obj.dictionary();
            t.set("Size", Obj.integer(total));
            t.set("Root", remap(root_ref, table));
            var info = doc.trailer.get("Info");
            if (info != null && info.is_ref() && table.has_key(info.num)) t.set("Info", Obj.reference(table[info.num]));
            var ids = doc.trailer.get("ID");
            if (ids != null) t.set("ID", ids.clone());
            var part4_bytes = new Gee.ArrayList<Bytes>();
            foreach (int n in part4) part4_bytes.add(new Bytes(serialize(table[n], remap(doc.resolve(Obj.reference(n)), table))));
            var page_bytes = new Gee.ArrayList<Gee.ArrayList<Bytes>>();
            var page_len = new int64[npages];
            for (int i = 0; i < npages; i++) {
                var list = new Gee.ArrayList<Bytes>();
                int64 len = 0;
                foreach (int n in page_objects[i]) {
                    var bytes = new Bytes(serialize(table[n], remap(doc.resolve(Obj.reference(n)), table)));
                    list.add(bytes);
                    len += bytes.length;
                }
                page_bytes.add(list);
                page_len[i] = len;
            }
            var rest_bytes = new Gee.ArrayList<Bytes>();
            var rest_nums = new Gee.ArrayList<int>();
            foreach (int n in rest) {
                rest_bytes.add(new Bytes(serialize(table[n], remap(doc.resolve(Obj.reference(n)), table))));
                rest_nums.add(table[n]);
            }
            int least_objs = int.MAX, most_objs = 0;
            int64 least_len = int64.MAX, most_len = 0;
            for (int i = 0; i < npages; i++) {
                least_objs = int.min(least_objs, page_objects[i].size);
                most_objs = int.max(most_objs, page_objects[i].size);
                least_len = int64.min(least_len, page_len[i]);
                most_len = int64.max(most_len, page_len[i]);
            }
            int obj_bits = bits_for(most_objs - least_objs);
            int len_bits = bits_for(most_len - least_len);
            uint8[] header = "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n".data;
            int64 hint_offset = 0, first_page_offset = 0, end_first = 0, main_xref = 0, t_offset = 0, file_len = 0;
            uint8[] hint_obj = {};
            uint8[] lin_obj = {};
            uint8[] first_xref = {};
            for (int pass = 0; pass < 3; pass++) {
                var bw = new BitWriter();
                bw.write(least_objs, 32);
                bw.write(first_page_offset, 32);
                bw.write(obj_bits, 16);
                bw.write(least_len, 32);
                bw.write(len_bits, 16);
                bw.write(0, 32);
                bw.write(0, 16);
                bw.write(0, 32);
                bw.write(0, 16);
                bw.write(0, 16);
                bw.write(0, 16);
                bw.write(0, 16);
                bw.write(1, 16);
                for (int i = 0; i < npages; i++) bw.write(page_objects[i].size - least_objs, obj_bits);
                bw.align();
                for (int i = 0; i < npages; i++) bw.write(page_len[i] - least_len, len_bits);
                bw.align();
                int shared_offset = (int) bw.bytes.len;
                int groups = page_bytes[0].size;
                int64 least_group = int64.MAX, most_group = 0;
                foreach (var b in page_bytes[0]) {
                    least_group = int64.min(least_group, b.length);
                    most_group = int64.max(most_group, b.length);
                }
                int group_bits = bits_for(most_group - least_group);
                bw.write(table[refs[0].num], 32);
                bw.write(first_page_offset, 32);
                bw.write(groups, 32);
                bw.write(groups, 32);
                bw.write(0, 16);
                bw.write(least_group, 32);
                bw.write(group_bits, 16);
                foreach (var b in page_bytes[0]) bw.write(b.length - least_group, group_bits);
                bw.align();
                foreach (var b in page_bytes[0]) bw.write(0, 1);
                bw.align();
                var hd = new Dict();
                hd.set("S", Obj.integer(shared_offset));
                var hs = Obj.stream(hd, bw.bytes.data);
                hint_obj = serialize(hint_num, hs);
                var lin = Obj.dictionary();
                lin.set("Linearized", Obj.integer(1));
                lin.set("L", Obj.keyword("%010lld".printf(file_len)));
                lin.set("H", Obj.keyword("[%010lld %010d]".printf(hint_offset, hint_obj.length)));
                lin.set("O", Obj.integer(table[refs[0].num]));
                lin.set("E", Obj.keyword("%010lld".printf(end_first)));
                lin.set("N", Obj.integer(npages));
                lin.set("T", Obj.keyword("%010lld".printf(t_offset)));
                lin_obj = serialize(lin_num, lin);
                int64 pos = header.length + lin_obj.length;
                var fx = new ByteArray();
                int first_count = total - lin_num;
                Obj.append(fx, "xref\n%d %d\n".printf(lin_num, first_count));
                int64 first_xref_len_guess = fx.len + first_count * 20;
                var ft = Obj.dictionary();
                foreach (var k in t.dict.keys) ft.set(k, t.get(k));
                ft.set("Prev", Obj.keyword("%010lld".printf(main_xref)));
                var trailer_buf = new ByteArray();
                Obj.append(trailer_buf, "trailer\n");
                ft.write(trailer_buf);
                Obj.append(trailer_buf, "\nstartxref\n0\n%%EOF\n");
                int64 cursor = pos + first_xref_len_guess + trailer_buf.len;
                var offsets = new Gee.HashMap<int, int64?>();
                offsets[lin_num] = header.length;
                foreach (var b in part4_bytes) {
                    string head = (string) b.get_data()[0 : 12];
                    offsets[int.parse(head.split(" ")[0])] = cursor;
                    cursor += b.length;
                }
                hint_offset = cursor;
                offsets[hint_num] = cursor;
                cursor += hint_obj.length;
                first_page_offset = cursor;
                foreach (var b in page_bytes[0]) {
                    string head = (string) b.get_data()[0 : 12];
                    offsets[int.parse(head.split(" ")[0])] = cursor;
                    cursor += b.length;
                }
                end_first = cursor;
                for (int i = 1; i < npages; i++) {
                    foreach (var b in page_bytes[i]) {
                        string head = (string) b.get_data()[0 : 12];
                        offsets[int.parse(head.split(" ")[0])] = cursor;
                        cursor += b.length;
                    }
                }
                foreach (var b in rest_bytes) {
                    string head = (string) b.get_data()[0 : 12];
                    offsets[int.parse(head.split(" ")[0])] = cursor;
                    cursor += b.length;
                }
                main_xref = cursor;
                string main_head = "xref\n0 %d\n".printf(main_size);
                t_offset = main_xref + main_head.length - 1;
                for (int n = lin_num; n < total; n++) {
                    Obj.append(fx, "%010lld 00000 n \n".printf(offsets.has_key(n) ? (int64) offsets[n] : 0));
                }
                fx.append(trailer_buf.data);
                first_xref = fx.steal();
                var main_buf = new ByteArray();
                Obj.append(main_buf, main_head);
                Obj.append(main_buf, "0000000000 65535 f \n");
                for (int n = 1; n < main_size; n++) Obj.append(main_buf, "%010lld 00000 n \n".printf(offsets.has_key(n) ? (int64) offsets[n] : 0));
                var mt = Obj.dictionary();
                mt.set("Size", Obj.integer(main_size));
                Obj.append(main_buf, "trailer\n");
                mt.write(main_buf);
                Obj.append(main_buf, "\nstartxref\n%lld\n%%%%EOF\n".printf(header.length + lin_obj.length));
                file_len = main_xref + main_buf.len;
                if (pass == 2) {
                    var out_buf = new ByteArray();
                    out_buf.append(header);
                    out_buf.append(lin_obj);
                    out_buf.append(first_xref);
                    foreach (var b in part4_bytes) out_buf.append(b.get_data());
                    out_buf.append(hint_obj);
                    foreach (var list in page_bytes) foreach (var b in list) out_buf.append(b.get_data());
                    foreach (var b in rest_bytes) out_buf.append(b.get_data());
                    out_buf.append(main_buf.data);
                    return out_buf.steal();
                }
            }
            return new uint8[0];
        }
    }
}
