using Gtk;
using Singularity.Annotations;

namespace Singularity.Widgets {

    public class MarkupEditor : Box {
        private const string[] PALETTE = { "#e01b24", "#ff7800", "#f6d32d", "#33d17a", "#3584e4", "#9141ac", "#000000", "#ffffff" };

        private Overlay overlay;
        private Gee.HashMap<Tool, ToggleButton> tool_buttons = new Gee.HashMap<Tool, ToggleButton>();
        private Button undo_button;
        private Button redo_button;
        private Button style_button;
        private Box style_swatch;
        private Popover style_popover;
        private Box redact_row;
        private Box toolbar;
        private Entry? text_entry = null;
        private TextItem? editing_text = null;
        private double text_x;
        private double text_y;
        private bool syncing = false;

        public MarkupCanvas canvas { get; private set; }
        public LiveTextSession live_text { get; private set; }
        public Document document { get; private set; }

        public signal void copied(string what);

        public MarkupEditor(Document document) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.document = document;
            build();
            canvas.document = document;
            document.changed.connect(sync_history);
            sync_history();
            live_text.set_texture(source_texture());
            document.changed.connect(() => {
                string key = redaction_key();
                if (key == redaction_signature) return;
                redaction_signature = key;
                live_text.set_texture(source_texture());
            });
        }

        private string redaction_signature = "";

        private string redaction_key() {
            var key = new StringBuilder();
            foreach (var item in document.items) {
                if (item is RedactItem) {
                    var b = item.bounds();
                    key.append("%d,%d,%d,%d,%d;".printf((int) b.x, (int) b.y, (int) b.width, (int) b.height, (int) ((RedactItem) item).style));
                }
            }
            return key.str;
        }

        private Gdk.Texture source_texture() {
            var surface = document.redacted_source();
            var bytes = new Bytes(surface.get_data()[0:surface.get_stride() * surface.get_height()]);
            return new Gdk.MemoryTexture(surface.get_width(), surface.get_height(), Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, surface.get_stride());
        }

        private void build() {
            add_css_class("markup-editor");
            hexpand = true;
            vexpand = true;

            overlay = new Overlay();
            overlay.hexpand = true;
            overlay.vexpand = true;
            append(overlay);

            canvas = new MarkupCanvas();
            canvas.bottom_inset = 64;
            canvas.top_inset = 44;
            canvas.text_requested.connect(begin_text);
            overlay.child = canvas;

            live_text = new LiveTextSession();
            live_text.view.set_geometry_func((out ox, out oy, out scale) => canvas.image_geometry(out ox, out oy, out scale));
            canvas.geometry_changed.connect(() => live_text.view.queue_draw());
            overlay.add_overlay(live_text.view);
            live_text.bar.valign = Align.END;
            live_text.bar.margin_bottom = 72;
            overlay.add_overlay(live_text.bar);
            live_text.toggle.toggled.connect(() => {
                if (live_text.active && canvas.tool != Tool.SELECT) set_tool(Tool.SELECT);
                canvas.can_target = !live_text.active;
            });

            toolbar = new Box(Orientation.HORIZONTAL, 2);
            toolbar.add_css_class("markup-toolbar");
            toolbar.halign = Align.CENTER;
            toolbar.valign = Align.END;
            toolbar.margin_bottom = 16;
            overlay.add_overlay(toolbar);

            add_tool(Tool.SELECT, "singularity-markup-select-symbolic", _("Select and Move (V)"));
            add_separator();
            add_tool(Tool.ARROW, "singularity-markup-arrow-symbolic", _("Arrow (A)"));
            add_tool(Tool.RECTANGLE, "singularity-markup-rectangle-symbolic", _("Rectangle (R)"));
            add_tool(Tool.ELLIPSE, "singularity-markup-ellipse-symbolic", _("Ellipse (O)"));
            add_tool(Tool.PEN, "singularity-markup-pen-symbolic", _("Pen (P)"));
            add_tool(Tool.HIGHLIGHTER, "singularity-markup-highlighter-symbolic", _("Highlighter (H)"));
            add_tool(Tool.TEXT, "singularity-markup-text-symbolic", _("Text (T)"));
            add_tool(Tool.STEP, "singularity-markup-step-symbolic", _("Numbered Step (N)"));
            add_tool(Tool.REDACT, "singularity-markup-redact-symbolic", _("Redact (B)"));
            add_tool(Tool.CROP, "singularity-markup-crop-symbolic", _("Crop (C)"));
            add_separator();

            style_button = new Button();
            style_button.add_css_class("flat");
            style_button.add_css_class("markup-style-button");
            style_button.tooltip_text = _("Color and Size");
            style_swatch = new Box(Orientation.HORIZONTAL, 0);
            style_swatch.add_css_class("markup-swatch");
            style_swatch.valign = Align.CENTER;
            style_swatch.halign = Align.CENTER;
            style_button.child = style_swatch;
            style_popover = build_style_popover();
            style_popover.set_parent(style_button);
            style_button.clicked.connect(() => style_popover.popup());
            toolbar.append(style_button);
            add_separator();

            undo_button = new Button.from_icon_name("edit-undo-symbolic");
            undo_button.add_css_class("flat");
            undo_button.tooltip_text = _("Undo (Ctrl+Z)");
            undo_button.clicked.connect(() => document.undo());
            toolbar.append(undo_button);
            redo_button = new Button.from_icon_name("edit-redo-symbolic");
            redo_button.add_css_class("flat");
            redo_button.tooltip_text = _("Redo (Shift+Ctrl+Z)");
            redo_button.clicked.connect(() => document.redo());
            toolbar.append(redo_button);
            add_separator();
            live_text.toggle.tooltip_text = _("Live Text: select text in the image");
            toolbar.append(live_text.toggle);

            set_tool(Tool.ARROW);
            update_swatch();
            canvas.notify["color"].connect(update_swatch);

            var keys = new EventControllerKey();
            keys.set_propagation_phase(PropagationPhase.BUBBLE);
            keys.key_pressed.connect(on_key);
            add_controller(keys);
        }

        private void add_separator() {
            var sep = new Box(Orientation.VERTICAL, 0);
            sep.add_css_class("markup-toolbar-sep");
            toolbar.append(sep);
        }

        private void add_tool(Tool tool, string icon, string tooltip) {
            var button = new ToggleButton();
            button.icon_name = icon;
            button.tooltip_text = tooltip;
            button.add_css_class("flat");
            button.add_css_class("markup-tool");
            button.toggled.connect(() => {
                if (syncing) return;
                if (button.active) set_tool(tool);
                else if (canvas.tool == tool) {
                    syncing = true;
                    button.active = true;
                    syncing = false;
                }
            });
            tool_buttons[tool] = button;
            toolbar.append(button);
        }

        public void set_tool(Tool tool) {
            commit_text();
            if (live_text.active && tool != Tool.SELECT) live_text.active = false;
            canvas.tool = tool;
            syncing = true;
            foreach (var entry in tool_buttons.entries) entry.value.active = entry.key == tool;
            syncing = false;
            redact_row.visible = tool == Tool.REDACT;
        }

        private Popover build_style_popover() {
            var popover = new Popover();
            popover.has_arrow = false;
            popover.position = PositionType.TOP;
            popover.add_css_class("markup-style-popover");
            var box = new Box(Orientation.VERTICAL, 12);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 12;
            box.margin_end = 12;

            var colors = new Box(Orientation.HORIZONTAL, 6);
            foreach (var spec in PALETTE) {
                var rgba = Gdk.RGBA();
                rgba.parse(spec);
                var swatch = new Button();
                swatch.add_css_class("markup-color");
                swatch.tooltip_text = color_name(spec);
                var dot = new Box(Orientation.HORIZONTAL, 0);
                dot.add_css_class("markup-color-dot");
                dot.add_css_class(color_class(spec));
                swatch.child = dot;
                swatch.clicked.connect(() => {
                    canvas.color = rgba;
                    popover.popdown();
                });
                colors.append(swatch);
            }
            box.append(colors);

            var sizes = new Box(Orientation.HORIZONTAL, 6);
            sizes.add_css_class("markup-choices");
            sizes.halign = Align.CENTER;
            ToggleButton? size_group = null;
            string[] size_ids = { "s", "m", "l" };
            string[] size_names = { _("Thin"), _("Medium"), _("Thick") };
            double[] size_values = { 2, 4, 8 };
            for (int i = 0; i < 3; i++) {
                double value = size_values[i];
                var button = new ToggleButton();
                button.add_css_class("markup-choice");
                button.tooltip_text = size_names[i];
                var dot = new Box(Orientation.HORIZONTAL, 0);
                dot.add_css_class("markup-size-" + size_ids[i]);
                dot.halign = Align.CENTER;
                dot.valign = Align.CENTER;
                button.child = dot;
                if (size_group == null) size_group = button; else button.group = size_group;
                button.active = value == canvas.stroke;
                button.toggled.connect(() => {
                    if (button.active) canvas.stroke = value;
                });
                sizes.append(button);
            }
            box.append(sizes);

            redact_row = new Box(Orientation.HORIZONTAL, 6);
            redact_row.add_css_class("markup-choices");
            redact_row.halign = Align.CENTER;
            var pixelate = new ToggleButton.with_label(_("Pixelate"));
            pixelate.add_css_class("markup-choice");
            pixelate.active = true;
            pixelate.toggled.connect(() => {
                if (pixelate.active) canvas.redact_style = RedactStyle.PIXELATE;
            });
            var blur = new ToggleButton.with_label(_("Blur"));
            blur.add_css_class("markup-choice");
            blur.group = pixelate;
            blur.toggled.connect(() => {
                if (blur.active) canvas.redact_style = RedactStyle.BLUR;
            });
            redact_row.append(pixelate);
            redact_row.append(blur);
            box.append(redact_row);

            popover.child = box;
            return popover;
        }

        private static string color_name(string spec) {
            switch (spec) {
                case "#e01b24": return _("Red");
                case "#ff7800": return _("Orange");
                case "#f6d32d": return _("Yellow");
                case "#33d17a": return _("Green");
                case "#3584e4": return _("Blue");
                case "#9141ac": return _("Purple");
                case "#000000": return _("Black");
                default: return _("White");
            }
        }

        private static string color_class(string spec) {
            for (int i = 0; i < PALETTE.length; i++) {
                if (PALETTE[i] == spec) return "markup-color-%d".printf(i);
            }
            return "markup-color-0";
        }

        private void update_swatch() {
            for (int i = 0; i < PALETTE.length; i++) style_swatch.remove_css_class("markup-color-%d".printf(i));
            var c = canvas.color;
            string spec = "#%02x%02x%02x".printf((uint) Math.round(c.red * 255), (uint) Math.round(c.green * 255), (uint) Math.round(c.blue * 255));
            style_swatch.add_css_class(color_class(spec));
        }

        private void sync_history() {
            undo_button.sensitive = document.can_undo;
            redo_button.sensitive = document.can_redo;
        }

        private bool on_key(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (text_entry != null) return false;
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            if (ctrl && (keyval == Gdk.Key.z || keyval == Gdk.Key.Z)) {
                if (shift) document.redo(); else document.undo();
                return true;
            }
            if (ctrl && (keyval == Gdk.Key.y || keyval == Gdk.Key.Y)) {
                document.redo();
                return true;
            }
            if (ctrl || (state & Gdk.ModifierType.ALT_MASK) != 0) return false;
            if (live_text.active) return false;
            switch (keyval) {
                case Gdk.Key.Delete:
                case Gdk.Key.BackSpace:
                    canvas.delete_selected();
                    return true;
                case Gdk.Key.v: set_tool(Tool.SELECT); return true;
                case Gdk.Key.a: set_tool(Tool.ARROW); return true;
                case Gdk.Key.r: set_tool(Tool.RECTANGLE); return true;
                case Gdk.Key.o: set_tool(Tool.ELLIPSE); return true;
                case Gdk.Key.p: set_tool(Tool.PEN); return true;
                case Gdk.Key.h: set_tool(Tool.HIGHLIGHTER); return true;
                case Gdk.Key.t: set_tool(Tool.TEXT); return true;
                case Gdk.Key.n: set_tool(Tool.STEP); return true;
                case Gdk.Key.b: set_tool(Tool.REDACT); return true;
                case Gdk.Key.c: set_tool(Tool.CROP); return true;
                default: return false;
            }
        }

        private void begin_text(double ix, double iy, TextItem? existing) {
            commit_text();
            editing_text = existing;
            text_x = existing != null ? existing.x : ix;
            text_y = existing != null ? existing.y : iy - (12 + canvas.stroke * 3) / 2;
            double vx, vy;
            canvas.to_view(text_x, text_y, out vx, out vy);
            text_entry = new Entry();
            text_entry.add_css_class("markup-text-entry");
            text_entry.placeholder_text = _("Type text");
            text_entry.width_chars = 16;
            text_entry.halign = Align.START;
            text_entry.valign = Align.START;
            text_entry.margin_start = int.max(0, (int) vx - 6);
            text_entry.margin_top = int.max(0, (int) vy - 6);
            if (existing != null) text_entry.text = existing.text;
            text_entry.activate.connect(() => commit_text());
            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval) => {
                if (keyval == Gdk.Key.Escape) {
                    cancel_text();
                    return true;
                }
                return false;
            });
            text_entry.add_controller(keys);
            var focus = new EventControllerFocus();
            focus.leave.connect(() => Idle.add(() => { commit_text(); return Source.REMOVE; }));
            text_entry.add_controller(focus);
            overlay.add_overlay(text_entry);
            text_entry.grab_focus();
        }

        private void cancel_text() {
            if (text_entry == null) return;
            var entry = text_entry;
            text_entry = null;
            editing_text = null;
            overlay.remove_overlay(entry);
            canvas.grab_focus();
        }

        public void commit_text() {
            if (text_entry == null) return;
            var entry = text_entry;
            text_entry = null;
            string value = entry.text.strip();
            overlay.remove_overlay(entry);
            if (editing_text != null) {
                if (value == "") {
                    document.remove(editing_text);
                } else if (value != editing_text.text) {
                    document.checkpoint();
                    editing_text.text = value;
                    document.touch();
                }
            } else if (value != "") {
                var item = new TextItem();
                item.color = canvas.color;
                item.stroke = canvas.stroke;
                item.x = text_x;
                item.y = text_y;
                item.text = value;
                document.add(item);
            }
            editing_text = null;
            canvas.grab_focus();
        }

        public bool copy_image() {
            commit_text();
            if (live_text.active && live_text.view.copy_selection()) return true;
            get_clipboard().set_texture(document.to_texture());
            copied(_("Image copied"));
            return true;
        }
    }
}
