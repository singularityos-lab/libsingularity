namespace Singularity.Pdf {

    public class TextLine {
        public Gee.ArrayList<Item> items = new Gee.ArrayList<Item>();
        public Rect box = Rect.empty();
        public double baseline;
        public double size;

        public string text() {
            var s = new StringBuilder();
            double last_x = -double.MAX;
            foreach (var it in items) {
                foreach (var g in it.glyphs) {
                    if (last_x > -double.MAX && g.box.x1 - last_x > size * 0.2 && !g.space && !s.str.has_suffix(" ")) s.append_c(' ');
                    s.append(g.text);
                    last_x = g.box.x2;
                }
            }
            return s.str;
        }
    }

    public class TextBlock {
        public int page;
        public Rect box = Rect.empty();
        public Gee.ArrayList<TextLine> lines = new Gee.ArrayList<TextLine>();
        public double size;
        public double line_height;
        public FontInfo? font;
        public double[] color = { 0, 0, 0 };
        public bool in_form = false;
        public string role = "P";

        public string text() {
            var s = new StringBuilder();
            foreach (var l in lines) {
                if (s.len > 0) s.append_c('\n');
                s.append(l.text().strip());
            }
            return s.str;
        }

        public Gee.ArrayList<Item> items() {
            var list = new Gee.ArrayList<Item>();
            foreach (var l in lines) list.add_all(l.items);
            return list;
        }
    }

    public class EditResult {
        public bool substituted = false;
        public string font_family = "";
        public string message = "";
    }

    public class Editor {
        public static Gee.ArrayList<TextBlock> blocks_from(Interpreter it, int page) {
            var lines = new Gee.ArrayList<TextLine>();
            foreach (var item in it.items) {
                if (item.kind != ItemKind.TEXT || item.glyphs.size == 0) continue;
                if (item.text().strip() == "") continue;
                double size = item.box.height() * 0.8;
                double base_y = item.glyphs[0].origin_y;
                TextLine? target = null;
                if (lines.size > 0) {
                    var last = lines[lines.size - 1];
                    bool same_line = (last.baseline - base_y).abs() < double.max(1.5, last.size * 0.3);
                    bool near = item.box.x1 - last.box.x2 < double.max(last.size, size) * 1.5 && item.box.x2 > last.box.x1 - 2;
                    if (same_line && near) target = last;
                }
                if (target == null) {
                    target = new TextLine();
                    target.baseline = base_y;
                    target.size = size;
                    lines.add(target);
                }
                target.items.add(item);
                target.box.union(item.box);
                target.size = double.max(target.size, size);
            }
            var blocks = new Gee.ArrayList<TextBlock>();
            foreach (var line in lines) {
                TextBlock? target = null;
                foreach (var b in blocks) {
                    var last = b.lines[b.lines.size - 1];
                    double gap = last.box.y1 - line.box.y2;
                    bool sizes = (last.size - line.size).abs() < double.max(1.2, last.size * 0.2);
                    bool aligned = line.box.x1 < b.box.x2 && line.box.x2 > b.box.x1;
                    if (gap > -line.size * 0.3 && gap < line.size * 0.9 && sizes && aligned) {
                        target = b;
                        break;
                    }
                }
                if (target == null) {
                    target = new TextBlock();
                    target.page = page;
                    target.size = line.size;
                    var first = line.items[0];
                    target.font = first.font;
                    target.color = first.fill_rgb;
                    target.in_form = first.form != null;
                    blocks.add(target);
                }
                target.lines.add(line);
                target.box.union(line.box);
                if (line.items[0].form != null) target.in_form = true;
            }
            foreach (var b in blocks) {
                double font_size = 0;
                var first = b.lines[0].items[0];
                font_size = first.font_size * first.text_matrix.scale_y() * first.ctm.scale_y();
                if (font_size > 0) b.size = font_size;
                if (b.lines.size > 1) {
                    b.line_height = (b.lines[0].baseline - b.lines[b.lines.size - 1].baseline) / (b.lines.size - 1);
                } else {
                    b.line_height = b.size * 1.2;
                }
                if (b.line_height <= 0) b.line_height = b.size * 1.2;
            }
            return blocks;
        }

        public static Gee.ArrayList<TextBlock> blocks(Document doc, int page) {
            var it = new Interpreter(doc);
            it.run_page(page);
            return blocks_from(it, page);
        }

        private static Op neutral_op(Op original, Item item) {
            double total = 0;
            foreach (var g in item.glyphs) total += g.advance;
            double tfs = item.font_size != 0 ? item.font_size : 1;
            double th = item.h_scale != 0 ? item.h_scale : 1;
            var arr = Obj.array();
            if (original.name == "TJ" && original.args.size > 0 && original.args[0].is_array()) {
                double shift = 0;
                foreach (var el in original.args[0].items) if (el.is_number()) shift += el.as_number();
                total -= shift / 1000 * tfs * th;
            }
            arr.add(Obj.number(Math.round(-total * 1000 / (tfs * th) * 1000) / 1000));
            return new Op.with("TJ", { arr });
        }

        private static void neutralize(Gee.ArrayList<Op> ops, Item item, Gee.ArrayList<Op> prefix) {
            var op = ops[item.op_index];
            var replacement = neutral_op(op, item);
            if (op.name == "'") {
                prefix.add(new Op("T*"));
            } else if (op.name == "\"") {
                prefix.add(new Op.with("Tw", { op.args[0] }));
                prefix.add(new Op.with("Tc", { op.args[1] }));
                prefix.add(new Op("T*"));
            }
            ops[item.op_index] = replacement;
        }

        public static void remove_items(Interpreter it, Gee.List<Item> items) {
            var inserts = new Gee.HashMap<Op, Gee.ArrayList<Op>>();
            foreach (var item in items) {
                var ops = it.ops_for(item);
                var prefix = new Gee.ArrayList<Op>();
                neutralize(ops, item, prefix);
                if (prefix.size > 0) inserts[ops[item.op_index]] = prefix;
                if (item.form != null) item.form.modified = true;
            }
            if (inserts.size == 0) return;
            for (int i = it.ops.size - 1; i >= 0; i--) {
                if (inserts.has_key(it.ops[i])) {
                    var pre = inserts[it.ops[i]];
                    for (int k = pre.size - 1; k >= 0; k--) it.ops.insert(i, pre[k]);
                }
            }
            foreach (var form in it.forms.values) {
                for (int i = form.ops.size - 1; i >= 0; i--) {
                    if (inserts.has_key(form.ops[i])) {
                        var pre = inserts[form.ops[i]];
                        for (int k = pre.size - 1; k >= 0; k--) form.ops.insert(i, pre[k]);
                    }
                }
            }
        }

        public static void commit(Document doc, Interpreter it) {
            doc.set_page_content(it.page_index, Content.serialize(it.ops));
            it.commit_forms();
        }

        private static string f(double v) {
            return Obj.format_number(Math.round(v * 1000) / 1000);
        }

        public static string unique_resource(Obj dict, string prefix) {
            int n = 1;
            while (dict.has("%s%d".printf(prefix, n))) n++;
            return "%s%d".printf(prefix, n);
        }

        private static string font_resource(Document doc, int page, Obj font_ref) {
            var res = doc.page_resources(page);
            var fonts = doc.sub_dict(res, "Font");
            foreach (var k in fonts.dict.keys) {
                var v = fonts.get(k);
                if (v.is_ref() && font_ref.is_ref() && v.num == font_ref.num) return k;
            }
            string name = unique_resource(fonts, "SF");
            fonts.set(name, font_ref);
            return name;
        }

        public static EditResult replace_block(Document doc, int page, TextBlock block, string new_text, string? family = null, double size_override = 0) {
            var result = new EditResult();
            var it = new Interpreter(doc);
            it.run_page(page);
            var fresh = blocks_from(it, page);
            TextBlock? match = null;
            foreach (var b in fresh) {
                if ((b.box.x1 - block.box.x1).abs() < 1 && (b.box.y2 - block.box.y2).abs() < 1) {
                    match = b;
                    break;
                }
            }
            if (match == null) {
                result.message = "block not found";
                return result;
            }
            var first = match.lines[0].items[0];
            var first_glyph = first.glyphs[0];
            double size = size_override > 0 ? size_override : match.size;
            double x0 = match.box.x1;
            double base0 = first_glyph.origin_y;
            double width = double.max(match.box.width(), 20);
            if (match.lines.size == 1 && !new_text.contains("\n")) {
                var media = doc.page_box(page);
                width = double.max(width, media[2] - x0 - 36);
            }
            remove_items(it, match.items());
            commit(doc, it);
            var ops = new StringBuilder();
            string font_name = "";
            FontInfo? original = first.font;
            bool use_original = family == null && original != null && original.dict != null && first.form == null;
            if (use_original) {
                bool complete;
                original.encode(new_text.replace("\n", " "), out complete);
                if (!complete) use_original = false;
            }
            EmbeddedFont? embedded = null;
            if (!use_original) {
                string pattern = "sans-serif";
                if (family != null) pattern = family;
                else if (original != null) pattern = original.family_hint();
                embedded = EmbeddedFont.for_pattern(doc, pattern);
                if (embedded == null) embedded = EmbeddedFont.for_pattern(doc, "sans-serif");
                if (embedded == null) {
                    result.message = "no font available";
                    return result;
                }
                if (!embedded.covers(new_text)) {
                    var fallback = EmbeddedFont.for_pattern(doc, "sans-serif");
                    if (fallback != null && fallback.covers(new_text)) embedded = fallback;
                }
                result.substituted = true;
                result.font_family = Native.font_family(embedded.path) ?? embedded.postscript_name;
                font_name = font_resource(doc, page, embedded.font_ref);
            } else {
                var fonts = doc.lookup(it.resources, "Font");
                font_name = first.font.resource_name;
                if (!fonts.is_dict() || !fonts.has(font_name)) font_name = font_resource(doc, page, first.font.dict.is_none() ? Obj.none() : doc.add_ref(first.font.dict));
                result.font_family = original.family_hint();
            }
            var m = first.text_matrix.multiply(first.ctm);
            double sx = m.scale_x(), sy = m.scale_y();
            double ux = sx > 0 ? m.a / sx : 1, uy = sx > 0 ? m.b / sx : 0;
            double vx = sy > 0 ? m.c / sy : 0, vy = sy > 0 ? m.d / sy : 1;
            bool rotated = (uy).abs() > 0.01 || (vx).abs() > 0.01;
            double c = match.color[0], g = match.color[1], b = match.color[2];
            ops.append_printf("q\nBT\n%s %s %s rg\n/%s %s Tf\n", f(c), f(g), f(b), font_name, f(size));
            var lines = new Gee.ArrayList<string>();
            if (use_original) {
                foreach (var l in wrap_original(new_text, original, size, width)) lines.add(l);
            } else {
                lines.add_all(Annotations.wrap_lines(new_text, embedded, size, width));
            }
            double lh = match.line_height > 0 ? match.line_height : size * 1.2;
            double ox = first_glyph.origin_x, oy = base0;
            for (int i = 0; i < lines.size; i++) {
                double px = rotated ? ox - vx * lh * i : x0;
                double py = rotated ? oy - vy * lh * i : oy - lh * i;
                if (rotated) ops.append_printf("%s %s %s %s %s %s Tm\n", f(ux), f(uy), f(vx), f(vy), f(px), f(py));
                else ops.append_printf("1 0 0 1 %s %s Tm\n", f(px), f(py));
                if (use_original) {
                    bool complete;
                    var bytes = original.encode(lines[i], out complete);
                    var tmp = new ByteArray();
                    Obj.write_string(tmp, bytes, original.is_cid);
                    tmp.append({ 0 });
                    ops.append((string) tmp.data);
                } else {
                    ops.append(embedded.hex(lines[i]));
                }
                ops.append(" Tj\n");
            }
            ops.append("ET\nQ\n");
            doc.append_page_content(page, ops.str.data);
            return result;
        }

        private static Gee.ArrayList<string> wrap_original(string text, FontInfo font, double size, double width) {
            var lines = new Gee.ArrayList<string>();
            foreach (var para in text.split("\n")) {
                var cur = new StringBuilder();
                foreach (var word in para.split(" ")) {
                    string trial = cur.len == 0 ? word : cur.str + " " + word;
                    if (cur.len > 0 && measure_original(font, trial, size) > width) {
                        lines.add(cur.str);
                        cur.assign(word);
                    } else {
                        cur.assign(trial);
                    }
                }
                lines.add(cur.str);
            }
            return lines;
        }

        public static double measure_original(FontInfo font, string text, double size) {
            bool complete;
            var bytes = font.encode(text, out complete);
            double w = 0;
            foreach (var code in font.decode(bytes)) w += font.width(code.code);
            return w * size / 1000;
        }

        public static void delete_block(Document doc, int page, TextBlock block) {
            var it = new Interpreter(doc);
            it.run_page(page);
            foreach (var b in blocks_from(it, page)) {
                if ((b.box.x1 - block.box.x1).abs() < 1 && (b.box.y2 - block.box.y2).abs() < 1) {
                    remove_items(it, b.items());
                    commit(doc, it);
                    return;
                }
            }
        }

        public static EditResult add_text(Document doc, int page, double x, double y, string text, string family, double size, double[] color, double width = 0) {
            var result = new EditResult();
            var font = EmbeddedFont.for_pattern(doc, family);
            if (font == null) {
                result.message = "no font available";
                return result;
            }
            result.font_family = Native.font_family(font.path) ?? font.postscript_name;
            string name = font_resource(doc, page, font.font_ref);
            var ops = new StringBuilder();
            ops.append_printf("q\nBT\n%s %s %s rg\n/%s %s Tf\n", f(color[0]), f(color[1]), f(color[2]), name, f(size));
            var lines = width > 0 ? Annotations.wrap_lines(text, font, size, width) : new Gee.ArrayList<string>.wrap(text.split("\n"));
            double ly = y;
            foreach (var l in lines) {
                ops.append_printf("1 0 0 1 %s %s Tm %s Tj\n", f(x), f(ly), font.hex(l));
                ly -= size * 1.2;
            }
            ops.append("ET\nQ\n");
            doc.append_page_content(page, ops.str.data);
            return result;
        }

        public static string add_image(Document doc, int page, Obj image_ref, Rect box) {
            var res = doc.page_resources(page);
            var xo = doc.sub_dict(res, "XObject");
            string name = unique_resource(xo, "Im");
            xo.set(name, image_ref);
            doc.append_page_content(page, "q %s 0 0 %s %s %s cm /%s Do Q\n".printf(f(box.width()), f(box.height()), f(box.x1), f(box.y1), name).data);
            return name;
        }

        private static Item? find_image(Interpreter it, ImageInfo info) {
            foreach (var item in it.items) {
                if (item.kind == ItemKind.IMAGE && item.op_index == info.item.op_index && (item.form == null) == (info.item.form == null)
                        && (item.box.x1 - info.item.box.x1).abs() < 0.5 && (item.box.y1 - info.item.box.y1).abs() < 0.5) return item;
            }
            return null;
        }

        public static bool move_image(Document doc, int page, ImageInfo info, Rect target) {
            var it = new Interpreter(doc);
            it.run_page(page);
            var item = find_image(it, info);
            if (item == null) return false;
            var old = item.box;
            if (old.width() <= 0 || old.height() <= 0) return false;
            var t = Matrix.of(target.width() / old.width(), 0, 0, target.height() / old.height(),
                target.x1 - old.x1 * target.width() / old.width(), target.y1 - old.y1 * target.height() / old.height());
            var c = item.ctm;
            var mm = c.multiply(t).multiply(c.inverse());
            var ops = it.ops_for(item);
            int idx = item.op_index;
            ops.insert(idx + 1, new Op("Q"));
            ops.insert(idx, new Op.with("cm", { Obj.number(mm.a), Obj.number(mm.b), Obj.number(mm.c), Obj.number(mm.d), Obj.number(mm.e), Obj.number(mm.f) }));
            ops.insert(idx, new Op("q"));
            if (item.form != null) item.form.modified = true;
            commit(doc, it);
            return true;
        }

        public static bool delete_image(Document doc, int page, ImageInfo info) {
            var it = new Interpreter(doc);
            it.run_page(page);
            var item = find_image(it, info);
            if (item == null) return false;
            var ops = it.ops_for(item);
            ops.remove_at(item.op_index);
            if (item.form != null) item.form.modified = true;
            commit(doc, it);
            return true;
        }

        public static bool replace_image(Document doc, int page, ImageInfo info, Obj image_ref) {
            var it = new Interpreter(doc);
            it.run_page(page);
            var item = find_image(it, info);
            if (item == null || item.xobject == "") return false;
            var res = item.form != null ? item.form.resources : doc.page_resources(page);
            var xo = doc.sub_dict(res, "XObject");
            string name = unique_resource(xo, "Im");
            xo.set(name, image_ref);
            var ops = it.ops_for(item);
            ops[item.op_index] = new Op.with("Do", { Obj.name_obj(name) });
            if (item.form != null) item.form.modified = true;
            commit(doc, it);
            return true;
        }
    }
}
