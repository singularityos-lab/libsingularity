namespace Singularity.Print {

    /**
     * Draws imposed sheet sides and writes them out as PDF or PNG. The
     * preview and the printed output share this code, so what the
     * dialog shows is what the printer receives.
     */
    public class SheetRenderer : Object {
        public PageSource source { get; construct; }
        public JobOptions options { get; set; }
        public int total_pages { get; set; }
        public DateTime when { get; set; default = new DateTime.now_local(); }

        public SheetRenderer(PageSource source, JobOptions options) {
            Object(source: source, options: options);
        }

        public void draw_side(Cairo.Context cr, SheetSide side, bool preview) {
            if (preview) {
                cr.set_source_rgb(1, 1, 1);
                cr.rectangle(0, 0, side.width, side.height);
                cr.fill();
            }
            if (options.grayscale) cr.push_group();
            foreach (var p in side.placements) {
                if (p.page < 0) continue;
                cr.save();
                cr.translate(p.x, p.y);
                if (p.rotated) {
                    cr.translate(p.width, 0);
                    cr.rotate(Math.PI / 2);
                }
                cr.scale(p.scale, p.scale);
                cr.rectangle(0, 0, source.page_width, source.page_height);
                cr.clip();
                source.render_page(cr, p.page);
                draw_page_decorations(cr, p.page);
                cr.restore();
                if (options.borders) {
                    cr.save();
                    cr.set_source_rgb(0.25, 0.25, 0.25);
                    cr.set_line_width(0.6);
                    cr.rectangle(p.x, p.y, p.width, p.height);
                    cr.stroke();
                    cr.restore();
                }
            }
            if (preview && options.booklet) {
                cr.save();
                cr.set_source_rgba(0.4, 0.45, 0.55, 0.45);
                cr.set_line_width(0.8);
                cr.set_dash({4, 4}, 0);
                cr.move_to(side.width / 2, 0);
                cr.line_to(side.width / 2, side.height);
                cr.stroke();
                cr.restore();
            }
            if (options.watermark.strip() != "") draw_watermark(cr, side);
            if (options.grayscale) {
                cr.pop_group_to_source();
                cr.paint();
                cr.save();
                cr.rectangle(0, 0, side.width, side.height);
                cr.clip();
                cr.set_operator(Cairo.Operator.HSL_SATURATION);
                cr.set_source_rgb(0.5, 0.5, 0.5);
                cr.paint();
                cr.restore();
            }
        }

        private void draw_page_decorations(Cairo.Context cr, int page) {
            if (options.header == "" && options.footer == "") return;
            double w = source.page_width;
            double h = source.page_height;
            var layout = Pango.cairo_create_layout(cr);
            var font = Pango.FontDescription.from_string("Sans 8");
            layout.set_font_description(font);
            layout.set_width((int) ((w - 72) * Pango.SCALE));
            layout.set_alignment(Pango.Alignment.CENTER);
            layout.set_ellipsize(Pango.EllipsizeMode.MIDDLE);
            cr.set_source_rgb(0.3, 0.3, 0.3);
            if (options.header != "") {
                layout.set_text(Options.expand_template(options.header, source.title, page + 1, total_pages, when), -1);
                cr.move_to(36, 14);
                Pango.cairo_show_layout(cr, layout);
            }
            if (options.footer != "") {
                layout.set_text(Options.expand_template(options.footer, source.title, page + 1, total_pages, when), -1);
                int lw, lh;
                layout.get_pixel_size(out lw, out lh);
                cr.move_to(36, h - 14 - lh);
                Pango.cairo_show_layout(cr, layout);
            }
        }

        private void draw_watermark(Cairo.Context cr, SheetSide side) {
            cr.save();
            var layout = Pango.cairo_create_layout(cr);
            var font = Pango.FontDescription.from_string("Sans Bold");
            double diag = Math.sqrt(side.width * side.width + side.height * side.height);
            font.set_absolute_size(diag / double.max(options.watermark.char_count(), 4) * 1.1 * Pango.SCALE);
            layout.set_font_description(font);
            layout.set_text(options.watermark.strip(), -1);
            int lw, lh;
            layout.get_pixel_size(out lw, out lh);
            cr.translate(side.width / 2, side.height / 2);
            cr.rotate(-Math.atan2(side.height, side.width));
            double fit = double.min(1.0, diag * 0.8 / double.max(lw, 1));
            cr.scale(fit, fit);
            cr.move_to(-lw / 2.0, -lh / 2.0);
            cr.set_source_rgba(0.45, 0.45, 0.45, options.watermark_opacity.clamp(5, 100) / 100.0);
            Pango.cairo_show_layout(cr, layout);
            cr.restore();
        }

        public void write_pdf(string path, Gee.List<SheetSide> sides) throws Error {
            if (sides.size == 0) throw new PrintError.INVALID(_("Nothing to print"));
            var surface = new Cairo.PdfSurface(path, sides[0].width, sides[0].height);
            surface.set_metadata(Cairo.PdfMetadata.TITLE, source.title);
            surface.set_metadata(Cairo.PdfMetadata.CREATOR, "Singularity");
            var cr = new Cairo.Context(surface);
            foreach (var side in sides) {
                surface.set_size(side.width, side.height);
                draw_side(cr, side, false);
                cr.show_page();
            }
            surface.finish();
            if (surface.status() != Cairo.Status.SUCCESS)
                throw new PrintError.FAILED(_("Cannot write %s").printf(path));
        }

        public string[] write_png(string path, Gee.List<SheetSide> sides, double dpi = 200) throws Error {
            string[] files = {};
            string base_path = path.has_suffix(".png") ? path.substring(0, path.length - 4) : path;
            for (int i = 0; i < sides.size; i++) {
                var side = sides[i];
                double k = dpi / 72.0;
                var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, (int) Math.ceil(side.width * k),
                                                     (int) Math.ceil(side.height * k));
                var cr = new Cairo.Context(surface);
                cr.set_source_rgb(1, 1, 1);
                cr.paint();
                cr.scale(k, k);
                draw_side(cr, side, false);
                string file = sides.size == 1 ? base_path + ".png" : "%s-%d.png".printf(base_path, i + 1);
                if (surface.write_to_png(file) != Cairo.Status.SUCCESS)
                    throw new PrintError.FAILED(_("Cannot write %s").printf(file));
                files += file;
            }
            return files;
        }
    }

    namespace TestPage {

        public string write(Printer printer, string path) throws Error {
            double w = 595.3, h = 841.9;
            var surface = new Cairo.PdfSurface(path, w, h);
            var cr = new Cairo.Context(surface);
            var layout = Pango.cairo_create_layout(cr);
            layout.set_font_description(Pango.FontDescription.from_string("Sans Bold 28"));
            layout.set_text(_("Test Page"), -1);
            cr.set_source_rgb(0.1, 0.1, 0.12);
            cr.move_to(56, 60);
            Pango.cairo_show_layout(cr, layout);
            layout.set_font_description(Pango.FontDescription.from_string("Sans 11"));
            layout.set_text("%s\n%s\n%s".printf(printer.display_name,
                                                printer.make_model != "" ? printer.make_model : printer.device_uri,
                                                new DateTime.now_local().format("%x %X")), -1);
            cr.move_to(56, 110);
            Pango.cairo_show_layout(cr, layout);
            double[,] colors = {
                {0.0, 0.68, 0.94}, {0.93, 0.0, 0.55}, {1.0, 0.95, 0.0}, {0.1, 0.1, 0.1},
                {0.9, 0.2, 0.2}, {0.2, 0.7, 0.3}, {0.2, 0.4, 0.9}
            };
            for (int i = 0; i < 7; i++) {
                cr.set_source_rgb(colors[i, 0], colors[i, 1], colors[i, 2]);
                cr.rectangle(56 + i * 70, 200, 60, 60);
                cr.fill();
            }
            for (int i = 0; i <= 10; i++) {
                cr.set_source_rgb(i / 10.0, i / 10.0, i / 10.0);
                cr.rectangle(56 + i * 44, 290, 44, 30);
                cr.fill();
            }
            cr.set_source_rgb(0, 0, 0);
            cr.set_line_width(0.5);
            for (int i = 0; i < 40; i++) {
                cr.move_to(56 + i * 12, 360);
                cr.line_to(56 + i * 12, 460);
            }
            cr.stroke();
            cr.set_line_width(1);
            cr.rectangle(18, 18, w - 36, h - 36);
            cr.stroke();
            for (int r = 1; r <= 6; r++) {
                cr.arc(w / 2, 620, r * 22, 0, 2 * Math.PI);
                cr.stroke();
            }
            cr.show_page();
            surface.finish();
            return path;
        }
    }
}
