namespace Singularity.Pdf {

    [Flags]
    public enum HiddenInfo {
        METADATA,
        JAVASCRIPT,
        ATTACHMENTS,
        COMMENTS,
        HIDDEN_LAYERS,
        HIDDEN_TEXT,
        FORM_ACTIONS,
        EXTERNAL_LINKS,
        PRIVATE_DATA,
        BOOKMARKS,
        ALL = METADATA | JAVASCRIPT | ATTACHMENTS | COMMENTS | HIDDEN_LAYERS | HIDDEN_TEXT | FORM_ACTIONS | EXTERNAL_LINKS | PRIVATE_DATA
    }

    public class SanitizeReport {
        public int metadata = 0;
        public int scripts = 0;
        public int attachments = 0;
        public int comments = 0;
        public int layers = 0;
        public int hidden_text = 0;
        public int actions = 0;
        public int links = 0;
        public int private_data = 0;
        public int bookmarks = 0;

        public int total {
            get { return metadata + scripts + attachments + comments + layers + hidden_text + actions + links + private_data + bookmarks; }
        }
    }

    public class Sanitizer {
        public static SanitizeReport inspect(Document doc) {
            var r = new SanitizeReport();
            var info = doc.info_if_present();
            if (info != null) r.metadata += info.dict.size;
            if (doc.catalog().has("Metadata")) r.metadata++;
            r.scripts = count_scripts(doc);
            r.attachments = Attachments.list(doc).size;
            foreach (var a in Annotations.list(doc)) {
                if (a.subtype in Annotations.MARKUP_TYPES && a.subtype != "FileAttachment") r.comments++;
                if (a.subtype == "Link") {
                    var action = doc.lookup(a.dict, "A");
                    var s = doc.lookup(action, "S");
                    if (s.is_name("URI") || s.is_name("Launch") || s.is_name("GoToR")) r.links++;
                }
            }
            r.layers = hidden_groups(doc).size;
            for (int p = 0; p < doc.page_count(); p++) {
                var it = new Interpreter(doc);
                it.run_page(p);
                foreach (var item in it.items) if (item.kind == ItemKind.TEXT && item.render_mode == 3 && item.text().strip() != "") r.hidden_text++;
                if (doc.page(p).has("PieceInfo") || doc.page(p).has("Thumb")) r.private_data++;
            }
            if (doc.catalog().has("PieceInfo")) r.private_data++;
            r.bookmarks = Outline.read(doc).size;
            return r;
        }

        private static int count_scripts(Document doc) {
            int n = 0;
            var names = doc.lookup(doc.lookup(doc.catalog(), "Names"), "JavaScript");
            if (names.is_dict()) n++;
            var open = doc.lookup(doc.catalog(), "OpenAction");
            if (open.is_dict() && doc.lookup(open, "S").is_name("JavaScript")) n++;
            if (doc.catalog().has("AA")) n++;
            foreach (var f in Forms.list(doc)) {
                if (f.calculate_js != "" || f.format_js != "" || f.validate_js != "" || f.keystroke_js != "") n++;
            }
            return n;
        }

        public static Gee.HashSet<int> hidden_groups(Document doc) {
            var result = new Gee.HashSet<int>();
            var ocp = doc.lookup(doc.catalog(), "OCProperties");
            if (!ocp.is_dict()) return result;
            var d = doc.lookup(ocp, "D");
            var off = doc.lookup(d, "OFF");
            if (off.is_array()) for (int i = 0; i < off.length; i++) if (off.at(i).is_ref()) result.add(off.at(i).num);
            if (doc.lookup(d, "BaseState").is_name("OFF")) {
                var all = doc.lookup(ocp, "OCGs");
                var on = doc.lookup(d, "ON");
                var on_set = new Gee.HashSet<int>();
                if (on.is_array()) for (int i = 0; i < on.length; i++) if (on.at(i).is_ref()) on_set.add(on.at(i).num);
                if (all.is_array()) for (int i = 0; i < all.length; i++) if (all.at(i).is_ref() && !on_set.contains(all.at(i).num)) result.add(all.at(i).num);
            }
            return result;
        }

        private static void strip_actions(Document doc, Obj? o, Gee.HashSet<int> seen, SanitizeReport r, bool external_links) {
            if (o == null) return;
            if (o.is_ref()) {
                if (seen.contains(o.num)) return;
                seen.add(o.num);
            }
            var d = doc.resolve(o);
            if (d.is_array()) {
                for (int i = 0; i < d.length; i++) strip_actions(doc, d.at(i), seen, r, external_links);
                return;
            }
            if (!d.is_dict()) return;
            var type = doc.lookup(d, "Type");
            if (type.is_name("Page") || type.is_name("Pages")) return;
            foreach (var key in new string[] { "A", "OpenAction" }) {
                var action = doc.lookup(d, key);
                if (!action.is_dict()) continue;
                var s = doc.lookup(action, "S");
                if (s.is_name("JavaScript") || s.is_name("Launch") || s.is_name("SubmitForm") || s.is_name("ImportData") || s.is_name("Rendition")) {
                    d.remove(key);
                    r.actions++;
                } else if (external_links && (s.is_name("URI") || s.is_name("GoToR"))) {
                    d.remove(key);
                    r.links++;
                }
            }
            if (d.has("AA")) {
                d.remove("AA");
                r.actions++;
            }
            if (d.is_stream()) return;
            foreach (var k in d.dict.keys) {
                if (k == "Parent" || k == "P" || k == "Dest" || k == "Prev" || k == "Next" || k == "Last") continue;
                strip_actions(doc, d.get(k), seen, r, external_links);
            }
        }

        public static SanitizeReport apply(Document doc, HiddenInfo what) {
            var r = new SanitizeReport();
            var cat = doc.catalog();
            if (HiddenInfo.METADATA in what) {
                var info = doc.info_if_present();
                if (info != null) {
                    r.metadata += info.dict.size;
                    doc.trailer.remove("Info");
                }
                if (cat.has("Metadata")) {
                    cat.remove("Metadata");
                    r.metadata++;
                }
                for (int p = 0; p < doc.page_count(); p++) {
                    if (doc.page(p).has("Metadata")) {
                        doc.page(p).remove("Metadata");
                        r.metadata++;
                    }
                }
            }
            if (HiddenInfo.JAVASCRIPT in what || HiddenInfo.FORM_ACTIONS in what) {
                var names = doc.lookup(cat, "Names");
                if (names.is_dict() && names.has("JavaScript")) {
                    names.remove("JavaScript");
                    r.scripts++;
                }
                var open = doc.lookup(cat, "OpenAction");
                if (open.is_dict() && doc.lookup(open, "S").is_name("JavaScript")) {
                    cat.remove("OpenAction");
                    r.scripts++;
                }
                if (cat.has("AA")) {
                    cat.remove("AA");
                    r.scripts++;
                }
                var seen = new Gee.HashSet<int>();
                for (int p = 0; p < doc.page_count(); p++) {
                    var page = doc.page(p);
                    if (page.has("AA")) {
                        page.remove("AA");
                        r.actions++;
                    }
                    strip_actions(doc, page.get("Annots"), seen, r, HiddenInfo.EXTERNAL_LINKS in what);
                }
                strip_actions(doc, cat.get("AcroForm"), seen, r, false);
                strip_actions(doc, cat.get("Outlines"), seen, r, HiddenInfo.EXTERNAL_LINKS in what);
            } else if (HiddenInfo.EXTERNAL_LINKS in what) {
                var seen = new Gee.HashSet<int>();
                for (int p = 0; p < doc.page_count(); p++) strip_actions(doc, doc.page(p).get("Annots"), seen, r, true);
            }
            if (HiddenInfo.ATTACHMENTS in what) {
                r.attachments = Attachments.list(doc).size;
                Attachments.remove_all(doc);
            }
            if (HiddenInfo.COMMENTS in what) {
                for (int p = 0; p < doc.page_count(); p++) {
                    foreach (var a in Annotations.list(doc, p)) {
                        if (a.subtype in Annotations.MARKUP_TYPES || a.subtype == "Popup") {
                            Annotations.remove(doc, p, a.reference);
                            if (a.subtype != "Popup") r.comments++;
                        }
                    }
                }
            }
            if (HiddenInfo.HIDDEN_LAYERS in what || HiddenInfo.HIDDEN_TEXT in what) {
                var hidden = HiddenInfo.HIDDEN_LAYERS in what ? hidden_groups(doc) : new Gee.HashSet<int>();
                r.layers = hidden.size;
                for (int p = 0; p < doc.page_count(); p++) strip_page(doc, p, hidden, HiddenInfo.HIDDEN_TEXT in what, r);
                if (HiddenInfo.HIDDEN_LAYERS in what && hidden.size > 0) {
                    var ocp = doc.lookup(cat, "OCProperties");
                    var ocgs = doc.lookup(ocp, "OCGs");
                    if (ocgs.is_array()) {
                        var keep = Obj.array();
                        for (int i = 0; i < ocgs.length; i++) if (!(ocgs.at(i).is_ref() && hidden.contains(ocgs.at(i).num))) keep.add(ocgs.at(i));
                        ocp.set("OCGs", keep);
                        var d = doc.lookup(ocp, "D");
                        if (d.is_dict()) {
                            d.remove("OFF");
                            d.remove("Order");
                            d.set("BaseState", Obj.name_obj("ON"));
                        }
                    }
                }
            }
            if (HiddenInfo.PRIVATE_DATA in what) {
                if (cat.has("PieceInfo")) {
                    cat.remove("PieceInfo");
                    r.private_data++;
                }
                for (int p = 0; p < doc.page_count(); p++) {
                    var page = doc.page(p);
                    foreach (var key in new string[] { "PieceInfo", "Thumb", "LastModified" }) {
                        if (page.has(key)) {
                            page.remove(key);
                            r.private_data++;
                        }
                    }
                }
                var names = doc.lookup(cat, "Names");
                if (names.is_dict() && names.has("Templates")) names.remove("Templates");
                cat.remove("SpiderInfo");
            }
            if (HiddenInfo.BOOKMARKS in what) {
                r.bookmarks = Outline.read(doc).size;
                cat.remove("Outlines");
            }
            return r;
        }

        private static void strip_page(Document doc, int page, Gee.HashSet<int> hidden, bool hidden_text, SanitizeReport r) {
            var it = new Interpreter(doc);
            it.run_page(page);
            var props = doc.lookup(it.resources, "Properties");
            var out_ops = new Gee.ArrayList<Op>();
            int skip_depth = 0;
            int depth = 0;
            bool changed = false;
            if (hidden_text) {
                var invisible = new Gee.ArrayList<Item>();
                foreach (var item in it.items) {
                    if (item.kind == ItemKind.TEXT && item.render_mode == 3 && item.text().strip() != "") {
                        invisible.add(item);
                        r.hidden_text++;
                    }
                }
                if (invisible.size > 0) {
                    Editor.remove_items(it, invisible);
                    it.commit_forms();
                    changed = true;
                }
            }
            for (int i = 0; i < it.ops.size; i++) {
                var op = it.ops[i];
                if (op.name == "BDC" || op.name == "BMC") {
                    depth++;
                    if (skip_depth == 0 && op.name == "BDC" && op.args.size >= 2 && op.args[0].is_name("OC") && hidden.size > 0) {
                        var p = op.args[1];
                        Obj? group = null;
                        if (p.is_name() && props.is_dict()) group = props.get(p.name);
                        else if (p.is_dict()) group = p.get("OCGs");
                        if (group != null && group.is_ref() && hidden.contains(group.num)) {
                            skip_depth = depth;
                            changed = true;
                            continue;
                        }
                    }
                } else if (op.name == "EMC") {
                    if (skip_depth > 0 && depth == skip_depth) {
                        skip_depth = 0;
                        depth--;
                        continue;
                    }
                    depth--;
                }
                if (skip_depth > 0) {
                    if (op.name == "q" || op.name == "Q" || op.name == "BT" || op.name == "ET") out_ops.add(op);
                    continue;
                }
                out_ops.add(op);
            }
            if (changed) {
                it.ops = out_ops;
                doc.set_page_content(page, Content.serialize(out_ops));
            }
        }
    }
}
