namespace Singularity.Notes {
    public class NoteRef : Object {
        public string id { get; construct; }
        public string title { get; construct; }
        public bool created { get; construct; }

        public NoteRef(string id, string title, bool created) {
            Object(id: id, title: title, created: created);
        }
    }

    public class NotePicker : Object {
        public const string INTERFACE = Contracts.NOTES;

        public delegate void PickedCallback(string? note_id);
        public delegate void ClosedCallback();

        private static Gee.ArrayList<NoteRef>? recent_cache = null;

        public static bool available() {
            return Capabilities.available(INTERFACE);
        }

        public static Gee.List<NoteRef> cached_recent() {
            if (recent_cache == null) recent_cache = new Gee.ArrayList<NoteRef>();
            return recent_cache.read_only_view;
        }

        private static void remember(Variant list) {
            var fresh = new Gee.ArrayList<NoteRef>();
            for (size_t i = 0; i < list.n_children(); i++) {
                string id, title;
                list.get_child(i, "(ss)", out id, out title);
                fresh.add(new NoteRef(id, title, false));
            }
            recent_cache = fresh;
        }

        public static void refresh_recent() {
            if (!available()) return;
            Capabilities.call.begin(INTERFACE, "ListRecent", new Variant("(i)", 8), new VariantType("(a(ss))"), 10000, (obj, res) => {
                try {
                    remember(Capabilities.call.end(res).get_child_value(0));
                } catch (Error e) {
                    warning("Notes: %s", e.message);
                }
            });
        }

        public static void popup(Gtk.Widget anchor, owned PickedCallback picked, owned ClosedCallback? closed = null, Gdk.Rectangle? at = null) {
            var cb = (owned) picked;
            var done = (owned) closed;
            Capabilities.call.begin(INTERFACE, "ListRecent", new Variant("(i)", 8), new VariantType("(a(ss))"), 10000, (obj, res) => {
                var menu = new Widgets.ContextMenu(anchor);
                if (at != null) menu.set_pointing_to(at);
                menu.add_item(_("New Note"), "document-new-symbolic", () => cb(null));
                try {
                    remember(Capabilities.call.end(res).get_child_value(0));
                } catch (Error e) {
                    warning("Notes: %s", e.message);
                }
                if (!cached_recent().is_empty) menu.add_separator();
                foreach (var n in cached_recent()) {
                    string id = n.id;
                    menu.add_item(n.title != "" ? n.title : _("Untitled Note"), "text-x-generic-symbolic", () => cb(id));
                }
                menu.closed.connect(() => {
                    if (done != null) done();
                    Idle.add(() => {
                        menu.unparent();
                        return Source.REMOVE;
                    });
                });
                menu.popup();
            });
        }

        public static string attachment_name(string prefix, string extension) {
            return "%s-%s.%s".printf(prefix, new DateTime.now_local().format("%Y%m%d-%H%M%S"), extension);
        }

        public static async NoteRef add(string? note_id, string new_title, string markdown) throws Error {
            var reply = yield Capabilities.call(INTERFACE, "Append", new Variant("(sss)", note_id ?? "", new_title, markdown), new VariantType("(ss)"));
            string id, title;
            reply.get("(ss)", out id, out title);
            return new NoteRef(id, title, note_id == null);
        }

        public static async NoteRef add_file(string? note_id, string new_title, File file, string name, string markdown) throws Error {
            var reply = yield Capabilities.call(INTERFACE, "AttachFile", new Variant("(ssss)", note_id ?? "", new_title, file.get_path() ?? "", name), new VariantType("(ss)"));
            string id, link;
            reply.get("(ss)", out id, out link);
            int at = markdown.index_of("{link}");
            string block = at >= 0 ? markdown.substring(0, at) + link + markdown.substring(at + 6) : markdown + link + "\n";
            var note = yield add(id, new_title, block);
            return new NoteRef(note.id, note.title, note_id == null);
        }

        public static Widgets.Toast toast(NoteRef note, string what) {
            var toast = new Widgets.Toast(note.created ? _("%s added to a new note").printf(what) : _("%s added to %s").printf(what, note.title));
            toast.button_label = _("Open Notes");
            string id = note.id;
            toast.button_clicked.connect(() => Capabilities.call_and_forget(INTERFACE, "Show", new Variant("(s)", id)));
            return toast;
        }
    }
}
