namespace Singularity.Accessibility {

    public enum ScreenReaderBackendKind {
        NONE,
        GSETTINGS,
        JSON;

        public static ScreenReaderBackendKind parse(string value) {
            switch (value.strip().down()) {
                case "gsettings": return GSETTINGS;
                case "json": return JSON;
                case "none": return NONE;
                default: return NONE;
            }
        }
    }

    public class ScreenReaderConfig : Object {
        public const string FILE_NAME = "singularity/screen-reader.conf";

        public string backend { get; set; default = "auto"; }
        public string profile { get; set; default = "default"; }
        public string json_path { get; set; default = ""; }
        public string voices_command { get; set; default = "spd-say"; }
        public string install_hint { get; set; default = ""; }
        public string? source_path { get; private set; default = null; }

        public static ScreenReaderConfig load() {
            var config = new ScreenReaderConfig();
            foreach (unowned string dir in Environment.get_system_config_dirs()) {
                string path = Path.build_filename(dir, FILE_NAME);
                if (FileUtils.test(path, FileTest.IS_REGULAR) && config.load_file(path)) break;
            }
            return config;
        }

        public bool load_file(string path) {
            var keyfile = new KeyFile();
            try {
                keyfile.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
                warning("ScreenReaderConfig: cannot read %s: %s", path, e.message);
                return false;
            }
            backend = read(keyfile, "Backend", backend);
            profile = read(keyfile, "Profile", profile);
            json_path = read(keyfile, "JsonPath", json_path);
            voices_command = read(keyfile, "VoicesCommand", voices_command);
            install_hint = read(keyfile, "InstallHint", install_hint);
            source_path = path;
            return true;
        }

        private static string read(KeyFile keyfile, string key, string fallback) {
            try {
                if (keyfile.has_key("ScreenReader", key)) return keyfile.get_string("ScreenReader", key).strip();
            } catch (Error e) {
            }
            return fallback;
        }
    }

    public interface ScreenReaderStore : Object {
        public signal void changed();
        public abstract bool get_bool(string key);
        public abstract void set_bool(string key, bool value);
        public abstract int get_int(string key);
        public abstract void set_int(string key, int value);
        public abstract double get_double(string key);
        public abstract void set_double(string key, double value);
        public abstract string get_string(string key);
        public abstract void set_string(string key, string value);
        public abstract string[] get_strv(string key);
        public abstract void set_strv(string key, string[] value);
    }

    public class ScreenReaderSettings : Object {
        public const string[] BOOL_KEYS = { "key-echo", "character-echo", "word-echo" };
        public const string[] VERBOSITY_LEVELS = { "brief", "verbose" };
        public const string[] PUNCTUATION_LEVELS = { "all", "most", "some", "none" };
        public const string[] KEYBOARD_LAYOUTS = { "desktop", "laptop" };
        public const string[] DESKTOP_MODIFIERS = { "Insert", "KP_Insert" };
        public const string[] LAPTOP_MODIFIERS = { "Caps_Lock", "Shift_Lock" };

        public ScreenReaderBackendKind kind { get; private set; default = ScreenReaderBackendKind.NONE; }
        public ScreenReaderConfig config { get; private set; }
        public ScreenReaderStore? store { get; private set; default = null; }

        public signal void changed();

        public ScreenReaderSettings(ScreenReaderConfig config, ScreenReaderBackendKind kind, ScreenReaderStore? store) {
            this.config = config;
            this.kind = kind;
            this.store = store;
            if (store != null) store.changed.connect(() => changed());
        }

        public static ScreenReaderSettings detect(ScreenReaderConfig? config = null) {
            var cfg = config ?? ScreenReaderConfig.load();
            ScreenReaderBackendKind kind;
            if (cfg.backend.down() == "auto" || cfg.backend == "") {
                if (OrcaGSettingsStore.schemas_installed()) kind = ScreenReaderBackendKind.GSETTINGS;
                else if (Environment.find_program_in_path("orca") != null) kind = ScreenReaderBackendKind.JSON;
                else kind = ScreenReaderBackendKind.NONE;
            } else {
                kind = ScreenReaderBackendKind.parse(cfg.backend);
                if (kind == ScreenReaderBackendKind.GSETTINGS && !OrcaGSettingsStore.schemas_installed())
                    kind = ScreenReaderBackendKind.NONE;
            }
            ScreenReaderStore? store = null;
            if (kind == ScreenReaderBackendKind.GSETTINGS) store = new OrcaGSettingsStore(cfg.profile);
            else if (kind == ScreenReaderBackendKind.JSON) store = new OrcaJsonStore(OrcaJsonStore.resolve_path(cfg.json_path), cfg.profile);
            return new ScreenReaderSettings(cfg, kind, store);
        }

        public bool available {
            get { return store != null; }
        }

        public static string[] modifier_keys_for(string choice) {
            switch (choice) {
                case "caps-lock": return LAPTOP_MODIFIERS;
                case "both": return { "Insert", "KP_Insert", "Caps_Lock", "Shift_Lock" };
                default: return DESKTOP_MODIFIERS;
            }
        }

        public static string modifier_choice_for(string[] keys) {
            bool insert = false;
            bool caps = false;
            foreach (unowned string k in keys) {
                if (k == "Insert" || k == "KP_Insert") insert = true;
                if (k == "Caps_Lock" || k == "Shift_Lock") caps = true;
            }
            if (insert && caps) return "both";
            if (caps) return "caps-lock";
            return "insert";
        }

        public string modifier_choice() {
            if (store == null) return "insert";
            return modifier_choice_for(store.get_strv("modifier-keys"));
        }

        public void set_modifier_choice(string choice) {
            if (store == null) return;
            store.set_strv("modifier-keys", modifier_keys_for(choice));
        }
    }

    public class OrcaGSettingsStore : Object, ScreenReaderStore {
        public const string PATH_PREFIX = "/org/gnome/orca/";
        public const string VOICE_SUB_PATH = "voice-sets/primary/default";

        private string profile;
        private Gee.HashMap<string, GLib.Settings> cache = new Gee.HashMap<string, GLib.Settings>();

        public OrcaGSettingsStore(string profile = "default") {
            this.profile = sanitize(profile == "" ? "default" : profile);
        }

        public static bool schemas_installed() {
            var source = SettingsSchemaSource.get_default();
            return source != null && source.lookup("org.gnome.Orca.Speech", true) != null
                && source.lookup("org.gnome.Orca.Voice", true) != null;
        }

        public static string sanitize(string name) {
            var lower = name.down();
            var sb = new StringBuilder();
            bool dash = false;
            for (int i = 0; i < lower.length; i++) {
                char c = lower[i];
                bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
                if (ok) {
                    sb.append_c(c);
                    dash = false;
                } else if (!dash) {
                    sb.append_c('-');
                    dash = true;
                }
            }
            string result = sb.str;
            while (result.has_prefix("-")) result = result.substring(1);
            while (result.has_suffix("-")) result = result.substring(0, result.length - 1);
            return result;
        }

        public static void locate(string key, out string schema_id, out string sub_path, out string gs_key) {
            switch (key) {
                case "speech-server":
                case "synthesizer":
                    schema_id = "org.gnome.Orca.Speech";
                    sub_path = "speech";
                    gs_key = key;
                    return;
                case "verbosity":
                    schema_id = "org.gnome.Orca.Speech";
                    sub_path = "speech";
                    gs_key = "verbosity-level";
                    return;
                case "punctuation":
                    schema_id = "org.gnome.Orca.Speech";
                    sub_path = "speech";
                    gs_key = "punctuation-level";
                    return;
                case "key-echo":
                case "character-echo":
                case "word-echo":
                    schema_id = "org.gnome.Orca.TypingEcho";
                    sub_path = "typing-echo";
                    gs_key = key;
                    return;
                case "keyboard-layout":
                case "desktop-modifier-keys":
                case "laptop-modifier-keys":
                    schema_id = "org.gnome.Orca.Keybindings";
                    sub_path = "keybindings";
                    gs_key = key;
                    return;
                case "voice":
                    schema_id = "org.gnome.Orca.Voice";
                    sub_path = VOICE_SUB_PATH;
                    gs_key = "family-name";
                    return;
                case "voice-lang":
                    schema_id = "org.gnome.Orca.Voice";
                    sub_path = VOICE_SUB_PATH;
                    gs_key = "family-lang";
                    return;
                case "voice-variant":
                    schema_id = "org.gnome.Orca.Voice";
                    sub_path = VOICE_SUB_PATH;
                    gs_key = "family-variant";
                    return;
                default:
                    schema_id = "org.gnome.Orca.Voice";
                    sub_path = VOICE_SUB_PATH;
                    gs_key = key;
                    return;
            }
        }

        public string path_for(string key) {
            string schema_id, sub_path, gs_key;
            locate(key, out schema_id, out sub_path, out gs_key);
            return "%s%s/%s/".printf(PATH_PREFIX, profile, sub_path);
        }

        public static string gs_key_for(string key) {
            string schema_id, sub_path, gs_key;
            locate(key, out schema_id, out sub_path, out gs_key);
            return gs_key;
        }

        private GLib.Settings settings_for(string key) {
            string schema_id, sub_path, gs_key;
            locate(key, out schema_id, out sub_path, out gs_key);
            string path = "%s%s/%s/".printf(PATH_PREFIX, profile, sub_path);
            string cache_key = schema_id + path;
            if (!cache.has_key(cache_key)) {
                var gs = new GLib.Settings.with_path(schema_id, path);
                gs.changed.connect(() => changed());
                cache[cache_key] = gs;
            }
            return cache[cache_key];
        }

        private void mark_voice(string key) {
            string schema_id, sub_path, gs_key;
            locate(key, out schema_id, out sub_path, out gs_key);
            if (schema_id != "org.gnome.Orca.Voice") return;
            var gs = settings_for("established");
            if (!gs.get_boolean("established")) gs.set_boolean("established", true);
        }

        public bool get_bool(string key) {
            return settings_for(key).get_boolean(gs_key_for(key));
        }

        public void set_bool(string key, bool value) {
            settings_for(key).set_boolean(gs_key_for(key), value);
        }

        public int get_int(string key) {
            return settings_for(key).get_int(gs_key_for(key));
        }

        public void set_int(string key, int value) {
            settings_for(key).set_int(gs_key_for(key), value);
            mark_voice(key);
        }

        public double get_double(string key) {
            return settings_for(key).get_double(gs_key_for(key));
        }

        public void set_double(string key, double value) {
            settings_for(key).set_double(gs_key_for(key), value);
            mark_voice(key);
        }

        public string get_string(string key) {
            return settings_for(key).get_string(gs_key_for(key));
        }

        public void set_string(string key, string value) {
            settings_for(key).set_string(gs_key_for(key), value);
            mark_voice(key);
        }

        public string[] get_strv(string key) {
            if (key == "modifier-keys") return get_strv(get_string("keyboard-layout") + "-modifier-keys");
            return settings_for(key).get_strv(gs_key_for(key));
        }

        public void set_strv(string key, string[] value) {
            if (key == "modifier-keys") {
                set_strv(get_string("keyboard-layout") + "-modifier-keys", value);
                return;
            }
            settings_for(key).set_strv(gs_key_for(key), value);
        }
    }

    public class OrcaJsonStore : Object, ScreenReaderStore {
        public string path { get; private set; }
        private string profile;
        private Json.Object root;
        private FileMonitor? monitor = null;
        private bool writing = false;

        public OrcaJsonStore(string path, string profile = "default") {
            this.path = path;
            this.profile = profile == "" ? "default" : profile;
            reload();
            try {
                monitor = File.new_for_path(path).monitor_file(FileMonitorFlags.NONE);
                monitor.changed.connect((f, o, ev) => {
                    if (writing) return;
                    if (ev == FileMonitorEvent.CHANGES_DONE_HINT || ev == FileMonitorEvent.CREATED || ev == FileMonitorEvent.DELETED) {
                        reload();
                        changed();
                    }
                });
            } catch (Error e) {
                monitor = null;
            }
        }

        public static string resolve_path(string configured) {
            if (configured != "") {
                if (configured.has_prefix("~/")) return Path.build_filename(Environment.get_home_dir(), configured.substring(2));
                return configured;
            }
            return Path.build_filename(Environment.get_user_data_dir(), "orca", "user-settings.conf");
        }

        public void reload() {
            root = new Json.Object();
            if (!FileUtils.test(path, FileTest.IS_REGULAR)) return;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var node = parser.get_root();
                if (node != null && node.get_node_type() == Json.NodeType.OBJECT) root = node.get_object();
            } catch (Error e) {
                warning("OrcaJsonStore: cannot read %s: %s", path, e.message);
            }
        }

        private Json.Object? profile_object(bool create) {
            Json.Object? profiles = null;
            if (root.has_member("profiles") && root.get_member("profiles").get_node_type() == Json.NodeType.OBJECT) {
                profiles = root.get_object_member("profiles");
            } else if (create) {
                profiles = new Json.Object();
                root.set_object_member("profiles", profiles);
            }
            if (profiles == null) return null;
            if (profiles.has_member(profile) && profiles.get_member(profile).get_node_type() == Json.NodeType.OBJECT)
                return profiles.get_object_member(profile);
            if (!create) return null;
            var obj = new Json.Object();
            var label = new Json.Array();
            label.add_string_element(profile == "default" ? "Default" : profile);
            label.add_string_element(profile);
            obj.set_array_member("profile", label);
            profiles.set_object_member(profile, obj);
            return obj;
        }

        private Json.Node? lookup(string member) {
            var prof = profile_object(false);
            if (prof != null && prof.has_member(member)) return prof.get_member(member);
            if (root.has_member("general") && root.get_member("general").get_node_type() == Json.NodeType.OBJECT) {
                var general = root.get_object_member("general");
                if (general.has_member(member)) return general.get_member(member);
            }
            return null;
        }

        private void put(string member, Json.Node value) {
            var prof = profile_object(true);
            prof.set_member(member, value);
            save();
        }

        private Json.Object? voice(bool create) {
            var node = lookup("voices");
            Json.Object? voices = null;
            if (node != null && node.get_node_type() == Json.NodeType.OBJECT) voices = node.get_object();
            if (voices == null) {
                if (!create) return null;
                voices = new Json.Object();
                profile_object(true).set_object_member("voices", voices);
            } else if (create) {
                var prof = profile_object(true);
                if (!prof.has_member("voices")) {
                    var copy = new Json.Object();
                    foreach (unowned string m in voices.get_members()) copy.set_member(m, voices.get_member(m).copy());
                    prof.set_object_member("voices", copy);
                    voices = copy;
                }
            }
            Json.Object? def = null;
            if (voices.has_member("default") && voices.get_member("default").get_node_type() == Json.NodeType.OBJECT)
                def = voices.get_object_member("default");
            if (def == null && create) {
                def = new Json.Object();
                voices.set_object_member("default", def);
            }
            return def;
        }

        private Json.Object? family(bool create) {
            var v = voice(create);
            if (v == null) return null;
            if (v.has_member("family") && v.get_member("family").get_node_type() == Json.NodeType.OBJECT)
                return v.get_object_member("family");
            if (!create) return null;
            var f = new Json.Object();
            v.set_object_member("family", f);
            return f;
        }

        public void save() {
            var gen = new Json.Generator();
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(root);
            gen.set_root(node);
            gen.pretty = true;
            gen.indent = 4;
            writing = true;
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                FileUtils.set_contents(path, gen.to_data(null));
            } catch (Error e) {
                warning("OrcaJsonStore: cannot write %s: %s", path, e.message);
            }
            writing = false;
            changed();
        }

        private static string bool_member(string key) {
            switch (key) {
                case "key-echo": return "enableKeyEcho";
                case "character-echo": return "enableEchoByCharacter";
                case "word-echo": return "enableEchoByWord";
                default: return key;
            }
        }

        public bool get_bool(string key) {
            var node = lookup(bool_member(key));
            if (node != null && node.get_value_type() == typeof(bool)) return node.get_boolean();
            return key == "key-echo";
        }

        public void set_bool(string key, bool value) {
            var node = new Json.Node(Json.NodeType.VALUE);
            node.set_boolean(value);
            put(bool_member(key), node);
        }

        private static string voice_member(string key) {
            switch (key) {
                case "pitch": return "average-pitch";
                case "volume": return "gain";
                default: return key;
            }
        }

        private double voice_number(string key, double fallback) {
            var v = voice(false);
            if (v == null || !v.has_member(voice_member(key))) return fallback;
            var node = v.get_member(voice_member(key));
            if (node.get_value_type() == typeof(int64)) return (double) node.get_int();
            if (node.get_value_type() == typeof(double)) return node.get_double();
            return fallback;
        }

        public int get_int(string key) {
            if (key == "rate") return (int) Math.round(voice_number("rate", 50));
            return 0;
        }

        public void set_int(string key, int value) {
            if (key != "rate") return;
            var v = voice(true);
            v.set_int_member("rate", value);
            v.set_boolean_member("established", true);
            save();
        }

        public double get_double(string key) {
            if (key == "pitch") return voice_number("pitch", 5.0);
            if (key == "volume") return voice_number("volume", 10.0);
            return 0;
        }

        public void set_double(string key, double value) {
            if (key != "pitch" && key != "volume") return;
            var v = voice(true);
            v.set_double_member(voice_member(key), value);
            v.set_boolean_member("established", true);
            save();
        }

        private string server_info(int index) {
            var node = lookup("speechServerInfo");
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY) return "";
            var arr = node.get_array();
            if (arr.get_length() <= index) return "";
            var el = arr.get_element(index);
            return el.get_value_type() == typeof(string) ? el.get_string() : "";
        }

        private static string enum_nick(int64 value, string[] nicks) {
            if (value < 0 || value >= nicks.length) return nicks[0];
            return nicks[value];
        }

        private string enum_member(string member, string[] nicks, string fallback) {
            var node = lookup(member);
            if (node == null) return fallback;
            if (node.get_value_type() == typeof(int64)) return enum_nick(node.get_int(), nicks);
            if (node.get_value_type() == typeof(bool)) return enum_nick(node.get_boolean() ? 1 : 0, nicks);
            if (node.get_value_type() == typeof(string)) return node.get_string();
            return fallback;
        }

        private static int nick_index(string value, string[] nicks) {
            for (int i = 0; i < nicks.length; i++) if (nicks[i] == value) return i;
            return 0;
        }

        public string get_string(string key) {
            switch (key) {
                case "speech-server": return server_info(0);
                case "synthesizer": return server_info(1);
                case "verbosity": return enum_member("speechVerbosityLevel", ScreenReaderSettings.VERBOSITY_LEVELS, "verbose");
                case "punctuation": return enum_member("verbalizePunctuationStyle", ScreenReaderSettings.PUNCTUATION_LEVELS, "most");
                case "keyboard-layout": {
                    var node = lookup("keyboardLayout");
                    if (node != null && node.get_value_type() == typeof(int64)) return node.get_int() == 2 ? "laptop" : "desktop";
                    return "desktop";
                }
                case "voice":
                case "voice-lang":
                case "voice-variant": {
                    var f = family(false);
                    string member = key == "voice" ? "name" : key == "voice-lang" ? "lang" : "variant";
                    if (f == null || !f.has_member(member)) return "";
                    var node = f.get_member(member);
                    return node.get_value_type() == typeof(string) ? node.get_string() : "";
                }
                default: return "";
            }
        }

        public void set_string(string key, string value) {
            switch (key) {
                case "speech-server":
                case "synthesizer": {
                    var arr = new Json.Array();
                    arr.add_string_element(key == "speech-server" ? value : get_string("speech-server"));
                    arr.add_string_element(key == "synthesizer" ? value : get_string("synthesizer"));
                    var node = new Json.Node(Json.NodeType.ARRAY);
                    node.set_array(arr);
                    var factory = new Json.Node(Json.NodeType.VALUE);
                    factory.set_string("speechdispatcherfactory");
                    profile_object(true).set_member("speechServerFactory", factory);
                    put("speechServerInfo", node);
                    return;
                }
                case "verbosity":
                case "punctuation": {
                    var node = new Json.Node(Json.NodeType.VALUE);
                    node.set_int(nick_index(value, key == "verbosity"
                        ? ScreenReaderSettings.VERBOSITY_LEVELS : ScreenReaderSettings.PUNCTUATION_LEVELS));
                    put(key == "verbosity" ? "speechVerbosityLevel" : "verbalizePunctuationStyle", node);
                    return;
                }
                case "keyboard-layout": {
                    var node = new Json.Node(Json.NodeType.VALUE);
                    node.set_int(value == "laptop" ? 2 : 1);
                    put("keyboardLayout", node);
                    return;
                }
                case "voice":
                case "voice-lang":
                case "voice-variant": {
                    var f = family(true);
                    string member = key == "voice" ? "name" : key == "voice-lang" ? "lang" : "variant";
                    f.set_string_member(member, value);
                    voice(true).set_boolean_member("established", true);
                    save();
                    return;
                }
                default:
                    return;
            }
        }

        public string[] get_strv(string key) {
            if (key != "modifier-keys") return {};
            var node = lookup("orcaModifierKeys");
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY)
                return get_string("keyboard-layout") == "laptop"
                    ? ScreenReaderSettings.LAPTOP_MODIFIERS : ScreenReaderSettings.DESKTOP_MODIFIERS;
            string[] result = {};
            node.get_array().foreach_element((a, i, el) => {
                if (el.get_value_type() == typeof(string)) result += el.get_string();
            });
            return result;
        }

        public void set_strv(string key, string[] value) {
            if (key != "modifier-keys") return;
            var arr = new Json.Array();
            foreach (unowned string v in value) arr.add_string_element(v);
            var node = new Json.Node(Json.NodeType.ARRAY);
            node.set_array(arr);
            put("orcaModifierKeys", node);
        }
    }

    public class SpeechVoice : Object {
        public string name { get; construct; }
        public string language { get; construct; }
        public string variant { get; construct; }

        public SpeechVoice(string name, string language, string variant) {
            Object(name: name, language: language, variant: variant);
        }
    }

    public class SpeechVoices : Object {
        public string command { get; construct; }

        public SpeechVoices(string command = "spd-say") {
            Object(command: command);
        }

        public bool available {
            get { return command != "" && Environment.find_program_in_path(command) != null; }
        }

        public static string[] parse_modules(string output) {
            string[] result = {};
            foreach (unowned string raw in output.split("\n")) {
                string line = raw.strip();
                if (line == "" || line.has_prefix("OUTPUT MODULES")) continue;
                result += line;
            }
            return result;
        }

        public static SpeechVoice[] parse_voices(string output) {
            SpeechVoice[] result = {};
            foreach (unowned string raw in output.split("\n")) {
                string line = raw.strip();
                if (line == "") continue;
                string[] parts = {};
                foreach (unowned string p in line.split_set(" \t")) if (p != "") parts += p;
                if (parts.length < 3) continue;
                if (parts[0] == "NAME" && parts[parts.length - 2] == "LANGUAGE") continue;
                string name = string.joinv(" ", parts[0:parts.length - 2]);
                result += new SpeechVoice(name, parts[parts.length - 2], parts[parts.length - 1]);
            }
            return result;
        }

        private async string run(string[] args) throws Error {
            string[] argv = { command };
            foreach (unowned string a in args) argv += a;
            var proc = new Subprocess.newv(argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            string? stdout_buf;
            yield proc.communicate_utf8_async(null, null, out stdout_buf, null);
            return stdout_buf ?? "";
        }

        public async string[] list_modules() {
            if (!available) return {};
            try {
                return parse_modules(yield run({ "-O" }));
            } catch (Error e) {
                return {};
            }
        }

        public async SpeechVoice[] list_voices(string module) {
            if (!available) return {};
            try {
                string[] args = module != "" ? new string[] { "-o", module, "-L" } : new string[] { "-L" };
                return parse_voices(yield run(args));
            } catch (Error e) {
                return {};
            }
        }
    }
}
