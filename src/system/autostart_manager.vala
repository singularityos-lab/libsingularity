using GLib;

namespace Singularity {

    /**
     * Reads and edits the XDG autostart entries of the session.
     *
     * `dir` is the user's directory, where every change is written; its
     * entries start as they always did. Among the system entries only two
     * kinds start: those in the Singularity prefix directories, where the
     * apps install their background services, and those elsewhere in
     * `XDG_CONFIG_DIRS` whose `OnlyShowIn` names Singularity. A user entry
     * replaces the system entry with the same file name, and `Hidden=true`
     * there turns it off.
     */
    public class AutostartManager : Object {
        /** The Singularity prefix directory for app autostart files. */
        public const string PREFIX_AUTOSTART_DIR = "/opt/local/etc/xdg/autostart";
        /** The desktop name matched by `OnlyShowIn` and `NotShowIn`. */
        public const string DESKTOP_NAME = "Singularity";

        public string dir { get; construct; }

        private string[] _prefix_dirs;
        private string[] _system_dirs;

        public AutostartManager() {
            Object(dir: Path.build_filename(Environment.get_user_config_dir(), "autostart"));
            _prefix_dirs = { PREFIX_AUTOSTART_DIR };
            _system_dirs = default_system_dirs();
        }

        /**
         * A manager over explicit directories, for tests and tools.
         *
         * @param user_dir    Directory written by the manager.
         * @param prefix_dirs Directories whose entries start without naming Singularity.
         * @param system_dirs Directories whose entries start only with `OnlyShowIn=Singularity`.
         */
        public AutostartManager.with_dirs(string user_dir, string[] prefix_dirs, string[] system_dirs) {
            Object(dir: user_dir);
            _prefix_dirs = prefix_dirs;
            _system_dirs = system_dirs;
        }

        /** The `XDG_CONFIG_DIRS` autostart directories, highest priority first, without the prefix one. */
        public static string[] default_system_dirs() {
            string[] dirs = {};
            foreach (unowned string config_dir in Environment.get_system_config_dirs()) {
                string path = Path.build_filename(config_dir, "autostart");
                if (path != PREFIX_AUTOSTART_DIR && !(path in dirs)) dirs += path;
            }
            return dirs;
        }

        /**
         * The entries the session starts, one per file name: the user's own
         * entries that pass `user_entry_should_launch`, and the system entries
         * without a user entry of the same name that pass `system_entry_should_launch`.
         *
         * @param desktop The current desktop names, or null for `XDG_CURRENT_DESKTOP`.
         */
        public Gee.List<string> launchable_entries(string? desktop = null) {
            var list = new Gee.ArrayList<string>();
            foreach (var entry in effective_entries()) {
                if (entry.kind == EntryKind.USER) {
                    if (user_entry_should_launch(entry.path)) list.add(entry.path);
                } else if (system_entry_should_launch(entry.path, entry.kind == EntryKind.SYSTEM, desktop)) {
                    list.add(entry.path);
                }
            }
            return list;
        }

        /**
         * The entries the settings page lists: the user's entries that are
         * not hidden, and the system entries the session would start.
         */
        public Gee.List<string> visible_entries() {
            var list = new Gee.ArrayList<string>();
            foreach (var entry in effective_entries()) {
                if (entry.kind == EntryKind.USER) {
                    if (!is_hidden(entry.path)) list.add(entry.path);
                } else if (system_entry_should_launch(entry.path, entry.kind == EntryKind.SYSTEM, null)) {
                    list.add(entry.path);
                }
            }
            return list;
        }

        /** Whether `path` is not in the user's directory. */
        public bool is_system_entry(string path) {
            return Path.get_dirname(path) != dir;
        }

        /** Whether the entry at `path` sets `Hidden=true`. */
        public static bool is_hidden(string path) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
                return kf.has_key("Desktop Entry", "Hidden") && kf.get_boolean("Desktop Entry", "Hidden");
            } catch (Error e) {
                return false;
            }
        }

        /**
         * The rule for the user's own entries: not hidden, the desktop file
         * loads and should be shown, and `X-GNOME-Autostart-enabled` is not
         * false.
         */
        public static bool user_entry_should_launch(string path) {
            if (is_hidden(path)) return false;
            var info = new DesktopAppInfo.from_filename(path);
            if (info == null || !info.should_show()) return false;
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
                if (kf.has_key("Desktop Entry", "X-GNOME-Autostart-enabled")
                        && !kf.get_boolean("Desktop Entry", "X-GNOME-Autostart-enabled"))
                    return false;
            } catch (Error e) {
            }
            return true;
        }

        /**
         * The rule for system entries: not hidden or disabled, `TryExec`
         * found, shown in the current desktop by `OnlyShowIn` and
         * `NotShowIn`, and its `X-GNOME-AutostartCondition`, if any, met.
         * With `require_only_show_in`, `OnlyShowIn` must name Singularity.
         *
         * @param path                 The desktop file.
         * @param require_only_show_in Whether the entry must name Singularity in `OnlyShowIn`.
         * @param desktop              The current desktop names, or null for `XDG_CURRENT_DESKTOP`.
         */
        public static bool system_entry_should_launch(string path, bool require_only_show_in, string? desktop = null) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
                const string G = "Desktop Entry";
                if (kf.has_key(G, "Type") && kf.get_string(G, "Type") != "Application") return false;
                if (kf.has_key(G, "Hidden") && kf.get_boolean(G, "Hidden")) return false;
                if (kf.has_key(G, "X-GNOME-Autostart-enabled") && !kf.get_boolean(G, "X-GNOME-Autostart-enabled"))
                    return false;
                if (!kf.has_key(G, "Exec") || kf.get_string(G, "Exec").strip() == "") return false;
                if (kf.has_key(G, "TryExec")) {
                    string try_exec = kf.get_string(G, "TryExec").strip();
                    if (try_exec != "" && Environment.find_program_in_path(try_exec) == null) return false;
                }
                string[] current = current_desktops(desktop);
                bool named = false;
                if (kf.has_key(G, "OnlyShowIn")) {
                    foreach (var name in kf.get_string_list(G, "OnlyShowIn")) {
                        if (name in current) named = true;
                    }
                    if (!named) return false;
                }
                if (require_only_show_in) {
                    if (!kf.has_key(G, "OnlyShowIn")) return false;
                    if (!(DESKTOP_NAME in kf.get_string_list(G, "OnlyShowIn"))) return false;
                }
                if (kf.has_key(G, "NotShowIn")) {
                    foreach (var name in kf.get_string_list(G, "NotShowIn")) {
                        if (name in current) return false;
                    }
                }
                if (kf.has_key(G, "X-GNOME-AutostartCondition")
                        && !condition_met(kf.get_string(G, "X-GNOME-AutostartCondition")))
                    return false;
                return true;
            } catch (Error e) {
                return false;
            }
        }

        /**
         * Evaluates an `X-GNOME-AutostartCondition`: `if-exists FILE` and
         * `unless-exists FILE`, relative to the user's config directory, and
         * `GSettings SCHEMA KEY`. Other conditions, such as GNOME session
         * ones, are not met.
         */
        public static bool condition_met(string condition) {
            string[] words = condition.strip().split_set(" \t", 3);
            if (words.length < 2) return false;
            string kind = words[0].down();
            if (kind == "if-exists" || kind == "unless-exists") {
                string file = words[1];
                if (words.length == 3) file += " " + words[2];
                string path = Path.is_absolute(file) ? file : Path.build_filename(Environment.get_user_config_dir(), file);
                bool exists = FileUtils.test(path, FileTest.EXISTS);
                return kind == "if-exists" ? exists : !exists;
            }
            if (kind == "gsettings" && words.length == 3) {
                var source = SettingsSchemaSource.get_default();
                var schema = source != null ? source.lookup(words[1], true) : null;
                string key = words[2].strip();
                if (schema == null || !schema.has_key(key)) return false;
                if (!schema.get_key(key).get_value_type().equal(VariantType.BOOLEAN)) return false;
                return new GLib.Settings.full(schema, null, null).get_boolean(key);
            }
            return false;
        }

        private static string[] current_desktops(string? desktop) {
            string? env = desktop ?? Environment.get_variable("XDG_CURRENT_DESKTOP");
            if (env == null || env.strip() == "") return { DESKTOP_NAME };
            return env.split(":");
        }

        private enum EntryKind { USER, PREFIX, SYSTEM }

        private class Entry {
            public string path;
            public EntryKind kind;

            public Entry(string path, EntryKind kind) {
                this.path = path;
                this.kind = kind;
            }
        }

        private Gee.List<Entry> effective_entries() {
            var list = new Gee.ArrayList<Entry>();
            var seen = new Gee.HashSet<string>();
            add_dir_entries(dir, EntryKind.USER, list, seen);
            foreach (unowned string prefix_dir in _prefix_dirs) add_dir_entries(prefix_dir, EntryKind.PREFIX, list, seen);
            foreach (unowned string system_dir in _system_dirs) add_dir_entries(system_dir, EntryKind.SYSTEM, list, seen);
            list.sort((a, b) => GLib.strcmp(Path.get_basename(a.path), Path.get_basename(b.path)));
            return list;
        }

        private void add_dir_entries(string path, EntryKind kind, Gee.List<Entry> list, Gee.Set<string> seen) {
            Dir d;
            try {
                d = Dir.open(path, 0);
            } catch (FileError e) {
                return;
            }
            string? name;
            while ((name = d.read_name()) != null) {
                if (!name.has_suffix(".desktop") || name in seen) continue;
                seen.add(name);
                list.add(new Entry(Path.build_filename(path, name), kind));
            }
        }

        private string? system_entry_named(string name) {
            foreach (unowned string prefix_dir in _prefix_dirs) {
                string path = Path.build_filename(prefix_dir, name);
                if (FileUtils.test(path, FileTest.EXISTS)) return path;
            }
            foreach (unowned string system_dir in _system_dirs) {
                string path = Path.build_filename(system_dir, name);
                if (FileUtils.test(path, FileTest.EXISTS)) return path;
            }
            return null;
        }

        private void write_hidden_override(string name) {
            ensure_dir();
            string target = Path.build_filename(dir, name);
            var kf = new KeyFile();
            kf.set_string("Desktop Entry", "Type", "Application");
            kf.set_string("Desktop Entry", "Name", name);
            kf.set_string("Desktop Entry", "Exec", "true");
            kf.set_boolean("Desktop Entry", "Hidden", true);
            try {
                FileUtils.set_contents(target, kf.to_data());
            } catch (Error e) {
                warning("Autostart: failed to write %s: %s", target, e.message);
            }
        }

        public Gee.List<string> entries() {
            var list = new Gee.ArrayList<string>();
            var d = File.new_for_path(dir);
            if (!d.query_exists()) return list;
            try {
                var en = d.enumerate_children("standard::name", FileQueryInfoFlags.NONE);
                FileInfo? fi;
                while ((fi = en.next_file()) != null) {
                    string n = fi.get_name();
                    if (n.has_suffix(".desktop"))
                        list.add(Path.build_filename(dir, n));
                }
            } catch (Error e) {
                warning("Autostart: failed to read %s: %s", dir, e.message);
            }
            list.sort((a, b) => GLib.strcmp(Path.get_basename(a), Path.get_basename(b)));
            return list;
        }

        public bool contains(string desktop_id) {
            string path = Path.build_filename(dir, desktop_id);
            if (File.new_for_path(path).query_exists()) return !is_hidden(path);
            string? system = system_entry_named(desktop_id);
            if (system == null) return false;
            return system_entry_should_launch(system, !(Path.get_dirname(system) in _prefix_dirs), null);
        }

        public void add_app(DesktopAppInfo info) {
            ensure_dir();
            string id = info.get_id() ?? (info.get_display_name() + ".desktop");
            string target = Path.build_filename(dir, id);
            var kf = new KeyFile();
            string? src = info.get_filename();
            try {
                if (src != null && kf.load_from_file(src, KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS)) {
                } else {
                    build_minimal_keyfile(kf, info.get_display_name(),
                        info.get_commandline() ?? "", info.get_icon());
                }
                kf.set_boolean("Desktop Entry", "X-GNOME-Autostart-enabled", true);
                FileUtils.set_contents(target, kf.to_data());
            } catch (Error e) {
                warning("Autostart: failed to write %s: %s", target, e.message);
            }
        }

        public void add_command(string command) {
            ensure_dir();
            string sanitized = command.split(" ")[0];
            sanitized = Path.get_basename(sanitized).replace("/", "_");
            if (sanitized == "") sanitized = "command";
            string target = Path.build_filename(dir, "custom-" + sanitized + ".desktop");
            var kf = new KeyFile();
            build_minimal_keyfile(kf, sanitized, command, null);
            try {
                kf.set_boolean("Desktop Entry", "X-GNOME-Autostart-enabled", true);
                FileUtils.set_contents(target, kf.to_data());
            } catch (Error e) {
                warning("Autostart: failed to write %s: %s", target, e.message);
            }
        }

        /**
         * Stops the entry at `path` from starting. A user entry is deleted;
         * when a system entry with the same name exists, or `path` is one,
         * a `Hidden=true` entry is written in the user's directory instead.
         */
        public void remove(string path) {
            string name = Path.get_basename(path);
            if (is_system_entry(path)) {
                if (system_entry_named(name) == path) write_hidden_override(name);
                return;
            }
            if (system_entry_named(name) != null) {
                write_hidden_override(name);
                return;
            }
            try { File.new_for_path(path).delete(); }
            catch (Error e) { warning("Autostart: failed to remove %s: %s", path, e.message); }
        }

        private void ensure_dir() {
            var d = File.new_for_path(dir);
            if (!d.query_exists()) {
                try { d.make_directory_with_parents(); }
                catch (Error e) { warning("Autostart: cannot create %s: %s", dir, e.message); }
            }
        }

        private void build_minimal_keyfile(KeyFile kf, string name, string exec, GLib.Icon? icon) {
            kf.set_string("Desktop Entry", "Type", "Application");
            kf.set_string("Desktop Entry", "Name", name);
            kf.set_string("Desktop Entry", "Exec", exec);
            kf.set_boolean("Desktop Entry", "Terminal", false);
            if (icon != null) kf.set_string("Desktop Entry", "Icon", icon.to_string());
        }
    }
}
