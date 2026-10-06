namespace Singularity.Pdf {

    public class OutlineItem {
        public string title = "";
        public int page = -1;
        public double top = -1;
        public string uri = "";
        public int depth = 0;
        public bool open = false;
        public bool bold = false;
        public bool italic = false;
        public double[]? color = null;
        public Gee.ArrayList<OutlineItem> children = new Gee.ArrayList<OutlineItem>();
    }

    public class Outline {
        public static Obj? find_name(Document doc, Obj node, string name, int depth = 0) {
            if (depth > 32 || !node.is_dict()) return null;
            var names = doc.lookup(node, "Names");
            if (names.is_array()) {
                for (int i = 0; i + 1 < names.length; i += 2) {
                    if (doc.resolve(names.at(i)).text_value() == name) return doc.resolve(names.at(i + 1));
                }
            }
            var kids = doc.lookup(node, "Kids");
            if (kids.is_array()) {
                for (int i = 0; i < kids.length; i++) {
                    var kid = doc.resolve(kids.at(i));
                    var limits = doc.lookup(kid, "Limits");
                    if (limits.is_array() && limits.length >= 2) {
                        string lo = doc.resolve(limits.at(0)).text_value(), hi = doc.resolve(limits.at(1)).text_value();
                        if (strcmp(name, lo) < 0 || strcmp(name, hi) > 0) continue;
                    }
                    var found = find_name(doc, kid, name, depth + 1);
                    if (found != null) return found;
                }
            }
            return null;
        }

        public static Obj resolve_dest(Document doc, Obj? dest) {
            var d = doc.resolve(dest);
            if (d.is_string() || d.is_name()) {
                string name = d.text_value();
                var dests = doc.lookup(doc.catalog(), "Dests");
                if (dests.is_dict() && dests.get(name) != null) d = doc.resolve(dests.get(name));
                else {
                    var tree = doc.lookup(doc.lookup(doc.catalog(), "Names"), "Dests");
                    var found = tree.is_dict() ? find_name(doc, tree, name) : null;
                    d = found ?? Obj.none();
                }
            }
            if (d.is_dict()) d = doc.resolve(d.get("D"));
            return d;
        }

        public static void dest_target(Document doc, Obj? dest, out int page, out double top) {
            page = -1;
            top = -1;
            var d = resolve_dest(doc, dest);
            if (!d.is_array() || d.length == 0) return;
            var p = d.at(0);
            if (p.is_ref()) page = doc.page_number_of(p.num);
            else if (p.is_number()) page = p.as_int();
            if (d.length >= 2 && d.at(1).is_name()) {
                string kind = d.at(1).name;
                if ((kind == "XYZ" && d.length >= 4) || kind == "FitH" || kind == "FitBH") {
                    var t = kind == "XYZ" ? d.at(3) : d.at(2);
                    if (t.is_number()) top = t.as_number();
                } else if (kind == "FitR" && d.length >= 6) {
                    top = d.at(5).as_number();
                }
            }
        }

        public static void target_of(Document doc, Obj item, out int page, out double top, out string uri) {
            page = -1;
            top = -1;
            uri = "";
            var dest = item.get("Dest");
            if (dest != null) {
                dest_target(doc, dest, out page, out top);
                return;
            }
            var action = doc.resolve(item.get("A"));
            if (!action.is_dict()) return;
            var s = doc.lookup(action, "S");
            if (s.is_name("GoTo")) dest_target(doc, action.get("D"), out page, out top);
            else if (s.is_name("URI")) uri = doc.lookup(action, "URI").text_value();
            else if (s.is_name("Launch") || s.is_name("GoToR")) {
                var f = doc.lookup(action, "F");
                uri = f.is_dict() ? doc.lookup(f, "F").text_value() : f.text_value();
            }
        }

        private static void read_level(Document doc, Obj? first, int depth, Gee.ArrayList<OutlineItem> into, Gee.HashSet<int> seen) {
            var cur = first;
            int guard = 0;
            while (cur != null && cur.is_ref() && !seen.contains(cur.num) && guard++ < 100000) {
                seen.add(cur.num);
                var node = doc.resolve(cur);
                if (!node.is_dict()) break;
                var item = new OutlineItem();
                item.title = doc.lookup(node, "Title").text_value();
                item.depth = depth;
                item.open = doc.lookup(node, "Count").as_int(0) > 0;
                int flags = doc.lookup(node, "F").as_int(0);
                item.italic = (flags & 1) != 0;
                item.bold = (flags & 2) != 0;
                var c = doc.lookup(node, "C");
                if (c.is_array() && c.length == 3) item.color = { c.at(0).as_number(), c.at(1).as_number(), c.at(2).as_number() };
                target_of(doc, node, out item.page, out item.top, out item.uri);
                read_level(doc, node.get("First"), depth + 1, item.children, seen);
                into.add(item);
                cur = node.get("Next");
            }
        }

        public static Gee.ArrayList<OutlineItem> tree(Document doc) {
            var result = new Gee.ArrayList<OutlineItem>();
            var outlines = doc.lookup(doc.catalog(), "Outlines");
            if (!outlines.is_dict()) return result;
            read_level(doc, outlines.get("First"), 0, result, new Gee.HashSet<int>());
            return result;
        }

        public static Gee.ArrayList<OutlineItem> read(Document doc) {
            var flat = new Gee.ArrayList<OutlineItem>();
            flatten_into(tree(doc), flat);
            return flat;
        }

        private static void flatten_into(Gee.List<OutlineItem> items, Gee.ArrayList<OutlineItem> flat) {
            foreach (var i in items) {
                flat.add(i);
                flatten_into(i.children, flat);
            }
        }

        public static Obj make_dest(Document doc, int page, double top) {
            var d = Obj.array();
            var refs = doc.page_refs();
            d.add(page >= 0 && page < refs.size ? refs[page] : Obj.integer(0));
            d.add(Obj.name_obj("XYZ"));
            d.add(Obj.none());
            d.add(top >= 0 ? Obj.number(top) : Obj.none());
            d.add(Obj.none());
            return d;
        }

        private static int write_level(Document doc, Gee.List<OutlineItem> items, Obj parent_ref, out Obj? first, out Obj? last) {
            first = null;
            last = null;
            var refs = new Gee.ArrayList<Obj>();
            var nodes = new Gee.ArrayList<Obj>();
            foreach (var item in items) {
                var node = Obj.dictionary();
                refs.add(doc.add_ref(node));
                nodes.add(node);
            }
            int total = 0;
            for (int i = 0; i < items.size; i++) {
                var item = items[i];
                var node = nodes[i];
                node.set("Title", Obj.text(item.title));
                node.set("Parent", parent_ref);
                if (i > 0) node.set("Prev", refs[i - 1]);
                if (i + 1 < items.size) node.set("Next", refs[i + 1]);
                if (item.uri != "") {
                    var a = Obj.dictionary();
                    a.set("S", Obj.name_obj("URI"));
                    a.set("URI", Obj.str(item.uri.data));
                    node.set("A", a);
                } else if (item.page >= 0) {
                    node.set("Dest", make_dest(doc, item.page, item.top));
                }
                int flags = (item.italic ? 1 : 0) | (item.bold ? 2 : 0);
                if (flags != 0) node.set("F", Obj.integer(flags));
                if (item.color != null) node.set("C", Obj.numbers(item.color));
                int count = 0;
                if (item.children.size > 0) {
                    Obj? cf, cl;
                    count = write_level(doc, item.children, refs[i], out cf, out cl);
                    node.set("First", cf);
                    node.set("Last", cl);
                    node.set("Count", Obj.integer(item.open ? count : -count));
                }
                total += 1 + (item.open ? count : 0);
            }
            if (refs.size > 0) {
                first = refs[0];
                last = refs[refs.size - 1];
            }
            return total;
        }

        public static void write(Document doc, Gee.List<OutlineItem> items) {
            var cat = doc.catalog();
            if (items.size == 0) {
                cat.remove("Outlines");
                return;
            }
            var root = Obj.dictionary();
            root.set("Type", Obj.name_obj("Outlines"));
            var root_ref = doc.add_ref(root);
            Obj? first, last;
            int count = write_level(doc, items, root_ref, out first, out last);
            root.set("First", first);
            root.set("Last", last);
            root.set("Count", Obj.integer(count));
            cat.set("Outlines", root_ref);
            if (!cat.has("PageMode")) cat.set("PageMode", Obj.name_obj("UseOutlines"));
        }

        public static void drop_destinations(Document doc, Gee.HashSet<int> removed_pages) {
            if (removed_pages.size == 0) return;
            var items = tree(doc);
            if (items.size == 0) return;
            prune(items, doc, removed_pages);
        }

        private static void prune(Gee.ArrayList<OutlineItem> items, Document doc, Gee.HashSet<int> removed) {
            var outlines = doc.lookup(doc.catalog(), "Outlines");
            if (!outlines.is_dict()) return;
            var stack = new Gee.ArrayList<Obj>();
            var first = outlines.get("First");
            if (first != null) stack.add(first);
            var seen = new Gee.HashSet<int>();
            while (stack.size > 0) {
                var cur = stack.remove_at(stack.size - 1);
                if (!cur.is_ref() || seen.contains(cur.num)) continue;
                seen.add(cur.num);
                var node = doc.resolve(cur);
                if (!node.is_dict()) continue;
                var d = resolve_dest(doc, node.has("Dest") ? node.get("Dest") : (doc.resolve(node.get("A")).is_dict() ? doc.resolve(node.get("A")).get("D") : null));
                if (d.is_array() && d.length > 0 && d.at(0).is_ref() && removed.contains(d.at(0).num)) {
                    node.remove("Dest");
                    node.remove("A");
                }
                if (node.get("Next") != null) stack.add(node.get("Next"));
                if (node.get("First") != null) stack.add(node.get("First"));
            }
        }
    }
}
