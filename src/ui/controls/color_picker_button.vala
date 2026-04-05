using Gtk;
using Gdk;

namespace Singularity.Widgets {

    /**
     * A compact button that opens an inline colour-picker popover.
     *
     * Shows a small colour swatch; clicking it opens a ColorChooserWidget
     * inside a popover. When the user picks a colour the swatch updates
     * immediately and `color_changed` is emitted.
     */
    public class ColorPickerButton : Button {
        private DrawingArea _swatch;
        private Popover _popover;
        private ColorChooserWidget _chooser;
        private RGBA _color;

        /** The currently selected colour. Setting this updates the swatch immediately. */
        public RGBA color {
            get { return _color; }
            set {
                _color = value;
                _swatch.queue_draw();
                _chooser.rgba = value;
            }
        }

        /** Emitted when the user confirms a new colour selection. */
        public signal void color_changed(RGBA new_color);

        /**
         * Creates a new colour-picker button.
         *
         * @param initial Initial colour to display; defaults to opaque black if `null`.
         */
        public ColorPickerButton(RGBA? initial = null) {
            Object();
            has_frame = false;
            add_css_class("singularity-button");
            add_css_class("color-picker-button");

            _color = RGBA();
            if (initial != null)
                _color = initial;
            else
                _color.parse("#000000");

            _swatch = new DrawingArea();
            _swatch.set_size_request(18, 18);
            _swatch.set_draw_func((da, cr, w, h) => {
                cr.set_source_rgba(_color.red, _color.green, _color.blue, _color.alpha);
                draw_rounded_rect(cr, 1, 1, w - 2, h - 2, 3);
                cr.fill();
                cr.set_source_rgba(0, 0, 0, 0.3);
                cr.set_line_width(1.0);
                draw_rounded_rect(cr, 1, 1, w - 2, h - 2, 3);
                cr.stroke();
            });
            set_child(_swatch);

            _chooser = new ColorChooserWidget();
            _chooser.rgba = _color;
            _chooser.use_alpha = false;
            _chooser.margin_top = 6;
            _chooser.margin_bottom = 6;
            _chooser.margin_start = 6;
            _chooser.margin_end = 6;
            _chooser.color_activated.connect((c) => {
                _color = c;
                _swatch.queue_draw();
                color_changed(c);
                _popover.popdown();
            });

            _popover = new Popover();
            _popover.set_parent(this);
            _popover.set_child(_chooser);

            clicked.connect(() => {
                _chooser.rgba = _color;
                _popover.popup();
            });
        }

        private void draw_rounded_rect(Cairo.Context cr, double x, double y,
                                        double w, double h, double r) {
            cr.move_to(x + r, y);
            cr.line_to(x + w - r, y);
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.line_to(x + w, y + h - r);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.line_to(x + r, y + h);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.line_to(x, y + r);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }
    }
}
