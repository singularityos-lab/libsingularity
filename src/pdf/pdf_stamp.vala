namespace Singularity.Pdf {

    public class HeaderFooter {
        public string top_left = "";
        public string top_center = "";
        public string top_right = "";
        public string bottom_left = "";
        public string bottom_center = "";
        public string bottom_right = "";
        public string family = "sans-serif";
        public double size = 9;
        public double[] color = { 0.2, 0.2, 0.2 };
        public double margin_x = 36;
        public double margin_y = 24;
        public int first_page = 0;
        public int last_page = -1;
        public int start_number = 1;
        public string bates_prefix = "";
        public string bates_suffix = "";
        public int bates_digits = 6;
        public int bates_start = 1;
        public string file_name = "";
    }

    public class Watermark {
        public string text = "";
        public string image_path = "";
        public string family = "sans-serif:bold";
        public double size = 72;
        public double[] color = { 0.8, 0.1, 0.1 };
        public double opacity = 0.25;
        public double rotation = 45;
        public double scale = 0.5;
        public bool behind = false;
        public int first_page = 0;
        public int last_page = -1;
    }

    public class Stamps {
        private static string f(double v) {
            return Obj.format_number(Math.round(v * 1000) / 1000);
        }

        public static string expand(string template, int page, int total, int number, HeaderFooter hf) {
            string bates = hf.bates_prefix + "%0*d".printf(hf.bates_digits, hf.bates_start + page - hf.first_page) + hf.bates_suffix;
            var now = new DateTime.now_local();
            return template.replace("<<page>>", number.to_string())
                .replace("<<pages>>", total.to_string())
                .replace("<<date>>", now.format("%x"))
                .replace("<<time>>", now.format("%X"))
                .replace("<<bates>>", bates)
                .replace("<<file>>", hf.file_name);
        }

        private static Obj gs_resource(Document doc, Obj res, double opacity, out string name) {
            var gs = doc.sub_dict(res, "ExtGState");
            name = Editor.unique_resource(gs, "SGS");
            var g = Obj.dictionary();
            g.set("Type", Obj.name_obj("ExtGState"));
            g.set("CA", Obj.number(opacity));
            g.set("ca", Obj.number(opacity));
            gs.set(name, g);
            return g;
        }

        public static int apply_header_footer(Document doc, HeaderFooter hf) {
            var font = EmbeddedFont.for_pattern(doc, hf.family);
            if (font == null) return 0;
            int total = doc.page_count();
            int last = hf.last_page < 0 ? total - 1 : int.min(total - 1, hf.last_page);
            int count = 0;
            for (int p = hf.first_page; p <= last; p++) {
                var box = doc.page_box(p, "CropBox");
                var res = doc.page_resources(p);
                var fonts = doc.sub_dict(res, "Font");
                string name = Editor.unique_resource(fonts, "HF");
                fonts.set(name, font.font_ref);
                int number = hf.start_number + p - hf.first_page;
                var ops = new StringBuilder();
                string[] texts = { hf.top_left, hf.top_center, hf.top_right, hf.bottom_left, hf.bottom_center, hf.bottom_right };
                for (int i = 0; i < 6; i++) {
                    if (texts[i].strip() == "") continue;
                    string t = expand(texts[i], p, total, number, hf);
                    double w = font.measure(t, hf.size);
                    double x;
                    switch (i % 3) {
                        case 0: x = box[0] + hf.margin_x; break;
                        case 1: x = (box[0] + box[2] - w) / 2; break;
                        default: x = box[2] - hf.margin_x - w; break;
                    }
                    double y = i < 3 ? box[3] - hf.margin_y - hf.size * 0.8 : box[1] + hf.margin_y;
                    string subtype = i < 3 ? "Header" : "Footer";
                    ops.append_printf("/Artifact <</Type /Pagination /Subtype /%s>> BDC\nq BT %s %s %s rg /%s %s Tf 1 0 0 1 %s %s Tm %s Tj ET Q\nEMC\n",
                        subtype, f(hf.color[0]), f(hf.color[1]), f(hf.color[2]), name, f(hf.size), f(x), f(y), font.hex(t));
                }
                if (ops.len == 0) continue;
                int rot = doc.page_rotation(p);
                if (rot != 0) {
                    ops.prepend(rotate_prefix(box, rot));
                    ops.append("Q\n");
                }
                doc.append_page_content(p, ops.str.data);
                count++;
            }
            return count;
        }

        private static string rotate_prefix(double[] box, int rot) {
            double w = box[2] - box[0], h = box[3] - box[1];
            switch (rot) {
                case 90: return "q 0 1 -1 0 %s %s cm\n".printf(f(box[0] + w + box[1]), f(box[1] - box[0]));
                case 180: return "q -1 0 0 -1 %s %s cm\n".printf(f(box[0] * 2 + w), f(box[1] * 2 + h));
                case 270: return "q 0 -1 1 0 %s %s cm\n".printf(f(box[0] - box[1]), f(box[1] + h + box[0]));
                default: return "q\n";
            }
        }

        public static int apply_watermark(Document doc, Watermark wm) throws Error {
            int total = doc.page_count();
            int last = wm.last_page < 0 ? total - 1 : int.min(total - 1, wm.last_page);
            EmbeddedFont? font = null;
            Obj? image = null;
            int iw = 0, ih = 0;
            if (wm.image_path != "") image = Images.from_file(doc, wm.image_path, out iw, out ih);
            else font = EmbeddedFont.for_pattern(doc, wm.family);
            if (font == null && image == null) return 0;
            int count = 0;
            for (int p = wm.first_page; p <= last; p++) {
                var box = doc.page_box(p, "CropBox");
                var res = doc.page_resources(p);
                string gs_name;
                gs_resource(doc, res, wm.opacity, out gs_name);
                double cx = (box[0] + box[2]) / 2, cy = (box[1] + box[3]) / 2;
                double a = wm.rotation * Math.PI / 180;
                var ops = new StringBuilder();
                ops.append_printf("/Artifact <</Type /Pagination /Subtype /Watermark>> BDC\nq /%s gs %s %s %s %s %s %s cm\n", gs_name,
                    f(Math.cos(a)), f(Math.sin(a)), f(-Math.sin(a)), f(Math.cos(a)), f(cx), f(cy));
                if (image != null) {
                    var xo = doc.sub_dict(res, "XObject");
                    string name = Editor.unique_resource(xo, "WM");
                    xo.set(name, image);
                    double pw = (box[2] - box[0]) * wm.scale;
                    double ph = pw * ih / double.max(1, iw);
                    ops.append_printf("%s 0 0 %s %s %s cm /%s Do\n", f(pw), f(ph), f(-pw / 2), f(-ph / 2), name);
                } else {
                    var fonts = doc.sub_dict(res, "Font");
                    string name = Editor.unique_resource(fonts, "WF");
                    fonts.set(name, font.font_ref);
                    double w = font.measure(wm.text, wm.size);
                    ops.append_printf("BT %s %s %s rg /%s %s Tf 1 0 0 1 %s %s Tm %s Tj ET\n", f(wm.color[0]), f(wm.color[1]), f(wm.color[2]),
                        name, f(wm.size), f(-w / 2), f(-wm.size * 0.35), font.hex(wm.text));
                }
                ops.append("Q\nEMC\n");
                if (wm.behind) doc.append_page_content(p, ops.str.data, true);
                else doc.append_page_content(p, ops.str.data);
                count++;
            }
            return count;
        }

        public static int remove_pagination(Document doc, string subtype) {
            int removed = 0;
            for (int p = 0; p < doc.page_count(); p++) {
                var ops = Content.parse(doc.page_content(p));
                var out_ops = new Gee.ArrayList<Op>();
                int skip = 0;
                int depth = 0;
                foreach (var op in ops) {
                    if (op.name == "BDC" || op.name == "BMC") {
                        depth++;
                        if (skip == 0 && op.name == "BDC" && op.args.size > 1 && op.args[0].is_name("Artifact") && op.args[1].is_dict()) {
                            var st = op.args[1].get("Subtype");
                            var type = op.args[1].get("Type");
                            if (type != null && type.is_name("Pagination") && st != null && st.is_name(subtype)) {
                                skip = depth;
                                removed++;
                                continue;
                            }
                        }
                    } else if (op.name == "EMC") {
                        if (skip > 0 && depth == skip) {
                            skip = 0;
                            depth--;
                            continue;
                        }
                        depth--;
                    }
                    if (skip > 0) continue;
                    out_ops.add(op);
                }
                if (out_ops.size != ops.size) doc.set_page_content(p, Content.serialize(out_ops));
            }
            return removed;
        }
    }
}
