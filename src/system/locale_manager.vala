using GLib;

namespace Singularity {

    [DBus (name = "org.freedesktop.locale1")]
    public interface Locale1 : Object {
        public abstract string[] locale { owned get; }
        public abstract string x11_layout { owned get; }
        public abstract string x11_model { owned get; }
        public abstract string x11_variant { owned get; }
        public abstract string x11_options { owned get; }
        public abstract string vconsole_keymap { owned get; }
        public abstract string vconsole_keymap_toggle { owned get; }
        public abstract void set_locale(string[] locale, bool interactive) throws Error;
        public abstract void set_vconsole_keyboard(string keymap, string keymap_toggle, bool convert, bool interactive) throws Error;
        public abstract void set_x11_keyboard(string layout, string model, string variant, string options, bool convert, bool interactive) throws Error;
    }
    public class LocaleManager : Object {
        private Locale1? proxy;
        public string[] current_locale { get; private set; default = {}; }
        public signal void state_changed();

        public LocaleManager() {
            init_async.begin();
        }

        private async void init_async() {
            try {
                proxy = yield Bus.get_proxy(BusType.SYSTEM, "org.freedesktop.locale1", "/org/freedesktop/locale1");
                message("LocaleManager: Connected to org.freedesktop.locale1");
                proxy.notify["locale"].connect(() => {
                    update_properties();
                    state_changed();
                });
                update_properties();
            } catch (Error e) {
                warning("Failed to connect to locale1: %s", e.message);
            }
        }

        private void update_properties() {
            if (proxy == null) return;
            this.current_locale = proxy.locale;
            state_changed();
        }

        public void update_locale(string[] locale_settings) {
            if (proxy == null) return;
            string[] merged = {};
            foreach (string s in locale_settings) merged += s;
            foreach (string current in current_locale) {
                string key = current.split("=", 2)[0];
                bool replaced = false;
                foreach (string s in locale_settings) {
                    if (s.split("=", 2)[0] == key) replaced = true;
                }
                if (!replaced) merged += current;
            }
            try {
                proxy.set_locale(merged, true);
            } catch (Error e) {
                warning("Failed to set locale: %s", e.message);
            }
        }

        public List<string> get_available_locales() {
            var list = new List<string>();
            try {
                var file = File.new_for_path("/usr/share/i18n/SUPPORTED");
                if (!file.query_exists()) return installed_locales();
                var dis = new DataInputStream(file.read());
                string? line;
                while ((line = dis.read_line(null)) != null) {
                    string locale = line.strip().split(" ")[0];
                    if (locale != "") {
                        list.append(locale);
                    }
                }
            } catch (Error e) {
                warning("Failed to read supported locales: %s", e.message);
            }
            return list;
        }

        private List<string> installed_locales() {
            var list = new List<string>();
            SintySystem.TextList installed;
            if (SintySystem.i18n_installed_locales(out installed) != 0 || installed.count() == 0) {
                warning("Failed to list installed locales");
                return list;
            }
            string[] names = {};
            for (size_t i = 0; i < installed.count(); i++) names += installed.at(i);
            foreach (string line in names) {
                string name = line.strip();
                if (name == "" || name == "C" || name == "POSIX" || name.has_prefix("C.")) continue;
                string[] parts = name.split(".", 2);
                if (parts.length == 2 && parts[1].down().replace("-", "") == "utf8") name = parts[0] + ".UTF-8";
                bool seen = false;
                foreach (string l in list) {
                    if (l == name) seen = true;
                }
                if (!seen) list.append(name);
            }
            return list;
        }

        public string get_lang_value() {
            foreach (string s in current_locale) {
                if (s.has_prefix("LANG=")) {
                    return s.substring(5);
                }
            }
            return "";
        }

        public string get_formats_value() {
            foreach (string s in current_locale) {
                if (s.has_prefix("LC_TIME=")) {
                    return s.substring(8);
                }
            }
            return get_lang_value();
        }
    }
}
