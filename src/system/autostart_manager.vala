using GLib;

namespace Singularity {

    public class AutostartManager : Object {
        public string dir { get; construct; }

        public AutostartManager() {
            Object(dir: Path.build_filename(Environment.get_user_config_dir(), "autostart"));
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
            return File.new_for_path(Path.build_filename(dir, desktop_id)).query_exists();
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

        public void remove(string path) {
            if (!path.has_prefix(dir)) return;
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
