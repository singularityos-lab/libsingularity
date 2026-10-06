namespace Singularity.Pdf {

    public class SignatureRequest {
        public string field_name = "Signature1";
        public int page = -1;
        public Rect rect = Rect.of(0, 0, 0, 0);
        public string signer = "";
        public string reason = "";
        public string location = "";
        public string contact = "";
        public string sub_filter = "ETSI.CAdES.detached";
        public int reserve = 20000;
        public bool timestamp_only = false;
        public string[] appearance_lines = {};
        public Gdk.Pixbuf? image = null;
        public int certify_permissions = 0;
    }

    public class PreparedSignature {
        public uint8[] data;
        public int64[] byte_range = new int64[4];
        public int contents_offset;
        public int contents_length;

        public uint8[] signed_bytes() {
            var b = new ByteArray();
            b.append(data[byte_range[0] : byte_range[0] + byte_range[1]]);
            b.append(data[byte_range[2] : byte_range[2] + byte_range[3]]);
            return b.steal();
        }

        public uint8[] finish(uint8[] cms) throws PdfError {
            if (cms.length * 2 > contents_length) throw new PdfError.FAILED("the signature is larger than the reserved space");
            var hex = new StringBuilder();
            foreach (uint8 c in cms) hex.append_printf("%02x", c);
            for (int i = 0; i < hex.len; i++) data[contents_offset + i] = hex.str[i];
            return data;
        }
    }

    public class SignatureInfo {
        public string field = "";
        public string signer = "";
        public string reason = "";
        public string location = "";
        public string date = "";
        public string sub_filter = "";
        public int64[] byte_range = {};
        public uint8[] contents = {};
        public bool covers_whole_file = false;
        public int64 revision_end = 0;
        public bool is_timestamp = false;
        public int page = -1;
        public Rect rect;
        public bool certification = false;
        public int docmdp = 0;
    }

    public class Signing {
        private const string RANGE_MARK = "/ByteRange [0 1111111111 2222222222 3333333333]";

        private static string f(double v) {
            return Obj.format_number(Math.round(v * 1000) / 1000);
        }

        public static PreparedSignature prepare(Document doc, SignatureRequest req) throws Error {
            if (doc.data.length == 0) {
                var fresh = Document.open_bytes(doc.save());
                return prepare(fresh, req);
            }
            doc.finish_fonts();
            var af = Forms.ensure_acroform(doc);
            af.set("SigFlags", Obj.integer(3));
            var sig = Obj.dictionary();
            sig.set("Type", Obj.name_obj(req.timestamp_only ? "DocTimeStamp" : "Sig"));
            sig.set("Filter", Obj.name_obj("Adobe.PPKLite"));
            sig.set("SubFilter", Obj.name_obj(req.timestamp_only ? "ETSI.RFC3161" : req.sub_filter));
            if (!req.timestamp_only) {
                sig.set("M", Obj.text(Annotations.date_now()));
                if (req.signer != "") sig.set("Name", Obj.text(req.signer));
                if (req.reason != "") sig.set("Reason", Obj.text(req.reason));
                if (req.location != "") sig.set("Location", Obj.text(req.location));
                if (req.contact != "") sig.set("ContactInfo", Obj.text(req.contact));
            }
            if (req.certify_permissions > 0) {
                var reference = Obj.dictionary();
                reference.set("Type", Obj.name_obj("SigRef"));
                reference.set("TransformMethod", Obj.name_obj("DocMDP"));
                var params = Obj.dictionary();
                params.set("Type", Obj.name_obj("TransformParams"));
                params.set("P", Obj.integer(req.certify_permissions));
                params.set("V", Obj.name_obj("1.2"));
                reference.set("TransformParams", params);
                var refs = Obj.array();
                refs.add(reference);
                sig.set("Reference", refs);
            }
            sig.set("ByteRange", Obj.keyword("[0 1111111111 2222222222 3333333333]"));
            sig.set("Contents", Obj.keyword("<" + string.nfill(req.reserve * 2, '0') + ">"));
            var sig_ref = doc.add_ref(sig);
            if (req.certify_permissions > 0) {
                var perms = Obj.dictionary();
                perms.set("DocMDP", sig_ref);
                doc.catalog().set("Perms", perms);
            }
            FieldInfo? existing = null;
            foreach (var fi in Forms.list(doc)) {
                if (fi.type == FieldType.SIGNATURE && fi.name == req.field_name && fi.value == "") existing = fi;
            }
            Obj widget;
            if (existing != null) {
                existing.dict.set("V", sig_ref);
                widget = existing.widgets.size > 0 ? existing.widgets[0].dict : existing.dict;
            } else {
                int page = req.page >= 0 ? req.page : 0;
                string name = req.field_name;
                int n = 2;
                while (Forms.find(doc, name) != null) name = "%s_%d".printf(req.field_name, n++);
                widget = Obj.dictionary();
                widget.set("Type", Obj.name_obj("Annot"));
                widget.set("Subtype", Obj.name_obj("Widget"));
                widget.set("FT", Obj.name_obj("Sig"));
                widget.set("T", Obj.text(name));
                widget.set("F", Obj.integer(req.rect.width() > 0 ? 4 : 132));
                widget.set("Rect", Obj.numbers({ req.rect.x1, req.rect.y1, req.rect.x2, req.rect.y2 }));
                widget.set("P", doc.page_refs()[page]);
                widget.set("V", sig_ref);
                var wref = doc.add_ref(widget);
                doc.lookup(af, "Fields").add(wref);
                doc.sub_array(doc.page(page), "Annots").add(wref);
            }
            var rect_obj = doc.lookup(widget, "Rect");
            if (rect_obj.is_array() && rect_obj.length >= 4) {
                var r = Rect.of(rect_obj.at(0).as_number(), rect_obj.at(1).as_number(), rect_obj.at(2).as_number(), rect_obj.at(3).as_number());
                if (r.width() > 1 && r.height() > 1) widget.set("AP", appearance(doc, r, req));
            }
            var opts = new SaveOptions();
            opts.mode = SaveMode.INCREMENTAL;
            uint8[] bytes = doc.save(opts);
            int mark = Lexer.rfind(bytes, "/ByteRange[0 1111111111 2222222222 3333333333]", bytes.length - 1);
            int mark_len = "/ByteRange[0 1111111111 2222222222 3333333333]".length;
            if (mark < 0) {
                mark = Lexer.rfind(bytes, RANGE_MARK, bytes.length - 1);
                mark_len = RANGE_MARK.length;
            }
            if (mark < 0) throw new PdfError.FAILED("the signature placeholder was not written");
            int contents = Lexer.find(bytes, "/Contents<", mark);
            int contents_skip = 10;
            if (contents < 0) {
                contents = Lexer.find(bytes, "/Contents <", mark);
                contents_skip = 11;
            }
            if (contents < 0) throw new PdfError.FAILED("the signature placeholder was not written");
            var prep = new PreparedSignature();
            int hex_start = contents + contents_skip;
            prep.contents_offset = hex_start;
            prep.contents_length = req.reserve * 2;
            int64 a = hex_start - 1;
            int64 b = hex_start + req.reserve * 2 + 1;
            prep.byte_range = { 0, a, b, bytes.length - b };
            string range = "/ByteRange[0 %lld %lld %lld]".printf(a, b, bytes.length - b);
            if (range.length > mark_len) throw new PdfError.FAILED("the byte range does not fit");
            string padded = range + string.nfill(mark_len - range.length, ' ');
            for (int i = 0; i < padded.length; i++) bytes[mark + i] = padded[i];
            prep.data = bytes;
            return prep;
        }

        private static Obj appearance(Document doc, Rect r, SignatureRequest req) {
            var res = Obj.dictionary();
            var ops = new StringBuilder();
            double w = r.width(), h = r.height();
            if (req.image != null) {
                try {
                    var img = Images.pixbuf_xobject(doc, req.image);
                    var xo = Obj.dictionary();
                    xo.set("Im0", img);
                    res.set("XObject", xo);
                    double iw = w * 0.45, ih = double.min(h, iw * req.image.height / double.max(1, req.image.width));
                    ops.append_printf("q %s 0 0 %s 0 %s cm /Im0 Do Q\n", f(iw), f(ih), f((h - ih) / 2));
                } catch (Error e) {
                }
            }
            var font = EmbeddedFont.for_pattern(doc, "sans-serif");
            if (font != null && req.appearance_lines.length > 0) {
                var fonts = Obj.dictionary();
                fonts.set("F1", font.font_ref);
                res.set("Font", fonts);
                double x = req.image != null ? w * 0.5 : 2;
                double size = double.min(10, h / (req.appearance_lines.length * 1.3 + 0.5));
                double y = h - size * 1.2;
                ops.append("BT 0 g\n");
                foreach (var line in req.appearance_lines) {
                    ops.append_printf("/F1 %s Tf 1 0 0 1 %s %s Tm %s Tj\n", f(size), f(x), f(y), font.hex(line));
                    y -= size * 1.3;
                }
                ops.append("ET\n");
                doc.finish_fonts();
            }
            var d = new Dict();
            d.set("Type", Obj.name_obj("XObject"));
            d.set("Subtype", Obj.name_obj("Form"));
            d.set("BBox", Obj.numbers({ 0, 0, w, h }));
            d.set("Resources", res);
            var ap = Obj.dictionary();
            ap.set("N", doc.add_ref(doc.make_stream(ops.str.data, true, d)));
            return ap;
        }

        public static Gee.ArrayList<SignatureInfo> list(Document doc) {
            var result = new Gee.ArrayList<SignatureInfo>();
            var perms = doc.lookup(doc.lookup(doc.catalog(), "Perms"), "DocMDP");
            foreach (var fi in Forms.list(doc)) {
                if (fi.type != FieldType.SIGNATURE) continue;
                var v = doc.lookup(fi.dict, "V");
                if (!v.is_dict()) continue;
                var info = new SignatureInfo();
                info.field = fi.name;
                info.signer = doc.lookup(v, "Name").text_value();
                info.reason = doc.lookup(v, "Reason").text_value();
                info.location = doc.lookup(v, "Location").text_value();
                info.date = doc.lookup(v, "M").text_value();
                info.sub_filter = doc.lookup(v, "SubFilter").name ?? "";
                info.is_timestamp = doc.lookup(v, "Type").is_name("DocTimeStamp");
                var br = doc.lookup(v, "ByteRange");
                int64[] range = {};
                for (int i = 0; i < br.length; i++) range += (int64) doc.resolve(br.at(i)).as_number();
                info.byte_range = range;
                var cobj = doc.lookup(v, "Contents");
                info.contents = cobj.is_string() ? cobj.bytes : new uint8[0];
                int end = info.contents.length;
                while (end > 0 && info.contents[end - 1] == 0) end--;
                info.contents = info.contents[0 : end];
                if (range.length == 4) {
                    info.revision_end = range[2] + range[3];
                    info.covers_whole_file = info.revision_end == doc.data.length || (info.revision_end + 2 >= doc.data.length && tail_is_eof(doc.data, info.revision_end));
                }
                if (fi.widgets.size > 0) {
                    info.page = fi.widgets[0].page;
                    info.rect = fi.widgets[0].rect;
                }
                var sig_ref = fi.dict.get("V");
                if (perms.is_dict() && sig_ref != null && sig_ref.is_ref()) {
                    var pr = doc.lookup(doc.lookup(doc.catalog(), "Perms"), "DocMDP");
                    var raw = doc.lookup(doc.catalog(), "Perms").get("DocMDP");
                    if (raw != null && raw.is_ref() && raw.num == sig_ref.num) {
                        info.certification = true;
                        var refs = doc.lookup(pr, "Reference");
                        if (refs.is_array() && refs.length > 0) info.docmdp = doc.lookup(doc.lookup(doc.resolve(refs.at(0)), "TransformParams"), "P").as_int(2);
                    }
                }
                result.add(info);
            }
            return result;
        }

        private static bool tail_is_eof(uint8[] data, int64 end) {
            for (int64 i = end; i < data.length; i++) {
                uint8 c = data[i];
                if (c != '\n' && c != '\r' && c != ' ' && c != 0) return false;
            }
            return true;
        }

        public static uint8[] signed_bytes(uint8[] data, int64[] range) {
            var b = new ByteArray();
            if (range.length != 4) return b.steal();
            if (range[0] + range[1] > data.length || range[2] + range[3] > data.length) return b.steal();
            b.append(data[range[0] : range[0] + range[1]]);
            b.append(data[range[2] : range[2] + range[3]]);
            return b.steal();
        }

        public static uint8[] revision(uint8[] data, int64 end) {
            return data[0 : int64.min(end, data.length)];
        }
    }
}
