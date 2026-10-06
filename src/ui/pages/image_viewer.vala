using Gtk;

namespace Singularity.Widgets {

    /**
     * A full screen image viewer with zoom and pan.
     *
     * Shows one of several images over a dark backdrop. Zoom follows the
     * pointer with Ctrl and the wheel, pinch on touchpads, the + and - keys
     * or the toolbar; a double click toggles between fitting the screen and a
     * close look at the clicked spot. Dragging pans a zoomed image, arrows
     * switch images and Escape closes. Images that are still loading show a
     * spinner and appear as soon as `set_image()` provides them.
     */
    public class ImageViewer : Gtk.Window {
        private const double MAX_ZOOM = 8.0;

        private Gdk.Paintable?[] images;
        private int current;
        private DrawingArea canvas;
        private Spinner spinner;
        private Label counter;
        private Button prev_button;
        private Button next_button;
        private double zoom = 1.0;
        private double offset_x = 0;
        private double offset_y = 0;
        private double drag_start_x = 0;
        private double drag_start_y = 0;
        private double pinch_start_zoom = 1.0;
        private double pointer_x = -1;
        private double pointer_y = -1;

        public ImageViewer(Gtk.Window? parent, Gdk.Paintable?[] images, int index) {
            this.images = images;
            current = index.clamp(0, int.max(images.length - 1, 0));
            if (parent != null) {
                transient_for = parent;
                application = parent.application;
            }
            modal = true;
            decorated = false;
            add_css_class("image-viewer");
            title = _("Image Viewer");

            var overlay = new Overlay();
            canvas = new DrawingArea();
            canvas.hexpand = true;
            canvas.vexpand = true;
            canvas.set_draw_func(draw);
            overlay.child = canvas;

            spinner = new Spinner();
            spinner.halign = Align.CENTER;
            spinner.valign = Align.CENTER;
            spinner.set_size_request(40, 40);
            overlay.add_overlay(spinner);

            var top = new Box(Orientation.HORIZONTAL, 6);
            top.add_css_class("image-viewer-bar");
            top.halign = Align.END;
            top.valign = Align.START;
            top.margin_top = 16;
            top.margin_end = 16;
            counter = new Label("");
            counter.add_css_class("image-viewer-counter");
            counter.margin_end = 6;
            top.append(counter);
            top.append(bar_button("zoom-out-symbolic", _("Zoom Out"), () => zoom_by(1 / 1.25, -1, -1)));
            top.append(bar_button("zoom-fit-best-symbolic", _("Fit to Screen"), reset_view));
            top.append(bar_button("zoom-in-symbolic", _("Zoom In"), () => zoom_by(1.25, -1, -1)));
            top.append(bar_button("window-close-symbolic", _("Close"), () => close()));
            overlay.add_overlay(top);

            prev_button = side_button("go-previous-symbolic", _("Previous"), Align.START, () => show_image(current - 1));
            next_button = side_button("go-next-symbolic", _("Next"), Align.END, () => show_image(current + 1));
            overlay.add_overlay(prev_button);
            overlay.add_overlay(next_button);

            child = overlay;
            attach_controllers();
            show_image(current);
        }

        public void set_image(int index, Gdk.Paintable paintable) {
            if (index < 0 || index >= images.length) return;
            images[index] = paintable;
            if (index == current) show_image(current);
        }

        private delegate void Action();

        private Button bar_button(string icon, string tooltip, owned Action action) {
            var button = new Button.from_icon_name(icon);
            button.add_css_class("circular");
            button.tooltip_text = tooltip;
            button.clicked.connect(() => action());
            return button;
        }

        private Button side_button(string icon, string tooltip, Align align, owned Action action) {
            var button = bar_button(icon, tooltip, (owned) action);
            button.add_css_class("image-viewer-nav");
            button.halign = align;
            button.valign = Align.CENTER;
            button.margin_start = 16;
            button.margin_end = 16;
            return button;
        }

        private void attach_controllers() {
            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, keycode, state) => {
                switch (keyval) {
                    case Gdk.Key.Escape: close(); return true;
                    case Gdk.Key.Left: show_image(current - 1); return true;
                    case Gdk.Key.Right: show_image(current + 1); return true;
                    case Gdk.Key.plus: case Gdk.Key.equal: case Gdk.Key.KP_Add:
                        zoom_by(1.25, -1, -1); return true;
                    case Gdk.Key.minus: case Gdk.Key.KP_Subtract:
                        zoom_by(1 / 1.25, -1, -1); return true;
                    case Gdk.Key.@0: case Gdk.Key.KP_0: reset_view(); return true;
                }
                return false;
            });
            ((Widget) this).add_controller(keys);

            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => {
                pointer_x = x;
                pointer_y = y;
            });
            canvas.add_controller(motion);

            var scroll = new EventControllerScroll(EventControllerScrollFlags.VERTICAL | EventControllerScrollFlags.HORIZONTAL);
            scroll.scroll.connect((dx, dy) => {
                var state = scroll.get_current_event_state();
                if ((state & Gdk.ModifierType.CONTROL_MASK) != 0 || zoom > 1.0) {
                    if ((state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                        zoom_by(dy < 0 ? 1.1 : 1 / 1.1, pointer_x, pointer_y);
                    } else {
                        offset_x -= dx * 20;
                        offset_y -= dy * 20;
                        clamp_offset();
                        canvas.queue_draw();
                    }
                    return true;
                }
                return false;
            });
            canvas.add_controller(scroll);

            var pinch = new GestureZoom();
            pinch.begin.connect(() => pinch_start_zoom = zoom);
            pinch.scale_changed.connect((scale) => {
                double cx, cy;
                pinch.get_bounding_box_center(out cx, out cy);
                set_zoom(pinch_start_zoom * scale, cx, cy);
            });
            canvas.add_controller(pinch);

            var drag = new GestureDrag();
            drag.drag_begin.connect(() => {
                drag_start_x = offset_x;
                drag_start_y = offset_y;
            });
            drag.drag_update.connect((x, y) => {
                if (zoom <= 1.0) return;
                offset_x = drag_start_x + x;
                offset_y = drag_start_y + y;
                clamp_offset();
                canvas.queue_draw();
            });
            canvas.add_controller(drag);

            var click = new GestureClick();
            click.pressed.connect((n, x, y) => {
                if (n != 2) return;
                if (zoom > 1.0) reset_view();
                else set_zoom(2.5, x, y);
            });
            canvas.add_controller(click);
        }

        private void show_image(int index) {
            if (images.length == 0) return;
            current = (index + images.length) % images.length;
            bool multiple = images.length > 1;
            prev_button.visible = multiple;
            next_button.visible = multiple;
            counter.label = multiple ? "%d / %d".printf(current + 1, images.length) : "";
            bool loaded = images[current] != null;
            spinner.spinning = !loaded;
            spinner.visible = !loaded;
            reset_view();
        }

        private void reset_view() {
            zoom = 1.0;
            offset_x = 0;
            offset_y = 0;
            canvas.queue_draw();
        }

        private void fit(out double width, out double height) {
            width = 0;
            height = 0;
            var image = images[current];
            if (image == null) return;
            double iw = image.get_intrinsic_width();
            double ih = image.get_intrinsic_height();
            if (iw <= 0 || ih <= 0) return;
            double available_w = canvas.get_width() * 0.92;
            double available_h = canvas.get_height() * 0.88;
            double scale = double.min(available_w / iw, available_h / ih);
            width = iw * scale;
            height = ih * scale;
        }

        private void zoom_by(double factor, double x, double y) {
            set_zoom(zoom * factor, x, y);
        }

        private void set_zoom(double value, double x, double y) {
            double next = value.clamp(1.0, MAX_ZOOM);
            if (x < 0 || y < 0) {
                x = canvas.get_width() / 2.0;
                y = canvas.get_height() / 2.0;
            }
            double cx = canvas.get_width() / 2.0 + offset_x;
            double cy = canvas.get_height() / 2.0 + offset_y;
            double ratio = next / zoom;
            offset_x += (x - cx) * (1 - ratio);
            offset_y += (y - cy) * (1 - ratio);
            zoom = next;
            if (zoom <= 1.0) {
                offset_x = 0;
                offset_y = 0;
            }
            clamp_offset();
            canvas.queue_draw();
        }

        private void clamp_offset() {
            double fw, fh;
            fit(out fw, out fh);
            double max_x = double.max((fw * zoom - canvas.get_width()) / 2.0, 0);
            double max_y = double.max((fh * zoom - canvas.get_height()) / 2.0, 0);
            offset_x = offset_x.clamp(-max_x, max_x);
            offset_y = offset_y.clamp(-max_y, max_y);
        }

        private void draw(DrawingArea area, Cairo.Context cr, int width, int height) {
            cr.set_source_rgba(0, 0, 0, 0.92);
            cr.paint();
            var image = images[current];
            if (image == null) return;
            double fw, fh;
            fit(out fw, out fh);
            if (fw <= 0) return;
            double w = fw * zoom;
            double h = fh * zoom;
            var snapshot = new Gtk.Snapshot();
            image.snapshot(snapshot, w, h);
            var node = snapshot.free_to_node();
            if (node == null) return;
            cr.save();
            cr.translate((width - w) / 2.0 + offset_x, (height - h) / 2.0 + offset_y);
            node.draw(cr);
            cr.restore();
        }
    }
}
