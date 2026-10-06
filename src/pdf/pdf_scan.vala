namespace Singularity.Pdf {

    public class OcrWord {
        public string text;
        public Rect box;

        public OcrWord(string text, Rect box) {
            this.text = text;
            this.box = box;
        }
    }

    public class ScanOptions {
        public bool deskew = true;
        public bool whiten = true;
        public bool remove_borders = true;
        public int jpeg_quality = 85;
    }

    public class Scans {
        private static string f(double v) {
            return Obj.format_number(Math.round(v * 1000) / 1000);
        }

        public static ImageInfo? main_image(Document doc, int page) {
            var box = doc.page_box(page, "CropBox");
            double area = (box[2] - box[0]) * (box[3] - box[1]);
            ImageInfo? best = null;
            double best_area = 0;
            foreach (var info in Images.list(doc, page)) {
                double a = info.item.box.width() * info.item.box.height();
                if (a > best_area) {
                    best_area = a;
                    best = info;
                }
            }
            if (best == null || best_area < area * 0.6) return null;
            return best;
        }

        public static bool is_scanned(Document doc, int page) {
            if (main_image(doc, page) == null) return false;
            var it = new Interpreter(doc);
            it.run_page(page);
            int visible = 0;
            foreach (var item in it.items) {
                if (item.kind == ItemKind.TEXT && item.render_mode != 3) visible += item.text().strip().char_count();
            }
            return visible < 20;
        }

        public static bool has_text_layer(Document doc, int page) {
            var it = new Interpreter(doc);
            it.run_page(page);
            foreach (var item in it.items) {
                if (item.kind == ItemKind.TEXT && item.text().strip() != "") return true;
            }
            return false;
        }

        public static int add_text_layer(Document doc, int page, Gee.List<OcrWord> words) {
            if (words.size == 0) return 0;
            var font = EmbeddedFont.for_pattern(doc, "sans-serif");
            if (font == null) return 0;
            var res = doc.page_resources(page);
            var fonts = doc.sub_dict(res, "Font");
            string name = Editor.unique_resource(fonts, "OCR");
            fonts.set(name, font.font_ref);
            var ops = new StringBuilder("q\nBT\n3 Tr\n");
            int count = 0;
            foreach (var w in words) {
                string t = w.text.strip();
                if (t == "" || w.box.width() <= 0 || w.box.height() <= 0) continue;
                double size = w.box.height() * 0.9;
                double natural = font.measure(t + " ", size);
                double scale = natural > 0 ? w.box.width() / natural * 100 : 100;
                ops.append_printf("/%s %s Tf %s Tz 1 0 0 1 %s %s Tm %s Tj\n", name, f(size), f(scale.clamp(10, 1000)), f(w.box.x1),
                    f(w.box.y1 + w.box.height() * 0.2), font.hex(t + " "));
                count++;
            }
            ops.append("ET\nQ\n");
            doc.append_page_content(page, ops.str.data);
            return count;
        }

        private static uint8[] grayscale(Gdk.Pixbuf pb, out int w, out int h) {
            w = pb.width;
            h = pb.height;
            var g = new uint8[w * h];
            unowned uint8[] px = pb.get_pixels_with_length();
            int n = pb.n_channels, stride = pb.rowstride;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int o = y * stride + x * n;
                    g[y * w + x] = (uint8) ((px[o] * 30 + px[o + 1] * 59 + px[o + 2] * 11) / 100);
                }
            }
            return g;
        }

        public static double skew_angle(Gdk.Pixbuf source) {
            double factor = double.min(1.0, 900.0 / source.width);
            var pb = factor < 1 ? source.scale_simple(int.max(1, (int) (source.width * factor)), int.max(1, (int) (source.height * factor)), Gdk.InterpType.BILINEAR) : source;
            int w, h;
            var g = grayscale(pb, out w, out h);
            var xs = new Gee.ArrayList<int>();
            var ys = new Gee.ArrayList<int>();
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    if (g[y * w + x] < 110) {
                        xs.add(x);
                        ys.add(y);
                    }
                }
            }
            if (xs.size < 50) return 0;
            double best = 0, best_score = -1;
            for (int pass = 0; pass < 2; pass++) {
                double lo = pass == 0 ? -6 : best - 0.3, hi = pass == 0 ? 6 : best + 0.3, step = pass == 0 ? 0.25 : 0.05;
                for (double a = lo; a <= hi + 1e-9; a += step) {
                    double r = a * Math.PI / 180;
                    double s = Math.sin(r), c = Math.cos(r);
                    int bins = h * 2 + w;
                    var hist = new int[bins];
                    for (int i = 0; i < xs.size; i++) {
                        int yy = (int) (ys[i] * c - xs[i] * s) + w;
                        if (yy >= 0 && yy < bins) hist[yy]++;
                    }
                    double score = 0;
                    foreach (int v in hist) score += (double) v * v;
                    if (score > best_score) {
                        best_score = score;
                        best = a;
                    }
                }
            }
            return best.abs() < 0.1 ? 0 : best;
        }

        public static Gdk.Pixbuf rotate(Gdk.Pixbuf pb, double degrees) {
            int w = pb.width, h = pb.height;
            var result = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, w, h);
            result.fill((uint32) 0xffffffffU);
            unowned uint8[] src = pb.get_pixels_with_length();
            unowned uint8[] dst = result.get_pixels_with_length();
            int sn = pb.n_channels, ss = pb.rowstride, ds = result.rowstride;
            double r = degrees * Math.PI / 180;
            double s = Math.sin(r), c = Math.cos(r);
            double cx = w / 2.0, cy = h / 2.0;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    double dx = x - cx, dy = y - cy;
                    double sx = dx * c - dy * s + cx, sy = dx * s + dy * c + cy;
                    int ix = (int) Math.floor(sx), iy = (int) Math.floor(sy);
                    if (ix < 0 || iy < 0 || ix + 1 >= w || iy + 1 >= h) continue;
                    double fx = sx - ix, fy = sy - iy;
                    for (int k = 0; k < 3; k++) {
                        double v = src[iy * ss + ix * sn + k] * (1 - fx) * (1 - fy) + src[iy * ss + (ix + 1) * sn + k] * fx * (1 - fy)
                            + src[(iy + 1) * ss + ix * sn + k] * (1 - fx) * fy + src[(iy + 1) * ss + (ix + 1) * sn + k] * fx * fy;
                        dst[y * ds + x * 3 + k] = (uint8) v.clamp(0, 255);
                    }
                }
            }
            return result;
        }

        public static void whiten(Gdk.Pixbuf pb) {
            int w, h;
            var g = grayscale(pb, out w, out h);
            var hist = new int[256];
            foreach (uint8 v in g) hist[v]++;
            int total = w * h, acc = 0, paper = 255;
            for (int v = 255; v >= 0; v--) {
                acc += hist[v];
                if (acc > total * 0.5) {
                    paper = v;
                    break;
                }
            }
            double white = double.max(120, paper - 10);
            unowned uint8[] px = pb.get_pixels_with_length();
            int n = pb.n_channels, stride = pb.rowstride;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int o = y * stride + x * n;
                    for (int k = 0; k < 3; k++) {
                        double v = px[o + k] * 255.0 / white;
                        px[o + k] = (uint8) v.clamp(0, 255);
                    }
                }
            }
        }

        public static void remove_borders(Gdk.Pixbuf pb) {
            int w, h;
            var g = grayscale(pb, out w, out h);
            unowned uint8[] px = pb.get_pixels_with_length();
            int n = pb.n_channels, stride = pb.rowstride;
            int top = 0, bottom = h - 1, left = 0, right = w - 1;
            while (top < h / 4 && dark_ratio_row(g, w, top) > 0.5) top++;
            while (bottom > h * 3 / 4 && dark_ratio_row(g, w, bottom) > 0.5) bottom--;
            while (left < w / 4 && dark_ratio_col(g, w, h, left) > 0.5) left++;
            while (right > w * 3 / 4 && dark_ratio_col(g, w, h, right) > 0.5) right--;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    if (y >= top && y <= bottom && x >= left && x <= right) continue;
                    int o = y * stride + x * n;
                    px[o] = 255;
                    px[o + 1] = 255;
                    px[o + 2] = 255;
                }
            }
        }

        private static double dark_ratio_row(uint8[] g, int w, int y) {
            int d = 0;
            for (int x = 0; x < w; x++) if (g[y * w + x] < 90) d++;
            return (double) d / w;
        }

        private static double dark_ratio_col(uint8[] g, int w, int h, int x) {
            int d = 0;
            for (int y = 0; y < h; y++) if (g[y * w + x] < 90) d++;
            return (double) d / h;
        }

        public static double clean_page(Document doc, int page, ScanOptions opts) throws Error {
            var info = main_image(doc, page);
            if (info == null || info.xobject == null) return 0;
            var x = doc.resolve(info.xobject);
            var pb = Images.decode(doc, x);
            if (pb == null) throw new PdfError.UNSUPPORTED("the scanned image cannot be decoded");
            var work = pb.copy();
            if (work.has_alpha) work = work.add_alpha(false, 0, 0, 0);
            double angle = 0;
            if (opts.deskew) {
                angle = skew_angle(work);
                if (angle != 0) work = rotate(work, angle);
            }
            if (opts.remove_borders) remove_borders(work);
            if (opts.whiten) whiten(work);
            var fresh = Images.pixbuf_xobject(doc, work, opts.jpeg_quality);
            Editor.replace_image(doc, page, info, fresh);
            return angle;
        }

        public static Document from_images(string[] paths, double page_width = 0, double page_height = 0) throws Error {
            var doc = new Document();
            foreach (var path in paths) {
                int w, h;
                var img = Images.from_file(doc, path, out w, out h);
                double pw = page_width, ph = page_height;
                double iw = w * 72.0 / 150, ih = h * 72.0 / 150;
                if (pw <= 0 || ph <= 0) {
                    pw = iw;
                    ph = ih;
                    if (pw > 842 || ph > 842) {
                        double s = double.min(842 / pw, 842 / ph);
                        pw *= s;
                        ph *= s;
                    }
                }
                if (page_width > 0 && (w > h) != (page_width > page_height)) {
                    double t = pw;
                    pw = ph;
                    ph = t;
                }
                int index = Pages.insert_blank(doc, doc.page_count(), pw, ph);
                double s = double.min(pw / double.max(1, w), ph / double.max(1, h));
                double dw = w * s, dh = h * s;
                Editor.add_image(doc, index, img, Rect.of((pw - dw) / 2, (ph - dh) / 2, (pw + dw) / 2, (ph + dh) / 2));
            }
            return doc;
        }
    }
}
