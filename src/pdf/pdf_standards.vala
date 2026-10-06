namespace Singularity.Pdf {

    public enum Severity {
        ERROR,
        WARNING,
        INFO
    }

    public class Issue {
        public string rule;
        public Severity severity;
        public int page;
        public string message;
        public bool fixable;

        public Issue(string rule, Severity severity, int page, string message, bool fixable) {
            this.rule = rule;
            this.severity = severity;
            this.page = page;
            this.message = message;
            this.fixable = fixable;
        }
    }

    public class Standards {
        public static string xml(string s) {
            return Markup.escape_text(s);
        }

        public static string pdfa_part(Document doc) {
            var meta = doc.lookup(doc.catalog(), "Metadata");
            if (!meta.is_stream()) return "";
            string x = (string) terminated(doc.stream_data(meta));
            int i = x.index_of("pdfaid:part");
            if (i < 0) return "";
            int j = i + 11;
            while (j < x.length && (x[j] == '=' || x[j] == '"' || x[j] == '>' || x[j] == ' ' || x[j] == '\'')) j++;
            string part = x.substring(j, 1);
            int k = x.index_of("pdfaid:conformance");
            string conf = "";
            if (k >= 0) {
                int m = k + 18;
                while (m < x.length && (x[m] == '=' || x[m] == '"' || x[m] == '>' || x[m] == ' ' || x[m] == '\'')) m++;
                conf = x.substring(m, 1).down();
            }
            return part + conf;
        }

        public static uint8[] terminated(uint8[] b) {
            var r = new uint8[b.length + 1];
            Memory.copy(r, b, b.length);
            r[b.length] = 0;
            return r;
        }

        private static Gee.ArrayList<Obj> all_fonts(Document doc) {
            var fonts = new Gee.ArrayList<Obj>();
            var seen = new Gee.HashSet<int>();
            var visited = new Gee.HashSet<int>();
            for (int p = 0; p < doc.page_count(); p++) {
                collect_fonts(doc, doc.page_resources(p, false), fonts, seen, visited, 0);
                foreach (var a in Annotations.list(doc, p)) {
                    var ap = doc.lookup(a.dict, "AP");
                    if (!ap.is_dict()) continue;
                    foreach (var k in ap.dict.keys) {
                        var st = doc.lookup(ap, k);
                        if (st.is_stream()) collect_fonts(doc, doc.lookup(st, "Resources"), fonts, seen, visited, 0);
                        else if (st.is_dict()) foreach (var s in st.dict.keys) collect_fonts(doc, doc.lookup(doc.lookup(st, s), "Resources"), fonts, seen, visited, 0);
                    }
                }
            }
            var af = Forms.acroform(doc);
            if (af != null) collect_fonts(doc, doc.lookup(af, "DR"), fonts, seen, visited, 0);
            return fonts;
        }

        private static void collect_fonts(Document doc, Obj res, Gee.ArrayList<Obj> fonts, Gee.HashSet<int> seen, Gee.HashSet<int> visited, int depth) {
            if (!res.is_dict() || depth > 10) return;
            var fd = doc.lookup(res, "Font");
            if (fd.is_dict()) {
                foreach (var k in fd.dict.keys) {
                    var r = fd.get(k);
                    if (r.is_ref()) {
                        if (seen.contains(r.num)) continue;
                        seen.add(r.num);
                    }
                    fonts.add(r);
                    var font = doc.resolve(r);
                    if (doc.lookup(font, "Subtype").is_name("Type3")) collect_fonts(doc, doc.lookup(font, "Resources"), fonts, seen, visited, depth + 1);
                }
            }
            var xo = doc.lookup(res, "XObject");
            if (xo.is_dict()) {
                foreach (var k in xo.dict.keys) {
                    var r = xo.get(k);
                    if (r.is_ref()) {
                        if (visited.contains(r.num)) continue;
                        visited.add(r.num);
                    }
                    var x = doc.resolve(r);
                    if (doc.lookup(x, "Subtype").is_name("Form")) collect_fonts(doc, doc.lookup(x, "Resources"), fonts, seen, visited, depth + 1);
                }
            }
        }

        public static bool font_embedded(Document doc, Obj font_ref) {
            var font = doc.resolve(font_ref);
            var st = doc.lookup(font, "Subtype");
            if (st.is_name("Type3")) return true;
            Obj fd;
            if (st.is_name("Type0")) {
                var desc = doc.lookup(font, "DescendantFonts");
                fd = doc.lookup(desc.is_array() ? doc.resolve(desc.at(0)) : Obj.none(), "FontDescriptor");
            } else {
                fd = doc.lookup(font, "FontDescriptor");
            }
            if (!fd.is_dict()) return false;
            return fd.has("FontFile") || fd.has("FontFile2") || fd.has("FontFile3");
        }

        public static string font_name(Document doc, Obj font_ref) {
            return doc.lookup(doc.resolve(font_ref), "BaseFont").name ?? "?";
        }

        public static bool embed_substitute(Document doc, Obj font_ref) {
            var font = doc.resolve(font_ref);
            var st = doc.lookup(font, "Subtype");
            if (!(st.is_name("TrueType") || st.is_name("Type1") || st.is_name("MMType1"))) return false;
            string base_name = doc.lookup(font, "BaseFont").name ?? "Helvetica";
            var info = FontInfo.load(doc, font_ref, "");
            string pattern = info.family_hint();
            int index;
            string? path = Native.font_match(pattern, out index);
            if (path == null) return false;
            var file = Native.FontFile.open(path, index);
            if (file == null || file.is_cff()) return false;
            if (base_name.contains("Symbol") || base_name.contains("Dingbats")) return false;
            uint8[] program = file.data().get_data();
            int first = 32, last = 255;
            var widths = Obj.array();
            double k = 1000.0 / file.upem();
            for (int c = first; c <= last; c++) {
                unichar u = info.code_unicode[c];
                uint g = u != 0 ? file.glyph(u) : 0;
                double w = info.widths.has_key(c) ? info.widths[c] : (g != 0 ? file.advance(g) * k : 0);
                widths.add(Obj.number(Math.round(w)));
            }
            int a, d, cap, x1, y1, x2, y2;
            file.metrics(out a, out d, out cap, out x1, out y1, out x2, out y2);
            var fd = Obj.dictionary();
            fd.set("Type", Obj.name_obj("FontDescriptor"));
            string ps = file.postscript_name();
            fd.set("FontName", Obj.name_obj(ps));
            fd.set("Flags", Obj.integer(32));
            fd.set("FontBBox", Obj.numbers({ Math.round(x1 * k), Math.round(y1 * k), Math.round(x2 * k), Math.round(y2 * k) }));
            fd.set("ItalicAngle", Obj.integer(0));
            fd.set("Ascent", Obj.number(Math.round(a * k)));
            fd.set("Descent", Obj.number(Math.round(d * k)));
            fd.set("CapHeight", Obj.number(Math.round(cap * k)));
            fd.set("StemV", Obj.integer(80));
            var ff = doc.make_stream(program, true);
            ff.set("Length1", Obj.integer(program.length));
            fd.set("FontFile2", doc.add_ref(ff));
            font.set("Subtype", Obj.name_obj("TrueType"));
            font.set("BaseFont", Obj.name_obj(ps));
            font.set("FirstChar", Obj.integer(first));
            font.set("LastChar", Obj.integer(last));
            font.set("Widths", widths);
            font.set("FontDescriptor", doc.add_ref(fd));
            var enc = doc.lookup(font, "Encoding");
            if (!enc.is_dict() && !enc.is_name("MacRomanEncoding")) font.set("Encoding", Obj.name_obj("WinAnsiEncoding"));
            else if (enc.is_dict()) {
                var diffs = doc.lookup(enc, "Differences");
                if (!diffs.is_array()) font.set("Encoding", Obj.name_obj("WinAnsiEncoding"));
            }
            if (!font.has("ToUnicode")) {
                var cmap = new StringBuilder("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n");
                var pairs = new Gee.ArrayList<string>();
                for (int c = first; c <= last; c++) {
                    unichar u = info.code_unicode[c];
                    if (u != 0 && u < 0xffff) pairs.add("<%02X> <%04X>".printf(c, (uint) u));
                }
                for (int s = 0; s < pairs.size; s += 100) {
                    int e = int.min(pairs.size, s + 100);
                    cmap.append_printf("%d beginbfchar\n", e - s);
                    for (int i = s; i < e; i++) cmap.append(pairs[i] + "\n");
                    cmap.append("endbfchar\n");
                }
                cmap.append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
                font.set("ToUnicode", doc.add_ref(doc.make_stream(cmap.str.data)));
            }
            return true;
        }

        private static bool uses_transparency(Document doc, int page) {
            var res = doc.page_resources(page, false);
            var gs = doc.lookup(res, "ExtGState");
            if (gs.is_dict()) {
                foreach (var k in gs.dict.keys) {
                    var g = doc.lookup(gs, k);
                    var smask = doc.lookup(g, "SMask");
                    if (!smask.is_none() && !smask.is_name("None")) return true;
                    if (doc.lookup(g, "CA").as_number(1) < 1 || doc.lookup(g, "ca").as_number(1) < 1) return true;
                    var bm = doc.lookup(g, "BM");
                    if (bm.is_name() && bm.name != "Normal" && bm.name != "Compatible") return true;
                }
            }
            var xo = doc.lookup(res, "XObject");
            if (xo.is_dict()) {
                foreach (var k in xo.dict.keys) {
                    var x = doc.lookup(xo, k);
                    if (x.has("SMask") || x.has("SMaskInData")) return true;
                    if (doc.lookup(x, "Group").is_dict() && doc.lookup(doc.lookup(x, "Group"), "S").is_name("Transparency")) return true;
                }
            }
            if (doc.lookup(doc.page(page), "Group").is_dict()) return true;
            return false;
        }

        private static bool has_lzw(Document doc) {
            foreach (var e in doc.entries.values) {
                if (e.obj == null || !e.obj.is_stream()) continue;
                var f = doc.lookup(e.obj, "Filter");
                if (f.is_name("LZWDecode") || f.is_name("LZW")) return true;
                if (f.is_array()) for (int i = 0; i < f.length; i++) if (doc.resolve(f.at(i)).is_name("LZWDecode")) return true;
            }
            return false;
        }

        private static bool has_output_intent(Document doc, string subtype) {
            var oi = doc.lookup(doc.catalog(), "OutputIntents");
            if (!oi.is_array()) return false;
            for (int i = 0; i < oi.length; i++) {
                var intent = doc.resolve(oi.at(i));
                if (doc.lookup(intent, "S").is_name(subtype)) return true;
            }
            return false;
        }

        public static Gee.ArrayList<Issue> check_pdfa(Document doc, string level) {
            doc.load_all();
            var issues = new Gee.ArrayList<Issue>();
            bool part1 = level.has_prefix("1");
            bool part3 = level.has_prefix("3");
            if (doc.security != null || doc.trailer.has("Encrypt")) issues.add(new Issue("6.1.3", Severity.ERROR, -1, _("The document is encrypted"), true));
            if (!doc.trailer.has("ID")) issues.add(new Issue("6.1.3", Severity.ERROR, -1, _("The file identifier is missing"), true));
            string current = pdfa_part(doc);
            if (current != level.down()) issues.add(new Issue("6.7.11", Severity.ERROR, -1, _("The XMP metadata does not declare PDF/A-%s").printf(level.up()), true));
            if (!has_output_intent(doc, "GTS_PDFA1")) issues.add(new Issue("6.2.2", Severity.ERROR, -1, _("There is no PDF/A output intent with an ICC profile"), true));
            foreach (var f in all_fonts(doc)) {
                if (!font_embedded(doc, f)) issues.add(new Issue("6.3.4", Severity.ERROR, -1, _("The font %s is not embedded").printf(font_name(doc, f)), true));
            }
            if (has_lzw(doc)) issues.add(new Issue("6.1.10", Severity.ERROR, -1, _("LZW compression is not allowed"), true));
            var names = doc.lookup(doc.catalog(), "Names");
            if (doc.lookup(names, "JavaScript").is_dict() || doc.catalog().has("AA")) issues.add(new Issue("6.6.1", Severity.ERROR, -1, _("The document contains JavaScript"), true));
            if (!part3 && doc.lookup(names, "EmbeddedFiles").is_dict()) issues.add(new Issue("6.1.11", Severity.ERROR, -1, _("Embedded files are not allowed in this conformance level"), true));
            var af = Forms.acroform(doc);
            if (af != null && doc.lookup(af, "NeedAppearances").as_bool(false)) issues.add(new Issue("6.9", Severity.ERROR, -1, _("Form fields rely on the viewer to draw their appearance"), true));
            if (af != null && !doc.lookup(af, "XFA").is_none()) issues.add(new Issue("6.9", Severity.ERROR, -1, _("XFA forms are not allowed"), true));
            for (int p = 0; p < doc.page_count(); p++) {
                foreach (var a in Annotations.list(doc, p)) {
                    if (a.subtype == "Popup") continue;
                    if (a.subtype == "FileAttachment" && !part3) issues.add(new Issue("6.5.3", Severity.ERROR, p, _("File attachment annotations are not allowed"), true));
                    if ((a.flags & 4) == 0 || (a.flags & 3) != 0) issues.add(new Issue("6.5.3", Severity.ERROR, p, _("A %s annotation is not set to print").printf(a.subtype), true));
                    if (a.subtype != "Link" && !doc.lookup(a.dict, "AP").is_dict() && a.rect.width() > 0) issues.add(new Issue("6.5.3", Severity.ERROR, p, _("A %s annotation has no appearance").printf(a.subtype), true));
                    if (doc.lookup(a.dict, "CA").as_number(1) < 1 && part1) issues.add(new Issue("6.5.3", Severity.ERROR, p, _("A %s annotation is transparent").printf(a.subtype), false));
                    var action = doc.lookup(a.dict, "A");
                    var s = doc.lookup(action, "S");
                    if (s.is_name("JavaScript") || s.is_name("Launch") || s.is_name("Sound") || s.is_name("Movie") || s.is_name("ImportData") || s.is_name("ResetForm")) {
                        issues.add(new Issue("6.6.1", Severity.ERROR, p, _("An annotation uses a forbidden action"), true));
                    }
                    if (a.dict.has("AA")) issues.add(new Issue("6.6.2", Severity.ERROR, p, _("An annotation has additional actions"), true));
                }
                if (part1 && uses_transparency(doc, p)) issues.add(new Issue("6.4", Severity.ERROR, p, _("Transparency is not allowed in PDF/A-1"), false));
            }
            return issues;
        }

        private static string pdf_date_to_xmp(string d) {
            var dt = Annotations.parse_date(d);
            if (dt == null) dt = new DateTime.now_local();
            return dt.format_iso8601();
        }

        public static void write_xmp(Document doc, string? pdfa_level, string? pdfx_version, bool pdfua = false) {
            var info = doc.info();
            string title = doc.lookup(info, "Title").text_value();
            string author = doc.lookup(info, "Author").text_value();
            string subject = doc.lookup(info, "Subject").text_value();
            string keywords = doc.lookup(info, "Keywords").text_value();
            string creator = doc.lookup(info, "Creator").text_value();
            string producer = "Singularity Reader";
            info.set("Producer", Obj.text(producer));
            string now = Annotations.date_now();
            if (!info.has("CreationDate")) info.set("CreationDate", Obj.text(now));
            info.set("ModDate", Obj.text(now));
            string created = pdf_date_to_xmp(doc.lookup(info, "CreationDate").text_value());
            string modified = pdf_date_to_xmp(now);
            var s = new StringBuilder();
            s.append("<?xpacket begin=\"\xef\xbb\xbf\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
            s.append("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");
            s.append("<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\"");
            if (pdfa_level != null) s.append(" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"");
            if (pdfx_version != null) s.append(" xmlns:pdfxid=\"http://www.npes.org/pdfx/ns/id/\" xmlns:pdfx=\"http://ns.adobe.com/pdfx/1.3/\"");
            if (pdfua) s.append(" xmlns:pdfuaid=\"http://www.aiim.org/pdfua/ns/id/\"");
            s.append(">\n");
            s.append("<dc:format>application/pdf</dc:format>\n");
            if (title != "") s.append_printf("<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">%s</rdf:li></rdf:Alt></dc:title>\n", xml(title));
            if (author != "") s.append_printf("<dc:creator><rdf:Seq><rdf:li>%s</rdf:li></rdf:Seq></dc:creator>\n", xml(author));
            if (subject != "") s.append_printf("<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">%s</rdf:li></rdf:Alt></dc:description>\n", xml(subject));
            if (keywords != "") s.append_printf("<pdf:Keywords>%s</pdf:Keywords>\n", xml(keywords));
            s.append_printf("<pdf:Producer>%s</pdf:Producer>\n", xml(producer));
            if (creator != "") s.append_printf("<xmp:CreatorTool>%s</xmp:CreatorTool>\n", xml(creator));
            s.append_printf("<xmp:CreateDate>%s</xmp:CreateDate>\n<xmp:ModifyDate>%s</xmp:ModifyDate>\n<xmp:MetadataDate>%s</xmp:MetadataDate>\n", created, modified, modified);
            s.append_printf("<xmpMM:DocumentID>uuid:%s</xmpMM:DocumentID>\n", Uuid.string_random());
            if (pdfa_level != null) {
                s.append_printf("<pdfaid:part>%c</pdfaid:part>\n", pdfa_level[0]);
                if (pdfa_level.length > 1) s.append_printf("<pdfaid:conformance>%s</pdfaid:conformance>\n", pdfa_level.substring(1).up());
            }
            if (pdfx_version != null) {
                s.append_printf("<pdfx:GTS_PDFXVersion>%s</pdfx:GTS_PDFXVersion>\n", xml(pdfx_version));
                if (pdfx_version.contains("X-4")) s.append_printf("<pdfxid:GTS_PDFXVersion>%s</pdfxid:GTS_PDFXVersion>\n", xml(pdfx_version));
            }
            if (pdfua) s.append("<pdfuaid:part>1</pdfuaid:part>\n");
            s.append("</rdf:Description>\n</rdf:RDF>\n</x:xmpmeta>\n");
            for (int i = 0; i < 20; i++) s.append("                                                                                \n");
            s.append("<?xpacket end=\"w\"?>");
            var d = new Dict();
            d.set("Type", Obj.name_obj("Metadata"));
            d.set("Subtype", Obj.name_obj("XML"));
            var stream = Obj.stream(d, s.str.data);
            stream.set("Length", Obj.integer(s.str.length));
            doc.catalog().set("Metadata", doc.add_ref(stream));
        }

        public static void add_srgb_intent(Document doc, string subtype) {
            var profile = Native.srgb_profile();
            if (profile == null) return;
            var d = new Dict();
            d.set("N", Obj.integer(3));
            var icc = doc.make_stream(profile.get_data(), true, d);
            var intent = Obj.dictionary();
            intent.set("Type", Obj.name_obj("OutputIntent"));
            intent.set("S", Obj.name_obj(subtype));
            intent.set("OutputConditionIdentifier", Obj.text("sRGB IEC61966-2.1"));
            intent.set("Info", Obj.text("sRGB IEC61966-2.1"));
            intent.set("RegistryName", Obj.text("http://www.color.org"));
            intent.set("DestOutputProfile", doc.add_ref(icc));
            var arr = doc.sub_array(doc.catalog(), "OutputIntents");
            arr.add(doc.add_ref(intent));
        }

        private static void drop_forbidden_actions(Document doc) {
            var cat = doc.catalog();
            var names = doc.lookup(cat, "Names");
            if (names.is_dict()) names.remove("JavaScript");
            cat.remove("AA");
            var open = doc.lookup(cat, "OpenAction");
            if (open.is_dict() && !doc.lookup(open, "S").is_name("GoTo")) cat.remove("OpenAction");
            for (int p = 0; p < doc.page_count(); p++) {
                doc.page(p).remove("AA");
                foreach (var a in Annotations.list(doc, p)) {
                    a.dict.remove("AA");
                    var action = doc.lookup(a.dict, "A");
                    var s = doc.lookup(action, "S");
                    if (s.is_name("JavaScript") || s.is_name("Launch") || s.is_name("Sound") || s.is_name("Movie") || s.is_name("ImportData") || s.is_name("ResetForm")) a.dict.remove("A");
                }
            }
        }

        public static Gee.ArrayList<Issue> convert_pdfa(Document doc, string level, out SaveOptions save) {
            string lv = level.down();
            bool part3 = lv.has_prefix("3");
            bool part1 = lv.has_prefix("1");
            save = new SaveOptions();
            save.mode = SaveMode.FULL;
            save.remove_security = true;
            save.garbage_collect = true;
            save.version = part1 ? "1.4" : "1.7";
            doc.security = null;
            doc.trailer.remove("Encrypt");
            foreach (var f in all_fonts(doc)) {
                if (!font_embedded(doc, f)) embed_substitute(doc, f);
            }
            drop_forbidden_actions(doc);
            if (!part3) {
                var names = doc.lookup(doc.catalog(), "Names");
                if (names.is_dict()) names.remove("EmbeddedFiles");
                doc.catalog().remove("AF");
                for (int p = 0; p < doc.page_count(); p++) {
                    foreach (var a in Annotations.list(doc, p)) if (a.subtype == "FileAttachment") Annotations.remove(doc, p, a.reference);
                }
            } else {
                foreach (var att in Attachments.list(doc)) {
                    if (!att.spec.has("AFRelationship")) att.spec.set("AFRelationship", Obj.name_obj("Unspecified"));
                }
            }
            var af = Forms.acroform(doc);
            if (af != null) {
                bool needed = doc.lookup(af, "NeedAppearances").as_bool(false);
                af.remove("NeedAppearances");
                af.remove("XFA");
                if (needed) foreach (var fi in Forms.list(doc)) Forms.generate_appearance(doc, fi);
            }
            for (int p = 0; p < doc.page_count(); p++) {
                foreach (var a in Annotations.list(doc, p)) {
                    if (a.subtype == "Popup") continue;
                    int flags = (a.flags | 4) & ~(1 | 2 | 32);
                    a.dict.set("F", Obj.integer(flags));
                    if (a.subtype != "Link" && !doc.lookup(a.dict, "AP").is_dict()) Annotations.regenerate_appearance(doc, a.dict);
                    if (part1) a.dict.remove("CA");
                }
            }
            var oi = doc.lookup(doc.catalog(), "OutputIntents");
            if (!has_output_intent(doc, "GTS_PDFA1")) {
                if (oi.is_array() && oi.length > 0) {
                    for (int i = 0; i < oi.length; i++) {
                        var intent = doc.resolve(oi.at(i));
                        if (doc.lookup(intent, "DestOutputProfile").is_stream()) {
                            var copy = intent.clone();
                            copy.set("S", Obj.name_obj("GTS_PDFA1"));
                            oi.add(doc.add_ref(copy));
                            break;
                        }
                    }
                }
                if (!has_output_intent(doc, "GTS_PDFA1")) add_srgb_intent(doc, "GTS_PDFA1");
            }
            doc.load_all();
            foreach (var e in doc.entries.values) {
                if (e.obj == null || !e.obj.is_stream()) continue;
                var f = doc.lookup(e.obj, "Filter");
                bool lzw = f.is_name("LZWDecode") || (f.is_array() && f.length > 0 && doc.resolve(f.at(0)).is_name("LZWDecode"));
                if (lzw) {
                    try {
                        doc.set_stream_data(e.obj, doc.decode_stream(e.obj));
                    } catch (Error err) {
                    }
                }
            }
            write_xmp(doc, lv, null);
            doc.version = save.version;
            var remaining = check_pdfa(doc, lv);
            var result = new Gee.ArrayList<Issue>();
            foreach (var i in remaining) {
                if (i.rule == "6.1.3" && i.message == _("The document is encrypted")) continue;
                if (i.rule == "6.1.3" && i.message == _("The file identifier is missing")) continue;
                result.add(i);
            }
            return result;
        }

        public static string? cmyk_profile_path() {
            string[] dirs = {};
            dirs += Path.build_filename(Environment.get_user_data_dir(), "color", "icc");
            foreach (var d in Environment.get_system_data_dirs()) dirs += Path.build_filename(d, "color", "icc");
            string? fallback = null;
            foreach (var d in dirs) {
                string? found = search_icc(d, 0, ref fallback);
                if (found != null) return found;
            }
            return fallback;
        }

        private static string? search_icc(string dir, int depth, ref string? fallback) {
            if (depth > 3) return null;
            try {
                var e = Dir.open(dir);
                string? name;
                while ((name = e.read_name()) != null) {
                    string path = Path.build_filename(dir, name);
                    if (FileUtils.test(path, FileTest.IS_DIR)) {
                        var r = search_icc(path, depth + 1, ref fallback);
                        if (r != null) return r;
                        continue;
                    }
                    string l = name.down();
                    if (!l.has_suffix(".icc") && !l.has_suffix(".icm")) continue;
                    uint8[] data;
                    FileUtils.get_data(path, out data);
                    if (Native.profile_channels(data) != 4) continue;
                    if (l.contains("fogra39") || l.contains("coated")) return path;
                    if (fallback == null) fallback = path;
                }
            } catch (Error e) {
            }
            return null;
        }

        private static bool page_uses_rgb(Document doc, int p) {
            var ops = Content.parse(doc.page_content(p));
            foreach (var op in ops) if (op.name == "rg" || op.name == "RG") return true;
            var xo = doc.lookup(doc.page_resources(p, false), "XObject");
            if (xo.is_dict()) {
                foreach (var k in xo.dict.keys) {
                    var x = doc.lookup(xo, k);
                    var cs = doc.lookup(x, "ColorSpace");
                    if (cs.is_name("DeviceRGB")) return true;
                    if (cs.is_array() && cs.length > 1 && doc.resolve(cs.at(0)).is_name("ICCBased") && doc.lookup(doc.resolve(cs.at(1)), "N").as_int(0) == 3) return true;
                }
            }
            return false;
        }

        public static Gee.ArrayList<Issue> check_pdfx(Document doc, string version) {
            doc.load_all();
            var issues = new Gee.ArrayList<Issue>();
            bool x1a = version.down().contains("1a");
            bool x4 = version.contains("4");
            if (doc.security != null) issues.add(new Issue("PDF/X", Severity.ERROR, -1, _("The document is encrypted"), true));
            if (!has_output_intent(doc, "GTS_PDFX")) issues.add(new Issue("PDF/X", Severity.ERROR, -1, _("There is no PDF/X output intent"), true));
            var info = doc.info_if_present();
            string declared = info != null ? doc.lookup(info, "GTS_PDFXVersion").text_value() : "";
            if (declared == "") issues.add(new Issue("PDF/X", Severity.ERROR, -1, _("The PDF/X version is not declared"), true));
            var trapped = info != null ? doc.lookup(info, "Trapped") : Obj.none();
            if (!trapped.is_name("True") && !trapped.is_name("False")) issues.add(new Issue("PDF/X", Severity.ERROR, -1, _("The trapping state is not declared"), true));
            foreach (var f in all_fonts(doc)) {
                if (!font_embedded(doc, f)) issues.add(new Issue("PDF/X", Severity.ERROR, -1, _("The font %s is not embedded").printf(font_name(doc, f)), true));
            }
            for (int p = 0; p < doc.page_count(); p++) {
                var page = doc.page(p);
                if (!page.has("TrimBox") && !page.has("ArtBox")) issues.add(new Issue("PDF/X", Severity.ERROR, p, _("The page has no trim box"), true));
                if (x1a && page_uses_rgb(doc, p)) issues.add(new Issue("PDF/X-1a", Severity.ERROR, p, _("The page uses RGB color"), true));
                if (!x4 && uses_transparency(doc, p)) issues.add(new Issue("PDF/X", Severity.ERROR, p, _("Transparency requires PDF/X-4"), false));
                foreach (var a in Annotations.list(doc, p)) {
                    if (a.subtype == "Link" || a.subtype == "Popup" || a.subtype == "TrapNet" || a.subtype == "PrinterMark") continue;
                    var inside = a.rect;
                    var trim = doc.page_box(p, page.has("TrimBox") ? "TrimBox" : "CropBox");
                    if (inside.intersects(Rect.of(trim[0], trim[1], trim[2], trim[3])) && (a.flags & 4) != 0) {
                        issues.add(new Issue("PDF/X", Severity.WARNING, p, _("A %s annotation prints inside the trim area").printf(a.subtype), false));
                    }
                }
            }
            return issues;
        }

        private static void convert_page_rgb(Document doc, int p, uint8[]? profile) {
            var ops = Content.parse(doc.page_content(p));
            bool changed = false;
            foreach (var op in ops) {
                if ((op.name == "rg" || op.name == "RG") && op.args.size >= 3) {
                    uint8[] rgb = { (uint8) (op.num(0) * 255), (uint8) (op.num(1) * 255), (uint8) (op.num(2) * 255) };
                    uint8[] cmyk = new uint8[4];
                    Native.rgb_to_cmyk(profile, rgb, cmyk, 1);
                    op.args.clear();
                    for (int i = 0; i < 4; i++) op.args.add(Obj.number(Math.round(cmyk[i] / 255.0 * 1000) / 1000));
                    op.name = op.name == "rg" ? "k" : "K";
                    changed = true;
                }
            }
            if (changed) doc.set_page_content(p, Content.serialize(ops));
            var xo = doc.lookup(doc.page_resources(p, false), "XObject");
            if (!xo.is_dict()) return;
            foreach (var k in xo.dict.keys) {
                var r = xo.get(k);
                var x = doc.resolve(r);
                if (!doc.lookup(x, "Subtype").is_name("Image")) continue;
                var cs = doc.lookup(x, "ColorSpace");
                bool rgb = cs.is_name("DeviceRGB") || (cs.is_array() && cs.length > 1 && doc.lookup(doc.resolve(cs.at(1)), "N").as_int(0) == 3);
                if (!rgb) continue;
                var pb = Images.decode(doc, x);
                if (pb == null) continue;
                int w = pb.width, h = pb.height;
                var src = new uint8[w * h * 3];
                unowned uint8[] px = pb.get_pixels_with_length();
                for (int y = 0; y < h; y++) for (int xx = 0; xx < w; xx++) for (int c = 0; c < 3; c++) src[(y * w + xx) * 3 + c] = px[y * pb.rowstride + xx * pb.n_channels + c];
                var cmyk = new uint8[w * h * 4];
                Native.rgb_to_cmyk(profile, src, cmyk, w * h);
                var d = new Dict();
                d.set("Type", Obj.name_obj("XObject"));
                d.set("Subtype", Obj.name_obj("Image"));
                d.set("Width", Obj.integer(w));
                d.set("Height", Obj.integer(h));
                d.set("BitsPerComponent", Obj.integer(8));
                d.set("ColorSpace", Obj.name_obj("DeviceCMYK"));
                var fresh = doc.make_stream(cmyk, true, d);
                var smask = x.get("SMask");
                if (smask != null) fresh.set("SMask", smask);
                if (r.is_ref()) doc.replace(r.num, fresh);
                else xo.set(k, doc.add_ref(fresh));
            }
        }

        public static Gee.ArrayList<Issue> convert_pdfx(Document doc, string version, out SaveOptions save) {
            bool x1a = version.down().contains("1a");
            save = new SaveOptions();
            save.mode = SaveMode.FULL;
            save.remove_security = true;
            save.garbage_collect = true;
            save.version = x1a ? "1.4" : (version.contains("4") ? "1.6" : "1.4");
            doc.security = null;
            doc.trailer.remove("Encrypt");
            foreach (var f in all_fonts(doc)) {
                if (!font_embedded(doc, f)) embed_substitute(doc, f);
            }
            string? path = cmyk_profile_path();
            uint8[]? profile = null;
            if (path != null) {
                try {
                    FileUtils.get_data(path, out profile);
                } catch (Error e) {
                    profile = null;
                }
            }
            for (int p = 0; p < doc.page_count(); p++) {
                var page = doc.page(p);
                if (!page.has("TrimBox") && !page.has("ArtBox")) {
                    var crop = doc.page_box(p, "CropBox");
                    page.set("TrimBox", Obj.numbers(crop));
                }
                if (x1a) convert_page_rgb(doc, p, profile);
            }
            if (!has_output_intent(doc, "GTS_PDFX")) {
                var intent = Obj.dictionary();
                intent.set("Type", Obj.name_obj("OutputIntent"));
                intent.set("S", Obj.name_obj("GTS_PDFX"));
                string desc = "FOGRA39";
                if (profile != null) {
                    string? described = Native.profile_description(profile);
                    desc = described != null && described != "" ? described : "CMYK";
                }
                intent.set("OutputConditionIdentifier", Obj.text(profile != null && desc.contains("FOGRA39") ? "FOGRA39" : (profile != null ? "Custom" : "FOGRA39")));
                intent.set("OutputCondition", Obj.text(desc));
                intent.set("Info", Obj.text(desc));
                intent.set("RegistryName", Obj.text("http://www.color.org"));
                if (profile != null) {
                    var d = new Dict();
                    d.set("N", Obj.integer(4));
                    intent.set("DestOutputProfile", doc.add_ref(doc.make_stream(profile, true, d)));
                }
                doc.sub_array(doc.catalog(), "OutputIntents").add(doc.add_ref(intent));
            }
            var info = doc.info();
            string v = x1a ? "PDF/X-1a:2003" : (version.contains("4") ? "PDF/X-4" : "PDF/X-3:2003");
            info.set("GTS_PDFXVersion", Obj.text(v));
            if (x1a) info.set("GTS_PDFXConformance", Obj.text("PDF/X-1a:2003"));
            if (!info.has("Trapped") || !(doc.lookup(info, "Trapped").is_name("True") || doc.lookup(info, "Trapped").is_name("False"))) info.set("Trapped", Obj.name_obj("False"));
            if (!info.has("Title")) info.set("Title", Obj.text(""));
            write_xmp(doc, null, v);
            doc.version = save.version;
            return check_pdfx(doc, version);
        }

        public static Gee.ArrayList<Issue> check_pdfua(Document doc) {
            var issues = new Gee.ArrayList<Issue>();
            var cat = doc.catalog();
            var mark = doc.lookup(cat, "MarkInfo");
            if (!doc.lookup(mark, "Marked").as_bool(false)) issues.add(new Issue("7.1", Severity.ERROR, -1, _("The document is not marked as tagged"), true));
            if (!doc.lookup(cat, "StructTreeRoot").is_dict()) issues.add(new Issue("7.1", Severity.ERROR, -1, _("The document has no structure tree"), true));
            if (doc.lookup(cat, "Lang").text_value() == "") issues.add(new Issue("7.2", Severity.ERROR, -1, _("The document language is not set"), true));
            var info = doc.info_if_present();
            if (info == null || doc.lookup(info, "Title").text_value().strip() == "") issues.add(new Issue("7.1", Severity.ERROR, -1, _("The document has no title"), true));
            if (!doc.lookup(doc.lookup(cat, "ViewerPreferences"), "DisplayDocTitle").as_bool(false)) issues.add(new Issue("7.1", Severity.ERROR, -1, _("The title is not shown in the window"), true));
            foreach (var f in all_fonts(doc)) {
                if (!font_embedded(doc, f)) issues.add(new Issue("7.21", Severity.ERROR, -1, _("The font %s is not embedded").printf(font_name(doc, f)), true));
            }
            foreach (var node in Tags.read(doc)) {
                if (node.role == "Figure" && node.alt.strip() == "") issues.add(new Issue("7.3", Severity.ERROR, node.page, _("A figure has no alternate text"), true));
            }
            for (int p = 0; p < doc.page_count(); p++) {
                if (!doc.lookup(doc.page(p), "Tabs").is_name("S") && Annotations.list(doc, p).size > 0) issues.add(new Issue("7.18", Severity.ERROR, p, _("The tab order does not follow the structure"), true));
                int untagged = Tags.untagged_content(doc, p);
                if (untagged > 0) issues.add(new Issue("7.1", Severity.ERROR, p, _("%d content items are neither tagged nor artifacts").printf(untagged), true));
            }
            return issues;
        }
    }
}
