namespace Singularity.Pdf {

    public class Pages {
        private const string[] INHERITED = { "Resources", "MediaBox", "CropBox", "Rotate" };

        public static Obj flatten(Document doc) {
            var refs = doc.page_refs();
            var root_ref = doc.catalog().get("Pages");
            Obj root;
            if (root_ref != null && root_ref.is_ref() && doc.resolve(root_ref).is_dict()) {
                root = doc.resolve(root_ref);
            } else {
                root = Obj.dictionary();
                root.set("Type", Obj.name_obj("Pages"));
                root_ref = doc.add_ref(root);
                doc.catalog().set("Pages", root_ref);
            }
            var kids = Obj.array();
            foreach (var r in refs) {
                var p = doc.resolve(r);
                foreach (var key in INHERITED) {
                    if (!p.has(key)) {
                        var v = doc.page_attr(p, key);
                        if (!v.is_none()) p.set(key, v.clone());
                    }
                }
                if (!p.has("MediaBox")) p.set("MediaBox", Obj.numbers({ 0, 0, 612, 792 }));
                if (!p.has("Resources")) p.set("Resources", Obj.dictionary());
                p.set("Parent", root_ref);
                p.set("Type", Obj.name_obj("Page"));
                kids.add(r);
            }
            foreach (var key in INHERITED) root.remove(key);
            root.set("Kids", kids);
            root.set("Count", Obj.integer(kids.length));
            doc.invalidate_pages();
            return root;
        }

        private static void set_kids(Document doc, Gee.List<Obj> list) {
            var root = flatten(doc);
            var kids = Obj.array();
            var root_ref = doc.catalog().get("Pages");
            foreach (var r in list) {
                doc.resolve(r).set("Parent", root_ref);
                kids.add(r);
            }
            root.set("Kids", kids);
            root.set("Count", Obj.integer(kids.length));
            doc.invalidate_pages();
        }

        public static void rotate(Document doc, int[] indices, int degrees) {
            foreach (int i in indices) {
                if (i < 0 || i >= doc.page_count()) continue;
                int r = (doc.page_rotation(i) + degrees) % 360;
                if (r < 0) r += 360;
                doc.page(i).set("Rotate", Obj.integer(r));
            }
        }

        public static void delete(Document doc, int[] indices) {
            flatten(doc);
            var list = new Gee.ArrayList<Obj>();
            var refs = doc.page_refs();
            var removed = new Gee.HashSet<int>();
            for (int i = 0; i < refs.size; i++) {
                if (i in indices) removed.add(refs[i].num);
                else list.add(refs[i]);
            }
            set_kids(doc, list);
            Outline.drop_destinations(doc, removed);
        }

        public static void reorder(Document doc, int[] order) {
            flatten(doc);
            var refs = doc.page_refs();
            var list = new Gee.ArrayList<Obj>();
            foreach (int i in order) {
                if (i >= 0 && i < refs.size) list.add(refs[i]);
            }
            set_kids(doc, list);
        }

        public static void move(Document doc, int from, int to) {
            int n = doc.page_count();
            if (from < 0 || from >= n) return;
            int[] order = {};
            for (int i = 0; i < n; i++) if (i != from) order += i;
            int[] result = {};
            int target = to.clamp(0, n - 1);
            for (int i = 0; i < order.length; i++) {
                if (i == target) result += from;
                result += order[i];
            }
            if (target >= order.length) result += from;
            reorder(doc, result);
        }

        public static void duplicate(Document doc, int index) {
            flatten(doc);
            var refs = doc.page_refs();
            var copy = doc.resolve(refs[index]).clone();
            copy.remove("Annots");
            var r = doc.add_ref(copy);
            var list = new Gee.ArrayList<Obj>();
            for (int i = 0; i < refs.size; i++) {
                list.add(refs[i]);
                if (i == index) list.add(r);
            }
            set_kids(doc, list);
        }

        public static int insert_blank(Document doc, int at, double width, double height) {
            flatten(doc);
            var p = Obj.dictionary();
            p.set("Type", Obj.name_obj("Page"));
            p.set("MediaBox", Obj.numbers({ 0, 0, width, height }));
            p.set("Resources", Obj.dictionary());
            p.set("Contents", doc.add_ref(doc.make_stream(new uint8[0], false)));
            var r = doc.add_ref(p);
            var refs = doc.page_refs();
            var list = new Gee.ArrayList<Obj>();
            list.add_all(refs);
            int pos = at.clamp(0, list.size);
            list.insert(pos, r);
            set_kids(doc, list);
            return pos;
        }

        public static Obj import_page(Document target, Document source, int index, Gee.HashMap<int, int> map) {
            var src = source.page(index);
            var copy = Obj.dictionary();
            foreach (var key in src.dict.keys) {
                if (key == "Parent" || key == "B" || key == "StructParents" || key == "Annots") continue;
                copy.set(key, src.get(key));
            }
            foreach (var key in INHERITED) {
                if (!copy.has(key)) {
                    var v = source.page_attr(src, key);
                    if (!v.is_none()) copy.set(key, v);
                }
            }
            var annots = source.lookup(src, "Annots");
            if (annots.is_array()) {
                var keep = Obj.array();
                for (int i = 0; i < annots.length; i++) {
                    var a = source.resolve(annots.at(i));
                    if (!a.is_dict()) continue;
                    var st = source.lookup(a, "Subtype");
                    if (st.is_name("Link")) {
                        var dest = a.get("Dest");
                        var action = source.resolve(a.get("A"));
                        if (dest != null || (action.is_dict() && source.lookup(action, "S").is_name("GoTo"))) continue;
                    }
                    if (st.is_name("Widget") || st.is_name("Popup")) continue;
                    var ac = a.clone();
                    ac.remove("P");
                    ac.remove("Parent");
                    ac.remove("Popup");
                    ac.remove("IRT");
                    keep.add(ac);
                }
                if (keep.length > 0) copy.set("Annots", keep);
            }
            var imported = target.import_object(source, copy, map);
            imported.set("Type", Obj.name_obj("Page"));
            return target.add_ref(imported);
        }

        public static int[] insert_from(Document doc, Document source, int[] source_pages, int at) {
            flatten(doc);
            var map = new Gee.HashMap<int, int>();
            var added = new Gee.ArrayList<Obj>();
            foreach (int i in source_pages) {
                if (i < 0 || i >= source.page_count()) continue;
                added.add(import_page(doc, source, i, map));
            }
            var list = new Gee.ArrayList<Obj>();
            list.add_all(doc.page_refs());
            int pos = at.clamp(0, list.size);
            int[] result = {};
            for (int k = 0; k < added.size; k++) {
                list.insert(pos + k, added[k]);
                result += pos + k;
            }
            set_kids(doc, list);
            return result;
        }

        public static Document extract(Document source, int[] pages) {
            var doc = new Document();
            doc.version = source.version;
            insert_from(doc, source, pages, 0);
            var info = source.info_if_present();
            if (info != null) {
                var copy = Obj.dictionary();
                foreach (var k in info.dict.keys) {
                    var v = info.get(k);
                    if (!v.is_ref()) copy.set(k, v.clone());
                }
                doc.trailer.set("Info", doc.add_ref(copy));
            }
            return doc;
        }

        public static Gee.ArrayList<Document> split_every(Document source, int count) {
            var result = new Gee.ArrayList<Document>();
            int n = source.page_count();
            int step = int.max(1, count);
            for (int start = 0; start < n; start += step) {
                int[] pages = {};
                for (int i = start; i < int.min(n, start + step); i++) pages += i;
                result.add(extract(source, pages));
            }
            return result;
        }

        public static Gee.ArrayList<Document> split_by_size(Document source, int64 max_bytes) throws Error {
            var result = new Gee.ArrayList<Document>();
            int n = source.page_count();
            int start = 0;
            while (start < n) {
                int end = start + 1;
                var best = extract(source, range(start, end));
                while (end < n) {
                    var candidate = extract(source, range(start, end + 1));
                    var opts = new SaveOptions();
                    opts.garbage_collect = true;
                    if (candidate.save(opts).length > max_bytes) break;
                    best = candidate;
                    end++;
                }
                result.add(best);
                start = end;
            }
            return result;
        }

        public static Gee.ArrayList<Document> split_by_outline(Document source, out string[] titles) {
            var result = new Gee.ArrayList<Document>();
            string[] names = {};
            var starts = new Gee.ArrayList<int>();
            var labels = new Gee.HashMap<int, string>();
            foreach (var item in Outline.read(source)) {
                if (item.page < 0 || labels.has_key(item.page)) continue;
                starts.add(item.page);
                labels[item.page] = item.title;
            }
            starts.sort((a, b) => a - b);
            int n = source.page_count();
            if (starts.size == 0 || starts[0] != 0) {
                starts.insert(0, 0);
                if (!labels.has_key(0)) labels[0] = "";
            }
            for (int i = 0; i < starts.size; i++) {
                int end = i + 1 < starts.size ? starts[i + 1] : n;
                if (end <= starts[i]) continue;
                result.add(extract(source, range(starts[i], end)));
                names += labels[starts[i]];
            }
            titles = names;
            return result;
        }

        public static int[] range(int start, int end) {
            int[] r = {};
            for (int i = start; i < end; i++) r += i;
            return r;
        }

        public static Document merge(Gee.List<Document> sources, string[]? bookmark_titles) {
            var doc = new Document();
            var items = new Gee.ArrayList<OutlineItem>();
            string version = "1.4";
            for (int s = 0; s < sources.size; s++) {
                var src = sources[s];
                if (src.version > version) version = src.version;
                int at = doc.page_count();
                int[] added = insert_from(doc, src, range(0, src.page_count()), at);
                if (bookmark_titles != null && s < bookmark_titles.length && added.length > 0) {
                    var item = new OutlineItem();
                    item.title = bookmark_titles[s];
                    item.page = added[0];
                    foreach (var child in Outline.read(src)) {
                        if (child.page >= 0 && child.depth == 0) {
                            var c = new OutlineItem();
                            c.title = child.title;
                            c.page = at + child.page;
                            c.top = child.top;
                            item.children.add(c);
                        }
                    }
                    items.add(item);
                }
            }
            doc.version = version;
            if (items.size > 0) Outline.write(doc, items);
            return doc;
        }

        public static void set_box(Document doc, int index, string key, Rect box) {
            doc.page(index).set(key, Obj.numbers({ box.x1, box.y1, box.x2, box.y2 }));
        }

        public static void crop(Document doc, int[] indices, double left, double bottom, double right, double top) {
            foreach (int i in indices) {
                var m = doc.page_box(i, "CropBox");
                var r = Rect.of(m[0] + left, m[1] + bottom, m[2] - right, m[3] - top);
                if (r.width() < 1 || r.height() < 1) continue;
                set_box(doc, i, "CropBox", r);
            }
        }

        public static void resize(Document doc, int[] indices, double width, double height, bool scale_content) {
            foreach (int i in indices) {
                var m = doc.page_box(i, "CropBox");
                double w = m[2] - m[0], h = m[3] - m[1];
                var p = doc.page(i);
                if (scale_content && w > 0 && h > 0) {
                    double s = double.min(width / w, height / h);
                    double dx = (width - w * s) / 2 - m[0] * s, dy = (height - h * s) / 2 - m[1] * s;
                    var pre = "q %s 0 0 %s %s %s cm\n".printf(Obj.format_number(s), Obj.format_number(s), Obj.format_number(dx), Obj.format_number(dy));
                    wrap_content(doc, i, pre.data, "\nQ\n".data);
                    Annotations.transform_page_annots(doc, i, Matrix.of(s, 0, 0, s, dx, dy));
                } else {
                    double dx = (width - w) / 2 - m[0], dy = (height - h) / 2 - m[1];
                    if (dx.abs() > 0.01 || dy.abs() > 0.01) {
                        var pre = "q 1 0 0 1 %s %s cm\n".printf(Obj.format_number(dx), Obj.format_number(dy));
                        wrap_content(doc, i, pre.data, "\nQ\n".data);
                        Annotations.transform_page_annots(doc, i, Matrix.of(1, 0, 0, 1, dx, dy));
                    }
                }
                p.set("MediaBox", Obj.numbers({ 0, 0, width, height }));
                p.remove("CropBox");
                p.remove("TrimBox");
                p.remove("BleedBox");
                p.remove("ArtBox");
            }
        }

        public static void wrap_content(Document doc, int index, uint8[] before, uint8[] after) {
            var p = doc.page(index);
            var existing = p.get("Contents");
            var list = Obj.array();
            list.add(doc.add_ref(doc.make_stream(before, false)));
            if (existing != null) {
                var r = doc.resolve(existing);
                if (r.is_array()) {
                    for (int i = 0; i < r.length; i++) list.add(r.at(i));
                } else if (!r.is_none()) {
                    list.add(existing);
                }
            }
            list.add(doc.add_ref(doc.make_stream(after, false)));
            p.set("Contents", list);
        }

        public static string page_label(Document doc, int index) {
            var labels = doc.lookup(doc.catalog(), "PageLabels");
            if (!labels.is_dict()) return (index + 1).to_string();
            var nums = new Gee.ArrayList<Obj>();
            collect_number_tree(doc, labels, nums, 0);
            int start = -1;
            Obj? spec = null;
            for (int i = 0; i + 1 < nums.size; i += 2) {
                int k = nums[i].as_int();
                if (k <= index && k > start) {
                    start = k;
                    spec = doc.resolve(nums[i + 1]);
                }
            }
            if (spec == null || !spec.is_dict()) return (index + 1).to_string();
            int first = doc.lookup(spec, "St").as_int(1);
            int value = first + index - start;
            string prefix = doc.lookup(spec, "P").text_value();
            var style = doc.lookup(spec, "S");
            string body = "";
            if (style.is_name("D")) body = value.to_string();
            else if (style.is_name("R")) body = roman(value).up();
            else if (style.is_name("r")) body = roman(value);
            else if (style.is_name("A")) body = letters(value).up();
            else if (style.is_name("a")) body = letters(value);
            return prefix + body;
        }

        public static void collect_number_tree(Document doc, Obj node, Gee.ArrayList<Obj> out_list, int depth) {
            if (depth > 32) return;
            var nums = doc.lookup(node, "Nums");
            if (nums.is_array()) {
                for (int i = 0; i < nums.length; i++) out_list.add(nums.at(i));
            }
            var kids = doc.lookup(node, "Kids");
            if (kids.is_array()) {
                for (int i = 0; i < kids.length; i++) collect_number_tree(doc, doc.resolve(kids.at(i)), out_list, depth + 1);
            }
        }

        public static string roman(int v) {
            if (v <= 0 || v >= 4000) return v.to_string();
            string[] syms = { "m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i" };
            int[] vals = { 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
            var s = new StringBuilder();
            for (int i = 0; i < vals.length; i++) {
                while (v >= vals[i]) {
                    s.append(syms[i]);
                    v -= vals[i];
                }
            }
            return s.str;
        }

        public static string letters(int v) {
            if (v <= 0) return "";
            int n = (v - 1) / 26 + 1;
            char c = (char) ('a' + (v - 1) % 26);
            return string.nfill(n, c);
        }
    }
}
