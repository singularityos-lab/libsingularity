namespace Singularity.Pdf {

    public class TagNode {
        public Obj reference;
        public Obj dict;
        public string role = "";
        public int page = -1;
        public string text = "";
        public string alt = "";
        public int depth = 0;
    }

    public class Tags {
        private static string normalize(string s) {
            var b = new StringBuilder();
            int i = 0;
            unichar c;
            while (s.get_next_char(ref i, out c)) {
                if (c.isdigit()) b.append_c('#');
                else if (!c.isspace()) b.append_unichar(c.tolower());
            }
            return b.str;
        }

        private static Gee.HashSet<string> repeated_margins(Document doc, Gee.ArrayList<Gee.ArrayList<TextBlock>> pages) {
            var counts = new Gee.HashMap<string, int>();
            for (int p = 0; p < pages.size; p++) {
                var box = doc.page_box(p);
                double h = box[3] - box[1];
                var seen = new Gee.HashSet<string>();
                foreach (var b in pages[p]) {
                    if (b.box.y1 > box[3] - h * 0.08 || b.box.y2 < box[1] + h * 0.08) {
                        string key = normalize(b.text());
                        if (key == "" || seen.contains(key)) continue;
                        seen.add(key);
                        counts[key] = (counts.has_key(key) ? counts[key] : 0) + 1;
                    }
                }
            }
            var result = new Gee.HashSet<string>();
            foreach (var e in counts.entries) {
                if (pages.size >= 2 && e.value >= int.max(2, pages.size / 2)) result.add(e.key);
                else if (e.key.replace("#", "") == "" || e.key.replace("#", "").replace("page", "").replace("of", "").replace("/", "") == "") result.add(e.key);
            }
            return result;
        }

        private static Gee.ArrayList<Op> strip_marks(Gee.ArrayList<Op> ops) {
            var out_ops = new Gee.ArrayList<Op>();
            var stack = new Gee.ArrayList<bool>();
            foreach (var op in ops) {
                if (op.name == "BDC" || op.name == "BMC") {
                    bool drop = false;
                    if (op.args.size > 0 && op.args[0].is_name("Artifact")) drop = true;
                    else if (op.name == "BDC" && op.args.size > 1 && op.args[1].is_dict() && op.args[1].has("MCID")) drop = true;
                    else if (op.name == "BDC" && op.args.size > 1 && op.args[1].is_name() && !op.args[0].is_name("OC")) drop = true;
                    else if (op.name == "BMC" && !(op.args.size > 0 && (op.args[0].is_name("Tx") || op.args[0].is_name("OC")))) drop = true;
                    stack.add(drop);
                    if (drop) continue;
                } else if (op.name == "EMC") {
                    bool drop = stack.size > 0 ? stack.remove_at(stack.size - 1) : true;
                    if (drop) continue;
                }
                out_ops.add(op);
            }
            return out_ops;
        }

        private static double median_size(Gee.ArrayList<Gee.ArrayList<TextBlock>> pages) {
            var sizes = new Gee.ArrayList<double?>();
            foreach (var list in pages) foreach (var b in list) {
                int n = b.text().char_count();
                for (int i = 0; i < int.min(n, 200); i += 20) sizes.add(b.size);
            }
            if (sizes.size == 0) return 11;
            sizes.sort((a, b) => a < b ? -1 : (a > b ? 1 : 0));
            return sizes[sizes.size / 2];
        }

        public static int auto_tag(Document doc, string language, string title) {
            doc.load_all();
            var cat = doc.catalog();
            var pages = new Gee.ArrayList<Gee.ArrayList<TextBlock>>();
            var interps = new Gee.ArrayList<Interpreter>();
            for (int p = 0; p < doc.page_count(); p++) {
                var it = new Interpreter(doc);
                it.run_page(p);
                it.ops = strip_marks(it.ops);
                it.run_ops(it.ops, it.resources);
                it.page_index = p;
                interps.add(it);
                pages.add(Editor.blocks_from(it, p));
            }
            var margins = repeated_margins(doc, pages);
            double body = median_size(pages);
            var root = Obj.dictionary();
            root.set("Type", Obj.name_obj("StructTreeRoot"));
            var root_ref = doc.add_ref(root);
            var document = Obj.dictionary();
            document.set("Type", Obj.name_obj("StructElem"));
            document.set("S", Obj.name_obj("Document"));
            document.set("P", root_ref);
            var doc_ref = doc.add_ref(document);
            var doc_kids = Obj.array();
            var nums = Obj.array();
            int elements = 0;
            var refs = doc.page_refs();
            for (int p = 0; p < pages.size; p++) {
                var it = interps[p];
                var page_ref = refs[p];
                var before = new Gee.HashMap<int, Gee.ArrayList<Op>>();
                var after = new Gee.HashMap<int, Gee.ArrayList<Op>>();
                var op_elem = new Gee.HashMap<int, Obj>();
                var parent_list = new Gee.ArrayList<Obj>();
                var wrapped = new Gee.HashSet<int>();
                var block_of_op = new Gee.HashMap<int, int>();
                var box = doc.page_box(p);
                double h = box[3] - box[1];
                var block_elems = new Gee.ArrayList<Obj?>();
                for (int bi = 0; bi < pages[p].size; bi++) {
                    var b = pages[p][bi];
                    string key = normalize(b.text());
                    bool margin = (b.box.y1 > box[3] - h * 0.08 || b.box.y2 < box[1] + h * 0.08) && margins.contains(key);
                    foreach (var item in b.items()) block_of_op[item.top_op] = margin ? -1 : bi;
                    if (margin) {
                        block_elems.add(null);
                        continue;
                    }
                    string role = "P";
                    if (b.size >= body * 1.5 && b.lines.size <= 3) role = "H1";
                    else if (b.size >= body * 1.18 && b.lines.size <= 3) role = "H2";
                    b.role = role;
                    var e = Obj.dictionary();
                    e.set("Type", Obj.name_obj("StructElem"));
                    e.set("S", Obj.name_obj(role));
                    e.set("P", doc_ref);
                    e.set("Pg", page_ref);
                    e.set("K", Obj.array());
                    var er = doc.add_ref(e);
                    block_elems.add(er);
                    doc_kids.add(er);
                    elements++;
                }
                int mcid = 0;
                foreach (var item in it.items) {
                    int top = item.top_op;
                    if (wrapped.contains(top)) continue;
                    var top_op = it.ops[top];
                    Obj? elem = null;
                    string tag = "Artifact";
                    if (item.kind == ItemKind.TEXT) {
                        if (item.render_mode == 3 && item.form == null && !block_of_op.has_key(top)) continue;
                        int bi = block_of_op.has_key(top) ? block_of_op[top] : -2;
                        if (bi >= 0) {
                            elem = block_elems[bi];
                            tag = doc.lookup(doc.resolve(elem), "S").name;
                        } else if (bi == -2 && item.text().strip() == "") {
                            tag = "Artifact";
                        } else if (bi == -2) {
                            var e = Obj.dictionary();
                            e.set("Type", Obj.name_obj("StructElem"));
                            e.set("S", Obj.name_obj("P"));
                            e.set("P", doc_ref);
                            e.set("Pg", page_ref);
                            e.set("K", Obj.array());
                            elem = doc.add_ref(e);
                            doc_kids.add(elem);
                            tag = "P";
                            elements++;
                        }
                    } else if (item.kind == ItemKind.IMAGE && item.box.width() > 8 && item.box.height() > 8 && item.form == null) {
                        var e = Obj.dictionary();
                        e.set("Type", Obj.name_obj("StructElem"));
                        e.set("S", Obj.name_obj("Figure"));
                        e.set("P", doc_ref);
                        e.set("Pg", page_ref);
                        e.set("Alt", Obj.text(""));
                        e.set("A", attributes_bbox(item.box));
                        e.set("K", Obj.array());
                        elem = doc.add_ref(e);
                        doc_kids.add(elem);
                        tag = "Figure";
                        elements++;
                    }
                    int start = item.kind == ItemKind.PATH && item.form == null ? item.op_start : top;
                    if (!before.has_key(start)) before[start] = new Gee.ArrayList<Op>();
                    if (!after.has_key(top)) after[top] = new Gee.ArrayList<Op>();
                    if (elem != null) {
                        var props = Obj.dictionary();
                        props.set("MCID", Obj.integer(mcid));
                        before[start].add(new Op.with("BDC", { Obj.name_obj(tag), props }));
                        doc.lookup(doc.resolve(elem), "K").add(Obj.integer(mcid));
                        parent_list.add(elem);
                        mcid++;
                    } else {
                        before[start].add(new Op.with("BMC", { Obj.name_obj("Artifact") }));
                    }
                    after[top].insert(0, new Op("EMC"));
                    wrapped.add(top);
                    op_elem[top] = elem ?? Obj.none();
                }
                var out_ops = new Gee.ArrayList<Op>();
                for (int i = 0; i < it.ops.size; i++) {
                    if (before.has_key(i)) out_ops.add_all(before[i]);
                    out_ops.add(it.ops[i]);
                    if (after.has_key(i)) out_ops.add_all(after[i]);
                }
                doc.set_page_content(p, Content.serialize(out_ops));
                var page = doc.page(p);
                page.set("StructParents", Obj.integer(p));
                page.set("Tabs", Obj.name_obj("S"));
                nums.add(Obj.integer(p));
                var arr = Obj.array();
                foreach (var e in parent_list) arr.add(e);
                nums.add(arr);
                foreach (var er in block_elems) {
                    if (er == null) continue;
                    var e = doc.resolve(er);
                    var k = doc.lookup(e, "K");
                    if (k.length == 0) {
                        remove_kid(doc_kids, er);
                        elements--;
                    }
                }
            }
            document.set("K", doc_kids);
            root.set("K", doc_ref);
            var parent_tree = Obj.dictionary();
            parent_tree.set("Nums", nums);
            root.set("ParentTree", doc.add_ref(parent_tree));
            root.set("ParentTreeNextKey", Obj.integer(pages.size));
            cat.set("StructTreeRoot", root_ref);
            var mark = Obj.dictionary();
            mark.set("Marked", Obj.boolean(true));
            cat.set("MarkInfo", mark);
            if (language != "") cat.set("Lang", Obj.text(language));
            var vp = doc.sub_dict(cat, "ViewerPreferences");
            vp.set("DisplayDocTitle", Obj.boolean(true));
            var info = doc.info();
            if (title != "") info.set("Title", Obj.text(title));
            else if (doc.lookup(info, "Title").text_value().strip() == "") {
                foreach (var list in pages) {
                    foreach (var b in list) {
                        if (b.role == "H1") {
                            info.set("Title", Obj.text(b.text().replace("\n", " ")));
                            break;
                        }
                    }
                    if (doc.lookup(info, "Title").text_value() != "") break;
                }
            }
            if (doc.catalog().has("Metadata")) Standards.write_xmp(doc, Standards.pdfa_part(doc) != "" ? Standards.pdfa_part(doc) : null, null, true);
            return elements;
        }

        private static Obj attributes_bbox(Rect r) {
            var a = Obj.dictionary();
            a.set("O", Obj.name_obj("Layout"));
            a.set("BBox", Obj.numbers({ r.x1, r.y1, r.x2, r.y2 }));
            return a;
        }

        private static void remove_kid(Obj arr, Obj target) {
            for (int i = arr.length - 1; i >= 0; i--) {
                if (arr.at(i).is_ref() && arr.at(i).num == target.num) arr.items.remove_at(i);
            }
        }

        private static Gee.HashMap<int, Gee.HashMap<int, string>> mcid_texts(Document doc) {
            var result = new Gee.HashMap<int, Gee.HashMap<int, string>>();
            for (int p = 0; p < doc.page_count(); p++) {
                var map = new Gee.HashMap<int, string>();
                var it = new Interpreter(doc);
                it.run_page(p);
                foreach (var item in it.items) {
                    if (item.kind != ItemKind.TEXT || item.mcid < 0) continue;
                    string prev = map.has_key(item.mcid) ? map[item.mcid] : "";
                    map[item.mcid] = prev + item.text();
                }
                result[p] = map;
            }
            return result;
        }

        public static Gee.ArrayList<TagNode> read(Document doc) {
            var result = new Gee.ArrayList<TagNode>();
            var root = doc.lookup(doc.catalog(), "StructTreeRoot");
            if (!root.is_dict()) return result;
            var texts = mcid_texts(doc);
            walk(doc, root.get("K"), -1, 0, result, texts, new Gee.HashSet<int>());
            return result;
        }

        private static void walk(Document doc, Obj? k, int page, int depth, Gee.ArrayList<TagNode> result,
                                 Gee.HashMap<int, Gee.HashMap<int, string>> texts, Gee.HashSet<int> seen) {
            if (k == null || depth > 64) return;
            if (k.is_array()) {
                for (int i = 0; i < k.length; i++) walk(doc, k.at(i), page, depth, result, texts, seen);
                return;
            }
            if (!k.is_ref()) return;
            if (seen.contains(k.num)) return;
            seen.add(k.num);
            var e = doc.resolve(k);
            if (!e.is_dict() || !doc.lookup(e, "S").is_name()) return;
            int pg = page;
            var pgref = e.get("Pg");
            if (pgref != null && pgref.is_ref()) pg = doc.page_number_of(pgref.num);
            var node = new TagNode();
            node.reference = k;
            node.dict = e;
            node.role = doc.lookup(e, "S").name;
            node.page = pg;
            node.alt = doc.lookup(e, "Alt").text_value();
            node.depth = depth;
            var kids = doc.lookup(e, "K");
            var sb = new StringBuilder();
            var list = new Gee.ArrayList<Obj>();
            if (kids.is_array()) list.add_all(kids.items);
            else if (!kids.is_none()) list.add(e.get("K"));
            bool has_elements = false;
            foreach (var kid in list) {
                var r = doc.resolve(kid);
                if (kid.is_number() && pg >= 0 && texts.has_key(pg) && texts[pg].has_key(kid.as_int())) sb.append(texts[pg][kid.as_int()]);
                else if (r.is_dict() && doc.lookup(r, "Type").is_name("MCR")) {
                    int mc = doc.lookup(r, "MCID").as_int(-1);
                    int mp = pg;
                    var rp = r.get("Pg");
                    if (rp != null && rp.is_ref()) mp = doc.page_number_of(rp.num);
                    if (mp >= 0 && texts.has_key(mp) && texts[mp].has_key(mc)) sb.append(texts[mp][mc]);
                } else if (kid.is_ref() && r.is_dict() && doc.lookup(r, "S").is_name()) {
                    has_elements = true;
                }
            }
            node.text = doc.lookup(e, "ActualText").text_value() != "" ? doc.lookup(e, "ActualText").text_value() : sb.str;
            if (node.role != "Document" && node.role != "Part" && node.role != "Sect" && node.role != "Div" || !has_elements) result.add(node);
            foreach (var kid in list) {
                if (kid.is_ref()) walk(doc, kid, pg, depth + 1, result, texts, seen);
            }
        }

        public static void set_alt(Document doc, TagNode node, string alt) {
            if (alt.strip() == "") node.dict.remove("Alt");
            else node.dict.set("Alt", Obj.text(alt));
        }

        public static void set_role(Document doc, TagNode node, string role) {
            node.dict.set("S", Obj.name_obj(role));
            if (role == "Artifact") node.dict.set("S", Obj.name_obj("NonStruct"));
        }

        public static void reorder(Document doc, Gee.List<TagNode> order) {
            var root = doc.lookup(doc.catalog(), "StructTreeRoot");
            if (!root.is_dict()) return;
            var top = doc.resolve(root.get("K"));
            Obj container = top.is_dict() && doc.lookup(top, "S").is_name("Document") ? top : root;
            var kids = Obj.array();
            var parent_ref = container == root ? doc.catalog().get("StructTreeRoot") : root.get("K");
            foreach (var n in order) {
                kids.add(n.reference);
                if (parent_ref != null) n.dict.set("P", parent_ref);
            }
            container.set("K", kids);
        }

        public static int untagged_content(Document doc, int page) {
            var it = new Interpreter(doc);
            it.run_page(page);
            int count = 0;
            foreach (var item in it.items) {
                if (item.mcid >= 0 || item.artifact) continue;
                if (item.kind == ItemKind.TEXT && item.text().strip() == "") continue;
                count++;
            }
            return count;
        }
    }
}
