using Gtk;
using Gdk;

namespace Singularity.Widgets {

    /**
     * A floating toolbar popover that appears above selected text in a rich-text editor.
     *
     * Provides quick access to bold/italic/underline/strikethrough toggles,
     * a link insert button, text and highlight colour pickers, and paragraph
     * alignment buttons. Connect to the emitted signals to apply formatting
     * to the underlying text buffer.
     */
    public class FloatingFormatBar : Popover {
        private ToggleButton _bold_btn;
        private ToggleButton _italic_btn;
        private ToggleButton _underline_btn;
        private ToggleButton _strike_btn;
        private ColorPickerButton _text_color;
        private ColorPickerButton _highlight_color;
        private ToggleButton _align_left;
        private ToggleButton _align_center;
        private ToggleButton _align_right;
        private ToggleButton _align_justify;

        /**
         * Emitted when a formatting toggle changes state.
         * @param format_name One of `"bold"`, `"italic"`, `"underline"`, `"strikethrough"`.
         * @param active      `true` if the format was turned on, `false` if turned off.
         */
        public signal void format_toggled(string format_name, bool active);
        /**
         * Emitted when the user picks a new text or highlight colour.
         * @param kind  Either `"text"` or `"highlight"`.
         * @param color The chosen colour.
         */
        public signal void color_changed(string kind, RGBA color);
        /** Emitted when the user clicks the insert-link button. */
        public signal void link_requested();
        /**
         * Emitted when the user selects a paragraph alignment.
         * @param justification The chosen Gtk.Justification value.
         */
        public signal void alignment_changed(Gtk.Justification justification);

        public FloatingFormatBar() {
            Object();
            autohide = false;   // never steal keyboard focus from text_view
            has_arrow = false;
            add_css_class("write-format-bar");

            var box = new Box(Orientation.HORIZONTAL, 2);
            box.margin_top = 4;
            box.margin_bottom = 4;
            box.margin_start = 6;
            box.margin_end = 6;

            _bold_btn = make_toggle("format-text-bold-symbolic", "Bold (Ctrl+B)");
            _italic_btn = make_toggle("format-text-italic-symbolic", "Italic (Ctrl+I)");
            _underline_btn = make_toggle("format-text-underline-symbolic", "Underline (Ctrl+U)");
            _strike_btn = make_toggle("format-text-strikethrough-symbolic", "Strikethrough");

            _bold_btn.toggled.connect(() => format_toggled("bold", _bold_btn.active));
            _italic_btn.toggled.connect(() => format_toggled("italic", _italic_btn.active));
            _underline_btn.toggled.connect(() => format_toggled("underline", _underline_btn.active));
            _strike_btn.toggled.connect(() => format_toggled("strikethrough", _strike_btn.active));

            box.append(_bold_btn);
            box.append(_italic_btn);
            box.append(_underline_btn);
            box.append(_strike_btn);
            box.append(make_sep());

            var link_btn = new Button();
            link_btn.has_frame = false;
            link_btn.tooltip_text = "Insert Link";
            var link_img = new Image.from_icon_name("insert-link-symbolic");
            link_img.pixel_size = 16;
            link_btn.set_child(link_img);
            link_btn.clicked.connect(() => link_requested());
            box.append(link_btn);
            box.append(make_sep());

            var text_init = RGBA();
            text_init.parse("#ffffff");
            _text_color = new ColorPickerButton(text_init);
            _text_color.tooltip_text = "Text Color";
            _text_color.color_changed.connect((c) => color_changed("text", c));

            var hl_init = RGBA();
            hl_init.parse("#ffff00");
            _highlight_color = new ColorPickerButton(hl_init);
            _highlight_color.tooltip_text = "Highlight";
            _highlight_color.color_changed.connect((c) => color_changed("highlight", c));

            box.append(_text_color);
            box.append(_highlight_color);
            box.append(make_sep());

            _align_left    = make_toggle("format-justify-left-symbolic",   "Align Left");
            _align_center  = make_toggle("format-justify-center-symbolic",  "Center");
            _align_right   = make_toggle("format-justify-right-symbolic",   "Align Right");
            _align_justify = make_toggle("format-justify-fill-symbolic",    "Justify");
            _align_left.toggled.connect(() => { if (_align_left.active) alignment_changed(Gtk.Justification.LEFT); });
            _align_center.toggled.connect(() => { if (_align_center.active) alignment_changed(Gtk.Justification.CENTER); });
            _align_right.toggled.connect(() => { if (_align_right.active) alignment_changed(Gtk.Justification.RIGHT); });
            _align_justify.toggled.connect(() => { if (_align_justify.active) alignment_changed(Gtk.Justification.FILL); });
            box.append(_align_left);
            box.append(_align_center);
            box.append(_align_right);
            box.append(_align_justify);

            set_child(box);
        }

        /**
         * Programmatically updates the state of a format toggle button without
         * emitting `format_toggled`.
         *
         * @param format One of `"bold"`, `"italic"`, `"underline"`, `"strikethrough"`.
         * @param active Whether the format should appear active.
         */
        public void set_format_state(string format, bool active) {
            switch (format) {
                case "bold":          if (_bold_btn.active != active) _bold_btn.set_active(active); break;
                case "italic":        if (_italic_btn.active != active) _italic_btn.set_active(active); break;
                case "underline":     if (_underline_btn.active != active) _underline_btn.set_active(active); break;
                case "strikethrough": if (_strike_btn.active != active) _strike_btn.set_active(active); break;
            }
        }

        /**
         * Updates the alignment button group to reflect the current paragraph alignment.
         *
         * @param just The active Gtk.Justification value.
         */
        public void set_alignment(Gtk.Justification just) {
            _align_left.set_active(just == Gtk.Justification.LEFT);
            _align_center.set_active(just == Gtk.Justification.CENTER);
            _align_right.set_active(just == Gtk.Justification.RIGHT);
            _align_justify.set_active(just == Gtk.Justification.FILL);
        }

        /**
         * Pops up the bar anchored to the given rectangle in widget coordinates.
         *
         * If the popover is already visible the position is not updated, to avoid
         * dismissing child popovers (e.g. the colour picker).
         *
         * @param rect The rectangle (in the parent widget's coordinates) to point at.
         */
        public void show_at_rect(Gdk.Rectangle rect) {
            if (!visible) {
                pointing_to = rect;
                position = PositionType.TOP;
                popup();
            }
            // When already visible, don't re-set pointing_to - repositioning
            // can briefly dismiss child popovers (e.g. color picker).
        }

        private ToggleButton make_toggle(string icon, string tooltip) {
            var btn = new ToggleButton();
            btn.has_frame = false;
            btn.tooltip_text = tooltip;
            var img = new Image.from_icon_name(icon);
            img.pixel_size = 16;
            btn.set_child(img);
            return btn;
        }

        private Separator make_sep() {
            var sep = new Separator(Orientation.VERTICAL);
            sep.margin_start = 2;
            sep.margin_end = 2;
            return sep;
        }
    }
}
