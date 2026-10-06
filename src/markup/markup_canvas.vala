using Gtk;
using Singularity.Annotations;

namespace Singularity.Widgets {

    public class MarkupCanvas : Widget {
        private const double MARGIN = 28;

        private Document? _document = null;
        private Item? pending = null;
        private Item? selected = null;
        private Bounds? crop_draft = null;
        private double last_x;
        private double last_y;
        private bool moved_selection = false;
        private GestureDrag drag;

        public Tool tool { get; set; default = Tool.ARROW; }
        public Gdk.RGBA color { get; set; }
        public double stroke { get; set; default = 4; }
        public RedactStyle redact_style { get; set; default = RedactStyle.PIXELATE; }
        public double bottom_inset { get; set; default = 0; }
        public double top_inset { get; set; default = 0; }

        public signal void text_requested(double image_x, double image_y, TextItem? existing);
        public signal void selection_changed();
        public signal void geometry_changed();

        public Document? document {
            get { return _document; }
            set {
                if (_document != null) _document.changed.disconnect(on_changed);
                _document = value;
                selected = null;
                pending = null;
                if (_document != null) _document.changed.connect(on_changed);
                queue_draw();
                geometry_changed();
            }
        }

        public Item? selected_item {
            get { return selected; }
        }

        construct {
            hexpand = true;
            vexpand = true;
            focusable = true;
            overflow = Overflow.HIDDEN;
            add_css_class("markup-canvas");
            var red = Gdk.RGBA();
            red.parse("#e01b24");
            color = red;

            drag = new GestureDrag();
            drag.button = Gdk.BUTTON_PRIMARY;
            drag.drag_begin.connect(on_drag_begin);
            drag.drag_update.connect(on_drag_update);
            drag.drag_end.connect(on_drag_end);
            add_controller(drag);

            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => update_cursor(x, y));
            add_controller(motion);

            notify["tool"].connect(() => {
                if (tool != Tool.SELECT) select(null);
                crop_draft = null;
                queue_draw();
                geometry_changed();
            });
            notify["color"].connect(() => restyle_selection());
            notify["stroke"].connect(() => restyle_selection());
            notify["bottom-inset"].connect(() => { queue_draw(); geometry_changed(); });
            notify["top-inset"].connect(() => { queue_draw(); geometry_changed(); });
        }

        private void on_changed() {
            if (selected != null && !_document.items.contains(selected)) select(null);
            queue_draw();
            geometry_changed();
        }

        public void select(Item? item) {
            selected = item;
            queue_draw();
            selection_changed();
        }

        public void delete_selected() {
            if (selected == null || _document == null) return;
            var item = selected;
            select(null);
            _document.remove(item);
        }

        private void restyle_selection() {
            if (selected == null || _document == null || tool != Tool.SELECT) return;
            if (selected.color.equal(color) && selected.stroke == stroke) return;
            _document.checkpoint();
            selected.color = color;
            if (!(selected is RedactItem)) selected.stroke = stroke;
            _document.touch();
        }

        private Bounds visible_region() {
            if (_document == null) return { 0, 0, 1, 1 };
            if (tool == Tool.CROP) return { 0, 0, _document.width, _document.height };
            return _document.crop;
        }

        public bool image_geometry(out double origin_x, out double origin_y, out double scale) {
            origin_x = 0;
            origin_y = 0;
            scale = 1;
            if (_document == null) return false;
            var region = visible_region();
            double w = get_width() - MARGIN * 2;
            double h = get_height() - MARGIN * 2 - top_inset - bottom_inset;
            if (w <= 0 || h <= 0) return false;
            scale = double.min(1.0, double.min(w / region.width, h / region.height));
            double vw = region.width * scale, vh = region.height * scale;
            origin_x = MARGIN + (w - vw) / 2 - region.x * scale;
            origin_y = MARGIN + top_inset + (h - vh) / 2 - region.y * scale;
            return true;
        }

        public void to_image(double x, double y, out double ix, out double iy) {
            double ox, oy, scale;
            image_geometry(out ox, out oy, out scale);
            ix = (x - ox) / scale;
            iy = (y - oy) / scale;
        }

        public void to_view(double ix, double iy, out double x, out double y) {
            double ox, oy, scale;
            image_geometry(out ox, out oy, out scale);
            x = ox + ix * scale;
            y = oy + iy * scale;
        }

        private void on_drag_begin(double x, double y) {
            if (_document == null) return;
            grab_focus();
            double ix, iy;
            to_image(x, y, out ix, out iy);
            last_x = ix;
            last_y = iy;
            moved_selection = false;
            switch (tool) {
                case Tool.SELECT:
                    select(_document.item_at(ix, iy));
                    break;
                case Tool.ARROW:
                    var arrow = new ArrowItem();
                    arrow.x1 = arrow.x2 = ix;
                    arrow.y1 = arrow.y2 = iy;
                    pending = arrow;
                    break;
                case Tool.RECTANGLE:
                case Tool.ELLIPSE:
                    var shape = new ShapeItem();
                    shape.ellipse = tool == Tool.ELLIPSE;
                    shape.x = ix;
                    shape.y = iy;
                    pending = shape;
                    break;
                case Tool.PEN:
                case Tool.HIGHLIGHTER:
                    var line = new StrokeItem();
                    line.highlighter = tool == Tool.HIGHLIGHTER;
                    line.add_point(ix, iy);
                    pending = line;
                    break;
                case Tool.REDACT:
                    var redact = new RedactItem();
                    redact.style = redact_style;
                    redact.x = ix;
                    redact.y = iy;
                    pending = redact;
                    break;
                case Tool.CROP:
                    crop_draft = { ix, iy, 0, 0 };
                    break;
                default:
                    break;
            }
            if (pending != null) {
                pending.color = color;
                pending.stroke = stroke;
            }
            queue_draw();
        }

        private void on_drag_update(double ox, double oy) {
            if (_document == null) return;
            double sx, sy, isx, isy, ix, iy;
            drag.get_start_point(out sx, out sy);
            to_image(sx, sy, out isx, out isy);
            to_image(sx + ox, sy + oy, out ix, out iy);
            drag_to(ix, iy, isx, isy);
        }

        private void drag_to(double ix, double iy, double sx, double sy) {
            if (tool == Tool.SELECT && selected != null) {
                if (!moved_selection) {
                    _document.checkpoint();
                    moved_selection = true;
                }
                _document.move_item(selected, ix - last_x, iy - last_y);
                last_x = ix;
                last_y = iy;
                return;
            }
            if (pending is ArrowItem) {
                ((ArrowItem) pending).x2 = ix;
                ((ArrowItem) pending).y2 = iy;
            } else if (pending is ShapeItem) {
                var b = Bounds.from_points(sx, sy, ix, iy);
                var shape = (ShapeItem) pending;
                shape.x = b.x;
                shape.y = b.y;
                shape.width = b.width;
                shape.height = b.height;
            } else if (pending is StrokeItem) {
                ((StrokeItem) pending).add_point(ix, iy);
            } else if (pending is RedactItem) {
                var b = Bounds.from_points(sx, sy, ix, iy);
                var r = (RedactItem) pending;
                r.x = b.x;
                r.y = b.y;
                r.width = b.width;
                r.height = b.height;
            } else if (tool == Tool.CROP && crop_draft != null) {
                crop_draft = Bounds.from_points(sx, sy, ix, iy);
            }
            queue_draw();
        }

        private void on_drag_end(double ox, double oy) {
            if (_document == null) return;
            double sx, sy;
            drag.get_start_point(out sx, out sy);
            double isx, isy, iex, iey;
            to_image(sx, sy, out isx, out isy);
            to_image(sx + ox, sy + oy, out iex, out iey);
            bool click = Math.fabs(ox) < 3 && Math.fabs(oy) < 3;
            if (click) {
                if (tool == Tool.TEXT || (tool == Tool.SELECT && selected is TextItem)) {
                    var existing = _document.item_at(isx, isy) as TextItem;
                    if (tool == Tool.TEXT || existing != null) text_requested(isx, isy, existing);
                } else if (tool == Tool.STEP) {
                    var step = new StepItem();
                    step.color = color;
                    step.stroke = stroke;
                    step.x = isx;
                    step.y = isy;
                    step.number = _document.next_step_number();
                    _document.add(step);
                }
                pending = null;
                crop_draft = null;
                queue_draw();
                return;
            }
            if (tool == Tool.CROP && crop_draft != null) {
                var draft = crop_draft;
                crop_draft = null;
                _document.set_crop(draft);
                queue_draw();
                return;
            }
            if (pending != null) {
                var item = pending;
                pending = null;
                var b = item.bounds();
                bool tiny = !(item is StrokeItem) && b.width < 3 && b.height < 3;
                if (item is ArrowItem) {
                    var a = (ArrowItem) item;
                    tiny = Math.sqrt((a.x2 - a.x1) * (a.x2 - a.x1) + (a.y2 - a.y1) * (a.y2 - a.y1)) < 6;
                }
                if (!tiny) _document.add(item);
            }
            queue_draw();
        }

        private void update_cursor(double x, double y) {
            if (_document == null) return;
            double ix, iy;
            to_image(x, y, out ix, out iy);
            switch (tool) {
                case Tool.SELECT:
                    set_cursor_from_name(_document.item_at(ix, iy) != null ? "move" : "default");
                    break;
                case Tool.TEXT:
                    set_cursor_from_name("text");
                    break;
                default:
                    set_cursor_from_name("crosshair");
                    break;
            }
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            if (_document == null) return;
            double ox, oy, scale;
            if (!image_geometry(out ox, out oy, out scale)) return;
            var region = visible_region();
            var cr = snapshot.append_cairo({ { 0, 0 }, { get_width(), get_height() } });
            double vx = ox + region.x * scale, vy = oy + region.y * scale;
            double vw = region.width * scale, vh = region.height * scale;
            for (int i = 6; i > 0; i--) {
                cr.rectangle(vx - i, vy - i + 2, vw + i * 2, vh + i * 2);
                cr.set_source_rgba(0, 0, 0, 0.035);
                cr.fill();
            }
            cr.save();
            cr.rectangle(vx, vy, vw, vh);
            cr.clip();
            cr.translate(ox, oy);
            cr.scale(scale, scale);
            _document.draw(cr, pending);
            cr.restore();

            if (tool == Tool.CROP) {
                Bounds c = _document.crop;
                if (crop_draft != null && !crop_draft.is_empty()) c = crop_draft;
                double cx = ox + c.x * scale, cy = oy + c.y * scale, cw = c.width * scale, ch = c.height * scale;
                cr.save();
                cr.set_fill_rule(Cairo.FillRule.EVEN_ODD);
                cr.rectangle(vx, vy, vw, vh);
                cr.rectangle(cx, cy, cw, ch);
                cr.set_source_rgba(0, 0, 0, 0.55);
                cr.fill();
                cr.set_source_rgba(1, 1, 1, 0.95);
                cr.set_line_width(1.5);
                cr.rectangle(cx, cy, cw, ch);
                cr.stroke();
                cr.set_line_width(4);
                double k = double.min(18, double.min(cw, ch) / 3);
                double[,] corners = { { cx, cy, 1, 1 }, { cx + cw, cy, -1, 1 }, { cx, cy + ch, 1, -1 }, { cx + cw, cy + ch, -1, -1 } };
                for (int i = 0; i < 4; i++) {
                    cr.move_to(corners[i, 0], corners[i, 1] + corners[i, 3] * k);
                    cr.line_to(corners[i, 0], corners[i, 1]);
                    cr.line_to(corners[i, 0] + corners[i, 2] * k, corners[i, 1]);
                    cr.stroke();
                }
                cr.restore();
            }

            if (selected != null && tool == Tool.SELECT) {
                var b = selected.bounds();
                var accent = Gdk.RGBA();
                accent.parse("#3584e4");
                cr.save();
                cr.set_source_rgba(accent.red, accent.green, accent.blue, 1);
                cr.set_line_width(1.5);
                double[] dash = { 5, 4 };
                cr.set_dash(dash, 0);
                cr.rectangle(ox + b.x * scale - 4, oy + b.y * scale - 4, b.width * scale + 8, b.height * scale + 8);
                cr.stroke();
                cr.restore();
            }
        }

        public override void size_allocate(int width, int height, int baseline) {
            base.size_allocate(width, height, baseline);
            geometry_changed();
        }
    }
}
