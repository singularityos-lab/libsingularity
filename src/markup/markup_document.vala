namespace Singularity.Annotations {

    public enum Tool {
        SELECT,
        ARROW,
        RECTANGLE,
        ELLIPSE,
        PEN,
        TEXT,
        HIGHLIGHTER,
        STEP,
        REDACT,
        CROP
    }

    public enum RedactStyle {
        PIXELATE,
        BLUR
    }

    public struct Point {
        public double x;
        public double y;
    }

    public struct Bounds {
        public double x;
        public double y;
        public double width;
        public double height;

        public Bounds.from_points(double x1, double y1, double x2, double y2) {
            x = double.min(x1, x2);
            y = double.min(y1, y2);
            width = Math.fabs(x2 - x1);
            height = Math.fabs(y2 - y1);
        }

        public bool contains(double px, double py, double slack = 0) {
            return px >= x - slack && px <= x + width + slack && py >= y - slack && py <= y + height + slack;
        }

        public bool is_empty() {
            return width < 1 || height < 1;
        }
    }

    public abstract class Item : Object {
        public Gdk.RGBA color { get; set; }
        public double stroke { get; set; default = 4; }

        public abstract void draw(Cairo.Context cr);
        public abstract Bounds bounds();
        public abstract void move_by(double dx, double dy);
        public abstract Item copy();
        public abstract string to_svg();

        public virtual bool hit(double x, double y) {
            return bounds().contains(x, y, stroke + 4);
        }

        protected void copy_style(Item from) {
            color = from.color;
            stroke = from.stroke;
        }

        protected void source_color(Cairo.Context cr, double alpha = 1.0) {
            cr.set_source_rgba(color.red, color.green, color.blue, color.alpha * alpha);
        }

        protected string svg_color() {
            return "#%02x%02x%02x".printf((uint) (color.red * 255), (uint) (color.green * 255), (uint) (color.blue * 255));
        }

        protected static string num(double v) {
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            return v.format(buf, "%.2f");
        }

        protected static double segment_distance(double px, double py, double x1, double y1, double x2, double y2) {
            double dx = x2 - x1, dy = y2 - y1;
            double len = dx * dx + dy * dy;
            double t = len > 0 ? (((px - x1) * dx + (py - y1) * dy) / len).clamp(0, 1) : 0;
            double cx = x1 + t * dx - px, cy = y1 + t * dy - py;
            return Math.sqrt(cx * cx + cy * cy);
        }
    }

    public class ArrowItem : Item {
        public double x1 { get; set; }
        public double y1 { get; set; }
        public double x2 { get; set; }
        public double y2 { get; set; }

        public double head_size {
            get { return 10 + stroke * 3; }
        }

        public override void draw(Cairo.Context cr) {
            double angle = Math.atan2(y2 - y1, x2 - x1);
            double head = head_size;
            double length = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
            double shaft = double.max(0, length - head * 0.8);
            cr.save();
            source_color(cr);
            cr.set_line_width(stroke);
            cr.set_line_cap(Cairo.LineCap.ROUND);
            cr.move_to(x1, y1);
            cr.line_to(x1 + Math.cos(angle) * shaft, y1 + Math.sin(angle) * shaft);
            cr.stroke();
            cr.move_to(x2, y2);
            cr.line_to(x2 - head * Math.cos(angle - 0.45), y2 - head * Math.sin(angle - 0.45));
            cr.line_to(x2 - head * Math.cos(angle + 0.45), y2 - head * Math.sin(angle + 0.45));
            cr.close_path();
            cr.fill();
            cr.restore();
        }

        public override Bounds bounds() {
            var b = Bounds.from_points(x1, y1, x2, y2);
            double pad = head_size / 2;
            return { b.x - pad, b.y - pad, b.width + pad * 2, b.height + pad * 2 };
        }

        public override bool hit(double x, double y) {
            return segment_distance(x, y, x1, y1, x2, y2) <= stroke + 6;
        }

        public override void move_by(double dx, double dy) {
            x1 += dx;
            y1 += dy;
            x2 += dx;
            y2 += dy;
        }

        public override Item copy() {
            var item = new ArrowItem();
            item.copy_style(this);
            item.x1 = x1;
            item.y1 = y1;
            item.x2 = x2;
            item.y2 = y2;
            return item;
        }

        public override string to_svg() {
            double angle = Math.atan2(y2 - y1, x2 - x1);
            double head = head_size;
            double length = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
            double shaft = double.max(0, length - head * 0.8);
            return "<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" stroke=\"%s\" stroke-width=\"%s\" stroke-linecap=\"round\"/>\n<polygon points=\"%s,%s %s,%s %s,%s\" fill=\"%s\"/>\n".printf(
                num(x1), num(y1), num(x1 + Math.cos(angle) * shaft), num(y1 + Math.sin(angle) * shaft), svg_color(), num(stroke),
                num(x2), num(y2),
                num(x2 - head * Math.cos(angle - 0.45)), num(y2 - head * Math.sin(angle - 0.45)),
                num(x2 - head * Math.cos(angle + 0.45)), num(y2 - head * Math.sin(angle + 0.45)), svg_color());
        }
    }

    public class ShapeItem : Item {
        public bool ellipse { get; set; }
        public double x { get; set; }
        public double y { get; set; }
        public double width { get; set; }
        public double height { get; set; }

        private void path(Cairo.Context cr) {
            if (ellipse) {
                cr.save();
                cr.translate(x + width / 2, y + height / 2);
                cr.scale(double.max(width / 2, 0.5), double.max(height / 2, 0.5));
                cr.arc(0, 0, 1, 0, 2 * Math.PI);
                cr.restore();
            } else {
                double r = double.min(stroke * 1.5, double.min(width, height) / 2);
                cr.new_sub_path();
                cr.arc(x + width - r, y + r, r, -Math.PI / 2, 0);
                cr.arc(x + width - r, y + height - r, r, 0, Math.PI / 2);
                cr.arc(x + r, y + height - r, r, Math.PI / 2, Math.PI);
                cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
                cr.close_path();
            }
        }

        public override void draw(Cairo.Context cr) {
            cr.save();
            source_color(cr);
            cr.set_line_width(stroke);
            path(cr);
            cr.stroke();
            cr.restore();
        }

        public override Bounds bounds() {
            return { x, y, width, height };
        }

        public override bool hit(double px, double py) {
            double slack = stroke + 6;
            if (!bounds().contains(px, py, slack)) return false;
            if (ellipse) {
                double rx = width / 2, ry = height / 2;
                if (rx < 1 || ry < 1) return true;
                double nx = (px - x - rx) / rx, ny = (py - y - ry) / ry;
                double d = Math.sqrt(nx * nx + ny * ny);
                return Math.fabs(d - 1) * double.min(rx, ry) <= slack;
            }
            bool inside = px > x + slack && px < x + width - slack && py > y + slack && py < y + height - slack;
            return !inside;
        }

        public override void move_by(double dx, double dy) {
            x += dx;
            y += dy;
        }

        public override Item copy() {
            var item = new ShapeItem();
            item.copy_style(this);
            item.ellipse = ellipse;
            item.x = x;
            item.y = y;
            item.width = width;
            item.height = height;
            return item;
        }

        public override string to_svg() {
            if (ellipse) {
                return "<ellipse cx=\"%s\" cy=\"%s\" rx=\"%s\" ry=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\"/>\n".printf(
                    num(x + width / 2), num(y + height / 2), num(width / 2), num(height / 2), svg_color(), num(stroke));
            }
            double r = double.min(stroke * 1.5, double.min(width, height) / 2);
            return "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" rx=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\"/>\n".printf(
                num(x), num(y), num(width), num(height), num(r), svg_color(), num(stroke));
        }
    }

    public class StrokeItem : Item {
        public Gee.ArrayList<Point?> points { get; private set; default = new Gee.ArrayList<Point?>(); }
        public bool highlighter { get; set; }

        public double width_px {
            get { return highlighter ? stroke * 4 + 8 : stroke; }
        }

        public void add_point(double x, double y) {
            points.add({ x, y });
        }

        public override void draw(Cairo.Context cr) {
            if (points.size == 0) return;
            cr.save();
            if (highlighter) {
                source_color(cr, 0.38);
                cr.set_line_cap(Cairo.LineCap.SQUARE);
            } else {
                source_color(cr);
                cr.set_line_cap(Cairo.LineCap.ROUND);
            }
            cr.set_line_join(Cairo.LineJoin.ROUND);
            cr.set_line_width(width_px);
            var first = points[0];
            cr.move_to(first.x, first.y);
            if (points.size == 1) cr.line_to(first.x + 0.1, first.y);
            for (int i = 1; i < points.size; i++) {
                var p = points[i];
                cr.line_to(p.x, p.y);
            }
            cr.stroke();
            cr.restore();
        }

        public override Bounds bounds() {
            double x1 = double.MAX, y1 = double.MAX, x2 = -double.MAX, y2 = -double.MAX;
            foreach (var p in points) {
                x1 = double.min(x1, p.x);
                y1 = double.min(y1, p.y);
                x2 = double.max(x2, p.x);
                y2 = double.max(y2, p.y);
            }
            double pad = width_px / 2;
            if (points.size == 0) return { 0, 0, 0, 0 };
            return { x1 - pad, y1 - pad, x2 - x1 + pad * 2, y2 - y1 + pad * 2 };
        }

        public override bool hit(double x, double y) {
            for (int i = 1; i < points.size; i++) {
                if (segment_distance(x, y, points[i - 1].x, points[i - 1].y, points[i].x, points[i].y) <= width_px / 2 + 5) return true;
            }
            return points.size == 1 && bounds().contains(x, y, 5);
        }

        public override void move_by(double dx, double dy) {
            for (int i = 0; i < points.size; i++) {
                var p = points[i];
                points[i] = { p.x + dx, p.y + dy };
            }
        }

        public override Item copy() {
            var item = new StrokeItem();
            item.copy_style(this);
            item.highlighter = highlighter;
            foreach (var p in points) item.points.add(p);
            return item;
        }

        public override string to_svg() {
            if (points.size == 0) return "";
            var d = new StringBuilder();
            for (int i = 0; i < points.size; i++) {
                d.append("%s%s %s ".printf(i == 0 ? "M" : "L", num(points[i].x), num(points[i].y)));
            }
            return "<path d=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\" stroke-linecap=\"%s\" stroke-linejoin=\"round\"%s/>\n".printf(
                d.str.strip(), svg_color(), num(width_px), highlighter ? "square" : "round", highlighter ? " stroke-opacity=\"0.38\"" : "");
        }
    }

    public class TextItem : Item {
        public double x { get; set; }
        public double y { get; set; }
        public string text { get; set; default = ""; }

        public double font_size {
            get { return 12 + stroke * 3; }
        }

        private Pango.Layout layout(Cairo.Context cr) {
            var layout = Pango.cairo_create_layout(cr);
            var font = new Pango.FontDescription();
            font.set_family("Sans");
            font.set_weight(Pango.Weight.BOLD);
            font.set_absolute_size(font_size * Pango.SCALE);
            layout.set_font_description(font);
            layout.set_text(text, -1);
            return layout;
        }

        public override void draw(Cairo.Context cr) {
            if (text == "") return;
            cr.save();
            var layout = layout(cr);
            cr.move_to(x, y);
            Pango.cairo_layout_path(cr, layout);
            double luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue;
            if (luminance > 0.6) cr.set_source_rgba(0, 0, 0, 0.55); else cr.set_source_rgba(1, 1, 1, 0.85);
            cr.set_line_width(double.max(2, font_size / 8));
            cr.set_line_join(Cairo.LineJoin.ROUND);
            cr.stroke_preserve();
            source_color(cr);
            cr.fill();
            cr.restore();
        }

        public override Bounds bounds() {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 1, 1);
            var cr = new Cairo.Context(surface);
            int w, h;
            layout(cr).get_pixel_size(out w, out h);
            return { x, y, double.max(w, font_size), double.max(h, font_size) };
        }

        public override bool hit(double px, double py) {
            return bounds().contains(px, py, 4);
        }

        public override void move_by(double dx, double dy) {
            x += dx;
            y += dy;
        }

        public override Item copy() {
            var item = new TextItem();
            item.copy_style(this);
            item.x = x;
            item.y = y;
            item.text = text;
            return item;
        }

        public override string to_svg() {
            if (text == "") return "";
            var builder = new StringBuilder();
            string[] rows = text.split("\n");
            for (int i = 0; i < rows.length; i++) {
                builder.append("<text x=\"%s\" y=\"%s\" font-family=\"Sans\" font-weight=\"bold\" font-size=\"%s\" fill=\"%s\">%s</text>\n".printf(
                    num(x), num(y + font_size * (i + 1)), num(font_size), svg_color(), GLib.Markup.escape_text(rows[i])));
            }
            return builder.str;
        }
    }

    public class StepItem : Item {
        public double x { get; set; }
        public double y { get; set; }
        public int number { get; set; default = 1; }

        public double radius {
            get { return 10 + stroke * 2; }
        }

        public override void draw(Cairo.Context cr) {
            cr.save();
            cr.arc(x, y, radius + 2, 0, 2 * Math.PI);
            cr.set_source_rgba(1, 1, 1, 0.9);
            cr.fill();
            cr.arc(x, y, radius, 0, 2 * Math.PI);
            source_color(cr);
            cr.fill();
            var layout = Pango.cairo_create_layout(cr);
            var font = new Pango.FontDescription();
            font.set_family("Sans");
            font.set_weight(Pango.Weight.BOLD);
            font.set_absolute_size(radius * 1.1 * Pango.SCALE);
            layout.set_font_description(font);
            layout.set_text(number.to_string(), -1);
            int w, h;
            layout.get_pixel_size(out w, out h);
            double luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue;
            if (luminance > 0.6) cr.set_source_rgb(0, 0, 0); else cr.set_source_rgb(1, 1, 1);
            cr.move_to(x - w / 2.0, y - h / 2.0);
            Pango.cairo_show_layout(cr, layout);
            cr.restore();
        }

        public override Bounds bounds() {
            double r = radius + 2;
            return { x - r, y - r, r * 2, r * 2 };
        }

        public override bool hit(double px, double py) {
            return Math.sqrt((px - x) * (px - x) + (py - y) * (py - y)) <= radius + 4;
        }

        public override void move_by(double dx, double dy) {
            x += dx;
            y += dy;
        }

        public override Item copy() {
            var item = new StepItem();
            item.copy_style(this);
            item.x = x;
            item.y = y;
            item.number = number;
            return item;
        }

        public override string to_svg() {
            return "<circle cx=\"%s\" cy=\"%s\" r=\"%s\" fill=\"%s\" stroke=\"#ffffff\" stroke-width=\"2\"/>\n<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" dominant-baseline=\"central\" font-family=\"Sans\" font-weight=\"bold\" font-size=\"%s\" fill=\"#ffffff\">%d</text>\n".printf(
                num(x), num(y), num(radius), svg_color(), num(x), num(y), num(radius * 1.1), number);
        }
    }

    public class RedactItem : Item {
        public double x { get; set; }
        public double y { get; set; }
        public double width { get; set; }
        public double height { get; set; }
        public RedactStyle style { get; set; default = RedactStyle.PIXELATE; }

        public int block_size {
            get { return (int) double.max(10, double.min(width, height) / 3); }
        }

        public void apply(Cairo.Context cr, Cairo.ImageSurface source) {
            int ix = (int) Math.floor(x), iy = (int) Math.floor(y);
            int iw = (int) Math.ceil(width), ih = (int) Math.ceil(height);
            if (iw < 1 || ih < 1) return;
            double factor = style == RedactStyle.PIXELATE ? block_size : double.max(14, double.min(iw, ih) / 2.5);
            int sw = int.max(1, (int) (iw / factor));
            int sh = int.max(1, (int) (ih / factor));
            var small = new Cairo.ImageSurface(Cairo.Format.ARGB32, sw, sh);
            var sc = new Cairo.Context(small);
            sc.scale((double) sw / iw, (double) sh / ih);
            sc.set_source_surface(source, -ix, -iy);
            sc.get_source().set_filter(Cairo.Filter.GOOD);
            sc.paint();
            small.flush();
            cr.save();
            cr.rectangle(ix, iy, iw, ih);
            cr.clip();
            cr.translate(ix, iy);
            cr.scale((double) iw / sw, (double) ih / sh);
            cr.set_source_surface(small, 0, 0);
            var pattern = cr.get_source();
            pattern.set_filter(style == RedactStyle.PIXELATE ? Cairo.Filter.NEAREST : Cairo.Filter.BILINEAR);
            pattern.set_extend(Cairo.Extend.PAD);
            cr.paint();
            cr.restore();
        }

        public override void draw(Cairo.Context cr) {
        }

        public override Bounds bounds() {
            return { x, y, width, height };
        }

        public override bool hit(double px, double py) {
            return bounds().contains(px, py, 2);
        }

        public override void move_by(double dx, double dy) {
            x += dx;
            y += dy;
        }

        public override Item copy() {
            var item = new RedactItem();
            item.copy_style(this);
            item.x = x;
            item.y = y;
            item.width = width;
            item.height = height;
            item.style = style;
            return item;
        }

        public override string to_svg() {
            return "";
        }
    }

    public class Document : Object {
        private class Snapshot {
            public Gee.ArrayList<Item> items = new Gee.ArrayList<Item>();
            public Bounds crop;
        }

        public Cairo.ImageSurface source { get; private set; }
        public int width { get; private set; }
        public int height { get; private set; }
        public Gee.ArrayList<Item> items { get; private set; default = new Gee.ArrayList<Item>(); }
        private Bounds _crop;
        public Bounds crop {
            get { return _crop; }
        }

        private Gee.ArrayList<Snapshot> undo_stack = new Gee.ArrayList<Snapshot>();
        private Gee.ArrayList<Snapshot> redo_stack = new Gee.ArrayList<Snapshot>();
        private Cairo.ImageSurface? redacted_cache = null;

        public signal void changed();

        public Document(Cairo.ImageSurface source) {
            Object();
            this.source = source;
            width = source.get_width();
            height = source.get_height();
            _crop = { 0, 0, width, height };
        }

        public static Document from_texture(Gdk.Texture texture) {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, texture.get_width(), texture.get_height());
            surface.flush();
            texture.download(surface.get_data(), surface.get_stride());
            surface.mark_dirty();
            return new Document(surface);
        }

        public static Document from_file(File file) throws Error {
            return from_texture(Gdk.Texture.from_file(file));
        }

        public bool can_undo {
            get { return undo_stack.size > 0; }
        }

        public bool can_redo {
            get { return redo_stack.size > 0; }
        }

        public bool is_modified {
            get { return items.size > 0 || is_cropped; }
        }

        public bool is_cropped {
            get { return crop.x > 0 || crop.y > 0 || crop.width < width || crop.height < height; }
        }

        private Snapshot snapshot() {
            var s = new Snapshot();
            foreach (var item in items) s.items.add(item.copy());
            s.crop = crop;
            return s;
        }

        private void restore(Snapshot s) {
            items.clear();
            foreach (var item in s.items) items.add(item.copy());
            _crop = s.crop;
            redacted_cache = null;
        }

        public void checkpoint() {
            undo_stack.add(snapshot());
            redo_stack.clear();
        }

        public void add(Item item) {
            checkpoint();
            items.add(item);
            if (item is RedactItem) redacted_cache = null;
            changed();
        }

        public void remove(Item item) {
            if (!items.contains(item)) return;
            checkpoint();
            items.remove(item);
            redacted_cache = null;
            changed();
        }

        public void move_item(Item item, double dx, double dy) {
            item.move_by(dx, dy);
            if (item is RedactItem) redacted_cache = null;
            changed();
        }

        public void touch() {
            redacted_cache = null;
            changed();
        }

        public void clear() {
            if (items.size == 0 && !is_cropped) return;
            checkpoint();
            items.clear();
            _crop = { 0, 0, width, height };
            redacted_cache = null;
            changed();
        }

        public void set_crop(Bounds rect) {
            double x1 = rect.x.clamp(0, width), y1 = rect.y.clamp(0, height);
            double x2 = (rect.x + rect.width).clamp(0, width), y2 = (rect.y + rect.height).clamp(0, height);
            if (x2 - x1 < 4 || y2 - y1 < 4) return;
            checkpoint();
            _crop = { Math.round(x1), Math.round(y1), Math.round(x2 - x1), Math.round(y2 - y1) };
            changed();
        }

        public void reset_crop() {
            if (!is_cropped) return;
            set_crop({ 0, 0, width, height });
        }

        public bool undo() {
            if (undo_stack.size == 0) return false;
            redo_stack.add(snapshot());
            restore(undo_stack.remove_at(undo_stack.size - 1));
            changed();
            return true;
        }

        public bool redo() {
            if (redo_stack.size == 0) return false;
            undo_stack.add(snapshot());
            restore(redo_stack.remove_at(redo_stack.size - 1));
            changed();
            return true;
        }

        public int next_step_number() {
            int max = 0;
            foreach (var item in items) {
                if (item is StepItem) max = int.max(max, ((StepItem) item).number);
            }
            return max + 1;
        }

        public Item? item_at(double x, double y) {
            for (int i = items.size - 1; i >= 0; i--) {
                if (items[i].hit(x, y)) return items[i];
            }
            return null;
        }

        public Cairo.ImageSurface redacted_source() {
            if (redacted_cache != null) return redacted_cache;
            bool any = false;
            foreach (var item in items) {
                if (item is RedactItem) { any = true; break; }
            }
            if (!any) return source;
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);
            cr.set_source_surface(source, 0, 0);
            cr.paint();
            foreach (var item in items) {
                if (item is RedactItem) ((RedactItem) item).apply(cr, source);
            }
            surface.flush();
            redacted_cache = surface;
            return surface;
        }

        public void draw(Cairo.Context cr, Item? pending = null) {
            cr.save();
            cr.set_source_surface(redacted_source(), 0, 0);
            cr.paint();
            if (pending is RedactItem) ((RedactItem) pending).apply(cr, source);
            foreach (var item in items) item.draw(cr);
            if (pending != null && !(pending is RedactItem)) pending.draw(cr);
            cr.restore();
        }

        public Cairo.ImageSurface render() {
            int w = (int) crop.width, h = (int) crop.height;
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context(surface);
            cr.translate(-crop.x, -crop.y);
            draw(cr);
            surface.flush();
            return surface;
        }

        public Gdk.Texture to_texture() {
            var surface = render();
            var bytes = new Bytes(surface.get_data()[0:surface.get_stride() * surface.get_height()]);
            return new Gdk.MemoryTexture(surface.get_width(), surface.get_height(), Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, surface.get_stride());
        }

        public void save_png(string path) throws Error {
            var status = render().write_to_png(path);
            if (status != Cairo.Status.SUCCESS) throw new IOError.FAILED(_("Could not save the image: %s"), status.to_string());
        }

        public Bytes to_png_bytes() {
            return to_texture().save_to_png_bytes();
        }

        public string to_svg() {
            int w = (int) crop.width, h = (int) crop.height;
            var base_surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context(base_surface);
            cr.set_source_surface(redacted_source(), -crop.x, -crop.y);
            cr.paint();
            base_surface.flush();
            var bytes = new Bytes(base_surface.get_data()[0:base_surface.get_stride() * h]);
            var texture = new Gdk.MemoryTexture(w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, base_surface.get_stride());
            string png = Base64.encode(texture.save_to_png_bytes().get_data());
            var svg = new StringBuilder();
            svg.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
            svg.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n".printf(w, h, w, h));
            svg.append("<image x=\"0\" y=\"0\" width=\"%d\" height=\"%d\" href=\"data:image/png;base64,%s\"/>\n".printf(w, h, png));
            svg.append("<g transform=\"translate(%d %d)\">\n".printf(-(int) crop.x, -(int) crop.y));
            foreach (var item in items) svg.append(item.to_svg());
            svg.append("</g>\n</svg>\n");
            return svg.str;
        }
    }
}
