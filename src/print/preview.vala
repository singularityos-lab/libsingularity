using Gtk;
using Singularity.Widgets;

namespace Singularity.Print {

    /**
     * Draws one sheet side on a soft backdrop with a paper shadow. The
     * rendered sheet is cached per size and invalidated by `refresh()`.
     */
    public class SheetView : Widget {
        public SheetRenderer? renderer { get; set; }
        public SheetSide? side { get; set; }
        public double zoom { get; set; default = 0; }
        public bool thumbnail { get; set; }

        private Cairo.ImageSurface? cache;
        private int cache_w;
        private int cache_h;
        private int cache_scale;

        public SheetView(bool thumbnail = false) {
            Object(thumbnail: thumbnail);
            add_css_class(thumbnail ? "print-thumb-sheet" : "print-sheet-view");
            notify["side"].connect(refresh);
            notify["renderer"].connect(refresh);
            notify["zoom"].connect(() => {
                cache = null;
                queue_resize();
            });
        }

        public void refresh() {
            cache = null;
            queue_resize();
            queue_draw();
        }

        public override SizeRequestMode get_request_mode() {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Orientation orientation, int for_size, out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            if (thumbnail || zoom <= 0 || side == null) {
                minimum = thumbnail ? 40 : 120;
                natural = thumbnail ? 72 : 400;
                return;
            }
            double size = orientation == Orientation.HORIZONTAL ? side.width : side.height;
            minimum = natural = (int) (size * zoom * 96.0 / 72.0) + 48;
        }

        private void sheet_rect(out double x, out double y, out double w, out double h) {
            double aw = get_width();
            double ah = get_height();
            double sw = side != null ? side.width : 595;
            double sh = side != null ? side.height : 842;
            double pad = thumbnail ? 4 : 24;
            double k;
            if (!thumbnail && zoom > 0) k = zoom * 96.0 / 72.0;
            else k = double.min((aw - pad * 2) / sw, (ah - pad * 2) / sh);
            k = double.max(k, 0.01);
            w = sw * k;
            h = sh * k;
            x = Math.floor((aw - w) / 2);
            y = Math.floor((ah - h) / 2);
        }

        public override void snapshot(Snapshot snapshot) {
            double x, y, w, h;
            sheet_rect(out x, out y, out w, out h);
            if (w < 2 || h < 2) return;
            var rect = Graphene.Rect().init((float) x, (float) y, (float) w, (float) h);
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(rect, thumbnail ? 2 : 3);
            var shadow = Gdk.RGBA() { red = 0, green = 0, blue = 0, alpha = thumbnail ? 0.18f : 0.22f };
            snapshot.append_outset_shadow(rounded, shadow, 0, thumbnail ? 1 : 6, 0, thumbnail ? 3 : 18);
            int scale = get_scale_factor();
            int pw = (int) Math.ceil(w * scale);
            int ph = (int) Math.ceil(h * scale);
            if (cache == null || cache_w != pw || cache_h != ph || cache_scale != scale) {
                cache = new Cairo.ImageSurface(Cairo.Format.RGB24, pw, ph);
                var cr = new Cairo.Context(cache);
                cr.set_source_rgb(1, 1, 1);
                cr.paint();
                if (renderer != null && side != null) {
                    cr.scale(pw / side.width, ph / side.height);
                    renderer.draw_side(cr, side, true);
                }
                cache.flush();
                cache_w = pw;
                cache_h = ph;
                cache_scale = scale;
            }
            var cr2 = snapshot.append_cairo(rect);
            cr2.translate(x, y);
            cr2.scale(1.0 / scale, 1.0 / scale);
            cr2.set_source_surface(cache, 0, 0);
            cr2.paint();
        }
    }

    /**
     * The preview stage: current sheet, navigation, zoom and a strip of
     * thumbnails for every sheet side.
     */
    public class PreviewStage : Box {
        public signal void side_changed(int index);

        private SheetView view;
        private ScrolledWindow scroller;
        private Box thumbs;
        private ScrolledWindow thumb_scroller;
        private Label position;
        private Button prev_btn;
        private Button next_btn;
        private Button zoom_label;
        private Stack stack;
        private StatusPage message_page;
        private Gee.List<SheetSide> sides = new Gee.ArrayList<SheetSide>();
        private SheetRenderer? renderer;
        private int current;
        private const double[] ZOOMS = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0};

        public PreviewStage() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("print-stage");
            hexpand = true;
            vexpand = true;

            view = new SheetView();
            view.hexpand = true;
            view.vexpand = true;
            scroller = new ScrolledWindow();
            scroller.child = view;
            scroller.hexpand = true;
            scroller.vexpand = true;
            scroller.hscrollbar_policy = PolicyType.AUTOMATIC;

            var spinner_box = new Box(Orientation.VERTICAL, 12);
            spinner_box.valign = Align.CENTER;
            spinner_box.halign = Align.CENTER;
            var spinner = new Spinner();
            spinner.spinning = true;
            spinner.set_size_request(32, 32);
            spinner_box.append(spinner);
            var wait = new Label(_("Preparing Preview"));
            wait.add_css_class("dim-label");
            spinner_box.append(wait);

            message_page = new StatusPage();
            message_page.icon_name = "printer";

            stack = new Stack();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named(scroller, "preview");
            stack.add_named(spinner_box, "loading");
            stack.add_named(message_page, "message");
            stack.vexpand = true;
            append(stack);

            var bar = new Box(Orientation.HORIZONTAL, 6);
            bar.add_css_class("print-preview-bar");
            bar.halign = Align.CENTER;
            prev_btn = bubble("go-previous-symbolic", _("Previous Sheet"));
            prev_btn.clicked.connect(() => show_side(current - 1));
            bar.append(prev_btn);
            position = new Label("");
            position.add_css_class("print-position");
            position.width_chars = 12;
            bar.append(position);
            next_btn = bubble("go-next-symbolic", _("Next Sheet"));
            next_btn.clicked.connect(() => show_side(current + 1));
            bar.append(next_btn);
            var sep = new Separator(Orientation.VERTICAL);
            sep.margin_start = 6;
            sep.margin_end = 6;
            bar.append(sep);
            var zoom_out = bubble("zoom-out-symbolic", _("Zoom Out"));
            zoom_out.clicked.connect(() => step_zoom(-1));
            bar.append(zoom_out);
            zoom_label = new Button.with_label(_("Fit"));
            zoom_label.add_css_class("flat");
            zoom_label.add_css_class("singularity-hover-btn");
            zoom_label.add_css_class("print-zoom-label");
            zoom_label.tooltip_text = _("Fit Sheet");
            zoom_label.clicked.connect(() => set_zoom(0));
            bar.append(zoom_label);
            var zoom_in = bubble("zoom-in-symbolic", _("Zoom In"));
            zoom_in.clicked.connect(() => step_zoom(1));
            bar.append(zoom_in);
            append(bar);

            thumbs = new Box(Orientation.HORIZONTAL, 10);
            thumbs.add_css_class("print-thumbs");
            thumbs.halign = Align.CENTER;
            thumb_scroller = new ScrolledWindow();
            thumb_scroller.child = thumbs;
            thumb_scroller.vscrollbar_policy = PolicyType.NEVER;
            thumb_scroller.hscrollbar_policy = PolicyType.AUTOMATIC;
            thumb_scroller.set_size_request(-1, 112);
            thumb_scroller.add_css_class("print-thumb-strip");
            append(thumb_scroller);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Page_Down) { show_side(current + 1); return true; }
                if (keyval == Gdk.Key.Page_Up) { show_side(current - 1); return true; }
                return false;
            });
            add_controller(keys);
            var zoom_scroll = new EventControllerScroll(EventControllerScrollFlags.VERTICAL);
            zoom_scroll.scroll.connect((dx, dy) => {
                var mods = zoom_scroll.get_current_event_state();
                if ((mods & Gdk.ModifierType.CONTROL_MASK) == 0) return false;
                step_zoom(dy < 0 ? 1 : -1);
                return true;
            });
            scroller.add_controller(zoom_scroll);
        }

        private Button bubble(string icon, string tip) {
            var b = new Button.from_icon_name(icon);
            b.add_css_class("flat");
            b.add_css_class("image-button");
            b.add_css_class("singularity-hover-btn");
            b.tooltip_text = tip;
            b.update_property(AccessibleProperty.LABEL, tip, -1);
            return b;
        }

        public void set_loading() {
            stack.visible_child_name = "loading";
        }

        public void set_message(string title, string description) {
            message_page.title = title;
            message_page.description = description;
            stack.visible_child_name = "message";
        }

        public void set_sides(SheetRenderer renderer, Gee.List<SheetSide> sides) {
            this.renderer = renderer;
            this.sides = sides;
            view.renderer = renderer;
            var child = thumbs.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                thumbs.remove(child);
                child = next;
            }
            for (int i = 0; i < sides.size; i++) {
                int index = i;
                var button = new Button();
                button.add_css_class("flat");
                button.add_css_class("print-thumb");
                var box = new Box(Orientation.VERTICAL, 4);
                var sheet = new SheetView(true);
                sheet.renderer = renderer;
                sheet.side = sides[i];
                double ratio = sides[i].width / sides[i].height;
                sheet.set_size_request((int) (64 * ratio).clamp(36, 96), 64);
                box.append(sheet);
                var num = new Label((i + 1).to_string());
                num.add_css_class("caption");
                box.append(num);
                button.child = box;
                button.tooltip_text = _("Sheet %d").printf(i + 1);
                button.clicked.connect(() => show_side(index));
                thumbs.append(button);
                if (i >= 199) break;
            }
            thumb_scroller.visible = sides.size > 1;
            stack.visible_child_name = "preview";
            show_side(int.min(current, sides.size - 1).clamp(0, int.max(sides.size - 1, 0)));
        }

        public void show_side(int index) {
            if (sides.size == 0) {
                view.side = null;
                position.label = "";
                prev_btn.sensitive = next_btn.sensitive = false;
                return;
            }
            current = index.clamp(0, sides.size - 1);
            view.side = sides[current];
            view.refresh();
            position.label = _("%d of %d").printf(current + 1, sides.size);
            prev_btn.sensitive = current > 0;
            next_btn.sensitive = current < sides.size - 1;
            int i = 0;
            var child = thumbs.get_first_child();
            while (child != null) {
                if (i == current) child.add_css_class("selected");
                else child.remove_css_class("selected");
                if (i == current) {
                    var target = child;
                    Idle.add(() => {
                        Graphene.Point p = {};
                        Graphene.Point origin = { 0, 0 };
                        if (target.compute_point(thumbs, origin, out p)) {
                            var adj = thumb_scroller.hadjustment;
                            double left = p.x - adj.page_size / 2 + target.get_width() / 2;
                            adj.value = left.clamp(adj.lower, double.max(adj.lower, adj.upper - adj.page_size));
                        }
                        return Source.REMOVE;
                    });
                }
                child = child.get_next_sibling();
                i++;
            }
            side_changed(current);
        }

        private void step_zoom(int dir) {
            double z = view.zoom;
            if (z <= 0) z = fit_zoom();
            double next = z;
            if (dir > 0) {
                foreach (var v in ZOOMS) if (v > z + 0.01) { next = v; break; }
            } else {
                for (int i = ZOOMS.length - 1; i >= 0; i--) if (ZOOMS[i] < z - 0.01) { next = ZOOMS[i]; break; }
            }
            set_zoom(next);
        }

        private double fit_zoom() {
            if (view.side == null) return 1;
            double aw = scroller.get_width() - 48;
            double ah = scroller.get_height() - 48;
            return double.min(aw / view.side.width, ah / view.side.height) * 72.0 / 96.0;
        }

        private void set_zoom(double z) {
            view.zoom = z;
            zoom_label.label = z <= 0 ? _("Fit") : "%d%%".printf((int) Math.round(z * 100));
            view.refresh();
        }
    }
}
