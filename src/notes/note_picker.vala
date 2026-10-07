namespace Singularity.Notes {
    public class NotePicker : Object {
        public delegate void PickedCallback(string? note_id);

        public static Widgets.ContextMenu popup(Gtk.Widget anchor, owned PickedCallback picked) {
            var store = NoteStore.get_default();
            var menu = new Widgets.ContextMenu(anchor);
            var cb = (owned) picked;
            menu.add_item(_("New Note"), "document-new-symbolic", () => cb(null));
            var recent = new Gee.ArrayList<Note>();
            foreach (var n in store.all()) {
                if (n.id == NoteStore.QUICK_NOTE_ID || n.id.has_prefix(NoteStore.WIDGET_PREFIX)) continue;
                recent.add(n);
            }
            recent.sort((a, b) => a.modified > b.modified ? -1 : (a.modified < b.modified ? 1 : 0));
            if (!recent.is_empty) menu.add_separator();
            int shown = 0;
            foreach (var n in recent) {
                if (shown++ == 8) break;
                string id = n.id;
                menu.add_item(n.title != "" ? n.title : _("Untitled Note"), "text-x-generic-symbolic", () => cb(id));
            }
            menu.popup();
            return menu;
        }

        public static Note target(string? note_id, string new_title) throws Error {
            var store = NoteStore.get_default();
            if (note_id != null && store.lookup(note_id) != null) return store.lookup(note_id).copy();
            return store.create("# %s\n".printf(new_title));
        }

        public static string attachment_name(string prefix, string extension) {
            return "%s-%s.%s".printf(prefix, new DateTime.now_local().format("%Y%m%d-%H%M%S"), extension);
        }

        public static string attachment_path(Note note, string name) {
            string dir = NoteStore.get_default().attachments_dir(note.id);
            DirUtils.create_with_parents(dir, 0700);
            return Path.build_filename(dir, name);
        }

        public static string attach_file(Note note, File source, string name) throws Error {
            string path = attachment_path(note, name);
            source.copy(File.new_for_path(path), FileCopyFlags.OVERWRITE);
            FileUtils.chmod(path, 0600);
            return attachment_link(note, name);
        }

        public static string attachment_link(Note note, string name) {
            return "attachments/%s/%s".printf(note.id, name);
        }

        public static void append(Note note, string markdown) throws Error {
            note.body = note.body.chomp() + "\n\n" + markdown.chomp() + "\n";
            NoteStore.get_default().save(note);
        }

        public static Widgets.Toast toast(Note note, bool created, string what) {
            var toast = new Widgets.Toast(created ? _("%s added to a new note").printf(what) : _("%s added to %s").printf(what, note.title));
            toast.button_label = _("Open Notes");
            string id = note.id;
            toast.button_clicked.connect(() => {
                ShareTargets.activate_app_action.begin("dev.sinty.notes", "show-note", new Variant.string(id));
            });
            return toast;
        }
    }
}
