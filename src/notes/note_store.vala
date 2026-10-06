namespace Singularity.Notes {

    public class NoteStore : Object {
        public const string QUICK_NOTE_ID = "quick-notes";
        public const string WIDGET_PREFIX = "widget-";
        public const string EXTENSION = ".md";

        public string dir { get; construct; }
        public string legacy_data_dir { get; set; }
        public string legacy_documents_dir { get; set; }

        public signal void changed();

        private Gee.HashMap<string, Note> notes = new Gee.HashMap<string, Note>();
        private FileMonitor? monitor = null;
        private uint reload_source = 0;
        private Singularity.Accounts.MirrorLock? file_lock = null;

        public NoteStore(string dir) {
            Object(dir: dir);
            legacy_data_dir = Path.build_filename(Environment.get_user_data_dir(), "singularity");
            legacy_documents_dir = Path.build_filename(Environment.get_home_dir(), "Documents");
        }

        public static string default_dir() {
            string? over = Environment.get_variable("SINGULARITY_NOTES_DIR");
            if (over != null && over != "") return over;
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "notes");
        }

        private static NoteStore? shared = null;

        public static NoteStore get_default() {
            if (shared == null) {
                shared = new NoteStore(default_dir());
                shared.import_legacy();
                shared.load();
                shared.watch();
            }
            return shared;
        }

        public static bool valid_id(string id) {
            if (id == "" || id.length > 200) return false;
            if (id.has_prefix(".")) return false;
            for (int i = 0; i < id.length; i++) {
                char c = id[i];
                if (!(c.isalnum() || c == '-' || c == '_' || c == '.')) return false;
            }
            return true;
        }

        public string path_for(string id) {
            return Path.build_filename(dir, id + EXTENSION);
        }

        public string attachments_dir(string id) {
            return Path.build_filename(dir, "attachments", id);
        }

        public void ensure_dir() {
            DirUtils.create_with_parents(dir, 0700);
        }

        private Singularity.Accounts.MirrorLock store_lock() {
            if (file_lock == null) file_lock = Singularity.Accounts.MirrorLock.for_path(Path.build_filename(dir, ".lock"));
            return file_lock;
        }

        private string? disk_text(string id) {
            string text;
            try {
                if (!FileUtils.get_contents(path_for(id), out text)) return null;
            } catch (FileError e) {
                return null;
            }
            return text;
        }

        public void load() {
            notes.clear();
            try {
                var d = Dir.open(dir);
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!name.has_suffix(EXTENSION)) continue;
                    string id = name.substring(0, name.length - EXTENSION.length);
                    if (!valid_id(id)) continue;
                    var n = read_note(id);
                    if (n != null) notes[id] = n;
                }
            } catch (FileError e) {
            }
        }

        private Note? read_note(string id) {
            string text;
            try {
                if (!FileUtils.get_contents(path_for(id), out text)) return null;
            } catch (FileError e) {
                return null;
            }
            var n = Note.parse(id, text);
            n.origin = text;
            if (n.modified == 0 || n.created == 0) {
                try {
                    var info = File.new_for_path(path_for(id)).query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                    int64 t = (int64) info.get_attribute_uint64(FileAttribute.TIME_MODIFIED);
                    if (n.modified == 0) n.modified = t;
                    if (n.created == 0) n.created = n.modified;
                } catch (Error e) {
                }
            }
            return n;
        }

        public Gee.List<Note> all() {
            var list = new Gee.ArrayList<Note>();
            list.add_all(notes.values);
            list.sort((a, b) => {
                if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
                if (a.modified != b.modified) return a.modified > b.modified ? -1 : 1;
                return strcmp(a.id, b.id);
            });
            return list;
        }

        public Gee.List<Note> search(string query, string? folder = null) {
            var list = new Gee.ArrayList<Note>();
            foreach (var n in all()) {
                if (folder != null && n.folder != folder && !n.folder.has_prefix(folder + "/")) continue;
                if (n.matches(query)) list.add(n);
            }
            return list;
        }

        public Gee.List<string> folders() {
            var set = new Gee.TreeSet<string>((a, b) => strcmp(a.casefold(), b.casefold()));
            foreach (var n in notes.values) if (n.folder != "") set.add(n.folder);
            foreach (string f in extra_folders()) set.add(f);
            var list = new Gee.ArrayList<string>();
            list.add_all(set);
            return list;
        }

        private string folders_path() {
            return Path.build_filename(dir, ".folders");
        }

        public string[] extra_folders() {
            string text;
            try {
                if (!FileUtils.get_contents(folders_path(), out text)) return {};
            } catch (FileError e) {
                return {};
            }
            string[] out_list = {};
            foreach (string line in text.split("\n")) if (line.strip() != "") out_list += line.strip();
            return out_list;
        }

        public void add_folder(string name) throws Error {
            string n = name.strip();
            if (n == "") return;
            var lk = store_lock();
            lk.acquire();
            try {
                string[] current = extra_folders();
                if (n in current) return;
                var sb = new StringBuilder();
                foreach (string f in current) sb.append(f + "\n");
                sb.append(n + "\n");
                ensure_dir();
                FileUtils.set_contents(folders_path(), sb.str);
            } finally {
                lk.release();
            }
            changed();
        }

        public void remove_folder(string name) throws Error {
            var lk = store_lock();
            lk.acquire();
            try {
                var sb = new StringBuilder();
                foreach (string f in extra_folders()) if (f != name) sb.append(f + "\n");
                ensure_dir();
                FileUtils.set_contents(folders_path(), sb.str);
                foreach (var n in notes.values.to_array()) {
                    if (n.folder != name) continue;
                    string? current = disk_text(n.id);
                    if (current != null && n.origin != current) merge_into(n, current, n.origin ?? "");
                    if (n.folder == name) n.folder = "";
                    write(n);
                }
            } finally {
                lk.release();
            }
            changed();
        }

        public Note? lookup(string id) {
            return notes[id];
        }

        public Note create(string body = "", string folder = "") throws Error {
            var n = new Note(Note.new_id());
            int64 now = get_real_time() / 1000000;
            n.created = now;
            n.modified = now;
            n.body = body;
            n.folder = folder;
            save(n, false);
            return n;
        }

        public void save(Note note, bool touch = true) throws Error {
            if (!valid_id(note.id)) throw new IOError.INVALID_ARGUMENT("invalid note id");
            var lk = store_lock();
            lk.acquire();
            try {
                string? current = disk_text(note.id);
                if (current != null && note.origin != current) merge_into(note, current, note.origin ?? "");
                if (touch) note.modified = get_real_time() / 1000000;
                if (note.created == 0) note.created = note.modified;
                write(note);
                notes[note.id] = note;
            } finally {
                lk.release();
            }
            changed();
        }

        private void merge_into(Note note, string current, string base_text) throws Error {
            var base_note = Note.parse(note.id, base_text);
            var theirs = Note.parse(note.id, current);
            string? body = LineMerge.merge(base_note.body, note.body, theirs.body);
            if (body == null) {
                var copy = new Note(Note.new_id());
                copy.body = Note.conflicted_copy_body(theirs.body);
                copy.folder = theirs.folder;
                copy.created = get_real_time() / 1000000;
                copy.modified = copy.created;
                write(copy);
                notes[copy.id] = copy;
                body = note.body;
            }
            note.body = body;
            note.folder = LineMerge.pick(base_note.folder, note.folder, theirs.folder);
            note.pinned = note.pinned != base_note.pinned && theirs.pinned == base_note.pinned ? note.pinned : theirs.pinned;
            if (theirs.created != 0 && (note.created == 0 || theirs.created < note.created)) note.created = theirs.created;
            if (theirs.modified > note.modified) note.modified = theirs.modified;
        }

        private void write(Note note) throws Error {
            ensure_dir();
            string text = note.serialize();
            FileUtils.set_contents_full(path_for(note.id), text, text.length, FileSetContentsFlags.CONSISTENT, 0600);
            note.origin = text;
        }

        public void remove(string id) throws Error {
            if (!valid_id(id)) return;
            var lk = store_lock();
            lk.acquire();
            try {
                var f = File.new_for_path(path_for(id));
                try {
                    f.delete();
                } catch (IOError.NOT_FOUND e) {
                }
                notes.unset(id);
            } finally {
                lk.release();
            }
            changed();
        }

        public bool remove_unchanged(Note note) throws Error {
            if (!valid_id(note.id)) return false;
            var lk = store_lock();
            lk.acquire();
            bool removed = false;
            try {
                string? current = disk_text(note.id);
                if (current != null && note.origin != current) {
                    var fresh = Note.parse(note.id, current);
                    fresh.origin = current;
                    notes[note.id] = fresh;
                } else {
                    var f = File.new_for_path(path_for(note.id));
                    try {
                        f.delete();
                    } catch (IOError.NOT_FOUND e) {
                    }
                    notes.unset(note.id);
                    removed = true;
                }
            } finally {
                lk.release();
            }
            changed();
            return removed;
        }

        public void watch() {
            if (monitor != null) return;
            ensure_dir();
            try {
                monitor = File.new_for_path(dir).monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
                monitor.changed.connect((file, other, ev) => {
                    string name = file.get_basename();
                    if (!name.has_suffix(EXTENSION) && name != ".folders") {
                        if (other == null || !other.get_basename().has_suffix(EXTENSION)) return;
                    }
                    if (reload_source != 0) return;
                    reload_source = Timeout.add(250, () => {
                        reload_source = 0;
                        reload_external();
                        changed();
                        return Source.REMOVE;
                    });
                });
            } catch (Error e) {
                warning("notes: cannot watch %s: %s", dir, e.message);
            }
        }

        public bool reload_external() {
            bool any = false;
            var seen = new Gee.HashSet<string>();
            try {
                var d = Dir.open(dir);
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!name.has_suffix(EXTENSION)) continue;
                    string id = name.substring(0, name.length - EXTENSION.length);
                    if (!valid_id(id)) continue;
                    seen.add(id);
                    string text;
                    try {
                        FileUtils.get_contents(path_for(id), out text);
                    } catch (FileError e) {
                        continue;
                    }
                    var old = notes[id];
                    if (old != null && (old.origin == text || old.serialize() == text)) {
                        old.origin = text;
                        continue;
                    }
                    var fresh = Note.parse(id, text);
                    fresh.origin = text;
                    notes[id] = fresh;
                    any = true;
                }
            } catch (FileError e) {
            }
            foreach (string id in notes.keys.to_array()) {
                if (!seen.contains(id)) {
                    notes.unset(id);
                    any = true;
                }
            }
            return any;
        }

        private string imported_path() {
            return Path.build_filename(dir, ".imported");
        }

        private Gee.HashSet<string> imported_sources() {
            var set = new Gee.HashSet<string>();
            string text;
            try {
                if (FileUtils.get_contents(imported_path(), out text)) {
                    foreach (string line in text.split("\n")) if (line.strip() != "") set.add(line.strip());
                }
            } catch (FileError e) {
            }
            return set;
        }

        private void mark_imported(string source) {
            var set = imported_sources();
            set.add(source);
            var sb = new StringBuilder();
            foreach (string s in set) sb.append(s + "\n");
            try {
                ensure_dir();
                FileUtils.set_contents(imported_path(), sb.str);
            } catch (FileError e) {
                warning("notes: %s", e.message);
            }
        }

        private bool import_file(string source, string id, bool pinned) {
            if (FileUtils.test(path_for(id), FileTest.EXISTS)) return false;
            if (imported_sources().contains(source)) return false;
            string text;
            try {
                if (!FileUtils.get_contents(source, out text)) return false;
            } catch (FileError e) {
                return false;
            }
            if (text.strip() == "") return false;
            var n = new Note(id);
            n.body = text;
            n.pinned = pinned;
            try {
                var info = File.new_for_path(source).query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                n.modified = (int64) info.get_attribute_uint64(FileAttribute.TIME_MODIFIED);
            } catch (Error e) {
                n.modified = get_real_time() / 1000000;
            }
            n.created = n.modified;
            try {
                write(n);
            } catch (Error e) {
                warning("notes: cannot import %s: %s", source, e.message);
                return false;
            }
            mark_imported(source);
            notes[id] = n;
            return true;
        }

        public int import_legacy() {
            var lk = store_lock();
            lk.acquire();
            try {
                return import_legacy_locked();
            } finally {
                lk.release();
            }
        }

        private int import_legacy_locked() {
            int count = 0;
            if (import_file(Path.build_filename(legacy_data_dir, "quick-notes.txt"), QUICK_NOTE_ID, true)) count++;
            try {
                var d = Dir.open(legacy_documents_dir);
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!name.has_prefix("singularity-note-") || !name.has_suffix(".txt")) continue;
                    string instance = name.substring(17, name.length - 17 - 4);
                    string id = WIDGET_PREFIX + instance;
                    if (!valid_id(id)) continue;
                    if (import_file(Path.build_filename(legacy_documents_dir, name), id, false)) count++;
                }
            } catch (FileError e) {
            }
            return count;
        }

        public Note ensure(string id, bool pinned = false) {
            var n = notes[id];
            if (n != null) return n;
            n = new Note(id);
            n.pinned = pinned;
            return n;
        }
    }
}
