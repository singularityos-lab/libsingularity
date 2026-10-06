namespace Singularity.Pdf {

    public class RedactionReport {
        public int glyphs_removed = 0;
        public int images_removed = 0;
        public int images_cleaned = 0;
        public int paths_removed = 0;
        public int annotations_removed = 0;
        public bool verified = false;
        public Gee.ArrayList<string> leftovers = new Gee.ArrayList<string>();
    }

    public class Redaction {
        private static bool hits(Rect box, Rect[] areas) {
            foreach (var a in areas) {
                if (box.intersects(a) && (box.overlap_ratio(a) > 0.15 || box.center_inside(a))) return true;
            }
            return false;
        }

        private static bool path_hits(Rect box, Rect[] areas) {
            foreach (var a in areas) {
                if (box.intersects(a) && box.overlap_ratio(a) >= 0.5) return true;
            }
            return false;
        }

        private static string f(double v) {
            return Obj.format_number(Math.round(v * 1000) / 1000);
        }

        private static Op rebuild_text(Op original, Item item, Rect[] areas, ref int removed) {
            var elements = new Gee.ArrayList<Obj>();
            if (original.name == "TJ" && original.args.size > 0 && original.args[0].is_array()) elements.add_all(original.args[0].items);
            else if (original.args.size > 0) elements.add(original.args[original.args.size - 1]);
            double tfs = item.font_size != 0 ? item.font_size : 1;
            var arr = Obj.array();
            int gi = 0;
            for (int e = 0; e < elements.size; e++) {
                var el = elements[e];
                if (!el.is_string()) {
                    arr.add(el);
                    continue;
                }
                var keep = new ByteArray();
                double pending = 0;
                while (gi < item.glyphs.size && item.glyphs[gi].element == e) {
                    var g = item.glyphs[gi];
                    if (hits(g.box, areas)) {
                        if (keep.len > 0) {
                            arr.add(Obj.str(keep.steal(), el.hex));
                            keep = new ByteArray();
                        }
                        double word = g.space ? item.word_spacing : 0;
                        pending += -(g.width * tfs + item.char_spacing + word) * 1000 / tfs;
                        removed++;
                    } else {
                        if (pending != 0) {
                            arr.add(Obj.number(Math.round(pending * 1000) / 1000));
                            pending = 0;
                        }
                        keep.append(el.bytes[g.offset : g.offset + g.length]);
                    }
                    gi++;
                }
                if (keep.len > 0) arr.add(Obj.str(keep.steal(), el.hex));
                if (pending != 0) arr.add(Obj.number(Math.round(pending * 1000) / 1000));
            }
            return new Op.with("TJ", { arr });
        }

        private static void blank_pixels(Gdk.Pixbuf pb, Matrix ctm, Rect[] areas) {
            var inv = ctm.inverse();
            int w = pb.width, h = pb.height;
            unowned uint8[] px = pb.get_pixels_with_length();
            int stride = pb.rowstride, n = pb.n_channels;
            foreach (var a in areas) {
                var r = Rect.empty();
                double ux, uy;
                inv.apply(a.x1, a.y1, out ux, out uy); r.add(ux, uy);
                inv.apply(a.x2, a.y1, out ux, out uy); r.add(ux, uy);
                inv.apply(a.x1, a.y2, out ux, out uy); r.add(ux, uy);
                inv.apply(a.x2, a.y2, out ux, out uy); r.add(ux, uy);
                int x1 = (int) Math.floor(r.x1 * w).clamp(0, w), x2 = (int) Math.ceil(r.x2 * w).clamp(0, w);
                int y1 = (int) Math.floor((1 - r.y2) * h).clamp(0, h), y2 = (int) Math.ceil((1 - r.y1) * h).clamp(0, h);
                for (int y = y1; y < y2; y++) {
                    for (int x = x1; x < x2; x++) {
                        int o = y * stride + x * n;
                        px[o] = 0;
                        px[o + 1] = 0;
                        px[o + 2] = 0;
                    }
                }
            }
        }

        private static bool axis_aligned(Matrix m) {
            return m.b.abs() < 1e-6 && m.c.abs() < 1e-6;
        }

        private static bool fully_inside(Rect box, Rect[] areas) {
            foreach (var a in areas) {
                if (box.x1 >= a.x1 - 0.5 && box.x2 <= a.x2 + 0.5 && box.y1 >= a.y1 - 0.5 && box.y2 <= a.y2 + 0.5) return true;
            }
            return false;
        }

        public static RedactionReport apply(Document doc, int page, Rect[] areas, double[]? fill = null, string overlay = "") {
            var report = new RedactionReport();
            if (areas.length == 0) return report;
            var it = new Interpreter(doc);
            it.run_page(page);
            var remove_ops = new Gee.HashMap<Gee.ArrayList<Op>, Gee.HashSet<int>>();
            var inserts = new Gee.HashMap<Op, Gee.ArrayList<Op>>();
            int removed = 0;
            foreach (var item in it.items) {
                var ops = it.ops_for(item);
                switch (item.kind) {
                    case ItemKind.TEXT:
                        bool any = false;
                        foreach (var g in item.glyphs) if (hits(g.box, areas)) any = true;
                        if (!any) break;
                        var op = ops[item.op_index];
                        var rebuilt = rebuild_text(op, item, areas, ref removed);
                        if (op.name == "'" || op.name == "\"") {
                            var pre = new Gee.ArrayList<Op>();
                            if (op.name == "\"" && op.args.size >= 2) {
                                pre.add(new Op.with("Tw", { op.args[0] }));
                                pre.add(new Op.with("Tc", { op.args[1] }));
                            }
                            pre.add(new Op("T*"));
                            inserts[rebuilt] = pre;
                        }
                        ops[item.op_index] = rebuilt;
                        if (item.form != null) item.form.modified = true;
                        break;
                    case ItemKind.IMAGE:
                        bool touch = false;
                        foreach (var a in areas) if (item.box.intersects(a)) touch = true;
                        if (!touch) break;
                        bool cleaned = false;
                        if (item.xobject != "" && !fully_inside(item.box, areas) && axis_aligned(item.ctm)) {
                            var res = item.form != null ? item.form.resources : doc.page_resources(page);
                            var xo = doc.sub_dict(res, "XObject");
                            var x = doc.resolve(xo.get(item.xobject));
                            var pb = Images.decode(doc, x);
                            if (pb != null) {
                                blank_pixels(pb, item.ctm, areas);
                                try {
                                    var fresh = Images.pixbuf_xobject(doc, pb);
                                    var smask = x.get("SMask");
                                    if (smask != null) doc.resolve(fresh).set("SMask", smask);
                                    string name = Editor.unique_resource(xo, "Rx");
                                    xo.set(name, fresh);
                                    ops[item.op_index] = new Op.with("Do", { Obj.name_obj(name) });
                                    cleaned = true;
                                    report.images_cleaned++;
                                } catch (Error e) {
                                }
                            }
                        }
                        if (!cleaned) {
                            if (!remove_ops.has_key(ops)) remove_ops[ops] = new Gee.HashSet<int>();
                            remove_ops[ops].add(item.op_index);
                            report.images_removed++;
                        }
                        if (item.form != null) item.form.modified = true;
                        break;
                    case ItemKind.PATH:
                        if (!path_hits(item.box, areas)) break;
                        if (!remove_ops.has_key(ops)) remove_ops[ops] = new Gee.HashSet<int>();
                        for (int k = item.op_start; k < item.op_index; k++) {
                            var name = ops[k].name;
                            if (name == "m" || name == "l" || name == "c" || name == "v" || name == "y" || name == "re" || name == "h") remove_ops[ops].add(k);
                        }
                        ops[item.op_index] = new Op("n");
                        report.paths_removed++;
                        if (item.form != null) item.form.modified = true;
                        break;
                    default:
                        break;
                }
            }
            report.glyphs_removed = removed;
            foreach (var e in remove_ops.entries) {
                var list = new Gee.ArrayList<int>();
                list.add_all(e.value);
                list.sort((a, b) => b - a);
                foreach (int idx in list) e.key.remove_at(idx);
            }
            if (inserts.size > 0) {
                var lists = new Gee.ArrayList<Gee.ArrayList<Op>>();
                lists.add(it.ops);
                foreach (var form in it.forms.values) lists.add(form.ops);
                foreach (var list in lists) {
                    for (int i = list.size - 1; i >= 0; i--) {
                        if (!inserts.has_key(list[i])) continue;
                        var pre = inserts[list[i]];
                        for (int k = pre.size - 1; k >= 0; k--) list.insert(i, pre[k]);
                    }
                }
            }
            Editor.commit(doc, it);
            var annots = Annotations.list(doc, page);
            foreach (var a in annots) {
                foreach (var area in areas) {
                    if (a.rect.intersects(area) && a.subtype != "Popup") {
                        if (a.subtype == "Widget") {
                            a.dict.set("V", Obj.text(""));
                            var parent = doc.resolve(a.dict.get("Parent"));
                            if (parent.is_dict()) parent.set("V", Obj.text(""));
                        }
                        Annotations.remove(doc, page, a.reference);
                        report.annotations_removed++;
                        break;
                    }
                }
            }
            verify(doc, page, areas, report);
            var color = fill ?? new double[] { 0, 0, 0 };
            var overlay_ops = new StringBuilder("q\n");
            overlay_ops.append_printf("%s %s %s rg\n", f(color[0]), f(color[1]), f(color[2]));
            foreach (var a in areas) overlay_ops.append_printf("%s %s %s %s re f\n", f(a.x1), f(a.y1), f(a.width()), f(a.height()));
            overlay_ops.append("Q\n");
            if (overlay != "") {
                var font = EmbeddedFont.for_pattern(doc, "sans-serif:bold");
                if (font != null) {
                    var res = doc.page_resources(page);
                    var fonts = doc.sub_dict(res, "Font");
                    string name = Editor.unique_resource(fonts, "RF");
                    fonts.set(name, font.font_ref);
                    double lum = color[0] * 0.3 + color[1] * 0.59 + color[2] * 0.11;
                    foreach (var a in areas) {
                        double size = double.min(10, a.height() * 0.7);
                        double w = font.measure(overlay, size);
                        if (w > a.width() || size < 3) continue;
                        overlay_ops.append_printf("q BT %s g /%s %s Tf 1 0 0 1 %s %s Tm %s Tj ET Q\n", lum > 0.5 ? "0" : "1", name, f(size),
                            f(a.x1 + (a.width() - w) / 2), f(a.y1 + (a.height() - size * 0.7) / 2), font.hex(overlay));
                    }
                }
            }
            doc.append_page_content(page, overlay_ops.str.data);
            return report;
        }

        public static void verify(Document doc, int page, Rect[] areas, RedactionReport report) {
            var it = new Interpreter(doc);
            it.run_page(page);
            report.leftovers.clear();
            foreach (var item in it.items) {
                switch (item.kind) {
                    case ItemKind.TEXT:
                        foreach (var g in item.glyphs) {
                            if (hits(g.box, areas) && g.text.strip() != "") report.leftovers.add("text \"%s\"".printf(g.text));
                        }
                        break;
                    case ItemKind.IMAGE:
                        foreach (var a in areas) {
                            if (!item.box.intersects(a)) continue;
                            bool clean = item.xobject.has_prefix("Rx");
                            if (clean) {
                                var res = item.form != null ? item.form.resources : doc.page_resources(page);
                                var pb = Images.decode(doc, doc.lookup(doc.lookup(res, "XObject"), item.xobject));
                                if (pb == null || !region_is_black(pb, item.ctm, a)) clean = false;
                            }
                            if (!clean) report.leftovers.add("image %s".printf(item.xobject));
                            break;
                        }
                        break;
                    case ItemKind.PATH:
                        if (path_hits(item.box, areas)) report.leftovers.add("vector graphics");
                        break;
                    default:
                        break;
                }
            }
            report.verified = report.leftovers.size == 0;
        }

        private static bool region_is_black(Gdk.Pixbuf pb, Matrix ctm, Rect a) {
            var inv = ctm.inverse();
            int w = pb.width, h = pb.height;
            var r = Rect.empty();
            double ux, uy;
            inv.apply(a.x1, a.y1, out ux, out uy); r.add(ux, uy);
            inv.apply(a.x2, a.y2, out ux, out uy); r.add(ux, uy);
            int x1 = (int) Math.ceil(r.x1 * w).clamp(0, w), x2 = (int) Math.floor(r.x2 * w).clamp(0, w);
            int y1 = (int) Math.ceil((1 - r.y2) * h).clamp(0, h), y2 = (int) Math.floor((1 - r.y1) * h).clamp(0, h);
            unowned uint8[] px = pb.get_pixels_with_length();
            for (int y = y1; y < y2; y++) {
                for (int x = x1; x < x2; x++) {
                    int o = y * pb.rowstride + x * pb.n_channels;
                    if (px[o] > 8 || px[o + 1] > 8 || px[o + 2] > 8) return false;
                }
            }
            return true;
        }

        public static Obj mark(Document doc, int page, Rect area, string overlay, string author) {
            var a = Obj.dictionary();
            a.set("Subtype", Obj.name_obj("Redact"));
            a.set("Rect", Obj.numbers({ area.x1, area.y1, area.x2, area.y2 }));
            a.set("QuadPoints", Obj.numbers({ area.x1, area.y2, area.x2, area.y2, area.x1, area.y1, area.x2, area.y1 }));
            a.set("IC", Obj.numbers({ 0, 0, 0 }));
            a.set("C", Obj.numbers({ 0.9, 0.1, 0.1 }));
            if (overlay != "") a.set("OverlayText", Obj.text(overlay));
            if (author != "") a.set("T", Obj.text(author));
            string ops = "0.9 0.1 0.1 RG 1.5 w %s %s %s %s re S\n".printf(f(area.x1 + 0.75), f(area.y1 + 0.75), f(area.width() - 1.5), f(area.height() - 1.5));
            a.set("AP", Annotations.appearance(doc, area, ops));
            return Annotations.add(doc, page, a);
        }

        public static Gee.ArrayList<RedactionReport> apply_marked(Document doc) {
            var reports = new Gee.ArrayList<RedactionReport>();
            for (int p = 0; p < doc.page_count(); p++) {
                Rect[] areas = {};
                string overlay = "";
                double[] color = { 0, 0, 0 };
                foreach (var a in Annotations.list(doc, p)) {
                    if (a.subtype != "Redact") continue;
                    var q = doc.lookup(a.dict, "QuadPoints");
                    if (q.is_array() && q.length >= 8) {
                        for (int i = 0; i + 7 < q.length; i += 8) {
                            var r = Rect.empty();
                            for (int k = 0; k < 8; k += 2) r.add(q.at(i + k).as_number(), q.at(i + k + 1).as_number());
                            areas += r;
                        }
                    } else {
                        areas += a.rect;
                    }
                    var ot = doc.lookup(a.dict, "OverlayText");
                    if (ot.is_string()) overlay = ot.text_value();
                    var ic = doc.lookup(a.dict, "IC");
                    if (ic.is_array() && ic.length == 3) color = { ic.at(0).as_number(), ic.at(1).as_number(), ic.at(2).as_number() };
                    Annotations.remove(doc, p, a.reference);
                }
                if (areas.length > 0) reports.add(apply(doc, p, areas, color, overlay));
            }
            return reports;
        }

        public static Gee.ArrayList<Rect?> find_text(Document doc, int page, Regex pattern) {
            var result = new Gee.ArrayList<Rect?>();
            var it = new Interpreter(doc);
            it.run_page(page);
            var glyphs = new Gee.ArrayList<Glyph>();
            var text = new StringBuilder();
            var starts = new Gee.ArrayList<int>();
            double last_y = double.MAX;
            foreach (var item in it.items) {
                if (item.kind != ItemKind.TEXT) continue;
                foreach (var g in item.glyphs) {
                    double y = (g.box.y1 + g.box.y2) / 2;
                    if (last_y != double.MAX && (y - last_y).abs() > g.box.height() * 0.6) {
                        text.append_c('\n');
                        starts.add(-1);
                    }
                    last_y = y;
                    for (int k = 0; k < g.text.length; k++) starts.add(glyphs.size);
                    if (g.text.length == 0) continue;
                    text.append(g.text);
                    glyphs.add(g);
                }
            }
            MatchInfo info;
            if (!pattern.match(text.str, 0, out info)) return result;
            do {
                int s, e;
                info.fetch_pos(0, out s, out e);
                var box = Rect.empty();
                double line_y = double.MAX;
                for (int b = s; b < e && b < starts.size; b++) {
                    int gi = starts[b];
                    if (gi < 0) continue;
                    var g = glyphs[gi];
                    double y = (g.box.y1 + g.box.y2) / 2;
                    if (line_y != double.MAX && (y - line_y).abs() > g.box.height() * 0.6) {
                        result.add(box);
                        box = Rect.empty();
                    }
                    line_y = y;
                    box.union(g.box);
                }
                if (!box.is_empty()) result.add(box);
                bool more;
                try {
                    more = info.next();
                } catch (RegexError e) {
                    more = false;
                }
                if (!more) break;
            } while (true);
            return result;
        }
    }
}
