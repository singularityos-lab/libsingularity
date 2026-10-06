namespace Singularity.Pdf {

    public enum FieldType {
        TEXT,
        CHECKBOX,
        RADIO,
        PUSHBUTTON,
        COMBO,
        LIST,
        SIGNATURE,
        UNKNOWN
    }

    public class FieldWidget {
        public int page = -1;
        public Rect rect;
        public Obj reference;
        public Obj dict;
        public string on_state = "";
    }

    public class FieldInfo {
        public string name = "";
        public string partial = "";
        public FieldType type = FieldType.UNKNOWN;
        public string value = "";
        public string default_value = "";
        public string[] options = {};
        public string[] option_labels = {};
        public Obj reference;
        public Obj dict;
        public Gee.ArrayList<FieldWidget> widgets = new Gee.ArrayList<FieldWidget>();
        public int flags = 0;
        public int max_len = 0;
        public int quadding = 0;
        public string da = "";
        public string tooltip = "";
        public string format_js = "";
        public string calculate_js = "";
        public string validate_js = "";
        public string keystroke_js = "";

        public bool read_only { get { return (flags & 1) != 0; } }
        public bool required { get { return (flags & 2) != 0; } }
        public bool multiline { get { return type == FieldType.TEXT && (flags & (1 << 12)) != 0; } }
        public bool password { get { return type == FieldType.TEXT && (flags & (1 << 13)) != 0; } }
        public bool comb { get { return type == FieldType.TEXT && (flags & (1 << 24)) != 0; } }
        public bool editable_combo { get { return type == FieldType.COMBO && (flags & (1 << 18)) != 0; } }
        public bool multi_select { get { return type == FieldType.LIST && (flags & (1 << 21)) != 0; } }
    }

    public class DetectedField {
        public FieldType type;
        public int page;
        public Rect rect;
        public string name;
    }

    public class Forms {
        public static Obj? acroform(Document doc) {
            var af = doc.lookup(doc.catalog(), "AcroForm");
            return af.is_dict() ? af : null;
        }

        public static bool has_xfa(Document doc) {
            var af = acroform(doc);
            return af != null && !doc.lookup(af, "XFA").is_none();
        }

        private static Obj inherited(Document doc, Obj field, string key) {
            var cur = field;
            for (int d = 0; d < 32 && cur.is_dict(); d++) {
                var v = cur.get(key);
                if (v != null) return doc.resolve(v);
                cur = doc.resolve(cur.get("Parent"));
            }
            if (key == "DA") {
                var af = acroform(doc);
                if (af != null) return doc.lookup(af, "DA");
            }
            return Obj.none();
        }

        private static string js_of(Document doc, Obj field, string trigger) {
            var aa = inherited(doc, field, "AA");
            if (!aa.is_dict()) return "";
            var action = doc.lookup(aa, trigger);
            if (!action.is_dict()) return "";
            var js = doc.lookup(action, "JS");
            if (js.is_stream()) return Obj.decode_text(doc.stream_data(js));
            return js.text_value();
        }

        public static Gee.ArrayList<FieldInfo> list(Document doc) {
            var result = new Gee.ArrayList<FieldInfo>();
            var af = acroform(doc);
            if (af == null) return result;
            var fields = doc.lookup(af, "Fields");
            if (!fields.is_array()) return result;
            var page_of = new Gee.HashMap<int, int>();
            for (int p = 0; p < doc.page_count(); p++) {
                var annots = doc.lookup(doc.page(p), "Annots");
                if (!annots.is_array()) continue;
                for (int i = 0; i < annots.length; i++) if (annots.at(i).is_ref()) page_of[annots.at(i).num] = p;
            }
            var seen = new Gee.HashSet<int>();
            for (int i = 0; i < fields.length; i++) walk(doc, fields.at(i), "", result, page_of, seen, 0);
            return result;
        }

        private static void walk(Document doc, Obj r, string prefix, Gee.ArrayList<FieldInfo> result, Gee.HashMap<int, int> page_of,
                                 Gee.HashSet<int> seen, int depth) {
            if (depth > 32) return;
            if (r.is_ref()) {
                if (seen.contains(r.num)) return;
                seen.add(r.num);
            }
            var f = doc.resolve(r);
            if (!f.is_dict()) return;
            string partial = doc.lookup(f, "T").text_value();
            string name = prefix == "" ? partial : (partial == "" ? prefix : prefix + "." + partial);
            var kids = doc.lookup(f, "Kids");
            bool has_field_kids = false;
            if (kids.is_array()) {
                for (int i = 0; i < kids.length; i++) {
                    var k = doc.resolve(kids.at(i));
                    if (k.is_dict() && k.has("T")) has_field_kids = true;
                }
            }
            if (has_field_kids) {
                for (int i = 0; i < kids.length; i++) walk(doc, kids.at(i), name, result, page_of, seen, depth + 1);
                return;
            }
            var info = new FieldInfo();
            info.name = name;
            info.partial = partial;
            info.reference = r;
            info.dict = f;
            var ft = inherited(doc, f, "FT");
            info.flags = inherited(doc, f, "Ff").as_int(0);
            if (ft.is_name("Tx")) info.type = FieldType.TEXT;
            else if (ft.is_name("Btn")) info.type = (info.flags & (1 << 16)) != 0 ? FieldType.PUSHBUTTON : ((info.flags & (1 << 15)) != 0 ? FieldType.RADIO : FieldType.CHECKBOX);
            else if (ft.is_name("Ch")) info.type = (info.flags & (1 << 17)) != 0 ? FieldType.COMBO : FieldType.LIST;
            else if (ft.is_name("Sig")) info.type = FieldType.SIGNATURE;
            var v = inherited(doc, f, "V");
            if (v.is_name()) info.value = v.name;
            else if (v.is_string()) info.value = v.text_value();
            else if (v.is_stream()) info.value = Obj.decode_text(doc.stream_data(v));
            else if (v.is_array()) {
                string[] parts = {};
                for (int i = 0; i < v.length; i++) parts += doc.resolve(v.at(i)).text_value();
                info.value = string.joinv("\n", parts);
            } else if (v.is_dict() && info.type == FieldType.SIGNATURE) {
                info.value = "signed";
            }
            var dv = inherited(doc, f, "DV");
            info.default_value = dv.is_name() ? dv.name : dv.text_value();
            info.max_len = inherited(doc, f, "MaxLen").as_int(0);
            info.quadding = inherited(doc, f, "Q").as_int(0);
            info.da = inherited(doc, f, "DA").text_value();
            info.tooltip = doc.lookup(f, "TU").text_value();
            var opt = inherited(doc, f, "Opt");
            if (opt.is_array()) {
                string[] opts = {}, labels = {};
                for (int i = 0; i < opt.length; i++) {
                    var o = doc.resolve(opt.at(i));
                    if (o.is_array() && o.length >= 2) {
                        opts += doc.resolve(o.at(0)).text_value();
                        labels += doc.resolve(o.at(1)).text_value();
                    } else {
                        opts += o.text_value();
                        labels += o.text_value();
                    }
                }
                info.options = opts;
                info.option_labels = labels;
            }
            info.format_js = js_of(doc, f, "F");
            info.calculate_js = js_of(doc, f, "C");
            info.validate_js = js_of(doc, f, "V");
            info.keystroke_js = js_of(doc, f, "K");
            if (kids.is_array() && kids.length > 0) {
                for (int i = 0; i < kids.length; i++) add_widget(doc, info, kids.at(i), page_of);
            } else {
                add_widget(doc, info, r, page_of);
            }
            if ((info.type == FieldType.CHECKBOX || info.type == FieldType.RADIO) && info.options.length == 0) {
                string[] states = {};
                foreach (var w in info.widgets) if (w.on_state != "") states += w.on_state;
                info.options = states;
                info.option_labels = states;
            }
            result.add(info);
        }

        private static void add_widget(Document doc, FieldInfo info, Obj r, Gee.HashMap<int, int> page_of) {
            var w = new FieldWidget();
            w.reference = r;
            w.dict = doc.resolve(r);
            if (r.is_ref() && page_of.has_key(r.num)) w.page = page_of[r.num];
            else {
                var p = w.dict.get("P");
                if (p != null && p.is_ref()) w.page = doc.page_number_of(p.num);
            }
            var rect = doc.lookup(w.dict, "Rect");
            if (rect.is_array() && rect.length >= 4) w.rect = Rect.of(rect.at(0).as_number(), rect.at(1).as_number(), rect.at(2).as_number(), rect.at(3).as_number());
            var ap = doc.lookup(doc.lookup(w.dict, "AP"), "N");
            if (ap.is_dict() && !ap.is_stream()) {
                foreach (var k in ap.dict.keys) if (k != "Off") w.on_state = k;
            }
            info.widgets.add(w);
        }

        public static FieldInfo? find(Document doc, string name) {
            foreach (var f in list(doc)) if (f.name == name) return f;
            return null;
        }

        public static void parse_da(string da, out string font, out double size, out double[] color) {
            font = "Helv";
            size = 0;
            color = { 0, 0, 0 };
            var ops = Content.parse(da.data);
            foreach (var op in ops) {
                if (op.name == "Tf" && op.args.size >= 2) {
                    if (op.args[0].is_name()) font = op.args[0].name;
                    size = op.num(1);
                } else if (op.name == "rg" && op.args.size >= 3) {
                    color = { op.num(0), op.num(1), op.num(2) };
                } else if (op.name == "g" && op.args.size >= 1) {
                    color = { op.num(0), op.num(0), op.num(0) };
                } else if (op.name == "k" && op.args.size >= 4) {
                    color = { (1 - op.num(0)) * (1 - op.num(3)), (1 - op.num(1)) * (1 - op.num(3)), (1 - op.num(2)) * (1 - op.num(3)) };
                }
            }
        }

        private static EmbeddedFont? form_font = null;
        private static unowned Document? form_font_doc = null;

        private static EmbeddedFont? font_for(Document doc) {
            if (form_font == null || form_font_doc != doc) {
                form_font = EmbeddedFont.for_pattern(doc, "sans-serif");
                form_font_doc = doc;
            }
            return form_font;
        }

        private static string f(double v) {
            return Obj.format_number(Math.round(v * 1000) / 1000);
        }

        private static Obj form_xobject(Document doc, Rect bbox, string content, Obj? resources) {
            var d = new Dict();
            d.set("Type", Obj.name_obj("XObject"));
            d.set("Subtype", Obj.name_obj("Form"));
            d.set("BBox", Obj.numbers({ 0, 0, bbox.width(), bbox.height() }));
            d.set("Resources", resources ?? Obj.dictionary());
            return doc.add_ref(doc.make_stream(content.data, true, d));
        }

        public static string display_value(FieldInfo info, string raw) {
            if (info.format_js != "") {
                string formatted;
                if (Script.format(info.format_js, raw, out formatted)) return formatted;
            }
            if (info.type == FieldType.COMBO || info.type == FieldType.LIST) {
                for (int i = 0; i < info.options.length; i++) if (info.options[i] == raw && i < info.option_labels.length) return info.option_labels[i];
            }
            return raw;
        }

        public static void generate_appearance(Document doc, FieldInfo info) {
            foreach (var w in info.widgets) generate_widget(doc, info, w);
            var af = acroform(doc);
            if (af != null) af.remove("NeedAppearances");
        }

        private static string border_ops(Document doc, FieldWidget w, double width, double height) {
            var mk = doc.lookup(w.dict, "MK");
            var s = new StringBuilder();
            if (mk.is_dict()) {
                var bg = doc.lookup(mk, "BG");
                if (bg.is_array() && bg.length == 3) s.append_printf("%s %s %s rg 0 0 %s %s re f\n", f(bg.at(0).as_number()), f(bg.at(1).as_number()), f(bg.at(2).as_number()), f(width), f(height));
                else if (bg.is_array() && bg.length == 1) s.append_printf("%s g 0 0 %s %s re f\n", f(bg.at(0).as_number()), f(width), f(height));
                var bc = doc.lookup(mk, "BC");
                if (bc.is_array() && bc.length == 3) s.append_printf("%s %s %s RG 1 w 0.5 0.5 %s %s re S\n", f(bc.at(0).as_number()), f(bc.at(1).as_number()), f(bc.at(2).as_number()), f(width - 1), f(height - 1));
                else if (bc.is_array() && bc.length == 1) s.append_printf("%s G 1 w 0.5 0.5 %s %s re S\n", f(bc.at(0).as_number()), f(width - 1), f(height - 1));
            }
            return s.str;
        }

        private static void generate_widget(Document doc, FieldInfo info, FieldWidget w) {
            double width = w.rect.width(), height = w.rect.height();
            if (width <= 0 || height <= 0) return;
            string font_name;
            double size;
            double[] color;
            parse_da(info.da, out font_name, out size, out color);
            var ap = Obj.dictionary();
            switch (info.type) {
                case FieldType.CHECKBOX:
                case FieldType.RADIO:
                    string on = w.on_state != "" ? w.on_state : "Yes";
                    var n = doc.lookup(doc.lookup(w.dict, "AP"), "N");
                    if (!(n.is_dict() && !n.is_stream() && n.has(on) && n.has("Off"))) {
                        var states = Obj.dictionary();
                        string border = border_ops(doc, w, width, height);
                        var on_ops = new StringBuilder(border);
                        double m = double.min(width, height);
                        if (info.type == FieldType.RADIO) {
                            double r = m * 0.25, cx = width / 2, cy = height / 2, k = 0.5523 * r;
                            on_ops.append_printf("%s %s %s rg %s %s m %s %s %s %s %s %s c %s %s %s %s %s %s c %s %s %s %s %s %s c %s %s %s %s %s %s c f\n",
                                f(color[0]), f(color[1]), f(color[2]),
                                f(cx + r), f(cy), f(cx + r), f(cy + k), f(cx + k), f(cy + r), f(cx), f(cy + r),
                                f(cx - k), f(cy + r), f(cx - r), f(cy + k), f(cx - r), f(cy),
                                f(cx - r), f(cy - k), f(cx - k), f(cy - r), f(cx), f(cy - r),
                                f(cx + k), f(cy - r), f(cx + r), f(cy - k), f(cx + r), f(cy));
                        } else {
                            on_ops.append_printf("%s %s %s RG %s w 1 J 1 j %s %s m %s %s l %s %s l S\n", f(color[0]), f(color[1]), f(color[2]), f(m * 0.12),
                                f(width * 0.22), f(height * 0.52), f(width * 0.42), f(height * 0.28), f(width * 0.80), f(height * 0.76));
                        }
                        states.set(on, form_xobject(doc, w.rect, on_ops.str, null));
                        states.set("Off", form_xobject(doc, w.rect, border, null));
                        ap.set("N", states);
                        w.dict.set("AP", ap);
                        if (w.on_state == "") w.on_state = on;
                    }
                    w.dict.set("AS", Obj.name_obj(info.value == w.on_state && info.value != "" ? w.on_state : "Off"));
                    return;
                case FieldType.PUSHBUTTON:
                case FieldType.SIGNATURE:
                case FieldType.UNKNOWN:
                    return;
                default:
                    break;
            }
            var font = font_for(doc);
            if (font == null) return;
            string text = display_value(info, info.value);
            if (info.password) text = string.nfill(text.char_count(), '*');
            if (size <= 0) size = info.multiline ? 10 : double.min(12, double.max(6, (height - 4) * 0.72));
            var res = Obj.dictionary();
            var fonts = Obj.dictionary();
            fonts.set("F1", font.font_ref);
            res.set("Font", fonts);
            var ops = new StringBuilder(border_ops(doc, w, width, height));
            ops.append("/Tx BMC\nq\n");
            ops.append_printf("1 1 %s %s re W n\n", f(width - 2), f(height - 2));
            ops.append_printf("BT\n%s %s %s rg\n/F1 %s Tf\n", f(color[0]), f(color[1]), f(color[2]), f(size));
            if (info.type == FieldType.LIST) {
                double y = height - 2 - size;
                for (int i = 0; i < info.options.length && y > -size; i++) {
                    bool selected = info.options[i] == info.value || (info.value.contains("\n") && info.options[i] in info.value.split("\n"));
                    string label = i < info.option_labels.length ? info.option_labels[i] : info.options[i];
                    if (selected) {
                        ops.append_printf("ET 0.6 0.75 0.95 rg 1 %s %s %s re f BT %s %s %s rg /F1 %s Tf\n", f(y - size * 0.25), f(width - 2), f(size * 1.2), f(color[0]), f(color[1]), f(color[2]), f(size));
                    }
                    ops.append_printf("1 0 0 1 3 %s Tm %s Tj\n", f(y), font.hex(label));
                    y -= size * 1.2;
                }
            } else if (info.comb && info.max_len > 0) {
                double cell = width / info.max_len;
                int i = 0;
                int idx = 0;
                unichar u;
                while (text.get_next_char(ref idx, out u) && i < info.max_len) {
                    string ch = u.to_string();
                    double cw = font.measure(ch, size);
                    ops.append_printf("1 0 0 1 %s %s Tm %s Tj\n", f(cell * i + (cell - cw) / 2), f((height - size * 0.7) / 2), font.hex(ch));
                    i++;
                }
            } else if (info.multiline) {
                double y = height - 2 - size;
                foreach (var line in Annotations.wrap_lines(text, font, size, width - 4)) {
                    ops.append_printf("1 0 0 1 2 %s Tm %s Tj\n", f(y), font.hex(line));
                    y -= size * 1.15;
                }
            } else {
                double tw = font.measure(text, size);
                double x = 2;
                if (info.quadding == 1) x = (width - tw) / 2;
                else if (info.quadding == 2) x = width - 2 - tw;
                ops.append_printf("1 0 0 1 %s %s Tm %s Tj\n", f(x), f((height - size * 0.7) / 2), font.hex(text));
            }
            ops.append("ET\nQ\nEMC\n");
            ap.set("N", form_xobject(doc, w.rect, ops.str, res));
            w.dict.set("AP", ap);
        }

        public static void set_value(Document doc, FieldInfo info, string value) {
            info.value = value;
            var target = info.dict;
            switch (info.type) {
                case FieldType.CHECKBOX:
                case FieldType.RADIO:
                    string v = value == "" ? "Off" : value;
                    if (info.type == FieldType.CHECKBOX && (value == "true" || value == "1")) v = info.options.length > 0 ? info.options[0] : "Yes";
                    info.value = v == "Off" ? "" : v;
                    target.set("V", Obj.name_obj(v));
                    break;
                case FieldType.LIST:
                    if (value.contains("\n")) {
                        var arr = Obj.array();
                        foreach (var part in value.split("\n")) arr.add(Obj.text(part));
                        target.set("V", arr);
                    } else {
                        target.set("V", Obj.text(value));
                    }
                    break;
                case FieldType.SIGNATURE:
                case FieldType.PUSHBUTTON:
                    return;
                default:
                    target.set("V", Obj.text(value));
                    break;
            }
            generate_appearance(doc, info);
        }

        public static Obj ensure_acroform(Document doc) {
            var cat = doc.catalog();
            var af = doc.lookup(cat, "AcroForm");
            if (!af.is_dict()) {
                af = Obj.dictionary();
                af.set("Fields", Obj.array());
                cat.set("AcroForm", doc.add_ref(af));
            }
            if (!af.has("DA")) af.set("DA", Obj.str("/Helv 0 Tf 0 g".data));
            if (!af.has("Fields")) af.set("Fields", Obj.array());
            return af;
        }

        public static FieldInfo create_field(Document doc, int page, FieldType type, string name, Rect rect, string[] options = {},
                                             string tooltip = "", int extra_flags = 0) {
            var af = ensure_acroform(doc);
            string unique = name;
            int n = 2;
            while (find(doc, unique) != null && type != FieldType.RADIO) unique = "%s_%d".printf(name, n++);
            var widget = Obj.dictionary();
            widget.set("Type", Obj.name_obj("Annot"));
            widget.set("Subtype", Obj.name_obj("Widget"));
            widget.set("Rect", Obj.numbers({ rect.x1, rect.y1, rect.x2, rect.y2 }));
            widget.set("F", Obj.integer(4));
            widget.set("P", doc.page_refs()[page]);
            var mk = Obj.dictionary();
            mk.set("BC", Obj.numbers({ 0.45, 0.45, 0.5 }));
            mk.set("BG", Obj.numbers({ 0.93, 0.95, 1 }));
            widget.set("MK", mk);
            var bs = Obj.dictionary();
            bs.set("W", Obj.integer(1));
            bs.set("S", Obj.name_obj("S"));
            widget.set("BS", bs);
            if (type == FieldType.RADIO) {
                var group = find(doc, name);
                Obj group_ref;
                if (group == null) {
                    var parent = Obj.dictionary();
                    parent.set("FT", Obj.name_obj("Btn"));
                    parent.set("Ff", Obj.integer((1 << 15) | (1 << 14) | extra_flags));
                    parent.set("T", Obj.text(name));
                    parent.set("V", Obj.name_obj("Off"));
                    parent.set("Kids", Obj.array());
                    if (tooltip != "") parent.set("TU", Obj.text(tooltip));
                    group_ref = doc.add_ref(parent);
                    doc.resolve(af.get("Fields")).add(group_ref);
                } else {
                    group_ref = group.reference;
                }
                var kids = doc.sub_array(doc.resolve(group_ref), "Kids");
                string state = options.length > 0 ? options[0] : "Choice%d".printf(kids.length + 1);
                widget.set("Parent", group_ref);
                var wref = doc.add_ref(widget);
                kids.add(wref);
                doc.sub_array(doc.page(page), "Annots").add(wref);
                var info = find(doc, name);
                foreach (var w in info.widgets) {
                    if (w.dict == widget) {
                        w.on_state = state;
                        generate_widget(doc, info, w);
                    }
                }
                return find(doc, name);
            }
            widget.set("T", Obj.text(unique));
            if (tooltip != "") widget.set("TU", Obj.text(tooltip));
            int flags = extra_flags;
            switch (type) {
                case FieldType.TEXT:
                    widget.set("FT", Obj.name_obj("Tx"));
                    widget.set("DA", Obj.str("/Helv 0 Tf 0 g".data));
                    widget.set("V", Obj.text(""));
                    break;
                case FieldType.CHECKBOX:
                    widget.set("FT", Obj.name_obj("Btn"));
                    widget.set("V", Obj.name_obj("Off"));
                    widget.set("DA", Obj.str("/ZaDb 0 Tf 0 g".data));
                    break;
                case FieldType.COMBO:
                case FieldType.LIST:
                    widget.set("FT", Obj.name_obj("Ch"));
                    if (type == FieldType.COMBO) flags |= 1 << 17;
                    var opt = Obj.array();
                    foreach (var o in options) opt.add(Obj.text(o));
                    widget.set("Opt", opt);
                    widget.set("DA", Obj.str("/Helv 0 Tf 0 g".data));
                    widget.set("V", Obj.text(options.length > 0 && type == FieldType.COMBO ? options[0] : ""));
                    break;
                case FieldType.SIGNATURE:
                    widget.set("FT", Obj.name_obj("Sig"));
                    widget.remove("MK");
                    break;
                case FieldType.PUSHBUTTON:
                    widget.set("FT", Obj.name_obj("Btn"));
                    flags |= 1 << 16;
                    break;
                default:
                    break;
            }
            if (flags != 0) widget.set("Ff", Obj.integer(flags));
            var field_ref = doc.add_ref(widget);
            doc.resolve(af.get("Fields")).add(field_ref);
            doc.sub_array(doc.page(page), "Annots").add(field_ref);
            var info = find(doc, unique);
            if (type == FieldType.CHECKBOX) info.widgets[0].on_state = options.length > 0 ? options[0] : "Yes";
            generate_appearance(doc, info);
            return info;
        }

        public static void remove_field(Document doc, FieldInfo info) {
            foreach (var w in info.widgets) {
                if (w.page >= 0) Annotations.remove(doc, w.page, w.reference);
            }
            var af = acroform(doc);
            if (af == null) return;
            remove_from(doc, doc.lookup(af, "Fields"), info.reference);
        }

        private static void remove_from(Document doc, Obj arr, Obj target) {
            if (!arr.is_array()) return;
            for (int i = arr.length - 1; i >= 0; i--) {
                var r = arr.at(i);
                if (r.is_ref() && target.is_ref() && r.num == target.num) {
                    arr.items.remove_at(i);
                    continue;
                }
                var kid = doc.resolve(r);
                if (kid.is_dict()) remove_from(doc, doc.lookup(kid, "Kids"), target);
            }
        }

        public static void set_properties(Document doc, FieldInfo info, string? new_name, string? tooltip, bool? required, bool? read_only,
                                          bool? multiline, int max_len, string[]? options) {
            var d = info.dict;
            if (new_name != null && new_name != "") d.set("T", Obj.text(new_name));
            if (tooltip != null) {
                if (tooltip == "") d.remove("TU");
                else d.set("TU", Obj.text(tooltip));
            }
            int flags = info.flags;
            if (required != null) flags = required ? flags | 2 : flags & ~2;
            if (read_only != null) flags = read_only ? flags | 1 : flags & ~1;
            if (multiline != null && info.type == FieldType.TEXT) flags = multiline ? flags | (1 << 12) : flags & ~(1 << 12);
            d.set("Ff", Obj.integer(flags));
            if (max_len > 0) d.set("MaxLen", Obj.integer(max_len));
            else if (max_len == 0) d.remove("MaxLen");
            if (options != null) {
                var opt = Obj.array();
                foreach (var o in options) opt.add(Obj.text(o));
                d.set("Opt", opt);
            }
        }

        public static void set_script(Document doc, FieldInfo info, string trigger, string js) {
            var aa = doc.sub_dict(info.dict, "AA");
            if (js.strip() == "") {
                aa.remove(trigger);
                return;
            }
            var action = Obj.dictionary();
            action.set("S", Obj.name_obj("JavaScript"));
            action.set("JS", Obj.text(js));
            aa.set(trigger, action);
            if (trigger == "C") {
                var af = ensure_acroform(doc);
                var co = doc.sub_array(af, "CO");
                bool present = false;
                for (int i = 0; i < co.length; i++) if (co.at(i).is_ref() && info.reference.is_ref() && co.at(i).num == info.reference.num) present = true;
                if (!present) co.add(info.reference);
            }
        }

        public static int recalculate(Document doc) {
            var fields = list(doc);
            var values = new Gee.HashMap<string, string>();
            foreach (var fi in fields) values[fi.name] = fi.value;
            var order = new Gee.ArrayList<FieldInfo>();
            var af = acroform(doc);
            var co = af != null ? doc.lookup(af, "CO") : Obj.none();
            if (co.is_array()) {
                for (int i = 0; i < co.length; i++) {
                    foreach (var fi in fields) {
                        if (fi.reference.is_ref() && co.at(i).is_ref() && fi.reference.num == co.at(i).num) order.add(fi);
                    }
                }
            }
            foreach (var fi in fields) if (fi.calculate_js != "" && !order.contains(fi)) order.add(fi);
            int changed = 0;
            foreach (var fi in order) {
                string result;
                if (!Script.calculate(fi.calculate_js, values, out result)) continue;
                if (result != fi.value) {
                    set_value(doc, fi, result);
                    values[fi.name] = result;
                    changed++;
                }
            }
            return changed;
        }

        public static bool validate(FieldInfo info, string value, out string message) {
            message = "";
            if (info.required && value.strip() == "") {
                message = _("This field is required");
                return false;
            }
            if (info.max_len > 0 && value.char_count() > info.max_len) {
                message = _("At most %d characters").printf(info.max_len);
                return false;
            }
            if (info.validate_js != "") return Script.validate(info.validate_js, value, out message);
            if (info.keystroke_js.contains("AFNumber_Keystroke") && value.strip() != "") {
                double d;
                if (!Script.parse_number(value, out d)) {
                    message = _("Enter a number");
                    return false;
                }
            }
            return true;
        }

        public static string xfdf_fields(Document doc) {
            var fields = list(doc);
            if (fields.size == 0) return "";
            var s = new StringBuilder("  <fields>\n");
            foreach (var fi in fields) {
                if (fi.type == FieldType.PUSHBUTTON || fi.type == FieldType.SIGNATURE) continue;
                s.append_printf("    <field name=\"%s\"><value>%s</value></field>\n", Markup.escape_text(fi.name), Markup.escape_text(fi.value));
            }
            s.append("  </fields>\n");
            return s.str;
        }

        public static Obj fdf_fields(Document doc) {
            var arr = Obj.array();
            foreach (var fi in list(doc)) {
                if (fi.type == FieldType.PUSHBUTTON || fi.type == FieldType.SIGNATURE) continue;
                var d = Obj.dictionary();
                d.set("T", Obj.text(fi.name));
                if (fi.type == FieldType.CHECKBOX || fi.type == FieldType.RADIO) d.set("V", Obj.name_obj(fi.value == "" ? "Off" : fi.value));
                else d.set("V", Obj.text(fi.value));
                arr.add(d);
            }
            return arr;
        }

        public static int import_values(Document doc, Gee.Map<string, string> values) {
            int count = 0;
            foreach (var fi in list(doc)) {
                if (!values.has_key(fi.name)) continue;
                set_value(doc, fi, values[fi.name]);
                count++;
            }
            if (count > 0) recalculate(doc);
            return count;
        }

        private static string csv_escape(string s) {
            if (s.contains(",") || s.contains("\"") || s.contains("\n")) return "\"" + s.replace("\"", "\"\"") + "\"";
            return s;
        }

        public static string export_csv(Document doc) {
            var fields = list(doc);
            var names = new StringBuilder();
            var vals = new StringBuilder();
            bool first = true;
            foreach (var fi in fields) {
                if (fi.type == FieldType.PUSHBUTTON || fi.type == FieldType.SIGNATURE) continue;
                if (!first) {
                    names.append_c(',');
                    vals.append_c(',');
                }
                first = false;
                names.append(csv_escape(fi.name));
                vals.append(csv_escape(fi.value));
            }
            return names.str + "\n" + vals.str + "\n";
        }

        public static Gee.ArrayList<Gee.ArrayList<string>> parse_csv(string text) {
            var rows = new Gee.ArrayList<Gee.ArrayList<string>>();
            var row = new Gee.ArrayList<string>();
            var cell = new StringBuilder();
            bool quoted = false;
            int i = 0;
            unichar c;
            string t = text.replace("\r\n", "\n");
            while (t.get_next_char(ref i, out c)) {
                if (quoted) {
                    if (c == '"') {
                        if (i < t.length && t[i] == '"') {
                            cell.append_c('"');
                            i++;
                        } else {
                            quoted = false;
                        }
                    } else {
                        cell.append_unichar(c);
                    }
                } else if (c == '"') {
                    quoted = true;
                } else if (c == ',' || c == ';') {
                    row.add(cell.str);
                    cell.truncate();
                } else if (c == '\n') {
                    row.add(cell.str);
                    cell.truncate();
                    rows.add(row);
                    row = new Gee.ArrayList<string>();
                } else {
                    cell.append_unichar(c);
                }
            }
            if (cell.len > 0 || row.size > 0) {
                row.add(cell.str);
                rows.add(row);
            }
            return rows;
        }

        public static int import_csv(Document doc, string text, int row = 0) {
            var rows = parse_csv(text);
            if (rows.size < 2) return 0;
            var header = rows[0];
            var data = rows[int.min(rows.size - 1, row + 1)];
            var values = new Gee.HashMap<string, string>();
            for (int i = 0; i < header.size && i < data.size; i++) values[header[i].strip()] = data[i];
            return import_values(doc, values);
        }

        public static Gee.HashMap<string, string> xfa_values(Document doc) {
            var values = new Gee.HashMap<string, string>();
            var af = acroform(doc);
            if (af == null) return values;
            var xfa = doc.lookup(af, "XFA");
            string xml = "";
            if (xfa.is_stream()) {
                xml = (string) doc.stream_data(xfa);
            } else if (xfa.is_array()) {
                for (int i = 0; i + 1 < xfa.length; i += 2) {
                    if (doc.resolve(xfa.at(i)).text_value() == "datasets") {
                        var bytes = doc.stream_data(xfa.at(i + 1));
                        var b = new uint8[bytes.length + 1];
                        Memory.copy(b, bytes, bytes.length);
                        xml = (string) b;
                    }
                }
            }
            if (xml == "") return values;
            int start = xml.index_of("<xfa:data");
            if (start < 0) return values;
            int end = xml.index_of("</xfa:data>", start);
            string data = end > 0 ? xml.substring(start, end - start + 11) : xml.substring(start);
            var stack = new Gee.ArrayList<string>();
            var text = new StringBuilder();
            var parser = MarkupParser() {
                start_element = (ctx, name, n, v) => {
                    stack.add(name);
                    text.truncate();
                },
                end_element = (ctx, name) => {
                    if (text.str.strip() != "" && stack.size > 1) values[stack[stack.size - 1]] = text.str.strip();
                    if (stack.size > 0) stack.remove_at(stack.size - 1);
                    text.truncate();
                },
                text = (ctx, t, len) => {
                    text.append_len(t, (ssize_t) len);
                }
            };
            var ctx = new MarkupParseContext(parser, MarkupParseFlags.TREAT_CDATA_AS_TEXT, null, null);
            try {
                ctx.parse(data, -1);
                ctx.end_parse();
            } catch (Error e) {
            }
            return values;
        }

        public static int apply_xfa_to_acroform(Document doc) {
            var values = xfa_values(doc);
            if (values.size == 0) return 0;
            var mapped = new Gee.HashMap<string, string>();
            foreach (var fi in list(doc)) {
                string leaf = fi.name.contains(".") ? fi.name.substring(fi.name.last_index_of_char('.') + 1) : fi.name;
                int bracket = leaf.index_of_char('[');
                if (bracket > 0) leaf = leaf.substring(0, bracket);
                if (values.has_key(leaf)) mapped[fi.name] = values[leaf];
            }
            return import_values(doc, mapped);
        }

        public static void remove_xfa(Document doc) {
            var af = acroform(doc);
            if (af != null) af.remove("XFA");
            doc.catalog().remove("NeedsRendering");
        }

        public static void flatten(Document doc) {
            var fields = list(doc);
            var per_page = new Gee.HashMap<int, string>();
            var page_res = new Gee.HashMap<int, Obj>();
            int counter = 0;
            foreach (var fi in fields) {
                foreach (var w in fi.widgets) {
                    if (w.page < 0) continue;
                    var n = doc.lookup(doc.lookup(w.dict, "AP"), "N");
                    Obj? ap_ref = doc.lookup(w.dict, "AP").is_dict() ? doc.lookup(w.dict, "AP").get("N") : null;
                    if (n.is_dict() && !n.is_stream()) {
                        var state = doc.lookup(w.dict, "AS");
                        ap_ref = state.is_name() ? n.get(state.name) : null;
                        n = doc.resolve(ap_ref);
                    }
                    if (n.is_stream() && ap_ref != null && (doc.lookup(w.dict, "F").as_int(0) & 2) == 0) {
                        if (!per_page.has_key(w.page)) {
                            per_page[w.page] = "";
                            page_res[w.page] = doc.page_resources(w.page);
                        }
                        var xo = doc.sub_dict(page_res[w.page], "XObject");
                        string name = "Fx%d".printf(counter++);
                        while (xo.has(name)) name = "Fx%d".printf(counter++);
                        if (!ap_ref.is_ref()) ap_ref = doc.add_ref(n);
                        xo.set(name, ap_ref);
                        var bbox = doc.lookup(n, "BBox");
                        double bx = 0, by = 0, bw = w.rect.width(), bh = w.rect.height();
                        if (bbox.is_array() && bbox.length >= 4) {
                            var br = Rect.of(bbox.at(0).as_number(), bbox.at(1).as_number(), bbox.at(2).as_number(), bbox.at(3).as_number());
                            bx = br.x1;
                            by = br.y1;
                            bw = br.width();
                            bh = br.height();
                        }
                        double sx = bw > 0 ? w.rect.width() / bw : 1, sy = bh > 0 ? w.rect.height() / bh : 1;
                        per_page[w.page] = per_page[w.page] + "q %s 0 0 %s %s %s cm /%s Do Q\n".printf(f(sx), f(sy), f(w.rect.x1 - bx * sx), f(w.rect.y1 - by * sy), name);
                    }
                    Annotations.remove(doc, w.page, w.reference);
                }
            }
            foreach (var e in per_page.entries) doc.append_page_content(e.key, e.value.data);
            doc.catalog().remove("AcroForm");
        }

        public static Gee.ArrayList<DetectedField> detect(Document doc, int page) {
            var result = new Gee.ArrayList<DetectedField>();
            var it = new Interpreter(doc);
            it.run_page(page);
            var texts = new Gee.ArrayList<Item>();
            foreach (var item in it.items) if (item.kind == ItemKind.TEXT && item.text().strip() != "") texts.add(item);
            var existing = new Gee.ArrayList<Rect?>();
            foreach (var fi in list(doc)) foreach (var w in fi.widgets) if (w.page == page) existing.add(w.rect);
            int n = 1;
            foreach (var item in it.items) {
                if (item.kind != ItemKind.PATH) continue;
                var b = item.box;
                DetectedField? cand = null;
                if (b.height() <= 2.5 && b.width() >= 40) {
                    cand = new DetectedField();
                    cand.type = FieldType.TEXT;
                    cand.rect = Rect.of(b.x1, b.y2 + 0.5, b.x2, b.y2 + 16);
                } else if (b.width() >= 6 && b.width() <= 22 && b.height() >= 6 && b.height() <= 22 && (b.width() - b.height()).abs() <= 3) {
                    cand = new DetectedField();
                    cand.type = FieldType.CHECKBOX;
                    cand.rect = b;
                } else if (b.width() >= 60 && b.height() >= 12 && b.height() <= 60) {
                    bool empty = true;
                    foreach (var t in texts) if (t.box.intersects(b)) empty = false;
                    if (empty) {
                        cand = new DetectedField();
                        cand.type = FieldType.TEXT;
                        cand.rect = Rect.of(b.x1 + 1, b.y1 + 1, b.x2 - 1, b.y2 - 1);
                    }
                }
                if (cand == null) continue;
                bool blocked = false;
                foreach (var t in texts) {
                    if (cand.type == FieldType.TEXT && t.box.overlap_ratio(cand.rect) > 0.3) blocked = true;
                }
                foreach (var r in existing) if (r.intersects(cand.rect)) blocked = true;
                foreach (var d in result) if (d.rect.intersects(cand.rect)) blocked = true;
                if (blocked) continue;
                cand.page = page;
                cand.name = label_near(texts, cand.rect);
                if (cand.name == "") cand.name = (cand.type == FieldType.CHECKBOX ? "Check" : "Field") + "%d".printf(n++);
                result.add(cand);
            }
            return result;
        }

        private static string label_near(Gee.List<Item> texts, Rect r) {
            Item? best = null;
            double best_d = 120;
            foreach (var t in texts) {
                double cy = (r.y1 + r.y2) / 2, ty = (t.box.y1 + t.box.y2) / 2;
                double d;
                if (t.box.x2 <= r.x1 + 2 && (ty - cy).abs() < double.max(8, r.height())) d = r.x1 - t.box.x2;
                else if (t.box.y1 >= r.y2 - 2 && t.box.x1 < r.x2 && t.box.x2 > r.x1) d = t.box.y1 - r.y2 + 20;
                else continue;
                if (d < best_d) {
                    best_d = d;
                    best = t;
                }
            }
            if (best == null) return "";
            string label = best.text().strip();
            while (label.has_suffix(":") || label.has_suffix("_") || label.has_suffix(".")) label = label.substring(0, label.length - 1).strip();
            var clean = new StringBuilder();
            int i = 0;
            unichar c;
            while (label.get_next_char(ref i, out c)) {
                if (c.isalnum() || c == ' ') clean.append_unichar(c);
            }
            string s = clean.str.strip();
            return s.char_count() > 40 ? s.substring(0, s.index_of_nth_char(40)) : s;
        }
    }
}
