namespace Singularity.Pdf {

    public enum ShapeKind {
        RECTANGLE,
        ELLIPSE,
        LINE,
        ARROW,
        POLYGON,
        POLYLINE,
        CLOUD
    }

    public class Points {
        public double[] v;

        public Points(double[] v) {
            this.v = v;
        }
    }

    public class AnnotInfo {
        public int page;
        public Obj reference;
        public Obj dict;
        public string subtype = "";
        public Rect rect;
        public string author = "";
        public string contents = "";
        public string subject = "";
        public string modified = "";
        public string name = "";
        public int reply_to = -1;
        public string state = "";
        public string state_model = "";
        public double[]? color = null;
        public int flags = 0;
        public bool is_reply {
            get { return reply_to >= 0; }
        }
    }

    public class Annotations {
        public const string[] MARKUP_TYPES = {
            "Text", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight", "Underline", "Squiggly",
            "StrikeOut", "Stamp", "Caret", "Ink", "FileAttachment", "Sound", "Redact"
        };

        public static string date_now() {
            var now = new DateTime.now_local();
            var off = now.get_utc_offset() / TimeSpan.MINUTE;
            string sign = off >= 0 ? "+" : "-";
            off = off.abs();
            return "D:%s%s%02d'%02d'".printf(now.format("%Y%m%d%H%M%S"), sign, (int) (off / 60), (int) (off % 60));
        }

        public static DateTime? parse_date(string d) {
            string s = d.has_prefix("D:") ? d.substring(2) : d;
            if (s.length < 4) return null;
            int[] parts = { 0, 1, 1, 0, 0, 0 };
            int[] lens = { 4, 2, 2, 2, 2, 2 };
            int pos = 0;
            for (int i = 0; i < 6 && pos + lens[i] <= s.length; i++) {
                int v = int.parse(s.substring(pos, lens[i]));
                parts[i] = v;
                pos += lens[i];
            }
            var tz = new TimeZone.utc();
            if (pos < s.length) {
                char c = s[pos];
                if (c == '+' || c == '-') {
                    string rest = s.substring(pos + 1).replace("'", "");
                    int hh = rest.length >= 2 ? int.parse(rest.substring(0, 2)) : 0;
                    int mm = rest.length >= 4 ? int.parse(rest.substring(2, 2)) : 0;
                    try {
                        tz = new TimeZone.identifier("%c%02d:%02d".printf(c, hh, mm));
                    } catch (Error e) {
                    }
                }
            } else {
                tz = new TimeZone.local();
            }
            return new DateTime(tz, parts[0], parts[1].clamp(1, 12), parts[2].clamp(1, 31), parts[3], parts[4], parts[5]);
        }

        public static Gee.ArrayList<AnnotInfo> list(Document doc, int page = -1) {
            var result = new Gee.ArrayList<AnnotInfo>();
            int first = page >= 0 ? page : 0;
            int last = page >= 0 ? page : doc.page_count() - 1;
            for (int p = first; p <= last; p++) {
                var annots = doc.lookup(doc.page(p), "Annots");
                if (!annots.is_array()) continue;
                for (int i = 0; i < annots.length; i++) {
                    var r = annots.at(i);
                    var a = doc.resolve(r);
                    if (!a.is_dict()) continue;
                    var info = new AnnotInfo();
                    info.page = p;
                    info.reference = r;
                    info.dict = a;
                    var st = doc.lookup(a, "Subtype");
                    info.subtype = st.is_name() ? st.name : "";
                    var rect = doc.lookup(a, "Rect");
                    if (rect.is_array() && rect.length >= 4) info.rect = Rect.of(rect.at(0).as_number(), rect.at(1).as_number(), rect.at(2).as_number(), rect.at(3).as_number());
                    info.author = doc.lookup(a, "T").text_value();
                    info.contents = doc.lookup(a, "Contents").text_value();
                    info.subject = doc.lookup(a, "Subj").text_value();
                    info.modified = doc.lookup(a, "M").text_value();
                    info.name = doc.lookup(a, "NM").text_value();
                    var irt = a.get("IRT");
                    if (irt != null && irt.is_ref()) info.reply_to = irt.num;
                    info.state = doc.lookup(a, "State").text_value();
                    info.state_model = doc.lookup(a, "StateModel").text_value();
                    info.flags = doc.lookup(a, "F").as_int(0);
                    var c = doc.lookup(a, "C");
                    if (c.is_array() && c.length == 3) info.color = { c.at(0).as_number(), c.at(1).as_number(), c.at(2).as_number() };
                    result.add(info);
                }
            }
            return result;
        }

        public static Obj add(Document doc, int page, Obj annot) {
            var p = doc.page(page);
            var refs = doc.page_refs();
            annot.set("Type", Obj.name_obj("Annot"));
            annot.set("P", refs[page]);
            if (!annot.has("F")) annot.set("F", Obj.integer(4));
            if (!annot.has("M")) annot.set("M", Obj.text(date_now()));
            if (!annot.has("NM")) annot.set("NM", Obj.text(Uuid.string_random()));
            var r = doc.add_ref(annot);
            var annots = doc.sub_array(p, "Annots");
            annots.add(r);
            return r;
        }

        public static void remove(Document doc, int page, Obj reference) {
            var p = doc.page(page);
            var annots = doc.lookup(p, "Annots");
            if (!annots.is_array()) return;
            var keep = Obj.array();
            var target = doc.resolve(reference);
            var popup = target.get("Popup");
            for (int i = 0; i < annots.length; i++) {
                var r = annots.at(i);
                if (r.is_ref() && reference.is_ref() && r.num == reference.num) continue;
                if (popup != null && popup.is_ref() && r.is_ref() && r.num == popup.num) continue;
                var a = doc.resolve(r);
                var irt = a.get("IRT");
                if (irt != null && irt.is_ref() && reference.is_ref() && irt.num == reference.num) continue;
                keep.add(r);
            }
            p.set("Annots", keep);
        }

        private static string col(double[] c, bool stroke) {
            return "%s %s %s %s".printf(Obj.format_number(c[0]), Obj.format_number(c[1]), Obj.format_number(c[2]), stroke ? "RG" : "rg");
        }

        public static double[] rgb(string hex) {
            string t = hex.strip();
            if (t.has_prefix("#")) t = t.substring(1);
            uint64 v = 0;
            if (t.length != 6 || !uint64.try_parse(t, out v, null, 16)) v = 0xe01b24;
            return { ((v >> 16) & 0xff) / 255.0, ((v >> 8) & 0xff) / 255.0, (v & 0xff) / 255.0 };
        }

        public static Obj appearance(Document doc, Rect bbox, string content, Obj? resources = null) {
            var d = new Dict();
            d.set("Type", Obj.name_obj("XObject"));
            d.set("Subtype", Obj.name_obj("Form"));
            d.set("BBox", Obj.numbers({ bbox.x1, bbox.y1, bbox.x2, bbox.y2 }));
            d.set("Resources", resources ?? Obj.dictionary());
            var s = doc.make_stream(content.data, true, d);
            var ap = Obj.dictionary();
            ap.set("N", doc.add_ref(s));
            return ap;
        }

        private static Obj opacity_resources(double opacity, bool multiply = false) {
            var res = Obj.dictionary();
            var gs = Obj.dictionary();
            var g0 = Obj.dictionary();
            g0.set("Type", Obj.name_obj("ExtGState"));
            g0.set("CA", Obj.number(opacity));
            g0.set("ca", Obj.number(opacity));
            if (multiply) g0.set("BM", Obj.name_obj("Multiply"));
            gs.set("GS0", g0);
            res.set("ExtGState", gs);
            return res;
        }

        private static void base_fields(Obj a, string subtype, double[] color, string author, string contents) {
            a.set("Subtype", Obj.name_obj(subtype));
            a.set("C", Obj.numbers(color));
            if (author != "") a.set("T", Obj.text(author));
            if (contents != "") a.set("Contents", Obj.text(contents));
            a.set("CreationDate", Obj.text(date_now()));
        }

        private static string cloud_path(double[] pts, double radius) {
            var s = new StringBuilder();
            int n = pts.length / 2;
            bool started = false;
            for (int i = 0; i < n; i++) {
                double x1 = pts[i * 2], y1 = pts[i * 2 + 1];
                double x2 = pts[((i + 1) % n) * 2], y2 = pts[((i + 1) % n) * 2 + 1];
                double len = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
                int bumps = int.max(1, (int) (len / (radius * 1.6)));
                double dx = (x2 - x1) / bumps, dy = (y2 - y1) / bumps;
                double nx = dy / double.max(0.001, Math.sqrt(dx * dx + dy * dy)), ny = -dx / double.max(0.001, Math.sqrt(dx * dx + dy * dy));
                for (int k = 0; k < bumps; k++) {
                    double ax = x1 + dx * k, ay = y1 + dy * k;
                    double bx = ax + dx, by = ay + dy;
                    if (!started) {
                        s.append_printf("%s %s m\n", Obj.format_number(ax), Obj.format_number(ay));
                        started = true;
                    }
                    double bulge = Math.sqrt(dx * dx + dy * dy) * 0.55;
                    s.append_printf("%s %s %s %s %s %s c\n",
                        Obj.format_number(ax + nx * bulge), Obj.format_number(ay + ny * bulge),
                        Obj.format_number(bx + nx * bulge), Obj.format_number(by + ny * bulge),
                        Obj.format_number(bx), Obj.format_number(by));
                }
            }
            s.append("h\n");
            return s.str;
        }

        private static string ellipse_path(Rect r) {
            double cx = (r.x1 + r.x2) / 2, cy = (r.y1 + r.y2) / 2, rx = r.width() / 2, ry = r.height() / 2;
            double k = 0.5523;
            return "%s %s m %s %s %s %s %s %s c %s %s %s %s %s %s c %s %s %s %s %s %s c %s %s %s %s %s %s c h\n".printf(
                f(cx + rx), f(cy),
                f(cx + rx), f(cy + ry * k), f(cx + rx * k), f(cy + ry), f(cx), f(cy + ry),
                f(cx - rx * k), f(cy + ry), f(cx - rx), f(cy + ry * k), f(cx - rx), f(cy),
                f(cx - rx), f(cy - ry * k), f(cx - rx * k), f(cy - ry), f(cx), f(cy - ry),
                f(cx + rx * k), f(cy - ry), f(cx + rx), f(cy - ry * k), f(cx + rx), f(cy));
        }

        private static string f(double v) {
            return Obj.format_number(Math.round(v * 1000) / 1000);
        }

        public static Obj shape(Document doc, int page, ShapeKind kind, double[] points, double[] color, double[]? fill,
                                double width, double opacity, string author, string contents) {
            var a = Obj.dictionary();
            var bounds = Rect.empty();
            for (int i = 0; i + 1 < points.length; i += 2) bounds.add(points[i], points[i + 1]);
            double pad = width * 2 + (kind == ShapeKind.ARROW ? width * 6 + 6 : 0) + (kind == ShapeKind.CLOUD ? 8 : 0);
            var rect = Rect.of(bounds.x1 - pad, bounds.y1 - pad, bounds.x2 + pad, bounds.y2 + pad);
            var ops = new StringBuilder();
            ops.append("/GS0 gs\n");
            ops.append_printf("%s\n%s w\n1 J 1 j\n", col(color, true), f(width));
            if (fill != null) ops.append_printf("%s\n", col(fill, false));
            string paint = fill != null ? "B" : "S";
            switch (kind) {
                case ShapeKind.RECTANGLE:
                    base_fields(a, "Square", color, author, contents);
                    ops.append_printf("%s %s %s %s re %s\n", f(bounds.x1), f(bounds.y1), f(bounds.width()), f(bounds.height()), paint);
                    a.set("Rect", Obj.numbers({ bounds.x1 - width, bounds.y1 - width, bounds.x2 + width, bounds.y2 + width }));
                    rect = Rect.of(bounds.x1 - width, bounds.y1 - width, bounds.x2 + width, bounds.y2 + width);
                    a.set("RD", Obj.numbers({ width, width, width, width }));
                    break;
                case ShapeKind.ELLIPSE:
                    base_fields(a, "Circle", color, author, contents);
                    ops.append(ellipse_path(bounds));
                    ops.append(paint + "\n");
                    rect = Rect.of(bounds.x1 - width, bounds.y1 - width, bounds.x2 + width, bounds.y2 + width);
                    a.set("RD", Obj.numbers({ width, width, width, width }));
                    break;
                case ShapeKind.LINE:
                case ShapeKind.ARROW:
                    base_fields(a, "Line", color, author, contents);
                    a.set("L", Obj.numbers(points[0 : 4]));
                    ops.append_printf("%s %s m %s %s l S\n", f(points[0]), f(points[1]), f(points[2]), f(points[3]));
                    if (kind == ShapeKind.ARROW) {
                        a.set("LE", Obj.names({ "None", "OpenArrow" }));
                        double ang = Math.atan2(points[3] - points[1], points[2] - points[0]);
                        double len = 6 + width * 3;
                        double ax1 = points[2] - len * Math.cos(ang - 0.45), ay1 = points[3] - len * Math.sin(ang - 0.45);
                        double ax2 = points[2] - len * Math.cos(ang + 0.45), ay2 = points[3] - len * Math.sin(ang + 0.45);
                        ops.append_printf("%s %s m %s %s l %s %s l S\n", f(ax1), f(ay1), f(points[2]), f(points[3]), f(ax2), f(ay2));
                    }
                    break;
                case ShapeKind.POLYGON:
                case ShapeKind.CLOUD:
                case ShapeKind.POLYLINE:
                    base_fields(a, kind == ShapeKind.POLYLINE ? "PolyLine" : "Polygon", color, author, contents);
                    a.set("Vertices", Obj.numbers(points));
                    if (kind == ShapeKind.CLOUD) {
                        var be = Obj.dictionary();
                        be.set("S", Obj.name_obj("C"));
                        be.set("I", Obj.integer(1));
                        a.set("BE", be);
                        ops.append(cloud_path(points, 6));
                        ops.append(paint + "\n");
                    } else {
                        for (int i = 0; i + 1 < points.length; i += 2) ops.append_printf("%s %s %s\n", f(points[i]), f(points[i + 1]), i == 0 ? "m" : "l");
                        ops.append(kind == ShapeKind.POLYGON ? "h " + paint + "\n" : "S\n");
                    }
                    break;
            }
            if (fill != null && (kind == ShapeKind.RECTANGLE || kind == ShapeKind.ELLIPSE || kind == ShapeKind.POLYGON || kind == ShapeKind.CLOUD)) a.set("IC", Obj.numbers(fill));
            var bs = Obj.dictionary();
            bs.set("W", Obj.number(width));
            a.set("BS", bs);
            if (opacity < 1) a.set("CA", Obj.number(opacity));
            a.set("Rect", Obj.numbers({ rect.x1, rect.y1, rect.x2, rect.y2 }));
            a.set("AP", appearance(doc, rect, ops.str, opacity_resources(opacity)));
            return add(doc, page, a);
        }

        public static Obj ink(Document doc, int page, Gee.List<Points> strokes, double[] color, double width, double opacity,
                              string author) {
            var a = Obj.dictionary();
            base_fields(a, "Ink", color, author, "");
            var list = Obj.array();
            var bounds = Rect.empty();
            var ops = new StringBuilder("/GS0 gs\n");
            ops.append_printf("%s\n%s w\n1 J 1 j\n", col(color, true), f(width));
            foreach (var stroke in strokes) {
                var s = stroke.v;
                list.add(Obj.numbers(s));
                for (int i = 0; i + 1 < s.length; i += 2) {
                    bounds.add(s[i], s[i + 1]);
                    ops.append_printf("%s %s %s\n", f(s[i]), f(s[i + 1]), i == 0 ? "m" : "l");
                }
                ops.append("S\n");
            }
            a.set("InkList", list);
            var bs = Obj.dictionary();
            bs.set("W", Obj.number(width));
            a.set("BS", bs);
            if (opacity < 1) a.set("CA", Obj.number(opacity));
            var rect = Rect.of(bounds.x1 - width, bounds.y1 - width, bounds.x2 + width, bounds.y2 + width);
            a.set("Rect", Obj.numbers({ rect.x1, rect.y1, rect.x2, rect.y2 }));
            a.set("AP", appearance(doc, rect, ops.str, opacity_resources(opacity)));
            return add(doc, page, a);
        }

        public static Obj note(Document doc, int page, double x, double y, string text, double[] color, string author) {
            var a = Obj.dictionary();
            base_fields(a, "Text", color, author, text);
            a.set("Rect", Obj.numbers({ x, y - 20, x + 20, y }));
            a.set("Name", Obj.name_obj("Comment"));
            a.set("Open", Obj.boolean(false));
            var ops = "%s\n0 0 0 RG 0.6 w\n%s %s 18 14 re B\n%s %s m %s %s l %s %s l f\n".printf(col(color, false),
                f(x + 1), f(y - 15), f(x + 5), f(y - 15), f(x + 5), f(y - 19), f(x + 9), f(y - 15));
            a.set("AP", appearance(doc, Rect.of(x, y - 20, x + 20, y), ops));
            return add(doc, page, a);
        }

        public static Obj markup(Document doc, int page, string subtype, Rect[] lines, double[] color, double opacity, string author, string contents) {
            var a = Obj.dictionary();
            base_fields(a, subtype, color, author, contents);
            var quads = Obj.array();
            var bounds = Rect.empty();
            var ops = new StringBuilder("/GS0 gs\n");
            foreach (var r in lines) {
                foreach (var v in new double[] { r.x1, r.y2, r.x2, r.y2, r.x1, r.y1, r.x2, r.y1 }) quads.add(Obj.number(v));
                bounds.union(r);
                switch (subtype) {
                    case "Highlight":
                        ops.append_printf("%s %s %s %s %s re f\n", col(color, false), f(r.x1), f(r.y1), f(r.width()), f(r.height()));
                        break;
                    case "Underline":
                        ops.append_printf("%s %s w %s %s m %s %s l S\n", col(color, true), f(double.max(0.5, r.height() / 14)), f(r.x1), f(r.y1 + r.height() * 0.07), f(r.x2), f(r.y1 + r.height() * 0.07));
                        break;
                    case "StrikeOut":
                        ops.append_printf("%s %s w %s %s m %s %s l S\n", col(color, true), f(double.max(0.5, r.height() / 14)), f(r.x1), f(r.y1 + r.height() * 0.45), f(r.x2), f(r.y1 + r.height() * 0.45));
                        break;
                    default:
                        ops.append_printf("%s 0.6 w\n", col(color, true));
                        double step = double.max(1.5, r.height() / 8);
                        bool up = true;
                        ops.append_printf("%s %s m\n", f(r.x1), f(r.y1));
                        for (double x = r.x1 + step; x <= r.x2; x += step) {
                            ops.append_printf("%s %s l\n", f(x), f(r.y1 + (up ? step : 0)));
                            up = !up;
                        }
                        ops.append("S\n");
                        break;
                }
            }
            a.set("QuadPoints", quads);
            a.set("Rect", Obj.numbers({ bounds.x1, bounds.y1, bounds.x2, bounds.y2 }));
            if (opacity < 1) a.set("CA", Obj.number(opacity));
            a.set("AP", appearance(doc, bounds, ops.str, opacity_resources(opacity, subtype == "Highlight")));
            return add(doc, page, a);
        }

        public static Obj free_text(Document doc, int page, Rect rect, string text, double size, double[] color, string author) {
            var a = Obj.dictionary();
            base_fields(a, "FreeText", color, author, text);
            a.set("Rect", Obj.numbers({ rect.x1, rect.y1, rect.x2, rect.y2 }));
            a.set("DA", Obj.str("/Helv %s Tf %s".printf(f(size), col(color, false)).data));
            var font = EmbeddedFont.for_pattern(doc, "sans-serif");
            var res = Obj.dictionary();
            var ops = new StringBuilder();
            if (font != null) {
                var fonts = Obj.dictionary();
                fonts.set("F1", font.font_ref);
                res.set("Font", fonts);
                ops.append_printf("BT\n%s\n/F1 %s Tf\n", col(color, false), f(size));
                double y = rect.y2 - size * 1.1;
                foreach (var line in wrap_lines(text, font, size, rect.width() - 4)) {
                    ops.append_printf("1 0 0 1 %s %s Tm %s Tj\n", f(rect.x1 + 2), f(y), font.hex(line));
                    y -= size * 1.2;
                }
                ops.append("ET\n");
            }
            a.set("AP", appearance(doc, rect, ops.str, res));
            return add(doc, page, a);
        }

        public static Gee.ArrayList<string> wrap_lines(string text, EmbeddedFont font, double size, double width) {
            var lines = new Gee.ArrayList<string>();
            foreach (var para in text.split("\n")) {
                var cur = new StringBuilder();
                foreach (var word in para.split(" ")) {
                    string trial = cur.len == 0 ? word : cur.str + " " + word;
                    if (cur.len > 0 && font.measure(trial, size) > width) {
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

        public static Obj stamp(Document doc, int page, Rect rect, string label, double[] color, string author) {
            var a = Obj.dictionary();
            base_fields(a, "Stamp", color, author, label);
            string name = label.replace(" ", "");
            a.set("Name", Obj.name_obj(name != "" ? name : "Draft"));
            a.set("Rect", Obj.numbers({ rect.x1, rect.y1, rect.x2, rect.y2 }));
            var font = EmbeddedFont.for_pattern(doc, "sans-serif:bold");
            var res = opacity_resources(0.85);
            var ops = new StringBuilder("/GS0 gs\n");
            double r = double.min(8, rect.height() / 4);
            ops.append_printf("%s 2.5 w\n", col(color, true));
            ops.append_printf("%s %s m %s %s l %s %s %s %s %s %s c %s %s l %s %s %s %s %s %s c %s %s l %s %s %s %s %s %s c %s %s l %s %s %s %s %s %s c h S\n",
                f(rect.x1 + r + 2), f(rect.y1 + 2), f(rect.x2 - r - 2), f(rect.y1 + 2),
                f(rect.x2 - 2), f(rect.y1 + 2), f(rect.x2 - 2), f(rect.y1 + 2), f(rect.x2 - 2), f(rect.y1 + r + 2),
                f(rect.x2 - 2), f(rect.y2 - r - 2),
                f(rect.x2 - 2), f(rect.y2 - 2), f(rect.x2 - 2), f(rect.y2 - 2), f(rect.x2 - r - 2), f(rect.y2 - 2),
                f(rect.x1 + r + 2), f(rect.y2 - 2),
                f(rect.x1 + 2), f(rect.y2 - 2), f(rect.x1 + 2), f(rect.y2 - 2), f(rect.x1 + 2), f(rect.y2 - r - 2),
                f(rect.x1 + 2), f(rect.y1 + r + 2),
                f(rect.x1 + 2), f(rect.y1 + 2), f(rect.x1 + 2), f(rect.y1 + 2), f(rect.x1 + r + 2), f(rect.y1 + 2));
            if (font != null) {
                var fonts = Obj.dictionary();
                fonts.set("F1", font.font_ref);
                res.set("Font", fonts);
                double size = rect.height() * 0.45;
                double w = font.measure(label.up(), size);
                if (w > rect.width() - 12) {
                    size *= (rect.width() - 12) / w;
                    w = font.measure(label.up(), size);
                }
                ops.append_printf("BT %s /F1 %s Tf 1 0 0 1 %s %s Tm %s Tj ET\n", col(color, false), f(size),
                    f(rect.x1 + (rect.width() - w) / 2), f(rect.y1 + (rect.height() - size * 0.7) / 2), font.hex(label.up()));
            }
            a.set("AP", appearance(doc, rect, ops.str, res));
            return add(doc, page, a);
        }

        public static Obj image_stamp(Document doc, int page, Rect rect, Obj image_ref, string author, string contents = "") {
            var a = Obj.dictionary();
            base_fields(a, "Stamp", { 0, 0, 0 }, author, contents);
            a.remove("C");
            a.set("Name", Obj.name_obj("Signature"));
            a.set("Rect", Obj.numbers({ rect.x1, rect.y1, rect.x2, rect.y2 }));
            var res = Obj.dictionary();
            var xo = Obj.dictionary();
            xo.set("Im0", image_ref);
            res.set("XObject", xo);
            string ops = "q %s 0 0 %s %s %s cm /Im0 Do Q\n".printf(f(rect.width()), f(rect.height()), f(rect.x1), f(rect.y1));
            a.set("AP", appearance(doc, rect, ops, res));
            return add(doc, page, a);
        }

        public static Obj reply(Document doc, int page, Obj parent, string text, string author) {
            var p = doc.resolve(parent);
            var a = Obj.dictionary();
            base_fields(a, "Text", { 1, 0.85, 0.2 }, author, text);
            var rect = p.get("Rect");
            a.set("Rect", rect != null ? rect.clone() : Obj.numbers({ 0, 0, 0, 0 }));
            a.set("IRT", parent);
            a.set("RT", Obj.name_obj("R"));
            a.set("F", Obj.integer(32));
            a.set("Open", Obj.boolean(false));
            return add(doc, page, a);
        }

        public static Obj set_state(Document doc, int page, Obj parent, string state, string author) {
            var p = doc.resolve(parent);
            var a = Obj.dictionary();
            base_fields(a, "Text", { 1, 0.85, 0.2 }, author, "%s set status to %s".printf(author != "" ? author : "Reviewer", state));
            var rect = p.get("Rect");
            a.set("Rect", rect != null ? rect.clone() : Obj.numbers({ 0, 0, 0, 0 }));
            a.set("IRT", parent);
            a.set("F", Obj.integer(32));
            a.set("State", Obj.text(state));
            a.set("StateModel", Obj.text(state == "Marked" || state == "Unmarked" ? "Marked" : "Review"));
            return add(doc, page, a);
        }

        public static string current_state(Gee.List<AnnotInfo> all, AnnotInfo target) {
            string state = "";
            string when = "";
            foreach (var a in all) {
                if (a.reply_to == target.reference.num && a.state != "" && a.state_model == "Review") {
                    if (a.modified >= when) {
                        state = a.state;
                        when = a.modified;
                    }
                }
            }
            return state;
        }

        public static Obj link(Document doc, int page, Rect rect, string? uri, int target_page, double target_top, string? file = null) {
            var a = Obj.dictionary();
            a.set("Subtype", Obj.name_obj("Link"));
            a.set("Rect", Obj.numbers({ rect.x1, rect.y1, rect.x2, rect.y2 }));
            a.set("Border", Obj.numbers({ 0, 0, 0 }));
            set_link_target(doc, a, uri, target_page, target_top, file);
            return add(doc, page, a);
        }

        public static void set_link_target(Document doc, Obj a, string? uri, int target_page, double target_top, string? file) {
            a.remove("Dest");
            a.remove("A");
            if (uri != null && uri != "") {
                var action = Obj.dictionary();
                action.set("S", Obj.name_obj("URI"));
                action.set("URI", Obj.str(uri.data));
                a.set("A", action);
            } else if (file != null && file != "") {
                var action = Obj.dictionary();
                bool pdf = file.down().has_suffix(".pdf");
                action.set("S", Obj.name_obj(pdf ? "GoToR" : "Launch"));
                var spec = Obj.dictionary();
                spec.set("Type", Obj.name_obj("Filespec"));
                spec.set("F", Obj.text(file));
                spec.set("UF", Obj.text(file));
                action.set("F", spec);
                if (pdf) {
                    var d = Obj.array();
                    d.add(Obj.integer(int.max(0, target_page)));
                    d.add(Obj.name_obj("Fit"));
                    action.set("D", d);
                }
                a.set("A", action);
            } else if (target_page >= 0) {
                a.set("Dest", Outline.make_dest(doc, target_page, target_top));
            }
        }

        public static Obj file_attachment(Document doc, int page, double x, double y, string filename, uint8[] data, string author, string description) {
            var a = Obj.dictionary();
            base_fields(a, "FileAttachment", { 0.2, 0.4, 0.8 }, author, description != "" ? description : filename);
            a.set("Rect", Obj.numbers({ x, y - 20, x + 14, y }));
            a.set("Name", Obj.name_obj("PushPin"));
            a.set("FS", Attachments.file_spec(doc, filename, data, description));
            string ops = "0.2 0.4 0.8 rg %s %s m %s %s l %s %s l f\n".printf(f(x + 7), f(y - 20), f(x + 2), f(y - 6), f(x + 12), f(y - 6));
            a.set("AP", appearance(doc, Rect.of(x, y - 20, x + 14, y), ops));
            return add(doc, page, a);
        }

        public static void transform_page_annots(Document doc, int page, Matrix m) {
            var annots = doc.lookup(doc.page(page), "Annots");
            if (!annots.is_array()) return;
            for (int i = 0; i < annots.length; i++) {
                var a = doc.resolve(annots.at(i));
                if (!a.is_dict()) continue;
                foreach (var key in new string[] { "Rect", "QuadPoints", "Vertices", "L" }) {
                    var v = doc.lookup(a, key);
                    if (!v.is_array()) continue;
                    if (key == "Rect" && v.length >= 4) {
                        var r = m.apply_rect(v.at(0).as_number(), v.at(1).as_number(), v.at(2).as_number(), v.at(3).as_number());
                        a.set(key, Obj.numbers({ r.x1, r.y1, r.x2, r.y2 }));
                        continue;
                    }
                    var out_arr = Obj.array();
                    for (int k = 0; k + 1 < v.length; k += 2) {
                        double px, py;
                        m.apply(v.at(k).as_number(), v.at(k + 1).as_number(), out px, out py);
                        out_arr.add(Obj.number(px));
                        out_arr.add(Obj.number(py));
                    }
                    a.set(key, out_arr);
                }
                var ap = doc.lookup(a, "AP");
                if (ap.is_dict()) {
                    var n = doc.resolve(ap.get("N"));
                    if (n.is_stream()) {
                        var bbox = doc.lookup(n, "BBox");
                        if (bbox.is_array() && bbox.length >= 4 && !n.has("Matrix")) n.set("Matrix", Obj.numbers({ m.a, m.b, m.c, m.d, m.e, m.f }));
                    }
                }
            }
        }

        private static string xml_escape(string s) {
            return Markup.escape_text(s);
        }

        private static string xfdf_rect(Rect r) {
            return "%s,%s,%s,%s".printf(f(r.x1), f(r.y1), f(r.x2), f(r.y2));
        }

        private static string xfdf_color(double[]? c) {
            if (c == null) return "";
            return "#%02X%02X%02X".printf((int) (c[0] * 255), (int) (c[1] * 255), (int) (c[2] * 255));
        }

        public static string export_xfdf(Document doc, string pdf_name) {
            var s = new StringBuilder();
            s.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xfdf xmlns=\"http://ns.adobe.com/xfdf/\" xml:space=\"preserve\">\n");
            s.append_printf("  <f href=\"%s\"/>\n  <annots>\n", xml_escape(pdf_name));
            var all = list(doc);
            var names = new Gee.HashMap<int, string>();
            foreach (var a in all) names[a.reference.num] = a.name != "" ? a.name : "annot-%d".printf(a.reference.num);
            foreach (var a in all) {
                if (a.subtype == "Popup" || a.subtype == "Link" || a.subtype == "Widget" || !(a.subtype in MARKUP_TYPES)) continue;
                string tag = a.subtype.down();
                if (tag == "strikeout") tag = "strikeout";
                s.append_printf("    <%s page=\"%d\" rect=\"%s\" name=\"%s\" flags=\"%d\"", tag, a.page, xfdf_rect(a.rect), xml_escape(names[a.reference.num]), a.flags);
                if (a.color != null) s.append_printf(" color=\"%s\"", xfdf_color(a.color));
                if (a.author != "") s.append_printf(" title=\"%s\"", xml_escape(a.author));
                if (a.subject != "") s.append_printf(" subject=\"%s\"", xml_escape(a.subject));
                if (a.modified != "") s.append_printf(" date=\"%s\"", xml_escape(a.modified));
                if (a.reply_to >= 0 && names.has_key(a.reply_to)) s.append_printf(" inreplyto=\"%s\"", xml_escape(names[a.reply_to]));
                if (a.state != "") s.append_printf(" state=\"%s\" statemodel=\"%s\"", xml_escape(a.state), xml_escape(a.state_model));
                var ca = doc.lookup(a.dict, "CA");
                if (ca.is_number()) s.append_printf(" opacity=\"%s\"", f(ca.as_number()));
                var quads = doc.lookup(a.dict, "QuadPoints");
                if (quads.is_array()) {
                    var c = new StringBuilder();
                    for (int i = 0; i < quads.length; i++) {
                        if (i > 0) c.append_c(',');
                        c.append(f(quads.at(i).as_number()));
                    }
                    s.append_printf(" coords=\"%s\"", c.str);
                }
                var l = doc.lookup(a.dict, "L");
                if (l.is_array() && l.length >= 4) s.append_printf(" start=\"%s,%s\" end=\"%s,%s\"", f(l.at(0).as_number()), f(l.at(1).as_number()), f(l.at(2).as_number()), f(l.at(3).as_number()));
                var ic = doc.lookup(a.dict, "IC");
                if (ic.is_array() && ic.length == 3) s.append_printf(" interior-color=\"%s\"", xfdf_color({ ic.at(0).as_number(), ic.at(1).as_number(), ic.at(2).as_number() }));
                var bs = doc.lookup(a.dict, "BS");
                if (bs.is_dict()) s.append_printf(" width=\"%s\"", f(doc.lookup(bs, "W").as_number(1)));
                var icon = doc.lookup(a.dict, "Name");
                if (icon.is_name()) s.append_printf(" icon=\"%s\"", xml_escape(icon.name));
                s.append(">");
                if (a.contents != "") s.append_printf("<contents>%s</contents>", xml_escape(a.contents));
                var vertices = doc.lookup(a.dict, "Vertices");
                if (vertices.is_array()) {
                    var c = new StringBuilder();
                    for (int i = 0; i + 1 < vertices.length; i += 2) {
                        if (i > 0) c.append_c(';');
                        c.append_printf("%s,%s", f(vertices.at(i).as_number()), f(vertices.at(i + 1).as_number()));
                    }
                    s.append_printf("<vertices>%s</vertices>", c.str);
                }
                var inklist = doc.lookup(a.dict, "InkList");
                if (inklist.is_array()) {
                    s.append("<inklist>");
                    for (int k = 0; k < inklist.length; k++) {
                        var stroke = doc.resolve(inklist.at(k));
                        var c = new StringBuilder();
                        for (int i = 0; i + 1 < stroke.length; i += 2) {
                            if (i > 0) c.append_c(';');
                            c.append_printf("%s,%s", f(stroke.at(i).as_number()), f(stroke.at(i + 1).as_number()));
                        }
                        s.append_printf("<gesture>%s</gesture>", c.str);
                    }
                    s.append("</inklist>");
                }
                s.append_printf("</%s>\n", tag);
            }
            s.append("  </annots>\n");
            string fields = Forms.xfdf_fields(doc);
            if (fields != "") s.append(fields);
            s.append("</xfdf>\n");
            return s.str;
        }

        private static double[] parse_numbers(string s) {
            double[] r = {};
            foreach (var part in s.replace(";", ",").split(",")) {
                string t = part.strip();
                if (t != "") r += double.parse(t);
            }
            return r;
        }

        private static double[]? parse_color(string? s) {
            if (s == null || !s.has_prefix("#") || s.length != 7) return null;
            return rgb(s);
        }

        public static int import_xfdf(Document doc, string xml) throws Error {
            var parser = new XfdfReader();
            parser.parse(xml);
            int count = 0;
            var by_name = new Gee.HashMap<string, Obj>();
            foreach (var a in list(doc)) if (a.name != "") by_name[a.name] = a.reference;
            foreach (var node in parser.annots) {
                int page = int.parse(node.attrs["page"] ?? "0");
                if (page < 0 || page >= doc.page_count()) continue;
                string name = node.attrs["name"] ?? "";
                if (name != "" && by_name.has_key(name)) continue;
                var r = parse_numbers(node.attrs["rect"] ?? "0,0,0,0");
                if (r.length < 4) continue;
                var rect = Rect.of(r[0], r[1], r[2], r[3]);
                var color = parse_color(node.attrs["color"]) ?? new double[] { 1, 0.8, 0 };
                string author = node.attrs["title"] ?? "";
                string contents = node.contents;
                Obj? created = null;
                string tag = node.tag;
                switch (tag) {
                    case "highlight":
                    case "underline":
                    case "strikeout":
                    case "squiggly":
                        var coords = parse_numbers(node.attrs["coords"] ?? "");
                        Rect[] lines = {};
                        for (int i = 0; i + 7 < coords.length; i += 8) {
                            var q = Rect.empty();
                            for (int k = 0; k < 8; k += 2) q.add(coords[i + k], coords[i + k + 1]);
                            lines += q;
                        }
                        if (lines.length == 0) lines += rect;
                        string subtype = tag == "highlight" ? "Highlight" : (tag == "underline" ? "Underline" : (tag == "strikeout" ? "StrikeOut" : "Squiggly"));
                        created = markup(doc, page, subtype, lines, color, double.parse(node.attrs["opacity"] ?? "1"), author, contents);
                        break;
                    case "square":
                    case "circle":
                        created = shape(doc, page, tag == "square" ? ShapeKind.RECTANGLE : ShapeKind.ELLIPSE,
                            { rect.x1 + 1, rect.y1 + 1, rect.x2 - 1, rect.y2 - 1 }, color, parse_color(node.attrs["interior-color"]),
                            double.parse(node.attrs["width"] ?? "1"), double.parse(node.attrs["opacity"] ?? "1"), author, contents);
                        break;
                    case "line":
                        var st = parse_numbers(node.attrs["start"] ?? "");
                        var en = parse_numbers(node.attrs["end"] ?? "");
                        if (st.length >= 2 && en.length >= 2) {
                            created = shape(doc, page, ShapeKind.LINE, { st[0], st[1], en[0], en[1] }, color, null,
                                double.parse(node.attrs["width"] ?? "1"), 1, author, contents);
                        }
                        break;
                    case "polygon":
                    case "polyline":
                        var v = parse_numbers(node.children.has_key("vertices") ? node.children["vertices"] : "");
                        if (v.length >= 4) created = shape(doc, page, tag == "polygon" ? ShapeKind.POLYGON : ShapeKind.POLYLINE, v, color, null,
                            double.parse(node.attrs["width"] ?? "1"), 1, author, contents);
                        break;
                    case "ink":
                        var strokes = new Gee.ArrayList<Points>();
                        foreach (var g in node.gestures) strokes.add(new Points(parse_numbers(g)));
                        if (strokes.size > 0) created = ink(doc, page, strokes, color, double.parse(node.attrs["width"] ?? "1"), double.parse(node.attrs["opacity"] ?? "1"), author);
                        break;
                    case "text":
                        if (node.attrs.has_key("inreplyto") && by_name.has_key(node.attrs["inreplyto"])) {
                            var parent = by_name[node.attrs["inreplyto"]];
                            if (node.attrs.has_key("state")) created = set_state(doc, page, parent, node.attrs["state"], author);
                            else created = reply(doc, page, parent, contents, author);
                        } else {
                            created = note(doc, page, rect.x1, rect.y2, contents, color, author);
                        }
                        break;
                    case "freetext":
                        created = free_text(doc, page, rect, contents, 12, color, author);
                        break;
                    case "stamp":
                        created = stamp(doc, page, rect, node.attrs["icon"] ?? contents, color, author);
                        break;
                    default:
                        break;
                }
                if (created != null) {
                    var obj = doc.resolve(created);
                    if (name != "") {
                        obj.set("NM", Obj.text(name));
                        by_name[name] = created;
                    }
                    if (node.attrs.has_key("date")) obj.set("M", Obj.text(node.attrs["date"]));
                    if (node.attrs.has_key("subject")) obj.set("Subj", Obj.text(node.attrs["subject"]));
                    count++;
                }
            }
            count += Forms.import_values(doc, parser.fields);
            return count;
        }

        public static uint8[] export_fdf(Document doc, string pdf_name) {
            var b = new ByteArray();
            Obj.append(b, "%FDF-1.2\n");
            b.append({ '%', 0xe2, 0xe3, 0xcf, 0xd3, '\n' });
            var annots = Obj.array();
            var objects = new Gee.ArrayList<Obj>();
            var all = list(doc);
            var map = new Gee.HashMap<int, int>();
            int next = 2;
            foreach (var a in all) {
                if (!(a.subtype in MARKUP_TYPES)) continue;
                map[a.reference.num] = next++;
            }
            foreach (var a in all) {
                if (!(a.subtype in MARKUP_TYPES)) continue;
                var copy = Obj.dictionary();
                foreach (var k in a.dict.dict.keys) {
                    if (k == "P" || k == "AP" || k == "Popup" || k == "Parent") continue;
                    var v = a.dict.get(k);
                    if (k == "IRT" && v.is_ref() && map.has_key(v.num)) {
                        copy.set(k, Obj.reference(map[v.num]));
                        continue;
                    }
                    copy.set(k, strip_refs(doc, v));
                }
                copy.set("Page", Obj.integer(a.page));
                objects.add(copy);
                annots.add(Obj.reference(map[a.reference.num]));
            }
            var fdf = Obj.dictionary();
            fdf.set("F", Obj.text(pdf_name));
            if (annots.length > 0) fdf.set("Annots", annots);
            var fields = Forms.fdf_fields(doc);
            if (fields.length > 0) fdf.set("Fields", fields);
            var root = Obj.dictionary();
            root.set("FDF", fdf);
            Obj.append(b, "1 0 obj\n");
            root.write(b);
            Obj.append(b, "\nendobj\n");
            for (int i = 0; i < objects.size; i++) {
                Obj.append(b, "%d 0 obj\n".printf(i + 2));
                objects[i].write(b);
                Obj.append(b, "\nendobj\n");
            }
            Obj.append(b, "trailer\n<</Root 1 0 R>>\n%%EOF\n");
            return b.steal();
        }

        private static Obj strip_refs(Document doc, Obj v) {
            switch (v.kind) {
                case ObjKind.REF:
                    var r = doc.resolve(v);
                    return r.is_stream() ? Obj.none() : strip_refs(doc, r);
                case ObjKind.ARRAY:
                    var a = Obj.array();
                    foreach (var i in v.items) a.add(strip_refs(doc, i));
                    return a;
                case ObjKind.DICT:
                    var d = Obj.dictionary();
                    foreach (var k in v.dict.keys) d.set(k, strip_refs(doc, v.dict.get(k)));
                    return d;
                default:
                    return v.clone();
            }
        }

        public static int import_fdf(Document doc, uint8[] data) throws Error {
            var fdf = Document.open_bytes(data);
            var root = fdf.lookup(fdf.catalog(), "FDF");
            if (!root.is_dict()) {
                root = fdf.lookup(fdf.trailer.get("Root"), "FDF");
            }
            int count = 0;
            var annots = fdf.lookup(root, "Annots");
            var created = new Gee.HashMap<int, Obj>();
            if (annots.is_array()) {
                for (int i = 0; i < annots.length; i++) {
                    var r = annots.at(i);
                    var a = fdf.resolve(r);
                    if (!a.is_dict()) continue;
                    int page = fdf.lookup(a, "Page").as_int(0);
                    if (page < 0 || page >= doc.page_count()) continue;
                    var copy = Obj.dictionary();
                    foreach (var k in a.dict.keys) {
                        if (k == "Page" || k == "IRT") continue;
                        copy.set(k, strip_refs(fdf, a.dict.get(k)));
                    }
                    var irt = a.get("IRT");
                    if (irt != null && irt.is_ref() && created.has_key(irt.num)) copy.set("IRT", created[irt.num]);
                    regenerate_appearance(doc, copy);
                    var nr = add(doc, page, copy);
                    if (r.is_ref()) created[r.num] = nr;
                    count++;
                }
            }
            var fields = fdf.lookup(root, "Fields");
            if (fields.is_array()) {
                var values = new Gee.HashMap<string, string>();
                collect_fdf_fields(fdf, fields, "", values);
                count += Forms.import_values(doc, values);
            }
            return count;
        }

        private static void collect_fdf_fields(Document fdf, Obj fields, string prefix, Gee.HashMap<string, string> values) {
            for (int i = 0; i < fields.length; i++) {
                var fld = fdf.resolve(fields.at(i));
                string name = fdf.lookup(fld, "T").text_value();
                string full = prefix == "" ? name : prefix + "." + name;
                var kids = fdf.lookup(fld, "Kids");
                if (kids.is_array()) collect_fdf_fields(fdf, kids, full, values);
                var v = fdf.lookup(fld, "V");
                if (!v.is_none()) values[full] = v.is_name() ? v.name : v.text_value();
            }
        }

        public static void regenerate_appearance(Document doc, Obj a) {
            var st = doc.lookup(a, "Subtype");
            if (!st.is_name()) return;
            var c = doc.lookup(a, "C");
            double[] color = c.is_array() && c.length == 3 ? new double[] { c.at(0).as_number(), c.at(1).as_number(), c.at(2).as_number() } : new double[] { 1, 0.8, 0 };
            var rect = doc.lookup(a, "Rect");
            if (!rect.is_array() || rect.length < 4) return;
            var r = Rect.of(rect.at(0).as_number(), rect.at(1).as_number(), rect.at(2).as_number(), rect.at(3).as_number());
            var ops = new StringBuilder();
            switch (st.name) {
                case "Highlight":
                case "Underline":
                case "StrikeOut":
                case "Squiggly":
                    var q = doc.lookup(a, "QuadPoints");
                    for (int i = 0; i + 7 < q.length; i += 8) {
                        var line = Rect.empty();
                        for (int k = 0; k < 8; k += 2) line.add(q.at(i + k).as_number(), q.at(i + k + 1).as_number());
                        if (st.name == "Highlight") ops.append_printf("%s %s %s %s %s re f\n", col(color, false), f(line.x1), f(line.y1), f(line.width()), f(line.height()));
                        else {
                            double y = st.name == "StrikeOut" ? line.y1 + line.height() * 0.45 : line.y1 + 1;
                            ops.append_printf("%s 1 w %s %s m %s %s l S\n", col(color, true), f(line.x1), f(y), f(line.x2), f(y));
                        }
                    }
                    a.set("AP", appearance(doc, r, ops.str, opacity_resources(doc.lookup(a, "CA").as_number(1), st.name == "Highlight")));
                    break;
                case "Square":
                    ops.append_printf("/GS0 gs %s 1 w %s %s %s %s re S\n", col(color, true), f(r.x1 + 1), f(r.y1 + 1), f(r.width() - 2), f(r.height() - 2));
                    a.set("AP", appearance(doc, r, ops.str, opacity_resources(doc.lookup(a, "CA").as_number(1))));
                    break;
                case "Circle":
                    ops.append_printf("/GS0 gs %s 1 w %s S\n", col(color, true), ellipse_path(Rect.of(r.x1 + 1, r.y1 + 1, r.x2 - 1, r.y2 - 1)));
                    a.set("AP", appearance(doc, r, ops.str, opacity_resources(doc.lookup(a, "CA").as_number(1))));
                    break;
                case "Ink":
                    var list = doc.lookup(a, "InkList");
                    ops.append_printf("/GS0 gs %s 1.5 w 1 J 1 j\n", col(color, true));
                    for (int k = 0; k < list.length; k++) {
                        var s = doc.resolve(list.at(k));
                        for (int i = 0; i + 1 < s.length; i += 2) ops.append_printf("%s %s %s\n", f(s.at(i).as_number()), f(s.at(i + 1).as_number()), i == 0 ? "m" : "l");
                        ops.append("S\n");
                    }
                    a.set("AP", appearance(doc, r, ops.str, opacity_resources(doc.lookup(a, "CA").as_number(1))));
                    break;
                case "Text":
                    ops.append_printf("%s 0 0 0 RG 0.6 w %s %s 18 14 re B\n", col(color, false), f(r.x1 + 1), f(r.y2 - 15));
                    a.set("AP", appearance(doc, Rect.of(r.x1, r.y2 - 20, r.x1 + 20, r.y2), ops.str));
                    break;
                default:
                    break;
            }
        }
    }

    public class XfdfNode {
        public string tag;
        public Gee.HashMap<string, string> attrs = new Gee.HashMap<string, string>();
        public string contents = "";
        public Gee.HashMap<string, string> children = new Gee.HashMap<string, string>();
        public Gee.ArrayList<string> gestures = new Gee.ArrayList<string>();
    }

    public class XfdfReader {
        public Gee.ArrayList<XfdfNode> annots = new Gee.ArrayList<XfdfNode>();
        public Gee.HashMap<string, string> fields = new Gee.HashMap<string, string>();
        private XfdfNode? current = null;
        private Gee.ArrayList<string> path = new Gee.ArrayList<string>();
        private Gee.ArrayList<string> field_names = new Gee.ArrayList<string>();
        private StringBuilder text = new StringBuilder();
        private bool in_annots = false;

        public void parse(string xml) throws Error {
            var parser = MarkupParser() {
                start_element = on_start,
                end_element = on_end,
                text = on_text
            };
            var ctx = new MarkupParseContext(parser, 0, this, null);
            ctx.parse(xml, -1);
            ctx.end_parse();
        }

        private void on_start(MarkupParseContext ctx, string name, string[] names, string[] values) throws MarkupError {
            string tag = name.contains(":") ? name.substring(name.index_of_char(':') + 1) : name;
            path.add(tag);
            text.truncate();
            if (tag == "annots") {
                in_annots = true;
                return;
            }
            if (tag == "field") {
                string fname = "";
                for (int i = 0; i < names.length; i++) if (names[i] == "name") fname = values[i];
                field_names.add(fname);
                return;
            }
            if (in_annots && current == null) {
                current = new XfdfNode();
                current.tag = tag.down();
                for (int i = 0; i < names.length; i++) current.attrs[names[i]] = values[i];
            }
        }

        private void on_end(MarkupParseContext ctx, string name) throws MarkupError {
            string tag = name.contains(":") ? name.substring(name.index_of_char(':') + 1) : name;
            if (path.size > 0) path.remove_at(path.size - 1);
            if (tag == "annots") {
                in_annots = false;
                return;
            }
            if (tag == "field") {
                if (field_names.size > 0) field_names.remove_at(field_names.size - 1);
                return;
            }
            if (tag == "value" && field_names.size > 0) {
                fields[string.joinv(".", field_names.to_array())] = text.str;
                return;
            }
            if (current == null) return;
            if (tag == "contents" || tag == "contents-richtext") {
                if (current.contents == "") current.contents = text.str;
            } else if (tag == "gesture") {
                current.gestures.add(text.str);
            } else if (tag == current.tag) {
                annots.add(current);
                current = null;
            } else {
                current.children[tag] = text.str;
            }
            text.truncate();
        }

        private void on_text(MarkupParseContext ctx, string t, size_t len) throws MarkupError {
            text.append_len(t, (ssize_t) len);
        }
    }
}
