using GLib;

namespace Singularity {

    public struct InputSource {
        public string id;
        public string name;
        public string description;
    }

    public class InputSourceUtil {

        public static InputSource[] list() {
            var sources = new List<InputSource?>();
            string? path = find_layout_list();
            if (path != null) {
                string contents;
                try {
                    FileUtils.get_contents(path, out contents);
                    string section = "";
                    foreach (unowned string raw in contents.split("\n")) {
                        string line = raw.chomp();
                        if (line.has_prefix("!")) {
                            section = line.substring(1).strip();
                            continue;
                        }
                        if (line.strip() == "") continue;
                        if (section == "layout")
                            add_layout(line, sources);
                        else if (section == "variant")
                            add_variant(line, sources);
                    }
                } catch (Error e) {
                    warning("Could not read keyboard layout list: %s", e.message);
                }
            }
            sources.sort((a, b) => a.name.collate(b.name));
            InputSource[] arr = new InputSource[sources.length()];
            int i = 0;
            foreach (var s in sources) {
                arr[i++] = s;
            }
            return arr;
        }

        private static string? find_layout_list() {
            string[] paths = {
                "/usr/share/X11/xkb/rules/evdev.lst",
                "/usr/local/share/X11/xkb/rules/evdev.lst"
            };
            foreach (unowned string p in paths) {
                if (FileUtils.test(p, FileTest.EXISTS)) return p;
            }
            return null;
        }

        private static int first_blank(string s) {
            for (int i = 0; i < s.length; i++) {
                if (s[i] == ' ' || s[i] == '\t') return i;
            }
            return -1;
        }

        private static void add_layout(string line, List<InputSource?> sources) {
            string trimmed = line.strip();
            int sep = first_blank(trimmed);
            if (sep <= 0) return;
            string id = trimmed.substring(0, sep);
            string desc = trimmed.substring(sep).strip();
            sources.append(InputSource() { id = id, name = desc, description = id });
        }

        private static void add_variant(string line, List<InputSource?> sources) {
            string trimmed = line.strip();
            int sep = first_blank(trimmed);
            if (sep <= 0) return;
            string variant = trimmed.substring(0, sep);
            string rest = trimmed.substring(sep).strip();
            string layout = variant;
            string desc = rest;
            int colon = rest.index_of(":");
            if (colon > 0) {
                layout = rest.substring(0, colon).strip();
                desc = rest.substring(colon + 1).strip();
            }
            string sid = layout + "+" + variant;
            sources.append(InputSource() { id = sid, name = desc, description = sid });
        }
    }
}
