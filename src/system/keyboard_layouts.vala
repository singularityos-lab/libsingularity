namespace Singularity {

    public class KeyboardLayouts : Object {
        private const string SOURCES_SCHEMA = "org.gnome.desktop.input-sources";
        private const string RULES = "/usr/share/X11/xkb/rules/evdev.xml";

        private static KeyboardLayouts? instance = null;
        private static Gee.HashMap<string, string>? short_names = null;
        private GLib.Settings desktop;
        private GLib.Settings? sources = null;

        public signal void changed();

        public static KeyboardLayouts get_default() {
            if (instance == null) instance = new KeyboardLayouts();
            return instance;
        }

        private KeyboardLayouts() {
            desktop = new GLib.Settings("dev.sinty.desktop");
            desktop.changed["xkb-layout"].connect(() => changed());
            desktop.changed["xkb-variant"].connect(() => changed());
            var source = GLib.SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup(SOURCES_SCHEMA, true) : null;
            if (schema != null && schema.has_key("sources")) {
                sources = new GLib.Settings(SOURCES_SCHEMA);
                sources.changed["sources"].connect(() => changed());
            }
        }

        public string current() {
            string variant;
            string layout = LocaleManager.effective_keyboard_layout(desktop, out variant);
            return variant != "" ? layout + "+" + variant : layout;
        }

        public string[] configured() {
            string[] result = {};
            if (sources != null) {
                var iter = sources.get_value("sources").iterator();
                string type, id;
                while (iter.next("(ss)", out type, out id)) {
                    if (type == "xkb" && id != "") result += id;
                }
            }
            string active = current();
            if (!(active in result)) {
                string[] with_active = { active };
                foreach (string id in result) with_active += id;
                result = with_active;
            }
            return result;
        }

        public string next() {
            string[] all = configured();
            string active = current();
            for (int i = 0; i < all.length; i++) {
                if (all[i] == active) return all[(i + 1) % all.length];
            }
            return all.length > 0 ? all[0] : active;
        }

        public void select(string id) {
            if (sources != null) {
                var builder = new VariantBuilder(new VariantType("a(ss)"));
                builder.add("(ss)", "xkb", id);
                var iter = sources.get_value("sources").iterator();
                string type, item;
                while (iter.next("(ss)", out type, out item)) {
                    if (type == "xkb" && item == id) continue;
                    builder.add("(ss)", type, item);
                }
                sources.set_value("sources", builder.end());
            }
            int plus = id.index_of_char('+');
            desktop.set_string("xkb-layout", plus > 0 ? id.substring(0, plus) : id);
            desktop.set_string("xkb-variant", plus > 0 ? id.substring(plus + 1) : "");
        }

        public static string short_label(string id) {
            int plus = id.index_of_char('+');
            string layout = plus > 0 ? id.substring(0, plus) : id;
            if (short_names == null) short_names = load_short_names();
            string? name = short_names[layout];
            return (name != null && name != "" ? name : layout).up();
        }

        private static Gee.HashMap<string, string> load_short_names() {
            var names = new Gee.HashMap<string, string>();
            string contents;
            try {
                if (!FileUtils.get_contents(RULES, out contents)) return names;
            } catch (FileError e) {
                return names;
            }
            int from = 0;
            while (true) {
                int layout = contents.index_of("<layout>", from);
                if (layout < 0) break;
                int end = contents.index_of("</configItem>", layout);
                if (end < 0) break;
                string item = contents.substring(layout, end - layout);
                string? name = tag(item, "name");
                string? brief = tag(item, "shortDescription");
                if (name != null && brief != null && !names.has_key(name)) names[name] = brief;
                from = end;
            }
            return names;
        }

        private static string? tag(string text, string name) {
            int start = text.index_of("<" + name + ">");
            if (start < 0) return null;
            start += name.length + 2;
            int end = text.index_of("</" + name + ">", start);
            return end > start ? text.substring(start, end - start).strip() : null;
        }
    }
}
