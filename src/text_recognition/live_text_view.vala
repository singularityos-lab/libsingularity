using Gtk;
using Singularity.TextRecognition;

namespace Singularity.Widgets {

    public delegate bool LiveTextGeometry(out double origin_x, out double origin_y, out double scale);

    public class LiveTextView : Widget {
        private RecognizedText? result = null;
        private Gee.List<DetectedData> data = new Gee.ArrayList<DetectedData>();
        private Gee.List<TextRange> matches = new Gee.ArrayList<TextRange>();
        private int anchor = -1;
        private int focus_word = -1;
        private bool dragging = false;
        private bool drag_moved = false;
        private LiveTextGeometry? geometry_func = null;
        private ContextMenu? menu = null;

        public signal void selection_changed();
        public signal void copied(string text);

        public bool has_selection {
            get { return anchor >= 0 && focus_word >= 0; }
        }

        public string selected_text {
            owned get { return result != null && has_selection ? result.text_between(anchor, focus_word) : ""; }
        }

        public RecognizedText? recognized {
            get { return result; }
        }

        public Gee.List<DetectedData> detected {
            get { return data; }
        }

        public int match_count {
            get { return matches.size; }
        }

        construct {
            focusable = true;
            can_focus = true;
            hexpand = true;
            vexpand = true;
            add_css_class("live-text-view");

            var drag = new GestureDrag();
            drag.button = Gdk.BUTTON_PRIMARY;
            drag.drag_begin.connect((x, y) => {
                grab_focus();
                if (result == null) return;
                double ix, iy;
                to_image(x, y, out ix, out iy);
                int word = result.nearest_word(ix, iy);
                dragging = word >= 0;
                drag_moved = false;
                if (!dragging) return;
                drag.set_state(EventSequenceState.CLAIMED);
            });
            drag.drag_update.connect((ox, oy) => {
                if (!dragging || result == null) return;
                if (!drag_moved && Math.fabs(ox) + Math.fabs(oy) < 3) return;
                double sx, sy;
                drag.get_start_point(out sx, out sy);
                double ix, iy, jx, jy;
                to_image(sx, sy, out ix, out iy);
                to_image(sx + ox, sy + oy, out jx, out jy);
                if (!drag_moved) anchor = result.nearest_word(ix, iy);
                drag_moved = true;
                focus_word = result.nearest_word(jx, jy);
                queue_draw();
                selection_changed();
            });
            drag.drag_end.connect(() => {
                dragging = false;
            });
            add_controller(drag);

            var click = new GestureClick();
            click.button = Gdk.BUTTON_PRIMARY;
            click.released.connect((n, x, y) => {
                if (result == null || drag_moved) return;
                double ix, iy;
                to_image(x, y, out ix, out iy);
                int word = result.word_at(ix, iy, 4);
                if (n == 1) {
                    var item = data_at(word);
                    if (item != null) {
                        activate_data(item);
                        return;
                    }
                    if (word < 0 || (has_selection && anchor != focus_word)) {
                        clear_selection();
                        return;
                    }
                }
                if (word < 0) return;
                if (n == 2) {
                    select_range(word, word);
                } else if (n >= 3) {
                    var line = result.lines[result.words[word].line];
                    select_range(line.words[0].index, line.words[line.words.size - 1].index);
                }
            });
            add_controller(click);

            var context = new GestureClick();
            context.button = Gdk.BUTTON_SECONDARY;
            context.pressed.connect((n, x, y) => {
                if (result == null) return;
                double ix, iy;
                to_image(x, y, out ix, out iy);
                int word = result.word_at(ix, iy, 4);
                if (word < 0) return;
                context.set_state(EventSequenceState.CLAIMED);
                if (!has_selection || word < int.min(anchor, focus_word) || word > int.max(anchor, focus_word)) {
                    select_range(word, word);
                }
                show_menu(x, y, data_at(word));
            });
            add_controller(context);

            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => {
                if (result == null) {
                    set_cursor(null);
                    return;
                }
                double ix, iy;
                to_image(x, y, out ix, out iy);
                int word = result.word_at(ix, iy, 4);
                if (data_at(word) != null) set_cursor_from_name("pointer");
                else if (word >= 0) set_cursor_from_name("text");
                else set_cursor(null);
            });
            add_controller(motion);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, keycode, state) => {
                bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
                if (ctrl && (keyval == Gdk.Key.c || keyval == Gdk.Key.C)) {
                    return copy_selection();
                }
                if (ctrl && (keyval == Gdk.Key.a || keyval == Gdk.Key.A)) {
                    select_all();
                    return true;
                }
                if (keyval == Gdk.Key.Escape && has_selection) {
                    clear_selection();
                    return true;
                }
                return false;
            });
            add_controller(keys);
        }

        public void set_geometry_func(owned LiveTextGeometry func) {
            geometry_func = (owned) func;
            queue_draw();
        }

        public void set_result(RecognizedText? text) {
            result = text;
            data = new Gee.ArrayList<DetectedData>();
            if (text != null) {
                bool calendar = Capabilities.available(Contracts.CALENDAR);
                foreach (var item in text.detect_data()) {
                    if (item.kind != DataKind.DATE || calendar) data.add(item);
                }
            }
            matches = new Gee.ArrayList<TextRange>();
            anchor = -1;
            focus_word = -1;
            queue_draw();
            selection_changed();
        }

        public void select_range(int first, int last) {
            if (result == null || result.is_empty) return;
            anchor = first.clamp(0, result.words.size - 1);
            focus_word = last.clamp(0, result.words.size - 1);
            queue_draw();
            selection_changed();
        }

        public void select_all() {
            if (result == null || result.is_empty) return;
            select_range(0, result.words.size - 1);
        }

        public void clear_selection() {
            anchor = -1;
            focus_word = -1;
            queue_draw();
            selection_changed();
        }

        public int search(string query) {
            matches = result != null ? result.find(query) : new Gee.ArrayList<TextRange>();
            if (matches.size > 0) select_range(matches[0].first, matches[0].last);
            queue_draw();
            return matches.size;
        }

        public bool copy_selection() {
            string text = selected_text;
            if (text == "") return false;
            copy_text(text);
            return true;
        }

        public void copy_all() {
            if (result == null || result.is_empty) return;
            copy_text(result.text);
        }

        private void copy_text(string text) {
            get_clipboard().set_text(text);
            copied(text);
        }

        public void activate_data(DetectedData item) {
            if (item.kind == DataKind.DATE) {
                Capabilities.call_and_forget(Contracts.CALENDAR, "NewEventAt", new Variant("(xbs)", item.when, item.timed, ""));
                return;
            }
            var root = get_root() as Gtk.Window;
            new UriLauncher(item.uri).launch.begin(root, null, (obj, res) => {
                try {
                    ((UriLauncher) obj).launch.end(res);
                } catch (Error e) {
                    warning("Live Text: %s", e.message);
                }
            });
        }

        private DetectedData? data_at(int word) {
            if (word < 0) return null;
            foreach (var item in data) {
                if (word >= item.first_word && word <= item.last_word) return item;
            }
            return null;
        }

        private void show_menu(double x, double y, DetectedData? item) {
            if (menu != null) menu.unparent();
            menu = new ContextMenu(this);
            if (item != null && item.kind == DataKind.DATE) {
                menu.add_item(_("Create Event"), item.kind.icon_name(), () => activate_data(item));
                menu.add_item(_("Show in Calendar"), "x-office-calendar-symbolic", () => {
                    Capabilities.call_and_forget(Contracts.CALENDAR, "ShowDay", new Variant("(x)", item.when));
                });
                menu.add_item(_("Copy Date"), "edit-copy-symbolic", () => copy_text(item.text));
                menu.add_separator();
            } else if (item != null) {
                string open_label = item.kind == DataKind.EMAIL ? _("Send Email") : (item.kind == DataKind.PHONE ? _("Call") : _("Open Link"));
                menu.add_item(open_label, item.kind.icon_name(), () => activate_data(item));
                string copy_label = item.kind == DataKind.EMAIL ? _("Copy Email Address") : (item.kind == DataKind.PHONE ? _("Copy Phone Number") : _("Copy Link"));
                menu.add_item(copy_label, "edit-copy-symbolic", () => copy_text(item.text));
                menu.add_separator();
            }
            menu.add_item(_("Copy"), "edit-copy-symbolic", () => copy_selection());
            menu.add_item(_("Select All"), "edit-select-all-symbolic", () => select_all());
            string chosen = selected_text.strip();
            if (chosen != "") {
                menu.add_separator();
                if (Capabilities.available(Contracts.TRANSLATE)) {
                    menu.add_item(_("Translate"), "accessories-dictionary-symbolic", () => {
                        Capabilities.call_and_forget(Contracts.TRANSLATE, "Translate", new Variant("(s)", chosen));
                    });
                }
                if (Capabilities.available(Contracts.TASKS)) {
                    menu.add_item(_("Add to Tasks"), "object-select-symbolic", () => {
                        Capabilities.call_and_forget(Contracts.TASKS, "AddTask", new Variant("(s)", chosen));
                    });
                }
                if (AppInfo.get_default_for_uri_scheme("geo") != null) {
                    menu.add_item(_("Show on Map"), "mark-location-symbolic", () => {
                        new UriLauncher("geo:0,0?q=" + Uri.escape_string(chosen.replace("\n", ", "), null, false)).launch.begin(get_root() as Gtk.Window, null);
                    });
                }
                if (Notes.NotePicker.available()) {
                    Gdk.Rectangle at = { (int) x, (int) y, 1, 1 };
                    menu.add_item(_("Add to a Note…"), "document-send-symbolic", () => {
                        Idle.add(() => {
                            Notes.NotePicker.popup(this, (id) => {
                                Notes.NotePicker.add.begin(id, _("Text from an Image"), chosen + "\n", (obj, res) => {
                                    try {
                                        Notes.NotePicker.add.end(res);
                                    } catch (Error e) {
                                        warning("Live Text: %s", e.message);
                                    }
                                });
                            }, null, at);
                            return Source.REMOVE;
                        });
                    });
                }
            }
            Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
            menu.set_pointing_to(rect);
            menu.popup();
        }

        private bool geometry(out double ox, out double oy, out double scale) {
            if (geometry_func != null) return geometry_func(out ox, out oy, out scale);
            ox = 0;
            oy = 0;
            scale = 1;
            if (result == null || result.image_width == 0 || result.image_height == 0) return false;
            double w = get_width(), h = get_height();
            scale = double.min(w / result.image_width, h / result.image_height);
            ox = (w - result.image_width * scale) / 2;
            oy = (h - result.image_height * scale) / 2;
            return true;
        }

        private void to_image(double x, double y, out double ix, out double iy) {
            double ox, oy, scale;
            geometry(out ox, out oy, out scale);
            if (scale <= 0) scale = 1;
            ix = (x - ox) / scale;
            iy = (y - oy) / scale;
        }

        public override bool contains(double x, double y) {
            if (result == null || result.is_empty) return false;
            if (dragging) return true;
            double ix, iy;
            to_image(x, y, out ix, out iy);
            double ox, oy, scale;
            geometry(out ox, out oy, out scale);
            return result.word_at(ix, iy, 6 / double.max(scale, 0.05)) >= 0;
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            if (result == null || result.is_empty) return;
            double ox, oy, scale;
            if (!geometry(out ox, out oy, out scale)) return;
            var cr = snapshot.append_cairo({ { 0, 0 }, { get_width(), get_height() } });
            var style_accent = Gdk.RGBA();
            style_accent.parse("#3584e4");
            cr.translate(ox, oy);
            foreach (var line in result.lines) {
                double pad = double.max(2, line.height * 0.18);
                rounded(cr, line.x * scale - pad, line.y * scale - pad, line.width * scale + pad * 2, line.height * scale + pad * 2, 4);
                cr.set_source_rgba(1, 1, 1, 0.16);
                cr.fill_preserve();
                cr.set_source_rgba(1, 1, 1, 0.55);
                cr.set_line_width(1);
                cr.stroke();
            }
            foreach (var range in matches) {
                for (int i = range.first; i <= range.last; i++) {
                    var w = result.words[i];
                    rounded(cr, w.x * scale - 1, w.y * scale - 1, w.width * scale + 2, w.height * scale + 2, 3);
                    cr.set_source_rgba(0.96, 0.83, 0.18, 0.45);
                    cr.fill();
                }
            }
            if (has_selection) {
                int a = int.min(anchor, focus_word), b = int.max(anchor, focus_word);
                for (int i = a; i <= b; i++) {
                    var w = result.words[i];
                    double x1 = w.x, x2 = w.x + w.width;
                    if (i < b && result.words[i + 1].line == w.line) x2 = result.words[i + 1].x;
                    cr.rectangle(x1 * scale, w.y * scale - 1, (x2 - x1) * scale, w.height * scale + 2);
                }
                cr.set_source_rgba(style_accent.red, style_accent.green, style_accent.blue, 0.38);
                cr.fill();
            }
            foreach (var item in data) {
                for (int i = item.first_word; i <= item.last_word; i++) {
                    var w = result.words[i];
                    cr.rectangle(w.x * scale, (w.y + w.height) * scale + 1, w.width * scale + (i < item.last_word ? 4 * scale : 0), double.max(1.5, 2 * scale));
                }
                cr.set_source_rgba(style_accent.red, style_accent.green, style_accent.blue, 0.95);
                cr.fill();
            }
        }

        private static void rounded(Cairo.Context cr, double x, double y, double w, double h, double r) {
            r = double.min(r, double.min(w, h) / 2);
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }

        public override void dispose() {
            if (menu != null) {
                menu.unparent();
                menu = null;
            }
            base.dispose();
        }
    }

    public class LiveTextSession : Object {
        private Cancellable? cancellable = null;
        private uint generation = 0;
        private Gdk.Texture? texture = null;
        private Box status_box;
        private Spinner spinner;
        private Label status_label;
        private Box actions_box;
        private Box data_box;
        private Singularity.Widgets.SearchEntry search_entry;
        private Label hint_label;

        public LiveTextView view { get; private set; }
        public ToggleButton toggle { get; private set; }
        public Box bar { get; private set; }
        public Recognizer recognizer { get; private set; }

        public bool active {
            get { return toggle.active; }
            set { toggle.active = value; }
        }

        public signal void copied(string text);

        public LiveTextSession(Recognizer? recognizer = null) {
            Object();
            this.recognizer = recognizer ?? Recognizer.get_default();
            build();
        }

        private void build() {
            view = new LiveTextView();
            view.visible = false;
            view.copied.connect((t) => {
                flash_copied();
                copied(t);
            });

            toggle = new ToggleButton();
            toggle.icon_name = "singularity-live-text-symbolic";
            toggle.tooltip_text = _("Live Text");
            toggle.add_css_class("flat");
            toggle.add_css_class("live-text-toggle");
            toggle.toggled.connect(on_toggled);

            bar = new Box(Orientation.HORIZONTAL, 8);
            bar.add_css_class("live-text-bar");
            bar.halign = Align.CENTER;
            bar.visible = false;

            status_box = new Box(Orientation.HORIZONTAL, 8);
            status_box.valign = Align.CENTER;
            spinner = new Spinner();
            status_box.append(spinner);
            var status_text = new Box(Orientation.VERTICAL, 2);
            status_label = new Label("");
            status_label.add_css_class("live-text-status");
            status_label.xalign = 0;
            status_text.append(status_label);
            hint_label = new Label("");
            hint_label.add_css_class("caption");
            hint_label.add_css_class("dim-label");
            hint_label.wrap = true;
            hint_label.max_width_chars = 44;
            hint_label.xalign = 0;
            hint_label.visible = false;
            status_text.append(hint_label);
            status_box.append(status_text);
            bar.append(status_box);

            actions_box = new Box(Orientation.HORIZONTAL, 6);
            actions_box.valign = Align.CENTER;
            search_entry = new Singularity.Widgets.SearchEntry();
            search_entry.placeholder_text = _("Find in Image");
            search_entry.entry.width_chars = 14;
            search_entry.search_changed.connect((entry) => {
                int n = view.search(entry.text);
                if (entry.text.strip() == "") set_status(summary(), false);
                else set_status(n == 0 ? _("No matches") : ngettext("%d match", "%d matches", n).printf(n), false);
            });
            actions_box.append(search_entry);
            var copy_all = new Button.with_label(_("Copy All"));
            copy_all.add_css_class("pill");
            copy_all.clicked.connect(() => view.copy_all());
            actions_box.append(copy_all);
            data_box = new Box(Orientation.HORIZONTAL, 6);
            actions_box.append(data_box);
            bar.append(actions_box);
        }

        private uint copied_id = 0;

        private void flash_copied() {
            set_status(_("Copied"), false);
            if (copied_id != 0) Source.remove(copied_id);
            copied_id = Timeout.add(1500, () => {
                copied_id = 0;
                set_status(summary(), false);
                return Source.REMOVE;
            });
        }

        private string summary() {
            var r = view.recognized;
            if (r == null || r.is_empty) return _("No text found");
            int n = r.words.size;
            return ngettext("%d word", "%d words", n).printf(n);
        }

        private void set_status(string text, bool busy, string? hint = null) {
            spinner.visible = busy;
            spinner.spinning = busy;
            status_label.label = text;
            hint_label.label = hint ?? "";
            hint_label.visible = hint != null;
        }

        public void set_texture(Gdk.Texture? texture) {
            this.texture = texture;
            generation++;
            if (cancellable != null) cancellable.cancel();
            view.set_result(null);
            if (active) run();
        }

        private void on_toggled() {
            view.visible = toggle.active;
            bar.visible = toggle.active;
            if (toggle.active) {
                if (view.recognized == null) run();
                view.grab_focus();
            } else {
                view.clear_selection();
                if (cancellable != null) cancellable.cancel();
            }
        }

        private void run() {
            clear_data();
            actions_box.visible = false;
            if (!recognizer.available) {
                set_status(_("Text recognition is not installed"), false, recognizer.install_hint);
                bar.add_css_class("unavailable");
                return;
            }
            bar.remove_css_class("unavailable");
            if (texture == null) {
                set_status(_("No text found"), false);
                return;
            }
            set_status(_("Recognizing text…"), true);
            generation++;
            uint gen = generation;
            if (cancellable != null) cancellable.cancel();
            cancellable = new Cancellable();
            recognizer.recognize_texture.begin(texture, cancellable, (obj, res) => {
                RecognizedText? result = null;
                string? error = null;
                try {
                    result = recognizer.recognize_texture.end(res);
                } catch (Error e) {
                    if (e is IOError.CANCELLED) return;
                    error = e.message;
                }
                if (gen != generation) return;
                if (error != null) {
                    set_status(_("Text could not be recognized"), false, error);
                    return;
                }
                view.set_result(result);
                set_status(summary(), false);
                actions_box.visible = !result.is_empty;
                fill_data();
            });
        }

        private void clear_data() {
            Widget? child = data_box.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                data_box.remove(child);
                child = next;
            }
        }

        private void fill_data() {
            clear_data();
            int shown = 0;
            foreach (var item in view.detected) {
                if (shown >= 2) break;
                var chip = new Button();
                chip.add_css_class("pill");
                chip.add_css_class("live-text-data");
                var box = new Box(Orientation.HORIZONTAL, 6);
                box.append(new Image.from_icon_name(item.kind.icon_name()));
                var label = new Label(item.text);
                label.ellipsize = Pango.EllipsizeMode.MIDDLE;
                label.max_width_chars = 22;
                box.append(label);
                chip.child = box;
                chip.tooltip_text = item.kind.to_label();
                chip.clicked.connect(() => view.activate_data(item));
                data_box.append(chip);
                shown++;
            }
        }
    }
}
