namespace Singularity.Pdf {

    public struct Matrix {
        public double a;
        public double b;
        public double c;
        public double d;
        public double e;
        public double f;

        public static Matrix identity() {
            return { 1, 0, 0, 1, 0, 0 };
        }

        public static Matrix of(double a, double b, double c, double d, double e, double f) {
            return { a, b, c, d, e, f };
        }

        public Matrix multiply(Matrix m) {
            return {
                a * m.a + b * m.c,
                a * m.b + b * m.d,
                c * m.a + d * m.c,
                c * m.b + d * m.d,
                e * m.a + f * m.c + m.e,
                e * m.b + f * m.d + m.f
            };
        }

        public void apply(double x, double y, out double ox, out double oy) {
            ox = a * x + c * y + e;
            oy = b * x + d * y + f;
        }

        public Rect apply_rect(double x1, double y1, double x2, double y2) {
            double px, py;
            var r = Rect.empty();
            apply(x1, y1, out px, out py);
            r.add(px, py);
            apply(x2, y1, out px, out py);
            r.add(px, py);
            apply(x1, y2, out px, out py);
            r.add(px, py);
            apply(x2, y2, out px, out py);
            r.add(px, py);
            return r;
        }

        public Matrix inverse() {
            double det = a * d - b * c;
            if (det.abs() < 1e-12) return identity();
            return {
                d / det, -b / det, -c / det, a / det,
                (c * f - d * e) / det, (b * e - a * f) / det
            };
        }

        public double scale_x() {
            return Math.sqrt(a * a + b * b);
        }

        public double scale_y() {
            return Math.sqrt(c * c + d * d);
        }
    }

    public struct Rect {
        public double x1;
        public double y1;
        public double x2;
        public double y2;

        public static Rect empty() {
            return { double.MAX, double.MAX, -double.MAX, -double.MAX };
        }

        public static Rect of(double x1, double y1, double x2, double y2) {
            return { double.min(x1, x2), double.min(y1, y2), double.max(x1, x2), double.max(y1, y2) };
        }

        public bool is_empty() {
            return x2 < x1 || y2 < y1;
        }

        public void add(double x, double y) {
            x1 = double.min(x1, x);
            y1 = double.min(y1, y);
            x2 = double.max(x2, x);
            y2 = double.max(y2, y);
        }

        public void union(Rect r) {
            if (r.is_empty()) return;
            add(r.x1, r.y1);
            add(r.x2, r.y2);
        }

        public bool intersects(Rect r) {
            return !is_empty() && !r.is_empty() && x1 < r.x2 && r.x1 < x2 && y1 < r.y2 && r.y1 < y2;
        }

        public bool contains_point(double x, double y) {
            return x >= x1 && x <= x2 && y >= y1 && y <= y2;
        }

        public bool center_inside(Rect r) {
            return r.contains_point((x1 + x2) / 2, (y1 + y2) / 2);
        }

        public double overlap_ratio(Rect r) {
            double w = double.min(x2, r.x2) - double.max(x1, r.x1);
            double h = double.min(y2, r.y2) - double.max(y1, r.y1);
            if (w <= 0 || h <= 0) return 0;
            double area = (x2 - x1) * (y2 - y1);
            return area <= 0 ? 0 : (w * h) / area;
        }

        public double width() { return x2 - x1; }
        public double height() { return y2 - y1; }
    }

    public class Op {
        public string name;
        public Gee.ArrayList<Obj> args = new Gee.ArrayList<Obj>();
        public uint8[]? inline_data = null;

        public Op(string name) {
            this.name = name;
        }

        public Op.with(string name, Obj[] operands) {
            this.name = name;
            foreach (var o in operands) args.add(o);
        }

        public double num(int i) {
            return i < args.size ? args[i].as_number() : 0;
        }
    }

    namespace Content {
        public Gee.ArrayList<Op> parse(uint8[] data) {
            var ops = new Gee.ArrayList<Op>();
            var lx = new Lexer(data);
            var operands = new Gee.ArrayList<Obj>();
            while (true) {
                lx.skip_space();
                if (lx.at_end()) break;
                int before = lx.pos;
                Obj o;
                try {
                    o = lx.parse();
                } catch (Error e) {
                    break;
                }
                if (lx.pos == before) {
                    lx.pos++;
                    continue;
                }
                if (o.kind != ObjKind.KEYWORD) {
                    operands.add(o);
                    continue;
                }
                if (o.name == "BI") {
                    var op = new Op("BI");
                    var dict = Obj.dictionary();
                    while (!lx.at_end()) {
                        lx.skip_space();
                        int save = lx.pos;
                        string w = lx.word();
                        if (w == "ID") break;
                        lx.pos = save;
                        Obj key;
                        try {
                            key = lx.parse();
                        } catch (Error e) {
                            break;
                        }
                        if (key.kind == ObjKind.KEYWORD && key.name == "ID") break;
                        if (!key.is_name()) continue;
                        Obj val;
                        try {
                            val = lx.parse();
                        } catch (Error e) {
                            break;
                        }
                        dict.set(key.name, val);
                    }
                    if (lx.pos < data.length && Lexer.is_space(data[lx.pos])) lx.pos++;
                    int start = lx.pos;
                    int end_pos = find_inline_end(data, start);
                    op.args.add(dict);
                    op.inline_data = data[start : end_pos];
                    int after = end_pos;
                    while (after < data.length && Lexer.is_space(data[after])) after++;
                    lx.pos = int.min(data.length, after + 2);
                    ops.add(op);
                    operands.clear();
                    continue;
                }
                var op = new Op(o.name);
                op.args.add_all(operands);
                operands.clear();
                ops.add(op);
            }
            return ops;
        }

        private int find_inline_end(uint8[] d, int start) {
            int i = start;
            while (i + 2 < d.length) {
                if (d[i] == 'E' && d[i + 1] == 'I' && Lexer.is_space(d[i - 1]) && (i + 2 >= d.length || Lexer.is_space(d[i + 2]) || Lexer.is_delimiter(d[i + 2]))) {
                    int e = i - 1;
                    return e;
                }
                i++;
            }
            return d.length;
        }

        public uint8[] serialize(Gee.List<Op> ops) {
            var b = new ByteArray();
            foreach (var op in ops) write_op(b, op);
            return b.steal();
        }

        public void write_op(ByteArray b, Op op) {
            if (op.name == "BI") {
                Obj.append(b, "BI");
                var d = op.args.size > 0 ? op.args[0] : Obj.dictionary();
                foreach (var k in d.dict.keys) {
                    Obj.append(b, " ");
                    Obj.append(b, Obj.encode_name(k));
                    Obj.append(b, " ");
                    d.dict.get(k).write(b);
                }
                Obj.append(b, " ID ");
                if (op.inline_data != null) b.append(op.inline_data);
                Obj.append(b, "\nEI\n");
                return;
            }
            foreach (var a in op.args) {
                a.write(b);
                Obj.append(b, " ");
            }
            Obj.append(b, op.name);
            Obj.append(b, "\n");
        }
    }

    public enum ItemKind {
        TEXT,
        IMAGE,
        PATH,
        SHADING
    }

    public class Glyph {
        public int element;
        public int offset;
        public int length;
        public int code;
        public string text;
        public Rect box;
        public double width;
        public double advance;
        public bool space;
        public double origin_x;
        public double origin_y;
    }

    public class FormContext {
        public int num;
        public Obj stream;
        public Gee.ArrayList<Op> ops;
        public Obj resources;
        public bool modified = false;
    }

    public class Item {
        public ItemKind kind;
        public int op_index;
        public int op_start;
        public FormContext? form;
        public Rect box = Rect.empty();
        public string xobject = "";
        public FontInfo? font;
        public double font_size;
        public int render_mode;
        public Gee.ArrayList<Glyph> glyphs = new Gee.ArrayList<Glyph>();
        public Matrix ctm;
        public Matrix text_matrix;
        public double char_spacing;
        public double word_spacing;
        public double h_scale;
        public double rise;
        public double[] fill_rgb = { 0, 0, 0 };
        public int block = -1;
        public int top_op = -1;
        public int mcid = -1;
        public bool artifact = false;

        public string text() {
            var s = new StringBuilder();
            foreach (var g in glyphs) s.append(g.text);
            return s.str;
        }
    }

    private class GState {
        public Matrix ctm = Matrix.identity();
        public double char_spacing = 0;
        public double word_spacing = 0;
        public double h_scale = 1;
        public double leading = 0;
        public FontInfo? font = null;
        public double font_size = 0;
        public int render_mode = 0;
        public double rise = 0;
        public double[] fill = { 0, 0, 0 };

        public GState copy() {
            var g = new GState();
            g.ctm = ctm;
            g.char_spacing = char_spacing;
            g.word_spacing = word_spacing;
            g.h_scale = h_scale;
            g.leading = leading;
            g.font = font;
            g.font_size = font_size;
            g.render_mode = render_mode;
            g.rise = rise;
            g.fill = fill;
            return g;
        }
    }

    public class Interpreter {
        public Document doc;
        public int page_index;
        public Gee.ArrayList<Op> ops;
        public Obj resources;
        public Gee.ArrayList<Item> items = new Gee.ArrayList<Item>();
        public Gee.HashMap<int, FormContext> forms = new Gee.HashMap<int, FormContext>();
        private Gee.HashMap<string, FontInfo> font_cache = new Gee.HashMap<string, FontInfo>();

        public Interpreter(Document doc) {
            this.doc = doc;
        }

        public void run_page(int index) {
            page_index = index;
            resources = doc.page_resources(index, false);
            ops = Content.parse(doc.page_content(index));
            items.clear();
            forms.clear();
            process(ops, resources, Matrix.identity(), null, 0, -1);
        }

        public void run_ops(Gee.ArrayList<Op> list, Obj res) {
            ops = list;
            resources = res;
            items.clear();
            process(ops, resources, Matrix.identity(), null, 0, -1);
        }

        private FontInfo? font_for(Obj res, string name, FormContext? form) {
            var fonts = doc.lookup(res, "Font");
            var fref = fonts.is_dict() ? fonts.get(name) : null;
            if (fref == null) return null;
            string key = fref.is_ref() ? "r%d".printf(fref.num) : "%s:%d".printf(name, form != null ? form.num : -1);
            if (font_cache.has_key(key)) return font_cache[key];
            var info = FontInfo.load(doc, fref, name);
            font_cache[key] = info;
            return info;
        }

        public FontInfo? font_named(string name) {
            return font_for(resources, name, null);
        }

        private Gee.ArrayList<int> mc_stack = new Gee.ArrayList<int>();

        private void add_item(Item item, int top) {
            item.top_op = top >= 0 ? top : item.op_index;
            for (int k = mc_stack.size - 1; k >= 0; k--) {
                int v = mc_stack[k];
                if (v == -2) {
                    item.artifact = true;
                    break;
                }
                if (v >= 0) {
                    item.mcid = v;
                    break;
                }
            }
            items.add(item);
        }

        private void process(Gee.ArrayList<Op> list, Obj res, Matrix base_ctm, FormContext? form, int depth, int top) {
            if (depth == 0) mc_stack.clear();
            var gs = new GState();
            gs.ctm = base_ctm;
            var stack = new Gee.ArrayList<GState>();
            Matrix tm = Matrix.identity(), tlm = Matrix.identity();
            Rect path_box = Rect.empty();
            int path_start = -1;
            for (int i = 0; i < list.size; i++) {
                var op = list[i];
                switch (op.name) {
                    case "q":
                        stack.add(gs.copy());
                        break;
                    case "Q":
                        if (stack.size > 0) gs = stack.remove_at(stack.size - 1);
                        break;
                    case "cm":
                        if (op.args.size >= 6) gs.ctm = Matrix.of(op.num(0), op.num(1), op.num(2), op.num(3), op.num(4), op.num(5)).multiply(gs.ctm);
                        break;
                    case "BT":
                        tm = Matrix.identity();
                        tlm = Matrix.identity();
                        break;
                    case "Tf":
                        if (op.args.size >= 2 && op.args[0].is_name()) {
                            gs.font = font_for(res, op.args[0].name, form);
                            gs.font_size = op.num(1);
                        }
                        break;
                    case "Tc": gs.char_spacing = op.num(0); break;
                    case "Tw": gs.word_spacing = op.num(0); break;
                    case "Tz": gs.h_scale = op.num(0) / 100; break;
                    case "TL": gs.leading = op.num(0); break;
                    case "Ts": gs.rise = op.num(0); break;
                    case "Tr": gs.render_mode = (int) op.num(0); break;
                    case "Td":
                        tlm = Matrix.of(1, 0, 0, 1, op.num(0), op.num(1)).multiply(tlm);
                        tm = tlm;
                        break;
                    case "TD":
                        gs.leading = -op.num(1);
                        tlm = Matrix.of(1, 0, 0, 1, op.num(0), op.num(1)).multiply(tlm);
                        tm = tlm;
                        break;
                    case "Tm":
                        if (op.args.size >= 6) tlm = Matrix.of(op.num(0), op.num(1), op.num(2), op.num(3), op.num(4), op.num(5));
                        tm = tlm;
                        break;
                    case "T*":
                        tlm = Matrix.of(1, 0, 0, 1, 0, -gs.leading).multiply(tlm);
                        tm = tlm;
                        break;
                    case "'":
                    case "\"":
                    case "Tj":
                    case "TJ":
                        if (op.name == "\"" && op.args.size >= 3) {
                            gs.word_spacing = op.num(0);
                            gs.char_spacing = op.num(1);
                        }
                        if (op.name == "'" || op.name == "\"") {
                            tlm = Matrix.of(1, 0, 0, 1, 0, -gs.leading).multiply(tlm);
                            tm = tlm;
                        }
                        show_text(op, i, gs, ref tm, form, top);
                        break;
                    case "rg":
                        gs.fill = { op.num(0), op.num(1), op.num(2) };
                        break;
                    case "g":
                        gs.fill = { op.num(0), op.num(0), op.num(0) };
                        break;
                    case "k":
                        gs.fill = { (1 - op.num(0)) * (1 - op.num(3)), (1 - op.num(1)) * (1 - op.num(3)), (1 - op.num(2)) * (1 - op.num(3)) };
                        break;
                    case "m":
                    case "l":
                    case "c":
                    case "v":
                    case "y":
                    case "re":
                        if (path_start < 0) {
                            path_start = i;
                            path_box = Rect.empty();
                        }
                        if (op.name == "re" && op.args.size >= 4) {
                            path_box.union(gs.ctm.apply_rect(op.num(0), op.num(1), op.num(0) + op.num(2), op.num(1) + op.num(3)));
                        } else {
                            for (int k = 0; k + 1 < op.args.size; k += 2) {
                                double px, py;
                                gs.ctm.apply(op.num(k), op.num(k + 1), out px, out py);
                                path_box.add(px, py);
                            }
                        }
                        break;
                    case "h":
                    case "W":
                    case "W*":
                        break;
                    case "S":
                    case "s":
                    case "f":
                    case "F":
                    case "f*":
                    case "B":
                    case "B*":
                    case "b":
                    case "b*":
                    case "n":
                        if (path_start >= 0) {
                            if (op.name != "n") {
                                var item = new Item();
                                item.kind = ItemKind.PATH;
                                item.op_start = path_start;
                                item.op_index = i;
                                item.form = form;
                                item.box = path_box;
                                item.ctm = gs.ctm;
                                item.fill_rgb = gs.fill;
                                add_item(item, top);
                            }
                        }
                        path_start = -1;
                        break;
                    case "Do":
                        if (op.args.size > 0 && op.args[0].is_name()) do_xobject(op.args[0].name, i, res, gs, form, depth, top >= 0 ? top : i);
                        break;
                    case "BMC":
                        mc_stack.add(op.args.size > 0 && op.args[0].is_name("Artifact") ? -2 : -1);
                        break;
                    case "BDC":
                        int mark = -1;
                        if (op.args.size > 0 && op.args[0].is_name("Artifact")) {
                            mark = -2;
                        } else if (op.args.size > 1 && op.args[1].is_dict()) {
                            var mcid = op.args[1].get("MCID");
                            if (mcid != null && mcid.is_number()) mark = mcid.as_int();
                        }
                        mc_stack.add(mark);
                        break;
                    case "EMC":
                        if (mc_stack.size > 0) mc_stack.remove_at(mc_stack.size - 1);
                        break;
                    case "BI":
                        var img = new Item();
                        img.kind = ItemKind.IMAGE;
                        img.op_index = i;
                        img.op_start = i;
                        img.form = form;
                        img.ctm = gs.ctm;
                        img.box = gs.ctm.apply_rect(0, 0, 1, 1);
                        add_item(img, top);
                        break;
                    case "sh":
                        var sh = new Item();
                        sh.kind = ItemKind.SHADING;
                        sh.op_index = i;
                        sh.op_start = i;
                        sh.form = form;
                        sh.ctm = gs.ctm;
                        sh.box = Rect.of(-1e6, -1e6, 1e6, 1e6);
                        add_item(sh, top);
                        break;
                    default:
                        break;
                }
            }
        }

        private void do_xobject(string name, int op_index, Obj res, GState gs, FormContext? form, int depth, int top) {
            var xobjects = doc.lookup(res, "XObject");
            var xref = xobjects.is_dict() ? xobjects.get(name) : null;
            if (xref == null) return;
            var x = doc.resolve(xref);
            if (!x.is_stream()) return;
            var subtype = doc.lookup(x, "Subtype");
            if (subtype.is_name("Image")) {
                var item = new Item();
                item.kind = ItemKind.IMAGE;
                item.op_index = op_index;
                item.op_start = op_index;
                item.form = form;
                item.xobject = name;
                item.ctm = gs.ctm;
                item.box = gs.ctm.apply_rect(0, 0, 1, 1);
                add_item(item, top);
            } else if (subtype.is_name("Form") && depth < 12 && xref.is_ref()) {
                var fm = doc.lookup(x, "Matrix");
                var m = Matrix.identity();
                if (fm.is_array() && fm.length >= 6) m = Matrix.of(fm.at(0).as_number(), fm.at(1).as_number(), fm.at(2).as_number(), fm.at(3).as_number(), fm.at(4).as_number(), fm.at(5).as_number());
                FormContext ctx;
                if (forms.has_key(xref.num)) {
                    ctx = forms[xref.num];
                } else {
                    ctx = new FormContext();
                    ctx.num = xref.num;
                    ctx.stream = x;
                    ctx.ops = Content.parse(doc.stream_data(x));
                    var fres = doc.lookup(x, "Resources");
                    ctx.resources = fres.is_dict() ? fres : res;
                    forms[xref.num] = ctx;
                }
                process(ctx.ops, ctx.resources, m.multiply(gs.ctm), ctx, depth + 1, top);
            }
        }

        private void show_text(Op op, int index, GState gs, ref Matrix tm, FormContext? form, int top) {
            var font = gs.font;
            var item = new Item();
            item.kind = ItemKind.TEXT;
            item.op_index = index;
            item.op_start = index;
            item.form = form;
            item.font = font;
            item.font_size = gs.font_size;
            item.render_mode = gs.render_mode;
            item.ctm = gs.ctm;
            item.text_matrix = tm;
            item.char_spacing = gs.char_spacing;
            item.word_spacing = gs.word_spacing;
            item.h_scale = gs.h_scale;
            item.rise = gs.rise;
            item.fill_rgb = gs.fill;
            var elements = new Gee.ArrayList<Obj>();
            if (op.name == "TJ") {
                if (op.args.size > 0 && op.args[0].is_array()) elements.add_all(op.args[0].items);
            } else if (op.args.size > 0) {
                elements.add(op.args[op.args.size - 1]);
            }
            double tfs = gs.font_size;
            double th = gs.h_scale;
            double asc = font != null ? font.ascent : 0.8;
            double desc = font != null ? font.descent : -0.2;
            for (int e = 0; e < elements.size; e++) {
                var el = elements[e];
                if (el.is_number()) {
                    double tx = -el.as_number() / 1000 * tfs * th;
                    tm = Matrix.of(1, 0, 0, 1, tx, 0).multiply(tm);
                    continue;
                }
                if (!el.is_string()) continue;
                if (font == null) continue;
                int offset = 0;
                foreach (var code in font.decode(el.bytes)) {
                    double w0 = font.width(code.code) / 1000;
                    bool is_space = code.length == 1 && code.code == 32;
                    double adv = (w0 * tfs + gs.char_spacing + (is_space ? gs.word_spacing : 0)) * th;
                    var trm = Matrix.of(tfs * th, 0, 0, tfs, 0, gs.rise).multiply(tm).multiply(gs.ctm);
                    var g = new Glyph();
                    g.element = e;
                    g.offset = offset;
                    g.length = code.length;
                    g.code = code.code;
                    g.text = font.unicode(code.code);
                    g.box = trm.apply_rect(0, desc, double.max(w0, 0.001), asc);
                    g.width = w0;
                    g.advance = adv;
                    g.space = is_space || g.text == " ";
                    trm.apply(0, 0, out g.origin_x, out g.origin_y);
                    item.glyphs.add(g);
                    item.box.union(g.box);
                    offset += code.length;
                    tm = Matrix.of(1, 0, 0, 1, adv, 0).multiply(tm);
                }
            }
            add_item(item, top);
        }

        public Gee.ArrayList<Op> ops_for(Item item) {
            return item.form != null ? item.form.ops : ops;
        }

        public string page_text() {
            var s = new StringBuilder();
            double last_y = double.MAX;
            double last_x = -double.MAX;
            foreach (var it in items) {
                if (it.kind != ItemKind.TEXT) continue;
                foreach (var g in it.glyphs) {
                    double y = (g.box.y1 + g.box.y2) / 2;
                    if (last_y != double.MAX && (y - last_y).abs() > (g.box.y2 - g.box.y1) * 0.6) s.append_c('\n');
                    else if (last_x > -double.MAX && g.box.x1 - last_x > (g.box.y2 - g.box.y1) * 0.25 && !g.space) s.append_c(' ');
                    s.append(g.text);
                    last_y = y;
                    last_x = g.box.x2;
                }
            }
            return s.str;
        }

        public void commit_forms() {
            foreach (var f in forms.values) {
                if (!f.modified) continue;
                doc.set_stream_data(f.stream, Content.serialize(f.ops));
            }
        }
    }
}
