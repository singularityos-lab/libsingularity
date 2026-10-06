namespace Singularity.Pdf {

    public class AttachmentInfo {
        public string name = "";
        public string description = "";
        public int size = -1;
        public int page = -1;
        public Obj spec;
        public Obj? annot = null;
    }

    public class Attachments {
        public static Obj file_spec(Document doc, string filename, uint8[] data, string description) {
            var ef_stream = doc.make_stream(data, true);
            ef_stream.set("Type", Obj.name_obj("EmbeddedFile"));
            string? mime = guess_mime(filename);
            if (mime != null) ef_stream.set("Subtype", Obj.name_obj(mime));
            var params = Obj.dictionary();
            params.set("Size", Obj.integer(data.length));
            params.set("ModDate", Obj.text(Annotations.date_now()));
            params.set("CheckSum", Obj.str(Crypto.digest(ChecksumType.MD5, data), true));
            ef_stream.set("Params", params);
            var ef = Obj.dictionary();
            ef.set("F", doc.add_ref(ef_stream));
            ef.set("UF", ef.get("F"));
            var spec = Obj.dictionary();
            spec.set("Type", Obj.name_obj("Filespec"));
            bool lossless;
            spec.set("F", Obj.str(Encodings.encode_pdfdoc(filename, out lossless)));
            spec.set("UF", Obj.text(filename));
            spec.set("EF", ef);
            spec.set("AFRelationship", Obj.name_obj("Unspecified"));
            if (description != "") spec.set("Desc", Obj.text(description));
            return doc.add_ref(spec);
        }

        private static string? guess_mime(string filename) {
            bool uncertain;
            string ct = ContentType.guess(filename, null, out uncertain);
            string? mime = ContentType.get_mime_type(ct);
            return mime;
        }

        private static void collect_names(Document doc, Obj node, Gee.ArrayList<Obj> out_list, int depth) {
            if (depth > 32 || !node.is_dict()) return;
            var names = doc.lookup(node, "Names");
            if (names.is_array()) for (int i = 0; i < names.length; i++) out_list.add(names.at(i));
            var kids = doc.lookup(node, "Kids");
            if (kids.is_array()) for (int i = 0; i < kids.length; i++) collect_names(doc, doc.resolve(kids.at(i)), out_list, depth + 1);
        }

        public static Gee.ArrayList<AttachmentInfo> list(Document doc) {
            var result = new Gee.ArrayList<AttachmentInfo>();
            var tree = doc.lookup(doc.lookup(doc.catalog(), "Names"), "EmbeddedFiles");
            var entries = new Gee.ArrayList<Obj>();
            collect_names(doc, tree, entries, 0);
            for (int i = 0; i + 1 < entries.size; i += 2) {
                var spec = doc.resolve(entries[i + 1]);
                if (!spec.is_dict()) continue;
                var info = describe(doc, spec);
                if (info.name == "") info.name = doc.resolve(entries[i]).text_value();
                result.add(info);
            }
            foreach (var a in Annotations.list(doc)) {
                if (a.subtype != "FileAttachment") continue;
                var spec = doc.lookup(a.dict, "FS");
                if (!spec.is_dict()) continue;
                var info = describe(doc, spec);
                info.page = a.page;
                info.annot = a.reference;
                result.add(info);
            }
            return result;
        }

        private static AttachmentInfo describe(Document doc, Obj spec) {
            var info = new AttachmentInfo();
            info.spec = spec;
            var uf = doc.lookup(spec, "UF");
            info.name = uf.is_string() ? uf.text_value() : doc.lookup(spec, "F").text_value();
            info.description = doc.lookup(spec, "Desc").text_value();
            var ef = doc.lookup(spec, "EF");
            var stream = doc.lookup(ef, "F");
            if (stream.is_stream()) {
                var size = doc.lookup(doc.lookup(stream, "Params"), "Size");
                info.size = size.is_number() ? size.as_int() : doc.stream_data(stream).length;
            }
            return info;
        }

        public static uint8[] data(Document doc, AttachmentInfo info) {
            var ef = doc.lookup(info.spec, "EF");
            var stream = doc.lookup(ef, "UF");
            if (!stream.is_stream()) stream = doc.lookup(ef, "F");
            return doc.stream_data(stream);
        }

        public static void add(Document doc, string filename, uint8[] data, string description = "") {
            var cat = doc.catalog();
            var names = doc.sub_dict(cat, "Names");
            var ef = doc.sub_dict(names, "EmbeddedFiles");
            var entries = new Gee.ArrayList<Obj>();
            collect_names(doc, ef, entries, 0);
            var pairs = new Gee.TreeMap<string, Obj>();
            for (int i = 0; i + 1 < entries.size; i += 2) pairs[doc.resolve(entries[i]).text_value()] = entries[i + 1];
            string key = filename;
            int n = 2;
            while (pairs.has_key(key)) key = "%s (%d)".printf(filename, n++);
            pairs[key] = file_spec(doc, filename, data, description);
            write_tree(doc, ef, pairs);
            var af = doc.sub_array(cat, "AF");
            af.add(pairs[key]);
        }

        private static void write_tree(Document doc, Obj ef, Gee.TreeMap<string, Obj> pairs) {
            ef.remove("Kids");
            ef.remove("Limits");
            var arr = Obj.array();
            foreach (var e in pairs.entries) {
                arr.add(Obj.text(e.key));
                arr.add(e.value);
            }
            ef.set("Names", arr);
        }

        public static void remove(Document doc, AttachmentInfo info) {
            if (info.annot != null && info.page >= 0) {
                Annotations.remove(doc, info.page, info.annot);
                return;
            }
            var cat = doc.catalog();
            var ef = doc.lookup(doc.lookup(cat, "Names"), "EmbeddedFiles");
            if (!ef.is_dict()) return;
            var entries = new Gee.ArrayList<Obj>();
            collect_names(doc, ef, entries, 0);
            var pairs = new Gee.TreeMap<string, Obj>();
            for (int i = 0; i + 1 < entries.size; i += 2) {
                var spec = doc.resolve(entries[i + 1]);
                if (spec == info.spec) continue;
                pairs[doc.resolve(entries[i]).text_value()] = entries[i + 1];
            }
            write_tree(doc, ef, pairs);
            var af = doc.lookup(cat, "AF");
            if (af.is_array()) {
                var keep = Obj.array();
                for (int i = 0; i < af.length; i++) if (doc.resolve(af.at(i)) != info.spec) keep.add(af.at(i));
                cat.set("AF", keep);
            }
        }

        public static void remove_all(Document doc) {
            var cat = doc.catalog();
            var names = doc.lookup(cat, "Names");
            if (names.is_dict()) names.remove("EmbeddedFiles");
            cat.remove("AF");
            cat.remove("Collection");
            for (int p = 0; p < doc.page_count(); p++) {
                foreach (var a in Annotations.list(doc, p)) {
                    if (a.subtype == "FileAttachment") Annotations.remove(doc, p, a.reference);
                }
            }
        }

        public static bool is_portfolio(Document doc) {
            return doc.lookup(doc.catalog(), "Collection").is_dict();
        }
    }
}
