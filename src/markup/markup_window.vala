using Gtk;
using Singularity.Annotations;

namespace Singularity.Widgets {

    public class MarkupWindow : Window {
        public const string DRAW_APP_ID = "dev.sinty.draw.desktop";

        public File file { get; construct; }
        public bool save_in_place { get; construct; }
        public File? source { get; construct; default = null; }
        public MarkupEditor? editor { get; private set; default = null; }

        public signal void saved(File target);

        public MarkupWindow(Gtk.Application app, File file, bool save_in_place = false) {
            Object(application: app, file: file, save_in_place: save_in_place);
        }

        public MarkupWindow.for_rendition(Gtk.Application app, File file, File source) {
            Object(application: app, file: file, save_in_place: false, source: source);
        }

        construct {
            add_css_class("markup-window");
            set_title(_("Markup"));
            Document document;
            try {
                document = Document.from_file(source ?? file);
            } catch (Error e) {
                var page = new StatusPage();
                page.icon_name = "image-missing";
                page.title = _("This image cannot be opened");
                page.description = e.message;
                set_content(page);
                set_default_size(560, 420);
                return;
            }
            editor = new MarkupEditor(document);
            editor.copied.connect((what) => flash_copy_button(what));
            set_content(editor);
            set_title(file.get_basename() ?? _("Markup"));

            int w = document.width + 80, h = document.height + 160;
            var display = Gdk.Display.get_default();
            int max_w = 1280, max_h = 860;
            if (display != null && display.get_monitors().get_n_items() > 0) {
                var geometry = ((Gdk.Monitor) display.get_monitors().get_item(0)).get_geometry();
                max_w = int.min(max_w, geometry.width - 80);
                max_h = int.min(max_h, geometry.height - 80);
            }
            set_default_size(w.clamp(640, max_w), h.clamp(480, max_h));

            copy_button = add_bubble_icon("edit-copy-symbolic", _("Copy (Ctrl+C)"), () => editor.copy_image());
            add_bubble_icon("singularity-share-symbolic", _("Share"), () => share());
            if (draw_app() != null) {
                add_bubble_text(_("Open in Draw"), () => open_in_draw());
            }
            add_bubble_text(_("Save As…"), () => save_as());
            add_bubble_suggested(_("Done"), () => done());

            var keys = new EventControllerKey();
            keys.set_propagation_phase(PropagationPhase.CAPTURE);
            keys.key_pressed.connect((keyval, keycode, state) => {
                bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
                bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                if (get_focus() is Editable) return false;
                if (ctrl && (keyval == Gdk.Key.c || keyval == Gdk.Key.C)) return editor.copy_image();
                if (ctrl && (keyval == Gdk.Key.s || keyval == Gdk.Key.S)) {
                    if (shift) save_as(); else save();
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller(keys);
        }

        private Gtk.Button? copy_button = null;
        private uint copy_reset_id = 0;

        private void flash_copy_button(string what) {
            if (copy_button == null) return;
            copy_button.icon_name = "object-select-symbolic";
            copy_button.tooltip_text = what;
            if (copy_reset_id != 0) Source.remove(copy_reset_id);
            copy_reset_id = Timeout.add(1500, () => {
                copy_reset_id = 0;
                copy_button.icon_name = "edit-copy-symbolic";
                copy_button.tooltip_text = _("Copy (Ctrl+C)");
                return Source.REMOVE;
            });
        }

        public static AppInfo? draw_app() {
            foreach (var info in AppInfo.get_all()) {
                if (info.get_id() == DRAW_APP_ID) return info;
            }
            return null;
        }

        private bool can_write_in_place() {
            if (!save_in_place) return false;
            string name = (file.get_basename() ?? "").down();
            if (!name.has_suffix(".png")) return false;
            var parent = file.get_parent();
            return parent != null && FileUtils.test(parent.get_path() ?? "", FileTest.IS_DIR);
        }

        public File copy_target(string suffix = ".png") {
            var parent = file.get_parent() ?? File.new_for_path(Environment.get_home_dir());
            string name = file.get_basename() ?? "image";
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            var candidate = parent.get_child(_("%s (Markup)").printf(stem) + suffix);
            int n = 2;
            while (candidate.query_exists()) {
                candidate = parent.get_child(_("%s (Markup %d)").printf(stem, n) + suffix);
                n++;
            }
            return candidate;
        }

        public File? save() {
            if (editor == null) return null;
            editor.commit_text();
            var target = can_write_in_place() ? file : copy_target();
            try {
                editor.document.save_png(target.get_path());
            } catch (Error e) {
                add_toast(new Toast(_("Could not save: %s").printf(e.message)));
                return null;
            }
            saved(target);
            return target;
        }

        private void save_as() {
            if (editor == null) return;
            editor.commit_text();
            var dialog = new FileDialog();
            dialog.title = _("Save Image");
            dialog.initial_file = copy_target();
            dialog.save.begin(this, null, (obj, res) => {
                try {
                    var target = dialog.save.end(res);
                    if (target == null) return;
                    editor.document.save_png(target.get_path());
                    saved(target);
                    add_toast(new Toast(_("Saved as %s").printf(target.get_basename())));
                } catch (Error e) {
                    if (!(e is DialogError.DISMISSED)) add_toast(new Toast(_("Could not save: %s").printf(e.message)));
                }
            });
        }

        private void done() {
            if (editor != null && editor.document.is_modified) {
                if (save() == null) return;
            }
            close();
        }

        private void share() {
            if (editor == null) return;
            File target;
            if (editor.document.is_modified) {
                var saved_file = save();
                if (saved_file == null) return;
                target = saved_file;
            } else {
                target = source ?? file;
            }
            Share.files(this, { target });
        }

        private void open_in_draw() {
            if (editor == null) return;
            editor.commit_text();
            var target = copy_target(".svg");
            try {
                FileUtils.set_contents(target.get_path(), editor.document.to_svg());
                var info = draw_app();
                if (info == null) return;
                var files = new GLib.List<File>();
                files.append(target);
                info.launch(files, get_display().get_app_launch_context());
                add_toast(new Toast(_("Opened %s in Draw").printf(target.get_basename())));
            } catch (Error e) {
                add_toast(new Toast(_("Could not open Draw: %s").printf(e.message)));
            }
        }
    }
}
